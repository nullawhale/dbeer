//! One captured close flow. No close request itself sends Stop or removes a session.
use super::*;
use profiles::ProfileMutation;
use std::sync::Arc;
mod activities;
mod changes;
pub(crate) mod finalizers;
#[cfg(all(test, feature = "native-smoke"))]
mod native_tests;
mod platform;

#[derive(Clone)]
pub enum CloseIntent {
    Tab(DocumentId),
    Profile(ProfileId),
    ProfileMutation(Arc<ProfileMutation>),
    Window,
    ClearDrafts,
}
impl CloseIntent {
    fn profile_id(&self) -> Option<ProfileId> {
        match self {
            Self::Profile(id) => Some(id.clone()),
            Self::ProfileMutation(mutation) => Some(mutation.profile_id()),
            _ => None,
        }
    }
}

/// A continuation is valid only for its original flow, even after Cancel/retry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct CloseToken(u64);
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Activity {
    File(u64),
    Export(u64),
    RunFile(u64),
    Changes(u64),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum ClosePhase {
    Reviewing,
    OwnersReview,
    OwnersWaiting,
    OwnersStopping,
    CatalogReview,
    CatalogWaiting,
    Changes(DocumentId),
    ApplyingChanges(DocumentId),
    Running(DocumentId),
    Stopping(DocumentId),
    Transaction(DocumentId),
    Resolving(DocumentId),
    Unknown,
    UnknownChanges(DocumentId),
    Disconnecting,
    Finishing,
}
pub(super) struct CloseFlow {
    pub(super) token: CloseToken,
    intent: CloseIntent,
    documents: Vec<(DocumentId, ProfileId)>,
    profiles: Vec<(ProfileId, u64, Option<ConnectionProfile>)>,
    pub(super) phase: ClosePhase,
    acknowledged_unknown: bool,
    resolution_session: Option<(DocumentId, u64, String)>,
    helpers_finished: bool,
    helpers: Vec<BackendClient>,
    focus: Option<FocusHandle>,
    drafts: Vec<DraftReview>,
    activities: Vec<Activity>,
    unknown_discards: Vec<DocumentId>,
    finalized: Vec<(finalizers::FinalizerKind, u64)>,
}
/// Constructed only after the original latest document write completed and all
/// retained participant revisions matched in this same UI turn.
pub(super) struct TerminalEvidence {
    token: CloseToken,
    snapshot: restoration::Snapshot,
}
/// Resolution stays bound to one immutable row/capability snapshot and draft
/// revision. Approval is deferred; Cancel at any later decision keeps buffers.
#[derive(Clone)]
pub(super) struct DraftReview {
    pub(super) document: DocumentId,
    pub(super) grid: Entity<TableState<ResultGrid>>,
    fingerprint: grid_changes::Fingerprint,
    revision: u64,
    approved: bool,
}
impl DraftReview {
    pub(super) fn discard_allowed(&self, cx: &App) -> bool {
        self.approved && self.valid(cx)
    }
    pub(super) fn valid(&self, cx: &App) -> bool {
        let g = self.grid.read(cx).delegate();
        g.context_valid
            && g.draft
                .as_ref()
                .is_some_and(|d| d.fingerprint == self.fingerprint && d.revision == self.revision)
    }
}
impl CloseFlow {
    fn contains(&self, id: DocumentId) -> bool {
        self.documents.iter().any(|(document, _)| *document == id)
    }
    fn transition(&mut self, token: CloseToken, from: ClosePhase, to: ClosePhase) -> bool {
        if self.token != token || self.phase != from {
            return false;
        }
        self.phase = to;
        true
    }
}

/// Teardown replies never resolve a current selection or a replacement session.
#[derive(Clone)]
struct DisconnectTarget {
    document: Option<(DocumentId, u64)>,
    profile: ProfileId,
    profile_generation: u64,
    session: String,
    settings: Option<ConnectionProfile>,
    client: BackendClient,
}
impl Workspace {
    pub(super) fn request_close_from_command(
        &mut self,
        intent: CloseIntent,
        focus: Option<FocusHandle>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let previous = self.next_close;
        self.request_close(intent, window, cx);
        if self.next_close != previous
            && let Some(flow) = self.close_flow.as_mut()
        {
            flow.focus = focus.or_else(|| flow.focus.take());
        }
    }
    pub fn request_close(
        &mut self,
        intent: CloseIntent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // Idempotent across every origin and phase. Only a token-bearing internal
        // continuation can advance the existing decision; another close is not Stop.
        if self.closing || self.close_flow.is_some() || self.transfer_task.is_some() {
            return;
        }
        self.invalidate_dead_helper();
        if let CloseIntent::ProfileMutation(mutation) = &intent
            && !mutation.matches(&self.profiles)
        {
            self.restore_profile_editor(
                mutation,
                Some(connections::ProfileError::Conflict.to_string()),
                window,
                cx,
            );
            return;
        }
        // This original Settings owner may have native chooser/parse/publication
        // futures. Invalidate only uncommitted UI authority; its registered finalizer
        // retains and drains every original job before window removal.
        self.prepare_appearance_close(window, cx);
        let activities = self.close_activities();
        // Preserve an existing owned review/native picker and its exact future.
        // An unrelated modal still owns the window and cannot be replaced.
        let owned_execution_review = self
            .tabs
            .iter()
            .any(|t| t.busy() && t.phase == Some(model::OperationPhase::Reviewing));
        if activities.is_empty()
            && !owned_execution_review
            && (window.has_active_dialog(cx) || window.has_active_prompt())
        {
            return;
        }
        let scope = intent.profile_id();
        let documents: Vec<_> = self
            .tabs
            .iter()
            .filter(|tab| match &intent {
                CloseIntent::Tab(id) => tab.id == *id,
                CloseIntent::Profile(_) | CloseIntent::ProfileMutation(_) => {
                    scope.as_ref() == Some(&tab.profile)
                }
                CloseIntent::Window => true,
                CloseIntent::ClearDrafts => tab.kind == model::DocumentKind::Sql,
            })
            .map(|tab| (tab.id, tab.profile.clone()))
            .collect();
        let profiles = self
            .profiles
            .iter()
            .filter(|profile| {
                matches!(intent, CloseIntent::Window | CloseIntent::ClearDrafts)
                    || scope.as_ref() == Some(&profile.id)
                    || documents.iter().any(|(_, id)| id == &profile.id)
            })
            .map(|profile| {
                (
                    profile.id.clone(),
                    profile.generation,
                    profile.config.clone(),
                )
            })
            .collect();
        self.next_close += 1;
        let token = CloseToken(self.next_close);
        let drafts = self
            .tabs
            .iter()
            .filter(|tab| documents.iter().any(|(id, _)| *id == tab.id))
            .flat_map(|tab| {
                tab.grid_views.values().filter_map(|grid| {
                    let g = grid.read(cx).delegate();
                    let d = g.draft.as_ref()?;
                    Some(DraftReview {
                        document: tab.id,
                        grid: grid.clone(),
                        fingerprint: d.fingerprint.clone(),
                        revision: d.revision,
                        approved: !g.has_drafts(),
                    })
                })
            })
            .collect();
        let mut helpers = Vec::<BackendClient>::new();
        for client in self
            .backend
            .iter()
            .cloned()
            .chain(self.tabs.iter().filter_map(|t| {
                t.session_client()
                    .or_else(|| t.operation_client.clone())
                    .or_else(|| t.run_file_recovery.as_ref().and_then(|r| r.client.clone()))
            }))
            .chain(
                self.profiles
                    .iter()
                    .filter_map(|p| p.session_client.clone()),
            )
        {
            if !helpers.iter().any(|c| c.same_instance(&client)) {
                helpers.push(client);
            }
        }
        self.close_flow = Some(CloseFlow {
            token,
            intent,
            documents,
            profiles,
            phase: ClosePhase::Reviewing,
            acknowledged_unknown: false,
            resolution_session: None,
            helpers_finished: false,
            helpers,
            focus: window.focused(cx),
            drafts,
            activities,
            unknown_discards: Vec::new(),
            finalized: Vec::new(),
        });
        self.closing = true;
        self.publish_close_readiness();
        self.lock_close_drafts(true, cx);
        self.resume_close(token, window, cx);
    }
    fn close_valid(&self, token: CloseToken) -> bool {
        self.close_flow.as_ref().is_some_and(|flow| {
            flow.token == token
                && flow.documents.iter().all(|(id, profile)| {
                    self.tabs
                        .iter()
                        .any(|tab| tab.id == *id && tab.profile == *profile)
                })
                && flow.profiles.iter().all(|(id, generation, config)| {
                    self.profiles.iter().any(|profile| {
                        profile.id == *id
                            && profile.generation == *generation
                            && profile.config == *config
                    })
                })
                && match &flow.intent {
                    CloseIntent::ProfileMutation(mutation) => mutation.matches(&self.profiles),
                    _ => true,
                }
        })
    }
    pub(super) fn resolving_close(&self, token: CloseToken, id: DocumentId) -> bool {
        self.close_valid(token)
            && self
                .close_flow
                .as_ref()
                .is_some_and(|flow| flow.phase == ClosePhase::Resolving(id))
    }
    pub(super) fn close_resolution_client(
        &self,
        token: CloseToken,
        id: DocumentId,
    ) -> Option<BackendClient> {
        if !self.resolving_close(token, id) {
            return None;
        }
        self.tabs
            .iter()
            .find(|t| t.id == id)?
            .session_client()
            .filter(BackendClient::is_alive)
    }
    fn transition_close(&mut self, token: CloseToken, from: ClosePhase, to: ClosePhase) -> bool {
        self.close_valid(token)
            && self
                .close_flow
                .as_mut()
                .is_some_and(|flow| flow.transition(token, from, to))
    }
    fn close_drafts_valid(&self, token: CloseToken, cx: &App) -> bool {
        self.close_flow.as_ref().is_some_and(|flow| {
            flow.token == token
                && flow.drafts.iter().all(|d| {
                    d.valid(cx)
                        && self.tabs.iter().any(|t| {
                            t.id == d.document && t.grid_views.values().any(|g| *g == d.grid)
                        })
                })
        })
    }
    fn lock_close_drafts(&mut self, locked: bool, cx: &mut App) {
        let Some(flow) = &self.close_flow else {
            return;
        };
        for tab in self.tabs.iter_mut().filter(|tab| flow.contains(tab.id)) {
            if let Some(table) = tab.catalog_document.as_mut().and_then(|d| d.table.as_mut()) {
                table.locks.closing = locked;
            }
            for grid in tab.grid_views.values() {
                grid.update(cx, |table, cx| {
                    if let Some(inline) = table.delegate_mut().inline.as_mut() {
                        inline.locked = locked;
                    }
                    cx.notify();
                });
            }
        }
    }
    pub(super) fn resume_close(
        &mut self,
        token: CloseToken,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.close_valid(token) && self.close_pending_activities(token) {
            self.review_close_activities(token, window, cx);
            return;
        }
        if self.close_valid(token)
            && (window.has_active_dialog(cx) || window.has_active_prompt())
            && self
                .tabs
                .iter()
                .any(|t| t.busy() && t.phase == Some(model::OperationPhase::Reviewing))
        {
            self.wait_close_activities(token, false, window, cx);
            return;
        }
        if !self.close_valid(token) || !self.close_drafts_valid(token, cx) {
            self.refuse_close(
                token,
                "The captured close context changed. Review it again.",
                window,
                cx,
            );
            return;
        }
        self.invalidate_dead_helper();
        let flow = self.close_flow.as_ref().unwrap();
        // Submitted resolution callbacks alone may resume a resolving phase.
        if matches!(
            flow.phase,
            ClosePhase::Disconnecting | ClosePhase::Finishing
        ) {
            return;
        }
        if self.close_catalog_busy(token) {
            self.review_close_catalog(token, window, cx);
            return;
        }
        if let Some(tab) = self
            .tabs
            .iter()
            .find(|tab| flow.contains(tab.id) && tab.busy())
        {
            let id = tab.id;
            self.close_flow.as_mut().unwrap().phase = ClosePhase::Running(id);
            let view = cx.entity().downgrade();
            window.open_dialog(cx, move |dialog, _, _| {
                let cancel = view.clone(); let stop = view.clone();
                dialog.title("Query is running").accessibility_label("Query is running").overlay_closable(false).close_button(false).on_ok({ let view = view.clone(); move |_, window, cx| {
                    _ = view.update(cx, |this, cx| { this.cancel_close_review(token, ClosePhase::Running(id), window, cx); }); false
                } })
                .on_cancel({ let view = view.clone(); move |_, window, cx| {
                    _ = view.update(cx, |this, cx| { this.cancel_close_review(token, ClosePhase::Running(id), window, cx); }); false
                } })
                    .child("Stop the operation before closing its session. Completed changes remain applied. Cancel leaves it running.")
                    .footer(div().flex().gap_2().justify_end()
                        .child(Button::new("cancel-running-close").label("Cancel").on_click(move |_, window, cx| {
                            _ = cancel.update(cx, |this, cx| { this.cancel_close_review(token, ClosePhase::Running(id), window, cx); });
                        }))
                        .child(Button::new("stop-running-close").label("Stop and Continue").on_click(move |_, window, cx| {
                            _ = stop.update(cx, |this, cx| { this.choose_close_stop(token, id, window, cx); });
                        })))
            });
            cx.notify();
            return;
        }
        if let Some(tab) = self
            .tabs
            .iter()
            .find(|tab| flow.contains(tab.id) && tab.transaction != "idle" && !tab.uncertain)
        {
            let id = tab.id;
            let failed = tab.transaction == "failedTransaction";
            let session = tab
                .session
                .clone()
                .map(|session| (id, tab.session_generation, session));
            self.close_flow.as_mut().unwrap().resolution_session = session;
            self.close_flow.as_mut().unwrap().phase = ClosePhase::Transaction(id);
            let view = cx.entity().downgrade();
            window.open_dialog(cx, move |dialog, _, _| {
                let cancel = view.clone(); let rollback = view.clone(); let commit = view.clone();
                dialog.title("Open transaction").accessibility_label("Open transaction").overlay_closable(false).close_button(false).on_ok({ let view = view.clone(); move |_, window, cx| {
                    _ = view.update(cx, |this, cx| { this.cancel_close_review(token, ClosePhase::Transaction(id), window, cx); }); false
                } })
                .on_cancel({ let view = view.clone(); move |_, window, cx| {
                    _ = view.update(cx, |this, cx| { this.cancel_close_review(token, ClosePhase::Transaction(id), window, cx); }); false
                } })
                    .child(if failed { "This transaction failed. Roll it back before closing the session." } else { "Choose how to finish the transaction before closing the session. Cancel leaves it open." })
                    .footer(div().flex().gap_2().justify_end()
                        .child(Button::new("cancel-close").label("Cancel").on_click(move |_, window, cx| {
                            _ = cancel.update(cx, |this, cx| { this.cancel_close_review(token, ClosePhase::Transaction(id), window, cx); });
                        }))
                        .child(Button::new("rollback-close").label("Roll Back").on_click(move |_, window, cx| {
                            _ = rollback.update(cx, |this, cx| this.resolve_close_transaction(token, id, false, window, cx));
                        }))
                        .when(!failed, |row| row.child(Button::new("commit-close").label("Commit").on_click(move |_, window, cx| {
                            _ = commit.update(cx, |this, cx| this.resolve_close_transaction(token, id, true, window, cx));
                        }))))
            });
            cx.notify();
            return;
        }
        if !flow.acknowledged_unknown
            && self
                .tabs
                .iter()
                .any(|tab| flow.contains(tab.id) && tab.uncertain)
        {
            self.close_flow.as_mut().unwrap().phase = ClosePhase::Unknown;
            let view = cx.entity().downgrade();
            window.open_dialog(cx, move |dialog, _, _| {
                let cancel = view.clone(); let accept = view.clone();
                dialog.title("Unknown commit outcome").accessibility_label("Unknown commit outcome").overlay_closable(false).close_button(false).on_ok({ let view = view.clone(); move |_, window, cx| {
                    _ = view.update(cx, |this, cx| { this.cancel_close_review(token, ClosePhase::Unknown, window, cx); }); false
                } })
                .on_cancel({ let view = view.clone(); move |_, window, cx| {
                    _ = view.update(cx, |this, cx| { this.cancel_close_review(token, ClosePhase::Unknown, window, cx); }); false
                } })
                    .child("Check the database before retrying any operation. Disconnecting cannot determine whether the previous operation committed.")
                    .footer(div().flex().gap_2().justify_end()
                        .child(Button::new("cancel-unknown-close").label("Cancel").on_click(move |_, window, cx| {
                            _ = cancel.update(cx, |this, cx| { this.cancel_close_review(token, ClosePhase::Unknown, window, cx); });
                        }))
                        .child(Button::new("acknowledge-unknown").label("I Checked; Disconnect and Close").on_click(move |_, window, cx| {
                            _ = accept.update(cx, |this, cx| { this.acknowledge_close_unknown(token, window, cx); });
                        })))
            });
            cx.notify();
            return;
        }
        if let Some(id) = self
            .tabs
            .iter()
            .find(|t| {
                flow.contains(t.id)
                    && self.unknown_changes(t.id).is_some()
                    && !flow.unknown_discards.contains(&t.id)
            })
            .map(|t| t.id)
        {
            self.review_unknown_changes(token, id, window, cx);
            return;
        }
        if let Some(review) = self
            .close_flow
            .as_ref()
            .unwrap()
            .drafts
            .iter()
            .find(|d| !d.approved)
            .cloned()
        {
            let id = review.document;
            self.close_flow.as_mut().unwrap().phase = ClosePhase::Changes(id);
            let view = cx.entity().downgrade();
            window.open_dialog(cx, move |dialog,_,_| {
                let cancel = view.clone(); let discard = view.clone(); let apply = view.clone();
                dialog.title("Pending table changes").accessibility_label("Pending table changes").overlay_closable(false).close_button(false)
                    .on_ok({ let view = view.clone(); move |_,window,cx| { _ = view.update(cx,|this,cx| this.cancel_close_review(token,ClosePhase::Changes(id),window,cx)); false } })
                    .on_cancel({ let view = view.clone(); move |_,window,cx| { _ = view.update(cx,|this,cx| this.cancel_close_review(token,ClosePhase::Changes(id),window,cx)); false } })
                    .child("Apply the table changes or discard them before closing. Apply opens a fresh session and exact review. Cancel keeps every table draft and its editor.")
                    .footer(div().flex().gap_2().justify_end()
                        .child(Button::new("cancel-staged-close").label("Cancel").on_click(move |_,window,cx| { _ = cancel.update(cx,|this,cx| this.cancel_close_review(token,ClosePhase::Changes(id),window,cx)); }))
                        .child(Button::new("apply-staged-close").label("Apply").on_click(move |_,window,cx| { _ = apply.update(cx,|this,cx| this.choose_close_apply(token,id,window,cx)); }))
                        .child(Button::new("discard-staged-close").label("Discard and Continue").on_click(move |_,window,cx| { _ = discard.update(cx,|this,cx| this.choose_close_discard(token,id,window,cx)); })))
            });
            cx.notify();
            return;
        }
        self.perform_close(token, window, cx);
    }
    fn cancel_close_review(
        &mut self,
        token: CloseToken,
        phase: ClosePhase,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // Cancel is allowed even if the captured settings became stale. It must
        // never unlock a later phase or a newer flow via an obsolete callback.
        if self
            .close_flow
            .as_ref()
            .is_some_and(|flow| flow.token == token && flow.phase == phase)
        {
            window.close_dialog(cx);
            self.cancel_close(&token, window, cx);
        }
    }
    pub(super) fn choose_close_discard(
        &mut self,
        token: CloseToken,
        id: DocumentId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.close_valid(token) || !self.close_drafts_valid(token, cx) {
            self.refuse_close_review(token, ClosePhase::Changes(id), window, cx);
            return;
        }
        if self.transition_close(token, ClosePhase::Changes(id), ClosePhase::Reviewing) {
            if let Some(review) = self
                .close_flow
                .as_mut()
                .unwrap()
                .drafts
                .iter_mut()
                .find(|d| d.document == id && !d.approved)
            {
                review.approved = true;
            }
            window.close_dialog(cx);
            self.resume_close(token, window, cx);
        }
    }
    fn choose_close_stop(
        &mut self,
        token: CloseToken,
        id: DocumentId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.close_valid(token) {
            self.refuse_close_review(token, ClosePhase::Running(id), window, cx);
            return;
        }
        if self.transition_close(token, ClosePhase::Running(id), ClosePhase::Stopping(id)) {
            window.close_dialog(cx);
            self.stop_before_close(id, token, window, cx);
        }
    }
    fn acknowledge_close_unknown(
        &mut self,
        token: CloseToken,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.close_valid(token) {
            self.refuse_close_review(token, ClosePhase::Unknown, window, cx);
            return;
        }
        if self.transition_close(token, ClosePhase::Unknown, ClosePhase::Reviewing) {
            window.close_dialog(cx);
            self.close_flow.as_mut().unwrap().acknowledged_unknown = true;
            self.resume_close(token, window, cx);
        }
    }
    fn refuse_close_review(
        &mut self,
        token: CloseToken,
        phase: ClosePhase,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self
            .close_flow
            .as_ref()
            .is_some_and(|flow| flow.token == token && flow.phase == phase)
        {
            window.close_dialog(cx);
            self.refuse_close(
                token,
                "The captured close context changed. Review it again.",
                window,
                cx,
            );
        }
    }
    pub(super) fn cancel_close(
        &mut self,
        token: &CloseToken,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self
            .close_flow
            .as_ref()
            .is_some_and(|flow| flow.token == *token)
        {
            return;
        }
        self.lock_close_drafts(false, cx);
        let flow = self.close_flow.take().unwrap();
        self.publish_close_readiness();
        self.closing = false;
        self.closing_task = None;
        if let Some(focus) = &flow.focus {
            focus.focus(window, cx);
        }
        if let CloseIntent::ProfileMutation(mutation) = flow.intent {
            self.restore_profile_editor(&mutation, None, window, cx);
        }
        cx.notify();
    }
    fn refuse_close(
        &mut self,
        token: CloseToken,
        error: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self
            .close_flow
            .as_ref()
            .is_some_and(|flow| flow.token == token)
        {
            return;
        }
        self.lock_close_drafts(false, cx);
        let flow = self.close_flow.take().unwrap();
        self.publish_close_readiness();
        self.closing = false;
        self.closing_task = None;
        if let Some(focus) = &flow.focus {
            focus.focus(window, cx);
        }
        if let CloseIntent::ProfileMutation(mutation) = flow.intent {
            self.restore_profile_editor(&mutation, Some(error.into()), window, cx);
        } else {
            Self::information(error.to_owned(), window, cx);
        }
        cx.notify();
    }
    fn stop_before_close(
        &mut self,
        id: DocumentId,
        token: CloseToken,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(tab) = self.tabs.iter().find(|tab| tab.id == id) else {
            self.cancel_close(&token, window, cx);
            return;
        };
        let original = tab.operation.as_ref().map(|context| context.operation);
        self.stop_document(id, cx);
        self.closing_task = Some(cx.spawn_in(window, async move |view, cx| {
            loop {
                let state = view
                    .update_in(cx, |this, _, _| {
                        if !this.close_valid(token) {
                            return None;
                        }
                        this.tabs.iter().find(|tab| tab.id == id).map(|tab| {
                            (
                                tab.busy(),
                                tab.operation.as_ref().map(|context| context.operation),
                            )
                        })
                    })
                    .ok()
                    .flatten();
                let Some((busy, operation)) = state else {
                    break;
                };
                if !busy {
                    break;
                }
                if operation != original {
                    break;
                }
                cx.background_executor()
                    .timer(Duration::from_millis(30))
                    .await;
            }
            _ = view.update_in(cx, |this, window, cx| {
                if !this.close_valid(token) {
                    this.refuse_close(
                        token,
                        "The captured close context changed while stopping.",
                        window,
                        cx,
                    );
                    return;
                }
                if !this.transition_close(token, ClosePhase::Stopping(id), ClosePhase::Reviewing) {
                    return;
                }
                this.closing_task = None;
                if this.tabs.iter().any(|tab| tab.id == id && tab.busy()) {
                    this.refuse_close(
                        token,
                        "The original operation has not reached its terminal outcome.",
                        window,
                        cx,
                    );
                } else {
                    this.resume_close(token, window, cx);
                }
            });
        }));
        cx.notify();
    }
    fn resolve_close_transaction(
        &mut self,
        token: CloseToken,
        id: DocumentId,
        commit: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.close_valid(token) || !self.close_drafts_valid(token, cx) {
            self.refuse_close_review(token, ClosePhase::Transaction(id), window, cx);
            return;
        }
        let valid = self
            .tabs
            .iter()
            .find(|tab| tab.id == id)
            .is_some_and(|tab| {
                !tab.busy()
                    && !tab.uncertain
                    && self
                        .close_flow
                        .as_ref()
                        .and_then(|flow| flow.resolution_session.as_ref())
                        .is_some_and(|(document, generation, session)| {
                            *document == id
                                && *generation == tab.session_generation
                                && tab.session.as_ref() == Some(session)
                        })
                    && tab.transaction != "idle"
                    && (!commit || tab.transaction != "failedTransaction")
            });
        if !valid {
            self.refuse_close_review(token, ClosePhase::Transaction(id), window, cx);
            return;
        }
        if !self.transition_close(
            token,
            ClosePhase::Transaction(id),
            ClosePhase::Resolving(id),
        ) {
            return;
        }
        window.close_dialog(cx);
        self.run_live(
            id,
            Some(if commit { "COMMIT;" } else { "ROLLBACK;" }.into()),
            Some(token),
            window,
            cx,
        );
        if self.resolving_close(token, id)
            && !self.tabs.iter().any(|tab| tab.id == id && tab.busy())
        {
            self.refuse_close(
                token,
                "The transaction could not be resolved. Its session remains open.",
                window,
                cx,
            );
        }
    }
    fn disconnect_target_valid(&self, target: &DisconnectTarget) -> bool {
        let Some(profile) = self
            .profiles
            .iter()
            .find(|p| p.id == target.profile && p.generation == target.profile_generation)
        else {
            return false;
        };
        if let Some((id, generation)) = target.document {
            self.tabs.iter().any(|tab| {
                tab.id == id
                    && tab.profile == target.profile
                    && tab.session_generation == generation
                    && tab.session.as_deref() == Some(&target.session)
                    && tab.session_settings == target.settings
                    && !tab.busy()
                    && tab
                        .session_client()
                        .is_some_and(|c| c.same_instance(&target.client))
            })
        } else {
            profile
                .session_client
                .as_ref()
                .is_some_and(|c| c.same_instance(&target.client))
                && profile.session.as_deref() == Some(&target.session)
                && profile.session_settings == target.settings
                && profile.task.is_none()
        }
    }
    fn perform_close(&mut self, token: CloseToken, window: &mut Window, cx: &mut Context<Self>) {
        if !self.close_valid(token) || !self.close_drafts_valid(token, cx) {
            self.refuse_close(token, "The captured close context changed.", window, cx);
            return;
        }
        let flow = self.close_flow.as_ref().unwrap();
        let mut targets = Vec::new();
        for tab in self.tabs.iter().filter(|tab| flow.contains(tab.id)) {
            if let Some(session) = &tab.session {
                let profile = self.profile(&tab.profile);
                let Some(client) = tab.session_client() else {
                    self.refuse_close(token,"The original session helper cannot be identified. The document remains open.",window,cx);
                    return;
                };
                targets.push(DisconnectTarget {
                    client,
                    document: Some((tab.id, tab.session_generation)),
                    profile: tab.profile.clone(),
                    profile_generation: profile.generation,
                    session: session.clone(),
                    settings: tab.session_settings.clone(),
                });
            }
        }
        let scope = flow.intent.profile_id();
        for profile in self
            .profiles
            .iter()
            .filter(|p| matches!(flow.intent, CloseIntent::Window) || scope.as_ref() == Some(&p.id))
        {
            if let Some(session) = &profile.session {
                let Some(client) = profile.session_client.clone() else {
                    self.refuse_close(token,"The original catalog helper cannot be identified. The document remains open.",window,cx);
                    return;
                };
                targets.push(DisconnectTarget {
                    client,
                    document: None,
                    profile: profile.id.clone(),
                    profile_generation: profile.generation,
                    session: session.clone(),
                    settings: profile.session_settings.clone(),
                });
            }
        }
        self.close_flow.as_mut().unwrap().phase = ClosePhase::Disconnecting;
        if targets.is_empty() {
            self.finish_close(token, window, cx);
            return;
        }
        self.closing_task = Some(cx.spawn_in(window, async move |view, cx| {
            for target in targets {
                let valid = view.update_in(cx, |this, _, cx| this.close_valid(token) && this.close_drafts_valid(token,cx) && this.disconnect_target_valid(&target)).unwrap_or(false);
                if !valid {
                    _ = view.update_in(cx, |this, window, cx| this.refuse_close(token, "The captured session changed before disconnect.", window, cx));
                    return;
                }
                // A demonstrably dead OWNED helper cannot acknowledge. Its loss
                // is never an ACK or proof of rollback. Nonidle SQL needs the
                // explicit uncertainty decision before local retirement.
                let unavailable = !target.client.is_alive();
                if unavailable && !target.client.owned_process_exited() {
                    let deadline=std::time::Instant::now()+Duration::from_secs(5);
                    while !target.client.owned_process_exited() && std::time::Instant::now()<deadline {
                        if !view.update_in(cx,|this,_,_|this.close_valid(token)).unwrap_or(false) {return;}
                        cx.background_executor().timer(Duration::from_millis(30)).await;
                    }
                    if !target.client.owned_process_exited() {
                        _=view.update_in(cx,|this,window,cx|this.refuse_close(token,"The original helper transport failed, but its process exit is not yet confirmed. The session and local drafts remain owned; wait for teardown before retrying.",window,cx));
                        return;
                    }
                }
                let dead=target.client.owned_process_exited();
                if dead {
                    let allowed=view.update_in(cx,|this,_,_| {
                        this.close_flow.as_ref().is_some_and(|f|f.acknowledged_unknown)
                            || target.document.is_none()
                            || this.tabs.iter().find(|t|Some(t.id)==target.document.map(|d|d.0)).is_some_and(|t|!t.uncertain && t.transaction=="idle")
                    }).unwrap_or(false);
                    if !allowed {
                        _=view.update_in(cx,|this,window,cx| {
                            if let Some((id,_))=target.document && let Some(tab)=this.tabs.iter_mut().find(|t|t.id==id) {tab.uncertain=true;}
                            this.refuse_close(token,"The original helper ended. The transaction outcome is unknown; review it explicitly before closing.",window,cx);
                        });
                        return;
                    }
                }
                let result = if dead {None} else {Some(target.client.disconnect(&target.session).await)};
                let accepted = view.update_in(cx, |this, window, cx| {
                    if !this.close_valid(token) || !this.close_drafts_valid(token,cx) || !this.disconnect_target_valid(&target) {
                        this.refuse_close(token,"The captured session changed while disconnecting.",window,cx);return false;
                    }
                    match result {
                        None | Some(Ok(())) => {
                            if let Some((id,_))=target.document {this.tabs.iter_mut().find(|t|t.id==id).unwrap().retire_session();}
                            else if let Some(index)=this.profile_index(&target.profile) {
                                this.profiles[index].session=None;
                                this.profiles[index].session_settings=None;
                                this.profiles[index].session_client=None;
                            }
                            cx.notify(); true
                        }
                        Some(Err(_)) => {
                            // A live helper's refusal retains this exact session
                            // for retry. A dead helper may retire only its local
                            // ownership, leaving uncertainty and drafts intact.
                            if target.client.owned_process_exited() {
                                if let Some((id,_))=target.document && let Some(tab)=this.tabs.iter_mut().find(|t|t.id==id) {
                                    tab.uncertain |= tab.transaction!="idle";
                                    tab.retire_session();
                                } else if let Some(index)=this.profile_index(&target.profile) {
                                    this.profiles[index].session=None;
                                    this.profiles[index].session_client=None;
                                    this.profiles[index].session_settings=None;
                                }
                            }
                            this.refuse_close(token,"Disconnect was not acknowledged. The document remains open; verify the database before retrying.",window,cx);
                            false
                        }
                    }
                }).unwrap_or(false);
                if !accepted {return;}
            }
            _=view.update_in(cx,|this,window,cx|this.finish_close(token,window,cx));
        }));
        cx.notify();
    }
    fn finish_close(&mut self, token: CloseToken, window: &mut Window, cx: &mut Context<Self>) {
        if !self.close_valid(token) || !self.close_drafts_valid(token, cx) {
            self.refuse_close(
                token,
                "The captured close context changed before finalization.",
                window,
                cx,
            );
            return;
        }
        if !self.transition_close(token, ClosePhase::Disconnecting, ClosePhase::Finishing) {
            return;
        }
        self.flush_close_documents(token, window, cx);
    }
    fn snapshot_after_close(&self, cx: &App) -> restoration::Snapshot {
        let mut snapshot = self.document_snapshot(cx);
        match self.close_flow.as_ref().map(|flow| &flow.intent) {
            Some(CloseIntent::Tab(id)) => {
                let removed = self
                    .tabs
                    .iter()
                    .find(|t| t.id == *id)
                    .map(|t| &t.persistent_id);
                snapshot.documents.retain(|d| Some(&d.id) != removed);
                if snapshot.selected_document_id.as_ref() == removed {
                    // Match close_tab's stable selected-tab resolution.
                    snapshot.selected_document_id = self
                        .tabs
                        .iter()
                        .enumerate()
                        .filter(|(_, t)| t.id != *id)
                        .nth(self.active.min(snapshot.documents.len().saturating_sub(1)))
                        .map(|(_, t)| t.persistent_id.clone());
                }
            }
            Some(CloseIntent::ClearDrafts) => {
                snapshot.documents.clear();
                snapshot.selected_document_id = None;
            }
            _ => {} // Window close preserves open drafts; profile disconnect keeps sources.
        }
        snapshot
    }
    fn flush_close_documents(
        &mut self,
        token: CloseToken,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.close_valid(token)
            || !self.close_drafts_valid(token, cx)
            || !self
                .close_flow
                .as_ref()
                .is_some_and(|flow| flow.phase == ClosePhase::Finishing)
        {
            return;
        }
        if self.flush_close_participants(token, window, cx) {
            return;
        }
        if self.shutdown_close_helpers(token, window, cx) {
            return;
        }
        self.restoration.debounce = None;
        self.restoration.revision += 1;
        let snapshot = self.snapshot_after_close(cx);
        let request = self
            .restoration
            .store
            .as_ref()
            .map(|store| store.reserve(snapshot.clone()));
        self.closing_task = Some(cx.spawn_in(window, async move |view, cx| {
            // Acquiring the owner mutex waits for any already-running old writer.
            let result = cx
                .background_executor()
                .spawn(async move { request.map_or(Ok(()), |r| r.commit()) })
                .await;
            _ = view.update_in(cx, |this, window, cx| {
                if !this.close_valid(token)
                    || !this.close_drafts_valid(token, cx)
                    || !this
                        .close_flow
                        .as_ref()
                        .is_some_and(|flow| flow.phase == ClosePhase::Finishing)
                {
                    this.refuse_close(
                        token,
                        "The table draft changed before finalization. Review it again.",
                        window,
                        cx,
                    );
                    return;
                }
                if let Err(error) = result {
                    this.restoration.error = Some(error.to_string());
                    this.refuse_close(token, &error.to_string(), window, cx);
                    // A failed clear/tab close retains its original drafts for retry.
                    this.schedule_documents(cx);
                    return;
                }
                // Editing remains available while closing. Reflush changes made while
                // the worker was running; equality and removal occur in one UI turn.
                if this.snapshot_after_close(cx) != snapshot
                    || !this.close_finalizers_current(token, cx)
                {
                    this.flush_close_documents(token, window, cx);
                    return;
                }
                if this.shutdown_close_platform(TerminalEvidence { token, snapshot }, window, cx) {
                    return;
                }
                this.complete_terminal_close(token, window, cx);
            });
        }));
    }
    pub(crate) fn complete_terminal_close(
        &mut self,
        token: CloseToken,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.close_valid(token)
            || !self.close_drafts_valid(token, cx)
            || !self.close_finalizers_current(token, cx)
        {
            self.publish_close_readiness();
            self.flush_close_documents(token, window, cx);
            return;
        }
        self.restoration.error = None;
        self.lock_close_drafts(false, cx);
        let flow = self.close_flow.take().unwrap();
        self.closing = false;
        self.closing_task = None;
        if let CloseIntent::ProfileMutation(mutation) = &flow.intent {
            // Publish profile changes first: failed credential/profile writes
            // retain the exact reviewed table drafts as well as SQL sources.
            self.commit_profile_mutation_with_drafts(mutation.clone(), flow.drafts, window, cx);
        } else {
            self.discard_reviewed_drafts(&flow.drafts, window, cx);
            self.complete_close(flow.intent, window, cx);
        }
    }
    pub(super) fn complete_close(
        &mut self,
        intent: CloseIntent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match &intent {
            CloseIntent::ProfileMutation(mutation) => {
                let id = mutation.profile_id();
                if let Some(index) = self.profile_index(&id) {
                    self.profiles[index].loaded = false;
                    self.profiles[index].session_settings = None;
                    self.profiles[index].schemas.clear();
                    self.profiles[index].status = "Disconnected".into();
                    for tab in &mut self.tabs {
                        if tab.profile == id {
                            tab.retire_session();
                            tab.query_id = None;
                            tab.transaction = "idle".into();
                            tab.uncertain = false;
                            tab.status = "Disconnected".into();
                        }
                    }
                }
                self.commit_profile_mutation(mutation.clone(), window, cx);
                return;
            }
            CloseIntent::Tab(id) => {
                if let Some(index) = self.tabs.iter().position(|t| t.id == *id) {
                    self.close_tab(index, window, cx);
                }
            }
            CloseIntent::ClearDrafts => {
                let active = self.tabs.get(self.active).map(|t| t.id);
                self.tabs.retain(|t| t.kind != model::DocumentKind::Sql);
                self.active = self
                    .tabs
                    .iter()
                    .position(|t| Some(t.id) == active)
                    .unwrap_or(0);
                if self.tabs.is_empty() {
                    self.add_default_tab(DemoTable::Products, window, cx);
                }
                self.schedule_documents(cx);
            }
            CloseIntent::Window => {
                termination::permit_exit();
                debug_assert_eq!(
                    termination::exit_outcome(),
                    termination::ExitOutcome::Reviewed
                );
                window.remove_window();
            }
            CloseIntent::Profile(index) => {
                let Some(index) = self.profile_index(index) else {
                    return;
                };
                let profile = &mut self.profiles[index];
                profile.loaded = false;
                profile.session_settings = None;
                profile.schemas.clear();
                profile.status = "Disconnected".into();
                for tab in &mut self.tabs {
                    if tab.profile == profile.id {
                        tab.retire_session();
                        tab.query_id = None;
                        tab.transaction = "idle".into();
                        tab.uncertain = false;
                        tab.status = "Disconnected".into();
                    }
                }
            }
        }
        self.refresh_connection_flags();
        cx.notify();
    }
    pub fn can_close_window(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        self.request_close(CloseIntent::Window, window, cx);
        false
    }
}

/// Used by normal startup and the headless production-view harness.
pub(super) fn install_window_guard(view: &Entity<Workspace>, window: &mut Window, cx: &App) {
    let weak = view.downgrade();
    window.on_window_should_close(cx, move |window, cx| {
        weak.update(cx, |this, cx| this.can_close_window(window, cx))
            .unwrap_or(false)
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    fn flow() -> CloseFlow {
        CloseFlow {
            token: CloseToken(7),
            intent: CloseIntent::Window,
            documents: vec![(DocumentId(1), ProfileId::demo("close"))],
            profiles: vec![],
            phase: ClosePhase::Running(DocumentId(1)),
            acknowledged_unknown: false,
            resolution_session: None,
            helpers_finished: false,
            helpers: Vec::new(),
            focus: None,
            drafts: Vec::new(),
            activities: Vec::new(),
            unknown_discards: Vec::new(),
            finalized: Vec::new(),
        }
    }
    #[core::prelude::v1::test]
    fn each_chosen_resolution_advances_once_and_an_old_flow_cannot_replace_it() {
        for (from, to) in [
            (ClosePhase::Changes(DocumentId(1)), ClosePhase::Reviewing),
            (
                ClosePhase::Running(DocumentId(1)),
                ClosePhase::Stopping(DocumentId(1)),
            ),
            (
                ClosePhase::Transaction(DocumentId(1)),
                ClosePhase::Resolving(DocumentId(1)),
            ),
            (ClosePhase::Unknown, ClosePhase::Reviewing),
            (ClosePhase::Disconnecting, ClosePhase::Finishing),
        ] {
            let mut flow = flow();
            flow.phase = from.clone();
            assert!(!flow.transition(CloseToken(6), from.clone(), to.clone()));
            assert!(flow.transition(CloseToken(7), from.clone(), to.clone()));
            assert!(!flow.transition(CloseToken(7), from, to.clone()));
            assert_eq!(flow.phase, to);
        }
    }
    #[core::prelude::v1::test]
    fn repeated_request_cannot_turn_selected_commit_or_disconnect_into_stop() {
        let mut flow = flow();
        for phase in [
            ClosePhase::Stopping(DocumentId(1)),
            ClosePhase::Resolving(DocumentId(1)),
            ClosePhase::Disconnecting,
            ClosePhase::Finishing,
        ] {
            flow.phase = phase.clone();
            assert!(!flow.transition(
                CloseToken(7),
                ClosePhase::Running(DocumentId(1)),
                ClosePhase::Stopping(DocumentId(1))
            ));
            assert_eq!(flow.phase, phase);
        }
        assert!(flow.contains(DocumentId(1)));
        assert!(!flow.contains(DocumentId(2)));
    }
}
