//! Portable fault and fixture cases. Execution is deferred to final integration.
use super::*;
use std::process::ChildStdin;

fn fixture() -> Value {
    serde_json::from_str(include_str!("../../../protocol/fixtures/contract-v3.json")).unwrap()
}
fn message(value: Value) -> Message {
    decode_message(&serde_json::to_vec(&value).unwrap()).unwrap()
}
fn columns() -> Value {
    json!([{"index":0,"name":"x","engine":"postgresql","nativeType":"text"}])
}
fn summary(value: &str) -> Value {
    json!({"columns":columns(),"rows":[[value]],"commandTag":"SELECT 1","rowCount":1,"displayedRowCount":1,"truncated":false})
}
fn remap_paths(value: &mut Value) {
    match value {
        Value::Object(fields) => {
            if fields.contains_key("path") {
                fields.insert(
                    "path".into(),
                    json!(
                        std::env::temp_dir()
                            .join("dbeer-contract-fixture.json")
                            .to_string_lossy()
                    ),
                );
            }
            for child in fields.values_mut() {
                remap_paths(child);
            }
        }
        Value::Array(values) => {
            for child in values {
                remap_paths(child);
            }
        }
        _ => {}
    }
}

#[test]
fn every_shared_command_is_expressible_by_the_submission_contract() {
    for line in include_str!("../../../protocol/fixtures/commands.ndjson").lines() {
        let command: WireCommand = serde_json::from_str(line).unwrap();
        assert!(command.valid());
    }
    let mut fixture = fixture();
    remap_paths(&mut fixture);
    for raw in fixture["commands"].as_array().unwrap() {
        let command: WireCommand = serde_json::from_value(raw.clone()).unwrap();
        assert!(command.valid());
        let round_trip: WireCommand =
            serde_json::from_value(serde_json::to_value(&command).unwrap()).unwrap();
        assert!(round_trip.valid());
    }
    for raw in fixture["responses"].as_array().unwrap() {
        message(raw.clone()).validate().unwrap();
    }
}

#[test]
fn typed_changes_preserve_default_null_empty_literal_binary_and_exact_numerics() {
    let raw = fixture()["commands"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["type"] == "changes.apply")
        .unwrap()["changes"]
        .clone();
    let request: ChangesRequest = serde_json::from_value(raw.clone()).unwrap();
    assert!(request.valid());
    assert!(
        matches!(&request.changes[0].original[0],CellValue::Text(v) if v == "9007199254740993")
    );
    assert!(matches!(request.changes[0].original[1], CellValue::Null));
    assert!(matches!(&request.changes[0].values[0].value,CellValue::Text(v) if v.is_empty()));
    assert!(matches!(
        request.changes[1].values[0].value,
        CellValue::Default
    ));
    assert!(matches!(&request.changes[1].values[1].value,CellValue::Text(v) if v == "NULL"));
    assert!(matches!(&request.changes[1].values[2].value,CellValue::Binary(v) if v.is_empty()));
    let mut invalid = request.clone();
    invalid.changes[0].original[1] = CellValue::Default;
    assert!(!invalid.valid());
    let mut invalid = request.clone();
    let duplicate = invalid.changes[0].values[0].clone();
    invalid.changes[0].values.push(duplicate);
    assert!(!invalid.valid());
    let mut invalid = request.clone();
    invalid.columns[1].name = invalid.columns[0].name.clone();
    assert!(!invalid.valid());
    let mut invalid = request;
    invalid.changes[0].original[2] = CellValue::Binary("invalid base64".into());
    assert!(!invalid.valid());
    for raw in [
        json!({"kind":"text","value":1}),
        json!({"kind":"binary"}),
        json!({"kind":"text","value":"x","extra":"private"}),
    ] {
        assert!(serde_json::from_value::<CellValue>(raw).is_err());
    }
}

#[test]
fn request_validation_covers_all_browse_filter_and_operation_fields() {
    let raw = fixture()["commands"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["requestId"] == "catalog-browse")
        .unwrap()["catalog"]
        .clone();
    let request: CatalogRequest = serde_json::from_value(raw).unwrap();
    assert!(request.valid());
    assert_eq!(request.filters.len(), 10);
    let mut invalid = request.clone();
    invalid.page = 1_000_001;
    assert!(!invalid.valid());
    let mut invalid = request.clone();
    invalid.filters[0].value = None;
    assert!(!invalid.valid());
    let mut invalid = request.clone();
    invalid.filters[9].value = Some("".into());
    assert!(!invalid.valid());
    let mut invalid = request;
    invalid.kind = "columns".into();
    assert!(!invalid.valid());
    assert!(
        serde_json::from_value::<OperationRequest>(
            json!({"type":"execute","sql":"SELECT 1","changes":{}})
        )
        .is_err()
    );
}

#[test]
fn metadata_preview_and_export_bind_to_the_exact_originating_request() {
    let fixture = fixture();
    let metadata = fixture["responses"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["requestId"] == "catalog-columns")
        .unwrap();
    let mut response = message(metadata.clone());
    let sets = Accumulator::new().hydrate(&mut response).unwrap();
    let parsed = sets[0].table_metadata().unwrap();
    assert_eq!(parsed[0].primary_key, 1);
    assert!(parsed[0].default.is_none());
    assert!(!parsed[2].editable);
    assert!(!parsed[2].edit_reason.is_empty());
    let mut invalid = sets[0].clone();
    invalid.rows[0][2] = Some("yes".into());
    assert!(invalid.table_metadata().is_err());
    let mut invalid = sets[0].clone();
    invalid.columns[1].name = "name".into();
    assert!(invalid.table_metadata().is_err());
    let changes: ChangesRequest = serde_json::from_value(
        fixture["commands"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["requestId"] == "preview")
            .unwrap()["changes"]
            .clone(),
    )
    .unwrap();
    let mut response = message(
        fixture["responses"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["requestId"] == "preview")
            .unwrap()
            .clone(),
    );
    let sets = Accumulator::new().hydrate(&mut response).unwrap();
    ReplyContext::Preview(changes.clone())
        .validate(&response, &sets)
        .unwrap();
    let parsed = sets[0].preview_statements().unwrap();
    assert_eq!(parsed.len(), 3);
    assert!(matches!(&parsed[0].parameters[0],CellValue::Text(v) if v.is_empty()));
    let mut changed = changes;
    changed.changes.swap(0, 2);
    assert!(
        ReplyContext::Preview(changed)
            .validate(&response, &sets)
            .is_err()
    );
    let mut response = message(
        fixture["responses"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["requestId"] == "export-json")
            .unwrap()
            .clone(),
    );
    let expected = ExportRequest {
        destination: None,
        path: "/fixture/result.json".into(),
        format: ExportFormat::Json,
        null_marker: None,
    };
    ReplyContext::Execute(Some(expected.clone()))
        .validate(&response, &[])
        .unwrap();
    response.export_path = Some("/fixture/other.json".into());
    assert!(
        ReplyContext::Execute(Some(expected))
            .validate(&response, &[])
            .is_err()
    );
    assert!(
        ReplyContext::Execute(None)
            .validate(&response, &[])
            .is_err()
    );
}

#[test]
fn terminal_shapes_reject_malformed_partial_sets_counts_and_unrelated_fields() {
    let mut response = fixture()["responses"][0].clone();
    response["resultSets"][1]["rows"] = json!([["wrong width"]]);
    assert!(message(response).validate().is_err());
    let mut response = fixture()["responses"][0].clone();
    response["resultSets"][0]["displayedRowCount"] = json!(1001);
    assert!(message(response).validate().is_err());
    let mut response = fixture()["responses"][0].clone();
    response["exportPath"] = json!("/fixture/result.json");
    assert!(message(response).validate().is_err());
    let mut response = fixture()["responses"][0].clone();
    response["secret"] = json!("private fixture");
    assert!(message(response).validate().is_err());
    let mut response = fixture()["responses"][2].clone();
    response["transactionStatus"] = Value::Null;
    assert!(message(response).validate().is_err());
}

/// No helper receives fixture commands: its owned stdin is kept open solely to
/// provide a real portable child handle for lifecycle failure/reaping assertions.
struct Harness {
    shared: Shared,
    normal: Receiver<Vec<u8>>,
    control: Receiver<Vec<u8>>,
    _input: ChildStdin,
}
impl Harness {
    fn new() -> Option<Self> {
        let Some(path) = std::env::var_os("DBEER_GPUI_HELPER_PATH") else {
            assert!(
                std::env::var_os("CI").is_none(),
                "CI must supply its native helper"
            );
            return None;
        };
        let mut child = Command::new(path)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("Spawn the owned idle helper");
        let input = child.stdin.take().unwrap();
        let (writer, normal) = async_channel::bounded(MAX_PENDING);
        let (control, control_receiver) = async_channel::bounded(MAX_PENDING * 2);
        let (hello_notify, hello_done) = async_channel::bounded(1);
        let shared = Shared {
            #[cfg(feature = "native-smoke")]
            request_attempts: AtomicU64::new(0),
            state: Mutex::new(State {
                pending: HashMap::new(),
                failure: None,
            }),
            writer,
            control,
            queued_bytes: AtomicU64::new(0),
            child: Arc::new(Mutex::new(child)),
            ready: AtomicBool::new(true),
            product_identity: None,
            hello_started: AtomicBool::new(false),
            captured_export: AtomicBool::new(false),
            hello_notify,
            hello_done,
            hello_error: Arc::new(Mutex::new(None)),
            closing: AtomicBool::new(false),
        };
        Some(Self {
            shared,
            normal,
            control: control_receiver,
            _input: input,
        })
    }
    fn query(&self, query: &str) -> Receiver<Result<QueryEvent>> {
        let (sender, receiver) = async_channel::bounded(2);
        self.shared.enqueue(json!({"type":"execute","sessionId":"session","queryId":query,"sql":"SELECT 1","stream":true}),Pending {terminal:"query.result",session_id:Some("session".into()),query_id:Some(query.into()),engine:None,started:false,context:ReplyContext::Execute(None),authoritative_status:None,control:false,accumulator:Accumulator::new(),sink:Sink::Stream {sender,receiver:receiver.clone()} }).unwrap();
        receiver
    }
    fn request_id(&self, query: &str) -> String {
        self.shared
            .state
            .lock()
            .unwrap()
            .pending
            .iter()
            .find(|(_, p)| p.terminal == "query.result" && p.query_id.as_deref() == Some(query))
            .unwrap()
            .0
            .clone()
    }
    fn receive(&self, raw: Value) -> Result<()> {
        self.shared.receive(message(raw))
    }
    fn start(&self, query: &str) {
        self.receive(json!({"type":"query.started","requestId":self.request_id(query),"sessionId":"session","queryId":query})).unwrap();
    }
    fn cancel(&self, query: &str) -> Result<()> {
        let (sender, _) = async_channel::bounded(1);
        self.shared.enqueue(
            json!({"type":"cancel","sessionId":"session","queryId":query}),
            Pending {
                terminal: "cancel.ack",
                session_id: Some("session".into()),
                query_id: Some(query.into()),
                engine: None,
                started: false,
                context: ReplyContext::General,
                authoritative_status: None,
                control: false,
                accumulator: Accumulator::new(),
                sink: Sink::Unary(sender),
            },
        )
    }
}
impl Drop for Harness {
    fn drop(&mut self) {
        self.shared.closing.store(true, Ordering::Release);
        let mut child = self.shared.child.lock().unwrap();
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[test]
fn product_pairing_gates_every_submission_before_any_connect_frame() {
    let expected = BuildIdentity::parse(include_bytes!(
        "../../../protocol/fixtures/gpui-build-identity-v1/valid-linux.json"
    ))
    .unwrap();
    for variant in [
        "absent",
        "null",
        "version",
        "build",
        "source",
        "target",
        "capability",
        "protocol",
        "matching",
    ] {
        let Some(mut h) = Harness::new() else { return };
        h.shared.product_identity = Some(expected.clone());
        h.shared.ready.store(false, Ordering::Release);
        let pending = |terminal| {
            let (sender, _) = async_channel::bounded(1);
            Pending {
                terminal,
                session_id: None,
                query_id: None,
                engine: Some("postgresql".into()),
                started: false,
                context: ReplyContext::General,
                authoritative_status: None,
                control: false,
                accumulator: Accumulator::new(),
                sink: Sink::Unary(sender),
            }
        };
        let connect = || json!({"type":"connect","connection":{"engine":"postgresql","host":"fixture","port":5432,"database":"fixture","user":"fixture","password":"","sslMode":"disable","policy":{"environment":"development","readOnly":true}}});
        assert!(
            h.shared
                .enqueue(connect(), pending("connect.result"))
                .is_err()
        );
        assert!(h.normal.is_empty());
        let request = Pending {
            engine: None,
            sink: Sink::Handshake {
                sender: h.shared.hello_notify.clone(),
                error: h.shared.hello_error.clone(),
            },
            ..pending("hello.ack")
        };
        h.shared
            .enqueue(json!({"type":"hello","protocolVersion":VERSION}), request)
            .unwrap();
        let sent: Value = serde_json::from_slice(&h.normal.try_recv().unwrap()).unwrap();
        assert_eq!(sent["type"], "hello");
        let mut reply = json!({"type":"hello.ack","requestId":sent["requestId"],"protocolVersion":3,"capabilities":["capturedExportV1"],"buildIdentity":expected});
        match variant {
            "absent" => {
                reply.as_object_mut().unwrap().remove("buildIdentity");
            }
            "null" => reply["buildIdentity"] = Value::Null,
            "version" => reply["buildIdentity"]["version"] = json!("9.9.9"),
            "build" => reply["buildIdentity"]["buildNumber"] = json!("999"),
            "source" => reply["buildIdentity"]["sourceSha256"] = json!("b".repeat(64)),
            "target" => reply["buildIdentity"]["target"] = json!("windows-x86_64-msvc"),
            "capability" => reply["capabilities"] = json!([]),
            "protocol" => reply["protocolVersion"] = json!(2),
            _ => {}
        }
        let result = h.shared.receive(message(reply));
        assert_eq!(result.is_ok(), variant == "matching", "{variant}");
        if let Err(error) = result {
            h.shared.fail(error);
        }
        assert_eq!(
            h.shared.ready.load(Ordering::Acquire),
            variant == "matching"
        );
        assert_eq!(
            h.shared
                .enqueue(connect(), pending("connect.result"))
                .is_ok(),
            variant == "matching"
        );
        assert_eq!(h.normal.len(), usize::from(variant == "matching"));
    }
}

#[test]
fn original_optional_identity_bytes_are_bounded_before_wire_normalization() {
    let identity =
        include_str!("../../../protocol/fixtures/gpui-build-identity-v1/valid-linux.json").trim();
    for extra in [" ".repeat(4096), "\"schemaVersion\":1,".into()] {
        let nested = format!("{{{extra}{}", &identity[1..]);
        let frame = format!(
            "{{\"type\":\"hello.ack\",\"requestId\":\"fixture\",\"protocolVersion\":3,\"buildIdentity\":{nested}}}"
        );
        assert!(decode_message(frame.as_bytes()).is_err());
    }
    for file in [
        include_bytes!("../../../protocol/fixtures/gpui-build-identity-v1/hello-absent.json")
            .as_slice(),
        include_bytes!("../../../protocol/fixtures/gpui-build-identity-v1/hello-null.json")
            .as_slice(),
        include_bytes!("../../../protocol/fixtures/gpui-build-identity-v1/hello-linux.json")
            .as_slice(),
    ] {
        decode_message(file).unwrap().validate().unwrap();
    }
}

#[test]
fn unexpected_product_metadata_preserves_malformed_terminal_recovery() {
    let mut terminal = fixture()["responses"][0].clone();
    terminal["buildIdentity"] = json!({"unknown":"invalid metadata"});
    let response = decode_message(&serde_json::to_vec(&terminal).unwrap()).unwrap();
    assert!(response.invalid_payload);
    assert!(response.validate().is_err());
    assert_eq!(response.transaction_status, Some(TransactionStatus::Idle));
    assert!(
        response
            .result_sets
            .as_ref()
            .is_some_and(|sets| !sets.is_empty())
    );
    assert!(response.build_identity.is_none());
}

#[test]
fn full_regular_queue_reserves_first_stop_and_exact_acks_without_unbounded_progress() {
    let Some(h) = Harness::new() else {
        return;
    };
    let mut receivers = Vec::new();
    for i in 0..MAX_PENDING {
        receivers.push(h.query(&format!("q-{i}")));
    }
    assert_eq!(h.normal.len(), MAX_PENDING);
    h.cancel("q-0").unwrap();
    assert!(h.cancel("q-0").is_err()); // repeated Stop cannot occupy another reserved slot
    h.cancel("q-1").unwrap();
    assert!(h.cancel("never-submitted").is_err());
    assert!(h.shared.state.lock().unwrap().failure.is_none());
    let request = h.request_id("q-0");
    h.start("q-0");
    for sequence in 1..=50 {
        let mut chunk = json!({"type":"query.chunk","requestId":request,"sessionId":"session","queryId":"q-0","sequence":sequence,"resultIndex":0,"rows":[]});
        if sequence == 1 {
            chunk["columns"] = columns();
        }
        h.receive(chunk).unwrap();
        let ack = loop {
            let raw: Value = serde_json::from_slice(&h.control.try_recv().unwrap()).unwrap();
            if raw["type"] == "stream.ack" {
                break raw;
            }
        };
        assert_eq!(ack["sequence"], sequence);
        assert_eq!(ack["queryId"], "q-0");
    }
    assert_eq!(receivers[0].len(), 2);
    h.shared
        .fail(BackendError::transport("The owned helper exited."));
    for receiver in receivers {
        let mut terminal = None;
        while let Ok(event) = receiver.try_recv() {
            if event.is_err() {
                terminal = Some(event);
            }
        }
        assert!(terminal.unwrap().unwrap_err().outcome_unknown);
    }
}

#[test]
fn malformed_terminal_retains_only_completed_prefix_and_authoritative_transaction() {
    let Some(h) = Harness::new() else {
        return;
    };
    let receiver = h.query("partial");
    let request = h.request_id("partial");
    h.start("partial");
    for (index, value) in ["completed", "unfinished"].into_iter().enumerate() {
        h.receive(json!({"type":"query.chunk","requestId":request,"sessionId":"session","queryId":"partial","sequence":index+1,"resultIndex":index,"columns":columns(),"rows":[[value]]})).unwrap();
    }
    let mut good = summary("completed");
    good["rows"] = json!([]);
    let failure=h.receive(json!({"type":"error","requestId":request,"sessionId":"session","queryId":"partial","category":"sql","message":"Synthetic failure.","connected":true,"outcomeUnknown":false,"transactionStatus":"failedTransaction","streamed":true,"resultSets":[good,{"columns":columns(),"rows":[[123]]}]})).unwrap_err();
    h.shared.fail(failure);
    let error = loop {
        if let Err(e) = receiver.try_recv().unwrap() {
            break e;
        }
    };
    assert!(error.outcome_unknown);
    assert_eq!(
        error.transaction_status,
        Some(TransactionStatus::FailedTransaction)
    );
    assert_eq!(error.result_sets.len(), 1);
    assert_eq!(
        error.result_sets[0].rows[0][0].as_deref(),
        Some("completed")
    );
}

#[test]
fn session_identity_failures_never_attribute_another_sessions_transaction() {
    let Some(h) = Harness::new() else {
        return;
    };
    let receiver = h.query("owned");
    let request = h.request_id("owned");
    h.start("owned");
    let error=h.receive(json!({"type":"error","requestId":request,"sessionId":"other-session","queryId":"owned","category":"sql","message":"Synthetic failure.","connected":true,"outcomeUnknown":false,"transactionStatus":"idle"})).unwrap_err();
    h.shared.fail(error);
    let terminal = loop {
        if let Err(e) = receiver.try_recv().unwrap() {
            break e;
        }
    };
    assert!(terminal.outcome_unknown);
    assert!(terminal.transaction_status.is_none());
    assert!(terminal.result_sets.is_empty());
}

#[test]
fn owned_helper_death_keeps_submitted_work_uncertain_before_started() {
    let Some(h) = Harness::new() else {
        return;
    };
    let receiver = h.query("unstarted");
    h.shared.child.lock().unwrap().kill().unwrap();
    h.shared.child.lock().unwrap().wait().unwrap();
    h.shared
        .fail(BackendError::transport("The owned helper exited."));
    assert!(receiver.try_recv().unwrap().unwrap_err().outcome_unknown);
}

#[test]
fn script_assessment_binds_count_and_unicode_classification_coordinates() {
    let operations = vec![
        OperationRequest::Execute {
            sql: "SELECT '😀'".into(),
            export: None,
        },
        OperationRequest::Execute {
            sql: "DELETE FROM fixture".into(),
            export: None,
        },
    ];
    let assessment = |count: usize| {
        message(
            json!({"type":"operation.assessment","requestId":"assessment","sessionId":"session","queryId":"preflight",
        "assessment":{"decision":"confirm","policy":{"environment":"production","readOnly":false},"authorization":"exact-ordered-grant",
        "operations": (0..count).map(|i| json!({"kind":if i == 0 {"read"} else {"destructive"},"statements":[{"start":0,"end":if i == 0 {13} else {19},"kind":"read","reason":"fixture"}]})).collect::<Vec<_>>()}}),
        )
    };
    let context = ReplyContext::Assessment(operations.clone());
    assert!(context.validate(&assessment(2), &[]).is_ok());
    assert!(context.validate(&assessment(1), &[]).is_err());
    // Reversing the original SQL must also rebind the helper's byte ranges;
    // a range through the non-BMP scalar cannot authorize another operation.
    let mut invalid = assessment(2);
    invalid.assessment.as_mut().unwrap().operations[0].statements[0].end = 10;
    assert!(context.validate(&invalid, &[]).is_err());
}

#[test]
fn close_requires_matching_disconnect_ack_and_stop_ack_is_not_a_query_terminal() {
    let Some(h) = Harness::new() else {
        return;
    };
    let query = h.query("close-running");
    h.start("close-running");
    h.cancel("close-running").unwrap();
    let cancel = h
        .shared
        .state
        .lock()
        .unwrap()
        .pending
        .iter()
        .find(|(_, pending)| pending.terminal == "cancel.ack")
        .unwrap()
        .0
        .clone();
    h.receive(json!({"type":"cancel.ack","requestId":cancel,"sessionId":"session","queryId":"close-running","status":"accepted"})).unwrap();
    let query_request = h.request_id("close-running");
    assert!(
        h.shared
            .state
            .lock()
            .unwrap()
            .pending
            .contains_key(&query_request)
    );
    while let Ok(event) = query.try_recv() {
        assert!(!matches!(event, Ok(QueryEvent::Finished(_))));
    }
    let (sender, receiver) = async_channel::bounded(1);
    h.shared
        .enqueue(
            json!({"type":"disconnect","sessionId":"session"}),
            Pending {
                terminal: "disconnect.ack",
                session_id: Some("session".into()),
                query_id: None,
                engine: None,
                started: false,
                context: ReplyContext::General,
                authoritative_status: None,
                control: false,
                accumulator: Accumulator::new(),
                sink: Sink::Unary(sender),
            },
        )
        .unwrap();
    let request = h
        .shared
        .state
        .lock()
        .unwrap()
        .pending
        .iter()
        .find(|(_, pending)| pending.terminal == "disconnect.ack")
        .unwrap()
        .0
        .clone();
    assert!(receiver.try_recv().is_err());
    assert!(
        h.receive(
            json!({"type":"disconnect.ack","requestId":request,"sessionId":"replacement-session"})
        )
        .is_err()
    );
    assert!(receiver.try_recv().is_err());
    h.receive(json!({"type":"disconnect.ack","requestId":request,"sessionId":"session"}))
        .unwrap();
    assert!(receiver.try_recv().unwrap().is_ok());
    h.shared
        .fail(BackendError::transport("Synthetic loss after Stop ACK."));
    let mut unknown = false;
    while let Ok(event) = query.try_recv() {
        if let Err(error) = event {
            unknown = error.outcome_unknown;
        }
    }
    assert!(unknown);
}

#[test]
fn additive_captured_full_export_fixture_preserves_progress_and_sql_publication_distinction() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../../../protocol/fixtures/run-to-file-v1.json"
    ))
    .unwrap();
    let export: ExportRequest = serde_json::from_value(fixture["export"].clone()).unwrap();
    assert!(export.destination.is_some());
    for field in [
        "progress",
        "sqlCompletedPublicationFailed",
        "sqlCompletedPublicationUnknown",
    ] {
        let response = message(fixture[field].clone());
        response.validate().unwrap();
        if field != "progress" {
            assert!(
                response.sql_completed == Some(true) && response.outcome_unknown == Some(false)
            );
        }
    }
    let mut foreign_progress_field = fixture["progress"].clone();
    foreign_progress_field["sqlCompleted"] = json!(true);
    assert!(decode_message(&serde_json::to_vec(&foreign_progress_field).unwrap()).is_err());
    let mut foreign_error_field = fixture["sqlCompletedPublicationFailed"].clone();
    foreign_error_field["sequence"] = json!(1);
    let response = message(foreign_error_field);
    assert!(response.invalid_payload && response.validate().is_err());
    let wrong_hello_type =
        include_bytes!("../../../protocol/fixtures/gpui-build-identity-v1/hello-wrong-type.json");
    assert!(
        BuildIdentity::optional_from_frame(wrong_hello_type, MAX_FRAME_BYTES)
            .unwrap()
            .is_none()
    );
    assert!(decode_message(wrong_hello_type).is_err());
    let mut not_executed = fixture["sqlCompletedPublicationFailed"].clone();
    not_executed.as_object_mut().unwrap().remove("sqlCompleted");
    not_executed["sqlNotExecuted"] = json!(true);
    let response = message(not_executed);
    response.validate().unwrap();
    assert!(response.sql_not_executed == Some(true) && response.sql_completed.is_none());
    let mut invalid = fixture["sqlCompletedPublicationFailed"].clone();
    invalid["outcomeUnknown"] = serde_json::json!(true);
    assert!(message(invalid).validate().is_err());
    let mut legacy = fixture["sqlCompletedPublicationFailed"].clone();
    legacy.as_object_mut().unwrap().remove("sqlCompleted");
    legacy.as_object_mut().unwrap().remove("exportPublication");
    let response = message(legacy);
    response.validate().unwrap();
    assert!(response.sql_completed.is_none());
}
