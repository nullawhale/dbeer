//! Opt-in real-window checks against the runners' disposable databases.
//! Credentials remain in memory; profile persistence and Keychain are unused.

use super::*;
use backend::{Connection, ExecutionPolicy};
use gpui_kit::test::TestWindowExt;
use std::{
    future::Future,
    path::{Path, PathBuf},
    time::Instant,
};

type SmokeResult<T> = std::result::Result<T, String>;

pub(super) fn start(view: Entity<Workspace>, window: &mut Window, cx: &mut App) {
    window
        .spawn(cx, async move |cx| {
            match run(view, cx).await {
                Ok(passed) => println!("Native live smoke: {passed} checks passed; completed."),
                Err(error) => {
                    eprintln!("Native live smoke FAILED: {error}");
                    _ = cx.update(|_, cx| cx.quit());
                    std::process::exit(1);
                }
            }
            _ = cx.update(|_, cx| cx.quit());
        })
        .detach();
}

fn required(name: &str) -> SmokeResult<String> {
    std::env::var(name).map_err(|_| "Run live smoke with both isolated database runners.".into())
}

fn fixtures() -> SmokeResult<Vec<Connection>> {
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
    let postgres = Connection {
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
        policy: ExecutionPolicy::default(),
    };
    let mysql = Connection {
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
        policy: ExecutionPolicy::default(),
    };
    Ok(vec![postgres, mysql])
}

async fn bounded<T>(future: impl Future<Output = T>) -> SmokeResult<T> {
    smol::future::race(async { Ok(future.await) }, async {
        smol::Timer::after(Duration::from_secs(12)).await;
        Err("The live helper exceeded the smoke-test deadline.".into())
    })
    .await
}

async fn pause(cx: &AsyncWindowContext, milliseconds: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(milliseconds))
        .await;
}

async fn wait_for(
    view: &Entity<Workspace>,
    cx: &mut AsyncWindowContext,
    name: &str,
    predicate: impl Fn(&Workspace) -> bool,
) -> SmokeResult<()> {
    let deadline = Instant::now() + Duration::from_secs(12);
    loop {
        if view
            .update_in(cx, |this, _, _| predicate(this))
            .map_err(|_| "The smoke window closed.")?
        {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!("Timed out waiting for {name}."));
        }
        pause(cx, 25).await;
    }
}

fn check(passed: &mut usize, name: &str, condition: bool) -> SmokeResult<()> {
    if !condition {
        return Err(name.into());
    }
    *passed += 1;
    println!("  PASS {name}");
    Ok(())
}

fn rendered_rows(tab: &QueryTab, cx: &App) -> Option<usize> {
    tab.grid
        .as_ref()
        .map(|grid| grid.read(cx).delegate().row_count())
}

fn typed_values(tab: &QueryTab) -> bool {
    let Some(set) = tab.result_sets.first() else {
        return false;
    };
    let Some(row) = set.rows.first() else {
        return false;
    };
    set.columns.len() == 7
        && set.rows.len() == 1
        && row.len() == 7
        && row[0].as_deref() == Some("1")
        && row[1].is_none()
        && row[2].as_deref() == Some("")
        && row[3].as_deref() == Some("NULL")
        && row[4].as_deref() == Some("9007199254740993.123456789")
        && row[5].as_deref() == Some("AP9c")
        && set.columns[1].name == set.columns[2].name
        && set.columns[2].name == set.columns[3].name
        && set.columns[5].encoding.as_deref() == Some("base64")
}

fn snapshot(window: &Window, path: &Path, dark: bool) -> SmokeResult<()> {
    if window.painted_quads().is_empty() {
        return Err("The live screenshot has no painted scene.".into());
    }
    let image = window
        .render_to_image()
        .map_err(|_| "Cannot capture the rendered live workspace.")?;
    let count = u64::from(image.width()) * u64::from(image.height());
    if count == 0 {
        return Err("The live screenshot has no pixels.".into());
    }
    let brightness = image
        .pixels()
        .map(|pixel| (u64::from(pixel.0[0]) + u64::from(pixel.0[1]) + u64::from(pixel.0[2])) / 3)
        .sum::<u64>()
        / count;
    if (dark && brightness >= 120) || (!dark && brightness <= 140) {
        return Err("The live screenshot theme has not repainted.".into());
    }
    image
        .save(path)
        .map_err(|_| "Cannot save the rendered live workspace.")?;
    Ok(())
}

async fn run_query(
    view: &Entity<Workspace>,
    cx: &mut AsyncWindowContext,
    id: DocumentId,
    sql: Option<String>,
) -> SmokeResult<()> {
    view.update_in(cx, |this, window, cx| {
        this.run_live(id, sql, None, window, cx)
    })
    .map_err(|_| "The smoke window closed before Run.")?;
    wait_for(view, cx, "the terminal query result", |this| {
        this.tabs
            .iter()
            .find(|tab| tab.id == id)
            .is_some_and(|tab| tab.task.is_none())
    })
    .await
}

async fn engine_smoke(
    view: &Entity<Workspace>,
    cx: &mut AsyncWindowContext,
    client: &BackendClient,
    connection: Connection,
    output: &Path,
    passed: &mut usize,
) -> SmokeResult<()> {
    let postgres = connection.engine == "postgresql";
    let label = if postgres { "PostgreSQL" } else { "MySQL" };
    let capture_prefix = if postgres { "postgres" } else { "mysql" };
    let schema_name = if postgres {
        "public"
    } else {
        &connection.database
    }
    .to_owned();
    let service = bounded(client.connect(connection.clone()))
        .await?
        .map_err(|_| "Cannot connect the live catalog fixture.")?;
    let first = bounded(client.connect(connection.clone()))
        .await?
        .map_err(|_| "Cannot connect the first live SQL-tab fixture.")?;
    let second = bounded(client.connect(connection.clone()))
        .await?
        .map_err(|_| "Cannot connect the second live SQL-tab fixture.")?;
    let typed_sql = if postgres {
        "SELECT 1 AS id, NULL::text AS x, ''::text AS x, 'NULL'::text AS x,\n\
         9007199254740993.123456789::numeric AS exact_value,\n\
         decode('00ff5c','hex') AS bytes, 'PostgreSQL'::text AS engine;"
    } else {
        "SELECT 1 AS id, NULL AS x, '' AS x, 'NULL' AS x,\n\
         CAST('9007199254740993.123456789' AS DECIMAL(40,9)) AS exact_value,\n\
         X'00FF5C' AS bytes, 'MySQL' AS engine;"
    };
    let profile = ConnectionProfile {
        id: format!("gpui-native-{capture_prefix}"),
        name: format!("{label} test"),
        engine: connection.engine.clone(),
        host: connection.host.clone(),
        port: connection.port,
        database: connection.database.clone(),
        user: connection.user.clone(),
        ssl_mode: connection.ssl_mode.clone(),
        ssl_root_cert: None,
        readonly: true,
        environment: "development".into(),
    };
    let first_session = first.session_id.clone();
    let second_session = second.session_id.clone();
    let (first_id, second_id) = view
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
                loaded: false,
                expanded: true,
                config: Some(profile.clone()),
                session: Some(service.session_id.clone()),
                session_settings: Some(profile.clone()),
                session_client: Some(client.clone()),
                schemas: Vec::new(),
                task: None,
                status: "Connected".into(),
            });
            this.add_sql_tab("Values.sql".into(), typed_sql.into(), window, cx);
            let first_id = this.tabs[0].id;
            this.tabs[0].session = Some(first.session_id);
            this.tabs[0].session_settings = this.profiles[0].config.clone();
            this.tabs[0].own_session(client.clone());
            this.add_sql_tab(
                "Independent.sql".into(),
                "SELECT 2 AS independent;".into(),
                window,
                cx,
            );
            let second_id = this.tabs[1].id;
            this.tabs[1].session = Some(second.session_id);
            this.tabs[1].session_settings = this.profiles[0].config.clone();
            this.tabs[1].own_session(client.clone());
            this.active = 0;
            this.connect_profile(0, window, cx);
            cx.notify();
            (first_id, second_id)
        })
        .map_err(|_| "Cannot install in-memory live smoke fixtures.")?;
    wait_for(view, cx, "the real catalog schemas", |this| {
        this.profiles[0].task.is_none()
    })
    .await?;
    let schema_index = view
        .update_in(cx, |this, window, cx| {
            check(
                passed,
                &format!("{label}: real catalog schemas loaded"),
                this.profiles[0].loaded && !this.profiles[0].schemas.is_empty(),
            )?;
            let index = this.profiles[0]
                .schemas
                .iter()
                .position(|schema| schema.name == schema_name)
                .ok_or("The isolated database's default schema was not listed.")?;
            this.expand_schema(0, index, window, cx);
            Ok::<_, String>(index)
        })
        .map_err(|_| "The smoke window closed during catalog loading.")??;
    wait_for(view, cx, "the real catalog objects", |this| {
        this.profiles[0].task.is_none()
    })
    .await?;
    view.update_in(cx, |this, window, cx| {
        check(
            passed,
            &format!("{label}: schema expansion completes"),
            this.profiles[0].schemas[schema_index].loaded,
        )?;
        check(
            passed,
            &format!("{label}: SQL tabs own separate sessions"),
            this.tabs[0].session != this.tabs[1].session
                && this.tabs[0].session != this.profiles[0].session,
        )?;
        this.tabs[0]
            .editor
            .update(cx, |editor, cx| editor.focus(window, cx));
        window.dispatch_action(
            Box::new(DispatchCommand {
                command: CommandId::RunCurrent,
            }),
            cx,
        );
        Ok::<_, String>(())
    })
    .map_err(|_| "The smoke window closed before Run dispatch.")??;
    wait_for(view, cx, "the first real result grid", |this| {
        this.tabs[0].task.is_none() && (this.tabs[0].error || this.tabs[0].grid.is_some())
    })
    .await?;
    view.update_in(cx, |this, _, cx| {
        check(
            passed,
            &format!("{label}: Run action renders the real result grid"),
            !this.tabs[0].error && rendered_rows(&this.tabs[0], cx) == Some(1),
        )?;
        check(
            passed,
            &format!(
                "{label}: NULL, empty text, literal NULL, numeric and binary values remain exact"
            ),
            typed_values(&this.tabs[0]),
        )
    })
    .map_err(|_| "The smoke window closed after Run.")??;

    run_query(view, cx, second_id, None).await?;
    view.update_in(cx, |this, _, cx| {
        check(
            passed,
            &format!("{label}: second SQL tab keeps the first result intact"),
            !this.tabs[1].error
                && rendered_rows(&this.tabs[1], cx) == Some(1)
                && typed_values(&this.tabs[0])
                && this.tabs[0].session.as_ref() == Some(&first_session),
        )
    })
    .map_err(|_| "The smoke window closed after the independent query.")??;
    view.update_in(cx, |this, window, cx| {
        this.tabs[0].filter.update(cx, |input, cx| {
            input.replace_all("absent-fixture-value", window, cx)
        });
    })
    .map_err(|_| "The smoke window closed before filtering.")?;
    pause(cx, 75).await;
    view.update_in(cx, |this, window, cx| {
        check(
            passed,
            &format!("{label}: filter updates only the intended real grid"),
            rendered_rows(&this.tabs[0], cx) == Some(0)
                && rendered_rows(&this.tabs[1], cx) == Some(1),
        )?;
        this.tabs[0]
            .filter
            .update(cx, |input, cx| input.replace_all("", window, cx));
        Ok::<_, String>(())
    })
    .map_err(|_| "The smoke window closed during filtering.")??;
    pause(cx, 75).await;
    view.update_in(cx, |this, _, cx| {
        check(
            passed,
            &format!("{label}: clearing the filter restores real rows"),
            rendered_rows(&this.tabs[0], cx) == Some(1),
        )
    })
    .map_err(|_| "The smoke window closed after filtering.")??;

    for (mode, dark, suffix) in [
        (ThemeMode::Dark, true, "dark"),
        (ThemeMode::Light, false, "light"),
    ] {
        view.update_in(cx, |this, window, cx| {
            this.active = 0;
            apply_theme(mode, Some(window), cx);
            cx.notify();
        })
        .map_err(|_| "The smoke window closed during theme switching.")?;
        pause(cx, 200).await;
        cx.update(|window, cx| {
            window.render_frame(cx);
            snapshot(
                window,
                &output.join(format!("{capture_prefix}-{suffix}.png")),
                dark,
            )
        })
        .map_err(|_| "The smoke window closed during capture.")??;
        check(
            passed,
            &format!("{label}: {suffix} workspace screenshot captured"),
            true,
        )?;
    }

    generated_select_smoke(view, cx, client, connection.clone(), label, passed).await?;

    run_query(
        view,
        cx,
        first_id,
        Some("SELECT * FROM dbeer_gpui_missing_table".into()),
    )
    .await?;
    view.update_in(cx, |this, _, cx| {
        check(
            passed,
            &format!("{label}: real SQL errors clear results and keep the session"),
            this.tabs[0].error
                && this.tabs[0].grid.is_none()
                && !this.tabs[0].uncertain
                && this.tabs[0].session.as_ref() == Some(&first_session),
        )?;
        check(
            passed,
            &format!("{label}: SQL error leaves the other tab intact"),
            !this.tabs[1].error && rendered_rows(&this.tabs[1], cx) == Some(1),
        )
    })
    .map_err(|_| "The smoke window closed during SQL error checks.")??;

    let sleep_sql = if postgres {
        "SELECT pg_sleep(30)"
    } else {
        "SELECT 1 FROM (SELECT 1 AS n UNION ALL SELECT 2) source_rows WHERE SLEEP(30)=0"
    };
    view.update_in(cx, |this, window, cx| {
        this.run_live(first_id, Some(sleep_sql.into()), None, window, cx)
    })
    .map_err(|_| "The smoke window closed before cancellation.")?;
    wait_for(view, cx, "a cancellable real query", |this| {
        this.tabs[0].query_id.is_some()
    })
    .await?;
    pause(cx, 100).await;
    view.update_in(cx, |this, _, cx| this.stop_live(first_id, cx))
        .map_err(|_| "The smoke window closed before Stop.")?;
    wait_for(view, cx, "the cancellation terminal result", |this| {
        this.tabs[0].task.is_none()
    })
    .await?;
    view.update_in(cx, |this, _, _| {
        check(
            passed,
            &format!("{label}: Stop waits for real cancellation and retains the SQL session"),
            this.tabs[0].error
                && this.tabs[0].status.to_lowercase().contains("cancel")
                && this.tabs[0].session.as_ref() == Some(&first_session)
                && !this.tabs[0].uncertain,
        )
    })
    .map_err(|_| "The smoke window closed after cancellation.")??;
    run_query(view, cx, first_id, None).await?;
    view.update_in(cx, |this, _, cx| {
        check(
            passed,
            &format!("{label}: real session can run again after cancellation"),
            !this.tabs[0].error
                && rendered_rows(&this.tabs[0], cx) == Some(1)
                && typed_values(&this.tabs[0]),
        )
    })
    .map_err(|_| "The smoke window closed after rerunning.")??;

    run_query(
        view,
        cx,
        first_id,
        Some("CREATE TABLE dbeer_gpui_must_not_exist(id integer)".into()),
    )
    .await?;
    view.update_in(cx, |this, window, cx| {
        check(
            passed,
            &format!("{label}: read-only helper policy rejects edits before execution"),
            this.tabs[0].error
                && this.tabs[0].result_sets.is_empty()
                && this.tabs[0].status.contains("rejected")
                && !window.has_active_dialog(cx),
        )
    })
    .map_err(|_| "The smoke window closed after policy rejection.")??;

    run_query(
        view,
        cx,
        first_id,
        Some("START TRANSACTION READ ONLY".into()),
    )
    .await?;
    view.update_in(cx, |this, window, cx| {
        check(
            passed,
            &format!("{label}: the SQL tab retains its open transaction"),
            !this.tabs[0].error
                && this.tabs[0].transaction == "transaction"
                && this.tabs[1].transaction == "idle",
        )?;
        this.request_close(CloseIntent::Tab(first_id), window, cx);
        Ok::<_, String>(())
    })
    .map_err(|_| "The smoke window closed before transaction-close review.")??;
    pause(cx, 100).await;
    cx.update(|window, cx| {
        window.render_frame(cx);
        check(
            passed,
            &format!("{label}: closing an open transaction presents the native review dialog"),
            window.has_active_dialog(cx) && window.try_find("rollback-close").is_some(),
        )?;
        window.click("rollback-close", cx);
        Ok::<_, String>(())
    })
    .map_err(|_| "The smoke window closed during transaction-close review.")??;
    wait_for(view, cx, "rollback and tab disconnection", |this| {
        !this.closing && this.tabs.iter().all(|tab| tab.id != first_id)
    })
    .await?;
    view.update_in(cx, |this, window, cx| {
        check(
            passed,
            &format!("{label}: Roll Back closes only the reviewed SQL tab"),
            this.tabs.len() == 1
                && this.tabs[0].id == second_id
                && !this.tabs[0].uncertain
                && this.tabs[0].session.as_ref() == Some(&second_session)
                && !window.has_active_dialog(cx),
        )?;
        this.request_close(
            CloseIntent::Profile(this.profiles[0].id.clone()),
            window,
            cx,
        );
        Ok::<_, String>(())
    })
    .map_err(|_| "The smoke window closed after transaction rollback.")??;
    wait_for(view, cx, "profile disconnection", |this| {
        !this.closing && this.profiles[0].session.is_none()
    })
    .await?;
    view.update_in(cx, |this, _, _| {
        check(
            passed,
            &format!("{label}: disconnect clears catalog and SQL sessions"),
            !this.profiles[0].loaded
                && this.profiles[0].schemas.is_empty()
                && this
                    .tabs
                    .iter()
                    .all(|tab| tab.session.is_none() && tab.transaction == "idle"),
        )
    })
    .map_err(|_| "The smoke window closed after disconnect.")??;
    confirmation_smoke(view, cx, client, connection, label, passed).await?;
    Ok(())
}

async fn generated_select_smoke(
    view: &Entity<Workspace>,
    cx: &mut AsyncWindowContext,
    client: &BackendClient,
    connection: Connection,
    label: &str,
    passed: &mut usize,
) -> SmokeResult<()> {
    let postgres = connection.engine == "postgresql";
    let schema = if postgres {
        "pg_catalog"
    } else {
        "information_schema"
    };
    let object_name = if postgres { "pg_class" } else { "TABLES" };
    let kind = if postgres { "table" } else { "view" };
    let session = bounded(client.connect(connection))
        .await?
        .map_err(|_| "Cannot connect the generated SELECT fixture.")?
        .session_id;
    let previous_count = view
        .update_in(cx, |this, window, cx| {
            let count = this.tabs.len();
            this.open_object(
                0,
                schema.into(),
                catalog::CatalogObject {
                    name: object_name.into(),
                    kind: kind.into(),
                    identity: None,
                },
                window,
                cx,
            );
            count
        })
        .map_err(|_| "The smoke window closed before generating SELECT.")?;
    wait_for(view, cx, "the adapter-generated SELECT tab", |this| {
        this.profiles[0].task.is_none() && this.tabs.len() == previous_count + 1
    })
    .await?;
    let id = view
        .update_in(cx, |this, _, cx| {
            let tab = &mut this.tabs[this.active];
            check(
                passed,
                &format!("{label}: catalog selection generates SQL through the database adapter"),
                tab.editor.read(cx).value().contains(object_name)
                    && tab.grid.is_none()
                    && tab.session.is_none(),
            )?;
            tab.session = Some(session);
            tab.session_settings = this.profiles[0].config.clone();
            tab.own_session(client.clone());
            Ok::<_, String>(tab.id)
        })
        .map_err(|_| "The smoke window closed after generating SELECT.")??;
    run_query(view, cx, id, None).await?;
    view.update_in(cx, |this, window, cx| {
        let tab = this
            .tabs
            .iter()
            .find(|tab| tab.id == id)
            .ok_or("The generated SELECT tab disappeared.")?;
        check(
            passed,
            &format!("{label}: generated SELECT renders actual catalog rows"),
            !tab.error && rendered_rows(tab, cx).is_some_and(|count| count > 0),
        )?;
        this.request_close(CloseIntent::Tab(id), window, cx);
        Ok::<_, String>(())
    })
    .map_err(|_| "The smoke window closed after the generated SELECT.")??;
    wait_for(view, cx, "generated SELECT session disconnection", |this| {
        !this.closing
            && this.tabs.len() == previous_count
            && this.tabs.iter().all(|tab| tab.id != id)
    })
    .await?;
    Ok(())
}

async fn table_was_not_created(client: &BackendClient, session: &str) -> SmokeResult<bool> {
    let stream = client
        .execute(session, "SELECT * FROM gpui_native_confirmation".into())
        .map_err(|_| "Cannot enqueue the confirmation absence check.")?;
    loop {
        match bounded(stream.events.recv())
            .await?
            .map_err(|_| "The confirmation absence check closed early.")?
        {
            Err(error) => {
                return Ok(error.category == "sql" && error.connected && !error.outcome_unknown);
            }
            Ok(backend::QueryEvent::Finished(_)) => return Ok(false),
            Ok(_) => {}
        }
    }
}

async fn confirmation_smoke(
    view: &Entity<Workspace>,
    cx: &mut AsyncWindowContext,
    client: &BackendClient,
    mut connection: Connection,
    label: &str,
    passed: &mut usize,
) -> SmokeResult<()> {
    connection.policy = ExecutionPolicy {
        environment: "production".into(),
        read_only: false,
    };
    let session = bounded(client.connect(connection.clone()))
        .await?
        .map_err(|_| "Cannot connect the in-memory confirmation fixture.")?
        .session_id;
    let sql = if connection.engine == "postgresql" {
        "CREATE TEMP TABLE gpui_native_confirmation(id integer);"
    } else {
        "CREATE TEMPORARY TABLE gpui_native_confirmation(id integer);"
    };
    let profile = ConnectionProfile {
        id: format!("gpui-native-{}-confirmation", connection.engine),
        name: format!("{label} confirmation"),
        engine: connection.engine,
        host: connection.host,
        port: connection.port,
        database: connection.database,
        user: connection.user,
        ssl_mode: connection.ssl_mode,
        ssl_root_cert: None,
        readonly: false,
        environment: "production".into(),
    };
    let (profile_index, id) = view
        .update_in(cx, |this, window, cx| {
            let profile_index = this.profiles.len();
            this.profiles.push(Profile {
                demo: false,
                id: ProfileId::saved(&profile),
                generation: 0,
                service_generation: 0,
                name: profile.name.clone().into(),
                environment: "Production",
                loaded: false,
                expanded: false,
                config: Some(profile.clone()),
                session: None,
                session_settings: None,
                session_client: None,
                schemas: Vec::new(),
                task: None,
                status: "In-memory confirmation fixture".into(),
            });
            this.selected_profile = profile_index;
            this.add_sql_tab("Review.sql".into(), sql.into(), window, cx);
            let tab = &mut this.tabs[this.active];
            tab.session = Some(session.clone());
            tab.session_settings = this.profiles[profile_index].config.clone();
            tab.own_session(client.clone());
            let id = tab.id;
            this.run_live(id, None, None, window, cx);
            (profile_index, id)
        })
        .map_err(|_| "Cannot install the in-memory confirmation fixture.")?;
    wait_for(view, cx, "the production execution confirmation", |this| {
        this.tabs
            .iter()
            .find(|tab| tab.id == id)
            .is_some_and(|tab| {
                tab.task.is_none() && tab.status.contains("Awaiting execution confirmation")
            })
    })
    .await?;
    view.update_in(cx, |this, window, cx| {
        let tab = this
            .tabs
            .iter()
            .find(|tab| tab.id == id)
            .ok_or("The confirmation SQL tab disappeared.")?;
        check(
            passed,
            &format!("{label}: production writes await review before submitting SQL"),
            window.has_active_dialog(cx)
                && tab.query_id.is_none()
                && tab.result_sets.is_empty()
                && tab.transaction == "idle"
                && !tab.error
                && !tab.uncertain,
        )
    })
    .map_err(|_| "The smoke window closed before execution review.")??;
    pause(cx, 100).await;
    cx.update(|window, cx| {
        window.render_frame(cx);
        if window.try_find("cancel-execution").is_none() {
            return Err("The native Cancel execution button was not rendered.".into());
        }
        window.click("cancel-execution", cx);
        Ok::<_, String>(())
    })
    .map_err(|_| "The smoke window closed before Cancel execution.")??;
    wait_for(view, cx, "cancelling the execution review", |this| {
        this.tabs
            .iter()
            .find(|tab| tab.id == id)
            .is_some_and(|tab| tab.task.is_none() && tab.status.to_lowercase().contains("cancel"))
    })
    .await?;
    check(
        passed,
        &format!("{label}: native Cancel leaves the database unchanged"),
        table_was_not_created(client, &session).await?,
    )?;

    view.update_in(cx, |this, window, cx| {
        this.run_live(id, None, None, window, cx)
    })
    .map_err(|_| "The smoke window closed before repeated execution review.")?;
    wait_for(
        view,
        cx,
        "the repeated production execution confirmation",
        |this| {
            this.tabs
                .iter()
                .find(|tab| tab.id == id)
                .is_some_and(|tab| {
                    tab.task.is_none() && tab.status.contains("Awaiting execution confirmation")
                })
        },
    )
    .await?;
    let generation = view
        .update_in(cx, |this, window, cx| {
            let tab = this
                .tabs
                .iter_mut()
                .find(|tab| tab.id == id)
                .ok_or("The confirmation SQL tab disappeared.")?;
            let generation = tab.generation;
            tab.editor.update(cx, |editor, cx| {
                editor.replace_all("SELECT 99 AS changed_snapshot;", window, cx)
            });
            Ok::<_, String>(generation)
        })
        .map_err(|_| "The smoke window closed before changing the reviewed SQL.")??;
    pause(cx, 100).await;
    view.update_in(cx, |this, _, _| {
        check(
            passed,
            &format!("{label}: editing during review changes the execution snapshot"),
            this.tabs
                .iter()
                .find(|tab| tab.id == id)
                .is_some_and(|tab| tab.generation > generation),
        )
    })
    .map_err(|_| "The smoke window closed after changing the reviewed SQL.")??;
    cx.update(|window, cx| {
        window.render_frame(cx);
        if window.try_find("confirm-execution").is_none() {
            return Err("The native Run Reviewed SQL button was not rendered.".into());
        }
        window.click("confirm-execution", cx);
        Ok::<_, String>(())
    })
    .map_err(|_| "The smoke window closed before confirming the changed snapshot.")??;
    wait_for(
        view,
        cx,
        "rejecting the changed execution snapshot",
        |this| {
            this.tabs
                .iter()
                .find(|tab| tab.id == id)
                .is_some_and(|tab| {
                    tab.task.is_none() && tab.status.to_lowercase().contains("cancel")
                })
        },
    )
    .await?;
    view.update_in(cx, |this, window, cx| {
        check(
            passed,
            &format!("{label}: Run Reviewed SQL rejects a changed snapshot before submission"),
            this.tabs
                .iter()
                .find(|tab| tab.id == id)
                .is_some_and(|tab| {
                    tab.query_id.is_none()
                        && tab.result_sets.is_empty()
                        && tab.transaction == "idle"
                        && !tab.uncertain
                })
                && !window.has_active_dialog(cx),
        )
    })
    .map_err(|_| "The smoke window closed after confirming the changed snapshot.")??;
    check(
        passed,
        &format!("{label}: a stale confirmation leaves the database unchanged"),
        table_was_not_created(client, &session).await?,
    )?;
    view.update_in(cx, |this, window, cx| {
        this.request_close(
            CloseIntent::Profile(this.profiles[profile_index].id.clone()),
            window,
            cx,
        )
    })
    .map_err(|_| "The smoke window closed before disconnecting the confirmation fixture.")?;
    wait_for(view, cx, "confirmation fixture disconnection", |this| {
        !this.closing
            && this
                .tabs
                .iter()
                .filter(|tab| tab.profile == this.profiles[profile_index].id)
                .all(|tab| tab.session.is_none())
    })
    .await?;
    Ok(())
}

async fn run(view: Entity<Workspace>, cx: &mut AsyncWindowContext) -> SmokeResult<usize> {
    let output = std::env::var_os("DBEER_GPUI_LIVE_SMOKE_OUTPUT")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../build/gpui/qa/live")
        });
    std::fs::create_dir_all(&output)
        .map_err(|_| "Cannot create the live smoke output directory.")?;
    let summary = output.join("summary.txt");
    if summary.exists() {
        std::fs::remove_file(&summary)
            .map_err(|_| "Cannot remove the stale live smoke summary.")?;
    }
    let mut passed = 0;
    pause(cx, 150).await;
    view.update_in(cx, |this, _, _| {
        check(
            &mut passed,
            "live smoke starts without persisted profiles or sessions",
            this.profile_store.is_none()
                && this
                    .profiles
                    .iter()
                    .all(|profile| profile.config.is_none() && profile.session.is_none())
                && this
                    .tabs
                    .iter()
                    .all(|tab| tab.session.is_none() && tab.grid.is_none()),
        )
    })
    .map_err(|_| "The live smoke window closed at startup.")??;
    let path = std::env::var_os("DBEER_GPUI_HELPER_PATH")
        .ok_or("Run live smoke with scripts/gpui-prototype.sh.")?;
    let client = BackendClient::spawn(PathBuf::from(path))
        .map_err(|_| "Cannot start the live Go helper.")?;
    bounded(client.handshake())
        .await?
        .map_err(|_| "The live Go helper handshake failed.")?;
    for connection in fixtures()? {
        engine_smoke(&view, cx, &client, connection, &output, &mut passed).await?;
    }
    view.update_in(cx, |this, _, cx| {
        this.backend = None;
        cx.notify();
    })
    .map_err(|_| "The live smoke window closed before helper shutdown.")?;
    drop(client);
    std::fs::write(&summary, format!(
        "Native live smoke: {passed} checks passed; completed.\nDatabases: isolated PostgreSQL and MySQL.\nSnapshots: postgres-dark.png, postgres-light.png, mysql-dark.png, mysql-light.png.\nNo persisted profiles or Keychain credentials were used.\n"
    )).map_err(|_| "Cannot save the completed live smoke summary.")?;
    Ok(passed)
}
