//! Native AppKit termination checks against disposable PostgreSQL and MySQL.
//! A supervisor survives each app's successful exit and verifies the durable result.

use super::*;
use backend::{Connection, ExecutionPolicy, QueryEvent, QueryOutcome};
use gpui_kit::test::TestWindowExt;
use std::{
    cell::Cell,
    future::Future,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    rc::Rc,
    time::Instant,
};

type SmokeResult<T> = std::result::Result<T, String>;

fn required(name: &str) -> SmokeResult<String> {
    std::env::var(name).map_err(|_| "An isolated termination-test setting is missing.".into())
}

fn fixtures() -> SmokeResult<Vec<Connection>> {
    if required("DBEER_GPUI_DISPOSABLE_DATABASES")? != "1" {
        return Err("Termination checks require disposable database runners.".into());
    }
    let dsn = required("DBEER_TEST_DSN")?;
    let dsn = dsn
        .strip_prefix("postgresql://")
        .ok_or("Unexpected PostgreSQL fixture format.")?;
    let (credentials, address) = dsn
        .split_once('@')
        .ok_or("Invalid PostgreSQL fixture settings.")?;
    let (user, password) = credentials
        .split_once(':')
        .ok_or("Invalid PostgreSQL fixture settings.")?;
    let (address, database) = address
        .split_once('/')
        .ok_or("Invalid PostgreSQL fixture settings.")?;
    let (host, port) = address
        .rsplit_once(':')
        .ok_or("Invalid PostgreSQL fixture settings.")?;
    let database = database
        .strip_suffix("?sslmode=disable")
        .ok_or("Unexpected PostgreSQL fixture TLS settings.")?;
    let policy = ExecutionPolicy {
        environment: "development".into(),
        read_only: false,
    };
    Ok(vec![
        Connection {
            engine: "postgresql".into(),
            host: host.into(),
            port: port
                .parse()
                .map_err(|_| "Invalid PostgreSQL fixture port.")?,
            database: database.into(),
            user: user.into(),
            password: password.into(),
            ssl_mode: "disable".into(),
            ssl_root_cert: None,
            policy: policy.clone(),
        },
        Connection {
            engine: "mysql".into(),
            host: required("DBEER_TEST_MYSQL_HOST")?,
            port: required("DBEER_TEST_MYSQL_PORT")?
                .parse()
                .map_err(|_| "Invalid MySQL fixture port.")?,
            database: required("DBEER_TEST_MYSQL_DATABASE")?,
            user: required("DBEER_TEST_MYSQL_USER")?,
            password: required("DBEER_TEST_MYSQL_PASSWORD")?,
            ssl_mode: required("DBEER_TEST_MYSQL_SSLMODE")?,
            ssl_root_cert: None,
            policy,
        },
    ])
}

async fn bounded<T>(future: impl Future<Output = T>) -> SmokeResult<T> {
    smol::future::race(async { Ok(future.await) }, async {
        smol::Timer::after(Duration::from_secs(15)).await;
        Err("The termination-test helper exceeded its deadline.".into())
    })
    .await
}

async fn helper() -> SmokeResult<BackendClient> {
    let client = BackendClient::spawn(PathBuf::from(required("DBEER_GPUI_HELPER_PATH")?))
        .map_err(|_| "Cannot start the termination-test helper.")?;
    bounded(client.handshake())
        .await?
        .map_err(|_| "The termination-test helper handshake failed.")?;
    Ok(client)
}

async fn query(client: &BackendClient, session: &str, sql: String) -> SmokeResult<QueryOutcome> {
    let assessment = bounded(client.assess(session, sql.clone()))
        .await?
        .map_err(|_| "Cannot assess an isolated termination-test operation.")?;
    if assessment.rejected() {
        return Err("An isolated termination-test operation was rejected.".into());
    }
    let stream = client
        .execute_authorized(session, sql, assessment.authorization)
        .map_err(|_| "Cannot enqueue an isolated termination-test operation.")?;
    loop {
        match bounded(stream.events.recv())
            .await?
            .map_err(|_| "An isolated termination-test stream closed early.")?
            .map_err(|_| "An isolated termination-test operation failed.")?
        {
            QueryEvent::Finished(outcome) => return Ok(outcome),
            QueryEvent::Started | QueryEvent::Chunk { .. } | QueryEvent::ExportProgress { .. } => {}
        }
    }
}

async fn row_count(client: &BackendClient, session: &str, table: &str) -> SmokeResult<usize> {
    query(client, session, format!("SELECT COUNT(*) FROM {table}"))
        .await?
        .result_sets
        .first()
        .and_then(|set| set.rows.first())
        .and_then(|row| row.first())
        .and_then(|cell| cell.as_deref())
        .and_then(|cell| cell.parse().ok())
        .ok_or_else(|| "The isolated termination-test count was invalid.".into())
}

fn output_directory() -> PathBuf {
    std::env::var_os("DBEER_GPUI_TERMINATION_SMOKE_OUTPUT")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../build/gpui/qa/termination")
        })
}

fn child_case(engine: &str, decision: &str, table: &str, marker: &Path) -> SmokeResult<usize> {
    let executable =
        std::env::current_exe().map_err(|_| "Cannot locate the native test binary.")?;
    let mut child = Command::new(executable)
        .arg("--termination-smoke-test")
        .env("DBEER_GPUI_TERMINATION_ENGINE", engine)
        .env("DBEER_GPUI_TERMINATION_DECISION", decision)
        .env("DBEER_GPUI_TERMINATION_TABLE", table)
        .env("DBEER_GPUI_TERMINATION_MARKER", marker)
        .stdin(Stdio::null())
        .spawn()
        .map_err(|_| "Cannot launch the native termination-test app.")?;
    let deadline = Instant::now() + Duration::from_secs(45);
    loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|_| "Cannot wait for the native termination-test app.")?
        {
            if !status.success() {
                return Err("The native termination-test app exited unsuccessfully.".into());
            }
            return std::fs::read_to_string(marker)
                .map_err(|_| "The app exited without completing its guarded window close.")?
                .trim()
                .parse()
                .map_err(|_| "The native termination-test completion marker was invalid.".into());
        }
        if Instant::now() >= deadline {
            _ = child.kill();
            _ = child.wait();
            return Err("The native termination-test app did not finish its guarded exit.".into());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

async fn supervise() -> SmokeResult<usize> {
    let output = output_directory();
    std::fs::create_dir_all(&output).map_err(|_| "Cannot create termination-test output.")?;
    let summary = output.join("summary.txt");
    if summary.exists() {
        std::fs::remove_file(&summary).map_err(|_| "Cannot remove a stale termination summary.")?;
    }
    let client = helper().await?;
    let mut passed = 0;
    for connection in fixtures()? {
        let engine = connection.engine.clone();
        let observer = bounded(client.connect(connection))
            .await?
            .map_err(|_| "Cannot connect the independent termination-test observer.")?
            .session_id;
        for decision in ["commit", "rollback"] {
            let table = format!("gpui_quit_{}_{engine}_{decision}", std::process::id());
            query(
                &client,
                &observer,
                format!("CREATE TABLE {table} (id INTEGER)"),
            )
            .await?;
            let marker = output.join(format!("{engine}-{decision}.completed"));
            _ = std::fs::remove_file(&marker);
            let result = child_case(&engine, decision, &table, &marker);
            let actual_count = row_count(&client, &observer, &table).await;
            let cleanup = query(&client, &observer, format!("DROP TABLE {table}")).await;
            passed += result?;
            let expected_count = usize::from(decision == "commit");
            check(
                &mut passed,
                &format!("{engine}: {decision} exit preserves the selected database outcome"),
                actual_count? == expected_count,
            )?;
            cleanup?;
        }
        bounded(client.disconnect(&observer))
            .await?
            .map_err(|_| "Cannot disconnect the termination-test observer.")?;
    }
    let marker = output.join("idle.completed");
    _ = std::fs::remove_file(&marker);
    passed += child_case("postgresql", "idle", "unused", &marker)?;
    std::fs::write(
        summary,
        format!(
            "Native termination smoke: {passed} checks passed; completed.\nAppKit terminate: exercised in five independent app processes.\nPostgreSQL and MySQL: Cancel, repeated Quit, Commit and Roll Back verified.\nIdle Quit: guarded window closure verified.\nNo persisted profiles or Keychain credentials were used.\n"
        ),
    )
    .map_err(|_| "Cannot save the completed termination-test summary.")?;
    Ok(passed)
}

pub(super) fn run_supervisor() -> Option<i32> {
    if !std::env::args().any(|arg| arg == "--termination-smoke-suite") {
        return None;
    }
    Some(match smol::block_on(supervise()) {
        Ok(passed) => {
            println!("Native termination smoke: {passed} checks passed; completed.");
            0
        }
        Err(error) => {
            eprintln!("Native termination smoke FAILED: {error}");
            1
        }
    })
}

fn check(passed: &mut usize, name: &str, condition: bool) -> SmokeResult<()> {
    if !condition {
        return Err(name.into());
    }
    *passed += 1;
    println!("  PASS {name}");
    Ok(())
}

async fn pause(cx: &AsyncWindowContext, milliseconds: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(milliseconds))
        .await;
}

async fn wait_for(
    view: &Entity<Workspace>,
    cx: &mut AsyncWindowContext,
    predicate: impl Fn(&Workspace) -> bool,
) -> SmokeResult<()> {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if view
            .update_in(cx, |this, _, _| predicate(this))
            .map_err(|_| "The termination-test window closed before the reviewed exit.")?
        {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("The termination-test workspace did not finish its operation.".into());
        }
        pause(cx, 25).await;
    }
}

async fn run_query(
    view: &Entity<Workspace>,
    cx: &mut AsyncWindowContext,
    id: DocumentId,
    sql: String,
) -> SmokeResult<()> {
    view.update_in(cx, |this, window, cx| {
        this.run_live(id, Some(sql), None, window, cx)
    })
    .map_err(|_| "The termination-test window closed before execution.")?;
    wait_for(view, cx, |this| this.tabs[0].task.is_none()).await?;
    view.update_in(cx, |this, window, cx| {
        if this.tabs[0].error || window.has_active_dialog(cx) {
            Err("The isolated termination-test query did not finish successfully.".into())
        } else {
            Ok(())
        }
    })
    .map_err(|_| "The termination-test window closed after execution.")?
}

async fn request_quit(cx: &AsyncWindowContext) {
    termination::request_native_quit();
    pause(cx, 125).await;
}

async fn run(
    view: Entity<Workspace>,
    cx: &mut AsyncWindowContext,
    completed: Rc<Cell<Option<usize>>>,
) -> SmokeResult<()> {
    let decision = required("DBEER_GPUI_TERMINATION_DECISION")?;
    let mut passed = 0;
    pause(cx, 150).await;
    view.update_in(cx, |this, _, _| {
        check(
            &mut passed,
            "termination test starts without saved profiles or credentials",
            this.profile_store.is_none()
                && this.profiles.iter().all(|profile| profile.config.is_none()),
        )
    })
    .map_err(|_| "The termination-test window closed at startup.")??;
    if decision == "idle" {
        completed.set(Some(passed));
        termination::request_native_quit();
        pause(cx, 15_000).await;
        return Err("Idle native Quit left its window open.".into());
    }
    if !matches!(decision.as_str(), "commit" | "rollback") {
        return Err("Invalid native termination-test decision.".into());
    }
    let engine = required("DBEER_GPUI_TERMINATION_ENGINE")?;
    let table = required("DBEER_GPUI_TERMINATION_TABLE")?;
    if !table.starts_with("gpui_quit_")
        || !table
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'_')
    {
        return Err("Invalid isolated termination-test table.".into());
    }
    let connection = fixtures()?
        .into_iter()
        .find(|connection| connection.engine == engine)
        .ok_or("Invalid native termination-test engine.")?;
    let client = helper().await?;
    let session = bounded(client.connect(connection.clone()))
        .await?
        .map_err(|_| "Cannot connect the termination-test SQL tab.")?
        .session_id;
    let profile = ConnectionProfile {
        id: "gpui-native-termination".into(),
        name: "Isolated termination fixture".into(),
        engine: connection.engine,
        host: connection.host,
        port: connection.port,
        database: connection.database,
        user: connection.user,
        ssl_mode: connection.ssl_mode,
        ssl_root_cert: None,
        readonly: false,
        environment: "development".into(),
    };
    let id = view
        .update_in(cx, |this, window, cx| {
            this.tabs.clear();
            this.profiles.clear();
            this.selected_profile = 0;
            this.backend = Some(client.clone());
            this.profiles.push(Profile {
                demo: false,
                id: ProfileId::saved(&profile),
                generation: 0,
                service_generation: 0,
                name: profile.name.clone().into(),
                environment: "Development",
                loaded: true,
                expanded: false,
                config: Some(profile.clone()),
                session: None,
                session_settings: None,
                session_client: None,
                schemas: Vec::new(),
                task: None,
                status: "In-memory termination fixture".into(),
            });
            this.add_sql_tab("Transaction.sql".into(), "SELECT 1;".into(), window, cx);
            this.tabs[0].session = Some(session.clone());
            this.tabs[0].session_settings = this.profiles[0].config.clone();
            this.tabs[0].own_session(client.clone());
            cx.notify();
            this.tabs[0].id
        })
        .map_err(|_| "Cannot install the in-memory termination fixture.")?;
    run_query(&view, cx, id, "START TRANSACTION".into()).await?;
    run_query(
        &view,
        cx,
        id,
        format!("INSERT INTO {table} (id) VALUES (1)"),
    )
    .await?;
    view.update_in(cx, |this, _, _| {
        check(
            &mut passed,
            "the real SQL tab retains its pending transaction",
            this.tabs[0].transaction == "transaction" && !this.tabs[0].uncertain,
        )
    })
    .map_err(|_| "The termination-test window closed before native Quit.")??;
    request_quit(cx).await;
    cx.update(|window, cx| {
        window.render_frame(cx);
        check(
            &mut passed,
            "AppKit native Quit presents Commit, Roll Back and Cancel",
            window.has_active_dialog(cx)
                && window.try_find("commit-close").is_some()
                && window.try_find("rollback-close").is_some()
                && window.try_find("cancel-close").is_some(),
        )
    })
    .map_err(|_| "Native Quit bypassed the transaction dialog.")??;
    request_quit(cx).await;
    request_quit(cx).await;
    cx.update(|window, cx| {
        window.render_frame(cx);
        check(
            &mut passed,
            "repeated native Quit retains the transaction review",
            window.try_find("commit-close").is_some()
                && window.try_find("rollback-close").is_some()
                && window.try_find("cancel-close").is_some(),
        )?;
        window.click("cancel-close", cx);
        Ok::<_, String>(())
    })
    .map_err(|_| "The repeated native Quit closed its transaction review.")??;
    pause(cx, 250).await;
    view.update_in(cx, |this, window, cx| {
        check(
            &mut passed,
            "one Cancel dismisses repeated Quit without stacked dialogs",
            !window.has_active_dialog(cx),
        )?;
        check(
            &mut passed,
            "Cancel keeps the app and the original open transaction",
            this.tabs.len() == 1
                && this.tabs[0].session.as_ref() == Some(&session)
                && this.tabs[0].transaction == "transaction"
                && !this.tabs[0].uncertain
                && !this.closing,
        )
    })
    .map_err(|_| "Cancel did not preserve the native app window.")??;
    check(
        &mut passed,
        "Cancel preserves the transaction's pending database edit",
        row_count(&client, &session, &table).await? == 1,
    )?;
    request_quit(cx).await;
    cx.update(|window, cx| {
        window.render_frame(cx);
        let button = if decision == "commit" {
            "commit-close"
        } else {
            "rollback-close"
        };
        check(
            &mut passed,
            "a fresh native Quit reopens transaction review after Cancel",
            window.has_active_dialog(cx) && window.try_find(button).is_some(),
        )?;
        window.click(button, cx);
        // Deliver native requests while the selected transaction resolution is
        // still queued. They must not turn the close operation into Stop.
        termination::request_native_quit();
        termination::request_native_quit();
        view.update(cx, |this, _| {
            check(
                &mut passed,
                "immediate repeated Quit preserves the selected transaction resolution",
                this.tabs[0].task.is_some()
                    && this.tabs[0].resolving_close
                    && !this.tabs[0].stop_requested,
            )
        })?;
        completed.set(Some(passed));
        Ok::<_, String>(())
    })
    .map_err(|_| "The termination-test window closed before the final decision.")??;
    pause(cx, 15_000).await;
    Err("The reviewed native Quit did not close its window.".into())
}

pub(super) fn start(view: Entity<Workspace>, window: &mut Window, cx: &mut App) {
    let completed = Rc::new(Cell::new(None::<usize>));
    let observed = completed.clone();
    cx.on_app_quit(move |cx| {
        // This callback runs before GPUI itself clears all remaining windows.
        // The marker therefore proves that the guarded close removed the window.
        if let Some(passed) = observed.get()
            && cx.windows().is_empty()
            && let Ok(marker) = std::env::var("DBEER_GPUI_TERMINATION_MARKER")
        {
            println!("  PASS native Quit exits after the guarded window closes");
            _ = std::fs::write(marker, (passed + 1).to_string());
        }
        async {}
    })
    .detach();
    window
        .spawn(cx, async move |cx| {
            if let Err(error) = run(view, cx, completed).await {
                eprintln!("Native termination smoke case FAILED: {error}");
                std::process::exit(1);
            }
        })
        .detach();
}
