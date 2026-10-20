//! GPUI entity ownership and document bindings. Editors are created once per document.
use super::*;

pub(super) struct Profile {
    pub(super) id: ProfileId,
    /// Only explicit disposable fixture profiles may use local demo data.
    pub(super) demo: bool,
    pub(super) generation: u64,
    /// Changes only when the physical catalog service is newly attached.
    pub(super) service_generation: u64,
    pub(super) name: SharedString,
    pub(super) environment: &'static str,
    pub(super) loaded: bool,
    pub(super) expanded: bool,
    pub(super) config: Option<ConnectionProfile>,
    pub(super) session: Option<String>,
    pub(super) session_settings: Option<ConnectionProfile>,
    pub(super) session_client: Option<BackendClient>,
    pub(super) schemas: Vec<CatalogSchema>,
    pub(super) task: Option<Task<()>>,
    pub(super) status: SharedString,
}
pub(super) struct QueryTab {
    pub(super) document: DocumentState,
    pub(super) catalog_document: Option<catalog::CatalogDocument>,
    pub(super) editor: Entity<EditorState>,
    pub(super) accessibility_guard: gpui_kit::component::input::InputAccessibilityGuard,
    pub(super) filter: Entity<InputState>,
    pub(super) grid: Option<Entity<TableState<ResultGrid>>>,
    pub(super) grid_views: std::collections::BTreeMap<(u64, usize), Entity<TableState<ResultGrid>>>,
    pub(super) grid_subscriptions: Vec<Subscription>,
    pub(super) task: Option<Task<()>>,
    pub(super) operation_client: Option<BackendClient>,
    pub(super) session_owner: Option<session_owner::SessionOwner>,
    pub(super) execution_decoration: gpui_kit::component::input::RangeDecorationCollection,
    pub(super) status: SharedString,
    pub(super) error: bool,
    pub(super) _subscriptions: Vec<Subscription>,
}
impl std::ops::Deref for QueryTab {
    type Target = DocumentState;
    fn deref(&self) -> &Self::Target {
        &self.document
    }
}
impl std::ops::DerefMut for QueryTab {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.document
    }
}
impl QueryTab {
    pub(super) fn retire_grid_contexts(&self, cx: &mut App) {
        for grid in self.grid_views.values() {
            grid.update(cx, |table, _| table.delegate_mut().context_valid = false);
        }
    }
}
pub(super) struct Workspace {
    pub(super) tabs: Vec<QueryTab>,
    pub(super) active: usize,
    pub(super) next_id: u64,
    pub(super) profiles: Vec<Profile>,
    pub(super) unbound_profile: Profile,
    pub(super) missing_profile: Profile,
    pub(super) profile_error: Option<String>,
    pub(super) startup_policy: product_identity::StartupPolicy,
    pub(super) selected_profile: usize,
    pub(super) search: Entity<InputState>,
    pub(super) catalog: catalog::CatalogState,
    pub(super) assistance: assistance::State,
    pub(super) completion: completion::Ui,
    pub(super) signatures: signature::Ui,
    pub(super) focus: FocusHandle,
    pub(super) backend: Option<BackendClient>,
    pub(super) closing: bool,
    pub(super) close_flow: Option<close::CloseFlow>,
    pub(super) next_close: u64,
    pub(super) closing_task: Option<Task<()>>,
    #[cfg(target_os = "linux")]
    pub(super) session_end: Option<session_end::Client>,
    #[cfg(target_os = "linux")]
    pub(super) session_end_task: Option<Task<()>>,
    #[cfg(target_os = "linux")]
    pub(super) session_end_readiness: Option<session_end::ReadinessPublisher>,
    pub(super) close_finalizers: Vec<close::finalizers::Finalizer>,
    pub(super) profile_store: Option<ProfileStore>,
    pub(super) profile_editor: Option<Entity<ConnectionEditor>>,
    pub(super) editor_subscription: Option<Subscription>,
    pub(super) startup_consumed: bool,
    pub(super) transfer_review: Option<Entity<transfer_view::TransferReview>>,
    pub(super) transfer_task: Option<Task<()>>,
    pub(super) run_file: Option<run_file_view::Flow>,
    pub(super) run_file_task: Option<Task<()>>,
    pub(super) next_run_file: u64,
    pub(super) export_request: Option<export_view::ExportRequest>,
    pub(super) export_task: Option<Task<()>>,
    pub(super) next_export_request: u64,
    pub(super) file_request: Option<file_view::FileRequest>,
    pub(super) file_task: Option<Task<()>>,
    pub(super) next_file_request: u64,
    pub(super) changes_preview: Option<preview_view::Flow>,
    pub(super) next_changes_preview: u64,
    pub(super) restoration: history_view::RestorationState,
    pub(super) appearance: appearance_settings::State,
    pub(super) shortcuts: shortcut_settings::State,
    pub(super) command_menu_origin: Option<commands::MenuOrigin>,
    pub(super) _subscriptions: Vec<Subscription>,
}

impl Workspace {
    pub(super) fn profile(&self, id: &ProfileId) -> &Profile {
        self.profiles
            .iter()
            .find(|p| &p.id == id)
            .unwrap_or_else(|| {
                if id == &ProfileId::unbound() {
                    &self.unbound_profile
                } else {
                    &self.missing_profile
                }
            })
    }
    pub(super) fn profile_index(&self, id: &ProfileId) -> Option<usize> {
        self.profiles.iter().position(|p| &p.id == id)
    }
    pub(super) fn operation_source_valid(&self, context: &OperationContext, cx: &App) -> bool {
        self.run_file_operation_valid(context)
            && self
                .tabs
                .iter()
                .find(|t| t.id == context.document)
                .is_some_and(|t| {
                    t.kind == model::DocumentKind::Sql
                        && t.owns(context)
                        && (!t.execution_editor_bound || t.generation == context.source_revision)
                        && (!t.execution_editor_bound
                            || t.execution_source.as_ref().is_none_or(|fragment| {
                                fragment.source().text() == t.editor.read(cx).value().as_ref()
                            }))
                        && context.settings.as_ref()
                            == self
                                .profiles
                                .iter()
                                .find(|p| p.id == context.profile)
                                .and_then(|p| p.config.as_ref())
                })
    }
    pub(super) fn operation_valid(&self, context: &OperationContext, cx: &App) -> bool {
        self.operation_source_valid(context, cx)
            && self
                .tabs
                .iter()
                .find(|t| t.id == context.document)
                .is_some_and(|t| t.accepts(context, context.settings.as_ref()))
    }

    pub(super) fn new(
        store: Option<ProfileStore>,
        policy: product_identity::StartupPolicy,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        assert!(
            policy.restore_disconnected,
            "Restored SQL documents must remain disconnected"
        );
        // Both stores use the original profile directory owner, before any view renders.
        let shortcuts = shortcut_settings::State::load(store.as_ref());
        let appearance = appearance_settings::State::load(store.as_ref(), window.appearance());
        appearance.apply(window, cx);
        let appearance_sub = cx.observe_window_appearance(window, |this, window, cx| {
            this.system_appearance_changed(window.appearance(), window, cx);
        });
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search object names"));
        let subscription = cx.subscribe_in(
            &search,
            window,
            |this, _, event: &InputEvent, window, cx| {
                if matches!(event, InputEvent::Change) {
                    this.schedule_catalog_search(window, cx);
                }
                cx.notify();
            },
        );
        let activation_sub = cx.observe_window_activation(window, |this, _, cx| {
            this.dismiss_completion();
            this.dismiss_signatures();
            cx.notify();
        });
        let mut workspace = Self {
            tabs: Vec::new(),
            active: 0,
            next_id: 1,
            selected_profile: 0,
            unbound_profile: Profile::unavailable(false),
            missing_profile: Profile::unavailable(true),
            profile_error: None,
            startup_policy: policy,
            profiles: if policy.built_in_fixtures {
                vec![
                    Profile {
                        id: ProfileId::demo("brewery"),
                        demo: true,
                        generation: 0,
                        service_generation: 0,
                        name: "Demo brewery".into(),
                        environment: "Development",
                        loaded: false,
                        expanded: true,
                        config: None,
                        session: None,
                        session_settings: None,
                        session_client: None,
                        schemas: Vec::new(),
                        task: None,
                        status: "Demo fixtures".into(),
                    },
                    Profile {
                        id: ProfileId::demo("reporting"),
                        demo: true,
                        generation: 0,
                        service_generation: 0,
                        name: "Demo reporting".into(),
                        environment: "Staging",
                        loaded: false,
                        expanded: false,
                        config: None,
                        session: None,
                        session_settings: None,
                        session_client: None,
                        schemas: Vec::new(),
                        task: None,
                        status: "Demo fixtures".into(),
                    },
                ]
            } else {
                Vec::new()
            },
            backend: None,
            closing: false,
            close_flow: None,
            next_close: 0,
            closing_task: None,
            close_finalizers: Vec::new(),
            #[cfg(target_os = "linux")]
            session_end: None,
            #[cfg(target_os = "linux")]
            session_end_task: None,
            #[cfg(target_os = "linux")]
            session_end_readiness: None,
            restoration: history_view::RestorationState::new(store.as_ref()),
            appearance,
            shortcuts,
            profile_store: store,
            profile_editor: None,
            editor_subscription: None,
            startup_consumed: false,
            transfer_review: None,
            transfer_task: None,
            run_file: None,
            run_file_task: None,
            next_run_file: 0,
            export_request: None,
            export_task: None,
            next_export_request: 0,
            file_request: None,
            file_task: None,
            next_file_request: 0,
            changes_preview: None,
            next_changes_preview: 0,
            command_menu_origin: None,
            search,
            catalog: catalog::CatalogState::default(),
            assistance: assistance::State::default(),
            completion: completion::Ui::default(),
            signatures: signature::Ui::default(),
            focus: cx.focus_handle(),
            _subscriptions: vec![subscription, activation_sub, appearance_sub],
        };
        if !policy.built_in_fixtures {
            workspace.load_profiles();
        }
        workspace.restore_local_documents(window, cx);
        if workspace.tabs.is_empty() {
            workspace.add_default_tab(DemoTable::Products, window, cx);
        }
        workspace.restoration.ready = true;
        workspace.schedule_documents(cx);
        workspace.start_assistance(cx);
        workspace.register_appearance_finalizer();
        workspace.register_shortcut_finalizer();
        workspace
    }

    pub(super) fn add_tab(
        &mut self,
        table: DemoTable,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if window.has_active_dialog(cx) {
            return;
        }
        self.add_default_tab(table, window, cx);
    }

    // Construction runs before GPUI installs the component dialog root. User
    // commands enter through add_tab after that root exists.
    pub(super) fn add_default_tab(
        &mut self,
        table: DemoTable,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let demo = self
            .profiles
            .get(self.selected_profile)
            .is_some_and(|profile| profile.demo);
        self.add_sql_tab(
            if !demo {
                format!("SQL {}", self.tabs.len() + 1)
            } else {
                format!("{}.sql", table.name())
            },
            if !demo { String::new() } else { table.query() },
            window,
            cx,
        );
    }

    pub(super) fn add_sql_tab(
        &mut self,
        title: String,
        sql: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let profile = self
            .profiles
            .get(self.selected_profile)
            .map(|profile| profile.id.clone())
            .unwrap_or_else(ProfileId::unbound);
        self.add_sql_tab_for_profile(title, sql, profile, window, cx);
    }

    /// Explicit profile ownership for file open and disconnected restoration.
    pub(super) fn add_sql_tab_for_profile(
        &mut self,
        title: String,
        sql: String,
        profile: ProfileId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<DocumentId> {
        self.add_document_for_profile(title, sql, profile, model::DocumentKind::Sql, window, cx)
    }

    /// Construct the final document kind before scheduling its first safe snapshot.
    pub(super) fn add_document_for_profile(
        &mut self,
        title: String,
        source: String,
        profile: ProfileId,
        kind: model::DocumentKind,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<DocumentId> {
        if self.closing
            || (kind != model::DocumentKind::Sql && self.profile_index(&profile).is_none())
        {
            return None;
        }
        let id = DocumentId(self.next_id);
        self.next_id += 1;
        let editor = cx.new(|cx| controls::sql_editor_state(source, window, cx));
        let execution_decoration = editor.update(cx, |state, cx| {
            state.create_range_decorations_collection(Vec::new(), cx)
        });
        let filter = cx.new(|cx| InputState::new(window, cx).placeholder("Filter loaded rows"));
        let filter_sub = cx.subscribe_in(&filter, window, move |this, input, event, window, cx| {
            if matches!(event, InputEvent::Change) {
                let value = input.read(cx).value();
                if let Some(grid) = this
                    .tabs
                    .iter()
                    .find(|tab| tab.id == id)
                    .and_then(|tab| tab.grid.as_ref())
                {
                    grid.update(cx, |grid, cx| {
                        grid.delegate_mut().set_filter(&value);
                        grid.delegate_mut().sync_details(window, cx);
                        cx.notify();
                    });
                }
                cx.notify();
            }
        });
        let editor_sub = cx.subscribe(&editor, move |this, _, event, cx| {
            if matches!(event, InputEvent::Change) {
                this.completion_source_changed(id, cx);
                this.dismiss_signatures();
                if let Some(tab) = this.tabs.iter_mut().find(|tab| tab.id == id) {
                    if tab.kind != model::DocumentKind::Sql {
                        return;
                    }
                    tab.generation += 1;
                    tab.clear_execution_marks();
                    tab.execution_decoration.clear(cx);

                    if tab.task.is_none() {
                        tab.status = "Query changed. Run to refresh results.".into();
                    }
                    tab.error = false;
                }
                this.schedule_documents(cx);
                this.sync_assistance(cx);
                cx.notify();
            } else if matches!(event, InputEvent::Blur) {
                this.dismiss_completion();
                this.dismiss_signatures();
                cx.notify();
            }
        });
        let typing_sub = cx.subscribe_in(
            &editor,
            window,
            move |this, _, event: &gpui_kit::component::input::InputTextEvent, window, cx| {
                this.completion_typed(id, &event.text, window, cx);
            },
        );
        let selection_sub = cx.observe_in(&editor, window, |this, _, window, cx| {
            this.completion_selection_changed(window, cx);
            this.refresh_signatures(window, cx);
        });
        let mut document = DocumentState::sql(id, title, profile);
        document.kind = kind;
        let owner = cx.entity().downgrade();
        let accessibility_guard = gpui_kit::component::input::InputAccessibilityGuard::default()
            .with_owner(move |window, cx| {
                let modal = window.has_active_dialog(cx) || window.has_active_prompt();
                owner.upgrade().is_some_and(|owner| {
                    let w = owner.read(cx);
                    !w.closing && !modal && w.tabs.get(w.active).is_some_and(|t| t.id == id)
                })
            });
        let initial_status = if self.document_profile_available(&document.profile) {
            "Ready. Connect or Run explicitly to start a session.".into()
        } else {
            self.profile(&document.profile).status.clone()
        };
        self.tabs.push(QueryTab {
            document,
            catalog_document: None,
            editor,
            accessibility_guard,
            filter,
            grid: None,
            grid_views: Default::default(),
            grid_subscriptions: Vec::new(),
            task: None,
            operation_client: None,
            session_owner: None,
            execution_decoration,
            error: false,
            status: initial_status,
            _subscriptions: vec![filter_sub, editor_sub, typing_sub, selection_sub],
        });
        self.active = self.tabs.len() - 1;
        self.tabs[self.active]
            .editor
            .update(cx, |state, cx| state.focus(window, cx));
        self.schedule_documents(cx);
        self.sync_assistance(cx);
        cx.notify();
        Some(id)
    }

    pub(super) fn close_tab(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        if self.tabs[index]
            .grid_views
            .values()
            .any(|g| g.read(cx).delegate().has_drafts())
        {
            self.request_close(CloseIntent::Tab(self.tabs[index].id), window, cx);
            return;
        }
        self.remove_reviewed_tab(index, window, cx);
    }
    pub(super) fn remove_reviewed_tab(
        &mut self,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.tabs.remove(index);
        if self.tabs.is_empty() {
            self.add_default_tab(DemoTable::Products, window, cx);
        } else {
            if index < self.active {
                self.active -= 1;
            }
            self.active = self.active.min(self.tabs.len() - 1);
            cx.notify();
        }
        self.schedule_documents(cx);
        self.sync_assistance(cx);
    }

    /// Capture the exact editor snapshot and byte selection before any asynchronous work.
    pub(super) fn prepare_execution(
        &self,
        id: DocumentId,
        override_sql: Option<String>,
        cx: &App,
    ) -> std::result::Result<sql::PreparedFragment, &'static str> {
        let tab = self
            .tabs
            .iter()
            .find(|tab| tab.id == id)
            .ok_or("SQL document is unavailable.")?;
        let dialect = self
            .profile(&tab.profile)
            .config
            .as_ref()
            .map_or(Some(sql::Dialect::PostgreSQL), |p| {
                sql::Dialect::from_engine(&p.engine)
            })
            .ok_or("Unsupported SQL dialect.")?;
        let editor = tab.editor.read(cx);
        let (source, selection, script) = match override_sql {
            Some(text) => (text, 0..0, true),
            None => (editor.value().to_string(), editor.selected_range(), false),
        };
        sql::resolve(sql::SourceText::new(source), selection, dialect, script)
            .ok_or("No SQL statement at the current selection.")
    }

    #[cfg(feature = "native-smoke")]
    pub(super) fn run_query(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.command(
            CommandId::RunCurrent,
            CommandOrigin::Button,
            None,
            window,
            cx,
        );
    }

    pub(super) fn run_prepared(
        &mut self,
        id: DocumentId,
        fragment: std::sync::Arc<sql::PreparedFragment>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing || self.export_request.is_some() || window.has_active_dialog(cx) {
            return;
        }
        let Some(index) = self.tabs.iter().position(|t| t.id == id) else {
            return;
        };
        if !self.document_profile_available(&self.tabs[index].profile) {
            self.tabs[index].status = "The saved connection is unavailable. Select a connection explicitly before running SQL.".into();
            self.tabs[index].error = true;
            cx.notify();
            return;
        }
        if self.profile(&self.tabs[index].profile).config.is_some() {
            self.run_live_prepared(id, fragment, None, window, cx);
            return;
        }
        self.tabs[index].clear_execution_marks();
        self.tabs[index].execution_decoration.clear(cx);
        if let Err(error) = scripts::validate(&fragment) {
            self.tabs[index].status = error.into();
            self.tabs[index].error = true;
            cx.notify();
            return;
        }
        let tab = &mut self.tabs[index];
        let Some(context) = tab.begin(None, fragment.source().text().len()) else {
            return;
        };
        tab.prepare_batch(fragment.clone());
        tab.execution_decoration.clear(cx);
        tab.result_sets.clear();
        tab.selected_result = 0;
        tab.error = false;
        tab.retire_grid_contexts(cx);
        tab.grid = None;
        if fragment.kind() == sql::FragmentKind::Script {
            tab.phase = Some(model::OperationPhase::Reviewing);
            tab.status = "Awaiting execution confirmation / demo fixtures".into();
            self.confirm_demo_script(context, fragment, window, cx);
        } else {
            self.execute_demo_batch(context, fragment, window, cx);
        }
        cx.notify();
    }

    fn confirm_demo_script(
        &mut self,
        context: OperationContext,
        fragment: std::sync::Arc<sql::PreparedFragment>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // Demo has no helper or real policy. Inspect the immutable source and
        // explicitly disclose synthetic classification before the same ordered loop.
        let reason = fragment
            .statements()
            .iter()
            .enumerate()
            .map(|(i, s)| {
                format!(
                    "Statement {} / bytes {}..{} / Demo fixture only (no database classification)",
                    i + 1,
                    s.span().bytes().start,
                    s.span().bytes().end
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        let preview =
            cx.new(|cx| controls::sql_editor_state(fragment.source_sql().to_owned(), window, cx));
        let view = cx.entity().downgrade();
        let original = context.clone();
        let guard =
            controls::review_guard(view.clone(), move |w, cx| w.operation_valid(&original, cx));
        window.open_dialog(cx, move |dialog, _, cx| {
            let cancel = view.clone();
            let cancelled = context.clone();
            let key_cancel = view.clone();
            let key_context = context.clone();
            let escape_cancel = view.clone();
            let escape_context = context.clone();
            let accept = view.clone();
            let approved = context.clone();
            let fragment = fragment.clone();
            let input_cancel = view.clone();
            let input_context = context.clone();
            dialog
                .title("Review entire demo script")
                .accessibility_label("Review entire demo script")
                .w(px(760.))
                .overlay_closable(false)
                .close_button(false)
                .on_ok(move |_, _, cx| {
                    _ = key_cancel.update(cx, |this, cx| this.finish_cancelled(&key_context, cx));
                    true
                })
                .on_cancel(move |_, _, cx| {
                    _ = escape_cancel
                        .update(cx, |this, cx| this.finish_cancelled(&escape_context, cx));
                    true
                })
                .child(
                    "Demo fixtures only. Return and Escape cancel. No SQL is sent to a database.",
                )
                .child(
                    div()
                        .id("demo-script-classification")
                        .max_h(px(100.))
                        .overflow_y_scroll()
                        .child(reason.clone()),
                )
                .child(
                    div()
                        .capture_key_down(move |event, window, cx| {
                            if matches!(event.keystroke.key.as_str(), "enter" | "escape") {
                                cx.stop_propagation();
                                window.close_dialog(cx);
                                _ = input_cancel.update(cx, |this, cx| {
                                    this.finish_cancelled(&input_context, cx)
                                });
                            }
                        })
                        .child(
                            controls::preview_editor(&preview, cx)
                                .accessibility_guard(guard.clone())
                                .accessibility_id("dbeer-sql-batch-review")
                                .readonly(true)
                                .h(px(260.)),
                        ),
                )
                .footer(
                    div()
                        .flex()
                        .gap_2()
                        .justify_end()
                        .child(Button::new("cancel-execution").label("Cancel").on_click(
                            move |_, window, cx| {
                                window.close_dialog(cx);
                                _ = cancel
                                    .update(cx, |this, cx| this.finish_cancelled(&cancelled, cx));
                            },
                        ))
                        .child(
                            Button::new("confirm-execution")
                                .label("Run Reviewed Demo Script")
                                .on_click(move |_, window, cx| {
                                    window.close_dialog(cx);
                                    _ = accept.update(cx, |this, cx| {
                                        if this.operation_valid(&approved, cx) {
                                            this.execute_demo_batch(
                                                approved.clone(),
                                                fragment.clone(),
                                                window,
                                                cx,
                                            );
                                        } else {
                                            this.finish_cancelled(&approved, cx);
                                        }
                                    });
                                }),
                        ),
                )
        });
    }

    fn execute_demo_batch(
        &mut self,
        context: OperationContext,
        fragment: std::sync::Arc<sql::PreparedFragment>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let id = context.document;
        let Some(tab) = self
            .tabs
            .iter_mut()
            .find(|t| t.id == id && t.owns(&context))
        else {
            return;
        };
        tab.status = "Running demo query...".into();
        if let Some(profile) = self.profiles.iter_mut().find(|p| p.id == context.profile) {
            profile.loaded = true;
        }
        self.tabs.iter_mut().find(|t| t.id == id).unwrap().task =
            Some(cx.spawn_in(window, async move |view, cx| {
                for (index, statement) in fragment.statements().iter().enumerate() {
                    let proceed = view
                        .update_in(cx, |this, _, cx| {
                            if !this.operation_valid(&context, cx) {
                                this.finish_cancelled(&context, cx);
                                return false;
                            }
                            let tab = this.tabs.iter_mut().find(|t| t.id == id).unwrap();
                            tab.active_execution = index;
                            tab.started(&context, format!("demo-{}-{index}", context.operation));
                            tab.execution_decoration.set(
                                vec![gpui_kit::component::input::RangeDecoration::new(
                                    statement.span().bytes(),
                                )],
                                cx,
                            );
                            cx.notify();
                            true
                        })
                        .unwrap_or(false);
                    if !proceed {
                        return;
                    }
                    cx.background_executor()
                        .timer(Duration::from_millis(450))
                        .await;
                    let finished = view
                        .update_in(cx, |this, window, cx| {
                            if !this.operation_valid(&context, cx) {
                                this.finish_cancelled(&context, cx);
                                return true;
                            }
                            match execute_fixture(statement.sql()) {
                                Ok(result) => {
                                    let set = scripts::demo_result(result);
                                    let outcome = backend::QueryOutcome {
                                        row_count: set.row_count,
                                        result_sets: vec![set],
                                        duration_ms: 450.,
                                        transaction_status: backend::TransactionStatus::Idle,
                                        command_tag: "DEMO SELECT".into(),
                                        truncated: false,
                                        display_notice: "Demo fixture".into(),
                                        export: None,
                                    };
                                    this.record_live_statement(&context, outcome, window, cx);
                                    if index + 1 == fragment.statements().len() {
                                        this.end_live_batch(&context, window, cx);
                                        true
                                    } else {
                                        false
                                    }
                                }
                                Err(message) => {
                                    this.fail_live(
                                        &context,
                                        backend::BackendError {
                                            message,
                                            category: "demo".into(),
                                            connected: true,
                                            outcome_unknown: false,
                                            sql_completed: false,
                                            sql_not_executed: false,
                                            export_publication: None,
                                            transaction_status: Some(
                                                backend::TransactionStatus::Idle,
                                            ),
                                            sql_state: None,
                                            error_position: None,
                                            result_sets: Vec::new(),
                                        },
                                        window,
                                        cx,
                                    );
                                    true
                                }
                            }
                        })
                        .unwrap_or(true);
                    if finished {
                        return;
                    }
                }
            }));
        cx.notify();
    }

    #[cfg(feature = "native-smoke")]
    pub(super) fn stop_query(&mut self, cx: &mut Context<Self>) {
        if let Some(tab) = self.tabs.get(self.active) {
            self.stop_document(tab.id, cx);
        }
    }

    pub(super) fn stop_document(&mut self, id: DocumentId, cx: &mut Context<Self>) {
        if self.stop_run_file_preparation(id, cx) {
            return;
        }

        if self.stop_changes_preview(id, cx) {
            return;
        }
        let Some(index) = self.tabs.iter().position(|t| t.id == id) else {
            return;
        };
        if self.profile(&self.tabs[index].profile).config.is_some() {
            self.stop_live(id, cx);
            return;
        }
        let tab = &mut self.tabs[index];
        if tab.task.take().is_some() {
            let cancelled = tab.operation.clone();
            if let Some(context) = &cancelled {
                tab.stop_requested = true;
                tab.end(context, model::ExecutionState::Cancelled, 0);
            }
            tab.execution_decoration.clear(cx);
            tab.status = "Demo query cancelled.".into();
            if let Some(context) = cancelled {
                self.record_statement_history(&context, "Query cancelled", cx);
            }
            cx.notify();
        }
    }

    pub(super) fn disconnect(&mut self, profile: usize, cx: &mut Context<Self>) {
        if self.run_file.is_some() {
            return;
        }

        self.profiles[profile].loaded = false;
        for tab in &mut self.tabs {
            if tab.profile == self.profiles[profile].id {
                tab.task = None;
                if let Some(context) = tab.operation.clone() {
                    tab.end(&context, model::ExecutionState::Cancelled, 0);
                }
                tab.retire_grid_contexts(cx);
                tab.grid = None;
                tab.error = false;
                tab.status = "Demo disconnected. Run to load fixtures again.".into();
            }
        }
        cx.notify();
    }
}
