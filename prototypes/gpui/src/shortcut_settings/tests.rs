//! Prepared production integration cases; runtime is deferred to final integration.
use super::State;
use crate::{
    ProfileStore,
    shortcut_settings_view::{self, PersistenceState},
    shortcuts::{ConfigurableCommand, Preferences},
};
use std::{fs, path::PathBuf};
struct Fixture {
    root: PathBuf,
    store: ProfileStore,
}
impl Fixture {
    fn new() -> Self {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/gpui/shortcut-workspace-tests")
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
#[test]
fn startup_clear_reset_and_corrupt_fallback_preserve_original_owner_and_close_authority() {
    let f = Fixture::new();
    let state = State::load(Some(&f.store));
    assert_eq!(state.persistence, PersistenceState::Saved);
    let store = state.store.clone().unwrap();
    let mut cleared = state.preferences;
    cleared
        .clear(ConfigurableCommand::RunCurrent, state.platform)
        .unwrap();
    store
        .reserve(cleared.clone(), state.platform)
        .unwrap()
        .commit()
        .unwrap();
    let restarted = State::load(Some(&f.store));
    assert_eq!(restarted.preferences, cleared);
    assert!(
        restarted
            .preferences
            .shortcut(ConfigurableCommand::RunCurrent, state.platform)
            .is_none()
    );
    let mut defaults = restarted.preferences;
    defaults.reset_defaults();
    restarted
        .store
        .unwrap()
        .reserve(defaults.clone(), state.platform)
        .unwrap()
        .commit()
        .unwrap();
    assert_eq!(State::load(Some(&f.store)).preferences, defaults);
    let original = b"{\"version\":999}";
    fs::write(f.root.join("shortcuts.json"), original).unwrap();
    let readonly = State::load(Some(&f.store));
    assert!(matches!(
        readonly.persistence,
        PersistenceState::ReadOnlyFallback(_)
    ));
    assert!(!readonly.dirty && readonly.pending.is_none());
    assert_eq!(fs::read(f.root.join("shortcuts.json")).unwrap(), original);
    assert!(
        readonly
            .store
            .as_ref()
            .unwrap()
            .recover_defaults(state.platform)
            .is_ok()
    );
    let recovered = State::load(Some(&f.store));
    assert_eq!(recovered.persistence, PersistenceState::Saved);
    let backups = fs::read_dir(&f.root)
        .unwrap()
        .flatten()
        .filter(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with("shortcuts-recovery-")
        })
        .collect::<Vec<_>>();
    assert_eq!(backups.len(), 1);
    assert_eq!(fs::read(backups[0].path()).unwrap(), original);
    assert!(!f.root.join("sql-documents.json").exists());
}
#[test]
fn disposable_is_explicit_preview_and_revision_exhaustion_refuses_mutation() {
    let mut state = State::load(None);
    assert_eq!(state.persistence, PersistenceState::PreviewOnly);
    assert!(!state.presentation().persistence().can_reload());
    assert!(state.presentation().persistence().can_edit());
    state.revision = u64::MAX;
    assert!(!state.advance());
    assert!(!state.dirty);
}
#[test]
fn fixed_conflicts_and_candidate_only_preferences_cannot_start_backend_work() {
    let state = State::load(None);
    for edit in [
        shortcut_settings_view::Edit::Clear(ConfigurableCommand::RunCurrent),
        shortcut_settings_view::Edit::ResetAll,
    ] {
        let _candidate = state.presentation().candidate(&edit).unwrap();
        assert_eq!(state.preferences, Preferences::default());
        assert!(state.pending.is_none());
    }
}

#[test]
fn actual_latest_reservation_and_readonly_finalizers_have_distinct_close_obligations() {
    use super::{Completion, PendingSave};
    use crate::shortcuts::SaveOutcome;
    let f = Fixture::new();
    let mut state = State::load(Some(&f.store));
    assert!(smol::block_on(state.finalization().future).is_ok());
    let store = state.store.as_ref().unwrap();
    let first = store
        .reserve(state.preferences.clone(), state.platform)
        .unwrap();
    state
        .preferences
        .clear(ConfigurableCommand::RunCurrent, state.platform)
        .unwrap();
    let latest = store
        .reserve(state.preferences.clone(), state.platform)
        .unwrap();
    let (completion, sender) = Completion::new();
    completion.finish(first.commit());
    drop(sender);
    state.dirty = true;
    state.revision = 1;
    state.pending = Some(PendingSave {
        revision: 1,
        reservation: 1,
        completion,
    });
    assert!(smol::block_on(state.finalization().future).is_err());
    let (completion, sender) = Completion::new();
    assert_eq!(latest.commit(), Ok(SaveOutcome::Published));
    completion.finish(Ok(SaveOutcome::Published));
    drop(sender);
    state.revision = 2;
    state.pending = Some(PendingSave {
        revision: 2,
        reservation: 2,
        completion,
    });
    assert!(smol::block_on(state.finalization().future).is_ok());
    assert_eq!(State::load(Some(&f.store)).preferences, state.preferences);
}

#[test]
fn faulted_actual_shortcut_publication_cannot_complete_normal_close_finalization() {
    use super::{Completion, PendingSave};
    use crate::shortcuts::{SaveOutcome, StoreError};
    for replace in [true, false] {
        let fixture = Fixture::new();
        let mut state = State::load(Some(&fixture.store));
        let store = state.store.clone().unwrap();
        store
            .reserve(state.preferences.clone(), state.platform)
            .unwrap()
            .commit()
            .unwrap();
        let before = fs::read(fixture.root.join("shortcuts.json")).unwrap();
        state
            .preferences
            .clear(ConfigurableCommand::RunCurrent, state.platform)
            .unwrap();
        let request = store
            .reserve(state.preferences.clone(), state.platform)
            .unwrap();
        let reservation = request.revision();
        let mut temporary = PathBuf::new();
        let foreign = b"foreign close shortcut staging";
        let result = request.commit_with(|prepared| {
            temporary = prepared.temporary_path().to_path_buf();
            if replace {
                fs::rename(&temporary, fixture.root.join("retained-close.tmp")).unwrap();
            }
            fs::write(&temporary, foreign).unwrap();
        });
        assert_eq!(result, Err(StoreError::Write));
        let (completion, sender) = Completion::new();
        completion.finish(result);
        drop(sender);
        state.dirty = true;
        state.revision = 1;
        state.pending = Some(PendingSave {
            revision: 1,
            reservation,
            completion,
        });
        assert!(smol::block_on(state.finalization().future).is_err());
        assert!(!store.latest_saved());
        assert_eq!(
            fs::read(fixture.root.join("shortcuts.json")).unwrap(),
            before
        );
        if replace {
            assert_eq!(fs::read(&temporary).unwrap(), foreign);
        }
        let latest = store
            .reserve(state.preferences.clone(), state.platform)
            .unwrap();
        let reservation = latest.revision();
        let (completion, sender) = Completion::new();
        let result = latest.commit();
        assert_eq!(result, Ok(SaveOutcome::Published));
        completion.finish(result);
        drop(sender);
        state.revision = 2;
        state.pending = Some(PendingSave {
            revision: 2,
            reservation,
            completion,
        });
        assert!(smol::block_on(state.finalization().future).is_ok());
        assert_eq!(
            State::load(Some(&fixture.store)).preferences,
            state.preferences
        );
        if replace {
            assert_eq!(fs::read(temporary).unwrap(), foreign);
        }
    }
}

#[cfg(feature = "native-smoke")]
mod retained {
    use super::{Fixture, State};
    use crate::{
        CloseIntent, CommandId, CommandOrigin, Workspace,
        shortcut_settings::{Completion, PendingSave},
        shortcut_settings_view::{Action, Edit, PersistenceState},
        shortcuts::{
            ConfigurableCommand, Modifiers, Preferences, SaveOutcome, Shortcut, StoreError,
        },
    };
    use gpui_kit::{
        AnyWindowHandle, AppContext, Entity, EntityInputHandler, Focusable, KeyDownEvent,
        TestAppContext, WindowOptions, test::TestWindowExt,
    };
    use std::time::Duration;
    fn workspace(f: &Fixture, cx: &mut TestAppContext) -> (AnyWindowHandle, Entity<Workspace>) {
        let result = cx.update(|cx| {
            gpui_kit::init(cx);
            crate::commands::install_keys(cx);
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
    async fn shared_settings_real_requests_save_clear_restart_restore_and_reject_stale_owner(
        cx: &mut TestAppContext,
    ) {
        let f = Fixture::new();
        let (handle, view) = workspace(&f, cx);
        let original = cx
            .update_window(handle, |_, window, cx| {
                view.update(cx, |this, cx| {
                    let editor = this.tabs[0].editor.clone();
                    editor.focus_handle(cx).focus(window, cx);
                    this.command(
                        CommandId::ShortcutSettings,
                        CommandOrigin::Menu,
                        None,
                        window,
                        cx,
                    );
                    let dialog = this.appearance.dialog.as_ref().unwrap();
                    let section = dialog.shortcuts.clone();
                    let library = dialog.library.entity_id();
                    let settings = dialog.view.entity_id();
                    let event = section
                        .update(cx, |section, cx| {
                            section.test_request(
                                Action::Edit(Edit::Clear(ConfigurableCommand::RunCurrent)),
                                window,
                                cx,
                            )
                        })
                        .unwrap();
                    (editor, section, settings, library, event)
                })
            })
            .unwrap();
        cx.run_until_parked();
        for _ in 0..50 {
            if cx.update(|cx| view.read(cx).shortcuts.persistence == PersistenceState::Saved) {
                break;
            }
            cx.background_executor
                .timer(Duration::from_millis(10))
                .await;
            cx.run_until_parked();
        }
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                assert!(
                    this.shortcuts
                        .preferences
                        .shortcut(ConfigurableCommand::RunCurrent, this.shortcuts.platform)
                        .is_none()
                );
                assert_eq!(
                    this.command_label(CommandId::RunCurrent),
                    CommandId::RunCurrent.title()
                );
                assert_eq!(
                    State::load(Some(&f.store)).preferences,
                    this.shortcuts.preferences
                );
                let dialog = this.appearance.dialog.as_ref().unwrap();
                assert_eq!(dialog.view.entity_id(), original.2);
                assert_eq!(dialog.library.entity_id(), original.3);
                assert_eq!(this.tabs[0].editor, original.0);
                let snapshot = this.shortcuts.preferences.clone();
                this.shortcut_event(original.2, original.1.entity_id(), &original.4, window, cx);
                assert_eq!(this.shortcuts.preferences, snapshot);
                assert!(this.backend.is_none());
                original.1.update(cx, |section, cx| {
                    section.test_request(Action::Edit(Edit::ResetAll), window, cx);
                });
            });
        })
        .unwrap();
        cx.run_until_parked();
        for _ in 0..50 {
            if cx.update(|cx| view.read(cx).shortcuts.persistence == PersistenceState::Saved) {
                break;
            }
            cx.background_executor
                .timer(Duration::from_millis(10))
                .await;
            cx.run_until_parked();
        }
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                assert_eq!(this.shortcuts.preferences, Preferences::default());
                assert_eq!(
                    State::load(Some(&f.store)).preferences,
                    Preferences::default()
                );
                assert!(this.command_label(CommandId::RunCurrent).contains("Enter"));
                this.prepare_appearance_close(window, cx);
                assert!(original.0.focus_handle(cx).is_focused(window));
                this.shortcut_event(original.2, original.1.entity_id(), &original.4, window, cx);
                assert_eq!(this.shortcuts.preferences, Preferences::default());
                assert!(this.backend.is_none());
            });
        })
        .unwrap();
    }
    #[gpui::test]
    async fn explicit_recovery_and_reload_reconcile_original_request_after_settings_dismissal(
        cx: &mut TestAppContext,
    ) {
        let f = Fixture::new();
        let original = b"{preserve corrupt shortcut preferences";
        std::fs::write(f.root.join("shortcuts.json"), original).unwrap();
        let (handle, view) = workspace(&f, cx);
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                assert!(!this.shortcuts.dirty);
                assert!(this.shortcuts.presentation().persistence().can_recover());
                this.command(
                    CommandId::ShortcutSettings,
                    CommandOrigin::Menu,
                    None,
                    window,
                    cx,
                );
                let section = this.appearance.dialog.as_ref().unwrap().shortcuts.clone();
                section.update(cx, |section, cx| {
                    section.test_request(Action::RecoverDefaults, window, cx);
                });
            });
        })
        .unwrap();
        cx.run_until_parked();
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| this.prepare_appearance_close(window, cx));
        })
        .unwrap();
        for _ in 0..50 {
            if cx.update(|cx| view.read(cx).shortcuts.persistence == PersistenceState::Saved) {
                break;
            }
            cx.background_executor
                .timer(Duration::from_millis(10))
                .await;
            cx.run_until_parked();
        }
        cx.update(|cx| {
            assert_eq!(view.read(cx).shortcuts.persistence, PersistenceState::Saved);
            assert_eq!(view.read(cx).shortcuts.preferences, Preferences::default());
            assert!(view.read(cx).backend.is_none());
        });
        let backups = std::fs::read_dir(&f.root)
            .unwrap()
            .flatten()
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("shortcuts-recovery-")
            })
            .collect::<Vec<_>>();
        assert_eq!(backups.len(), 1);
        assert_eq!(std::fs::read(backups[0].path()).unwrap(), original);
        let mut external = Preferences::default();
        cx.update(|cx| {
            external
                .clear(
                    ConfigurableCommand::RunCurrent,
                    view.read(cx).shortcuts.platform,
                )
                .unwrap()
        });
        std::fs::write(
            f.root.join("shortcuts.json"),
            serde_json::to_vec(&external).unwrap(),
        )
        .unwrap();
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.command(
                    CommandId::ShortcutSettings,
                    CommandOrigin::Menu,
                    None,
                    window,
                    cx,
                );
                let section = this.appearance.dialog.as_ref().unwrap().shortcuts.clone();
                section.update(cx, |section, cx| {
                    section.test_request(Action::Reload, window, cx);
                });
            });
        })
        .unwrap();
        cx.run_until_parked();
        for _ in 0..50 {
            if cx.update(|cx| view.read(cx).shortcuts.persistence == PersistenceState::Saved) {
                break;
            }
            cx.background_executor
                .timer(Duration::from_millis(10))
                .await;
            cx.run_until_parked();
        }
        cx.update(|cx| {
            assert_eq!(view.read(cx).shortcuts.preferences, external);
            assert!(!view.read(cx).shortcuts.dirty);
            assert!(view.read(cx).backend.is_none());
        });
    }
    #[gpui::test]
    fn recorder_precedes_workspace_run_and_preserves_composition_altgr_and_original_entities(
        cx: &mut TestAppContext,
    ) {
        let f = Fixture::new();
        let (handle, view) = workspace(&f, cx);
        cx.update_window(handle, |_, window, cx| {
            let (section, editor, source) = view.update(cx, |this, cx| {
                let editor = this.tabs[0].editor.clone();
                let source = editor.read(cx).value();
                this.command(
                    CommandId::ShortcutSettings,
                    CommandOrigin::Menu,
                    None,
                    window,
                    cx,
                );
                (
                    this.appearance.dialog.as_ref().unwrap().shortcuts.clone(),
                    editor,
                    source,
                )
            });
            let input = section.update(cx, |section, cx| {
                section.test_record(ConfigurableCommand::RunCurrent, window, cx)
            });
            window.render_frame(cx);
            input.update(cx, |input, cx| {
                input.replace_and_mark_text_in_range(None, "compose", Some(7..7), window, cx)
            });
            window.press(&crate::platform::binding("enter"), cx);
            view.update(cx, |this, cx| {
                assert!(!this.tabs[0].busy());
                assert!(this.backend.is_none());
                assert_eq!(this.tabs[0].editor, editor);
                assert_eq!(editor.read(cx).value(), source);
            });
            input.update(cx, |input, cx| input.unmark_text(window, cx));
            window.press("ctrl-alt-q", cx);
            view.update(cx, |this, cx| {
                assert_eq!(this.shortcuts.preferences, Preferences::default());
                assert!(this.backend.is_none());
                this.prepare_appearance_close(window, cx);
                this.search.focus_handle(cx).focus(window, cx);
            });
            window.render_frame(cx);
            window.press(&crate::platform::binding("enter"), cx);
            assert!(!view.read(cx).tabs[0].busy());
            assert!(view.read(cx).backend.is_none());
        })
        .unwrap();
    }
    #[gpui::test]
    fn exact_native_route_clear_rebind_and_common_busy_unknown_modal_gates(
        cx: &mut TestAppContext,
    ) {
        let f = Fixture::new();
        let (handle, view) = workspace(&f, cx);
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.tabs[0].editor.focus_handle(cx).focus(window, cx);
                this.shortcuts
                    .preferences
                    .clear(ConfigurableCommand::RunCurrent, this.shortcuts.platform)
                    .unwrap();
                let mut native = KeyDownEvent {
                    keystroke: Preferences::default()
                        .shortcut(ConfigurableCommand::RunCurrent, this.shortcuts.platform)
                        .unwrap()
                        .keystroke(),
                    is_held: false,
                    prefer_character_input: false,
                };
                this.shortcut_key(&native, window, cx);
                assert!(!this.tabs[0].busy());
                // A named F key is admitted on the development source; exact
                // native identity ignores a misleading character alias.
                let shortcut = Shortcut::new(
                    "f9",
                    Modifiers {
                        control: true,
                        ..Modifiers::default()
                    },
                );
                this.shortcuts
                    .preferences
                    .set(
                        ConfigurableCommand::RunCurrent,
                        crate::shortcuts::BindingChoice::Bound(shortcut.clone()),
                        this.shortcuts.platform,
                    )
                    .unwrap();
                native.keystroke = shortcut.keystroke();
                native.keystroke.key = "f8".into();
                native.keystroke.key_char = Some("f9".into());
                this.shortcut_key(&native, window, cx);
                assert!(!this.tabs[0].busy());
                native.keystroke = shortcut.keystroke();
                this.tabs[0].uncertain = true;
                this.shortcut_key(&native, window, cx);
                assert!(!this.tabs[0].busy());
                this.tabs[0].uncertain = false;
                this.closing = true;
                this.shortcut_key(&native, window, cx);
                assert!(!this.tabs[0].busy());
                this.closing = false;
                assert!(this.backend.is_none());
            });
        })
        .unwrap();
    }
    #[gpui::test]
    fn latest_shortcut_close_drains_original_reservation_and_stale_error_reflushes_same_scope(
        cx: &mut TestAppContext,
    ) {
        let f = Fixture::new();
        let (handle, view) = workspace(&f, cx);
        let (first, first_sender) = Completion::new();
        let (latest, latest_sender) = Completion::new();
        first.finish(Err(StoreError::Write));
        latest.finish(Ok(SaveOutcome::Published));
        let (id, sibling, token) = cx
            .update_window(handle, |_, window, cx| {
                view.update(cx, |this, cx| {
                    let id = this.tabs[0].id;
                    this.add_sql_tab("Independent.sql".into(), "SELECT 2;".into(), window, cx);
                    let sibling = this.tabs[1].id;
                    this.shortcuts.dirty = true;
                    this.shortcuts.revision = 1;
                    this.shortcuts.pending = Some(PendingSave {
                        revision: 1,
                        reservation: 1,
                        completion: first,
                    });
                    this.request_close(CloseIntent::Tab(id), window, cx);
                    (id, sibling, this.close_flow.as_ref().unwrap().token)
                })
            })
            .unwrap();
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            this.shortcuts.pending.as_ref().is_some_and(|pending| {
                pending.revision == 1 && pending.completion.done.receiver_count() > 1
            })
        });
        cx.update_window(handle, |_, _, cx| {
            view.update(cx, |this, _| {
                this.shortcuts.revision = 2;
                this.shortcuts.pending = Some(PendingSave {
                    revision: 2,
                    reservation: 2,
                    completion: latest,
                });
            });
        })
        .unwrap();
        drop(first_sender);
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            this.shortcuts.pending.as_ref().is_some_and(|pending| {
                pending.revision == 2 && pending.completion.done.receiver_count() > 1
            })
        });
        cx.update(|cx| {
            assert!(view.read(cx).closing);
            assert_eq!(view.read(cx).close_flow.as_ref().unwrap().token, token);
            assert!(view.read(cx).tabs.iter().any(|t| t.id == id));
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
}
