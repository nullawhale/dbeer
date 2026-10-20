//! Prepared integration cases. Execution is deferred until final integration.
use super::{PendingSave, SaveResult, State};
use crate::{
    ProfileStore,
    appearance::{self, AppearanceStore, Preferences, SaveOutcome, Scheme, StoreError},
    settings_view::PersistenceState,
};
use gpui_kit::WindowAppearance;
use std::{
    fs,
    path::PathBuf,
    sync::{Arc, Mutex},
};

struct Fixture {
    root: PathBuf,
    store: ProfileStore,
}
impl Fixture {
    fn new() -> Self {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/gpui/appearance-workspace-tests")
            .join(uuid::Uuid::new_v4().to_string());
        let store = ProfileStore::acquire(root.join("connections.json")).unwrap();
        Self { root, store }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn settled(revision: u64, result: SaveResult) -> PendingSave {
    let (sender, done) = async_channel::bounded(1);
    drop(sender);
    PendingSave {
        revision,
        result: Arc::new(Mutex::new(Some(result))),
        done,
    }
}

#[test]
fn startup_loads_normalized_imports_before_saved_selectors_without_source_files() {
    let f = Fixture::new();
    let mut theme = appearance::Theme::native(Scheme::Dark);
    theme.id = format!("imported-{}", uuid::Uuid::new_v4());
    theme.name = "Retained imported colors".into();
    theme.is_imported = true;
    fs::write(
        f.root.join("themes.json"),
        serde_json::to_vec(&serde_json::json!({"version":1,"themes":[theme]})).unwrap(),
    )
    .unwrap();
    let store = AppearanceStore::new(f.store.data_owner());
    store.load().unwrap();
    let preferences = Preferences {
        application_color_theme: theme.id.clone(),
        editor_color_theme: "jetbrains-light".into(),
        ..Preferences::default()
    };
    assert_eq!(
        store.reserve(preferences.clone()).commit(),
        Ok(SaveOutcome::Published)
    );
    for os in [WindowAppearance::Light, WindowAppearance::Dark] {
        let state = State::load(Some(&f.store), os);
        assert_eq!(state.themes.len(), 9);
        assert_eq!(state.preferences, preferences);
        assert_eq!(
            state.resolved.application_theme_id.as_deref(),
            Some(theme.id.as_str())
        );
        assert_eq!(state.resolved.editor_theme_id, "jetbrains-light");
        assert_eq!(state.persistence, PersistenceState::Saved);
        assert!(state.library_error.is_none());
    }
    assert!(!f.root.join("sql-documents.json").exists());
}

#[test]
fn missing_ids_and_corrupt_preferences_or_library_are_retained_without_close_trap() {
    let f = Fixture::new();
    let preferences = Preferences {
        application_color_theme: "imported-unavailable".into(),
        editor_color_theme: "future-scheme".into(),
        ..Preferences::default()
    };
    let store = AppearanceStore::new(f.store.data_owner());
    store.load().unwrap();
    store.reserve(preferences.clone()).commit().unwrap();
    fs::write(f.root.join("themes.json"), b"{\"version\":999}").unwrap();
    let state = State::load(Some(&f.store), WindowAppearance::Dark);
    assert_eq!(state.preferences, preferences);
    assert!(state.library_error.is_some());
    assert!(state.themes.iter().any(|t| t.id == "native-light"));
    assert!(
        state
            .presentation()
            .application_choices()
            .iter()
            .any(|c| c.id() == "imported-unavailable" && !c.available())
    );
    for bytes in [
        b"{broken".as_slice(),
        b"{\"version\":999}".as_slice(),
        b"{\"version\":1,\"version\":1}".as_slice(),
    ] {
        fs::write(f.root.join("appearance.json"), bytes).unwrap();
        let mut state = State::load(Some(&f.store), WindowAppearance::Light);
        assert!(!state.writable);
        assert_eq!(state.persistence, PersistenceState::ReadOnlyFallback);
        assert!(smol::block_on(state.finalization().future).is_ok());
        // In-memory preview remains explicitly unsavable and is never reserved.
        state
            .preferences
            .choose_editor("native-dark", &state.themes);
        state.advance();
        assert!(state.pending.is_none());
        assert!(smol::block_on(state.finalization().future).is_ok());
        assert_eq!(fs::read(f.root.join("appearance.json")).unwrap(), bytes);
    }
}

#[test]
fn exact_publication_is_broadcast_and_superseded_or_failed_is_never_close_success() {
    let f = Fixture::new();
    let mut state = State::load(Some(&f.store), WindowAppearance::Dark);
    for result in [
        Ok(SaveOutcome::Superseded),
        Err(StoreError::Write),
        Err(StoreError::Conflict),
    ] {
        state.pending = Some(settled(state.revision, result));
        assert!(smol::block_on(state.finalization().future).is_err());
    }
    state.pending = Some(settled(state.revision, Ok(SaveOutcome::Published)));
    assert!(smol::block_on(state.pending.as_ref().unwrap().wait()).is_ok());
    assert!(smol::block_on(state.finalization().future).is_ok());
    let old = state.finalization();
    state.advance();
    assert_ne!(old.revision, state.revision);
    assert!(smol::block_on(state.finalization().future).is_err());
    state.pending = Some(settled(state.revision, Ok(SaveOutcome::Published)));
    assert!(smol::block_on(state.finalization().future).is_ok());
    state.revision = u64::MAX;
    assert!(!state.advance());
    state.revision = 0;
    state.presentation_revision = u64::MAX;
    assert!(!state.advance());
}

#[cfg(feature = "native-smoke")]
mod retained {
    use super::*;
    use crate::{
        CloseIntent, CommandId, CommandOrigin, DemoTable, ResultGrid, Workspace, demo,
        grid_selection, platform,
        settings_view::{SettingsAction, SettingsEvent},
    };
    use gpui_kit::{
        AnyWindowHandle, AppContext, Context, Entity, Focusable, TestAppContext, Window,
        WindowOptions, point, px,
    };
    use gpui_kit::{
        component::{WindowExt, table::TableState},
        test::{TestAppContextExt, TestWindowExt},
    };
    use std::time::Duration;

    fn event(
        this: &mut Workspace,
        action: SettingsAction,
        window: &mut Window,
        cx: &mut Context<Workspace>,
    ) {
        let owner = this.appearance.dialog.as_ref().unwrap().view.entity_id();
        let event = SettingsEvent {
            revision: this.appearance.presentation_revision,
            action,
        };
        this.appearance_event(owner, &event, window, cx);
    }
    fn workspace(f: &Fixture, cx: &mut TestAppContext) -> (AnyWindowHandle, Entity<Workspace>) {
        let result = cx.update(|cx| {
            gpui_kit::init(cx);
            gpui_kit::open_window(WindowOptions::default(), cx, |window, cx| {
                cx.new(|cx| {
                    Workspace::new(
                        Some(f.store.clone()),
                        crate::product_identity::StartupPolicy::new(
                            crate::product_identity::Platform::MacDevelopment,
                            true,
                        ),
                        window,
                        cx,
                    )
                })
            })
            .unwrap()
        });
        crate::workspace_tests::prepare_test_window(cx, result.0);
        result
    }

    #[gpui::test]
    fn common_settings_live_choices_keep_sql_grid_running_owner_focus_and_undo(
        cx: &mut TestAppContext,
    ) {
        let (handle, view) = crate::workspace_tests::workspace(cx);
        cx.update_window(handle, |_, window, cx| {
            let editor = view.read(cx).tabs[0].editor.clone();
            editor.update(cx, |state, cx| {
                state.set_value(
                    (0..90)
                        .map(|i| format!("SELECT {i};\n"))
                        .collect::<String>(),
                    window,
                    cx,
                );
                state.set_selected_range(0..0, cx);
                state.focus(window, cx);
            });
            window.render_frame(cx);
            cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(
                "-- appearance edit\n".into(),
            ));
            window.press(&crate::platform::binding("v"), cx);
            editor.update(cx, |state, cx| {
                state.set_selected_range(4..10, cx);
                state.set_scroll_offset(point(px(-10.), px(-80.)), cx);
            });
            window.render_frame(cx);
            let source = editor.read(cx).value();
            let selection = editor.read(cx).selected_range();
            let scroll = editor.read(cx).scroll_offset();
            let native_revision = editor.read(cx).accessibility_document_revision();
            let mut grid = ResultGrid::new(demo::QueryResult {
                columns: DemoTable::Products.columns(),
                rows: DemoTable::Products.rows(),
            });
            grid.selection.select(
                &[1, 2],
                grid_selection::CellPoint { row: 2, column: 1 },
                false,
                false,
                7,
            );
            let selected = grid.selection.clone();
            let grid = cx.new(|cx| TableState::new(grid, window, cx));
            view.update(cx, |this, cx| {
                this.tabs[0].grid = Some(grid.clone());
                let context = this.tabs[0].begin(None, source.len()).unwrap();
                let context = this.tabs[0]
                    .attach(&context, "synthetic-appearance-session".into())
                    .unwrap();
                this.tabs[0].started(&context, "synthetic-appearance-query".into());
                this.command(CommandId::Appearance, CommandOrigin::Menu, None, window, cx);
                assert!(this.appearance.dialog.is_some());
                let settings = this.appearance.dialog.as_ref().unwrap().view.clone();
                let first_revision = this.appearance.presentation_revision;
                let original_owner = settings.entity_id();
                for (app, sql) in [
                    ("dark", "native-light"),
                    ("solarized-light", "jetbrains-darcula"),
                    ("system", "automatic"),
                ] {
                    event(
                        this,
                        SettingsAction::ChooseApplication(app.into()),
                        window,
                        cx,
                    );
                    event(this, SettingsAction::ChooseEditor(sql.into()), window, cx);
                    assert_eq!(
                        this.appearance.dialog.as_ref().unwrap().view.entity_id(),
                        original_owner
                    );
                    assert_eq!(this.tabs[0].editor, editor);
                    assert_eq!(this.tabs[0].grid.as_ref(), Some(&grid));
                    assert!(this.tabs[0].owns(&context) && this.tabs[0].busy());
                    assert_eq!(
                        this.tabs[0].query_id.as_deref(),
                        Some("synthetic-appearance-query")
                    );
                    assert_eq!(this.editor_palette(cx), this.appearance.resolved.editor);
                }
                let preferences = this.appearance.preferences.clone();
                this.appearance_event(
                    original_owner,
                    &SettingsEvent {
                        revision: first_revision,
                        action: SettingsAction::ChooseEditor("native-light".into()),
                    },
                    window,
                    cx,
                );
                assert_eq!(this.appearance.preferences, preferences);
                let revision = this.appearance.revision;
                let saved = this.appearance.preferences.clone();
                this.system_appearance_changed(WindowAppearance::Light, window, cx);
                assert_eq!(this.appearance.resolved.application_scheme, Scheme::Light);
                this.system_appearance_changed(WindowAppearance::Dark, window, cx);
                assert_eq!(this.appearance.resolved.application_scheme, Scheme::Dark);
                assert_eq!(this.appearance.revision, revision);
                assert_eq!(this.appearance.preferences, saved);
                assert!(this.appearance.pending.is_none());
                // A named application palette survives the toolkit refresh too.
                event(
                    this,
                    SettingsAction::ChooseApplication("solarized-light".into()),
                    window,
                    cx,
                );
                this.system_appearance_changed(WindowAppearance::Dark, window, cx);
                assert_eq!(
                    this.appearance.resolved.application_theme_id.as_deref(),
                    Some("solarized-light")
                );
                event(this, SettingsAction::Close, window, cx);
                assert!(editor.focus_handle(cx).is_focused(window));
                this.appearance_event(
                    original_owner,
                    &SettingsEvent {
                        revision: this.appearance.presentation_revision,
                        action: SettingsAction::ChooseApplication("dark".into()),
                    },
                    window,
                    cx,
                );
                assert_eq!(
                    this.appearance.preferences.application_color_theme,
                    "solarized-light"
                );
                this.tabs[0].phase = None;
                this.tabs[0].operation = None;
            });
            window.render_frame(cx);
            assert_eq!(editor.read(cx).value(), source);
            assert_eq!(editor.read(cx).selected_range(), selection);
            assert_eq!(editor.read(cx).scroll_offset(), scroll);
            assert_eq!(
                editor.read(cx).accessibility_document_revision(),
                native_revision
            );
            assert_eq!(
                editor.read(cx).explicit_editor_style().unwrap().background,
                view.read(cx).appearance.resolved.editor.background.hsla()
            );
            assert_eq!(grid.read(cx).delegate().selection, selected);
            window.press(&platform::binding("z"), cx);
            assert!(!editor.read(cx).value().starts_with("-- appearance edit"));
            assert!(view.read(cx).backend.is_none());
        })
        .unwrap();
    }

    #[gpui::test]
    async fn real_workspace_reserves_latest_restart_failed_retry_and_explicit_reload(
        cx: &mut TestAppContext,
    ) {
        let f = Fixture::new();
        let (handle, view) = workspace(&f, cx);
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.command(CommandId::Appearance, CommandOrigin::Menu, None, window, cx);
                event(
                    this,
                    SettingsAction::ChooseApplication("solarized-dark".into()),
                    window,
                    cx,
                );
                event(
                    this,
                    SettingsAction::ChooseEditor("jetbrains-light".into()),
                    window,
                    cx,
                );
                assert_eq!(
                    this.appearance.pending.as_ref().unwrap().revision,
                    this.appearance.revision
                );
            });
        })
        .unwrap();
        cx.wait_for(handle, Duration::from_secs(5), |_, cx| {
            view.read(cx).appearance.persistence == PersistenceState::Saved
        })
        .await;
        let restarted = State::load(Some(&f.store), WindowAppearance::Light);
        assert_eq!(
            restarted.preferences.application_color_theme,
            "solarized-dark"
        );
        assert_eq!(restarted.preferences.editor_color_theme, "jetbrains-light");
        assert_eq!(restarted.resolved.application_scheme, Scheme::Dark);
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.appearance
                    .store
                    .as_ref()
                    .unwrap()
                    .fail_replacement(true);
                event(
                    this,
                    SettingsAction::ChooseEditor("native-dark".into()),
                    window,
                    cx,
                );
            });
        })
        .unwrap();
        cx.wait_for(handle, Duration::from_secs(5), |_, cx| {
            view.read(cx).appearance.persistence == PersistenceState::SaveFailed(StoreError::Write)
        })
        .await;
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                assert!(smol::block_on(this.appearance.finalization().future).is_err());
                this.appearance
                    .store
                    .as_ref()
                    .unwrap()
                    .fail_replacement(false);
                event(this, SettingsAction::RetrySave, window, cx);
            });
        })
        .unwrap();
        cx.wait_for(handle, Duration::from_secs(5), |_, cx| {
            view.read(cx).appearance.persistence == PersistenceState::Saved
        })
        .await;
        fs::write(
            f.root.join("appearance.json"),
            serde_json::to_vec(&Preferences::default()).unwrap(),
        )
        .unwrap();
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                event(
                    this,
                    SettingsAction::ChooseEditor("native-light".into()),
                    window,
                    cx,
                )
            });
        })
        .unwrap();
        cx.wait_for(handle, Duration::from_secs(5), |_, cx| {
            view.read(cx).appearance.persistence
                == PersistenceState::SaveFailed(StoreError::Conflict)
        })
        .await;
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                event(this, SettingsAction::Reload, window, cx)
            });
        })
        .unwrap();
        cx.wait_for(handle, Duration::from_secs(5), |_, cx| {
            view.read(cx).appearance.persistence == PersistenceState::Saved
        })
        .await;
        cx.update(|cx| {
            assert_eq!(view.read(cx).appearance.preferences, Preferences::default());
            assert!(smol::block_on(view.read(cx).appearance.finalization().future).is_ok());
        });
    }

    #[gpui::test]
    fn normal_close_awaits_latest_actual_participant_and_stale_failure_cannot_refuse_it(
        cx: &mut TestAppContext,
    ) {
        let (handle, view) = crate::workspace_tests::workspace(cx);
        let (first_sender, first_done) = async_channel::bounded(1);
        let (latest_sender, latest_done) = async_channel::bounded(1);
        let (id, sibling, token) = cx
            .update_window(handle, |_, window, cx| {
                view.update(cx, |this, cx| {
                    this.appearance.revision = 1;
                    this.appearance.pending = Some(PendingSave {
                        revision: 1,
                        result: Arc::new(Mutex::new(Some(Err(StoreError::Write)))),
                        done: first_done,
                    });
                    let id = this.tabs[0].id;
                    this.add_sql_tab("Independent.sql".into(), "SELECT 2;".into(), window, cx);
                    let sibling = this.tabs[1].id;
                    this.request_close(CloseIntent::Tab(id), window, cx);
                    (id, sibling, this.close_flow.as_ref().unwrap().token)
                })
            })
            .unwrap();
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            this.appearance
                .pending
                .as_ref()
                .is_some_and(|pending| pending.revision == 1 && pending.done.receiver_count() > 1)
        });
        cx.update(|cx| assert!(view.read(cx).tabs.iter().any(|t| t.id == id)));
        cx.update_window(handle, |_, _, cx| {
            view.update(cx, |this, _| {
                // Model a newer already-accepted reservation arriving while the
                // old finalizer is awaiting its completion, without database IO.
                this.appearance.revision = 2;
                this.appearance.pending = Some(PendingSave {
                    revision: 2,
                    result: Arc::new(Mutex::new(Some(Ok(SaveOutcome::Published)))),
                    done: latest_done,
                });
            });
        })
        .unwrap();
        drop(first_sender);
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            this.appearance
                .pending
                .as_ref()
                .is_some_and(|pending| pending.revision == 2 && pending.done.receiver_count() > 1)
        });
        cx.update(|cx| {
            assert!(view.read(cx).tabs.iter().any(|t| t.id == id));
            assert!(
                view.read(cx).closing,
                "An obsolete failure refused the latest owner."
            );
            assert_eq!(view.read(cx).close_flow.as_ref().unwrap().token, token);
            assert!(view.read(cx).tabs.iter().any(|t| t.id == sibling));
        });
        drop(latest_sender);
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            this.tabs.iter().all(|tab| tab.id != id)
        });
        cx.update(|cx| {
            assert!(view.read(cx).tabs.iter().all(|t| t.id != id));
            assert!(view.read(cx).tabs.iter().any(|t| t.id == sibling));
        });
    }
    #[gpui::test]
    async fn corrupt_startup_preview_only_close_and_explicit_repair(cx: &mut TestAppContext) {
        let f = Fixture::new();
        let bytes = b"{preserve original unreadable appearance";
        fs::write(f.root.join("appearance.json"), bytes).unwrap();
        let (handle, view) = workspace(&f, cx);
        let id = cx
            .update_window(handle, |_, window, cx| {
                view.update(cx, |this, cx| {
                    let id = this.tabs[0].id;
                    this.command(CommandId::Appearance, CommandOrigin::Menu, None, window, cx);
                    event(
                        this,
                        SettingsAction::ChooseEditor("native-dark".into()),
                        window,
                        cx,
                    );
                    assert_eq!(
                        this.appearance.persistence,
                        PersistenceState::ReadOnlyFallback
                    );
                    assert!(this.appearance.pending.is_none());
                    event(this, SettingsAction::Close, window, cx);
                    this.request_close(CloseIntent::Tab(id), window, cx);
                    id
                })
            })
            .unwrap();
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            this.tabs.iter().all(|tab| tab.id != id)
        });
        cx.update(|cx| assert!(view.read(cx).tabs.iter().all(|t| t.id != id)));
        assert_eq!(fs::read(f.root.join("appearance.json")).unwrap(), bytes);
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.command(CommandId::Appearance, CommandOrigin::Menu, None, window, cx);
                // External repair alone never grants in-memory write authority.
                fs::write(
                    f.root.join("appearance.json"),
                    serde_json::to_vec(&Preferences::default()).unwrap(),
                )
                .unwrap();
                event(
                    this,
                    SettingsAction::ChooseApplication("dark".into()),
                    window,
                    cx,
                );
                assert!(!this.appearance.writable && this.appearance.pending.is_none());
                event(this, SettingsAction::Reload, window, cx);
            });
        })
        .unwrap();
        cx.wait_for(handle, Duration::from_secs(5), |_, cx| {
            view.read(cx).appearance.persistence == PersistenceState::Saved
        })
        .await;
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                assert_eq!(this.appearance.preferences, Preferences::default());
                event(
                    this,
                    SettingsAction::ChooseEditor("jetbrains-light".into()),
                    window,
                    cx,
                );
            });
        })
        .unwrap();
        cx.wait_for(handle, Duration::from_secs(5), |_, cx| {
            view.read(cx).appearance.persistence == PersistenceState::Saved
        })
        .await;
        assert_eq!(
            State::load(Some(&f.store), WindowAppearance::Dark)
                .preferences
                .editor_color_theme,
            "jetbrains-light"
        );
    }
    #[gpui::test]
    fn latest_close_error_preserves_scope_and_retry_keeps_original_editor(cx: &mut TestAppContext) {
        let (handle, view) = crate::workspace_tests::workspace(cx);
        let (id, sibling, token, editor, text) = cx
            .update_window(handle, |_, window, cx| {
                view.update(cx, |this, cx| {
                    let id = this.tabs[0].id;
                    let editor = this.tabs[0].editor.clone();
                    let text = editor.read(cx).value();
                    this.add_sql_tab("Independent.sql".into(), "SELECT 2;".into(), window, cx);
                    let sibling = this.tabs[1].id;
                    this.appearance.revision = 1;
                    this.appearance.pending = Some(settled(1, Err(StoreError::Write)));
                    this.request_close(CloseIntent::Tab(id), window, cx);
                    (
                        id,
                        sibling,
                        this.close_flow.as_ref().unwrap().token,
                        editor,
                        text,
                    )
                })
            })
            .unwrap();
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            !this.closing && this.close_flow.is_none()
        });
        cx.update_window(handle, |_, window, cx| {
            assert!(!view.read(cx).closing);
            assert!(view.read(cx).close_flow.is_none());
            assert!(
                window.has_active_dialog(cx),
                "Latest error must remain a visible close refusal."
            );
            assert!(
                view.read(cx)
                    .tabs
                    .iter()
                    .any(|t| t.id == id && t.editor == editor)
            );
            assert_eq!(editor.read(cx).value(), text);
            assert!(view.read(cx).tabs.iter().any(|t| t.id == sibling));
            window.close_dialog(cx);
            view.update(cx, |this, cx| {
                this.appearance.revision = 2;
                this.appearance.pending = Some(settled(2, Ok(SaveOutcome::Published)));
                this.request_close(CloseIntent::Tab(id), window, cx);
                assert_ne!(this.close_flow.as_ref().unwrap().token, token);
            });
        })
        .unwrap();
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            this.tabs.iter().all(|tab| tab.id != id)
        });
        cx.update(|cx| {
            assert!(view.read(cx).tabs.iter().all(|t| t.id != id));
            assert!(view.read(cx).tabs.iter().any(|t| t.id == sibling));
        });
    }
}
