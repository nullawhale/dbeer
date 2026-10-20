//! Prepared disposable both-engine full export/session/exact-once acceptance.
use super::*;
async fn sql(
    client: &backend::BackendClient,
    session: &str,
    source: String,
) -> backend::QueryOutcome {
    let assessment = crate::live_tests::bounded(client.assess(session, source.clone()))
        .await
        .unwrap();
    crate::live_tests::finish(
        client
            .execute_authorized(session, source, assessment.authorization)
            .unwrap(),
    )
    .await
    .unwrap()
}
#[test]
fn both_engines_full_counts_independent_observer_temp_set_transaction_and_exact_once_mutations() {
    if std::env::var("DBEER_GPUI_DISPOSABLE_DATABASES").as_deref() != Ok("1") {
        return;
    }
    for mut connection in [
        crate::live_tests::postgres_connection(),
        crate::live_tests::mysql_connection(),
    ]
    .into_iter()
    .flatten()
    {
        smol::block_on(async {
            connection.policy = backend::ExecutionPolicy {
                environment: "development".into(),
                read_only: false,
            };
            let client = crate::live_tests::client().await;
            let session = client.connect(connection.clone()).await.unwrap().session_id;
            let observer = client.connect(connection.clone()).await.unwrap().session_id;
            let postgres = connection.engine == "postgresql";
            let table = format!("gpui_export_{}", uuid::Uuid::new_v4().simple());
            let table = if postgres {
                format!("\"{table}\"")
            } else {
                format!("`{table}`")
            };
            sql(
                &client,
                &observer,
                format!("CREATE TABLE {table} (id integer PRIMARY KEY,value integer)"),
            )
            .await;
            sql(
                &client,
                &session,
                "CREATE TEMPORARY TABLE gpui_export_private(value integer)".into(),
            )
            .await;
            sql(
                &client,
                &session,
                "INSERT INTO gpui_export_private VALUES(37)".into(),
            )
            .await;
            sql(
                &client,
                &session,
                if postgres {
                    "SET application_name='gpui-export-owned'"
                } else {
                    "SET @gpui_export_marker='gpui-export-owned'"
                }
                .into(),
            )
            .await;
            for first in (0..3000).step_by(300) {
                let values = (first..first + 300)
                    .map(|n| format!("({n},0)"))
                    .collect::<Vec<_>>()
                    .join(",");
                sql(
                    &client,
                    &observer,
                    format!("INSERT INTO {table} VALUES {values}"),
                )
                .await;
            }
            sql(&client, &session, "BEGIN".into()).await;
            let mut files = crate::fault_test_support::FileFixture::new().unwrap();
            let path = files.destination("full.json").unwrap();
            let export = backend::ExportRequest {
                path: path.to_str().unwrap().into(),
                format: backend::ExportFormat::Json,
                null_marker: None,
                destination: Some(capture_destination(&path).unwrap()),
            };
            let source = if postgres {
                format!("UPDATE {table} SET value=value+1 RETURNING id,value")
            } else {
                format!("SELECT id,REPEAT('x',4096),value FROM {table} ORDER BY id")
            };
            let assessment = client
                .assess_operations(
                    &session,
                    vec![backend::OperationRequest::Execute {
                        sql: source.clone(),
                        export: Some(export.clone()),
                    }],
                )
                .await
                .unwrap();
            let outcome = crate::live_tests::finish(
                client
                    .run_to_file(&session, source, export, assessment.authorization)
                    .unwrap(),
            )
            .await
            .unwrap();
            assert_eq!(outcome.export.unwrap().row_count, 3000);
            assert!(
                outcome
                    .result_sets
                    .iter()
                    .map(|s| s.rows.len())
                    .sum::<usize>()
                    <= 1000
            );
            assert!(outcome.transaction_status == backend::TransactionStatus::Transaction);
            let document: serde_json::Value =
                serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
            assert_eq!(
                document["resultSets"][0]["rows"].as_array().unwrap().len(),
                3000
            );
            assert_eq!(document["resultSets"][0]["metadata"]["truncated"], false);
            files.capture_output("full.json").unwrap();
            assert!(
                sql(
                    &client,
                    &session,
                    "SELECT value FROM gpui_export_private".into()
                )
                .await
                .result_sets[0]
                    .rows[0][0]
                    .as_deref()
                    == Some("37")
            );
            let setting = if postgres {
                "SELECT current_setting('application_name')"
            } else {
                "SELECT @gpui_export_marker"
            };
            assert!(
                sql(&client, &session, setting.into()).await.result_sets[0].rows[0][0].as_deref()
                    == Some("gpui-export-owned")
            );
            let visible = sql(
                &client,
                &observer,
                format!("SELECT sum(value) FROM {table}"),
            )
            .await;
            assert!(visible.result_sets[0].rows[0][0].as_deref() == Some("0"));
            if !postgres {
                let path = files.destination("mutation.json").unwrap();
                let export = backend::ExportRequest {
                    path: path.to_str().unwrap().into(),
                    format: backend::ExportFormat::Json,
                    null_marker: None,
                    destination: Some(capture_destination(&path).unwrap()),
                };
                let source = format!("UPDATE {table} SET value=value+1");
                let assessment = client
                    .assess_operations(
                        &session,
                        vec![backend::OperationRequest::Execute {
                            sql: source.clone(),
                            export: Some(export.clone()),
                        }],
                    )
                    .await
                    .unwrap();
                let _ = crate::live_tests::finish(
                    client
                        .run_to_file(&session, source, export, assessment.authorization)
                        .unwrap(),
                )
                .await
                .unwrap();
                files.capture_output("mutation.json").unwrap();
            }
            sql(&client, &session, "COMMIT".into()).await;
            assert!(
                sql(
                    &client,
                    &observer,
                    format!("SELECT sum(value) FROM {table}")
                )
                .await
                .result_sets[0]
                    .rows[0][0]
                    .as_deref()
                    == Some("3000")
            );
            sql(&client, &observer, format!("DROP TABLE {table}")).await;
            client.disconnect(&session).await.unwrap();
            client.disconnect(&observer).await.unwrap();
            files.cleanup().unwrap();
        });
    }
}
