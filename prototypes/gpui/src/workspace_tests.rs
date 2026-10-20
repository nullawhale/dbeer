//! Headless GPUI production-view tests. These prove callbacks/entity lifetime,
//! not native rendering, OS input/IME, accessibility or desktop acceptance.
use crate::{BackendClient, OperationContext, Workspace, apply_theme, backend, platform};
use gpui_kit::component::{ThemeMode, WindowExt};
use gpui_kit::test::TestWindowExt;
use gpui_kit::{
    AnyWindowHandle, App, AppContext, Bounds, ClipboardItem, Entity, Point, TestAppContext,
    WindowBounds, WindowOptions, init, open_window, point, px, size,
};

pub(super) fn workspace(cx: &mut TestAppContext) -> (AnyWindowHandle, Entity<Workspace>) {
    workspace_with_policy(
        cx,
        crate::product_identity::StartupPolicy::new(
            crate::product_identity::Platform::MacDevelopment,
            true,
        ),
    )
}
pub(super) fn workspace_with_policy(
    cx: &mut TestAppContext,
    policy: crate::product_identity::StartupPolicy,
) -> (AnyWindowHandle, Entity<Workspace>) {
    let result = cx.update(|cx| {
        // The retained workspace owns real helper/LSP I/O. Its test executor
        // must accept wakes from those owned threads.
        cx.background_executor().allow_parking();
        init(cx);
        apply_theme(ThemeMode::Dark, None, cx);
        let (handle, view) = open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Point::default(),
                    size: size(px(1280.), px(820.)),
                })),
                ..Default::default()
            },
            cx,
            |window, cx| cx.new(|cx| Workspace::new(None, policy, window, cx)),
        )
        .unwrap();
        handle
            .update(cx, |_, window, cx| {
                crate::close::install_window_guard(&view, window, cx);
                window.activate_window();
            })
            .unwrap();
        (handle, view)
    });
    prepare_test_window(cx, result.0);
    result
}

pub(crate) fn prepare_test_window(cx: &mut TestAppContext, handle: AnyWindowHandle) {
    cx.update_window(handle, |_, window, cx| {
        cx.background_executor().allow_parking();
        window.activate_window();
    })
    .unwrap();
    // TestPlatform delivers activation through its foreground callback.
    cx.run_until_parked();
}

#[gpui_kit::test]
fn fresh_product_workspace_is_empty_unbound_and_only_explicit_binding_selects_a_real_profile(
    cx: &mut TestAppContext,
) {
    let (window, view) = workspace_with_policy(
        cx,
        crate::product_identity::StartupPolicy::new(crate::product_identity::Platform::Linux, true),
    );
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        view.update(cx, |this, cx| {
            assert!(this.profiles.is_empty() && this.backend.is_none());
            assert_eq!(this.tabs.len(), 1);
            assert_eq!(this.tabs[0].profile, crate::model::ProfileId::unbound());
            assert!(this.tabs[0].editor.read(cx).value().is_empty());
            assert!(
                this.tabs[0].session.is_none()
                    && this.tabs[0].result_sets.is_empty()
                    && this.tabs[0].executions.is_empty()
            );
            assert_eq!(this.document_snapshot(cx).documents[0].profile_id, None);
            let mut settings = crate::connections::ConnectionProfile::new();
            settings.id = "demo-brewery".into();
            this.profiles
                .push(crate::workspace::Profile::saved(settings.clone()));
            assert!(!this.profiles[0].demo);
            assert_eq!(this.tabs[0].profile, crate::model::ProfileId::unbound());
            this.bind_selected_document_profile(cx);
            assert_eq!(
                this.tabs[0].profile,
                crate::model::ProfileId::saved(&settings)
            );
            assert!(this.backend.is_none() && this.tabs[0].session.is_none());
            assert_eq!(
                this.document_snapshot(cx).documents[0]
                    .profile_id
                    .as_deref(),
                Some("demo-brewery")
            );
            this.add_default_tab(crate::demo::DemoTable::Products, window, cx);
            assert!(this.tabs[this.active].editor.read(cx).value().is_empty());
            assert!(this.backend.is_none() && this.tabs.iter().all(|tab| tab.session.is_none()));
        });
        window.render_frame(cx);
    })
    .unwrap();
}

#[gpui_kit::test]
fn tab_switch_theme_and_other_tab_close_preserve_editor_selection_scroll_and_undo(
    cx: &mut TestAppContext,
) {
    let (window, view) = workspace(cx);
    let first = cx.update(|cx| view.read(cx).tabs[0].editor.clone());
    let first_id = cx.update(|cx| view.read(cx).tabs[0].id);
    cx.update_window(window, |_, window, cx| {
        let source = (0..90)
            .map(|n| format!("SELECT {n};\n"))
            .collect::<String>();
        first.update(cx, |state, cx| {
            state.set_value(source, window, cx);
            state.set_selected_range(0..0, cx);
            state.focus(window, cx);
        });
        window.render_frame(cx);
        window.input("'--\"", cx);
        assert!(
            first.read(cx).value().starts_with("'--\"SELECT"),
            "SQL typing substituted or auto-closed punctuation."
        );
        cx.write_to_clipboard(ClipboardItem::new_string(
            "'quoted' -- dash\r\nSELECT 'caf\u{00e9}\u{1f642}';".to_string(),
        ));
        window.press(&platform::binding("v"), cx);
        assert!(
            first
                .read(cx)
                .value()
                .contains("'quoted' -- dash\r\nSELECT 'caf\u{00e9}\u{1f642}';"),
            "SQL paste altered plain text."
        );
        first.update(cx, |state, cx| {
            state.set_selected_range(4..12, cx);
            state.set_scroll_offset(point(px(-10.), px(-80.)), cx);
        });
        window.render_frame(cx);
        let selection = first.read(cx).selected_range();
        let scroll = first.read(cx).scroll_offset();
        let text = first.read(cx).value();
        view.update(cx, |this, cx| {
            this.selected_profile = 1;
            this.add_sql_tab("Other.sql".into(), "SELECT 2;".into(), window, cx);
            this.toggle_theme(window, cx);
        });
        window.render_frame(cx);
        window.click(("tab", first_id.0), cx);
        view.update(cx, |this, cx| {
            this.close_tab(1, window, cx);
        });
        window.render_frame(cx);
        assert_eq!(view.read(cx).tabs[0].editor.entity_id(), first.entity_id());
        assert_eq!(first.read(cx).selected_range(), selection);
        assert_eq!(first.read(cx).scroll_offset(), scroll);
        assert!(first.read(cx).value() == text);
        window.press(&platform::binding("z"), cx);
        assert!(
            !first.read(cx).value().contains("'quoted' -- dash"),
            "Undo history was lost on tab/theme changes."
        );
        assert!(
            first.read(cx).value().starts_with("'--\"SELECT"),
            "Paste was not one atomic undo step."
        );
    })
    .unwrap();
    assert!(
        cx.update(|cx| view.read(cx).tabs[0].generation > 0),
        "Editor Change did not advance its document revision."
    );
}

fn attach(view: &Entity<Workspace>, cx: &mut App) -> OperationContext {
    view.update(cx, |this, _| {
        let tab = &mut this.tabs[0];
        let context = tab.begin(None, 8).unwrap();
        let context = tab.attach(&context, "owned-session".into()).unwrap();
        tab.started(&context, "owned-query".into());
        context
    })
}
fn outcome(tx: backend::TransactionStatus) -> backend::QueryOutcome {
    backend::QueryOutcome {
        result_sets: vec![backend::ResultSet::default()],
        duration_ms: 0.,
        transaction_status: tx,
        command_tag: "TEST".into(),
        row_count: 0,
        truncated: false,
        display_notice: String::new(),
        export: None,
    }
}

#[gpui_kit::test]
fn stale_source_terminal_reconciles_original_tab_without_clearing_newer_work(
    cx: &mut TestAppContext,
) {
    let (window, view) = workspace(cx);
    cx.update_window(window, |_, window, cx| {
        let context = attach(&view, cx);
        view.update(cx, |this, cx| {
            this.tabs[0].generation += 1;
            this.add_sql_tab("Other.sql".into(), "SELECT 2;".into(), window, cx);
            this.selected_profile = 1;
            this.finish_live(
                &context,
                outcome(backend::TransactionStatus::Transaction),
                window,
                cx,
            );
            assert!(!this.tabs[0].busy());
            assert_eq!(this.tabs[0].transaction, "transaction");
            assert!(this.tabs[0].result_sets.is_empty());
            assert_eq!(this.tabs[1].transaction, "idle");
            let next = this.tabs[0].begin(None, 8).unwrap();
            let next = this.tabs[0].attach(&next, "owned-session".into()).unwrap();
            this.fail_live(
                &context,
                backend::BackendError::transport("Late previous operation."),
                window,
                cx,
            );
            assert!(this.tabs[0].owns(&next));
            this.finish_cancelled(&next, cx);
            // An unrelated dialog can open during an asynchronous disconnect.
            // Internal replacement of the last closed tab must still happen.
            this.close_tab(1, window, cx);
            Workspace::information("Synthetic close-race dialog", window, cx);
            let closing = this.tabs[0].id;
            this.complete_close(crate::close::CloseIntent::Tab(closing), window, cx);
            assert_eq!(
                this.tabs.len(),
                1,
                "Last-tab close left the workspace empty behind a dialog."
            );
        });
    })
    .unwrap();
}

#[gpui_kit::test]
fn helper_death_before_callback_keeps_busy_until_authoritative_unknown_terminal(
    cx: &mut TestAppContext,
) {
    let path = std::env::var_os("DBEER_GPUI_HELPER_PATH").expect("Use the GPUI test runner.");
    let client = BackendClient::spawn(path).expect("Start isolated helper.");
    smol::block_on(client.handshake()).expect("Helper handshake.");
    let (window, view) = workspace(cx);
    let context = cx
        .update_window(window, |_, _, cx| {
            let context = attach(&view, cx);
            view.update(cx, |this, cx| {
                this.backend = Some(client.clone());
                this.tabs[0].own_session(client.clone());
                this.tabs[0].operation_client = Some(client.clone());
                this.tabs[0].task = Some(cx.spawn(async |_, _| {
                    smol::future::pending::<()>().await;
                }));
                client.fail_for_test();
                // The same caller path is used by Run and window/profile close.
                this.invalidate_dead_helper();
                assert!(
                    this.tabs[0].owns(&context),
                    "Helper invalidation consumed the original operation."
                );
                assert!(
                    this.tabs[0].busy(),
                    "Helper invalidation made an unknown operation appear idle."
                );
                assert!(this.tabs[0].task.is_some());
            });
            context
        })
        .unwrap();
    await_workspace(cx, &view, |_| client.owned_process_exited());
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let mut terminal = backend::BackendError::transport("The owned helper exited.");
            terminal.outcome_unknown = true;
            this.fail_live(&context, terminal, window, cx);
            assert!(!this.tabs[0].busy());
            assert!(
                this.tabs[0].uncertain,
                "Autocommit helper loss must retain unknown outcome."
            );
            assert!(this.tabs[0].session.is_none());
            assert!(this.tabs[0].begin(None, 8).is_none());
        });
    })
    .unwrap();
}

pub(crate) fn await_workspace(
    cx: &mut TestAppContext,
    view: &Entity<Workspace>,
    predicate: impl Fn(&Workspace) -> bool,
) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    loop {
        cx.run_until_parked();
        if cx.update(|cx| predicate(view.read(cx))) {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "The isolated workspace operation timed out."
        );
        // Inspect the owned predicate before advancing to its next scheduled
        // timer. run_until_parked drains runnable tasks without moving test time.
        cx.dispatcher.advance_clock_to_next_timer();
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
}

pub(crate) fn await_window(
    cx: &mut TestAppContext,
    handle: AnyWindowHandle,
    timeout: std::time::Duration,
    mut predicate: impl FnMut(&mut gpui_kit::Window, &mut App) -> bool,
) {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        cx.run_until_parked();
        if cx
            .update_window(handle, |_, window, cx| predicate(window, cx))
            .unwrap()
        {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "The owned window condition timed out."
        );
        cx.dispatcher.advance_clock_to_next_timer();
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
}

fn database_workspace(cx: &mut TestAppContext, connection: backend::Connection) {
    let postgres = connection.engine == "postgresql";
    let client = BackendClient::spawn(std::env::var_os("DBEER_GPUI_HELPER_PATH").unwrap())
        .expect("Start isolated helper.");
    smol::block_on(client.handshake()).expect("Complete isolated handshake.");
    let first =
        smol::block_on(client.connect(connection.clone())).expect("Connect isolated first tab.");
    let second =
        smol::block_on(client.connect(connection.clone())).expect("Connect isolated second tab.");
    let service = smol::block_on(client.connect(connection.clone()))
        .expect("Connect isolated catalog session.");
    let identity = smol::block_on(crate::live_tests::finish(
        client
            .execute(
                &first.session_id,
                if postgres {
                    "SELECT pg_backend_pid()"
                } else {
                    "SELECT CONNECTION_ID()"
                }
                .into(),
            )
            .expect("Enqueue isolated session identity."),
    ))
    .expect("Read isolated session identity.");
    let server_id = identity
        .result_sets
        .first()
        .and_then(|set| set.rows.first())
        .and_then(|row| row.first())
        .and_then(|value| value.as_ref())
        .and_then(|value| value.parse::<u64>().ok())
        .expect("The isolated server omitted its numeric session identity.");
    let observer_session = service.session_id.clone();
    let settings = crate::connections::ConnectionProfile {
        engine: connection.engine,
        host: connection.host,
        port: connection.port,
        database: connection.database,
        user: connection.user,
        ssl_mode: connection.ssl_mode,
        ssl_root_cert: connection.ssl_root_cert,
        readonly: connection.policy.read_only,
        environment: connection.policy.environment,
        ..Default::default()
    };
    let (window, view) = workspace(cx);
    // Real helper I/O wakes from its reader thread. GPUI's test scheduler
    // explicitly permits nondeterministic I/O only after enabling parking.
    cx.update(|cx| cx.background_executor().allow_parking());
    let (first_id, second_id, profile_id) = cx
        .update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.backend = Some(client.clone());
                this.profiles
                    .push(crate::workspace::Profile::saved(settings.clone()));
                let index = this.profiles.len() - 1;
                let profile_id = this.profiles[index].id.clone();
                this.profiles[index].session = Some(service.session_id);
                this.profiles[index].session_settings = Some(settings.clone());
                this.profiles[index].session_client = Some(client.clone());
                this.tabs[0].profile = profile_id.clone();
                this.tabs[0].session = Some(first.session_id);
                this.tabs[0].session_settings = Some(settings.clone());
                this.tabs[0].own_session(client.clone());
                let first_id = this.tabs[0].id;
                this.selected_profile = index;
                this.add_sql_tab("Independent.sql".into(), "SELECT 2;".into(), window, cx);
                let tab = &mut this.tabs[1];
                tab.session = Some(second.session_id);
                tab.session_settings = Some(settings);
                tab.own_session(client.clone());
                let second_id = tab.id;
                this.connect_profile(index, window, cx);
                // Reorder while the service request is in flight; callbacks must find ID.
                this.profiles.swap(0, index);
                this.selected_profile = index;
                (first_id, second_id, profile_id)
            })
        })
        .unwrap();
    await_workspace(cx, &view, |this| this.profile(&profile_id).task.is_none());
    assert!(
        cx.update(|cx| !view.read(cx).profile(&profile_id).schemas.is_empty()),
        "Catalog response followed a vector index after reordering."
    );
    let run = |cx: &mut TestAppContext, id, sql: &str| {
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.run_live(id, Some(sql.into()), None, window, cx)
            })
        })
        .unwrap();
    };
    run(
        cx,
        first_id,
        if postgres {
            "SELECT pg_sleep(0.3)"
        } else {
            "SELECT SLEEP(0.3)"
        },
    );
    await_workspace(cx, &view, |this| this.tabs[0].query_id.is_some());
    run(cx, second_id, "SELECT 2");
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.active = 1;
            this.selected_profile = 1;
            this.tabs[0].editor.update(cx, |editor, cx| {
                editor.insert(" -- source changed", window, cx)
            });
        })
    })
    .unwrap();
    await_workspace(cx, &view, |this| this.tabs.iter().all(|tab| !tab.busy()));
    cx.update(|cx| {
        let this = view.read(cx);
        assert!(
            this.tabs[0].result_sets.is_empty(),
            "An obsolete source received query results."
        );
        assert!(
            !this.tabs[1].result_sets.is_empty(),
            "The captured second tab lost its results."
        );
        assert!(
            this.tabs[0].session != this.tabs[1].session,
            "Physical sessions were shared."
        );
    });
    run(cx, first_id, "START TRANSACTION READ ONLY");
    await_workspace(cx, &view, |this| !this.tabs[0].busy());
    cx.update(|cx| {
        assert_eq!(view.read(cx).tabs[0].transaction, "transaction");
        assert_eq!(view.read(cx).tabs[1].transaction, "idle");
    });
    run(
        cx,
        first_id,
        if postgres {
            "SELECT pg_sleep(30)"
        } else {
            "SELECT 1 FROM (SELECT 1 AS n UNION ALL SELECT 2) source_rows WHERE SLEEP(30)=0"
        },
    );
    await_workspace(cx, &view, |this| this.tabs[0].query_id.is_some());
    // Observe the exact physical session in its server sleep state. Local
    // enqueue/Started and arbitrary delays do not prove execution reached it.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        cx.run_until_parked();
        let sql = if postgres {
            format!("SELECT wait_event FROM pg_stat_activity WHERE pid={server_id}")
        } else {
            format!("SELECT STATE FROM information_schema.PROCESSLIST WHERE ID={server_id}")
        };
        let observed = smol::block_on(crate::live_tests::finish(
            client
                .execute(&observer_session, sql)
                .expect("Enqueue isolated server observation."),
        ))
        .expect("Observe isolated server execution.");
        let sleeping = observed
            .result_sets
            .iter()
            .flat_map(|set| &set.rows)
            .filter_map(|row| row.first())
            .filter_map(|value| value.as_ref())
            .any(|value| {
                value.eq_ignore_ascii_case(if postgres { "PgSleep" } else { "User sleep" })
            });
        if sleeping {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "The captured physical session did not enter its server sleep state."
        );
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    // Task 11: Cancel must preserve the exact observed physical session and
    // in-flight operation. No Stop request is authorized by merely asking close.
    let pid = std::process::id();
    cx.update_window(window, |_, window, cx| {
        let before = view.update(cx, |this, cx| {
            let tab = this.tabs.iter().find(|tab| tab.id == first_id).unwrap();
            let before = (
                tab.session.clone(),
                tab.query_id.clone(),
                tab.operation.as_ref().unwrap().operation,
            );
            this.request_close(crate::close::CloseIntent::Tab(first_id), window, cx);
            this.can_close_window(window, cx);
            before
        });
        window.render_frame(cx);
        window.click("cancel-running-close", cx);
        view.update(cx, |this, _| {
            let tab = this.tabs.iter().find(|tab| tab.id == first_id).unwrap();
            assert_eq!(tab.session, before.0);
            assert_eq!(tab.query_id, before.1);
            assert_eq!(tab.operation.as_ref().unwrap().operation, before.2);
            assert!(tab.busy() && !tab.stop_requested);
            assert!(!this.closing);
            assert_eq!(std::process::id(), pid);
        });
    })
    .unwrap();
    cx.update(|cx| view.update(cx, |this, cx| this.stop_live(first_id, cx)));
    await_workspace(cx, &view, |this| !this.tabs[0].busy());
    let unknown = cx.update(|cx| {
        let this = view.read(cx);
        assert_eq!(this.tabs[1].transaction, "idle");
        assert!(
            this.tabs[1].session.is_some(),
            "Stop disconnected the independent tab."
        );
        this.tabs[0].uncertain
    });
    if unknown {
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let settings = this.profile(&profile_id).config.clone();
                assert!(
                    this.tabs[0].begin(settings, 8).is_none(),
                    "An unknown cancellation outcome allowed blind retry."
                );
                this.request_close(crate::close::CloseIntent::Tab(first_id), window, cx);
            });
            window.render_frame(cx);
            assert!(
                window.has_active_dialog(cx),
                "Unknown close skipped acknowledgement."
            );
            window.click("acknowledge-unknown", cx);
        })
        .unwrap();
        await_workspace(cx, &view, |this| {
            !this.closing && this.tabs.iter().all(|tab| tab.id != first_id)
        });
    } else {
        cx.update(|cx| {
            assert_eq!(
                view.read(cx).tabs[0].transaction,
                if postgres {
                    "failedTransaction"
                } else {
                    "transaction"
                },
                "Stop lost the authoritative engine transaction state."
            )
        });
        run(cx, first_id, "ROLLBACK");
        await_workspace(cx, &view, |this| !this.tabs[0].busy());
    }
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            assert_eq!(this.tabs[0].transaction, "idle");
            this.request_close(
                crate::close::CloseIntent::Profile(profile_id.clone()),
                window,
                cx,
            );
        })
    })
    .unwrap();
    await_workspace(cx, &view, |this| !this.closing);
    cx.update(|cx| {
        let this = view.read(cx);
        assert!(
            this.tabs.iter().all(|tab| tab.session.is_none()),
            "Profile disconnect missed a captured tab."
        );
        assert!(
            this.profile(&profile_id).session.is_none(),
            "Catalog session survived profile disconnect."
        );
    });
}

#[gpui_kit::test]
fn postgres_workspace_query_cancel_transaction_routing(cx: &mut TestAppContext) {
    if let Some(connection) = crate::live_tests::postgres_connection() {
        database_workspace(cx, connection);
    }
}
#[gpui_kit::test]
fn mysql_workspace_query_cancel_transaction_routing(cx: &mut TestAppContext) {
    if let Some(connection) = crate::live_tests::mysql_connection() {
        database_workspace(cx, connection);
    }
}

#[gpui_kit::test]
fn queued_success_and_connected_error_use_original_helper_after_replacement(
    cx: &mut TestAppContext,
) {
    let path = std::env::var_os("DBEER_GPUI_HELPER_PATH").expect("Use the GPUI test runner.");
    let replacement = BackendClient::spawn(&path).expect("Start isolated replacement helper.");
    smol::block_on(replacement.handshake()).expect("Replacement handshake.");
    let (window, view) = workspace(cx);
    for error_case in [false, true] {
        let original = BackendClient::spawn(&path).expect("Start isolated original helper.");
        smol::block_on(original.handshake()).expect("Original handshake.");
        let context = cx
            .update_window(window, |_, _, cx| {
                let context = attach(&view, cx);
                view.update(cx, |this, cx| {
                    this.backend = Some(original.clone());
                    this.tabs[0].own_session(original.clone());
                    this.tabs[0].operation_client = Some(original.clone());
                    this.tabs[0].task = Some(cx.spawn(async |_, _| {
                        smol::future::pending::<()>().await;
                    }));
                    original.fail_for_test();
                    this.invalidate_dead_helper();
                    assert!(this.tabs[0].owns(&context) && this.tabs[0].busy());
                });
                context
            })
            .unwrap();
        await_workspace(cx, &view, |_| original.owned_process_exited());
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.backend = Some(replacement.clone());
                if error_case {
                    let mut error = backend::BackendError::transport("Queued original SQL error.");
                    error.category = "sql".into();
                    error.connected = true;
                    error.transaction_status = Some(backend::TransactionStatus::FailedTransaction);
                    this.fail_live(&context, error, window, cx);
                } else {
                    this.finish_live(
                        &context,
                        outcome(backend::TransactionStatus::Idle),
                        window,
                        cx,
                    );
                }
                assert!(
                    this.tabs[0].session.is_none(),
                    "A replacement helper retained an original helper session."
                );
                assert!(!this.tabs[0].busy());
                assert_eq!(
                    this.tabs[0].uncertain, error_case,
                    "A lost open transaction must require acknowledgement."
                );
                assert!(replacement.is_alive());
            });
        })
        .unwrap();
    }
}

#[gpui_kit::test]
fn catalog_endpoint_tls_policy_change_refuses_before_dispatch(cx: &mut TestAppContext) {
    let client = BackendClient::spawn(std::env::var_os("DBEER_GPUI_HELPER_PATH").unwrap())
        .expect("Start isolated helper.");
    smol::block_on(client.handshake()).expect("Complete isolated handshake.");
    let (window, view) = workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.backend = Some(client.clone());
            let settings = crate::connections::ConnectionProfile::new();
            this.profiles
                .push(crate::workspace::Profile::saved(settings.clone()));
            let index = this.profiles.len() - 1;
            for change in [0, 1, 2] {
                let profile = &mut this.profiles[index];
                profile.session = Some("not-a-real-session".into());
                profile.session_settings = Some(settings.clone());
                let mut changed = settings.clone();
                match change {
                    0 => changed.host = "other-host".into(),
                    1 => changed.ssl_mode = "require".into(),
                    _ => changed.readonly = !changed.readonly,
                }
                profile.config = Some(changed);
                profile.schemas = vec![crate::catalog::CatalogSchema::schema("synthetic".into())];
                let generation = profile.generation;
                this.connect_profile(index, window, cx);
                this.expand_schema(index, 0, window, cx);
                this.open_object(
                    index,
                    "synthetic".into(),
                    crate::catalog::CatalogObject {
                        name: "object".into(),
                        kind: "table".into(),
                        identity: None,
                    },
                    window,
                    cx,
                );
                assert!(
                    this.profiles[index].task.is_none(),
                    "Changed catalog context dispatched work to the old session."
                );
                assert_eq!(
                    this.profiles[index].generation, generation,
                    "Changed catalog context began an operation."
                );
            }
            assert!(client.is_alive());
        })
    })
    .unwrap();
}

#[gpui_kit::test]
fn saved_profile_with_legacy_demo_like_id_routes_to_live_operation(cx: &mut TestAppContext) {
    let (window, view) = workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let mut settings = crate::connections::ConnectionProfile::new();
            settings.id = "demo-brewery".into();
            assert!(
                settings.validate().is_ok(),
                "Existing valid profile identity must be preserved."
            );
            this.profiles
                .push(crate::workspace::Profile::saved(settings.clone()));
            this.selected_profile = this.profiles.len() - 1;
            this.add_sql_tab("Saved.sql".into(), "SELECT 1;".into(), window, cx);
            let id = this.tabs[this.active].id;

            assert!(
                this.profile(&this.tabs[this.active].profile)
                    .config
                    .is_some(),
                "A valid saved ID resolved to the built-in demo."
            );
            this.run_query(window, cx);
            let context = this
                .tabs
                .iter()
                .find(|tab| tab.id == id)
                .and_then(|tab| tab.operation.clone())
                .expect("Run must capture the saved profile.");
            assert!(
                context.settings.as_ref() == Some(&settings),
                "Saved SQL routed to demo fixtures."
            );
            assert!(this.tabs[this.active].operation_client.is_some());
            // Cancel before the asynchronous fixture is polled; no credentials or
            // database connection are accessed by this routing regression.
            this.finish_cancelled(&context, cx);
        })
    })
    .unwrap();
}

fn mutation_fixture(
    this: &mut Workspace,
) -> (
    crate::connections::ConnectionProfile,
    std::sync::Arc<crate::profiles::ProfileMutation>,
) {
    let mut original = crate::connections::ConnectionProfile::new();
    original.id = "lifecycle-fixture".into();
    this.profiles
        .push(crate::workspace::Profile::saved(original.clone()));
    this.tabs[0].profile = crate::model::ProfileId::saved(&original);
    this.tabs[0].session = Some("captured-session".into());
    this.tabs[0].session_settings = Some(original.clone());
    let mut candidate = original.clone();
    candidate.host = "replacement.invalid".into();
    candidate.ssl_mode = "verify-ca".into();
    candidate.environment = "production".into();
    candidate.readonly = true;
    let mutation = std::sync::Arc::new(crate::profiles::ProfileMutation {
        change: crate::profiles::ProfileChange::Save(Box::new(
            crate::connections::ProfileSaveRequested {
                profile: candidate,
                expected: Some(original.clone()),
                password: Some(std::sync::Arc::new(crate::startup::Secret::new(
                    "synthetic-replacement".into(),
                ))),
                connect: true,
            },
        )),
        editor: None,
        startup: false,
    });
    (original, mutation)
}

#[gpui_kit::test]
fn profile_mutation_cancel_preserves_transaction_profile_selection_and_editor(
    cx: &mut TestAppContext,
) {
    let (window, view) = workspace(cx);
    cx.update_window(window, |_, window, cx| {
        let (original, editor, selected, document) = view.update(cx, |this, cx| {
            let (original, mutation) = mutation_fixture(this);
            this.tabs[0].transaction = "transaction".into();
            let editor = this.tabs[0].editor.clone();
            let document = this.tabs[0].id;
            let selected = this.profiles[this.selected_profile].id.clone();
            // A vector reorder does not change the captured mutation owner.
            this.profiles.swap(0, 2);
            this.selected_profile = 2;
            this.request_close(
                crate::close::CloseIntent::ProfileMutation(mutation),
                window,
                cx,
            );
            (original, editor, selected, document)
        });
        window.render_frame(cx);
        window.click("cancel-close", cx);
        let this = view.read(cx);
        assert_eq!(this.tabs[0].id, document);
        assert_eq!(this.tabs[0].editor.entity_id(), editor.entity_id());
        assert_eq!(this.tabs[0].session.as_deref(), Some("captured-session"));
        assert_eq!(this.tabs[0].transaction, "transaction");
        assert_eq!(this.tabs[0].session_settings.as_ref(), Some(&original));
        assert_eq!(
            this.profile(&crate::model::ProfileId::saved(&original))
                .config
                .as_ref(),
            Some(&original)
        );
        assert_eq!(this.profiles[this.selected_profile].id, selected);
        assert!(!this.closing);
    })
    .unwrap();
}

#[gpui_kit::test]
fn running_and_unknown_profile_cancel_never_stops_or_acknowledges_implicitly(
    cx: &mut TestAppContext,
) {
    let (window, view) = workspace(cx);
    cx.update_window(window, |_, window, cx| {
        let (original, mutation) = view.update(cx, |this, cx| {
            let (original, mutation) = mutation_fixture(this);
            let context = this.tabs[0].begin(Some(original.clone()), 8).unwrap();
            this.tabs[0].started(&context, "captured-query".into());
            this.request_close(
                crate::close::CloseIntent::ProfileMutation(mutation.clone()),
                window,
                cx,
            );
            (original, mutation)
        });
        window.render_frame(cx);
        window.click("cancel-running-close", cx);
        view.update(cx, |this, cx| {
            assert!(this.tabs[0].busy());
            assert!(!this.tabs[0].stop_requested);
            let context = this.tabs[0].operation.clone().unwrap();
            this.finish_cancelled(&context, cx);
            this.tabs[0].uncertain = true;
            this.request_close(
                crate::close::CloseIntent::ProfileMutation(mutation),
                window,
                cx,
            );
        });
        window.render_frame(cx);
        window.click("cancel-unknown-close", cx);
        let this = view.read(cx);
        assert!(this.tabs[0].uncertain);
        assert_eq!(this.tabs[0].session.as_deref(), Some("captured-session"));
        assert_eq!(
            this.profile(&crate::model::ProfileId::saved(&original))
                .config
                .as_ref(),
            Some(&original)
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn delete_confirmation_and_stale_edit_keep_profile_and_session(cx: &mut TestAppContext) {
    let (window, view) = workspace(cx);
    cx.update_window(window, |_, window, cx| {
        let (original, mutation) = view.update(cx, |this, cx| {
            let (original, mutation) = mutation_fixture(this);
            this.delete_profile(crate::model::ProfileId::saved(&original), window, cx);
            (original, mutation)
        });
        window.render_frame(cx);
        window.click("cancel-delete-profile", cx);
        view.update(cx, |this, cx| {
            let index = this
                .profile_index(&crate::model::ProfileId::saved(&original))
                .unwrap();
            this.profiles[index].config.as_mut().unwrap().host = "external-change.invalid".into();
            this.request_close(
                crate::close::CloseIntent::ProfileMutation(mutation),
                window,
                cx,
            );
            assert_eq!(this.profiles.len(), 3);
            assert_eq!(this.tabs[0].session.as_deref(), Some("captured-session"));
            assert_eq!(this.tabs[0].session_settings.as_ref(), Some(&original));
            assert!(!this.closing);
        });
    })
    .unwrap();
}

#[gpui_kit::test]
fn sql_preparation_captures_selection_and_rejects_invalid_batches_before_helper_startup(
    cx: &mut TestAppContext,
) {
    let (window, view) = workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let settings = crate::connections::ConnectionProfile::new();
            this.profiles
                .push(crate::workspace::Profile::saved(settings.clone()));
            let tab = &mut this.tabs[0];
            tab.profile = crate::model::ProfileId::saved(&settings);
            let id = tab.id;
            let editor = tab.editor.clone();
            let source = "SELECT '😀';\r\nSELECT 2;";
            editor.update(cx, |state, cx| {
                state.set_value(source, window, cx);
                state.set_selected_range(16..24, cx);
            });
            let prepared = this.prepare_execution(id, None, cx).unwrap();
            assert_eq!(prepared.single_statement().unwrap().sql(), "SELECT 2");
            assert_eq!(prepared.single_statement().unwrap().span().bytes(), 16..24);
            // Changing the editor cannot alter an already resolved command.
            editor.update(cx, |state, cx| state.set_value("SELECT 3;", window, cx));
            assert_eq!(prepared.source().text(), source);
            for invalid in [
                "SELECT 1; SELECT 2;",
                "SOURCE x.sql;",
                "SELECT 'incomplete",
                "/* incomplete",
            ] {
                this.run_live(id, Some(invalid.into()), None, window, cx);
                assert!(
                    this.backend.is_none(),
                    "Parsing failure started the helper."
                );
                assert!(!this.tabs[0].busy());
                assert!(this.tabs[0].task.is_none());
                assert!(this.tabs[0].session.is_none());
                assert!(this.tabs[0].error);
            }
            // MySQL routine caret resolution mirrors Swift's default-delimiter reparse.
            // Interim Run refuses that multi-fragment result rather than submitting pieces.
            let profile = this.profiles.last_mut().unwrap();
            profile.config.as_mut().unwrap().engine = "mysql".into();
            editor.update(cx, |state, cx| {
                state.set_value(
                    "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END//",
                    window,
                    cx,
                );
                state.set_selected_range(20..20, cx);
            });
            this.run_live(id, None, None, window, cx);
            assert!(this.backend.is_none());
            assert!(!this.tabs[0].busy());
            assert!(this.tabs[0].status.contains("Multiple statements"));
        });
    })
    .unwrap();
}

fn demo_script(
    cx: &mut TestAppContext,
    window: AnyWindowHandle,
    view: &Entity<Workspace>,
    source: &str,
) -> crate::model::DocumentId {
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let id = this.tabs[0].id;
            this.tabs[0].editor.update(cx, |editor, cx| {
                editor.set_value(source.to_owned(), window, cx);
                editor.focus(window, cx);
            });
            this.command(
                crate::CommandId::RunScript,
                crate::CommandOrigin::Button,
                None,
                window,
                cx,
            );
            id
        })
    })
    .unwrap()
}

#[gpui_kit::test]
fn script_whole_source_review_is_required_for_demo_and_keyboard_cancel_sends_nothing(
    cx: &mut TestAppContext,
) {
    for key in ["enter", "escape"] {
        let (window, view) = workspace(cx);
        demo_script(
            cx,
            window,
            &view,
            "SELECT COUNT(*) FROM public.products;\r\nSELECT COUNT(*) FROM public.orders;",
        );
        cx.update_window(window, |_, window, cx| {
            window.render_frame(cx);
            assert!(window.has_active_dialog(cx));
            view.update(cx, |this, cx| {
                this.can_close_window(window, cx);
                let token = this.close_flow.as_ref().unwrap().token;
                this.can_close_window(window, cx);
                assert_eq!(this.close_flow.as_ref().unwrap().token, token);
                assert_eq!(
                    this.close_flow.as_ref().unwrap().phase,
                    crate::close::ClosePhase::OwnersWaiting
                );
                assert!(!this.tabs[0].stop_requested);
                // Cancel only the pending close; the original script review
                // keeps its focus and keyboard cancellation authority.
                this.cancel_close(&token, window, cx);
                assert!(this.close_flow.is_none());
            });
            let this = view.read(cx);
            assert_eq!(
                this.tabs[0].phase,
                Some(crate::model::OperationPhase::Reviewing)
            );
            assert!(this.tabs[0].result_sets.is_empty() && this.backend.is_none());
            window.press(key, cx);
        })
        .unwrap();
        await_workspace(cx, &view, |this| !this.tabs[0].busy());
        cx.update(|cx| {
            let this = view.read(cx);
            assert!(this.backend.is_none() && this.tabs[0].result_sets.is_empty());
            assert!(this.tabs[0].successful_ranges.is_empty());
            assert!(
                this.tabs[0]
                    .executions
                    .iter()
                    .all(|e| e.state != crate::model::ExecutionState::Succeeded)
            );
        });
    }
}

#[gpui_kit::test]
fn script_review_remains_on_original_tab_and_source_edit_invalidates_approval(
    cx: &mut TestAppContext,
) {
    let (window, view) = workspace(cx);
    let id = demo_script(
        cx,
        window,
        &view,
        "SELECT COUNT(*) FROM public.products; SELECT COUNT(*) FROM public.orders;",
    );
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.tabs[0].editor.update(cx, |editor, cx| {
                editor.set_value("SELECT COUNT(*) FROM public.customers;", window, cx)
            });
            this.add_sql_tab("Other.sql".into(), "SELECT 9;".into(), window, cx);
        });
        window.render_frame(cx);
        window.click("confirm-execution", cx);
    })
    .unwrap();
    await_workspace(cx, &view, |this| {
        !this.tabs.iter().find(|t| t.id == id).unwrap().busy()
    });
    cx.update(|cx| {
        let this = view.read(cx);
        assert!(
            this.tabs
                .iter()
                .all(|t| t.result_sets.is_empty() && t.successful_ranges.is_empty() && !t.busy())
        );
        assert!(this.backend.is_none());
    });
}

#[gpui_kit::test]
fn reviewed_script_keeps_statement_results_and_skips_after_first_failure(cx: &mut TestAppContext) {
    let (window, view) = workspace(cx);
    let id = demo_script(
        cx,
        window,
        &view,
        "SELECT COUNT(*) FROM public.products; SELECT unsupported_fixture; SELECT COUNT(*) FROM public.orders;",
    );
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        window.click("confirm-execution", cx);
        view.update(cx, |this, cx| {
            this.add_sql_tab("Other.sql".into(), "SELECT 9;".into(), window, cx)
        });
    })
    .unwrap();
    await_workspace(cx, &view, |this| {
        !this.tabs.iter().find(|t| t.id == id).unwrap().busy()
    });
    cx.update(|cx| {
        use crate::model::ExecutionState as S;
        let this = view.read(cx);
        let tab = this.tabs.iter().find(|t| t.id == id).unwrap();
        assert_eq!(
            tab.executions.iter().map(|e| e.state).collect::<Vec<_>>(),
            [S::Succeeded, S::Failed, S::Skipped]
        );
        assert_eq!(tab.executions[0].results, 0..1);
        assert_eq!(tab.result_sets.len(), 1);
        assert_eq!(tab.successful_ranges.len(), 1);
        assert!(tab.executions[1].failure.is_some() && this.tabs[1].result_sets.is_empty());
        assert_eq!(tab.execution_source.as_ref().unwrap().statements().len(), 3);
    });
}

#[gpui_kit::test]
fn script_stop_preserves_prefix_clears_active_highlight_and_marks_no_cancelled_success(
    cx: &mut TestAppContext,
) {
    let (window, view) = workspace(cx);
    let id = demo_script(
        cx,
        window,
        &view,
        "SELECT COUNT(*) FROM public.products; SELECT COUNT(*) FROM public.orders; SELECT COUNT(*) FROM public.customers;",
    );
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        window.click("confirm-execution", cx);
    })
    .unwrap();
    await_workspace(cx, &view, |this| {
        this.tabs[0].active_execution == 1 && this.tabs[0].busy()
    });
    cx.update(|cx| view.update(cx, |this, cx| this.stop_document(id, cx)));
    cx.update(|cx| {
        use crate::model::ExecutionState as S;
        let tab = &view.read(cx).tabs[0];
        assert!(!tab.busy());
        assert_eq!(
            tab.executions.iter().map(|e| e.state).collect::<Vec<_>>(),
            [S::Succeeded, S::Cancelled, S::Skipped]
        );
        assert_eq!(tab.successful_ranges.len(), 1);
        assert!(tab.execution_decoration.get_ranges(cx).is_empty());
    });
}

#[gpui_kit::test]
fn script_error_navigation_uses_original_unicode_source_and_unknown_terminal_keeps_lock(
    cx: &mut TestAppContext,
) {
    let (window, view) = workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let source = "SELECT '😀';\r\nSELECT 'é😀'; SELECT 3;";
            let tab = &mut this.tabs[0];
            let id = tab.id;
            tab.editor
                .update(cx, |editor, cx| editor.set_value(source, window, cx));
            let fragment = crate::sql::resolve(
                crate::sql::SourceText::new(source),
                0..0,
                crate::sql::Dialect::PostgreSQL,
                true,
            )
            .unwrap();
            let context = tab.begin(None, source.len()).unwrap();
            tab.prepare_batch(std::sync::Arc::new(fragment));
            let context = tab.attach(&context, "original-session".into()).unwrap();
            tab.started(&context, "first".into());
            this.record_live_statement(
                &context,
                outcome(backend::TransactionStatus::Transaction),
                window,
                cx,
            );
            let tab = &mut this.tabs[0];
            tab.active_execution = 1;
            tab.started(&context, "second".into());
            let expected = tab.execution_source.as_ref().unwrap().statements()[1]
                .map_adapter_error(Some(10))
                .unwrap()
                .unwrap();
            this.fail_live(
                &context,
                backend::BackendError {
                    message: "Synthetic SQL failure".into(),
                    category: "sql".into(),
                    connected: true,
                    outcome_unknown: false,
                    sql_completed: false,
                    sql_not_executed: false,
                    export_publication: None,
                    transaction_status: Some(backend::TransactionStatus::FailedTransaction),
                    sql_state: Some("42601".into()),
                    error_position: Some(10),
                    result_sets: vec![backend::ResultSet::default()],
                },
                window,
                cx,
            );
            assert_eq!(this.tabs[0].transaction, "failedTransaction");
            assert_eq!(this.tabs[0].result_sets.len(), 2);
            assert_eq!(this.tabs[0].executions[1].results, 1..2);
            this.navigate_execution_error(id, window, cx);
            assert_eq!(
                this.tabs[0].editor.read(cx).selected_range(),
                expected.source.byte..expected.source.byte
            );
            assert_eq!(this.tabs[0].successful_ranges.len(), 1);
            // A subsequent submitted request without a terminal cannot become a
            // successful operation or allow another Run, even in autocommit.
            let tab = &mut this.tabs[0];
            let context = tab.begin(None, source.len()).unwrap();
            tab.started(&context, "lost".into());
            let mut error = backend::BackendError::transport("Synthetic lost terminal");
            error.outcome_unknown = true;
            this.fail_live(&context, error, window, cx);
            assert!(this.tabs[0].uncertain && this.tabs[0].successful_ranges.is_empty());
            assert!(this.tabs[0].begin(None, 1).is_none());
        });
    })
    .unwrap();
}

#[gpui_kit::test]
fn close_cancel_retains_pid_window_query_and_exact_session_across_every_origin(
    cx: &mut TestAppContext,
) {
    use crate::{
        close::CloseIntent,
        commands::{CommandId, CommandOrigin},
    };
    let (window, view) = workspace(cx);
    let pid = std::process::id();
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let (original, _) = mutation_fixture(this);
            let context = this.tabs[0].begin(Some(original), 8).unwrap();
            this.tabs[0].started(&context, "running-close-query".into());
            this.command(CommandId::CloseTab, CommandOrigin::Button, None, window, cx);
            let first = this.close_flow.as_ref().unwrap().token;
            this.request_close(
                CloseIntent::Profile(this.tabs[0].profile.clone()),
                window,
                cx,
            );
            this.command(CommandId::Quit, CommandOrigin::System, None, window, cx);
            assert_eq!(this.close_flow.as_ref().unwrap().token, first);
            assert!(!this.tabs[0].stop_requested);
        });
        window.render_frame(cx);
        assert!(window.try_find("stop-running-close").is_some());
        window.click("cancel-running-close", cx);
        let this = view.read(cx);
        assert!(this.tabs[0].busy());
        assert_eq!(
            this.tabs[0].query_id.as_deref(),
            Some("running-close-query")
        );
        assert_eq!(this.tabs[0].session.as_deref(), Some("captured-session"));
        assert!(!this.tabs[0].stop_requested);
        assert!(!this.closing);
        assert!(this.close_flow.is_none());
        assert_eq!(std::process::id(), pid);
    })
    .unwrap();
    assert!(cx.update_window(window, |_, _, _| ()).is_ok());
}

#[gpui_kit::test]
fn native_window_guard_repeats_review_and_failed_transaction_has_no_commit(
    cx: &mut TestAppContext,
) {
    let (window, view) = workspace(cx);
    cx.update_window(window, |_, _, cx| {
        view.update(cx, |this, _| {
            mutation_fixture(this);
            this.tabs[0].transaction = "failedTransaction".into();
        });
    })
    .unwrap();
    {
        let mut visual = gpui_kit::VisualTestContext::from_window(window, cx);
        assert!(!visual.simulate_close());
        assert!(!visual.simulate_close());
    }
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("commit-close").is_none());
        assert!(window.try_find("rollback-close").is_some());
        window.click("cancel-close", cx);
        assert_eq!(view.read(cx).tabs[0].transaction, "failedTransaction");
        assert_eq!(
            view.read(cx).tabs[0].session.as_deref(),
            Some("captured-session")
        );
        assert!(!view.read(cx).closing);
    })
    .unwrap();
}

#[gpui_kit::test]
fn return_and_escape_are_cancel_for_running_close_and_keep_original_operation(
    cx: &mut TestAppContext,
) {
    let (window, view) = workspace(cx);
    for key in ["enter", "escape"] {
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                if !this.tabs[0].busy() {
                    let (original, _) = mutation_fixture(this);
                    this.tabs[0].begin(Some(original), 8).unwrap();
                }
                this.request_close(crate::close::CloseIntent::Window, window, cx);
            });
            window.render_frame(cx);
            window.press(key, cx);
        })
        .unwrap();
        cx.run_until_parked();
        cx.update_window(window, |_, window, cx| {
            assert!(!window.has_active_dialog(cx));
            assert!(view.read(cx).tabs[0].busy());
            assert!(!view.read(cx).tabs[0].stop_requested);
            assert!(!view.read(cx).closing);
        })
        .unwrap();
    }
}

#[gpui_kit::test]
fn unacknowledged_disconnect_never_removes_document_or_accepts_repeated_close(
    cx: &mut TestAppContext,
) {
    let Some(path) = std::env::var_os("DBEER_GPUI_HELPER_PATH") else {
        return;
    };
    cx.update(|cx| cx.background_executor().allow_parking());
    let client = BackendClient::spawn(path).expect("Start exact owned fault helper.");
    smol::block_on(client.handshake()).expect("Handshake owned fault helper.");
    let (window, view) = workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            mutation_fixture(this);
            this.backend = Some(client.clone());
            this.tabs[0].own_session(client.clone());
            let id = this.tabs[0].id;
            this.request_close(crate::close::CloseIntent::Tab(id), window, cx);
            let token = this.close_flow.as_ref().unwrap().token;
            assert_eq!(
                this.close_flow.as_ref().unwrap().phase,
                crate::close::ClosePhase::Disconnecting
            );
            this.can_close_window(window, cx);
            this.request_close(crate::close::CloseIntent::Tab(id), window, cx);
            assert_eq!(this.close_flow.as_ref().unwrap().token, token);
        });
    })
    .unwrap();
    await_workspace(cx, &view, |this| !this.closing);
    cx.update_window(window, |_, window, cx| {
        assert_eq!(view.read(cx).tabs.len(), 1);
        assert!(window.has_active_dialog(cx));
        assert!(view.read(cx).close_flow.is_none());
    })
    .unwrap();
}

#[gpui_kit::test]
fn stop_close_waits_for_original_terminal_and_unknown_loss_stays_reviewable(
    cx: &mut TestAppContext,
) {
    let Some(path) = std::env::var_os("DBEER_GPUI_HELPER_PATH") else {
        return;
    };
    cx.update(|cx| cx.background_executor().allow_parking());
    let client = BackendClient::spawn(path).expect("Start owned terminal-gap helper.");
    smol::block_on(client.handshake()).expect("Handshake terminal-gap helper.");
    let (window, view) = workspace(cx);
    let context = cx
        .update_window(window, |_, window, cx| {
            let context = view.update(cx, |this, cx| {
                let (original, _) = mutation_fixture(this);
                this.backend = Some(client.clone());
                let tab = &mut this.tabs[0];
                let context = tab.begin(Some(original), 8).unwrap();
                tab.started(&context, "terminal-gap-query".into());
                tab.operation_client = Some(client.clone());
                tab.task = Some(cx.spawn(async |_, _| smol::future::pending::<()>().await));
                this.request_close(crate::close::CloseIntent::Tab(context.document), window, cx);
                context
            });
            window.render_frame(cx);
            window.click("stop-running-close", cx);
            view.update(cx, |this, cx| {
                assert!(this.tabs[0].busy() && this.tabs[0].stop_requested);
                assert_eq!(this.tabs[0].query_id.as_deref(), Some("terminal-gap-query"));
                let token = this.close_flow.as_ref().unwrap().token;
                this.can_close_window(window, cx);
                this.request_close(crate::close::CloseIntent::Tab(context.document), window, cx);
                assert_eq!(this.close_flow.as_ref().unwrap().token, token);
            });
            context
        })
        .unwrap();
    // The actual helper refuses cancellation of this synthetic query identity.
    // That Stop response alone must not release the original operation lock.
    cx.run_until_parked();
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            assert!(this.tabs[0].busy());
            let mut terminal = backend::BackendError::transport("Synthetic authoritative loss.");
            terminal.outcome_unknown = true;
            this.fail_live(&context, terminal, window, cx);
        });
    })
    .unwrap();
    await_workspace(cx, &view, |this| {
        this.close_flow
            .as_ref()
            .is_some_and(|flow| flow.phase == crate::close::ClosePhase::Unknown)
    });
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(view.read(cx).tabs[0].id, context.document);
        assert!(view.read(cx).tabs[0].uncertain);
        window.click("cancel-unknown-close", cx);
        assert!(view.read(cx).tabs[0].uncertain);
        assert!(!view.read(cx).closing);
    })
    .unwrap();
}

#[gpui_kit::test]
fn selected_commit_is_idempotent_editor_independent_and_bound_to_original_helper(
    cx: &mut TestAppContext,
) {
    let Some(path) = std::env::var_os("DBEER_GPUI_HELPER_PATH") else {
        return;
    };
    cx.update(|cx| cx.background_executor().allow_parking());
    let original = BackendClient::spawn(&path).expect("Start owned resolution helper.");
    smol::block_on(original.handshake()).expect("Handshake resolution helper.");
    let replacement = BackendClient::spawn(path).expect("Start owned replacement helper.");
    smol::block_on(replacement.handshake()).expect("Handshake replacement helper.");
    let (window, view) = workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            mutation_fixture(this);
            this.backend = Some(original.clone());
            this.tabs[0].own_session(original.clone());
            this.tabs[0].transaction = "transaction".into();
            this.request_close(crate::close::CloseIntent::Tab(this.tabs[0].id), window, cx);
        });
        window.render_frame(cx);
        window.click("commit-close", cx);
        view.update(cx, |this, cx| {
            let context = this.tabs[0].operation.clone().unwrap();
            let token = this.close_flow.as_ref().unwrap().token;
            this.can_close_window(window, cx);
            this.request_close(crate::close::CloseIntent::Tab(context.document), window, cx);
            assert_eq!(this.close_flow.as_ref().unwrap().token, token);
            assert!(this.tabs[0].busy() && this.tabs[0].resolving_close);
            assert!(!this.tabs[0].stop_requested);
            this.tabs[0].editor.update(cx, |editor, cx| {
                editor.insert(" -- unrelated edit", window, cx)
            });
            assert!(this.operation_source_valid(&context, cx));
            assert!(
                this.close_resolution_client(token, context.document)
                    .unwrap()
                    .same_instance(&original)
            );
            this.backend = Some(replacement.clone());
            assert!(
                this.close_resolution_client(token, context.document)
                    .unwrap()
                    .same_instance(&original)
            );
            // A stale terminal for the old operation cannot alter a newer close.
            this.cancel_close(&token, window, cx);
        });
    })
    .unwrap();
}

#[gpui_kit::test]
fn cancelled_close_callbacks_cannot_cancel_a_new_review(cx: &mut TestAppContext) {
    let (window, view) = workspace(cx);
    cx.update_window(window, |_, window, cx| {
        let old = view.update(cx, |this, cx| {
            let (original, _) = mutation_fixture(this);
            this.tabs[0].begin(Some(original), 8).unwrap();
            this.request_close(crate::close::CloseIntent::Tab(this.tabs[0].id), window, cx);
            this.close_flow.as_ref().unwrap().token
        });
        window.render_frame(cx);
        window.click("cancel-running-close", cx);
        view.update(cx, |this, cx| {
            this.request_close(crate::close::CloseIntent::Window, window, cx);
            let new = this.close_flow.as_ref().unwrap().token;
            assert_ne!(old, new);
            this.cancel_close(&old, window, cx);
            assert_eq!(this.close_flow.as_ref().unwrap().token, new);
            assert!(this.closing && !this.tabs[0].stop_requested);
        });
        window.render_frame(cx);
        assert!(window.try_find("cancel-running-close").is_some());
    })
    .unwrap();
}

fn attach_draft_store(
    cx: &mut TestAppContext,
    view: &Entity<Workspace>,
) -> (std::path::PathBuf, crate::restoration::WorkspaceStore) {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../build/gpui/restoration-ui-tests")
        .join(crate::restoration::new_uuid());
    let owner = crate::instance::DataDirectory::acquire(&root).unwrap();
    let store = crate::restoration::WorkspaceStore::new(owner);
    store.load().unwrap();
    cx.update(|cx| {
        view.update(cx, |this, cx| {
            this.restoration.store = Some(store.clone());
            this.restoration.debounce = None;
            store.reserve(this.document_snapshot(cx)).commit().unwrap();
        })
    });
    (root, store)
}

#[gpui_kit::test]
fn restored_draft_uuid_order_selection_missing_binding_and_history_reopen_stay_disconnected(
    cx: &mut TestAppContext,
) {
    use crate::restoration::{Snapshot, StoredDocument};
    let (window, view) = workspace_with_policy(
        cx,
        crate::product_identity::StartupPolicy::new(
            crate::product_identity::Platform::Linux,
            false,
        ),
    );
    let (root, store) = attach_draft_store(cx, &view);
    let first = StoredDocument {
        id: crate::restoration::new_uuid(),
        title: "Saved analysis".into(),
        text: "SELECT '😀';\r\n".into(),
        profile_id: Some("legacy-missing-profile".into()),
    };
    let second = StoredDocument {
        id: crate::restoration::new_uuid(),
        title: "Unbound draft".into(),
        text: "SELECT 2;".into(),
        profile_id: None,
    };
    let saved = Snapshot {
        documents: vec![first.clone(), second.clone()],
        selected_document_id: Some(first.id.clone()),
        ..Snapshot::default()
    };
    store.reserve(saved).commit().unwrap();
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.tabs.clear();
            this.restoration.ready = false;
            this.restore_local_documents(window, cx);
            this.restoration.ready = true;
            assert_eq!(this.active, 0);
            assert_eq!(this.tabs[0].persistent_id, first.id);
            assert_eq!(this.tabs[1].persistent_id, second.id);
            assert_eq!(this.tabs[0].profile.0, "legacy-missing-profile");
            assert!(
                this.profiles.is_empty(),
                "Restoration invented a missing or unbound connection."
            );
            assert!(!this.document_profile_available(&this.tabs[0].profile));
            assert!(this.backend.is_none());
            assert!(this.tabs.iter().all(|tab| tab.session.is_none()
                && tab.result_sets.is_empty()
                && tab.executions.is_empty()
                && !tab.busy()
                && !tab.uncertain
                && tab.transaction == "idle"
                && tab.file.binding.is_none()));
            assert_eq!(this.tabs[0].editor.read(cx).value().as_ref(), first.text);
            let retained = this.tabs[0].editor.entity_id();
            let history_id = crate::restoration::new_uuid();
            this.restoration
                .snapshot
                .history
                .push(crate::restoration::HistoryEntry {
                    id: history_id.clone(),
                    date: crate::restoration::now_ms(),
                    document_id: Some(first.id.clone()),
                    profile_id: first.profile_id.clone(),
                    sql: first.text.clone(),
                    outcome: "Completed".into(),
                });
            assert!(this.reopen_history(&history_id, window, cx));
            let opened = &this.tabs[this.active];
            assert_ne!(opened.persistent_id, first.id);
            assert_eq!(opened.profile.0, "legacy-missing-profile");
            assert!(
                opened.session.is_none()
                    && opened.executions.is_empty()
                    && opened.result_sets.is_empty()
                    && !opened.busy()
            );
            assert_eq!(this.tabs[0].editor.entity_id(), retained);
            let source = opened.editor.read(cx).value();
            this.run_prepared(
                opened.id,
                std::sync::Arc::new(
                    crate::sql::resolve(
                        crate::sql::SourceText::new(source.to_string()),
                        0..0,
                        crate::sql::Dialect::PostgreSQL,
                        false,
                    )
                    .unwrap(),
                ),
                window,
                cx,
            );
            assert!(this.backend.is_none() && !this.tabs[this.active].busy());
            assert_eq!(
                this.tabs[this.active].editor.read(cx).value().as_ref(),
                first.text
            );
        });
    })
    .unwrap();
    _ = std::fs::remove_dir_all(root);
}

#[gpui_kit::test]
fn history_records_each_submitted_statement_once_skips_unsubmitted_and_honors_disabled_recording(
    cx: &mut TestAppContext,
) {
    let (window, view) = workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let fragment = std::sync::Arc::new(
                crate::sql::resolve(
                    crate::sql::SourceText::new("SELECT 1; SELECT 2; SELECT 3;"),
                    0..0,
                    crate::sql::Dialect::PostgreSQL,
                    true,
                )
                .unwrap(),
            );
            let context = this.tabs[0]
                .begin(None, fragment.source().text().len())
                .unwrap();
            this.tabs[0].prepare_batch(fragment);
            this.tabs[0].started(&context, "synthetic-first".into());
            let terminal = || backend::QueryOutcome {
                result_sets: Vec::new(),
                duration_ms: 1.,
                row_count: 0,
                transaction_status: backend::TransactionStatus::Idle,
                command_tag: "SELECT".into(),
                truncated: false,
                display_notice: String::new(),
                export: None,
            };
            this.record_live_statement(&context, terminal(), window, cx);
            this.record_live_statement(&context, terminal(), window, cx);
            assert_eq!(this.restoration.snapshot.history.len(), 1);
            this.tabs[0].active_execution = 1;
            this.tabs[0].started(&context, "synthetic-second".into());
            this.fail_live(
                &context,
                backend::BackendError {
                    message: "Synthetic refusal".into(),
                    category: "sql".into(),
                    connected: true,
                    outcome_unknown: false,
                    sql_completed: false,
                    sql_not_executed: false,
                    export_publication: None,
                    transaction_status: Some(backend::TransactionStatus::Idle),
                    sql_state: None,
                    error_position: None,
                    result_sets: Vec::new(),
                },
                window,
                cx,
            );
            assert_eq!(
                this.restoration
                    .snapshot
                    .history
                    .iter()
                    .map(|e| e.outcome.as_str())
                    .collect::<Vec<_>>(),
                ["Completed", "Query failed"]
            );
            assert_eq!(
                this.restoration
                    .snapshot
                    .history
                    .iter()
                    .map(|e| e.sql.as_str())
                    .collect::<Vec<_>>(),
                ["SELECT 1", "SELECT 2"]
            );
            assert_eq!(
                this.tabs[0].executions[2].state,
                crate::model::ExecutionState::Skipped
            );
            this.record_live_statement(&context, terminal(), window, cx);
            assert_eq!(this.restoration.snapshot.history.len(), 2);
            this.restoration.snapshot.history_enabled = false;
            let fragment = std::sync::Arc::new(
                crate::sql::resolve(
                    crate::sql::SourceText::new("SELECT 4;"),
                    0..0,
                    crate::sql::Dialect::PostgreSQL,
                    true,
                )
                .unwrap(),
            );
            let next = this.tabs[0].begin(None, 9).unwrap();
            this.tabs[0].prepare_batch(fragment);
            this.tabs[0].started(&next, "synthetic-disabled".into());
            this.finish_live(&next, terminal(), window, cx);
            assert_eq!(this.restoration.snapshot.history.len(), 2);
        });
    })
    .unwrap();
}

#[gpui_kit::test]
fn clear_drafts_cancel_preserves_editor_saved_sql_and_durable_snapshot(cx: &mut TestAppContext) {
    let (window, view) = workspace(cx);
    let (root, store) = attach_draft_store(cx, &view);
    let sql_file = root.join("keep.sql");
    std::fs::write(&sql_file, b"SELECT 99;\r\n").unwrap();
    let before = std::fs::read(root.join("workspace.json")).unwrap();
    let original = cx.update(|cx| view.read(cx).tabs[0].editor.entity_id());
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.tabs[0].begin(None, 8).unwrap();
            this.request_close(crate::close::CloseIntent::ClearDrafts, window, cx);
        });
        window.render_frame(cx);
        window.click("cancel-running-close", cx);
        assert!(!view.read(cx).closing);
        assert_eq!(view.read(cx).tabs[0].editor.entity_id(), original);
        assert!(view.read(cx).tabs[0].busy() && !view.read(cx).tabs[0].stop_requested);
    })
    .unwrap();
    assert_eq!(std::fs::read(root.join("workspace.json")).unwrap(), before);
    assert_eq!(std::fs::read(sql_file).unwrap(), b"SELECT 99;\r\n");
    assert_eq!(store.load().unwrap().documents.len(), 1);
    _ = std::fs::remove_dir_all(root);
}

#[gpui_kit::test]
fn final_draft_flush_failure_keeps_retryable_window_then_clear_persists_empty_without_deleting_sql(
    cx: &mut TestAppContext,
) {
    cx.update(|cx| cx.background_executor().allow_parking());
    let (window, view) = workspace_with_policy(
        cx,
        crate::product_identity::StartupPolicy::new(
            crate::product_identity::Platform::MacDevelopment,
            false,
        ),
    );
    let draft = "-- edited ordinary product draft\r\n";
    cx.update_window(window, |_, window, cx| {
        let this = view.read(cx);
        assert!(this.profiles.is_empty() && this.backend.is_none());
        assert_eq!(this.tabs.len(), 1);
        assert_eq!(this.tabs[0].profile, crate::model::ProfileId::unbound());
        assert_eq!(this.tabs[0].editor.read(cx).value().as_ref(), "");
        let editor = this.tabs[0].editor.clone();
        editor.update(cx, |editor, cx| editor.set_value(draft, window, cx));
    })
    .unwrap();
    let (root, store) = attach_draft_store(cx, &view);
    let initial = store.load().unwrap();
    assert_eq!(initial.documents.len(), 1);
    assert_eq!(initial.documents[0].text, draft);
    assert_eq!(initial.documents[0].profile_id, None);
    let sql_file = root.join("keep.sql");
    std::fs::write(&sql_file, b"SELECT 77;").unwrap();
    let before = std::fs::read(root.join("workspace.json")).unwrap();
    let original = cx.update(|cx| {
        (
            view.read(cx).tabs[0].id,
            view.read(cx).tabs[0].editor.clone(),
            view.read(cx).tabs[0].persistent_id.clone(),
        )
    });
    store.fail_replacement(true);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.request_close(crate::close::CloseIntent::ClearDrafts, window, cx)
        });
    })
    .unwrap();
    await_workspace(cx, &view, |this| !this.closing);
    cx.update_window(window, |_, window, cx| {
        let this = view.read(cx);
        assert_eq!(this.tabs.len(), 1);
        assert_eq!(this.tabs[0].id, original.0);
        assert_eq!(this.tabs[0].editor, original.1);
        assert_eq!(this.tabs[0].persistent_id, original.2);
        assert_eq!(this.tabs[0].editor.read(cx).value().as_ref(), draft);
        assert!(this.restoration.error.is_some());
        assert!(window.has_active_dialog(cx));
        window.close_dialog(cx);
    })
    .unwrap();
    assert_eq!(std::fs::read(root.join("workspace.json")).unwrap(), before);
    store.fail_replacement(false);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.request_close(crate::close::CloseIntent::ClearDrafts, window, cx)
        });
    })
    .unwrap();
    await_workspace(cx, &view, |this| !this.closing);
    let cleared = store.load().unwrap();
    assert!(cleared.documents.is_empty());
    assert_eq!(cleared.selected_document_id, None);
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        let this = view.read(cx);
        assert_eq!(this.tabs.len(), 1);
        let replacement = &this.tabs[0];
        assert_ne!(replacement.id, original.0);
        assert_ne!(replacement.editor, original.1);
        assert_ne!(replacement.persistent_id, original.2);
        assert_eq!(replacement.editor.read(cx).value().as_ref(), "");
        assert_eq!(replacement.profile, crate::model::ProfileId::unbound());
        assert_eq!(this.document_snapshot(cx).documents[0].profile_id, None);
        assert!(
            replacement.session.is_none()
                && replacement.session_settings.is_none()
                && replacement.session_owner.is_none()
                && replacement.query_id.is_none()
                && replacement.operation_client.is_none()
                && replacement.task.is_none()
                && replacement.execution_source.is_none()
                && replacement.executions.is_empty()
                && replacement.result_sets.is_empty()
        );
        assert_eq!(replacement.transaction, "idle");
        assert!(!replacement.busy() && !replacement.uncertain);
        assert!(this.profiles.is_empty() && this.backend.is_none());
        assert!(this.restoration.error.is_none());
    })
    .unwrap();
    assert_eq!(std::fs::read(sql_file).unwrap(), b"SELECT 77;");
    _ = std::fs::remove_dir_all(root);
}

#[gpui_kit::test]
fn window_final_flush_rechecks_edits_before_exit_and_preserves_open_document_uuid(
    cx: &mut TestAppContext,
) {
    cx.update(|cx| cx.background_executor().allow_parking());
    let (window, view) = workspace(cx);
    let (root, store) = attach_draft_store(cx, &view);
    let durable_id = cx.update(|cx| view.read(cx).tabs[0].persistent_id.clone());
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.request_close(crate::close::CloseIntent::Window, window, cx);
            assert_eq!(
                this.close_flow.as_ref().unwrap().phase,
                crate::close::ClosePhase::Finishing
            );
            this.tabs[0].editor.update(cx, |editor, cx| {
                editor.set_value("SELECT 'latest 😀';\r\n", window, cx)
            });
            this.schedule_documents(cx);
            assert!(this.restoration.debounce.is_none());
        });
    })
    .unwrap();
    await_workspace(cx, &view, |this| !this.closing);
    let saved = store.load().unwrap();
    assert_eq!(saved.documents[0].id, durable_id);
    assert_eq!(saved.documents[0].text, "SELECT 'latest 😀';\r\n");
    assert_eq!(saved.selected_document_id.as_ref(), Some(&durable_id));
    _ = std::fs::remove_dir_all(root);
}

#[gpui_kit::test]
fn history_command_panel_toggle_and_clear_callbacks_persist_without_database_work(
    cx: &mut TestAppContext,
) {
    cx.update(|cx| cx.background_executor().allow_parking());
    let (window, view) = workspace(cx);
    let (root, store) = attach_draft_store(cx, &view);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.restoration
                .snapshot
                .history
                .push(crate::restoration::HistoryEntry {
                    id: crate::restoration::new_uuid(),
                    date: crate::restoration::now_ms(),
                    document_id: None,
                    profile_id: None,
                    sql: "SELECT 'private local history';".into(),
                    outcome: "Completed".into(),
                });
            this.command(
                crate::CommandId::History,
                crate::CommandOrigin::Menu,
                None,
                window,
                cx,
            );
        });
        window.render_frame(cx);
        window.click("history-enabled", cx);
        assert!(!view.read(cx).restoration.snapshot.history_enabled);
        window.render_frame(cx);
        window.click("history-clear", cx);
        assert!(view.read(cx).restoration.snapshot.history.is_empty());
        assert!(view.read(cx).backend.is_none());
    })
    .unwrap();
    await_workspace(cx, &view, |this| {
        this.restoration.saved_revision == this.restoration.revision
    });
    let saved = store.load().unwrap();
    assert!(!saved.history_enabled && saved.history.is_empty());
    _ = std::fs::remove_dir_all(root);
}
