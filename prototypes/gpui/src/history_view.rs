//! Managed history UI and source-only workspace snapshots.
use super::*;
use gpui_kit::component::checkbox::Checkbox;
use restoration::{HistoryEntry, Snapshot, StoredDocument, WorkspaceStore};

pub(super) struct RestorationState {
    pub(super) store: Option<WorkspaceStore>,
    pub(super) snapshot: Snapshot,
    pub(super) ready: bool,
    pub(super) error: Option<String>,
    pub(super) debounce: Option<Task<()>>,
    pub(super) revision: u64,
    pub(super) saved_revision: u64,
    history_preference_changed: bool,
    history_was_cleared: bool,
}
impl RestorationState {
    pub(super) fn new(store: Option<&ProfileStore>) -> Self {
        Self {
            store: store.map(|s| WorkspaceStore::new(s.data_owner())),
            snapshot: Snapshot::default(),
            ready: false,
            error: None,
            debounce: None,
            revision: 0,
            saved_revision: 0,
            history_preference_changed: false,
            history_was_cleared: false,
        }
    }
}
impl Workspace {
    pub(super) fn document_profile_available(&self, id: &ProfileId) -> bool {
        self.profiles
            .iter()
            .any(|p| &p.id == id && (p.config.is_some() || p.demo))
    }
    fn ensure_document_profile(&mut self, saved: Option<String>) -> ProfileId {
        // Missing bindings remain document identities, never invented connections.
        saved.map(ProfileId).unwrap_or_else(ProfileId::unbound)
    }
    pub(super) fn bind_selected_document_profile(&mut self, cx: &mut Context<Self>) {
        if self.closing {
            return;
        }
        let Some(profile) = self
            .profiles
            .get(self.selected_profile)
            .filter(|p| p.config.is_some())
            .map(|p| p.id.clone())
        else {
            return;
        };
        let Some(tab) = self.tabs.get(self.active) else {
            return;
        };
        if tab.snapshot_locked() || self.document_profile_available(&tab.profile) {
            return;
        }
        self.tabs[self.active].profile = profile;
        self.sync_assistance(cx);
        self.tabs[self.active].status =
            "Connection selected. Disconnected; no SQL has been executed.".into();
        self.schedule_documents(cx);
        cx.notify();
    }
    pub(super) fn restore_local_documents(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(store) = &self.restoration.store else {
            return;
        };
        match store.load() {
            Ok(snapshot) => {
                let had_documents = !self.tabs.is_empty();
                let active = self.tabs.get(self.active).map(|tab| tab.id);
                for saved in &snapshot.documents {
                    if self.tabs.iter().any(|tab| tab.persistent_id == saved.id) {
                        continue;
                    }
                    let profile = self.ensure_document_profile(saved.profile_id.clone());
                    if let Some(id) = self.add_sql_tab_for_profile(
                        saved.title.clone(),
                        saved.text.clone(),
                        profile,
                        window,
                        cx,
                    ) {
                        let tab = self.tabs.iter_mut().find(|t| t.id == id).unwrap();
                        tab.persistent_id = saved.id.clone();
                        tab.status =
                            "Restored SQL draft. Disconnected; no SQL has been executed.".into();
                    }
                }
                self.active = if had_documents {
                    self.tabs
                        .iter()
                        .position(|tab| Some(tab.id) == active)
                        .unwrap_or(0)
                } else {
                    self.tabs
                        .iter()
                        .position(|tab| {
                            Some(&tab.persistent_id) == snapshot.selected_document_id.as_ref()
                        })
                        .unwrap_or(0)
                };
                let mut snapshot = snapshot;
                // Recovery merges records and retains this window's current SQL,
                // selection and preference; retry never discards unsaved edits.
                if had_documents {
                    if self.restoration.history_was_cleared {
                        snapshot.history.clear();
                    }
                    for entry in &self.restoration.snapshot.history {
                        if !snapshot.history.iter().any(|saved| saved.id == entry.id) {
                            snapshot.history.push(entry.clone());
                        }
                    }
                    if self.restoration.history_preference_changed {
                        snapshot.history_enabled = self.restoration.snapshot.history_enabled;
                    }
                    snapshot.trim(restoration::now_ms());
                }
                self.restoration.snapshot = snapshot;
                self.restoration.error = None;
            }
            Err(error) => self.restoration.error = Some(error.to_string()),
        }
    }
    fn persisted_profile_id(&self, id: &ProfileId) -> Option<String> {
        // Saved IDs are opaque. Only the explicit unbound value and actual
        // in-memory fixture metadata omit a binding from persistence.
        (id != &ProfileId::unbound()
            && !self
                .profiles
                .iter()
                .any(|profile| &profile.id == id && profile.demo))
        .then(|| id.0.clone())
    }
    pub(super) fn document_snapshot(&self, cx: &App) -> Snapshot {
        let documents: Vec<_> = self
            .tabs
            .iter()
            .filter(|t| t.kind == model::DocumentKind::Sql)
            .map(|tab| StoredDocument {
                id: tab.persistent_id.clone(),
                title: tab.title.clone(),
                text: tab.editor.read(cx).value().to_string(),
                profile_id: self.persisted_profile_id(&tab.profile),
            })
            .collect();
        let selected_document_id = self
            .tabs
            .get(self.active)
            .filter(|t| t.kind == model::DocumentKind::Sql)
            .map(|t| t.persistent_id.clone());
        Snapshot {
            version: restoration::VERSION,
            documents,
            selected_document_id,
            history: self.restoration.snapshot.history.clone(),
            history_enabled: self.restoration.snapshot.history_enabled,
        }
    }
    pub(super) fn schedule_documents(&mut self, cx: &mut Context<Self>) {
        self.save_documents_after(Duration::from_secs(1), cx);
    }
    fn save_documents_after(&mut self, delay: Duration, cx: &mut Context<Self>) {
        if !self.restoration.ready {
            return;
        }
        self.restoration.revision += 1;
        self.restoration.debounce = None;
        // Finishing owns the desired post-intent snapshot. Editor changes are
        // rechecked by that loop, never by a competing full-workspace debounce.
        if self
            .close_flow
            .as_ref()
            .is_some_and(|flow| flow.phase == close::ClosePhase::Finishing)
        {
            return;
        }
        let Some(store) = &self.restoration.store else {
            return;
        };
        let request = store.reserve(self.document_snapshot(cx));
        let revision = self.restoration.revision;
        self.restoration.debounce = Some(cx.spawn(async move |view, cx| {
            cx.background_executor().timer(delay).await;
            let result = cx
                .background_executor()
                .spawn(async move { request.commit() })
                .await;
            _ = view.update(cx, |this, cx| {
                if this.restoration.revision != revision {
                    return;
                }
                if result.is_ok() {
                    this.restoration.saved_revision = revision;
                }
                this.restoration.error = result.err().map(|e| e.to_string());
                cx.notify();
            });
        }));
    }
    pub(super) fn record_statement_history(
        &mut self,
        context: &OperationContext,
        outcome: &'static str,
        cx: &mut Context<Self>,
    ) {
        let profile_id = self.persisted_profile_id(&context.profile);
        let Some(tab) = self.tabs.iter_mut().find(|t| t.id == context.document) else {
            return;
        };
        if tab.kind != model::DocumentKind::Sql || !tab.history_allowed {
            return;
        }
        let index = tab.active_execution;
        let Some(execution) = tab.executions.get_mut(index).filter(|e| {
            e.operation == context.operation && e.started_at.is_some() && !e.history_recorded
        }) else {
            return;
        };
        execution.history_recorded = true;
        let Some(statement) = tab
            .execution_source
            .as_ref()
            .and_then(|f| f.statements().get(index))
        else {
            return;
        };
        let entry = HistoryEntry {
            id: restoration::new_uuid(),
            date: restoration::now_ms(),
            document_id: Some(tab.persistent_id.clone()),
            profile_id,
            sql: statement.sql().into(),
            outcome: outcome.into(),
        };
        self.restoration
            .snapshot
            .record(entry, restoration::now_ms());
        self.schedule_documents(cx);
    }
    pub(super) fn reopen_history(
        &mut self,
        id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.closing {
            return false;
        }
        let Some(entry) = self
            .restoration
            .snapshot
            .history
            .iter()
            .find(|e| e.id == id)
            .cloned()
        else {
            return false;
        };
        let profile = self.ensure_document_profile(entry.profile_id);
        let added = self.add_sql_tab_for_profile(
            format!("SQL {}", self.tabs.len() + 1),
            entry.sql,
            profile,
            window,
            cx,
        );
        if let Some(id) = added {
            self.tabs.iter_mut().find(|t| t.id == id).unwrap().status =
                "Opened from history. Disconnected; no SQL has been executed.".into();
        }
        added.is_some()
    }
    pub(super) fn show_history(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let workspace = cx.entity().downgrade();
        let observed = cx.entity();
        let panel = cx.new(|cx| {
            let subscription = cx.observe(&observed, |_, _, cx| cx.notify());
            HistoryPanel {
                workspace,
                _subscription: subscription,
            }
        });
        window.open_dialog(cx, move |dialog, _, _| {
            dialog
                .title("SQL History")
                .accessibility_label("SQL History")
                .w(px(760.))
                .content({
                    let panel = panel.clone();
                    move |content, _, _| content.child(panel.clone())
                })
        });
    }
}
struct HistoryPanel {
    workspace: WeakEntity<Workspace>,
    _subscription: Subscription,
}
impl Render for HistoryPanel {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let Some(workspace) = self.workspace.upgrade() else {
            return div();
        };
        let state = workspace.read(cx);
        let enabled = state.restoration.snapshot.history_enabled;
        let error = state.restoration.error.clone();
        let rows = state
            .restoration
            .snapshot
            .history
            .iter()
            .rev()
            .cloned()
            .collect::<Vec<_>>();
        let mut list = div()
            .id("history-entries")
            .h(px(330.))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_3();
        for entry in rows {
            let id = entry.id.clone();
            list = list.child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .text_xs()
                            .text_color(cx.theme().muted_foreground)
                            .child(format!("{} / {}", format_date(entry.date), entry.outcome)),
                    )
                    .child(
                        div()
                            .font_family(cx.theme().mono_font_family.clone())
                            .child(entry.sql.chars().take(600).collect::<String>()),
                    )
                    .child(
                        Button::new(SharedString::from(format!("history-open-{id}")))
                            .small()
                            .label("Open in SQL Tab")
                            .on_click(cx.listener(move |this, _, window, cx| {
                                _ = this.workspace.update(cx, |workspace, cx| {
                                    if workspace.reopen_history(&id, window, cx) {
                                        window.close_dialog(cx);
                                    }
                                });
                            })),
                    ),
            );
        }
        div().flex().flex_col().gap_3()
            .child(Checkbox::new("history-enabled").label("Record executed SQL").checked(enabled).on_change(cx.listener(|this, value: &bool, _, cx| {
                _ = this.workspace.update(cx, |workspace, cx| { workspace.restoration.snapshot.history_enabled = *value; workspace.restoration.history_preference_changed = true; workspace.schedule_documents(cx); cx.notify(); });
            })))
            .child("Up to 1000 executions from the last 30 days, stored on this computer.")
            .when_some(error, |view, error| view.child(div().text_color(rgb(0xca5555)).child(error)))
            .child(list)
            .child(div().flex().gap_2()
                .child(Button::new("history-clear").label("Clear History").on_click(cx.listener(|this, _, _, cx| {
                    _ = this.workspace.update(cx, |workspace, cx| { workspace.restoration.snapshot.history.clear(); workspace.restoration.history_was_cleared = true; workspace.save_documents_after(Duration::ZERO, cx); cx.notify(); });
                })))
                .child(Button::new("history-retry-save").label("Retry Save").on_click(cx.listener(|this, _, _, cx| { _ = this.workspace.update(cx, |workspace, cx| workspace.save_documents_after(Duration::ZERO, cx)); })))
                .child(Button::new("history-retry-load").label("Retry Load").on_click(cx.listener(|this, _, window, cx| {
                    _ = this.workspace.update(cx, |workspace, cx| {
                        if workspace.closing { return; }
                        workspace.restoration.debounce = None;
                        workspace.restoration.ready = false;
                        workspace.restore_local_documents(window, cx);
                        workspace.restoration.ready = true;
                        workspace.save_documents_after(Duration::ZERO, cx);
                        cx.notify();
                    });
                })))
                .child(Button::new("drafts-clear").label("Clear SQL Drafts...").on_click(cx.listener(|this, _, window, cx| {
                    let workspace = this.workspace.clone();
                    window.close_dialog(cx);
                    window.open_dialog(cx, move |dialog, _, _| {
                        let clear = workspace.clone();
                        dialog.title("Clear SQL Drafts?").accessibility_label("Clear SQL Drafts?").overlay_closable(false).close_button(false)
                            .on_ok(|_, _, _| true).on_cancel(|_, _, _| true)
                            .child("Close the current documents and remove the saved drafts. Saved .sql files stay on disk.")
                            .footer(div().flex().gap_2().justify_end()
                                .child(Button::new("drafts-clear-cancel").label("Cancel").on_click(|_, window, cx| window.close_dialog(cx)))
                                .child(Button::new("drafts-clear-confirm").label("Clear Drafts").on_click(move |_, window, cx| { window.close_dialog(cx); _ = clear.update(cx, |workspace, cx| workspace.request_close(CloseIntent::ClearDrafts, window, cx)); })))
                    });
                }))))
    }
}
// ISO calendar date/time without a new locale/runtime dependency; milliseconds are UTC.
fn format_date(ms: f64) -> String {
    let seconds = (ms / 1_000.).floor() as i64;
    let days = seconds.div_euclid(86400);
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    let y = y + i64::from(m <= 2);
    let time = seconds.rem_euclid(86400);
    format!(
        "{y:04}-{m:02}-{d:02} {:02}:{:02}:{:02} UTC",
        time / 3600,
        time / 60 % 60,
        time % 60
    )
}
