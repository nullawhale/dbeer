//! Prepared cases only; runtime execution belongs to final integration.
use super::*;
use backend::{ChangeKind, Column, QueryOutcome, ResultSet, TransactionStatus};
use serde_json::json;

pub(super) fn request() -> ChangesRequest {
    serde_json::from_value(json!({"schema":"quoted schema", "table":"table\"😀", "columns":[
        {"name":"id","engine":"postgresql","nativeType":"numeric"},
        {"name":"value","engine":"postgresql","nativeType":"text"},
        {"name":"bytes","engine":"postgresql","nativeType":"bytea"}], "changes":[
        {"kind":"update","original":[{"kind":"text","value":"9007199254740993.123456789"},{"kind":"null"},{"kind":"binary","value":"AP9c"}],
         "values":[{"column":"value","value":{"kind":"text","value":"NULL\r\n😀 ' $1 ?"}}]},
        {"kind":"insert","values":[{"column":"id","value":{"kind":"default"}},{"column":"value","value":{"kind":"text","value":""}},{"column":"bytes","value":{"kind":"binary","value":""}}]},
        {"kind":"delete","original":[{"kind":"text","value":"2"},{"kind":"text","value":"DEFAULT"},{"kind":"binary","value":"AA=="}]}]})).unwrap()
}
fn outcome(plan: &Plan) -> QueryOutcome {
    QueryOutcome {
        result_sets: vec![ResultSet {
            columns: ["operation", "sql", "parameters"]
                .into_iter()
                .enumerate()
                .map(|(index, name)| Column {
                    index,
                    name: name.into(),
                    engine: "postgresql".into(),
                    native_type: "text".into(),
                    type_oid: 25,
                    encoding: None,
                })
                .collect(),
            rows: plan
                .request
                .changes
                .iter()
                .enumerate()
                .map(|(i, c)| {
                    vec![
                        Some(
                            match c.kind {
                                ChangeKind::Update => "update",
                                ChangeKind::Insert => "insert",
                                ChangeKind::Delete => "delete",
                            }
                            .into(),
                        ),
                        Some(format!("EXACT GENERATED {i} $1 ? DEFAULT\r\n")),
                        Some(
                            serde_json::to_string(&vec![
                                CellValue::Null,
                                CellValue::Text("".into()),
                                CellValue::Text("NULL".into()),
                                CellValue::Text("9007199254740993.123456789".into()),
                                CellValue::Binary("AP9c".into()),
                            ])
                            .unwrap(),
                        ),
                    ]
                })
                .collect(),
            ..Default::default()
        }],
        duration_ms: 0.0,
        transaction_status: TransactionStatus::Idle,
        command_tag: "PREVIEW 3".into(),
        row_count: 3,
        truncated: false,
        display_notice: String::new(),
        export: None,
    }
}
fn assessment() -> backend::OperationAssessment {
    backend::OperationAssessment {
        decision: "confirm".into(),
        policy: backend::ExecutionPolicy {
            environment: "production".into(),
            read_only: false,
        },
        operations: vec![backend::AssessedOperation {
            kind: "destructive".into(),
            statements: vec![],
        }],
        authorization: Some("grant-original".into()),
    }
}
#[test]
fn plan_freezes_typed_originals_and_one_exact_ordered_apply_operation() {
    let mut source = request();
    let plan = Plan::new(source.clone()).unwrap();
    source.changes.reverse();
    assert!(plan.request() != &source);
    assert!(
        matches!(&plan.operations()[0],OperationRequest::Apply{changes} if changes == plan.request())
    );
    let OperationRequest::Apply { changes } = &plan.operations()[0] else {
        panic!("Expected the helper changes operation.");
    };
    assert!(
        matches!(&changes.changes[0].original[0],CellValue::Text(v) if v=="9007199254740993.123456789")
    );
    assert!(matches!(
        changes.changes[1].values[0].value,
        CellValue::Default
    ));
    assert!(changes.changes[2].kind == ChangeKind::Delete);
}
#[test]
fn display_preserves_generated_sql_separate_typed_parameters_and_defaults() {
    let plan = Plan::new(request()).unwrap();
    let statements = plan.statements(outcome(&plan)).unwrap();
    let display = display_statements(&plan, &statements, &assessment());
    assert!(display.contains("EXACT GENERATED 0 $1 ? DEFAULT\r\n"));
    assert!(display.contains("9007199254740993.123456789"));
    assert!(display.contains("AP9c"));
    assert!(display.contains("\"kind\": \"default\""));
    assert!(display.contains("Parameter kinds: null, text, text, text, binary"));
    assert!(display.contains("NULL\\r\\n😀 ' $1 ?"));
}
#[test]
fn preview_refuses_changed_order_partial_truncated_or_nonidle_results() {
    let plan = Plan::new(request()).unwrap();
    let mut reply = outcome(&plan);
    reply.result_sets[0].rows.swap(0, 2);
    assert!(plan.statements(reply).is_err());
    let mut reply = outcome(&plan);
    reply.result_sets[0].rows.pop();
    assert!(plan.statements(reply).is_err());
    let mut reply = outcome(&plan);
    reply.truncated = true;
    assert!(plan.statements(reply).is_err());
    let mut reply = outcome(&plan);
    reply.transaction_status = TransactionStatus::Transaction;
    assert!(plan.statements(reply).is_err());
}
#[test]
fn cancellation_is_shared_sticky_and_prevents_future_submission() {
    let cancel = Cancellation::default();
    let queued = cancel.clone();
    assert!(queued.check().is_ok());
    cancel.cancel();
    assert!(queued.cancelled());
    assert!(queued.check().is_err());
}

#[test]
fn readonly_preparation_transport_loss_never_invents_a_mutation_outcome() {
    let mut error = BackendError::transport("Fixture readonly stream lost.");
    error.outcome_unknown = true; // generic query transport context
    assert!(!before_submission(error).outcome_unknown);
}

mod fault_helper {
    use super::*;
    pub(super) struct Fixture {
        peer: crate::fault_test_support::Fixture,
    }
    impl std::ops::Deref for Fixture {
        type Target = crate::fault_test_support::Fixture;
        fn deref(&self) -> &Self::Target {
            &self.peer
        }
    }
    impl std::ops::DerefMut for Fixture {
        fn deref_mut(&mut self) -> &mut Self::Target {
            &mut self.peer
        }
    }
    impl Fixture {
        pub fn new() -> Self {
            Self {
                peer: crate::fault_test_support::Fixture::new("preview", ""),
            }
        }
        pub async fn session(&self, purpose: Purpose, cancel: Cancellation) -> FreshSession {
            let connected = self
                .client
                .connect(backend::Connection {
                    engine: "postgresql".into(),
                    host: "fixture".into(),
                    port: 5432,
                    database: "fixture".into(),
                    user: "fixture".into(),
                    password: String::new(),
                    ssl_mode: "disable".into(),
                    ssl_root_cert: None,
                    policy: assessment().policy,
                })
                .await
                .unwrap();
            FreshSession::adopt(
                self.client.clone(),
                connected,
                purpose,
                assessment().policy,
                cancel,
                &[],
            )
            .unwrap()
        }
    }
    async fn prepared(plan: Arc<Plan>, session: FreshSession) -> Arc<Preparation> {
        let stream = plan.preview(&session).unwrap();
        let previewed = stream.finish().await.unwrap();
        let pending = previewed.begin_assessment().unwrap();
        assert!(!pending.query_id().is_empty());
        pending.finish().await.unwrap()
    }
    #[test]
    fn standalone_cannot_approve_and_every_preview_has_another_idle_session() {
        smol::block_on(async {
            let f = Fixture::new();
            let first = f
                .session(Purpose::Standalone, Cancellation::default())
                .await;
            let second = f
                .session(Purpose::Standalone, Cancellation::default())
                .await;
            assert!(first.id() != second.id());
            let plan = Plan::new(request()).unwrap();
            let p = prepared(plan, first.clone()).await;
            assert!(p.approval(true).is_err());
            first.cleanup().await.unwrap();
            second.cleanup().await.unwrap();
            assert!(!first.valid());
            let log = f.log();
            assert!(log.contains("changes.preview"));
            assert!(log.contains("operation.assess"));
            assert!(!log.contains("changes.apply\n"));
            assert!(!log.contains("execute\n"));
        });
    }
    #[test]
    fn approval_is_exact_preparation_session_and_invalidated_by_stop_or_teardown() {
        smol::block_on(async {
            let f = Fixture::new();
            let cancel = Cancellation::default();
            let session = f.session(Purpose::Apply, cancel.clone()).await;
            let plan = Plan::new(request()).unwrap();
            let first = prepared(plan.clone(), session.clone()).await;
            assert!(first.approval(false).is_err());
            let approval = first.approval(true).unwrap();
            assert!(approval.authorization_for(&first).is_ok());
            let second_session = f.session(Purpose::Apply, Cancellation::default()).await;
            let second = prepared(plan, second_session.clone()).await;
            assert!(approval.authorization_for(&second).is_err());
            cancel.cancel();
            assert!(approval.authorization_for(&first).is_err());
            session.cleanup().await.unwrap();
            second_session.cleanup().await.unwrap();
        });
    }
    #[test]
    fn cancel_before_submit_and_original_client_cleanup_do_not_touch_other_sessions() {
        smol::block_on(async {
            let original = Fixture::new();
            let replacement = Fixture::new();
            let cancel = Cancellation::default();
            let session = original.session(Purpose::Standalone, cancel.clone()).await;
            let borrowed = session.id().to_owned();
            let other = original
                .session(Purpose::Standalone, Cancellation::default())
                .await;
            let plan = Plan::new(request()).unwrap();
            cancel.cancel();
            assert!(plan.preview(&session).is_err());
            session.cleanup().await.unwrap();
            assert!(other.valid());
            assert!(replacement.log().lines().all(|l| l == "hello"));
            assert!(!original.log().contains("changes.preview"));
            let duplicate = backend::ConnectionOutcome {
                session_id: borrowed.clone(),
                engine: "postgresql".into(),
                capabilities: vec![],
                transaction_status: TransactionStatus::Idle,
            };
            assert!(
                FreshSession::adopt(
                    original.client.clone(),
                    duplicate,
                    Purpose::Standalone,
                    assessment().policy,
                    Cancellation::default(),
                    &[borrowed]
                )
                .is_err()
            );
            other.cleanup().await.unwrap();
        });
    }
    #[test]
    fn new_preview_invalidates_previous_grant_even_on_same_session() {
        smol::block_on(async {
            let f = Fixture::new();
            let session = f.session(Purpose::Apply, Cancellation::default()).await;
            let plan = Plan::new(request()).unwrap();
            let first = prepared(plan.clone(), session.clone()).await;
            let grant = first.approval(true).unwrap();
            let next = plan.preview(&session).unwrap();
            assert!(grant.authorization_for(&first).is_err());
            let next = next
                .finish()
                .await
                .unwrap()
                .begin_assessment()
                .unwrap()
                .finish()
                .await
                .unwrap();
            assert!(grant.authorization_for(&next).is_err());
            let latest = next.approval(true).unwrap();
            session.cleanup().await.unwrap();
            assert!(latest.authorization_for(&next).is_err());
        });
    }
    #[test]
    fn stop_after_preview_submission_skips_assessment_and_dml_then_drains() {
        smol::block_on(async {
            let f = Fixture::new();
            let cancel = Cancellation::default();
            let session = f.session(Purpose::Standalone, cancel.clone()).await;
            let plan = Plan::new(request()).unwrap();
            let pending = plan.preview(&session).unwrap();
            let query = pending.query_id().to_owned();
            cancel.cancel();
            session.client().cancel(session.id(), &query).await.unwrap();
            assert!(pending.finish().await.is_err());
            session.cleanup().await.unwrap();
            assert!(!f.log().contains("operation.assess"));
            assert!(!f.log().contains("changes.apply"));
        });
    }
    #[test]
    fn preview_failure_retries_with_unchanged_request_and_cleanup_failure_requires_retry() {
        smol::block_on(async {
            let mut f = Fixture::new();
            let source = request();
            let plan = Plan::new(source.clone()).unwrap();
            f.set_mode("preview-error");
            let first = f
                .session(Purpose::Standalone, Cancellation::default())
                .await;
            assert!(plan.preview(&first).unwrap().finish().await.is_err());
            first.cleanup().await.unwrap();
            f.clear_mode();
            let second = f
                .session(Purpose::Standalone, Cancellation::default())
                .await;
            let result = prepared(plan.clone(), second.clone()).await;
            assert!(!result.display().is_empty());
            f.refuse_disconnect_once();
            assert!(second.cleanup().await.is_err());
            assert!(!second.valid());
            second.cleanup().await.unwrap();
            assert!(plan.request() == &source);
            assert!(f.log().lines().filter(|l| *l == "disconnect").count() == 3);
        });
    }
    #[test]
    fn apply_is_exact_one_shot_and_consumes_every_approval_before_enqueue() {
        smol::block_on(async {
            let f = Fixture::new();
            let session = f.session(Purpose::Apply, Cancellation::default()).await;
            let plan = Plan::new(request()).unwrap();
            let preview = plan.preview(&session).unwrap();
            let preview_id = preview.query_id().to_owned();
            let assessment = preview.finish().await.unwrap().begin_assessment().unwrap();
            let assessment_id = assessment.query_id().to_owned();
            let prepared = assessment.finish().await.unwrap();
            let first = prepared.approval(true).unwrap();
            let duplicate = prepared.approval(true).unwrap();
            let pending = first.begin_apply(&prepared).unwrap();
            assert!(pending.query_id() != preview_id && pending.query_id() != assessment_id);
            assert!(duplicate.begin_apply(&prepared).is_err());
            assert!(prepared.approval(true).is_err());
            let result = pending.finish().await.unwrap();
            assert!(result.transaction_status == TransactionStatus::Idle);
            assert!(result.row_count == plan.request().changes.len() as u64);
            session.cleanup().await.unwrap();
            assert!(f.log().lines().filter(|l| *l == "changes.apply").count() == 1);
            assert!(!f.log().contains("execute"));
        });
    }
    #[test]
    fn sticky_stop_during_review_prevents_enqueue_on_the_original_session() {
        smol::block_on(async {
            let f = Fixture::new();
            let cancel = Cancellation::default();
            let session = f.session(Purpose::Apply, cancel.clone()).await;
            let prepared = prepared(Plan::new(request()).unwrap(), session.clone()).await;
            let approved = prepared.approval(true).unwrap();
            cancel.cancel();
            assert!(approved.begin_apply(&prepared).is_err());
            session.cleanup().await.unwrap();
            assert!(!f.log().contains("changes.apply"));
        });
    }
    #[test]
    fn stop_after_enqueue_drains_authoritative_commit_or_entire_batch_rollback() {
        smol::block_on(async {
            for mode in ["apply-hold-success", "apply-hold-rollback"] {
                let mut f = Fixture::new();
                f.set_mode(mode);
                let cancel = Cancellation::default();
                let session = f.session(Purpose::Apply, cancel.clone()).await;
                let prepared = prepared(Plan::new(request()).unwrap(), session.clone()).await;
                let pending = prepared
                    .approval(true)
                    .unwrap()
                    .begin_apply(&prepared)
                    .unwrap();
                let query = pending.query_id().to_owned();
                assert!(matches!(
                    pending.stream.events.recv().await.unwrap().unwrap(),
                    backend::QueryEvent::Started
                ));
                cancel.cancel();
                session.invalidate();
                // The exact owned query is cancellable immediately after enqueue.
                session.client().cancel(session.id(), &query).await.unwrap();
                let result = pending.finish().await;
                if mode == "apply-hold-success" {
                    assert!(result.unwrap().transaction_status == TransactionStatus::Idle);
                } else {
                    let error = result.err().unwrap();
                    assert!(!error.outcome_unknown && error.category == "cancelled");
                    assert!(error.transaction_status == Some(TransactionStatus::Idle));
                }
                session.cleanup().await.unwrap();
                assert!(f.log().lines().filter(|l| *l == "changes.apply").count() == 1);
            }
        });
    }
    #[test]
    fn lost_terminal_after_submission_remains_unknown_after_disconnect_and_never_retries() {
        smol::block_on(async {
            let mut f = Fixture::new();
            let replacement = Fixture::new();
            f.set_mode("apply-lost-ack");
            let session = f.session(Purpose::Apply, Cancellation::default()).await;
            let prepared = prepared(Plan::new(request()).unwrap(), session.clone()).await;
            let duplicate = prepared.approval(true).unwrap();
            let pending = prepared
                .approval(true)
                .unwrap()
                .begin_apply(&prepared)
                .unwrap();
            let error = pending.finish().await.err().unwrap();
            assert!(error.outcome_unknown);
            let _ = session.cleanup().await;
            assert!(error.outcome_unknown); // Teardown cannot prove rollback.
            assert!(duplicate.begin_apply(&prepared).is_err());
            assert!(f.log().lines().filter(|l| *l == "changes.apply").count() == 1);
            assert!(replacement.log().lines().all(|l| l == "hello"));
        });
    }
    #[test]
    fn known_conflict_preserves_exact_request_and_cleanup_retry_does_not_reapply() {
        smol::block_on(async {
            let mut f = Fixture::new();
            f.set_mode("apply-known-rollback");
            let session = f.session(Purpose::Apply, Cancellation::default()).await;
            let plan = Plan::new(request()).unwrap();
            let prepared = prepared(plan.clone(), session.clone()).await;
            let error = prepared
                .approval(true)
                .unwrap()
                .begin_apply(&prepared)
                .unwrap()
                .finish()
                .await
                .err()
                .unwrap();
            assert!(!error.outcome_unknown && error.category == "conflict");
            f.refuse_disconnect_once();
            assert!(session.cleanup().await.is_err());
            session.cleanup().await.unwrap();
            assert!(plan.request() == &request());
            assert!(f.log().lines().filter(|l| *l == "changes.apply").count() == 1);
        });
    }
}
