//! Prepared disposable DB acceptance. Nothing runs without the isolated runner.
use super::*;
use crate::{
    backend::{CatalogRequest, ColumnAssignment, RowChange, SnapshotColumn},
    live_tests,
};
async fn sql(client: &BackendClient, session: &str, source: String) -> backend::QueryOutcome {
    let assessment = live_tests::bounded(client.assess(session, source.clone()))
        .await
        .expect("Assess isolated fixture SQL.");
    assert!(
        !assessment.rejected(),
        "Fixture SQL must be allowed on the disposable writer."
    );
    live_tests::finish(
        client
            .execute_authorized(session, source, assessment.authorization)
            .expect("Submit authorized isolated fixture SQL."),
    )
    .await
    .expect("Complete isolated fixture SQL.")
}
#[test]
fn postgres_mysql_previews_and_atomic_apply_preserve_independent_sql_state() {
    if std::env::var("DBEER_GPUI_DISPOSABLE_DATABASES").as_deref() != Ok("1") {
        return;
    }
    for mut connection in [
        live_tests::postgres_connection(),
        live_tests::mysql_connection(),
    ]
    .into_iter()
    .flatten()
    {
        smol::block_on(async move {
            connection.policy = backend::ExecutionPolicy {
                environment: "development".into(),
                read_only: false,
            };
            let client = live_tests::client().await;
            let observer = live_tests::bounded(client.connect(connection.clone()))
                .await
                .expect("Connect fixture observer.");
            let original_sql = live_tests::bounded(client.connect(connection.clone()))
                .await
                .expect("Connect independent SQL transaction.");
            let service = live_tests::bounded(client.connect(connection.clone()))
                .await
                .expect("Connect original catalog service.");
            let postgres = connection.engine == "postgresql";
            let table = format!("gpui_preview_{}", uuid::Uuid::new_v4().simple());
            // Identifiers contain only a fixed ASCII prefix and random hex. This
            // test DDL is never part of a product changes/preview request.
            let quoted = if postgres {
                format!("\"{table}\"")
            } else {
                format!("`{table}`")
            };
            let schema = if postgres {
                "public".to_owned()
            } else {
                connection.database.clone()
            };
            let definition = if postgres {
                "(id integer,part integer,value text DEFAULT 'base',bytes bytea,quantity numeric(40,20),computed integer GENERATED ALWAYS AS(id+part) STORED,PRIMARY KEY(id,part))"
            } else {
                "(id INT,part INT,value VARCHAR(80) DEFAULT 'base',bytes VARBINARY(8),quantity DECIMAL(40,20),computed INT GENERATED ALWAYS AS(id+part) STORED,PRIMARY KEY(id,part)) ENGINE=InnoDB"
            };
            sql(
                &client,
                &observer.session_id,
                format!("CREATE TABLE {quoted} {definition}"),
            )
            .await;
            let binary = if postgres {
                "decode('00ff5c','hex')"
            } else {
                "X'00FF5C'"
            };
            sql(&client,&observer.session_id,format!("INSERT INTO {quoted} (id,part,value,bytes,quantity) VALUES(1,1,NULL,{binary},9007199254740993.123456789),(2,1,'NULL',{binary},2)" )).await;
            sql(
                &client,
                &original_sql.session_id,
                "CREATE TEMPORARY TABLE dbeer_preview_private(marker varchar(40))".into(),
            )
            .await;
            sql(
                &client,
                &original_sql.session_id,
                "INSERT INTO dbeer_preview_private VALUES ('private-session-value')".into(),
            )
            .await;
            sql(&client, &original_sql.session_id, "BEGIN".into()).await;
            let marker_set = if postgres {
                "SET application_name='gpui-preview-original'"
            } else {
                "SET @dbeer_preview_marker='gpui-preview-original'"
            };
            sql(&client, &original_sql.session_id, marker_set.into()).await;
            let marker_read = if postgres {
                "SELECT current_setting('application_name'),marker FROM dbeer_preview_private"
            } else {
                "SELECT @dbeer_preview_marker,marker FROM dbeer_preview_private"
            };
            let marker_before = sql(&client, &original_sql.session_id, marker_read.into()).await;
            let request = CatalogRequest {
                kind: "browse".into(),
                schema: schema.clone(),
                object: table.clone(),
                object_kind: "table".into(),
                ..Default::default()
            };
            let before = live_tests::finish(
                client
                    .catalog(&service.session_id, request.clone())
                    .expect("Browse original table."),
            )
            .await
            .expect("Read original table.");
            let set = &before.result_sets[0];
            assert!(set.rows.len() == 2);
            let original = |row: usize| {
                set.columns
                    .iter()
                    .zip(&set.rows[row])
                    .map(|(column, value)| crate::grid_changes::original_value(column, value))
                    .collect()
            };
            let assignment = |column: &str, value: CellValue| ColumnAssignment {
                column: column.into(),
                value,
            };
            let changes = ChangesRequest {
                schema,
                table: table.clone(),
                columns: set
                    .columns
                    .iter()
                    .map(|c| SnapshotColumn {
                        name: c.name.clone(),
                        engine: c.engine.clone(),
                        native_type: c.native_type.clone(),
                    })
                    .collect(),
                changes: vec![
                    RowChange {
                        kind: backend::ChangeKind::Update,
                        original: original(0),
                        values: vec![
                            assignment("value", CellValue::Text("NULL\r\n😀 ' $1 ?".into())),
                            assignment(
                                "quantity",
                                CellValue::Text("9007199254740993.123456789".into()),
                            ),
                            assignment("bytes", CellValue::Binary("AP9c".into())),
                        ],
                    },
                    RowChange {
                        kind: backend::ChangeKind::Insert,
                        original: vec![],
                        values: vec![
                            assignment("id", CellValue::Text("3".into())),
                            assignment("part", CellValue::Text("1".into())),
                            assignment("value", CellValue::Default),
                            assignment("bytes", CellValue::Binary(String::new())),
                            assignment("quantity", CellValue::Null),
                        ],
                    },
                    RowChange {
                        kind: backend::ChangeKind::Delete,
                        original: original(1),
                        values: vec![],
                    },
                ],
            };
            let plan = Plan::new(changes.clone()).expect("Freeze typed fixture changes.");
            let borrowed = vec![
                observer.session_id.clone(),
                original_sql.session_id.clone(),
                service.session_id.clone(),
            ];
            let mut previous = None;
            for _ in 0..2 {
                let connected = live_tests::bounded(client.connect(connection.clone()))
                    .await
                    .expect("Connect separate idle preview.");
                assert!(!borrowed.contains(&connected.session_id));
                assert!(previous.as_ref() != Some(&connected.session_id));
                previous = Some(connected.session_id.clone());
                let session = FreshSession::adopt(
                    client.clone(),
                    connected,
                    Purpose::Standalone,
                    connection.policy.clone(),
                    Cancellation::default(),
                    &borrowed,
                )
                .expect("Adopt fresh preview session.");
                let previewed = live_tests::bounded(
                    plan.preview(&session)
                        .expect("Submit readonly preview.")
                        .finish(),
                )
                .await
                .expect("Complete exact parameterized preview.");
                let prepared = live_tests::bounded(
                    previewed
                        .begin_assessment()
                        .expect("Assess exact changes.apply batch.")
                        .finish(),
                )
                .await
                .expect("Receive helper batch assessment.");
                let display = prepared.display();
                assert!(display.contains("9007199254740993.123456789"));
                assert!(display.contains("AP9c"));
                assert!(display.contains("DEFAULT"));
                assert!(prepared.approval(true).is_err());
                live_tests::bounded(session.cleanup())
                    .await
                    .expect("Revoke and close standalone preview.");
            }
            let after = live_tests::finish(
                client
                    .catalog(&service.session_id, request)
                    .expect("Observer browse after previews."),
            )
            .await
            .expect("Read unchanged table.");
            assert!(
                before.result_sets == after.result_sets,
                "Standalone preview must not mutate database rows."
            );
            let marker_after = sql(&client, &original_sql.session_id, marker_read.into()).await;
            assert!(marker_after.transaction_status == backend::TransactionStatus::Transaction);
            assert!(
                marker_before.result_sets == marker_after.result_sets,
                "SQL session SET state must be unchanged."
            );
            // Apply always opens another idle session and re-previews/re-assesses
            // the exact immutable batch, independent of both observer and SQL tab.
            let (apply_session, pending) =
                begin_apply(&client, &connection, &borrowed, plan.clone()).await;
            let applied = live_tests::bounded(pending.finish())
                .await
                .expect("Atomic Apply completion.");
            assert!(
                applied.row_count == 3
                    && applied.transaction_status == backend::TransactionStatus::Idle
            );
            live_tests::bounded(apply_session.cleanup())
                .await
                .expect("Close successful Apply session.");
            let observed = sql(
                &client,
                &observer.session_id,
                format!(
                    "SELECT id,part,value,bytes,quantity,computed FROM {quoted} ORDER BY id,part"
                ),
            )
            .await;
            let rows = &observed.result_sets[0].rows;
            assert!(rows.len() == 2);
            assert!(rows[0][0].as_deref() == Some("1") && rows[0][1].as_deref() == Some("1"));
            assert!(rows[0][2].as_deref() == Some("NULL\r\n😀 ' $1 ?"));
            assert!(rows[0][3].as_deref() == Some("AP9c"));
            assert!(rows[0][4].as_deref() == Some("9007199254740993.12345678900000000000"));
            assert!(rows[0][5].as_deref() == Some("2"));
            assert!(rows[1][0].as_deref() == Some("3") && rows[1][2].as_deref() == Some("base"));
            assert!(rows[1][3].as_deref() == Some("") && rows[1][4].is_none());
            assert!(rows[1][5].as_deref() == Some("4"));
            // The first operation would succeed alone; each later failure must
            // roll back that insert. Every attempt has another fresh Apply owner.
            for (id, failure) in [(7, 0), (8, 1), (9, 2)] {
                let insert = RowChange {
                    kind: backend::ChangeKind::Insert,
                    original: vec![],
                    values: vec![
                        assignment("id", CellValue::Text(id.to_string())),
                        assignment("part", CellValue::Text("1".into())),
                        assignment("value", CellValue::Text("must roll back".into())),
                    ],
                };
                let later = match failure {
                    0 => changes.changes[0].clone(), // untouched PK, changed non-key full-row original
                    1 => changes.changes[2].clone(), // the earlier successful Apply deleted this row
                    _ => RowChange {
                        kind: backend::ChangeKind::Insert,
                        original: vec![],
                        values: vec![
                            assignment("id", CellValue::Text("3".into())),
                            assignment("part", CellValue::Text("1".into())),
                        ],
                    }, // duplicate composite PK
                };
                let mut failed_batch = changes.clone();
                failed_batch.changes = vec![insert, later];
                let (session, pending) = begin_apply(
                    &client,
                    &connection,
                    &borrowed,
                    Plan::new(failed_batch).unwrap(),
                )
                .await;
                let error = live_tests::bounded(pending.finish())
                    .await
                    .expect_err("Entire batch must fail.");
                assert!(
                    !error.outcome_unknown
                        && error.transaction_status == Some(backend::TransactionStatus::Idle)
                );
                live_tests::bounded(session.cleanup())
                    .await
                    .expect("Close recovered Apply session.");
                let unchanged = sql(&client, &observer.session_id,
                    format!("SELECT id,part,value,bytes,quantity,computed FROM {quoted} ORDER BY id,part")).await;
                assert!(
                    observed.result_sets == unchanged.result_sets,
                    "Observer must see no partially applied batch."
                );
            }
            // Metadata is revalidated inside Apply, even after successful preview
            // and assessment. Adapter locks/validation remain the sole authority.
            let mut stale_columns = changes.clone();
            stale_columns.changes = vec![RowChange {
                kind: backend::ChangeKind::Insert,
                original: vec![],
                values: vec![
                    assignment("id", CellValue::Text("10".into())),
                    assignment("part", CellValue::Text("1".into())),
                ],
            }];
            let connected = live_tests::bounded(client.connect(connection.clone()))
                .await
                .unwrap();
            let session = FreshSession::adopt(
                client.clone(),
                connected,
                Purpose::Apply,
                connection.policy.clone(),
                Cancellation::default(),
                &borrowed,
            )
            .unwrap();
            let previewed = live_tests::bounded(
                Plan::new(stale_columns)
                    .unwrap()
                    .preview(&session)
                    .unwrap()
                    .finish(),
            )
            .await
            .unwrap();
            let prepared = live_tests::bounded(previewed.begin_assessment().unwrap().finish())
                .await
                .unwrap();
            sql(
                &client,
                &observer.session_id,
                format!("ALTER TABLE {quoted} ADD COLUMN extra integer"),
            )
            .await;
            let error = live_tests::bounded(
                prepared
                    .approval(true)
                    .unwrap()
                    .begin_apply(&prepared)
                    .unwrap()
                    .finish(),
            )
            .await
            .err()
            .unwrap();
            assert!(!error.outcome_unknown && error.category == "conflict");
            live_tests::bounded(session.cleanup()).await.unwrap();
            sql(
                &client,
                &observer.session_id,
                format!("ALTER TABLE {quoted} DROP COLUMN extra"),
            )
            .await;
            let unchanged = sql(
                &client,
                &observer.session_id,
                format!(
                    "SELECT id,part,value,bytes,quantity,computed FROM {quoted} ORDER BY id,part"
                ),
            )
            .await;
            assert!(observed.result_sets == unchanged.result_sets);
            let marker_after_apply =
                sql(&client, &original_sql.session_id, marker_read.into()).await;
            assert!(
                marker_after_apply.transaction_status == backend::TransactionStatus::Transaction
            );
            assert!(
                marker_before.result_sets == marker_after_apply.result_sets,
                "Apply must preserve an unrelated SQL transaction, SET state and private temporary table."
            );
            sql(&client, &original_sql.session_id, "ROLLBACK".into()).await;
            sql(
                &client,
                &observer.session_id,
                format!("DROP TABLE {quoted}"),
            )
            .await;
            for session in borrowed {
                live_tests::bounded(client.disconnect(&session))
                    .await
                    .expect("Close original isolated session.");
            }
            assert!(plan.request() == &changes);
        });
    }
}

async fn begin_apply(
    client: &BackendClient,
    connection: &backend::Connection,
    borrowed: &[String],
    plan: std::sync::Arc<Plan>,
) -> (FreshSession, PendingApply) {
    let connected = live_tests::bounded(client.connect(connection.clone()))
        .await
        .expect("Connect new idle Apply owner.");
    let session = FreshSession::adopt(
        client.clone(),
        connected,
        Purpose::Apply,
        connection.policy.clone(),
        Cancellation::default(),
        borrowed,
    )
    .unwrap();
    let previewed = live_tests::bounded(plan.preview(&session).unwrap().finish())
        .await
        .expect("New session exact preview.");
    let prepared = live_tests::bounded(previewed.begin_assessment().unwrap().finish())
        .await
        .expect("New session exact batch assessment.");
    let pending = prepared
        .approval(true)
        .unwrap()
        .begin_apply(&prepared)
        .expect("Enqueue exact reviewed batch.");
    (session, pending)
}
