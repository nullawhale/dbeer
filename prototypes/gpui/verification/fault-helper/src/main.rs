//! Owned test peer only. No database, credential, profile or production API.
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    fs::{self, OpenOptions},
    io::{self, BufRead, Read, Write},
    path::{Path, PathBuf},
};

const MAX_FRAME: u64 = 16 * 1024 * 1024;
type Result<T> = std::result::Result<T, ()>;

fn send(value: &Value) -> Result<()> {
    let mut output = io::stdout().lock();
    serde_json::to_writer(&mut output, value).map_err(|_| ())?;
    output.write_all(b"\n").map_err(|_| ())?;
    output.flush().map_err(|_| ())
}
fn mode(root: &Path, export: bool) -> Result<String> {
    let mode = fs::read_to_string(root.join("mode")).map_err(|_| ())?;
    if mode.len() > 64
        || !matches!(
            (export, mode.as_str()),
            (
                true,
                "success"
                    | "hold"
                    | "helper-loss"
                    | "publication-failure"
                    | "mutated-target"
                    | "legacy-helper",
            ) | (
                false,
                "" | "preview-error"
                    | "apply-lost-ack"
                    | "apply-hold-success"
                    | "apply-hold-rollback"
                    | "apply-known-rollback",
            )
        )
    {
        return Err(());
    }
    Ok(mode)
}
fn same_query(first: &Value, second: &Value) -> bool {
    ["sessionId", "queryId"].iter().all(|field| {
        first[*field]
            .as_str()
            .is_some_and(|value| !value.is_empty())
            && first[*field] == second[*field]
    })
}
fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.write(true);
    options
}
fn reply(command: &Value) -> Value {
    let mut value = json!({});
    for field in ["requestId", "sessionId", "queryId"] {
        if let Some(item) = command.get(field) {
            value[field] = item.clone();
        }
    }
    value
}
fn update(mut base: Value, extra: Value) -> Value {
    for (key, value) in extra.as_object().unwrap() {
        base[key] = value.clone();
    }
    base
}
fn error(base: Value, category: &str, message: &str, unknown: bool) -> Value {
    update(
        base,
        json!({"type":"error", "category":category, "message":message,
        "connected":true, "transactionStatus":"idle", "outcomeUnknown":unknown}),
    )
}
fn applied(base: Value, command: &Value) -> Value {
    update(
        base,
        json!({"type":"query.result", "columns":[], "rows":[],
        "rowCount": command["changes"]["changes"].as_array().map_or(0, Vec::len),
        "displayedRowCount":0, "commandTag":"APPLY", "durationMs":0,
        "transactionStatus":"idle", "truncated":false}),
    )
}
fn exported(base: Value, command: &Value, selected_mode: &str) -> Value {
    if selected_mode == "publication-failure" {
        update(
            base,
            json!({"type":"error", "category":"export", "message":"SQL completed; publication failed.",
            "connected":true, "outcomeUnknown":false, "transactionStatus":"transaction", "sqlCompleted":true,
            "exportPublication":"notPublished", "resultSets":[], "streamed":true}),
        )
    } else {
        update(
            base,
            json!({"type":"query.result", "columns":[], "rows":[], "resultSets":[], "streamed":true,
            "rowCount":9001, "displayedRowCount":0, "commandTag":"EXPORT", "durationMs":1,
            "transactionStatus":"transaction", "truncated":true, "exportPath":command["export"]["path"],
            "exportFormat":command["export"]["format"], "exportRowCount":9001}),
        )
    }
}

struct Peer {
    root: PathBuf,
    export: bool,
    sessions: HashMap<String, Value>,
    preview_grants: HashSet<String>,
    export_grants: HashMap<String, Value>,
    next_session: usize,
    held: Option<(Value, Value)>,
    pending: Option<(Value, Value)>,
    cancel_before_credit: bool,
    disconnect_refused: bool,
}
impl Peer {
    fn receive(&mut self, command: Value) -> Result<bool> {
        let kind = command["type"].as_str().ok_or(())?;
        for field in ["requestId", "sessionId", "queryId"] {
            if field == "requestId" || command.get(field).is_some() {
                let id = command[field].as_str().ok_or(())?;
                if id.is_empty()
                    || id.len() > 128
                    || !id
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
                {
                    return Err(());
                }
            }
        }
        if !matches!(
            kind,
            "hello"
                | "connect"
                | "changes.preview"
                | "operation.assess"
                | "changes.apply"
                | "execute"
                | "stream.ack"
                | "cancel"
                | "disconnect"
                | "shutdown"
        ) {
            return Err(());
        }
        let mut log = private_options()
            .create(true)
            .append(true)
            .open(
                self.root
                    .join(if self.export { "counts" } else { "commands" }),
            )
            .map_err(|_| ())?;
        if log.metadata().map_err(|_| ())?.len() + kind.len() as u64 + 1 > 64 * 1024 {
            return Err(());
        }
        writeln!(log, "{kind}").map_err(|_| ())?; // Types only, never payloads.
        log.flush().map_err(|_| ())?;
        let base = reply(&command);
        let selected_mode = mode(&self.root, self.export)?;
        let session = command["sessionId"].as_str().unwrap_or("").to_owned();
        let response = match kind {
            "hello" => update(
                base,
                json!({"type":"hello.ack", "protocolVersion":3,
                "capabilities":if self.export && selected_mode != "legacy-helper" {json!(["capturedExportV1"])} else {json!([])}}),
            ),
            "connect" => {
                self.next_session += 1;
                let id = if self.export {
                    "original-sql".to_owned()
                } else {
                    format!("preview-session-{}", self.next_session)
                };
                self.sessions
                    .insert(id.clone(), command["connection"]["policy"].clone());
                update(
                    base,
                    json!({"type":"connect.result", "sessionId":id, "engine":"postgresql", "transactionStatus":"idle",
                    "capabilities":["execute","cancel","transactions","catalog","operationAssessment","executionPolicy"]}),
                )
            }
            "changes.preview" if !self.export => {
                if selected_mode == "preview-error" {
                    error(base, "validation", "Fixture preview rejected.", false)
                } else {
                    send(&update(base.clone(), json!({"type":"query.started"})))?;
                    let changes = command["changes"]["changes"].as_array().ok_or(())?;
                    let rows: Vec<Value> = changes.iter().map(|change| json!([change["kind"], "EXACT GENERATED $1 DEFAULT",
                        "[{\"kind\":\"null\"},{\"kind\":\"text\",\"value\":\"9007199254740993.123456789\"},{\"kind\":\"binary\",\"value\":\"AP9c\"}]"])).collect();
                    let columns: Vec<Value> = ["operation", "sql", "parameters"].iter().enumerate().map(|(i, name)|
                        json!({"index":i,"name":name,"engine":"postgresql","nativeType":"text","typeOid":25})).collect();
                    update(
                        base,
                        json!({"type":"query.result","columns":columns,"rows":rows,"rowCount":rows.len(),
                        "displayedRowCount":rows.len(),"commandTag":"PREVIEW","durationMs":0,"transactionStatus":"idle","truncated":false}),
                    )
                }
            }
            "operation.assess" => {
                let operations = command["operations"].as_array().ok_or(())?;
                if self.export {
                    if operations.len() != 1
                        || operations[0]["type"] != "execute"
                        || operations[0].get("export").is_none()
                    {
                        return Err(());
                    }
                    let source = operations[0]["sql"]
                        .as_str()
                        .filter(|s| !s.is_empty())
                        .ok_or(())?;
                    let end = source.len();
                    self.export_grants.insert(session, operations[0].clone());
                    update(
                        base,
                        json!({"type":"operation.assessment", "assessment":{"decision":"confirm",
                        "policy":{"environment":"production","readOnly":false},"operations":[{"kind":"write",
                        "statements":[{"start":0,"end":end,"kind":"write","reason":"Disposable fixture write."}]}],"authorization":"single-use"}}),
                    )
                } else {
                    if operations.iter().any(|op| op["type"] != "changes.apply") {
                        return Err(());
                    }
                    self.preview_grants.insert(session.clone());
                    let policy = self.sessions.get(&session).ok_or(())?;
                    let assessed: Vec<Value> = operations
                        .iter()
                        .map(|_| json!({"kind":"destructive","statements":[]}))
                        .collect();
                    update(
                        base,
                        json!({"type":"operation.assessment", "assessment":{"decision":"confirm","policy":policy,
                        "operations":assessed,"authorization":format!("fixture-grant-{session}")}}),
                    )
                }
            }
            "changes.apply" if !self.export => {
                if command["authorization"] != format!("fixture-grant-{session}") {
                    return Err(());
                }
                if !self.preview_grants.remove(&session) {
                    error(base, "policy", "Fixture grant revoked.", false)
                } else {
                    send(&update(base.clone(), json!({"type":"query.started"})))?;
                    match selected_mode.as_str() {
                        "apply-lost-ack" => return Ok(false),
                        "apply-hold-success" | "apply-hold-rollback" => {
                            self.held = Some((base, command));
                            return Ok(true);
                        }
                        "apply-known-rollback" => error(
                            base,
                            "conflict",
                            "Fixture full-row conflict. Entire batch rolled back.",
                            false,
                        ),
                        _ => applied(base, &command),
                    }
                }
            }
            "execute" if self.export => {
                if self.pending.is_some() || self.held.is_some() {
                    return Err(());
                }
                let operation =
                    json!({"type":command["type"],"sql":command["sql"],"export":command["export"]});
                if command["authorization"] != "single-use"
                    || self.export_grants.remove(&session).as_ref() != Some(&operation)
                {
                    update(
                        base,
                        json!({"type":"error","category":"policy","message":"Exact operation binding refused.","connected":true,"outcomeUnknown":false,"transactionStatus":"transaction"}),
                    )
                } else {
                    send(&update(base.clone(), json!({"type":"query.started"})))?;
                    if selected_mode == "helper-loss" {
                        return Ok(false);
                    }
                    send(&update(
                        base.clone(),
                        json!({"type":"query.progress","resultIndex":2050,"rowCount":9001,"sequence":1}),
                    ))?;
                    self.pending = Some((base, command));
                    return Ok(true);
                }
            }
            "stream.ack" if self.export => {
                if command["sequence"] != 1 {
                    return Err(());
                }
                if !self
                    .pending
                    .as_ref()
                    .is_some_and(|(pending, _)| same_query(pending, &command))
                {
                    return Err(());
                }
                let (response, pending) = self.pending.take().ok_or(())?;
                if selected_mode == "hold" && !self.cancel_before_credit {
                    self.held = Some((response, pending));
                    return Ok(true);
                }
                self.cancel_before_credit = false;
                exported(response, &pending, &selected_mode)
            }
            "cancel" => {
                self.preview_grants.remove(&session);
                self.export_grants.remove(&session);
                let held = self
                    .held
                    .as_ref()
                    .is_some_and(|(held, _)| same_query(held, &command));
                let pending = self
                    .pending
                    .as_ref()
                    .is_some_and(|(pending, _)| same_query(pending, &command));
                let ack = update(
                    base,
                    json!({"type":"cancel.ack","status":if held || pending {"accepted"} else {"alreadyFinished"}}),
                );
                if held {
                    let (response, pending) = self.held.take().ok_or(())?;
                    send(&ack)?;
                    if self.export {
                        exported(response, &pending, &selected_mode)
                    } else if selected_mode == "apply-hold-rollback" {
                        error(
                            response,
                            "cancelled",
                            "Fixture entire Apply rolled back.",
                            false,
                        )
                    } else {
                        applied(response, &pending)
                    }
                } else if pending {
                    // Stop uses the reserved lane and may overtake stream.ack.
                    // ACK Stop now, but retain the original terminal until its
                    // exact stream credit arrives. No timing assumptions.
                    self.cancel_before_credit = true;
                    ack
                } else {
                    ack
                }
            }
            "disconnect" => {
                let once = self.root.join("disconnect-once");
                if !self.export && !self.disconnect_refused && once.exists() {
                    if fs::read(once).map_err(|_| ())? != b"1" {
                        return Err(());
                    }
                    // The parent factory owns this file's identity. Leave it
                    // for verified parent cleanup instead of unlinking by name.
                    self.disconnect_refused = true;
                    error(base, "validation", "Fixture teardown refused once.", false)
                } else {
                    self.sessions.remove(&session);
                    update(base, json!({"type":"disconnect.ack"}))
                }
            }
            "shutdown" => {
                send(&update(base, json!({"type":"shutdown.ack"})))?;
                return Ok(false);
            }
            _ => return Err(()),
        };
        send(&response)?;
        Ok(true)
    }
}
fn run() -> Result<()> {
    let executable = std::env::current_exe().map_err(|_| ())?;
    let root = executable.parent().ok_or(())?.to_owned();
    let flavor = fs::read_to_string(root.join("fixture-kind")).map_err(|_| ())?;
    if !matches!(flavor.as_str(), "preview" | "run-to-file") {
        return Err(());
    }
    let marker = fs::read_to_string(root.join("disposable.marker")).map_err(|_| ())?;
    if marker != "owned-dbeer-parity-only-v1" {
        return Err(());
    }
    let nonce = root.file_name().and_then(|s| s.to_str()).ok_or(())?;
    if nonce.len() != 36 || !nonce.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
        return Err(());
    }
    let journal = json!({"schemaVersion":1,"disposableMarker":marker,"nonce":nonce,
        "ownedPid":std::process::id(),"fixtureKind":flavor,"state":"started"});
    let file = private_options()
        .create_new(true)
        .write(true)
        .open(root.join("fault-peer-started.json"))
        .map_err(|_| ())?;
    serde_json::to_writer(file, &journal).map_err(|_| ())?;
    let mut peer = Peer {
        root,
        export: flavor == "run-to-file",
        sessions: HashMap::new(),
        preview_grants: HashSet::new(),
        export_grants: HashMap::new(),
        next_session: 0,
        held: None,
        pending: None,
        cancel_before_credit: false,
        disconnect_refused: false,
    };
    let mut input = io::stdin().lock();
    loop {
        let mut frame = Vec::new();
        let count = input
            .by_ref()
            .take(MAX_FRAME + 1)
            .read_until(b'\n', &mut frame)
            .map_err(|_| ())?;
        if count == 0 {
            return Ok(());
        }
        if count as u64 > MAX_FRAME || frame.last() != Some(&b'\n') {
            return Err(());
        }
        let command = serde_json::from_slice(&frame).map_err(|_| ())?;
        if !peer.receive(command)? {
            return Ok(());
        }
    }
}
fn main() {
    if run().is_err() {
        eprintln!("Disposable parity peer refused an invalid command.");
        std::process::exit(2);
    }
}
