//! Prepared isolated-database signature contract. Never executed during coding.
use crate::{
    backend::{self, BackendClient},
    language_service::{
        CatalogSnapshot, ContextKey, Dialect, LanguageService,
        metadata::{CatalogOwner, CatalogPager},
    },
    live_tests::{bounded, client, finish, mysql_connection, postgres_connection},
};

async fn query(client: &BackendClient, session: &str, sql: String) -> backend::QueryOutcome {
    finish(
        client
            .execute(session, sql)
            .expect("Enqueue isolated fixture SQL."),
    )
    .await
    .unwrap_or_else(|_| panic!("Complete isolated fixture SQL."))
}
async fn metadata(client: &BackendClient, session: &str, revision: u64) -> CatalogSnapshot {
    let owner = CatalogOwner {
        profile_id: "signature-fixture-profile".into(),
        settings_revision: 1,
        service_generation: 1,
        catalog_revision: revision,
    };
    let mut pager = CatalogPager::new(owner.clone());
    while let Some(request) = pager.next_request() {
        let page = request.page;
        let result = finish(
            client
                .catalog(session, request)
                .expect("Enqueue explicit metadata page."),
        )
        .await
        .expect("Read explicit metadata page.");
        assert_eq!(result.transaction_status, backend::TransactionStatus::Idle);
        pager
            .accept_page(&owner, page, &result.result_sets)
            .expect("Validate metadata page.");
    }
    pager
        .finish(&owner)
        .expect("Complete original-service metadata.")
}

#[test]
fn connected_go_function_metadata_refreshes_without_database_work_while_typing() {
    if std::env::var("DBEER_GPUI_DISPOSABLE_DATABASES").as_deref() != Ok("1") {
        return;
    }
    for mut connection in [postgres_connection(), mysql_connection()]
        .into_iter()
        .flatten()
    {
        smol::block_on(async move {
            let postgres = connection.engine == "postgresql";
            let dialect = if postgres {
                Dialect::PostgreSQL
            } else {
                Dialect::MySQL
            };
            let client = client().await;
            let sql = bounded(client.connect(connection.clone()))
                .await
                .expect("Connect independent SQL session.");
            let service = bounded(client.connect(connection.clone()))
                .await
                .expect("Connect original catalog service.");
            // Only this disposable fixture owner may create its unique function.
            connection.policy.read_only = false;
            let setup = bounded(client.connect(connection))
                .await
                .expect("Connect fixture setup owner.");
            let name = format!("sig_{}", uuid::Uuid::new_v4().simple());
            let drop_sql = format!(
                "DROP FUNCTION {name}{}",
                if postgres { "(integer,integer)" } else { "" }
            );
            let parameters = if postgres {
                "input_value integer, scale integer DEFAULT 1"
            } else {
                "input_value integer, scale integer"
            };
            let body = if postgres {
                "LANGUAGE sql AS 'SELECT input_value::bigint * scale'"
            } else {
                "DETERMINISTIC NO SQL RETURN input_value * scale"
            };
            query(
                &client,
                &setup.session_id,
                format!("CREATE FUNCTION {name}({parameters}) RETURNS bigint {body}"),
            )
            .await;
            let transaction = query(
                &client,
                &sql.session_id,
                "START TRANSACTION READ ONLY".into(),
            )
            .await;
            assert_eq!(
                transaction.transaction_status,
                backend::TransactionStatus::Transaction
            );
            let language = LanguageService::spawn(crate::platform::helper_path())
                .expect("Start bundled offline language service.");
            language
                .initialize()
                .await
                .expect("Initialize offline language service.");
            // Explicit Connect/Refresh owns the only catalog page calls. No LSP
            // request retains this database client or a SQL session identifier.
            let snapshot = metadata(&client, &service.session_id, 1).await;
            assert!(
                snapshot
                    .relations()
                    .iter()
                    .any(|r| r.name == name && !r.signatures.is_empty())
            );
            let count = client.request_attempts_for_test();
            for arguments in ["", "1", "1, ", "1, 2", "1, "] {
                let source = format!("SELECT {name}({arguments}");
                let caret = source.len();
                let capture = language
                    .update(
                        "connected-signature",
                        source,
                        dialect,
                        ContextKey {
                            profile_id: Some("signature-fixture-profile".into()),
                            settings_revision: 1,
                            catalog_revision: 1,
                        },
                        snapshot.clone(),
                    )
                    .expect("Synchronize captured source.");
                let help = language
                    .signature_help(&capture, caret)
                    .await
                    .expect("Read offline signature.")
                    .expect("Connected function signature.");
                let selected = &help.signatures[help.active_signature];
                assert!(selected.label.to_lowercase().ends_with(" → bigint"));
                if arguments.contains(',') {
                    let range = selected.parameter_ranges
                        [selected.active_parameter.expect("Active second argument.")]
                    .clone();
                    let active = &selected.label[range];
                    assert!(active.starts_with("scale: int"));
                    assert_eq!(active.contains("DEFAULT"), postgres);
                }
            }
            assert_eq!(
                client.request_attempts_for_test(),
                count,
                "Typing submitted database work."
            );
            query(&client, &setup.session_id, drop_sql.clone()).await;
            let text_body = if postgres {
                "LANGUAGE sql AS 'SELECT input_value::text'"
            } else {
                "DETERMINISTIC NO SQL RETURN CAST(input_value AS CHAR)"
            };
            query(
                &client,
                &setup.session_id,
                format!("CREATE FUNCTION {name}({parameters}) RETURNS text {text_body}"),
            )
            .await;
            let refreshed = metadata(&client, &service.session_id, 2).await;
            let count = client.request_attempts_for_test();
            let source = format!("SELECT {name}(1, ");
            let caret = source.len();
            let capture = language
                .update(
                    "connected-signature",
                    source,
                    dialect,
                    ContextKey {
                        profile_id: Some("signature-fixture-profile".into()),
                        settings_revision: 1,
                        catalog_revision: 2,
                    },
                    refreshed,
                )
                .expect("Publish explicit refreshed metadata.");
            let help = language
                .signature_help(&capture, caret)
                .await
                .expect("Read refreshed signature.")
                .expect("Refreshed function exists.");
            assert!(
                help.signatures[help.active_signature]
                    .label
                    .to_lowercase()
                    .ends_with(" → text")
            );
            assert_eq!(
                client.request_attempts_for_test(),
                count,
                "Signature refresh submitted database work."
            );
            let still_open = query(&client, &sql.session_id, "SELECT 1".into()).await;
            assert_eq!(
                still_open.transaction_status,
                backend::TransactionStatus::Transaction
            );
            query(&client, &sql.session_id, "ROLLBACK".into()).await;
            query(&client, &setup.session_id, drop_sql).await;
            language.shutdown().await;
            for session in [&sql.session_id, &service.session_id, &setup.session_id] {
                bounded(client.disconnect(session))
                    .await
                    .expect("Disconnect original owned fixture session.");
            }
        });
    }
}
