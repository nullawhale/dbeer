//! Original-client ownership for standalone Preview and fresh-session Apply.
use super::*;
use crate::{
    changes_view::{Capture, ChangesBatch},
    preview::{Cancellation, FreshSession, Plan, Preparation, Purpose},
};
use std::{
    future::Future,
    sync::{Arc, Mutex},
};

type Result<T> = std::result::Result<T, backend::BackendError>;
#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Preparing,
    Cleaning,
    CleanupFailed,
    Reviewing,
    Applying,
}
enum Completion {
    Preview(Result<Arc<Preparation>>),
    Apply(Result<backend::QueryOutcome>),
}
struct ChangesWork {
    purpose: Purpose,
    plan: Arc<Plan>,
    client: BackendClient,
    profile: ConnectionProfile,
    cancel: Cancellation,
    owned: Arc<Mutex<Option<FreshSession>>>,
}
pub(super) struct Flow {
    pub(super) token: u64,
    close: Option<close::CloseToken>,
    purpose: Purpose,
    completion: Option<Completion>,
    review: Option<async_channel::Sender<bool>>,
    window: Option<AnyWindowHandle>,
    batch: Arc<ChangesBatch>,
    cancel: Cancellation,
    session: Option<FreshSession>,
    query: Option<String>,
    phase: Phase,
    pub(super) status: String,
    task: Option<Task<()>>,
}
impl Flow {
    pub(super) fn document(&self) -> DocumentId {
        self.batch.capture.owner.document
    }
    pub(super) fn applying(&self) -> bool {
        self.purpose == Purpose::Apply
    }
    pub(super) fn cancelling(&self) -> bool {
        self.cancel.cancelled() && self.phase != Phase::CleanupFailed
    }
}
fn stale() -> backend::BackendError {
    backend::BackendError::transport(
        "Changes work was cancelled or its original table, draft, profile or policy changed. Local changes were preserved.",
    )
}
impl Workspace {
    pub(super) fn preview_blocks(&self, document: DocumentId) -> bool {
        self.changes_preview
            .as_ref()
            .is_some_and(|f| f.document() == document)
    }
    pub(super) fn changes_preview_token(&self, document: DocumentId) -> Option<u64> {
        self.changes_preview
            .as_ref()
            .filter(|f| f.document() == document)
            .map(|f| f.token)
    }
    /// Task 19 reuses this before/after credentials, connect, preview, assessment,
    /// user review and immediately before submission. No current-selection read.
    pub(super) fn changes_batch_valid(&self, batch: &ChangesBatch, cx: &App) -> bool {
        self.changes_valid(&batch.capture, true, cx)
            && (if self
                .changes_preview
                .as_ref()
                .is_some_and(|f| f.close.is_some() && f.batch.capture.grid == batch.capture.grid)
            {
                self.close_changes_batch(&batch.capture, cx)
            } else {
                self.changes_batch(&batch.capture, cx)
            })
            .is_some_and(|b| b.request == batch.request)
    }
    fn preview_valid(&self, token: u64, cx: &App) -> bool {
        (!self.closing
            || self.changes_preview.as_ref().is_some_and(|f| {
                f.close
                    .is_some_and(|close| self.close_apply_valid(close, f.document()))
                    || self.close_owns_activity(close::Activity::Changes(token))
            }))
            && (self.file_request.is_none() && self.export_request.is_none())
            && self.changes_preview.as_ref().is_some_and(|f| {
                f.token == token && !f.cancel.cancelled() && self.changes_batch_valid(&f.batch, cx)
            })
    }
    fn preview_lock(&mut self, id: DocumentId, locked: bool) {
        if let Some(table) = self
            .tabs
            .iter_mut()
            .find(|t| t.id == id)
            .and_then(|t| t.catalog_document.as_mut())
            .and_then(|d| d.table.as_mut())
        {
            table.locks.previewing = locked;
        }
    }
    #[cfg(all(test, feature = "native-smoke"))]
    fn reserve_changes_preview(
        &mut self,
        batch: Arc<ChangesBatch>,
        cx: &mut Context<Self>,
    ) -> (u64, Cancellation) {
        self.reserve_changes_flow(batch, Purpose::Standalone, cx)
    }
    fn reserve_changes_flow(
        &mut self,
        batch: Arc<ChangesBatch>,
        purpose: Purpose,
        cx: &mut Context<Self>,
    ) -> (u64, Cancellation) {
        let cancel = Cancellation::default();
        self.next_changes_preview += 1;
        let token = self.next_changes_preview;
        self.preview_lock(batch.capture.owner.document, true);
        batch.capture.grid.update(cx, |table, cx| {
            table.delegate_mut().edit_error = None;
            cx.notify();
        });
        self.changes_preview = Some(Flow {
            token,
            close: None,
            purpose,
            completion: None,
            review: None,
            window: None,
            batch,
            cancel: cancel.clone(),
            session: None,
            query: None,
            phase: Phase::Preparing,
            status: "Reading credentials for a fresh changes session...".into(),
            task: None,
        });
        (token, cancel)
    }
    pub(super) fn start_changes_preview(
        &mut self,
        capture: Capture,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.start_changes_flow(capture, Purpose::Standalone, None, window, cx);
    }
    pub(super) fn start_changes_apply(
        &mut self,
        capture: Capture,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.start_changes_flow(capture, Purpose::Apply, None, window, cx);
    }
    fn start_changes_flow(
        &mut self,
        capture: Capture,
        purpose: Purpose,
        close: Option<close::CloseToken>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if (self.closing
            && !close.is_some_and(|token| self.close_apply_valid(token, capture.owner.document)))
            || self.changes_preview.is_some()
            || (self.file_request.is_some()
                || (self.export_request.is_some() || self.run_file.is_some()))
            || window.has_active_dialog(cx)
            || window.has_active_prompt()
            || self.changes_recovery_locked(capture.owner.document)
        {
            return;
        }
        let Some(batch) = (if close.is_some() {
            self.close_changes_batch(&capture, cx)
        } else {
            self.changes_batch(&capture, cx)
        })
        .map(Arc::new) else {
            return;
        };
        let Ok(plan) = Plan::new(batch.request.clone()) else {
            return;
        };
        let client = capture.owner.target.changes_client().clone();
        let settings = capture.owner.target.changes_settings().clone();
        let (token, cancel) = self.reserve_changes_flow(batch, purpose, cx);
        self.changes_preview.as_mut().unwrap().window = Some(window.window_handle());
        self.changes_preview.as_mut().unwrap().close = close;
        if purpose == Purpose::Apply {
            self.apply_lock(capture.owner.document, true);
        }
        let task = cx.spawn_in(window, async move |view, cx| {
            let owned = Arc::new(Mutex::new(None));
            let work = ChangesWork {
                purpose,
                plan,
                client,
                profile: settings,
                cancel,
                owned: owned.clone(),
            };
            let prepared = prepare_changes(view.clone(), cx, token, work).await;
            let completion = if purpose == Purpose::Apply {
                Completion::Apply(match prepared {
                    Ok(prepared) => review_and_apply(view.clone(), cx, token, prepared).await,
                    Err(error) => Err(preview::before_submission(error)),
                })
            } else {
                Completion::Preview(prepared)
            };
            _ = view
                .update_in(cx, |this, _, cx| {
                    let f = this.changes_preview.as_mut().filter(|f| f.token == token)?;
                    f.completion = Some(completion);
                    f.phase = Phase::Cleaning;
                    f.query = None;
                    f.review = None;
                    f.status =
                        "Revoking authorization and closing the original changes session...".into();
                    cx.notify();
                    Some(())
                })
                .ok();
            let session = owned.lock().unwrap_or_else(|p| p.into_inner()).clone();
            let cleanup = if let Some(session) = &session {
                wait_cleanup(view.clone(), cx, token, session.cleanup()).await
            } else {
                Ok(())
            };
            _ = view.update_in(cx, |this, window, cx| {
                if !this
                    .changes_preview
                    .as_ref()
                    .is_some_and(|f| f.token == token)
                {
                    return;
                }
                if cleanup.is_err()
                    && session
                        .as_ref()
                        .is_some_and(|s| !s.client().owned_process_exited())
                {
                    this.retain_changes_cleanup_failure(token, window, cx);
                    return;
                }
                this.complete_changes_flow(token, window, cx);
            });
        });
        self.changes_preview.as_mut().unwrap().task = Some(task);
        cx.notify();
    }
    pub(super) fn start_close_changes_apply(
        &mut self,
        capture: Capture,
        token: close::CloseToken,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.start_changes_flow(capture, Purpose::Apply, Some(token), window, cx);
    }
    pub(super) fn close_changes_cleanup_failed(&self) -> bool {
        self.changes_preview
            .as_ref()
            .is_some_and(|f| f.phase == Phase::CleanupFailed)
    }
    pub(super) fn stop_changes_for_close(
        &mut self,
        token: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.changes_preview.as_ref().is_some_and(|f| {
            f.token == token && f.phase == Phase::Reviewing && f.purpose == Purpose::Standalone
        }) {
            window.close_dialog(cx);
            self.finish_preview_review(token, window, cx);
        } else if let Some(id) = self
            .changes_preview
            .as_ref()
            .filter(|f| f.token == token)
            .map(Flow::document)
        {
            self.stop_changes_preview(id, cx);
        }
    }
    fn retain_changes_cleanup_failure(
        &mut self,
        token: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(f) = self.changes_preview.as_mut().filter(|f| f.token == token) else {
            return;
        };
        f.cancel.cancel();
        f.phase = Phase::CleanupFailed;
        f.status="Changes-session teardown was not acknowledged. Cancel retries cleanup on the original helper. Disconnect does not establish the Apply outcome.".into();
        let close = f.close.take();
        if let Some(close) = close {
            self.cancel_close(&close, window, cx);
        }
        cx.notify();
    }
    fn complete_changes_flow(&mut self, token: u64, window: &mut Window, cx: &mut Context<Self>) {
        let Some(f) = self.changes_preview.as_mut().filter(|f| f.token == token) else {
            return;
        };
        let completion = f.completion.take();
        match completion {
            Some(Completion::Preview(Ok(prepared))) if self.preview_valid(token, cx) => self.show_changes_preview(token, prepared, window, cx),
            Some(Completion::Apply(result)) => self.complete_changes_apply(token, result, window, cx),
            _ => self.release_changes_preview(token, Some("Preview cancelled or unavailable. Local changes were preserved; Preview SQL can be retried."), cx),
        }
    }
    pub(super) fn stop_changes_preview(
        &mut self,
        document: DocumentId,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(f) = self
            .changes_preview
            .as_mut()
            .filter(|f| f.document() == document)
        else {
            return false;
        };
        f.cancel.cancel();
        if let Some(session) = &f.session {
            session.invalidate();
        }
        if let Some(review) = &f.review {
            _ = review.try_send(false);
        }
        f.status = "Stopping changes work and awaiting its authoritative terminal and original-session cleanup...".into();
        let token = f.token;
        if f.phase == Phase::CleanupFailed {
            let session = f.session.clone().unwrap();
            f.phase = Phase::Cleaning;
            let handle = f.window;
            f.task = Some(cx.spawn(async move |view, cx| {
                let result = session.cleanup().await;
                if result.is_ok() || session.client().owned_process_exited() {
                    if let Some(handle) = handle {
                        _ = handle.update(cx, |_, window, cx| {
                            _ = view.update(cx, |this, cx| this.complete_changes_flow(token, window, cx));
                        });
                    }
                } else {
                    _ = view.update(cx, |this, cx| {
                        if let Some(f) = this.changes_preview.as_mut().filter(|f| f.token == token) {
                            f.phase = Phase::CleanupFailed;
                            f.status = "Changes-session teardown failed. Cancel retries the original session; closing remains blocked.".into();
                            cx.notify();
                        }
                    });
                }
            }));
        } else if let (Some(session), Some(query)) = (f.session.clone(), f.query.clone()) {
            // Explicit ownership; never look up workspace.backend after awaiting.
            cx.spawn(async move |_, _| {
                _ = smol::future::race(session.client().cancel(session.id(), &query), async {
                    smol::Timer::after(Duration::from_secs(5)).await;
                    Err(stale())
                })
                .await;
            })
            .detach();
        }
        cx.notify();
        true
    }
    fn release_changes_preview(&mut self, token: u64, error: Option<&str>, cx: &mut Context<Self>) {
        let Some(f) = self.changes_preview.as_ref().filter(|f| f.token == token) else {
            return;
        };
        let document = f.document();
        let grid = f.batch.capture.grid.clone();
        grid.update(cx, |table, cx| {
            table.delegate_mut().edit_error = error.map(str::to_owned);
            cx.notify();
        });
        self.changes_preview = None;
        self.preview_lock(document, false);
        self.apply_lock(document, false);
        cx.notify();
    }
    pub(super) fn unknown_changes(&self, id: DocumentId) -> Option<bool> {
        let table = self
            .tabs
            .iter()
            .find(|t| t.id == id)?
            .catalog_document
            .as_ref()?
            .table
            .as_ref()?;
        let tables::ChangesRecovery::Unknown { inspected, .. } = table.recovery else {
            return None;
        };
        Some(
            inspected
                && table.inspection_proof.as_ref().is_some_and(|proof| {
                    self.catalog_target_valid(&proof.target)
                        && self
                            .tabs
                            .iter()
                            .find(|t| t.id == proof.document)
                            .and_then(|t| t.catalog_document.as_ref())
                            .is_some_and(|doc| {
                                !doc.loading
                                    && doc.target.node == proof.target.node
                                    && doc.table.as_ref().is_some_and(|t| {
                                        t.snapshot == proof.snapshot
                                            && t.pending.is_none()
                                            && !t.locks.locked()
                                    })
                            })
                }),
        )
    }
    pub(super) fn changes_recovery_locked(&self, id: DocumentId) -> bool {
        let Some(owner) = self.tabs.iter().find(|t| t.id == id) else {
            return true;
        };
        let Some(doc) = &owner.catalog_document else {
            return true;
        };
        self.tabs
            .iter()
            .filter(|t| t.profile == owner.profile)
            .filter_map(|t| t.catalog_document.as_ref())
            .any(|d| {
                d.target.node == doc.target.node
                    && d.table
                        .as_ref()
                        .is_some_and(|t| t.recovery != tables::ChangesRecovery::Ready)
            })
    }
    fn apply_lock(&mut self, id: DocumentId, value: bool) {
        if let Some(t) = self
            .tabs
            .iter_mut()
            .find(|t| t.id == id)
            .and_then(|t| t.catalog_document.as_mut())
            .and_then(|d| d.table.as_mut())
        {
            t.locks.applying = value;
        }
    }
    fn show_apply_review(
        &mut self,
        token: u64,
        prepared: Arc<Preparation>,
        sender: async_channel::Sender<bool>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<()> {
        if !self.preview_valid(token, cx)
            || !prepared.session().valid()
            || window.has_active_dialog(cx)
            || window.has_active_prompt()
        {
            return Err(stale());
        }
        let f = self.changes_preview.as_mut().unwrap();
        f.phase = Phase::Reviewing;
        f.query = None;
        f.review = Some(sender.clone());
        f.status = "Review the exact Apply batch. Return and Escape cancel.".into();
        let profile = f.batch.capture.owner.target.changes_settings();
        let label = format!(
            "{} / {} / {}:{} / {} / {} / {} / readonly={}. {} Return and Escape cancel. Only Apply Reviewed Changes submits this batch.",
            profile.name,
            profile.engine,
            profile.host,
            profile.port,
            profile.database,
            profile.user,
            profile.environment,
            profile.readonly,
            if prepared.requires_confirmation() {
                "The helper requires confirmation."
            } else {
                "The helper allows this batch."
            }
        );
        let editor = cx.new(|cx| controls::plain_editor_state(prepared.display(), window, cx));
        let view = cx.entity().downgrade();
        let guard = controls::review_guard(view.clone(), move |w, cx| w.preview_valid(token, cx));
        window.open_dialog(cx, move |dialog, _, cx| {
            let enter = view.clone();
            let escape = view.clone();
            let keys = view.clone();
            let cancel = view.clone();
            let apply = view.clone();
            dialog
                .title("Review atomic table changes")
                .accessibility_label("Review atomic table changes")
                .w(px(820.))
                .overlay_closable(false)
                .close_button(false)
                .on_ok(move |_, window, cx| {
                    _ = enter.update(cx, |this, cx| {
                        this.finish_apply_review(token, false, window, cx)
                    });
                    true
                })
                .on_cancel(move |_, window, cx| {
                    _ = escape.update(cx, |this, cx| {
                        this.finish_apply_review(token, false, window, cx)
                    });
                    true
                })
                .child(label.clone())
                .child(
                    div()
                        .capture_key_down(move |event, window, cx| {
                            if matches!(event.keystroke.key.as_str(), "enter" | "escape") {
                                cx.stop_propagation();
                                _ = keys.update(cx, |this, cx| {
                                    this.finish_apply_review(token, false, window, cx)
                                });
                            }
                        })
                        .child(
                            controls::preview_editor(&editor, cx)
                                .accessibility_guard(guard.clone())
                                .accessibility_id("dbeer-table-changes-review")
                                .aria_label(
                                    "Exact Apply SQL, typed parameters and frozen original rows",
                                )
                                .readonly(true)
                                .h(px(400.)),
                        ),
                )
                .footer(
                    div()
                        .flex()
                        .gap_2()
                        .child(
                            Button::new("cancel-changes-apply")
                                .label("Cancel")
                                .on_click(move |_, window, cx| {
                                    _ = cancel.update(cx, |this, cx| {
                                        this.finish_apply_review(token, false, window, cx)
                                    });
                                }),
                        )
                        .child(
                            Button::new("approve-changes-apply")
                                .label("Apply Reviewed Changes")
                                .on_click(move |_, window, cx| {
                                    _ = apply.update(cx, |this, cx| {
                                        this.finish_apply_review(token, true, window, cx)
                                    });
                                }),
                        ),
                )
        });
        cx.notify();
        Ok(())
    }
    fn finish_apply_review(
        &mut self,
        token: u64,
        approved: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let valid = self.preview_valid(token, cx);
        let Some(f) = self
            .changes_preview
            .as_mut()
            .filter(|f| f.token == token && f.phase == Phase::Reviewing)
        else {
            return;
        };
        f.phase = Phase::Preparing;
        if let Some(sender) = f.review.take() {
            _ = sender.try_send(approved && valid);
        }
        window.close_dialog(cx);
        cx.notify();
    }
    fn complete_changes_apply(
        &mut self,
        token: u64,
        result: Result<backend::QueryOutcome>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(f) = self.changes_preview.as_ref().filter(|f| f.token == token) else {
            return;
        };
        let batch = f.batch.clone();
        let closing = f.close;
        let id = f.document();
        let context_valid = self.changes_batch_valid(&batch, cx);
        let unknown = result.as_ref().is_err_and(|e| e.outcome_unknown);
        if (result.is_ok() || unknown)
            && let Some(tab) = self.tabs.iter_mut().find(|t| t.id == id)
        {
            let t = tab
                .catalog_document
                .as_mut()
                .unwrap()
                .table
                .as_mut()
                .unwrap();
            t.recovery = if unknown {
                tables::ChangesRecovery::Unknown {
                    inspection: None,
                    inspected: false,
                }
            } else {
                tables::ChangesRecovery::ReloadRequired
            };
            t.locks.outcome_unknown = unknown;
            t.inspection_proof = None;
            tab.error = unknown;
        }
        let error = if unknown {
            Some(
                "The COMMIT outcome is unknown. Inspect Data in a new tab, then explicitly Discard and Reload. Another Apply is blocked; disconnect is not proof of rollback.",
            )
        } else if result.is_err() {
            Some(
                "Apply failed or was cancelled before commit. Local changes were preserved. Review the data and error before an explicit new attempt.",
            )
        } else {
            Some(
                "Changes committed. A successful reload is required before further editing or Apply; do not reapply this batch.",
            )
        };
        self.release_changes_preview(token, error, cx);
        if result.is_ok() {
            // A successful commit remains authoritative after Stop or context
            // mutation. Never leave a retryable committed draft behind.
            self.clear_changes_after_commit(&batch.capture, window, cx);
            if context_valid && closing.is_none() {
                self.reload_changes_snapshot(
                    id,
                    Some(batch.capture.owner.target.clone()),
                    window,
                    cx,
                );
            }
        } else if let Err(error) = &result {
            // Sanitized helper diagnostics only; no SQL/results/credentials logged.
            if !unknown {
                batch.capture.grid.update(cx, |t, cx| {
                    t.delegate_mut().edit_error =
                        Some(format!("{} Local changes were preserved.", error.message));
                    cx.notify();
                });
            }
        }
        if let Some(token) = closing {
            self.close_apply_finished(token, id, result.is_ok(), window, cx);
        }
        cx.notify();
    }
    fn clear_changes_after_commit(
        &mut self,
        capture: &Capture,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.tabs.iter().any(|t| {
            t.id == capture.owner.document
                && t.grid_views.get(&capture.owner.result) == Some(&capture.grid)
        }) {
            return;
        }
        capture.grid.update(cx, |t, cx| {
            let g = t.delegate_mut();
            // Local editing is locked throughout Apply. If a future caller can
            // mutate it, preserve a changed revision for explicit Discard instead.
            if g.draft_revision() == capture.revision {
                if let Some(d) = &mut g.draft {
                    d.discard();
                }
                g.inline = None;
                g.selection = crate::grid_selection::Selection::default();
                g.project_draft();
                g.sync_details(window, cx);
                t.refresh(cx);
            }
            cx.notify();
        });
        self.sync_changes_locks(capture.owner.document, cx);
    }
    /// Success retries only the read-only snapshot, using the original captured
    /// service automatically or a newly explicit connected context on user Retry.
    pub(super) fn reload_changes_snapshot(
        &mut self,
        id: DocumentId,
        original: Option<catalog::CatalogTarget>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing
            || self.changes_preview.is_some()
            || (self.file_request.is_some()
                || (self.export_request.is_some() || self.run_file.is_some()))
            || window.has_active_dialog(cx)
            || window.has_active_prompt()
        {
            return;
        }
        let Some(tab) = self.tabs.iter().find(|t| t.id == id) else {
            return;
        };
        let Some(doc) = &tab.catalog_document else {
            return;
        };
        let Some(table) = &doc.table else {
            return;
        };
        if table.recovery != tables::ChangesRecovery::ReloadRequired || table.pending.is_some() {
            return;
        }
        let target = original.or_else(|| {
            self.profile_index(&tab.profile)
                .and_then(|p| self.catalog_target(p, doc.target.node.clone()))
        });
        let Some(target) = target.filter(|t| {
            self.catalog_target_valid(t)
                && self
                    .catalog_action_available(CommandId::CatalogOpenData, t)
                    .is_ok()
        }) else {
            return;
        };
        let doc = self
            .tabs
            .iter_mut()
            .find(|t| t.id == id)
            .unwrap()
            .catalog_document
            .as_mut()
            .unwrap();
        let table = doc.table.as_mut().unwrap();
        let Some(request) = table.begin(table.navigation.clone()) else {
            return;
        };
        doc.loading = true;
        self.start_table_work(target, id, request, window, cx);
    }
    pub(super) fn inspect_unknown_changes(
        &mut self,
        id: DocumentId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing
            || self.changes_preview.is_some()
            || (self.file_request.is_some()
                || (self.export_request.is_some() || self.run_file.is_some()))
            || window.has_active_dialog(cx)
            || window.has_active_prompt()
        {
            return;
        }
        let Some(tab) = self.tabs.iter().find(|t| t.id == id) else {
            return;
        };
        let Some(doc) = &tab.catalog_document else {
            return;
        };
        if !doc
            .table
            .as_ref()
            .is_some_and(|t| matches!(t.recovery, tables::ChangesRecovery::Unknown { .. }))
        {
            return;
        }
        let Some(target) = self
            .profile_index(&tab.profile)
            .and_then(|p| self.catalog_target(p, doc.target.node.clone()))
        else {
            return;
        };
        if self
            .catalog_action_available(CommandId::CatalogOpenData, &target)
            .is_err()
        {
            return;
        }
        let Some(inspection) = self.new_catalog_document(target.clone(), true, window, cx) else {
            return;
        };
        let owner = self
            .tabs
            .iter_mut()
            .find(|t| t.id == id)
            .unwrap()
            .catalog_document
            .as_mut()
            .unwrap()
            .table
            .as_mut()
            .unwrap();
        owner.recovery = tables::ChangesRecovery::Unknown {
            inspection: Some(inspection),
            inspected: false,
        };
        owner.inspection_proof = None;
        let doc = self
            .tabs
            .iter_mut()
            .find(|t| t.id == inspection)
            .unwrap()
            .catalog_document
            .as_mut()
            .unwrap();
        let request = doc
            .table
            .as_mut()
            .unwrap()
            .begin(tables::Navigation::default())
            .unwrap();
        self.start_table_work(target, inspection, request, window, cx);
        cx.notify();
    }
    pub(super) fn complete_changes_inspection(&mut self, inspection: DocumentId) {
        // This is called only after columns/browse/columns validation and atomic
        // publication. A newly opened/empty, failed, pending or stale tab cannot
        // authorize recovery. Keep exact current helper/service/policy/generation
        // plus the loaded snapshot until the user's explicit Discard and Reload.
        let Some(tab) = self.tabs.iter().find(|t| t.id == inspection) else {
            return;
        };
        let Some(doc) = &tab.catalog_document else {
            return;
        };
        let Some(table) = &doc.table else {
            return;
        };
        if doc.loading
            || table.pending.is_some()
            || table.snapshot == 0
            || tab.result_sets.is_empty()
            || !self.catalog_target_valid(&doc.target)
        {
            return;
        }
        let target = doc.target.clone();
        let snapshot = table.snapshot;
        for tab in &mut self.tabs {
            let Some(doc) = &mut tab.catalog_document else {
                continue;
            };
            if doc.target.profile != target.profile
                || doc.target.node != target.node
                || doc.target.changes_settings() != target.changes_settings()
            {
                continue;
            }
            if let Some(table) = &mut doc.table
                && let tables::ChangesRecovery::Unknown {
                    inspection: Some(owner),
                    inspected,
                } = &mut table.recovery
                && *owner == inspection
            {
                *inspected = true;
                table.inspection_proof = Some(tables::ChangesInspection {
                    document: inspection,
                    target: target.clone(),
                    snapshot,
                });
            }
        }
    }
    pub(super) fn discard_unknown_changes(
        &mut self,
        id: DocumentId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing
            || self.changes_preview.is_some()
            || (self.file_request.is_some()
                || (self.export_request.is_some() || self.run_file.is_some()))
            || window.has_active_dialog(cx)
            || window.has_active_prompt()
        {
            return;
        }
        if self.unknown_changes(id) != Some(true) {
            return;
        }
        let Some(tab) = self.tabs.iter_mut().find(|t| t.id == id) else {
            return;
        };
        let Some(table) = tab.catalog_document.as_mut().and_then(|d| d.table.as_mut()) else {
            return;
        };
        table.recovery = tables::ChangesRecovery::ReloadRequired;
        table.locks.outcome_unknown = false;
        table.inspection_proof = None;
        let grids: Vec<_> = tab.grid_views.values().cloned().collect();
        for grid in grids {
            grid.update(cx, |t, cx| {
                let g = t.delegate_mut();
                g.inline = None;
                if let Some(d) = &mut g.draft { d.discard(); }
                g.selection = crate::grid_selection::Selection::default();
                g.edit_error = Some("Local changes discarded after inspection. Reload must succeed before editing or Apply.".into());
                g.project_draft(); g.sync_details(window, cx); t.refresh(cx); cx.notify();
            });
        }
        self.sync_changes_locks(id, cx);
        self.reload_changes_snapshot(id, None, window, cx);
        cx.notify();
    }
    fn show_changes_preview(
        &mut self,
        token: u64,
        prepared: Arc<Preparation>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if window.has_active_dialog(cx)
            || window.has_active_prompt()
            || !self.preview_valid(token, cx)
        {
            self.release_changes_preview(
                token,
                Some("Preview context changed. Preview SQL again to inspect the current batch."),
                cx,
            );
            return;
        }
        let f = self.changes_preview.as_mut().unwrap();
        f.phase = Phase::Reviewing;
        f.session = None; // Already revoked and torn down. Its grant cannot authorize Apply.
        f.status = "Reviewing the closed standalone preview.".into();
        let profile = f.batch.capture.owner.target.changes_settings();
        let label = format!(
            "{} / {} / {}:{} / {} / {} / {} / readonly={}. This standalone session is closed. Apply requires a new session, preview and assessment. Return and Escape close.",
            profile.name,
            profile.engine,
            profile.host,
            profile.port,
            profile.database,
            profile.user,
            profile.environment,
            profile.readonly
        );
        let editor = cx.new(|cx| controls::plain_editor_state(prepared.display(), window, cx));
        let view = cx.entity().downgrade();
        let guard = controls::review_guard(view.clone(), move |w, cx| w.preview_valid(token, cx));
        window.open_dialog(cx, move |dialog, _, cx| {
            let accept = view.clone();
            let cancel = view.clone();
            let button = view.clone();
            let input = view.clone();
            dialog.title("Generated SQL and bound values").accessibility_label("Generated SQL and bound values").w(px(820.)).overlay_closable(false).close_button(false)
                .on_ok(move |_, window, cx| { _ = accept.update(cx, |this, cx| this.finish_preview_review(token, window, cx)); true })
                .on_cancel(move |_, window, cx| { _ = cancel.update(cx, |this, cx| this.finish_preview_review(token, window, cx)); true })
                .child(label.clone())
                .child(div().capture_key_down(move |event, window, cx| {
                    if matches!(event.keystroke.key.as_str(), "enter" | "escape") {
                        cx.stop_propagation();
                        window.close_dialog(cx);
                        _ = input.update(cx, |this, cx| this.finish_preview_review(token, window, cx));
                    }
                }).child(controls::preview_editor(&editor, cx).accessibility_guard(guard.clone()).accessibility_id("dbeer-table-changes-review").aria_label("Exact generated SQL, typed bound values and frozen original changes").readonly(true).h(px(400.))))
                .footer(Button::new("close-changes-preview").label("Close Preview").on_click(move |_, window, cx| {
                    window.close_dialog(cx);
                    _ = button.update(cx, |this, cx| this.finish_preview_review(token, window, cx));
                }))
        });
        cx.notify();
    }
    fn finish_preview_review(&mut self, token: u64, _window: &mut Window, cx: &mut Context<Self>) {
        let valid = self.preview_valid(token, cx);
        self.release_changes_preview(
            token,
            (!valid).then_some("The preview context changed. Preview SQL again before review."),
            cx,
        );
    }
}
/// A deadline requests cancellation but NEVER drops a connect future or loses an
/// eventual session ID. Original work drains, then the original session closes.
/// A nonresponsive helper keeps the lock/close refusal until reply or helper death.
async fn wait_stage<T>(
    view: WeakEntity<Workspace>,
    cx: &mut AsyncWindowContext,
    token: u64,
    future: impl Future<Output = T>,
) -> T {
    let mut future = Box::pin(future);
    if let Some(value) = smol::future::race(async { Some(future.as_mut().await) }, async {
        smol::Timer::after(Duration::from_secs(30)).await;
        None
    })
    .await
    {
        return value;
    }
    _ = view.update_in(cx, |this, _, cx| {
        if let Some(id) = this
            .changes_preview
            .as_ref()
            .filter(|f| f.token == token)
            .map(Flow::document)
        {
            this.stop_changes_preview(id, cx);
        }
    });
    future.await
}
async fn wait_cleanup<T>(
    view: WeakEntity<Workspace>,
    cx: &mut AsyncWindowContext,
    token: u64,
    future: impl Future<Output = T>,
) -> T {
    let mut future = Box::pin(future);
    if let Some(value) = smol::future::race(async { Some(future.as_mut().await) }, async {
        smol::Timer::after(Duration::from_secs(5)).await;
        None
    })
    .await
    {
        return value;
    }
    _ = view.update_in(cx, |this, _, cx| {
        if let Some(f) = this.changes_preview.as_mut().filter(|f| f.token == token) {
            f.status = "Waiting for the original helper to acknowledge changes-session teardown. Closing remains blocked.".into();
            cx.notify();
        }
    });
    future.await
}
fn validate(view: &WeakEntity<Workspace>, cx: &mut AsyncWindowContext, token: u64) -> Result<()> {
    view.update_in(cx, |this, _, cx| {
        if this.preview_valid(token, cx) {
            Ok(())
        } else {
            Err(stale())
        }
    })
    .map_err(|_| stale())?
}
async fn prepare_changes(
    view: WeakEntity<Workspace>,
    cx: &mut AsyncWindowContext,
    token: u64,
    work: ChangesWork,
) -> Result<Arc<Preparation>> {
    let ChangesWork {
        purpose,
        plan,
        client,
        profile,
        cancel,
        owned,
    } = work;
    validate(&view, cx, token)?;
    cancel.check()?;
    let policy = preview::policy(&profile);
    let engine = profile.engine.clone();
    let connection = wait_stage(view.clone(), cx, token, smol::unblock(move || live::connection(&profile))).await.map_err(|_| backend::BackendError::transport("The platform credential store could not provide this profile's password. Local changes were preserved."))?;
    validate(&view, cx, token)?; // Credential lookup can display an OS prompt.
    cancel.check()?;
    let connected = wait_stage(view.clone(), cx, token, client.connect(connection)).await?;
    let connection_valid = connected.engine == engine
        && connected.transaction_status == backend::TransactionStatus::Idle
        && [
            "cancel",
            "transactions",
            "operationAssessment",
            "executionPolicy",
        ]
        .iter()
        .all(|required| connected.capabilities.iter().any(|c| c == required));
    // Snapshot current IDs at completion, not only those present before connect.
    let borrowed = view
        .update_in(cx, |this, _, _| {
            this.profiles
                .iter()
                .filter_map(|p| p.session.clone())
                .chain(this.tabs.iter().filter_map(|t| t.session.clone()))
                .chain(
                    this.changes_preview
                        .iter()
                        .filter_map(|f| f.session.as_ref().map(|s| s.id().to_owned())),
                )
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let session = FreshSession::adopt(client, connected, purpose, policy, cancel, &borrowed)?;
    *owned.lock().unwrap_or_else(|p| p.into_inner()) = Some(session.clone());
    // Publish ownership even if stale/cancelled: it must still be cleaned up.
    if view
        .update_in(cx, |this, _, cx| {
            if let Some(f) = this.changes_preview.as_mut().filter(|f| f.token == token) {
                f.session = Some(session.clone());
                f.status = "Requesting parameterized preview on a new idle session...".into();
                cx.notify();
                true
            } else {
                false
            }
        })
        .unwrap_or(false)
    {
        validate(&view, cx, token)?;
    } else {
        return Err(stale());
    }
    if !connection_valid {
        return Err(stale());
    }
    let stream = view
        .update_in(cx, |this, _, cx| {
            if !this.preview_valid(token, cx) {
                return Err(stale());
            }
            let stream = plan.preview(&session)?;
            this.changes_preview.as_mut().unwrap().query = Some(stream.query_id().to_owned());
            cx.notify();
            Ok(stream)
        })
        .map_err(|_| stale())??;
    let previewed = wait_stage(view.clone(), cx, token, stream.finish()).await?;
    validate(&view, cx, token)?;
    let pending = view
        .update_in(cx, |this, _, cx| {
            if !this.preview_valid(token, cx) {
                return Err(stale());
            }
            let pending = previewed.begin_assessment()?;
            let f = this.changes_preview.as_mut().unwrap();
            f.query = Some(pending.query_id().to_owned());
            f.status = "Assessing the exact ordered changes batch...".into();
            cx.notify();
            Ok(pending)
        })
        .map_err(|_| stale())??;
    // Stop owns the assessment query too; cleanup revokes any unused grant.
    let prepared = wait_stage(view.clone(), cx, token, pending.finish()).await?;
    validate(&view, cx, token)?;
    Ok(prepared)
}

async fn review_and_apply(
    view: WeakEntity<Workspace>,
    cx: &mut AsyncWindowContext,
    token: u64,
    prepared: Arc<Preparation>,
) -> Result<backend::QueryOutcome> {
    validate(&view, cx, token)?;
    if prepared.rejected() {
        return Err(backend::BackendError::transport(
            "The helper execution policy denied this changes batch. Local changes were preserved.",
        ));
    }
    let (sender, receiver) = async_channel::bounded(1);
    view.update_in(cx, |this, window, cx| {
        this.show_apply_review(token, prepared.clone(), sender, window, cx)
    })
    .map_err(|_| stale())??;
    // No review deadline: Stop/Cancel is sticky and wakes this exact owner.
    let approved = receiver.recv().await.unwrap_or(false);
    _ = view.update_in(cx, |this, window, cx| {
        if this
            .changes_preview
            .as_ref()
            .is_some_and(|f| f.token == token && f.phase == Phase::Reviewing)
        {
            window.close_dialog(cx);
        }
    });
    if !approved {
        return Err(stale());
    }
    validate(&view, cx, token)?;
    let pending = view.update_in(cx, |this, _, cx| {
        if !this.preview_valid(token, cx) { return Err(stale()); }
        let pending = prepared.approval(true)?.begin_apply(&prepared)?;
        let f = this.changes_preview.as_mut().unwrap();
        f.query = Some(pending.query_id().to_owned());
        f.review = None;
        f.phase = Phase::Applying;
        f.status = "Applying the exact reviewed batch atomically. Stop waits for authoritative recovery...".into();
        cx.notify();
        Ok(pending)
    }).map_err(|_| stale())??;
    // Once enqueued, retain its original terminal even if context or Stop changes.
    wait_stage(view, cx, token, pending.finish()).await
}

#[cfg(all(test, feature = "native-smoke"))]
mod tests;
