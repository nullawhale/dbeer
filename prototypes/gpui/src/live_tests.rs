//! Real-helper checks. Database cases run only when isolated runner settings exist.
//! Assertions deliberately avoid printing connection settings, SQL, or row values.

use std::{future::Future, path::PathBuf, time::Duration};

use crate::backend::{
    BackendClient, BackendError, CatalogRequest, Connection, ExecutionPolicy, QueryEvent,
    QueryOutcome, QueryStream, TransactionStatus,
};

fn checked<T, E>(result: Result<T, E>, message: &str) -> T {
    result.unwrap_or_else(|_| panic!("{message}"))
}

pub(super) async fn bounded<T>(future: impl Future<Output = T>) -> T {
    smol::future::race(future, async {
        smol::Timer::after(Duration::from_secs(20)).await;
        panic!("The helper did not complete within the integration-test deadline.");
    })
    .await
}

pub(super) async fn client() -> BackendClient {
    let path = checked(
        std::env::var_os("DBEER_GPUI_HELPER_PATH").ok_or(()),
        "Run helper tests with scripts/gpui-prototype.sh test.",
    );
    let client = checked(
        BackendClient::spawn(PathBuf::from(path)),
        "Cannot start the existing Go helper.",
    );
    let concurrent = client.clone();
    let (first, second) = bounded(smol::future::zip(
        client.handshake(),
        concurrent.handshake(),
    ))
    .await;
    checked(first, "Helper handshake failed.");
    checked(second, "Concurrent helper handshake failed.");
    checked(
        bounded(client.handshake()).await,
        "Repeated helper handshake failed.",
    );
    client
}

pub(super) async fn finish(stream: QueryStream) -> Result<QueryOutcome, BackendError> {
    loop {
        match checked(
            bounded(stream.events.recv()).await,
            "The helper closed an unfinished stream.",
        )? {
            QueryEvent::Started | QueryEvent::Chunk { .. } | QueryEvent::ExportProgress { .. } => {}
            QueryEvent::Finished(outcome) => return Ok(outcome),
        }
    }
}

async fn query(client: &BackendClient, session: &str, sql: &str, purpose: &str) -> QueryOutcome {
    let stream = checked(
        client.execute(session, sql.to_owned()),
        "Cannot enqueue an integration query.",
    );
    finish(stream).await.unwrap_or_else(|error| {
        panic!(
            "The {purpose} query failed: category={}, SQLSTATE={}.",
            error.category,
            error.sql_state.as_deref().unwrap_or("unavailable")
        )
    })
}

fn env_value(name: &str) -> String {
    checked(
        std::env::var(name),
        "An isolated database setting is missing.",
    )
}

pub(super) fn postgres_connection() -> Option<Connection> {
    let dsn = match std::env::var("DBEER_TEST_DSN") {
        Ok(dsn) => dsn,
        Err(_) => {
            assert!(
                std::env::var("DBEER_REQUIRE_POSTGRES").as_deref() != Ok("1"),
                "PostgreSQL was required but its isolated fixture is unavailable."
            );
            return None;
        }
    };
    // The repository's PostgreSQL runner uses this fixed URL shape with random
    // hexadecimal credentials. Reject other forms instead of guessing a profile.
    let dsn = checked(
        dsn.strip_prefix("postgresql://").ok_or(()),
        "Unexpected PostgreSQL fixture URL format.",
    );
    let (credentials, address) = checked(
        dsn.split_once('@').ok_or(()),
        "Invalid PostgreSQL fixture credentials.",
    );
    let (user, password) = checked(
        credentials.split_once(':').ok_or(()),
        "Invalid PostgreSQL fixture credentials.",
    );
    let (address, database) = checked(
        address.split_once('/').ok_or(()),
        "Invalid PostgreSQL fixture address.",
    );
    let (host, port) = checked(
        address.rsplit_once(':').ok_or(()),
        "Invalid PostgreSQL fixture port.",
    );
    let database = checked(
        database.strip_suffix("?sslmode=disable").ok_or(()),
        "Unexpected PostgreSQL fixture TLS settings.",
    );
    Some(Connection {
        engine: "postgresql".into(),
        host: host.into(),
        port: checked(port.parse(), "Invalid PostgreSQL fixture port."),
        database: database.into(),
        user: user.into(),
        password: password.into(),
        ssl_mode: "disable".into(),
        ssl_root_cert: None,
        policy: ExecutionPolicy::default(),
    })
}

pub(super) fn mysql_connection() -> Option<Connection> {
    if std::env::var_os("DBEER_TEST_MYSQL_HOST").is_none() {
        assert!(
            std::env::var("DBEER_REQUIRE_MYSQL").as_deref() != Ok("1"),
            "MySQL was required but its isolated fixture is unavailable."
        );
        return None;
    }
    Some(Connection {
        engine: "mysql".into(),
        host: env_value("DBEER_TEST_MYSQL_HOST"),
        port: checked(
            env_value("DBEER_TEST_MYSQL_PORT").parse(),
            "Invalid MySQL fixture port.",
        ),
        database: env_value("DBEER_TEST_MYSQL_DATABASE"),
        user: env_value("DBEER_TEST_MYSQL_USER"),
        password: env_value("DBEER_TEST_MYSQL_PASSWORD"),
        ssl_mode: env_value("DBEER_TEST_MYSQL_SSLMODE"),
        ssl_root_cert: None,
        policy: ExecutionPolicy::default(),
    })
}

/// A separate helper and physical session observe only this fixture's server.
/// Its teardown cannot borrow or roll back either SQL-tab transaction.
struct PhysicalObserver {
    client: BackendClient,
    session: String,
    closed: bool,
}
impl PhysicalObserver {
    async fn connect(connection: Connection) -> Self {
        let path = checked(
            std::env::var_os("DBEER_GPUI_HELPER_PATH").ok_or(()),
            "The independent observer requires the runner's isolated helper.",
        );
        let client = checked(
            BackendClient::spawn(PathBuf::from(path)),
            "Cannot start the independent observer helper.",
        );
        let mut observer = Self {
            client,
            session: String::new(),
            closed: false,
        };
        checked(
            bounded(observer.client.handshake()).await,
            "Independent observer helper handshake failed.",
        );
        observer.session = checked(
            bounded(observer.client.connect(connection)).await,
            "Cannot connect the independent cancellation observer.",
        )
        .session_id;
        observer
    }

    async fn wait_for_sleep(&self, postgres: bool, server_id: u64) {
        let sql = if postgres {
            format!("SELECT wait_event FROM pg_stat_activity WHERE pid={server_id}")
        } else {
            format!("SELECT STATE FROM information_schema.PROCESSLIST WHERE ID={server_id}")
        };
        let observed = smol::future::race(
            async {
                loop {
                    let outcome = query(
                        &self.client,
                        &self.session,
                        &sql,
                        "physical cancellation observer",
                    )
                    .await;
                    if outcome
                        .result_sets
                        .iter()
                        .flat_map(|set| &set.rows)
                        .filter_map(|row| row.first())
                        .filter_map(|cell| cell.as_ref())
                        .any(|value| {
                            value.eq_ignore_ascii_case(if postgres {
                                "PgSleep"
                            } else {
                                "User sleep"
                            })
                        })
                    {
                        break true;
                    }
                    // Poll pacing only; the observed server state is the barrier.
                    smol::Timer::after(Duration::from_millis(5)).await;
                }
            },
            async {
                smol::Timer::after(Duration::from_secs(10)).await;
                false
            },
        )
        .await;
        assert!(
            observed,
            "The exact physical session did not reach its server sleep state."
        );
    }

    async fn close(&mut self) {
        checked(
            bounded(self.client.disconnect(&self.session)).await,
            "Independent observer disconnect failed.",
        );
        checked(
            self.client.await_owned_exit().await,
            "Independent observer helper exit was not proven.",
        );
        assert!(
            self.client.owned_process_exited(),
            "Independent observer helper exit was not observed."
        );
        self.closed = true;
    }
}
impl Drop for PhysicalObserver {
    fn drop(&mut self) {
        if !self.closed {
            // Includes a failed connect/query/assertion. Retire only this helper,
            // never a PID or an app session, and retain a cleanup failure as failure.
            let exited = smol::block_on(self.client.retire_owned_for_test()).is_ok()
                && self.client.owned_process_exited();
            if !exited {
                let message = "Independent cancellation observer helper cleanup failed.";
                if std::thread::panicking() {
                    eprintln!("{message}");
                } else {
                    panic!("{message}");
                }
            }
        }
    }
}

async fn verify_database(connection: Connection) {
    assert!(
        connection.policy.read_only,
        "Live checks must be read-only."
    );
    let postgres = connection.engine == "postgresql";
    let client = client().await;
    let first = checked(
        bounded(client.connect(connection.clone())).await,
        "The helper could not connect to the isolated database.",
    );
    let second = checked(
        bounded(client.connect(connection.clone())).await,
        "The helper could not open a second SQL-tab session.",
    );
    assert!(
        first.session_id != second.session_id,
        "SQL tabs must have independent helper sessions."
    );
    let first_id = &first.session_id;
    let second_id = &second.session_id;
    let identity_sql = if postgres {
        "SELECT pg_backend_pid()"
    } else {
        "SELECT CONNECTION_ID()"
    };
    let first_identity = query(&client, first_id, identity_sql, "first session identity").await;
    let second_identity = query(&client, second_id, identity_sql, "second session identity").await;
    assert!(
        first_identity.result_sets[0].rows[0][0] != second_identity.result_sets[0].rows[0][0],
        "SQL tabs must have independent physical database sessions."
    );
    let server_id = first_identity
        .result_sets
        .first()
        .and_then(|set| set.rows.first())
        .and_then(|row| row.first())
        .and_then(|cell| cell.as_ref())
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|id| *id > 0)
        .expect("The captured database session omitted its numeric physical identity.");
    let mut observer = PhysicalObserver::connect(connection).await;
    let observer_identity = query(
        &observer.client,
        &observer.session,
        identity_sql,
        "independent observer identity",
    )
    .await;
    assert!(
        observer_identity.result_sets[0].rows[0][0] != first_identity.result_sets[0].rows[0][0]
            && observer_identity.result_sets[0].rows[0][0]
                != second_identity.result_sets[0].rows[0][0],
        "The cancellation observer must have its own physical database session."
    );

    let typed_sql = if postgres {
        "SELECT NULL::text AS value_null, ''::text AS value_empty, 'NULL'::text AS value_literal, \
         9007199254740993.123456789::numeric AS value_exact, decode('00ff5c','hex') AS value_bytes"
    } else {
        "SELECT NULL AS value_null, '' AS value_empty, 'NULL' AS value_literal, \
         CAST('9007199254740993.123456789' AS DECIMAL(40,9)) AS value_exact, X'00FF5C' AS value_bytes"
    };
    let typed = query(&client, first_id, typed_sql, "typed values").await;
    assert!(
        typed.result_sets.len() == 1,
        "Typed query lost its result set."
    );
    let set = &typed.result_sets[0];
    assert!(set.rows.len() == 1, "Typed query lost its row.");
    assert!(set.columns.len() == 5, "Typed query lost column metadata.");
    let row = &set.rows[0];
    assert!(row[0].is_none(), "SQL NULL changed during transport.");
    assert!(
        row[1].as_deref() == Some(""),
        "Empty text changed during transport."
    );
    assert!(
        row[2].as_deref() == Some("NULL"),
        "Literal NULL text changed during transport."
    );
    assert!(
        row[3].as_deref() == Some("9007199254740993.123456789"),
        "Exact numeric text lost precision."
    );
    assert!(
        row[4].as_deref() == Some("AP9c"),
        "Binary bytes changed during transport."
    );
    assert!(
        set.columns[4].encoding.as_deref() == Some("base64"),
        "Binary column lost its encoding."
    );

    // More than one 64 KiB frame exercises stream credits. The server completes
    // every row while the client retains the helper's bounded display prefix.
    let stream_sql = if postgres {
        "SELECT n, repeat('x',1024) AS payload FROM generate_series(1,1107)n"
    } else {
        "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<600) \
         SELECT n, repeat('x',1024) AS payload FROM seq \
         UNION ALL SELECT n, repeat('x',1024) AS payload FROM seq"
    };
    let streamed = query(&client, first_id, stream_sql, "bounded stream").await;
    assert!(
        streamed.result_sets.len() == 1,
        "Streaming lost its result set."
    );
    let set = &streamed.result_sets[0];
    assert!(
        set.rows.len() == 1000,
        "Streaming did not retain its bounded display prefix."
    );
    assert!(set.truncated, "The helper's truncation notice was lost.");
    assert!(
        set.row_count == if postgres { 1107 } else { 1200 },
        "Streaming did not finish the full server command."
    );

    let catalog = checked(
        client.catalog(
            first_id,
            CatalogRequest {
                kind: "schemas".into(),
                ..CatalogRequest::default()
            },
        ),
        "Cannot enqueue a catalog request.",
    );
    let catalog = checked(finish(catalog).await, "Catalog request failed.");
    assert!(
        catalog.result_sets.iter().any(|set| !set.rows.is_empty()),
        "The real database catalog was empty."
    );

    let begin = query(
        &client,
        first_id,
        "START TRANSACTION READ ONLY",
        "begin transaction",
    )
    .await;
    assert!(
        matches!(begin.transaction_status, TransactionStatus::Transaction),
        "The first SQL tab lost its transaction state."
    );
    let other = query(&client, second_id, "SELECT 1", "independent session").await;
    assert!(
        matches!(other.transaction_status, TransactionStatus::Idle),
        "A transaction leaked into another SQL tab."
    );
    let failed = checked(
        client.execute(first_id, "SELECT * FROM dbeer_gpui_missing_table".into()),
        "Cannot enqueue the transaction error check.",
    );
    let failed = match finish(failed).await {
        Err(error) => error,
        Ok(_) => panic!("The missing-table query unexpectedly succeeded."),
    };
    assert!(
        failed.category == "sql" && failed.connected && !failed.outcome_unknown,
        "A recoverable SQL error lost its known session state."
    );
    assert!(
        failed.transaction_status
            == Some(if postgres {
                TransactionStatus::FailedTransaction
            } else {
                TransactionStatus::Transaction
            }),
        "The helper lost the engine's transaction state after a SQL error."
    );
    let rollback = query(&client, first_id, "ROLLBACK", "rollback").await;
    assert!(
        matches!(rollback.transaction_status, TransactionStatus::Idle),
        "Rollback did not restore the SQL tab state."
    );

    let blocked = checked(
        client.execute(
            first_id,
            "CREATE TABLE dbeer_gpui_must_not_exist(id integer)".into(),
        ),
        "Cannot enqueue the read-only policy check.",
    );
    let blocked = match finish(blocked).await {
        Err(error) => error,
        Ok(_) => panic!("The read-only helper accepted a database write."),
    };
    assert!(
        blocked.connected && !blocked.outcome_unknown,
        "A policy rejection damaged the SQL tab session."
    );

    let sleep_sql = if postgres {
        "SELECT pg_sleep(30)"
    } else {
        "SELECT 1 FROM (SELECT 1 AS n UNION ALL SELECT 2) source_rows WHERE SLEEP(30)=0"
    };
    let pending = checked(
        client.execute(first_id, sleep_sql.into()),
        "Cannot enqueue cancellation check.",
    );
    match checked(
        bounded(pending.events.recv()).await,
        "The cancellable stream did not start.",
    ) {
        Ok(QueryEvent::Started) => {}
        _ => panic!("The cancellable stream did not start correctly."),
    }
    observer.wait_for_sleep(postgres, server_id).await;
    let cancelled = checked(
        bounded(client.cancel(first_id, &pending.query_id)).await,
        "Cancellation was not acknowledged.",
    );
    assert!(
        cancelled.status == "accepted",
        "The running query did not accept cancellation."
    );
    let error = match finish(pending).await {
        Err(error) => error,
        Ok(_) => panic!("The cancelled query unexpectedly completed."),
    };
    assert!(
        error.category == "cancelled" && error.connected && !error.outcome_unknown,
        "Cancellation did not preserve a known, reusable SQL tab session."
    );
    let after_cancel = query(
        &client,
        first_id,
        identity_sql,
        "session reuse after cancellation",
    )
    .await;
    assert!(
        after_cancel.result_sets[0].rows[0][0] == first_identity.result_sets[0].rows[0][0],
        "Cancellation replaced the physical SQL-tab session."
    );

    checked(
        bounded(client.disconnect(first_id)).await,
        "Disconnect failed.",
    );
    let stale = checked(
        client.execute(first_id, "SELECT 1".into()),
        "Cannot enqueue the disconnected-session check.",
    );
    let stale = match finish(stale).await {
        Err(error) => error,
        Ok(_) => panic!("A disconnected SQL tab was silently reconnected."),
    };
    assert!(
        !stale.connected && !stale.outcome_unknown,
        "A disconnected SQL tab reported an incorrect connection state."
    );
    let other = query(&client, second_id, "SELECT 1", "independent session").await;
    assert!(
        matches!(other.transaction_status, TransactionStatus::Idle),
        "Disconnect affected another SQL tab."
    );
    checked(
        bounded(client.disconnect(second_id)).await,
        "Second disconnect failed.",
    );
    observer.close().await;
}

async fn approved_query(
    client: &BackendClient,
    session: &str,
    sql: &str,
    confirmation_required: bool,
) -> QueryOutcome {
    let assessment = checked(
        bounded(client.assess(session, sql.to_owned())).await,
        "The helper could not assess an isolated operation.",
    );
    assert!(
        assessment.requires_confirmation() == confirmation_required && !assessment.rejected(),
        "The production execution policy made an unexpected decision."
    );
    assert!(
        assessment.authorization.is_some(),
        "The helper omitted the exact-operation authorization."
    );
    let stream = checked(
        client.execute_authorized(session, sql.to_owned(), assessment.authorization),
        "Cannot enqueue the explicitly authorized operation.",
    );
    checked(
        finish(stream).await,
        "The explicitly authorized operation failed.",
    )
}

async fn policy_rejection(stream: QueryStream) {
    let error = match finish(stream).await {
        Err(error) => error,
        Ok(_) => panic!("The helper accepted a write without valid exact-operation authorization."),
    };
    assert!(
        error.category == "policy" && error.connected && !error.outcome_unknown,
        "The helper did not reject unauthorized SQL safely."
    );
}

async fn verify_write_policy(mut connection: Connection) {
    // This opt-in is set only by test-gpui-databases.sh, which creates fresh,
    // disposable servers. Tables are session-local and disappear on every exit.
    assert!(
        std::env::var("DBEER_GPUI_DISPOSABLE_DATABASES").as_deref() == Ok("1"),
        "Write-policy checks require disposable database fixtures."
    );
    connection.policy = ExecutionPolicy {
        environment: "production".into(),
        read_only: false,
    };
    let postgres = connection.engine == "postgresql";
    let client = client().await;
    let first = checked(
        bounded(client.connect(connection.clone())).await,
        "Cannot connect the opt-in write-policy session.",
    );
    let second = checked(
        bounded(client.connect(connection)).await,
        "Cannot connect the independent write-policy session.",
    );
    let session = &first.session_id;
    let create = if postgres {
        "CREATE TEMP TABLE dbeer_gpui_policy_rows(id integer)"
    } else {
        "CREATE TEMPORARY TABLE dbeer_gpui_policy_rows(id integer) ENGINE=InnoDB"
    };
    let assessment = checked(
        bounded(client.assess(session, create.into())).await,
        "Cannot assess a production write.",
    );
    assert!(
        assessment.requires_confirmation() && assessment.authorization.is_some(),
        "A production write did not require explicit confirmation."
    );
    policy_rejection(checked(
        client.execute(session, create.into()),
        "Cannot enqueue the missing-authorization check.",
    ))
    .await;

    let assessment = checked(
        bounded(client.assess(session, create.into())).await,
        "Cannot reassess a production write.",
    );
    policy_rejection(checked(
        client.execute_authorized(session, format!("{create} "), assessment.authorization),
        "Cannot enqueue the changed-SQL authorization check.",
    ))
    .await;

    let assessment = checked(
        bounded(client.assess(session, create.into())).await,
        "Cannot reassess the exact production write.",
    );
    let token = assessment.authorization;
    let created = checked(
        client.execute_authorized(session, create.into(), token.clone()),
        "Cannot enqueue the confirmed temporary-table creation.",
    );
    checked(
        finish(created).await,
        "Confirmed temporary-table creation failed.",
    );
    policy_rejection(checked(
        client.execute_authorized(session, create.into(), token),
        "Cannot enqueue the one-shot authorization replay check.",
    ))
    .await;

    let begin = approved_query(&client, session, "BEGIN", false).await;
    assert!(
        matches!(begin.transaction_status, TransactionStatus::Transaction),
        "The write transaction did not open."
    );
    let inserted = approved_query(
        &client,
        session,
        "INSERT INTO dbeer_gpui_policy_rows VALUES(1)",
        true,
    )
    .await;
    assert!(
        matches!(inserted.transaction_status, TransactionStatus::Transaction),
        "An authorized write lost its open transaction."
    );
    let other = query(
        &client,
        &second.session_id,
        "SELECT 1",
        "independent write-policy session",
    )
    .await;
    assert!(
        matches!(other.transaction_status, TransactionStatus::Idle),
        "A write transaction leaked into another SQL tab."
    );
    let rollback = approved_query(&client, session, "ROLLBACK", false).await;
    assert!(
        matches!(rollback.transaction_status, TransactionStatus::Idle),
        "Explicit rollback did not close the write transaction."
    );
    let count = query(
        &client,
        session,
        "SELECT COUNT(*) FROM dbeer_gpui_policy_rows",
        "rolled-back row count",
    )
    .await;
    assert!(
        count.result_sets[0].rows[0][0].as_deref() == Some("0"),
        "An explicit rollback retained a database edit."
    );

    approved_query(&client, session, "BEGIN", false).await;
    approved_query(
        &client,
        session,
        "INSERT INTO dbeer_gpui_policy_rows VALUES(2)",
        true,
    )
    .await;
    let commit = approved_query(&client, session, "COMMIT", false).await;
    assert!(
        matches!(commit.transaction_status, TransactionStatus::Idle),
        "Explicit commit did not close the write transaction."
    );
    let committed = query(
        &client,
        session,
        "SELECT id FROM dbeer_gpui_policy_rows",
        "committed temporary row",
    )
    .await;
    assert!(
        committed.result_sets[0].rows.len() == 1
            && committed.result_sets[0].rows[0][0].as_deref() == Some("2"),
        "An explicit commit lost its database edit."
    );
    let isolated = checked(
        client.execute(
            &second.session_id,
            "SELECT * FROM dbeer_gpui_policy_rows".into(),
        ),
        "Cannot enqueue the session-local table isolation check.",
    );
    let isolated = match finish(isolated).await {
        Err(error) => error,
        Ok(_) => panic!("A temporary table leaked into another SQL tab."),
    };
    assert!(
        isolated.category == "sql"
            && isolated.connected
            && isolated.transaction_status == Some(TransactionStatus::Idle),
        "The independent SQL tab lost its state."
    );
    checked(
        bounded(client.disconnect(session)).await,
        "Write-policy disconnect failed.",
    );
    checked(
        bounded(client.disconnect(&second.session_id)).await,
        "Independent write-policy disconnect failed.",
    );
}

#[test]
fn existing_go_helper_handshake() {
    smol::block_on(async {
        let _client = client().await;
    });
}

#[test]
fn postgres_live_helper() {
    if let Some(connection) = postgres_connection() {
        smol::block_on(verify_database(connection));
    }
}

#[test]
fn mysql_live_helper() {
    if let Some(connection) = mysql_connection() {
        smol::block_on(verify_database(connection));
    }
}

/// Actual owned Go process death while the captured physical DB query is active.
/// This is native headless fault coverage, not an installed GUI/COMMIT proof.
async fn verify_real_helper_death(connection: Connection) {
    assert!(
        std::env::var("DBEER_GPUI_DISPOSABLE_DATABASES").as_deref() == Ok("1"),
        "Real helper death requires the final runner's owned database fixtures."
    );
    let postgres = connection.engine == "postgresql";
    let mut source = checked(
        crate::fault_test_support::RealHelperSource::open(),
        "The original real helper source could not be retained.",
    );
    let owner = checked(source.spawn(), "Cannot spawn the retained real helper.");
    checked(
        bounded(owner.handshake()).await,
        "Real helper handshake failed.",
    );
    let session = checked(
        bounded(owner.connect(connection.clone())).await,
        "Cannot connect the original real helper session.",
    )
    .session_id;
    let identity_sql = if postgres {
        "SELECT pg_backend_pid()"
    } else {
        "SELECT CONNECTION_ID()"
    };
    let original = query(
        &owner,
        &session,
        identity_sql,
        "original fault session identity",
    )
    .await;
    let server_id = original
        .result_sets
        .first()
        .and_then(|set| set.rows.first())
        .and_then(|row| row.first())
        .and_then(|cell| cell.as_ref())
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value > 0)
        .expect("The original physical fault session identity is missing.");
    let mut observer = PhysicalObserver::connect(connection).await;
    let independent = query(
        &observer.client,
        &observer.session,
        identity_sql,
        "fault observer identity",
    )
    .await;
    assert!(
        independent.result_sets[0].rows[0][0] != original.result_sets[0].rows[0][0],
        "The fault observer must use a separate physical session."
    );
    let sleeping = if postgres {
        "SELECT pg_sleep(30)"
    } else {
        "SELECT SLEEP(30)"
    };
    let pending = checked(
        owner.execute(&session, sleeping.into()),
        "Cannot enqueue the original fault query.",
    );
    match checked(
        bounded(pending.events.recv()).await,
        "The original fault query never started.",
    ) {
        Ok(QueryEvent::Started) => {}
        _ => panic!("The original fault query did not report its original start."),
    }
    observer.wait_for_sleep(postgres, server_id).await;
    // Shared::fail completes this exact pending stream as Unknown, then the
    // original retained native Child is killed/reaped. A broken pipe alone is
    // never credited as an observed process exit or database rollback.
    checked(
        bounded(owner.retire_owned_for_test()).await,
        "The original real helper did not retire.",
    );
    assert!(
        owner.owned_process_exited(),
        "Actual original helper exit was not observed."
    );
    assert!(
        !owner.is_alive(),
        "The retired real helper still accepts ordinary operations."
    );
    let error = match finish(pending).await {
        Err(error) => error,
        Ok(_) => panic!("An interrupted original query was falsely accepted as completed."),
    };
    assert!(
        error.outcome_unknown && !error.connected,
        "Real helper death must preserve the pending query's uncertain outcome."
    );
    assert!(
        owner.execute(&session, "SELECT 1".into()).is_err(),
        "A dead original helper silently reconnected/retried the original session."
    );
    let physical = if postgres {
        format!("SELECT COUNT(*) FROM pg_stat_activity WHERE pid={server_id}")
    } else {
        format!("SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID={server_id}")
    };
    let gone = smol::future::race(
        async {
            loop {
                let snapshot = query(
                    &observer.client,
                    &observer.session,
                    &physical,
                    "original fault session exit",
                )
                .await;
                if snapshot.result_sets[0].rows[0][0].as_deref() == Some("0") {
                    break true;
                }
                smol::Timer::after(Duration::from_millis(5)).await;
            }
        },
        async {
            smol::Timer::after(Duration::from_secs(10)).await;
            false
        },
    )
    .await;
    assert!(
        gone,
        "The exact original physical DB session did not disappear."
    );
    let still_independent = query(
        &observer.client,
        &observer.session,
        identity_sql,
        "fault observer preservation",
    )
    .await;
    assert!(
        still_independent.result_sets[0].rows[0][0] == independent.result_sets[0].rows[0][0],
        "Retiring the original helper disturbed its independent observer."
    );
    checked(
        source.verify(),
        "The original real helper executable changed during fault coverage.",
    );
    observer.close().await;
}

#[test]
fn postgres_real_helper_death_awaits_original_exit_and_physical_session_loss() {
    if std::env::var("DBEER_GPUI_DISPOSABLE_DATABASES").as_deref() == Ok("1")
        && let Some(connection) = postgres_connection()
    {
        smol::block_on(verify_real_helper_death(connection));
    }
}

#[test]
fn mysql_real_helper_death_awaits_original_exit_and_physical_session_loss() {
    if std::env::var("DBEER_GPUI_DISPOSABLE_DATABASES").as_deref() == Ok("1")
        && let Some(connection) = mysql_connection()
    {
        smol::block_on(verify_real_helper_death(connection));
    }
}

#[test]
fn postgres_opt_in_write_policy() {
    if std::env::var("DBEER_GPUI_DISPOSABLE_DATABASES").as_deref() == Ok("1")
        && let Some(connection) = postgres_connection()
    {
        smol::block_on(verify_write_policy(connection));
    }
}

#[test]
fn mysql_opt_in_write_policy() {
    if std::env::var("DBEER_GPUI_DISPOSABLE_DATABASES").as_deref() == Ok("1")
        && let Some(connection) = mysql_connection()
    {
        smol::block_on(verify_write_policy(connection));
    }
}

async fn verify_ordered_read_script(connection: Connection) {
    let postgres = connection.engine == "postgresql";
    let client = client().await;
    let connected = checked(
        bounded(client.connect(connection)).await,
        "Cannot connect the read-script fixture.",
    );
    let identity = if postgres {
        "SELECT pg_backend_pid()"
    } else {
        "SELECT CONNECTION_ID()"
    };
    let source = format!(
        "{identity};\r\nBEGIN;\r\n{identity};\r\nSELECT * FROM dbeer_gpui_script_missing;\r\nSELECT 987654321;"
    );
    let fragment = crate::sql::resolve(
        crate::sql::SourceText::new(source),
        0..0,
        if postgres {
            crate::sql::Dialect::PostgreSQL
        } else {
            crate::sql::Dialect::MySQL
        },
        true,
    )
    .unwrap();
    let assessment = checked(
        bounded(
            client.assess_operations(&connected.session_id, crate::scripts::operations(&fragment)),
        )
        .await,
        "Read-script preflight failed.",
    );
    assert!(
        !assessment.rejected() && !assessment.requires_confirmation(),
        "The read-script fixture unexpectedly requires helper confirmation."
    );
    // UI still reviews this allow decision; this contract fixture represents
    // an explicit approval of the immutable ordered batch.
    let mut outcomes = Vec::new();
    let mut failed = false;
    for statement in fragment.statements() {
        if failed {
            break;
        }
        match finish(checked(
            client.execute_authorized(
                &connected.session_id,
                statement.sql().to_owned(),
                assessment.authorization.clone(),
            ),
            "Cannot submit the captured read-script statement.",
        ))
        .await
        {
            Ok(outcome) => outcomes.push(outcome),
            Err(error) => {
                assert!(
                    error.connected
                        && !error.outcome_unknown
                        && error.transaction_status
                            == Some(if postgres {
                                TransactionStatus::FailedTransaction
                            } else {
                                TransactionStatus::Transaction
                            }),
                    "A middle script error lost its authoritative session state."
                );
                failed = true;
            }
        }
    }
    assert!(
        failed && outcomes.len() == 3,
        "The read script did not stop at its first failure."
    );
    assert!(
        outcomes[0].result_sets[0].rows[0][0] == outcomes[2].result_sets[0].rows[0][0],
        "The script changed physical database sessions."
    );
    assert!(
        outcomes[1].result_sets.iter().all(|s| s.columns.is_empty()),
        "BEGIN lost its command-only result context."
    );
    assert!(outcomes[1].transaction_status == TransactionStatus::Transaction);
    // An error destroys the remaining grant; a later operation cannot reuse it.
    policy_rejection(checked(
        client.execute_authorized(
            &connected.session_id,
            fragment.statements()[4].sql().to_owned(),
            assessment.authorization,
        ),
        "Cannot verify the failed script grant was revoked.",
    ))
    .await;
    query(
        &client,
        &connected.session_id,
        "ROLLBACK",
        "read-script cleanup",
    )
    .await;
    checked(
        bounded(client.disconnect(&connected.session_id)).await,
        "Read-script disconnect failed.",
    );
}

async fn verify_script_grant_order_and_revocation(mut connection: Connection) {
    assert!(
        std::env::var("DBEER_GPUI_DISPOSABLE_DATABASES").as_deref() == Ok("1"),
        "Script grant tests require disposable database fixtures."
    );
    connection.policy = ExecutionPolicy {
        environment: "production".into(),
        read_only: false,
    };
    let client = client().await;
    let connected = checked(
        bounded(client.connect(connection.clone())).await,
        "Cannot connect the ordered-grant fixture.",
    );
    let other = checked(
        bounded(client.connect(connection)).await,
        "Cannot connect the independent grant fixture.",
    );
    let operations = vec![
        crate::backend::OperationRequest::Execute {
            sql: "SELECT 1".into(),
            export: None,
        },
        crate::backend::OperationRequest::Execute {
            sql: "SELECT 2".into(),
            export: None,
        },
    ];
    let assess = || client.assess_operations(&connected.session_id, operations.clone());
    let grant = checked(bounded(assess()).await, "Cannot assess an ordered grant.");
    policy_rejection(checked(
        client.execute_authorized(
            &connected.session_id,
            "SELECT 2".into(),
            grant.authorization,
        ),
        "Cannot enqueue the out-of-order grant check.",
    ))
    .await;
    let grant = checked(
        bounded(assess()).await,
        "Cannot assess a session-bound grant.",
    );
    policy_rejection(checked(
        client.execute_authorized(&other.session_id, "SELECT 1".into(), grant.authorization),
        "Cannot enqueue the cross-session grant check.",
    ))
    .await;
    let grant = checked(
        bounded(assess()).await,
        "Cannot assess the cancelled grant.",
    );
    checked(
        bounded(client.revoke_authorization(&connected.session_id)).await,
        "Cannot revoke a cancelled review grant.",
    );
    policy_rejection(checked(
        client.execute_authorized(
            &connected.session_id,
            "SELECT 1".into(),
            grant.authorization,
        ),
        "Cannot enqueue the revoked grant check.",
    ))
    .await;
    let grant = checked(
        bounded(assess()).await,
        "Cannot assess the final ordered batch.",
    );
    for value in ["SELECT 1", "SELECT 2"] {
        checked(
            finish(checked(
                client.execute_authorized(
                    &connected.session_id,
                    value.into(),
                    grant.authorization.clone(),
                ),
                "Cannot enqueue the exact ordered statement.",
            ))
            .await,
            "The exact ordered statement failed.",
        );
    }
    policy_rejection(checked(
        client.execute_authorized(
            &connected.session_id,
            "SELECT 1".into(),
            grant.authorization,
        ),
        "Cannot enqueue the consumed grant replay check.",
    ))
    .await;
    checked(
        bounded(client.disconnect(&connected.session_id)).await,
        "Ordered-grant disconnect failed.",
    );
    checked(
        bounded(client.disconnect(&other.session_id)).await,
        "Independent grant disconnect failed.",
    );
}

#[test]
fn postgres_ordered_read_script() {
    if let Some(connection) = postgres_connection() {
        smol::block_on(verify_ordered_read_script(connection));
    }
}
#[test]
fn mysql_ordered_read_script() {
    if let Some(connection) = mysql_connection() {
        smol::block_on(verify_ordered_read_script(connection));
    }
}
#[test]
fn postgres_opt_in_script_grant_order_and_revocation() {
    if std::env::var("DBEER_GPUI_DISPOSABLE_DATABASES").as_deref() == Ok("1")
        && let Some(connection) = postgres_connection()
    {
        smol::block_on(verify_script_grant_order_and_revocation(connection));
    }
}
#[test]
fn mysql_opt_in_script_grant_order_and_revocation() {
    if std::env::var("DBEER_GPUI_DISPOSABLE_DATABASES").as_deref() == Ok("1")
        && let Some(connection) = mysql_connection()
    {
        smol::block_on(verify_script_grant_order_and_revocation(connection));
    }
}

#[test]
fn mysql_opt_in_delimiter_routine_keeps_all_statement_result_sets() {
    if std::env::var("DBEER_GPUI_DISPOSABLE_DATABASES").as_deref() != Ok("1") {
        return;
    }
    let Some(mut connection) = mysql_connection() else {
        return;
    };
    connection.policy = ExecutionPolicy {
        environment: "production".into(),
        read_only: false,
    };
    smol::block_on(async move {
        let client = client().await;
        let connected = checked(
            bounded(client.connect(connection)).await,
            "Cannot connect the disposable routine fixture.",
        );
        let name = format!("dbeer_gpui_script_proc_{}", std::process::id());
        let source = format!(
            "DELIMITER $$\r\nCREATE PROCEDURE {name}() BEGIN SELECT NULL AS n, '' AS e, 'NULL' AS t; SELECT CAST('9007199254740993.123456789' AS DECIMAL(40,9)) AS exact_value, X'00FF5C' AS bytes_value; END$$\r\nDELIMITER ;\r\nCALL {name}();\r\nDROP PROCEDURE {name};"
        );
        let fragment = crate::sql::resolve(
            crate::sql::SourceText::new(source),
            0..0,
            crate::sql::Dialect::MySQL,
            true,
        )
        .unwrap();
        assert!(
            crate::scripts::validate(&fragment).is_ok() && fragment.statements().len() == 3,
            "The routine was split into executable pieces."
        );
        let assessment =
            checked(
                bounded(client.assess_operations(
                    &connected.session_id,
                    crate::scripts::operations(&fragment),
                ))
                .await,
                "Cannot assess the whole stored-routine script.",
            );
        assert!(!assessment.rejected() && assessment.authorization.is_some());
        let mut calls = Vec::new();
        for statement in fragment.statements() {
            calls.push(checked(
                finish(checked(
                    client.execute_authorized(
                        &connected.session_id,
                        statement.sql().to_owned(),
                        assessment.authorization.clone(),
                    ),
                    "Cannot enqueue the exact routine statement.",
                ))
                .await,
                "The approved stored-routine statement failed.",
            ));
        }
        assert!(
            calls[0].result_sets.iter().all(|s| s.columns.is_empty()),
            "Routine creation lost its command-only context."
        );
        let sets: Vec<_> = calls[1]
            .result_sets
            .iter()
            .filter(|s| !s.columns.is_empty())
            .collect();
        assert!(
            sets.len() == 2
                && sets[0].rows[0][0].is_none()
                && sets[0].rows[0][1].as_deref() == Some("")
                && sets[0].rows[0][2].as_deref() == Some("NULL"),
            "CALL lost its typed first result set."
        );
        assert!(
            sets[1].rows[0][0].as_deref() == Some("9007199254740993.123456789")
                && sets[1].rows[0][1].as_deref() == Some("AP9c"),
            "CALL changed exact numeric or binary bytes."
        );
        assert!(calls[2].transaction_status == TransactionStatus::Idle);
        checked(
            bounded(client.disconnect(&connected.session_id)).await,
            "Routine fixture disconnect failed.",
        );
    });
}
