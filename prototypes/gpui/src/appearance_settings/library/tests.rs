//! Prepared production chooser/store/close cases. Runtime execution is deferred.
use super::{Completion, LibraryState, PendingMutation};
use crate::theme_library::Error;

#[test]
fn close_completion_broadcast_keeps_latest_error_and_unchanged_fallback_closes() {
    let (completion, sender) = Completion::new();
    completion.finish(Err(Error::PublishedUnverified));
    drop(sender);
    let mut library = LibraryState::default();
    assert!(smol::block_on(library.finalization(None).future).is_ok());
    library.revision = 3;
    library.pending = Some(PendingMutation {
        revision: 3,
        completion: completion.clone(),
    });
    assert_eq!(
        smol::block_on(completion.wait()),
        Err(Error::PublishedUnverified)
    );
    assert!(smol::block_on(library.finalization(None).future).is_err());
    assert!(smol::block_on(library.finalization(None).future).is_err());
    library.revision = u64::MAX;
    assert!(!library.advance());
    library.serial = u64::MAX;
    assert!(library.serial().is_none());
}

#[test]
fn actual_refused_library_publication_cannot_complete_latest_close_finalizer() {
    use crate::{instance::DataDirectory, theme_library::LibraryStore};
    use std::{fs, path::PathBuf};
    for appeared in [false, true] {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/gpui/task27-close-tests")
            .join(uuid::Uuid::new_v4().to_string());
        let root = fs::canonicalize({
            fs::create_dir_all(&root).unwrap();
            &root
        })
        .unwrap();
        let store = LibraryStore::new(DataDirectory::acquire(&root).unwrap());
        store.load().unwrap();
        let source = root.join("synthetic-theme.json");
        fs::write(&source, br##"{"colors":{"editor.background":"#123456"}}"##).unwrap();
        let preview = crate::theme_library::preview_import(&source).unwrap();
        let result = store
            .reserve_import(preview.clone())
            .commit_with(|prepared| {
                if appeared {
                    fs::write(root.join("themes.json"), b"foreign appeared library").unwrap();
                } else {
                    fs::write(prepared.temporary_path(), b"modified staged library").unwrap();
                }
            });
        assert_eq!(result, Err(Error::Conflict));
        let (completion, sender) = Completion::new();
        completion.finish(result.map(|_| ()));
        drop(sender);
        let mut library = LibraryState {
            revision: 1,
            pending: Some(PendingMutation {
                revision: 1,
                completion,
            }),
            ..LibraryState::default()
        };
        assert!(smol::block_on(library.finalization(Some(store.clone())).future).is_err());
        // Only the next actual confirmed publication may satisfy this same participant.
        let result = if appeared {
            store.load_or_builtins().unwrap();
            store.reserve_recovery_import(preview).commit()
        } else {
            store.reserve_import(preview).commit()
        };
        assert!(matches!(
            result,
            Ok(crate::theme_library::CommitOutcome::Imported(_))
        ));
        let (completion, sender) = Completion::new();
        completion.finish(result.map(|_| ()));
        drop(sender);
        library.revision = 2;
        library.pending = Some(PendingMutation {
            revision: 2,
            completion,
        });
        assert!(smol::block_on(library.finalization(Some(store)).future).is_ok());
        fs::remove_dir_all(root).unwrap();
    }
}

#[cfg(windows)]
#[test]
fn unknown_library_publication_cannot_authorize_close_completion() {
    let (completion, sender) = Completion::new();
    completion.finish(Err(Error::PublicationUnknown));
    drop(sender);
    let library = LibraryState {
        revision: 1,
        pending: Some(PendingMutation {
            revision: 1,
            completion,
        }),
        ..LibraryState::default()
    };
    let result = smol::block_on(library.finalization(None).future);
    assert!(result.is_err_and(|error| error.contains("inspect") && error.contains("reload")));
}

#[cfg(feature = "native-smoke")]
mod retained {
    use super::*;
    use crate::{
        CloseIntent, CommandId, CommandOrigin, ProfileStore, Workspace, appearance,
        appearance::SaveOutcome,
        appearance_settings::{PendingSave, State},
        settings_view::{PersistenceState, SettingsAction},
        theme_library_view::{ImportMode, LibraryAction, LibraryEvent, Workflow},
    };
    use gpui_kit::{
        AnyWindowHandle, AppContext, Context, Entity, TestAppContext, Window, WindowAppearance,
        WindowOptions, test::TestAppContextExt,
    };
    use std::{
        fs,
        path::PathBuf,
        sync::{Arc, Mutex},
        time::Duration,
    };

    struct Fixture {
        root: PathBuf,
        store: ProfileStore,
    }
    impl Fixture {
        fn new() -> Self {
            let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../build/gpui/task27-workspace-tests")
                .join(uuid::Uuid::new_v4().to_string());
            let store = ProfileStore::acquire(root.join("connections.json")).unwrap();
            let root = fs::canonicalize(root).unwrap();
            Self { root, store }
        }
        fn source(&self) -> PathBuf {
            let path = self.root.join("synthetic-source.jsonc");
            fs::write(
                &path,
                include_bytes!("../../../fixtures/settings-theme-library/import.jsonc"),
            )
            .unwrap();
            path
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
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
    fn open(this: &mut Workspace, window: &mut Window, cx: &mut Context<Workspace>) {
        this.command(CommandId::Appearance, CommandOrigin::Menu, None, window, cx);
        assert!(this.appearance.dialog.is_some());
    }
    fn event(
        this: &mut Workspace,
        action: LibraryAction,
        window: &mut Window,
        cx: &mut Context<Workspace>,
    ) {
        let dialog = this.appearance.dialog.as_ref().unwrap();
        let (owner, section) = (dialog.view.entity_id(), dialog.library.entity_id());
        this.theme_library_event(
            owner,
            section,
            &LibraryEvent {
                revision: this.appearance.presentation_revision,
                action,
            },
            window,
            cx,
        );
    }
    fn choose(cx: &mut TestAppContext, path: PathBuf) {
        assert!(cx.did_prompt_for_paths());
        cx.simulate_path_prompt_response(move |options| {
            assert!(options.files && !options.directories && !options.multiple);
            Some(vec![path])
        });
    }
    async fn reviewed(handle: AnyWindowHandle, view: &Entity<Workspace>, cx: &mut TestAppContext) {
        cx.wait_for(handle, Duration::from_secs(5), |_, cx| {
            matches!(
                view.read(cx).appearance.library.workflow,
                Workflow::Review(_)
            )
        })
        .await;
    }
    async fn idle(handle: AnyWindowHandle, view: &Entity<Workspace>, cx: &mut TestAppContext) {
        cx.wait_for(handle, Duration::from_secs(5), |_, cx| {
            view.read(cx).appearance.library.workflow == Workflow::Idle
        })
        .await;
    }

    #[gpui::test]
    async fn native_picker_original_cancel_cannot_parse_or_cancel_new_review(
        cx: &mut TestAppContext,
    ) {
        let f = Fixture::new();
        let path = f.source();
        let (handle, view) = workspace(&f, cx);
        let (owner, section, revision, request) = cx
            .update_window(handle, |_, window, cx| {
                view.update(cx, |this, cx| {
                    open(this, window, cx);
                    let preferences = this.appearance.preferences.clone();
                    event(this, LibraryAction::RequestImport, window, cx);
                    let dialog = this.appearance.dialog.as_ref().unwrap();
                    let request = this.appearance.library.workflow.import_request().unwrap();
                    let identities = (
                        dialog.view.entity_id(),
                        dialog.library.entity_id(),
                        this.appearance.presentation_revision,
                        request,
                    );
                    event(
                        this,
                        LibraryAction::CancelImport {
                            request,
                            preview: None,
                        },
                        window,
                        cx,
                    );
                    assert_eq!(this.appearance.preferences, preferences);
                    assert!(this.appearance.library.pending.is_none());
                    identities
                })
            })
            .unwrap();
        choose(cx, path.clone());
        cx.run_until_parked();
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                assert_eq!(this.appearance.library.workflow, Workflow::Idle);
                assert_eq!(this.appearance.themes.len(), 8);
                event(this, LibraryAction::RequestImport, window, cx);
                assert_ne!(
                    this.appearance.library.workflow.import_request(),
                    Some(request)
                );
                this.theme_library_event(
                    owner,
                    section,
                    &LibraryEvent {
                        revision,
                        action: LibraryAction::CancelImport {
                            request,
                            preview: None,
                        },
                    },
                    window,
                    cx,
                );
                assert!(matches!(
                    this.appearance.library.workflow,
                    Workflow::Choosing(_)
                ));
            });
        })
        .unwrap();
        choose(cx, path);
        reviewed(handle, &view, cx).await;
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                let review = this.appearance.library.workflow.review().unwrap().clone();
                let before = this.appearance.preferences.clone();
                assert!(this.appearance.pending.is_none());
                assert!(!f.root.join("themes.json").exists());
                event(
                    this,
                    LibraryAction::CancelImport {
                        request: review.token().request(),
                        preview: Some(review.token()),
                    },
                    window,
                    cx,
                );
                assert_eq!(this.appearance.preferences, before);
                assert_eq!(this.appearance.themes.len(), 8);
            });
        })
        .unwrap();
    }

    #[gpui::test]
    fn canceled_background_parse_discards_original_preview_without_reserving_selectors(
        cx: &mut TestAppContext,
    ) {
        let f = Fixture::new();
        let path = f.source();
        let (handle, view) = workspace(&f, cx);
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                open(this, window, cx);
                let original = this.appearance.preferences.clone();
                event(this, LibraryAction::RequestImport, window, cx);
                // Inject the native callback's original selected path at the SAME
                // production parse entry point, then cancel before the worker terminal.
                let mut capture = this.appearance.library.import.clone().unwrap();
                let request = capture.request;
                capture.path = Some(path);
                this.parse_theme_file(capture, window, cx);
                assert_eq!(this.appearance.library.workflow, Workflow::Parsing(request));
                event(
                    this,
                    LibraryAction::CancelImport {
                        request,
                        preview: None,
                    },
                    window,
                    cx,
                );
                assert_eq!(this.appearance.preferences, original);
                assert!(this.appearance.pending.is_none());
                assert!(this.appearance.library.pending.is_none());
            });
        })
        .unwrap();
        assert!(cx.did_prompt_for_paths());
        cx.simulate_path_prompt_response(|_| None);
        cx.run_until_parked();
        cx.update(|cx| {
            assert_eq!(view.read(cx).appearance.library.workflow, Workflow::Idle);
            assert_eq!(view.read(cx).appearance.themes.len(), 8);
            assert!(view.read(cx).appearance.library.import.is_none());
        });
        assert!(!f.root.join("themes.json").exists());
        assert!(!f.root.join("appearance.json").exists());
    }

    #[gpui::test]
    async fn explicit_import_retains_entities_and_newer_editor_choice_then_restarts_without_source(
        cx: &mut TestAppContext,
    ) {
        let f = Fixture::new();
        let path = f.source();
        let (handle, view) = workspace(&f, cx);
        let (editor, library) = cx
            .update_window(handle, |_, window, cx| {
                view.update(cx, |this, cx| {
                    open(this, window, cx);
                    let library = this.appearance.dialog.as_ref().unwrap().library.clone();
                    let editor = this.tabs[0].editor.clone();
                    event(this, LibraryAction::RequestImport, window, cx);
                    (editor, library)
                })
            })
            .unwrap();
        choose(cx, path.clone());
        reviewed(handle, &view, cx).await;
        let imported = cx
            .update_window(handle, |_, window, cx| {
                view.update(cx, |this, cx| {
                    let review = this.appearance.library.workflow.review().unwrap().clone();
                    let id = review.theme().id.clone();
                    assert!(!this.appearance.themes.iter().any(|theme| theme.id == id));
                    event(
                        this,
                        LibraryAction::CommitImport(review.token()),
                        window,
                        cx,
                    );
                    // The worker is dispatched, but the original terminal cannot run
                    // until this UI turn finishes. This is a real in-flight later choice.
                    this.choose_appearance(
                        SettingsAction::ChooseEditor("jetbrains-light".into()),
                        window,
                        cx,
                    );
                    assert_eq!(
                        this.appearance.preferences.editor_color_theme,
                        "jetbrains-light"
                    );
                    assert_eq!(this.appearance.dialog.as_ref().unwrap().library, library);
                    assert_eq!(this.tabs[0].editor, editor);
                    id
                })
            })
            .unwrap();
        idle(handle, &view, cx).await;
        cx.update(|cx| {
            let this = view.read(cx);
            assert_eq!(
                this.appearance.preferences.editor_color_theme,
                "jetbrains-light"
            );
            assert_eq!(
                this.appearance.preferences.application_color_theme,
                appearance::NATIVE
            );
            assert_eq!(this.appearance.themes.last().unwrap().id, imported);
            assert_eq!(this.tabs[0].editor, editor);
            assert_eq!(this.appearance.dialog.as_ref().unwrap().library, library);
        });
        fs::remove_file(path).unwrap();
        let restart = State::load(Some(&f.store), WindowAppearance::Dark);
        assert!(restart.themes.iter().any(|theme| theme.id == imported));
        assert!(!f.root.join("sql-documents.json").exists());
    }

    #[gpui::test]
    async fn committed_import_selects_editor_only_and_successful_remove_resets_current_matching_choices(
        cx: &mut TestAppContext,
    ) {
        let f = Fixture::new();
        let path = f.source();
        let (handle, view) = workspace(&f, cx);
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                open(this, window, cx);
                this.choose_appearance(
                    SettingsAction::ChooseApplication("solarized-light".into()),
                    window,
                    cx,
                );
                event(this, LibraryAction::RequestImport, window, cx);
            });
        })
        .unwrap();
        choose(cx, path);
        reviewed(handle, &view, cx).await;
        let id = cx
            .update_window(handle, |_, window, cx| {
                view.update(cx, |this, cx| {
                    let review = this.appearance.library.workflow.review().unwrap().clone();
                    let id = review.theme().id.clone();
                    event(
                        this,
                        LibraryAction::CommitImport(review.token()),
                        window,
                        cx,
                    );
                    id
                })
            })
            .unwrap();
        idle(handle, &view, cx).await;
        cx.wait_for(handle, Duration::from_secs(5), |_, cx| {
            view.read(cx).appearance.persistence == PersistenceState::Saved
        })
        .await;
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                assert_eq!(this.appearance.preferences.editor_color_theme, id);
                assert_eq!(
                    this.appearance.preferences.application_color_theme,
                    "solarized-light"
                );
                event(this, LibraryAction::Browse(id.clone()), window, cx);
                event(this, LibraryAction::Remove(id.clone()), window, cx);
                // Reservation alone cannot reset a selector or remove its menu value.
                assert_eq!(this.appearance.preferences.editor_color_theme, id);
                assert!(this.appearance.themes.iter().any(|t| t.id == id));
                // This later independent application choice must survive the remove terminal.
                this.choose_appearance(
                    SettingsAction::ChooseApplication("jetbrains-darcula".into()),
                    window,
                    cx,
                );
            });
        })
        .unwrap();
        idle(handle, &view, cx).await;
        cx.wait_for(handle, Duration::from_secs(5), |_, cx| {
            view.read(cx).appearance.persistence == PersistenceState::Saved
        })
        .await;
        cx.update(|cx| {
            let this = view.read(cx);
            assert_eq!(
                this.appearance.preferences.editor_color_theme,
                appearance::AUTOMATIC
            );
            assert_eq!(
                this.appearance.preferences.application_color_theme,
                "jetbrains-darcula"
            );
            assert!(!this.appearance.themes.iter().any(|t| t.id == id));
            assert!(
                smol::block_on(
                    this.appearance
                        .library
                        .finalization(this.appearance.library_store.clone())
                        .future
                )
                .is_ok()
            );
            assert!(smol::block_on(this.appearance.finalization().future).is_ok());
        });
    }

    #[gpui::test]
    async fn corrupt_recovery_is_explicit_and_failed_removal_retains_selectors(
        cx: &mut TestAppContext,
    ) {
        let f = Fixture::new();
        let original = b"{corrupt theme library\r\n";
        fs::write(f.root.join("themes.json"), original).unwrap();
        let path = f.source();
        let (handle, view) = workspace(&f, cx);
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                open(this, window, cx);
                event(this, LibraryAction::RequestImport, window, cx);
                assert_eq!(this.appearance.library.workflow, Workflow::Idle);
                assert!(this.appearance.library_recovery_available);
                event(this, LibraryAction::RequestRecoveryImport, window, cx);
                assert_eq!(fs::read(f.root.join("themes.json")).unwrap(), original);
            });
        })
        .unwrap();
        choose(cx, path);
        reviewed(handle, &view, cx).await;
        let id = cx
            .update_window(handle, |_, window, cx| {
                view.update(cx, |this, cx| {
                    let review = this.appearance.library.workflow.review().unwrap().clone();
                    assert_eq!(review.token().request().mode(), ImportMode::Recovery);
                    let id = review.theme().id.clone();
                    event(
                        this,
                        LibraryAction::CommitImport(review.token()),
                        window,
                        cx,
                    );
                    id
                })
            })
            .unwrap();
        idle(handle, &view, cx).await;
        let backups = fs::read_dir(&f.root)
            .unwrap()
            .filter_map(std::result::Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("themes-recovery-")
            })
            .collect::<Vec<_>>();
        assert_eq!(backups.len(), 1);
        assert_eq!(fs::read(backups[0].path()).unwrap(), original);
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                assert_eq!(this.appearance.preferences.editor_color_theme, id);
                let current = this.appearance.preferences.clone();
                fs::write(f.root.join("themes.json"), b"{external replacement}").unwrap();
                event(this, LibraryAction::Browse(id.clone()), window, cx);
                event(this, LibraryAction::Remove(id.clone()), window, cx);
                assert_eq!(this.appearance.preferences, current);
            });
        })
        .unwrap();
        cx.wait_for(handle, Duration::from_secs(5), |_, cx| {
            matches!(
                view.read(cx).appearance.library.workflow,
                Workflow::RemoveFailed {
                    error: Error::Conflict,
                    ..
                }
            )
        })
        .await;
        cx.update(|cx| {
            let this = view.read(cx);
            assert_eq!(this.appearance.preferences.editor_color_theme, id);
            assert!(this.appearance.themes.iter().any(|t| t.id == id));
            assert!(
                smol::block_on(
                    this.appearance
                        .library
                        .finalization(this.appearance.library_store.clone())
                        .future
                )
                .is_err()
            );
        });
        assert_eq!(
            fs::read(f.root.join("themes.json")).unwrap(),
            b"{external replacement}"
        );
    }

    #[gpui::test]
    fn normal_close_drains_original_canceled_native_picker_before_removing_only_captured_tab(
        cx: &mut TestAppContext,
    ) {
        let f = Fixture::new();
        let (handle, view) = workspace(&f, cx);
        let (id, sibling) = cx
            .update_window(handle, |_, window, cx| {
                view.update(cx, |this, cx| {
                    let id = this.tabs[0].id;
                    this.add_sql_tab("Independent.sql".into(), "SELECT 2;".into(), window, cx);
                    let sibling = this.tabs[1].id;
                    open(this, window, cx);
                    event(this, LibraryAction::RequestImport, window, cx);
                    this.request_close(CloseIntent::Tab(id), window, cx);
                    assert!(this.appearance.dialog.is_none());
                    assert!(this.appearance.library.import.is_none());
                    (id, sibling)
                })
            })
            .unwrap();
        cx.run_until_parked();
        cx.update(|cx| {
            assert!(view.read(cx).tabs.iter().any(|tab| tab.id == id));
            assert!(view.read(cx).closing);
        });
        assert!(cx.did_prompt_for_paths());
        cx.simulate_path_prompt_response(|_| None);
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            this.tabs.iter().all(|tab| tab.id != id)
        });
        cx.update(|cx| {
            let this = view.read(cx);
            assert!(this.tabs.iter().all(|tab| tab.id != id));
            assert!(this.tabs.iter().any(|tab| tab.id == sibling));
            assert_eq!(this.appearance.themes.len(), 8);
            assert!(this.appearance.pending.is_none());
        });
    }
    #[gpui::test]
    fn common_close_rechecks_stale_library_failure_and_awaits_required_latest_appearance(
        cx: &mut TestAppContext,
    ) {
        let f = Fixture::new();
        let (handle, view) = workspace(&f, cx);
        let (first, first_sender) = Completion::new();
        first.finish(Err(Error::LibraryWrite));
        let (latest, latest_sender) = Completion::new();
        latest.finish(Ok(()));
        let (appearance_sender, appearance_done) = async_channel::bounded(1);
        let (id, sibling, token) = cx
            .update_window(handle, |_, window, cx| {
                view.update(cx, |this, cx| {
                    let id = this.tabs[0].id;
                    this.add_sql_tab("Independent.sql".into(), "SELECT 2;".into(), window, cx);
                    let sibling = this.tabs[1].id;
                    this.appearance.library.revision = 1;
                    this.appearance.library.pending = Some(PendingMutation {
                        revision: 1,
                        completion: first,
                    });
                    this.request_close(CloseIntent::Tab(id), window, cx);
                    (id, sibling, this.close_flow.as_ref().unwrap().token)
                })
            })
            .unwrap();
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            this.appearance
                .library
                .pending
                .as_ref()
                .is_some_and(|pending| {
                    pending.revision == 1 && pending.completion.done.receiver_count() > 1
                })
        });
        cx.update_window(handle, |_, _, cx| {
            view.update(cx, |this, _| {
                // Newer already accepted reservations, including the separate save
                // required by a successful library terminal, retain their own evidence.
                this.appearance.library.revision = 2;
                this.appearance.library.pending = Some(PendingMutation {
                    revision: 2,
                    completion: latest,
                });
                this.appearance.revision = 1;
                this.appearance.pending = Some(PendingSave {
                    revision: 1,
                    result: Arc::new(Mutex::new(Some(Ok(SaveOutcome::Published)))),
                    done: appearance_done,
                });
            });
        })
        .unwrap();
        drop(first_sender);
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            this.appearance
                .library
                .pending
                .as_ref()
                .is_some_and(|pending| {
                    pending.revision == 2 && pending.completion.done.receiver_count() > 1
                })
        });
        cx.update(|cx| {
            assert!(view.read(cx).closing);
            assert_eq!(view.read(cx).close_flow.as_ref().unwrap().token, token);
        });
        drop(latest_sender);
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            this.appearance
                .pending
                .as_ref()
                .is_some_and(|pending| pending.done.receiver_count() > 1)
        });
        cx.update(|cx| {
            assert!(view.read(cx).tabs.iter().any(|t| t.id == id));
            assert_eq!(view.read(cx).close_flow.as_ref().unwrap().token, token);
        });
        drop(appearance_sender);
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            this.tabs.iter().all(|tab| tab.id != id)
        });
        cx.update(|cx| {
            assert!(view.read(cx).tabs.iter().all(|t| t.id != id));
            assert!(view.read(cx).tabs.iter().any(|t| t.id == sibling));
        });
    }
}
