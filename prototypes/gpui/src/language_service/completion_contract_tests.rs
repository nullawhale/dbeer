//! Prepared real offline Go contract cases. No database connection is created.
use super::*;
use crate::backend::{ForeignKey, ForeignKeyColumn};
use metadata::Relation;

fn catalog() -> CatalogSnapshot {
    CatalogSnapshot::bounded([
        Relation {
            schema: "public".into(),
            name: "orders".into(),
            kind: "table".into(),
            columns: ["id", "customer_id", "tenant_id", "total", "status"]
                .map(str::to_owned)
                .into(),
            foreign_keys: vec![ForeignKey {
                name: "orders_customer_fk".into(),
                target_schema: "public".into(),
                target_table: "customers".into(),
                columns: vec![
                    ForeignKeyColumn {
                        source: "tenant_id".into(),
                        target: "tenant_id".into(),
                    },
                    ForeignKeyColumn {
                        source: "customer_id".into(),
                        target: "id".into(),
                    },
                ],
            }],
            signatures: vec![],
        },
        Relation {
            schema: "public".into(),
            name: "customers".into(),
            kind: "table".into(),
            columns: ["id", "tenant_id", "name"].map(str::to_owned).into(),
            foreign_keys: vec![],
            signatures: vec![],
        },
    ])
}

#[test]
fn bundled_go_contextual_completion_and_plain_fk_edits_both_dialects() {
    // This runs the same bundled executable/argument as production. The fixture
    // asserts transport/presentation reuse; Go remains the sole SQL authority.
    smol::block_on(async {
        let service = LanguageService::spawn(crate::platform::helper_path()).unwrap();
        service.initialize().await.unwrap();
        for dialect in [Dialect::PostgreSQL, Dialect::MySQL] {
            for (query, required, forbidden) in [
                (
                    "SELECT o.| FROM orders o",
                    vec!["status", "total"],
                    vec!["name"],
                ),
                (
                    "WITH recent(order_id,amount) AS (SELECT id,total FROM orders) SELECT r.| FROM recent r",
                    vec!["order_id", "amount"],
                    vec!["id", "total"],
                ),
                (
                    "SELECT d.| FROM (SELECT id AS order_id,total FROM orders) AS d",
                    vec!["order_id", "total"],
                    vec!["id", "status"],
                ),
                (
                    "SELECT * FROM orders o WHERE EXISTS (SELECT o.| FROM customers c)",
                    vec!["status", "total"],
                    vec!["name"],
                ),
                (
                    "SELECT * FROM orders o, LATERAL (SELECT o.|) d",
                    vec!["status", "total"],
                    vec!["name"],
                ),
                (
                    "SELECT * FROM orders o, (SELECT o.|) d",
                    vec![],
                    vec!["status", "total"],
                ),
                (
                    "SELECT total AS revenue FROM orders ORDER BY |",
                    vec!["revenue", "total"],
                    vec!["name"],
                ),
            ] {
                let offset = query.find('|').unwrap();
                let source = query.replacen('|', "", 1);
                let capture = service
                    .update("scope", source, dialect, ContextKey::default(), catalog())
                    .unwrap();
                let batch = service.completion(&capture, offset).await.unwrap();
                for required in required {
                    assert!(
                        batch.items.iter().any(|item| item.label == required),
                        "Missing required scope candidate."
                    );
                }
                for forbidden in forbidden {
                    assert!(
                        !batch.items.iter().any(|item| item.label == forbidden),
                        "An unrelated scope leaked."
                    );
                }
            }
            for query in [
                "SELECT * FROM orders o JOIN cust|",
                "SELECT * FROM orders o JOIN customers c ON |",
            ] {
                let offset = query.find('|').unwrap();
                let source = query.replacen('|', "", 1);
                let capture = service
                    .update("joins", source, dialect, ContextKey::default(), catalog())
                    .unwrap();
                let batch = service.completion(&capture, offset).await.unwrap();
                let first = batch.items.first().expect("The FK candidate must exist.");
                assert!(first.kind == Some(15), "Go FK rank was changed.");
                assert!(
                    first.replacement.contains(" AND ") && !first.replacement.contains("${"),
                    "FK edit must remain plain composite text."
                );
            }
            let source = "SELECT i FROM orders o JOIN customers c ON true";
            let offset = "SELECT i".len();
            let capture = service
                .update(
                    "ambiguous",
                    source,
                    dialect,
                    ContextKey::default(),
                    catalog(),
                )
                .unwrap();
            let batch = service.completion(&capture, offset).await.unwrap();
            let ambiguous: Vec<_> = batch
                .items
                .iter()
                .filter(|item| item.label == "id")
                .collect();
            assert!(
                ambiguous.len() == 2,
                "Both qualified candidates must survive."
            );
            assert!(
                ambiguous.iter().all(|item| item.replacement.contains('.')),
                "Ambiguous names must retain Go qualification."
            );
            for source in [
                "SELECT 'unterminated",
                "SELECT 1 -- comment",
                "SELECT /* comment",
            ] {
                let capture = service
                    .update(
                        "suppressed",
                        source,
                        dialect,
                        ContextKey::default(),
                        catalog(),
                    )
                    .unwrap();
                assert!(
                    service
                        .completion(&capture, source.len())
                        .await
                        .unwrap()
                        .items
                        .is_empty(),
                    "Literal/comment completion must remain suppressed."
                );
            }
        }
        service.shutdown().await;
    });
}
