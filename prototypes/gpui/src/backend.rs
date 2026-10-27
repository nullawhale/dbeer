//! Version 3 helper transport. Database work and pipe I/O never run on GPUI's UI thread.
//!
//! Each SQL tab owns a helper session. Chunks are validated into a bounded
//! accumulator before granting stream credit; progress may be coalesced, but a
//! terminal result is always retained for the consumer.

use std::{
    collections::HashMap,
    fmt,
    io::{BufRead, BufReader, Write},
    path::Path,
    process::{Child, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

#[path = "backend_contract.rs"]
mod contract;
pub use contract::*;
use contract::{ReplyContext, WireCommand};

use crate::product_identity::BuildIdentity;
use async_channel::{Receiver, Sender};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

const VERSION: u32 = 3;
const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;
const MAX_DISPLAY_BYTES: usize = 8 * 1024 * 1024;
const MAX_DISPLAY_ROWS: usize = 1_000;
const MAX_RESULT_SETS: usize = 1_024;
const MAX_PENDING: usize = 128;
const MAX_OUTBOUND_BYTES: u64 = 32 * 1024 * 1024;
static NEXT_ID: AtomicU64 = AtomicU64::new(1);

fn id() -> String {
    format!("gpui-{}", NEXT_ID.fetch_add(1, Ordering::Relaxed))
}
fn valid_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= 128
}
fn postgresql() -> String {
    "postgresql".to_owned()
}

#[derive(Clone, Deserialize, Serialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutionPolicy {
    pub environment: String,
    pub read_only: bool,
}
impl Default for ExecutionPolicy {
    fn default() -> Self {
        Self {
            environment: "development".into(),
            read_only: true,
        }
    }
}

fn wire_default_policy() -> ExecutionPolicy {
    ExecutionPolicy {
        environment: "unspecified".into(),
        read_only: false,
    }
}

/// Deliberately does not implement Debug: a connection contains a password.
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Connection {
    #[serde(default = "postgresql")]
    pub engine: String,
    pub host: String,
    pub port: u16,
    pub database: String,
    pub user: String,
    pub password: String,
    pub ssl_mode: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ssl_root_cert: Option<String>,
    #[serde(default = "wire_default_policy")]
    pub policy: ExecutionPolicy,
}

#[derive(Clone, Copy, Deserialize, Serialize, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum TransactionStatus {
    Idle,
    Transaction,
    FailedTransaction,
}

#[derive(Clone, Deserialize, Serialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Column {
    pub index: usize,
    pub name: String,
    #[serde(default = "postgresql")]
    pub engine: String,
    #[serde(default)]
    pub native_type: String,
    #[serde(default)]
    pub type_oid: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encoding: Option<String>,
}

#[derive(Clone, Default, Deserialize, Serialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResultSet {
    pub columns: Vec<Column>,
    pub rows: Vec<Vec<Option<String>>>,
    pub command_tag: String,
    pub row_count: u64,
    pub displayed_row_count: usize,
    pub truncated: bool,
    #[serde(default)]
    pub display_notice: String,
}

#[derive(Clone, Debug)]
pub struct ConnectionOutcome {
    pub session_id: String,
    pub engine: String,
    pub capabilities: Vec<String>,
    pub transaction_status: TransactionStatus,
}

#[derive(Clone, Debug)]
pub struct QueryOutcome {
    pub result_sets: Vec<ResultSet>,
    pub duration_ms: f64,
    pub transaction_status: TransactionStatus,
    pub command_tag: String,
    pub row_count: u64,
    pub truncated: bool,
    pub display_notice: String,
    // Consumed by the Run to File presentation in Task 21.
    #[allow(dead_code)]
    pub export: Option<ExportOutcome>,
}

#[derive(Clone, Debug)]
pub enum QueryEvent {
    Started,
    /// Cumulative rows received for this execution. Intermediate progress can be coalesced.
    Chunk {
        result_index: usize,
        row_count: usize,
    },
    ExportProgress {
        result_index: usize,
        row_count: u64,
    },
    Finished(QueryOutcome),
}

pub struct QueryStream {
    pub query_id: String,
    pub events: Receiver<Result<QueryEvent>>,
}
/// Assessment is submitted synchronously so the owner publishes the exact query
/// ID in the same UI turn as enqueueing. No protocol change is involved.
pub struct AssessmentRequest {
    pub query_id: String,
    receiver: Receiver<Result<Message>>,
}
impl AssessmentRequest {
    pub async fn finish(self) -> Result<OperationAssessment> {
        self.receiver
            .recv()
            .await
            .map_err(|_| BackendError::transport("The database helper stopped responding."))??
            .assessment
            .ok_or_else(BackendError::invalid)
    }
}

#[derive(Clone, Debug)]
pub struct CancelOutcome {
    pub status: String,
}

#[derive(Clone, Deserialize, Debug)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StatementAssessment {
    pub start: usize,
    pub end: usize,
    pub kind: String,
    pub reason: String,
}
#[derive(Clone, Deserialize, Debug)]
#[serde(deny_unknown_fields)]
pub struct AssessedOperation {
    pub kind: String,
    pub statements: Vec<StatementAssessment>,
}
#[derive(Clone, Deserialize, Debug)]
#[serde(deny_unknown_fields)]
pub struct OperationAssessment {
    /// Exact helper decision: allow, confirm, or deny.
    pub decision: String,
    pub policy: ExecutionPolicy,
    pub operations: Vec<AssessedOperation>,
    pub authorization: Option<String>,
}
impl OperationAssessment {
    pub fn requires_confirmation(&self) -> bool {
        self.decision == "confirm"
    }
    pub fn rejected(&self) -> bool {
        self.decision == "deny"
    }
}

/// Contains only fixed transport diagnostics or the helper's sanitized error response.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ExportPublication {
    NotPublished,
    Unknown,
}
#[derive(Clone, Debug)]
pub struct BackendError {
    pub message: String,
    pub category: String,
    pub connected: bool,
    pub outcome_unknown: bool,
    pub sql_completed: bool,
    pub sql_not_executed: bool,
    pub export_publication: Option<ExportPublication>,
    pub transaction_status: Option<TransactionStatus>,
    pub sql_state: Option<String>,
    pub error_position: Option<usize>,
    pub result_sets: Vec<ResultSet>,
}
impl BackendError {
    pub(super) fn transport(message: &str) -> Self {
        Self {
            message: message.into(),
            category: "transport".into(),
            connected: false,
            outcome_unknown: false,
            sql_completed: false,
            sql_not_executed: false,
            export_publication: None,
            transaction_status: None,
            sql_state: None,
            error_position: None,
            result_sets: Vec::new(),
        }
    }
    fn invalid() -> Self {
        Self::transport("The database helper sent an invalid protocol message.")
    }
}
impl fmt::Display for BackendError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for BackendError {}
type Result<T> = std::result::Result<T, BackendError>;

fn product_identity_error() -> BackendError {
    BackendError::transport(
        "The DBeer application and helper build identities do not match. Extract a complete matching package.",
    )
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Message {
    #[serde(rename = "type")]
    kind: String,
    request_id: String,
    protocol_version: Option<u32>,
    #[serde(skip)]
    build_identity: Option<BuildIdentity>,
    session_id: Option<String>,
    query_id: Option<String>,
    engine: Option<String>,
    capabilities: Option<Vec<String>>,
    transaction_status: Option<TransactionStatus>,
    duration_ms: Option<f64>,
    columns: Option<Vec<Column>>,
    rows: Option<Vec<Vec<Option<String>>>>,
    command_tag: Option<String>,
    row_count: Option<u64>,
    displayed_row_count: Option<usize>,
    truncated: Option<bool>,
    display_notice: Option<String>,
    result_sets: Option<Vec<ResultSet>>,
    streamed: Option<bool>,
    sequence: Option<usize>,
    result_index: Option<usize>,
    status: Option<String>,
    category: Option<String>,
    message: Option<String>,
    connected: Option<bool>,
    outcome_unknown: Option<bool>,
    sql_completed: Option<bool>,
    sql_not_executed: Option<bool>,
    export_publication: Option<ExportPublication>,
    sql_state: Option<String>,
    error_position: Option<usize>,
    assessment: Option<OperationAssessment>,
    export_path: Option<String>,
    export_format: Option<ExportFormat>,
    export_row_count: Option<u64>,
    #[serde(skip)]
    invalid_payload: bool,
}

struct Accumulator {
    sets: Vec<ResultSet>,
    sequence: usize,
    rows: usize,
    bytes: usize,
    // Only an authoritative terminal can identify the completed prefix.
    completed: Vec<ResultSet>,
}
impl Accumulator {
    fn new() -> Self {
        Self {
            sets: Vec::new(),
            sequence: 0,
            rows: 0,
            bytes: 0,
            completed: Vec::new(),
        }
    }
    fn append(&mut self, message: &mut Message) -> Result<()> {
        let sequence = message.sequence.ok_or_else(BackendError::invalid)?;
        let index = message.result_index.ok_or_else(BackendError::invalid)?;
        if sequence != self.sequence + 1 || index >= MAX_RESULT_SETS {
            return Err(BackendError::invalid());
        }
        if let Some(columns) = message.columns.take() {
            if index != self.sets.len() || !valid_columns(&columns) {
                return Err(BackendError::invalid());
            }
            self.bytes += encoded_len(&columns)? + 1_024;
            self.sets.push(ResultSet {
                columns,
                ..ResultSet::default()
            });
        }
        if self.sets.is_empty() || index != self.sets.len() - 1 {
            return Err(BackendError::invalid());
        }
        let rows = message.rows.take().ok_or_else(BackendError::invalid)?;
        if !valid_rows(&self.sets[index].columns, &rows) {
            return Err(BackendError::invalid());
        }
        self.rows += rows.len();
        for row in &rows {
            self.bytes += encoded_len(row)? + 1;
        }
        if self.rows > MAX_DISPLAY_ROWS || self.bytes > MAX_DISPLAY_BYTES {
            return Err(BackendError::invalid());
        }
        self.sets[index].rows.extend(rows);
        self.sequence = sequence;
        Ok(())
    }
    fn capture_completed(&mut self, message: &Message) {
        let legacy;
        let summaries = if let Some(summaries) = message.result_sets.as_ref() {
            summaries
        } else if message.kind == "query.result" && message.streamed != Some(true) {
            let (
                Some(columns),
                Some(rows),
                Some(command_tag),
                Some(row_count),
                Some(displayed_row_count),
                Some(truncated),
            ) = (
                &message.columns,
                &message.rows,
                &message.command_tag,
                message.row_count,
                message.displayed_row_count,
                message.truncated,
            )
            else {
                return;
            };
            legacy = vec![ResultSet {
                columns: columns.clone(),
                rows: rows.clone(),
                command_tag: command_tag.clone(),
                row_count,
                displayed_row_count,
                truncated,
                display_notice: message.display_notice.clone().unwrap_or_default(),
            }];
            &legacy
        } else {
            return;
        };
        let mut completed = Vec::new();
        for (index, summary) in summaries.iter().take(MAX_RESULT_SETS).enumerate() {
            if !valid_set(summary, message.streamed == Some(true)) {
                break;
            }
            let mut set = summary.clone();
            if message.streamed == Some(true) {
                let Some(buffered) = self.sets.get(index) else {
                    break;
                };
                if set.columns != buffered.columns || set.displayed_row_count != buffered.rows.len()
                {
                    break;
                }
                set.rows = buffered.rows.clone();
            } else if self.sequence != 0 {
                break;
            }
            completed.push(set);
            if validate_aggregate(&completed).is_err() {
                completed.pop();
                break;
            }
        }
        self.completed = completed;
    }
    fn hydrate(&mut self, message: &mut Message) -> Result<Vec<ResultSet>> {
        let streamed = message.streamed == Some(true);
        if streamed {
            let mut sets = message
                .result_sets
                .take()
                .ok_or_else(BackendError::invalid)?;
            if sets.len() > self.sets.len()
                || (message.kind != "error" && sets.len() != self.sets.len())
            {
                return Err(BackendError::invalid());
            }
            for (index, set) in sets.iter().enumerate() {
                if !valid_set(set, true)
                    || set.columns != self.sets[index].columns
                    || set.displayed_row_count != self.sets[index].rows.len()
                {
                    return Err(BackendError::invalid());
                }
            }
            for (set, buffered) in sets.iter_mut().zip(&self.sets) {
                set.rows = buffered.rows.clone();
            }
            validate_aggregate(&sets)?;
            Ok(sets)
        } else {
            if self.sequence != 0 {
                return Err(BackendError::invalid());
            }
            let sets = if let Some(sets) = message.result_sets.take() {
                sets
            } else if message.kind == "query.result" {
                vec![message.take_result_set()?]
            } else {
                Vec::new()
            };
            if !sets.iter().all(|set| valid_set(set, false)) {
                return Err(BackendError::invalid());
            }
            validate_aggregate(&sets)?;
            Ok(sets)
        }
    }
}

fn encoded_len(value: &impl Serialize) -> Result<usize> {
    serde_json::to_vec(value)
        .map(|value| value.len())
        .map_err(|_| BackendError::invalid())
}
fn valid_columns(columns: &[Column]) -> bool {
    columns.iter().enumerate().all(|(index, column)| {
        column.index == index
            && matches!(column.engine.as_str(), "postgresql" | "mysql")
            && matches!(column.encoding.as_deref(), None | Some("base64"))
    })
}
fn valid_rows(columns: &[Column], rows: &[Vec<Option<String>>]) -> bool {
    rows.iter().all(|row| {
        row.len() == columns.len()
            && row.iter().zip(columns).all(|(cell, column)| {
                column.encoding.as_deref() != Some("base64")
                    || cell.as_deref().is_none_or(valid_base64)
            })
    })
}
fn valid_base64(value: &str) -> bool {
    let bytes = value.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return false;
    }
    let padding = bytes.iter().rev().take_while(|byte| **byte == b'=').count();
    if padding > 2 {
        return false;
    }
    let body = &bytes[..bytes.len() - padding];
    if !body
        .iter()
        .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'+' || *byte == b'/')
    {
        return false;
    }
    // Reject noncanonical trailing bits, matching the Go encoder's representation.
    let sextet = |byte: u8| match byte {
        b'A'..=b'Z' => byte - b'A',
        b'a'..=b'z' => byte - b'a' + 26,
        b'0'..=b'9' => byte - b'0' + 52,
        b'+' => 62,
        _ => 63,
    };
    padding == 0
        || body
            .last()
            .is_some_and(|last| sextet(*last) & if padding == 2 { 15 } else { 3 } == 0)
}
fn valid_set(set: &ResultSet, streamed: bool) -> bool {
    set.row_count <= i64::MAX as u64
        && set.displayed_row_count <= MAX_DISPLAY_ROWS
        && (set.columns.is_empty() || set.row_count >= set.displayed_row_count as u64)
        && valid_columns(&set.columns)
        && valid_rows(&set.columns, &set.rows)
        && if streamed {
            set.rows.is_empty()
        } else {
            set.displayed_row_count == set.rows.len()
        }
}
fn validate_aggregate(sets: &[ResultSet]) -> Result<()> {
    if sets.len() > MAX_RESULT_SETS
        || sets
            .iter()
            .try_fold(0usize, |n, set| n.checked_add(set.displayed_row_count))
            .is_none_or(|n| n > MAX_DISPLAY_ROWS)
        || encoded_len(&sets)? > MAX_DISPLAY_BYTES
    {
        return Err(BackendError::invalid());
    }
    Ok(())
}
impl Message {
    fn export_outcome(&self) -> Result<Option<ExportOutcome>> {
        match (&self.export_path, self.export_format, self.export_row_count) {
            (None, None, None) => Ok(None),
            (Some(path), Some(format), Some(row_count))
                if !path.is_empty()
                    && path.len() <= 4096
                    && !path.contains('\0')
                    && row_count <= i64::MAX as u64 =>
            {
                Ok(Some(ExportOutcome {
                    path: path.clone(),
                    format,
                    row_count,
                }))
            }
            _ => Err(BackendError::invalid()),
        }
    }
    fn take_result_set(&mut self) -> Result<ResultSet> {
        Ok(ResultSet {
            columns: self.columns.take().ok_or_else(BackendError::invalid)?,
            rows: self.rows.take().ok_or_else(BackendError::invalid)?,
            command_tag: self.command_tag.clone().ok_or_else(BackendError::invalid)?,
            row_count: self.row_count.ok_or_else(BackendError::invalid)?,
            displayed_row_count: self.displayed_row_count.ok_or_else(BackendError::invalid)?,
            truncated: self.truncated.ok_or_else(BackendError::invalid)?,
            display_notice: self.display_notice.clone().unwrap_or_default(),
        })
    }
    fn valid_result_sets(&self) -> bool {
        self.result_sets.as_ref().is_none_or(|sets| {
            sets.iter()
                .all(|s| valid_set(s, self.streamed == Some(true)))
                && validate_aggregate(sets).is_ok()
        })
    }
    fn validate(&self) -> Result<()> {
        if self.invalid_payload
            || self.sql_not_executed == Some(true)
                && (self.sql_completed == Some(true)
                    || self.outcome_unknown == Some(true)
                    || self.kind != "error")
            || self.sql_completed == Some(true)
                && (self.kind != "error"
                    || self.outcome_unknown == Some(true)
                    || !matches!(
                        self.export_publication,
                        Some(ExportPublication::NotPublished | ExportPublication::Unknown)
                    ))
            || self.export_publication.is_some()
                && self.sql_completed != Some(true)
                && self.sql_not_executed != Some(true)
        {
            return Err(BackendError::invalid());
        }
        if !valid_id(&self.request_id)
            || self.session_id.as_deref().is_some_and(|id| !valid_id(id))
            || self.query_id.as_deref().is_some_and(|id| !valid_id(id))
        {
            return Err(BackendError::invalid());
        }
        let session_query = self.session_id.is_some() && self.query_id.is_some();
        let valid = match self.kind.as_str() {
            "hello.ack" => {
                self.protocol_version == Some(VERSION)
                    && self.capabilities.as_ref().is_none_or(|values| {
                        let mut names = std::collections::HashSet::new();
                        values.len() <= 128 && values.iter().all(|v| valid_id(v) && names.insert(v))
                    })
            }
            "connect.result" => {
                self.session_id.is_some()
                    && self.transaction_status.is_some()
                    && self.capabilities.as_ref().is_some_and(|values| {
                        let mut names = std::collections::HashSet::new();
                        values.len() <= 128 && values.iter().all(|v| valid_id(v) && names.insert(v))
                    })
                    && self
                        .engine
                        .as_deref()
                        .is_some_and(|engine| matches!(engine, "postgresql" | "mysql"))
            }
            "query.started" => session_query,
            "query.progress" => {
                session_query
                    && self.sequence.is_some_and(|v| v > 0)
                    && self.result_index.is_some()
                    && self.row_count.is_some_and(|v| v <= i64::MAX as u64)
            }
            "query.chunk" => {
                session_query
                    && self.sequence.is_some_and(|value| value > 0)
                    && self
                        .result_index
                        .is_some_and(|index| index < MAX_RESULT_SETS)
                    && self.rows.is_some()
                    && self.columns.as_ref().is_none_or(|c| valid_columns(c))
            }
            "query.result" => {
                session_query
                    && self.transaction_status.is_some()
                    && self
                        .duration_ms
                        .is_some_and(|value| value.is_finite() && value >= 0.0)
                    && self
                        .columns
                        .as_ref()
                        .is_some_and(|columns| valid_columns(columns))
                    && self.rows.as_ref().is_some_and(|rows| {
                        valid_rows(self.columns.as_deref().unwrap_or_default(), rows)
                    })
                    && self.command_tag.is_some()
                    && self.row_count.is_some_and(|v| v <= i64::MAX as u64)
                    && self
                        .displayed_row_count
                        .is_some_and(|v| v <= MAX_DISPLAY_ROWS)
                    && self.export_outcome().is_ok()
                    && self.valid_result_sets()
                    && (self.streamed != Some(true) || self.result_sets.is_some())
                    && (self.columns.as_ref().is_some_and(Vec::is_empty)
                        || self
                            .row_count
                            .zip(self.displayed_row_count)
                            .is_some_and(|(total, displayed)| total >= displayed as u64))
                    && self.truncated.is_some()
                    && if self.streamed == Some(true) {
                        self.rows.as_ref().is_some_and(Vec::is_empty)
                    } else {
                        self.rows.as_ref().map(Vec::len) == self.displayed_row_count
                    }
            }
            "cancel.ack" => {
                session_query
                    && matches!(self.status.as_deref(), Some("accepted" | "alreadyFinished"))
            }
            "disconnect.ack" => self.session_id.is_some(),
            "shutdown.ack" => true,
            "operation.assessment" => {
                session_query && self.assessment.as_ref().is_some_and(valid_assessment)
            }
            "error" => {
                self.category.is_some()
                    && self.message.is_some()
                    && self.connected.is_some()
                    && self.outcome_unknown.is_some()
                    && self.error_position.is_none_or(|value| value > 0)
                    && self.sql_state.as_ref().is_none_or(|s| {
                        s.len() == 5
                            && s.bytes()
                                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
                    })
                    && (self.connected != Some(true)
                        || self.session_id.is_some() && self.transaction_status.is_some())
                    && (self.streamed != Some(true) || session_query && self.result_sets.is_some())
                    && (self.result_sets.is_none() || session_query)
                    && self.valid_result_sets()
            }
            _ => false,
        };
        if valid {
            Ok(())
        } else {
            Err(BackendError::invalid())
        }
    }
}
fn valid_assessment(value: &OperationAssessment) -> bool {
    matches!(value.decision.as_str(), "allow" | "confirm" | "deny")
        && matches!(
            value.policy.environment.as_str(),
            "unspecified" | "development" | "staging" | "production"
        )
        && !value.operations.is_empty()
        && value.operations.len() <= MAX_RESULT_SETS
        && value.operations.iter().all(|operation| {
            matches!(
                operation.kind.as_str(),
                "read" | "write" | "destructive" | "unknown"
            ) && operation.statements.iter().all(|statement| {
                statement.end > statement.start
                    && matches!(
                        statement.kind.as_str(),
                        "read" | "write" | "destructive" | "unknown"
                    )
            })
        })
        && if value.decision == "deny" {
            value.authorization.is_none()
        } else {
            value.authorization.as_deref().is_some_and(valid_id)
        }
}

struct Pending {
    terminal: &'static str,
    session_id: Option<String>,
    query_id: Option<String>,
    engine: Option<String>,
    started: bool,
    context: ReplyContext,
    authoritative_status: Option<TransactionStatus>,
    control: bool,
    accumulator: Accumulator,
    sink: Sink,
}
enum Sink {
    Handshake {
        sender: Sender<()>,
        error: Arc<Mutex<Option<BackendError>>>,
    },
    Unary(Sender<Result<Message>>),
    Stream {
        sender: Sender<Result<QueryEvent>>,
        receiver: Receiver<Result<QueryEvent>>,
    },
}
impl Sink {
    fn progress(&self, event: QueryEvent) {
        if let Self::Stream { sender, .. } = self {
            let _ = sender.try_send(Ok(event));
        }
    }
    fn finish(self, result: Result<Message>, outcome: Option<QueryOutcome>) {
        match self {
            Self::Handshake { sender, error } => {
                if let Err(failure) = result {
                    *error.lock().unwrap_or_else(|poison| poison.into_inner()) = Some(failure);
                }
                sender.close();
            }
            Self::Unary(sender) => {
                let _ = sender.try_send(result);
            }
            Self::Stream { sender, receiver } => {
                let terminal = match result {
                    Ok(_) => outcome
                        .map(QueryEvent::Finished)
                        .ok_or_else(BackendError::invalid),
                    Err(error) => Err(error),
                };
                // A retained receiver allows evicting stale progress, never a terminal.
                while sender.is_full() {
                    let _ = receiver.try_recv();
                }
                let _ = sender.try_send(terminal);
            }
        }
    }
}
struct State {
    pending: HashMap<String, Pending>,
    failure: Option<BackendError>,
}
struct Shared {
    #[cfg(all(test, feature = "native-smoke"))]
    request_attempts: AtomicU64,
    state: Mutex<State>,
    writer: Sender<Vec<u8>>,
    control: Sender<Vec<u8>>,
    queued_bytes: AtomicU64,
    child: Arc<Mutex<Child>>,
    ready: AtomicBool,
    product_identity: Option<BuildIdentity>,
    hello_started: AtomicBool,
    captured_export: AtomicBool,
    hello_notify: Sender<()>,
    hello_done: Receiver<()>,
    hello_error: Arc<Mutex<Option<BackendError>>>,
    closing: AtomicBool,
}
impl Shared {
    fn fail(&self, error: BackendError) {
        let pending = {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            if state.failure.is_some() {
                return;
            }
            state.failure = Some(error.clone());
            std::mem::take(&mut state.pending)
        };
        self.ready.store(false, Ordering::Release);
        self.writer.close();
        self.control.close();
        for (_, request) in pending {
            let mut contextual = error.clone();
            contextual.outcome_unknown = request.terminal == "query.result";
            contextual.transaction_status = request.authoritative_status;
            contextual.result_sets = request.accumulator.completed;
            request.sink.finish(Err(contextual), None);
        }
        if !self.closing.load(Ordering::Acquire) {
            let _ = self
                .child
                .lock()
                .unwrap_or_else(|poison| poison.into_inner())
                .kill();
            let child = self.child.clone();
            let _ = thread::Builder::new()
                .name("dbeer-helper-failure-reaper".into())
                .spawn(move || {
                    let _ = reap_owned_child(child, Duration::from_millis(250));
                });
        }
    }
    fn reserve_queued_bytes(&self, bytes: u64) -> bool {
        let mut current = self.queued_bytes.load(Ordering::Acquire);
        loop {
            let Some(next) = current
                .checked_add(bytes)
                .filter(|n| *n <= MAX_OUTBOUND_BYTES)
            else {
                return false;
            };
            match self.queued_bytes.compare_exchange_weak(
                current,
                next,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return true,
                Err(actual) => current = actual,
            }
        }
    }
    fn enqueue(&self, mut command: Value, mut request: Pending) -> Result<()> {
        #[cfg(all(test, feature = "native-smoke"))]
        self.request_attempts.fetch_add(1, Ordering::Relaxed);
        let request_id = id();
        command["requestId"] = Value::String(request_id.clone());
        let typed: WireCommand =
            serde_json::from_value(command.clone()).map_err(|_| BackendError::invalid())?;
        if !typed.valid() {
            return Err(BackendError::invalid());
        }
        if self.product_identity.is_some()
            && !self.ready.load(Ordering::Acquire)
            && !matches!(command["type"].as_str(), Some("hello" | "shutdown"))
        {
            return Err(product_identity_error());
        }
        let mut frame = serde_json::to_vec(&command)
            .map_err(|_| BackendError::transport("Cannot encode a database helper command."))?;
        if frame.len() > MAX_FRAME_BYTES {
            return Err(BackendError::transport(
                "The database command exceeds the 16 MiB protocol limit.",
            ));
        }
        frame.push(b'\n');
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if let Some(error) = state.failure.as_ref() {
            return Err(error.clone());
        }
        let cancel = request.terminal == "cancel.ack";
        if cancel
            && state.pending.values().any(|r| {
                r.terminal == "cancel.ack"
                    && r.session_id == request.session_id
                    && r.query_id == request.query_id
            })
        {
            return Err(BackendError::transport(
                "Cancellation is already in progress.",
            ));
        }
        // Only the first Stop of a currently submitted execution uses the
        // reserved lane. Repeated/finished-query requests cannot fill it.
        let control = cancel
            && state.pending.values().any(|r| {
                r.terminal == "query.result"
                    && r.session_id == request.session_id
                    && r.query_id == request.query_id
            });
        request.control = control;
        let same_lane = state
            .pending
            .values()
            .filter(|r| r.control == control)
            .count();
        if same_lane >= MAX_PENDING {
            return Err(BackendError::transport(
                "Too many database operations are in progress.",
            ));
        }
        let frame_bytes = frame.len() as u64;
        if !control && !self.reserve_queued_bytes(frame_bytes) {
            return Err(BackendError::transport(
                "The database helper command queue is full.",
            ));
        }
        state.pending.insert(request_id.clone(), request);
        let lane = if control { &self.control } else { &self.writer };
        if let Err(failure) = lane.try_send(frame) {
            if !control {
                self.queued_bytes.fetch_sub(frame_bytes, Ordering::AcqRel);
            }
            state.pending.remove(&request_id);
            let closed = failure.is_closed();
            drop(state);
            let error = BackendError::transport(if closed {
                "Cannot send a command to the database helper."
            } else {
                "The database helper command queue is full."
            });
            // Saturation refuses only this not-submitted request. It must not
            // poison unrelated sessions or invent an uncertain outcome.
            if closed {
                self.fail(error.clone());
            }
            return Err(error);
        }
        Ok(())
    }
    fn receive(&self, mut message: Message) -> Result<()> {
        {
            let mut state = self.state.lock().unwrap_or_else(|p| p.into_inner());
            if let Some(request) = state.pending.get_mut(&message.request_id)
                && request.session_id == message.session_id
                && request.query_id == message.query_id
                && request.terminal == "query.result"
                && matches!(message.kind.as_str(), "query.result" | "error")
            {
                request.authoritative_status = message.transaction_status;
                request.accumulator.capture_completed(&message);
            }
        }
        message.validate()?;
        if self.closing.load(Ordering::Acquire) && message.kind == "shutdown.ack" {
            return Ok(());
        }
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if state.failure.is_some() {
            return Ok(());
        }
        // Validate the immutable compiled product before removing its waiter or
        // publishing readiness. Every operation uses this same ready gate.
        if message.kind == "hello.ack"
            && let Some(identity) = &self.product_identity
        {
            identity
                .require_matching_helper(
                    message.build_identity.as_ref(),
                    message.protocol_version.unwrap_or_default(),
                    message.capabilities.as_deref().unwrap_or_default(),
                )
                .map_err(|_| product_identity_error())?;
        }
        let request = state
            .pending
            .get_mut(&message.request_id)
            .ok_or_else(BackendError::invalid)?;
        if (message.kind != "connect.result" && request.session_id != message.session_id)
            || request.query_id != message.query_id
            || (message.kind == "connect.result" && request.engine != message.engine)
        {
            return Err(BackendError::invalid());
        }
        if message.kind == "query.started" && request.terminal == "query.result" && !request.started
        {
            request.started = true;
            request.sink.progress(QueryEvent::Started);
            return Ok(());
        }
        if message.kind == "query.progress" {
            if !request.started || !matches!(&request.context, ReplyContext::Execute(Some(_))) {
                return Err(BackendError::invalid());
            }
            let sequence = message.sequence.ok_or_else(BackendError::invalid)?;
            if sequence != request.accumulator.sequence + 1 {
                return Err(BackendError::invalid());
            }
            request.accumulator.sequence = sequence;
            let ack = json!({"type":"stream.ack","requestId":id(),"sessionId":message.session_id,"queryId":message.query_id,"sequence":sequence});
            let mut frame = serde_json::to_vec(&ack).map_err(|_| BackendError::invalid())?;
            frame.push(b'\n');
            self.control
                .try_send(frame)
                .map_err(|_| BackendError::transport("Cannot acknowledge full export progress."))?;
            request.sink.progress(QueryEvent::ExportProgress {
                result_index: message.result_index.unwrap_or_default(),
                row_count: message.row_count.unwrap_or_default(),
            });
            return Ok(());
        }
        if message.kind == "query.chunk" {
            if request.terminal != "query.result" || !request.started {
                return Err(BackendError::invalid());
            }
            request.accumulator.append(&mut message)?;
            let ack = json!({"type":"stream.ack","requestId":id(),"sessionId":message.session_id,"queryId":message.query_id,"sequence":message.sequence});
            let mut frame = serde_json::to_vec(&ack).map_err(|_| BackendError::invalid())?;
            frame.push(b'\n');
            self.control
                .try_send(frame)
                .map_err(|_| BackendError::transport("Cannot acknowledge database results."))?;
            request.sink.progress(QueryEvent::Chunk {
                result_index: message.result_index.unwrap_or_default(),
                row_count: request.accumulator.rows,
            });
            return Ok(());
        }
        if message.kind != request.terminal && message.kind != "error" {
            return Err(BackendError::invalid());
        }
        if message.kind == "query.result" && !request.started {
            return Err(BackendError::invalid());
        }
        let sets = if request.terminal == "query.result" {
            if message.streamed == Some(true) && !request.context.streamed() {
                return Err(BackendError::invalid());
            }
            let sets = request.accumulator.hydrate(&mut message)?;
            request.context.validate(&message, &sets)?;
            sets
        } else {
            Vec::new()
        };
        if request.terminal != "query.result" {
            request.context.validate(&message, &[])?;
        }
        let mut sets = sets;
        let outcome = if message.kind == "query.result" {
            Some(QueryOutcome {
                result_sets: std::mem::take(&mut sets),
                duration_ms: message.duration_ms.ok_or_else(BackendError::invalid)?,
                transaction_status: message
                    .transaction_status
                    .ok_or_else(BackendError::invalid)?,
                command_tag: message.command_tag.clone().unwrap_or_default(),
                row_count: message.row_count.unwrap_or_default(),
                truncated: message.truncated.unwrap_or(false),
                display_notice: message.display_notice.clone().unwrap_or_default(),
                export: message.export_outcome()?,
            })
        } else {
            None
        };
        let request = state
            .pending
            .remove(&message.request_id)
            .ok_or_else(BackendError::invalid)?;
        drop(state);
        if message.kind == "hello.ack" {
            self.captured_export.store(
                message
                    .capabilities
                    .as_ref()
                    .is_some_and(|c| c.iter().any(|v| v == "capturedExportV1")),
                Ordering::Release,
            );
            self.ready.store(true, Ordering::Release);
        }
        if message.kind == "error" {
            let error = BackendError {
                message: message.message.take().ok_or_else(BackendError::invalid)?,
                category: message.category.take().ok_or_else(BackendError::invalid)?,
                connected: message.connected.unwrap_or(false),
                outcome_unknown: message.outcome_unknown.unwrap_or(false),
                sql_completed: message.sql_completed.unwrap_or(false),
                sql_not_executed: message.sql_not_executed.unwrap_or(false),
                export_publication: message.export_publication.take(),
                transaction_status: message.transaction_status,
                sql_state: message.sql_state.take(),
                error_position: message.error_position,
                result_sets: sets,
            };
            request.sink.finish(Err(error), None);
        } else {
            request.sink.finish(Ok(message), outcome);
        }
        Ok(())
    }
}

struct ClientInner {
    shared: Arc<Shared>,
}
impl Drop for ClientInner {
    fn drop(&mut self) {
        self.shared.closing.store(true, Ordering::Release);
        let mut frame =
            serde_json::to_vec(&json!({"type":"shutdown","requestId":id()})).unwrap_or_default();
        frame.push(b'\n');
        let _ = self.shared.control.try_send(frame);
        self.shared
            .fail(BackendError::transport("The database helper was closed."));
        let child = self.shared.child.clone();
        // Closing the last tab/client never waits for process teardown on the UI thread.
        let _ = thread::Builder::new()
            .name("dbeer-helper-reaper".into())
            .spawn(move || {
                let _ = reap_owned_child(child, Duration::from_millis(250));
            });
    }
}

#[derive(Clone)]
pub struct BackendClient {
    inner: Arc<ClientInner>,
}
impl BackendClient {
    #[cfg(all(test, feature = "native-smoke"))]
    pub(super) fn request_attempts_for_test(&self) -> u64 {
        self.inner.shared.request_attempts.load(Ordering::Relaxed)
    }
    pub(super) fn same_instance(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.inner, &other.inner)
    }
    #[cfg(all(test, feature = "native-smoke"))]
    pub(super) fn fail_for_test(&self) {
        self.inner
            .shared
            .fail(BackendError::transport("The owned test helper exited."));
    }
    /// False after any fatal transport error; reconnection requires spawning a fresh helper.
    pub fn is_alive(&self) -> bool {
        self.inner
            .shared
            .hello_error
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .is_none()
            && !self.inner.shared.closing.load(Ordering::Acquire)
            && self
                .inner
                .shared
                .state
                .lock()
                .unwrap_or_else(|poison| poison.into_inner())
                .failure
                .is_none()
    }
    /// Transport failure and process exit are separate facts. Never block the
    /// UI on a reaper holding this mutex; lack of observation grants nothing.
    pub(super) fn owned_process_exited(&self) -> bool {
        self.inner
            .shared
            .child
            .try_lock()
            .ok()
            .is_some_and(|mut child| child.try_wait().ok().flatten().is_some())
    }

    pub fn spawn(path: impl AsRef<Path>) -> Result<Self> {
        let product_identity =
            BuildIdentity::optional_embedded().map_err(|_| product_identity_error())?;
        let mut command = Command::new(path.as_ref());
        #[cfg(target_os = "windows")]
        {
            use std::os::windows::process::CommandExt;
            // The helper communicates over pipes; a GUI launch needs no console.
            command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| BackendError::transport("Cannot launch the bundled database helper."))?;
        let input = child
            .stdin
            .take()
            .ok_or_else(|| BackendError::transport("Cannot open database helper input."))?;
        let output = child
            .stdout
            .take()
            .ok_or_else(|| BackendError::transport("Cannot open database helper output."))?;
        let (writer, receiver) = async_channel::bounded::<Vec<u8>>(MAX_PENDING);
        // Each active stream owns at most one unacknowledged chunk. Reserve
        // another MAX_PENDING slots for Stop/disconnect even at full load.
        let (control, control_receiver) = async_channel::bounded::<Vec<u8>>(MAX_PENDING * 2);
        let (hello_notify, hello_done) = async_channel::bounded(1);
        let shared = Arc::new(Shared {
            #[cfg(all(test, feature = "native-smoke"))]
            request_attempts: AtomicU64::new(0),
            state: Mutex::new(State {
                pending: HashMap::new(),
                failure: None,
            }),
            writer,
            control,
            queued_bytes: AtomicU64::new(0),
            child: Arc::new(Mutex::new(child)),
            ready: AtomicBool::new(false),
            product_identity,
            hello_started: AtomicBool::new(false),
            captured_export: AtomicBool::new(false),
            hello_notify,
            hello_done,
            hello_error: Arc::new(Mutex::new(None)),
            closing: AtomicBool::new(false),
        });
        let writer_shared = shared.clone();
        if thread::Builder::new()
            .name("dbeer-helper-writer".into())
            .spawn(move || {
                let mut input = input;
                loop {
                    let next = if let Ok(frame) = control_receiver.try_recv() {
                        Some((frame, true))
                    } else {
                        smol::block_on(smol::future::or(
                            async {
                                control_receiver
                                    .recv()
                                    .await
                                    .ok()
                                    .map(|frame| (frame, true))
                            },
                            async { receiver.recv().await.ok().map(|frame| (frame, false)) },
                        ))
                    };
                    let Some((frame, control)) = next else {
                        break;
                    };
                    if !control {
                        writer_shared
                            .queued_bytes
                            .fetch_sub(frame.len() as u64, Ordering::AcqRel);
                    }
                    if input
                        .write_all(&frame)
                        .and_then(|()| input.flush())
                        .is_err()
                    {
                        writer_shared.fail(BackendError::transport(
                            "Cannot write to the database helper.",
                        ));
                        return;
                    }
                }
            })
            .is_err()
        {
            shared.fail(BackendError::transport(
                "Cannot start database helper transport.",
            ));
            return Err(BackendError::transport(
                "Cannot start database helper transport.",
            ));
        }
        let reader_shared = shared.clone();
        if thread::Builder::new()
            .name("dbeer-helper-reader".into())
            .spawn(move || {
                let mut output = BufReader::new(output);
                loop {
                    let result = read_frame(&mut output)
                        .and_then(|frame| decode_message(&frame))
                        .and_then(|message| reader_shared.receive(message));
                    if let Err(error) = result {
                        reader_shared.fail(error);
                        return;
                    }
                }
            })
            .is_err()
        {
            shared.fail(BackendError::transport(
                "Cannot start database helper transport.",
            ));
            return Err(BackendError::transport(
                "Cannot start database helper transport.",
            ));
        }
        let timer_shared = Arc::downgrade(&shared);
        let _ = thread::Builder::new()
            .name("dbeer-helper-handshake-timeout".into())
            .spawn(move || {
                thread::sleep(Duration::from_secs(10));
                if let Some(shared) = timer_shared.upgrade()
                    && !shared.ready.load(Ordering::Acquire)
                    && !shared.closing.load(Ordering::Acquire)
                {
                    shared.fail(BackendError::transport(
                        "The database helper handshake timed out.",
                    ));
                }
            });
        Ok(Self {
            inner: Arc::new(ClientInner { shared }),
        })
    }
    async fn unary(
        &self,
        command: Value,
        terminal: &'static str,
        session_id: Option<String>,
        query_id: Option<String>,
        engine: Option<String>,
        context: ReplyContext,
    ) -> Result<Message> {
        let (sender, receiver) = async_channel::bounded(1);
        self.inner.shared.enqueue(
            command,
            Pending {
                terminal,
                session_id,
                query_id,
                engine,
                started: false,
                context,
                authoritative_status: None,
                control: false,
                accumulator: Accumulator::new(),
                sink: Sink::Unary(sender),
            },
        )?;
        receiver
            .recv()
            .await
            .map_err(|_| BackendError::transport("The database helper stopped responding."))?
    }
    fn require_ready(&self) -> Result<()> {
        if self.inner.shared.ready.load(Ordering::Acquire) {
            Ok(())
        } else {
            let state = self
                .inner
                .shared
                .state
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            Err(state
                .failure
                .clone()
                .unwrap_or_else(|| BackendError::transport("The database helper is not ready.")))
        }
    }
    pub async fn handshake(&self) -> Result<()> {
        let shared = &self.inner.shared;
        if shared.ready.load(Ordering::Acquire) {
            return Ok(());
        }
        if shared
            .hello_started
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            let request = Pending {
                terminal: "hello.ack",
                session_id: None,
                query_id: None,
                engine: None,
                started: false,
                context: ReplyContext::General,
                authoritative_status: None,
                control: false,
                accumulator: Accumulator::new(),
                sink: Sink::Handshake {
                    sender: shared.hello_notify.clone(),
                    error: shared.hello_error.clone(),
                },
            };
            if let Err(error) =
                shared.enqueue(json!({"type":"hello","protocolVersion":VERSION}), request)
            {
                *shared
                    .hello_error
                    .lock()
                    .unwrap_or_else(|poison| poison.into_inner()) = Some(error);
                shared.hello_notify.close();
            }
        }
        // Closing a channel wakes every waiter, including callers arriving after completion.
        // The one-shot remains owned by the reader if an awaiting UI task is cancelled.
        let _ = shared.hello_done.recv().await;
        if shared.ready.load(Ordering::Acquire) {
            return Ok(());
        }
        if let Some(error) = shared
            .hello_error
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .clone()
        {
            return Err(error);
        }
        self.require_ready()
    }
    pub async fn connect(&self, connection: Connection) -> Result<ConnectionOutcome> {
        self.require_ready()?;
        if !matches!(connection.engine.as_str(), "postgresql" | "mysql")
            || connection.host.is_empty()
            || connection.database.is_empty()
            || connection.user.is_empty()
            || connection.port == 0
            || !matches!(
                connection.ssl_mode.as_str(),
                "disable" | "allow" | "prefer" | "require" | "verify-ca" | "verify-full"
            )
            || !matches!(
                connection.policy.environment.as_str(),
                "unspecified" | "development" | "staging" | "production"
            )
        {
            return Err(BackendError::invalid());
        }
        let engine = connection.engine.clone();
        let message = self
            .unary(
                json!({"type":"connect","connection":connection}),
                "connect.result",
                None,
                None,
                Some(engine),
                ReplyContext::General,
            )
            .await?;
        Ok(ConnectionOutcome {
            session_id: message.session_id.ok_or_else(BackendError::invalid)?,
            engine: message.engine.ok_or_else(BackendError::invalid)?,
            capabilities: message.capabilities.ok_or_else(BackendError::invalid)?,
            transaction_status: message
                .transaction_status
                .ok_or_else(BackendError::invalid)?,
        })
    }
    fn stream(
        &self,
        mut command: Value,
        session_id: &str,
        context: ReplyContext,
    ) -> Result<QueryStream> {
        self.require_ready()?;
        if !valid_id(session_id) {
            return Err(BackendError::invalid());
        }
        let query_id = id();
        command["sessionId"] = json!(session_id);
        command["queryId"] = json!(query_id);
        if context.streamed() {
            command["stream"] = json!(true);
        }
        let (sender, receiver) = async_channel::bounded(16);
        self.inner.shared.enqueue(
            command,
            Pending {
                terminal: "query.result",
                session_id: Some(session_id.into()),
                query_id: Some(query_id.clone()),
                engine: None,
                started: false,
                context,
                authoritative_status: None,
                control: false,
                accumulator: Accumulator::new(),
                sink: Sink::Stream {
                    sender,
                    receiver: receiver.clone(),
                },
            },
        )?;
        Ok(QueryStream {
            query_id,
            events: receiver,
        })
    }
    #[cfg_attr(not(any(test, feature = "native-smoke")), allow(dead_code))]
    pub fn execute(&self, session_id: &str, sql: String) -> Result<QueryStream> {
        self.execute_authorized(session_id, sql, None)
    }
    pub fn execute_authorized(
        &self,
        session_id: &str,
        sql: String,
        authorization: Option<String>,
    ) -> Result<QueryStream> {
        if sql.is_empty() || authorization.as_deref().is_some_and(|a| !valid_id(a)) {
            return Err(BackendError::invalid());
        }
        let mut command = json!({"type":"execute","sql":sql});
        if let Some(authorization) = authorization {
            command["authorization"] = json!(authorization);
        }
        self.stream(command, session_id, ReplyContext::Execute(None))
    }
    pub fn catalog(&self, session_id: &str, catalog: CatalogRequest) -> Result<QueryStream> {
        if !catalog.valid() {
            return Err(BackendError::invalid());
        }
        self.stream(
            json!({"type":"catalog","catalog":catalog}),
            session_id,
            ReplyContext::Catalog(catalog),
        )
    }
    #[cfg_attr(not(any(test, feature = "native-smoke")), allow(dead_code))]
    pub async fn assess(&self, session_id: &str, sql: String) -> Result<OperationAssessment> {
        self.assess_operations(
            session_id,
            vec![OperationRequest::Execute { sql, export: None }],
        )
        .await
    }
    #[allow(dead_code)]
    pub async fn assess_operations(
        &self,
        session_id: &str,
        operations: Vec<OperationRequest>,
    ) -> Result<OperationAssessment> {
        self.begin_assessment(session_id, operations)?
            .finish()
            .await
    }
    pub fn begin_assessment(
        &self,
        session_id: &str,
        operations: Vec<OperationRequest>,
    ) -> Result<AssessmentRequest> {
        self.require_ready()?;
        if !valid_id(session_id)
            || operations.is_empty()
            || operations.len() > MAX_RESULT_SETS
            || !operations.iter().all(OperationRequest::valid)
        {
            return Err(BackendError::invalid());
        }
        let query_id = id();
        let (sender, receiver) = async_channel::bounded(1);
        self.inner.shared.enqueue(
            json!({"type":"operation.assess","sessionId":session_id,"queryId":query_id,"operations":operations}),
            Pending { terminal: "operation.assessment", session_id: Some(session_id.into()), query_id: Some(query_id.clone()),
                engine: None, started: false, context: ReplyContext::Assessment(operations), authoritative_status: None,
                control: false, accumulator: Accumulator::new(), sink: Sink::Unary(sender) },
        )?;
        Ok(AssessmentRequest { query_id, receiver })
    }
    #[allow(dead_code)]
    pub fn run_to_file(
        &self,
        session_id: &str,
        sql: String,
        export: ExportRequest,
        authorization: Option<String>,
    ) -> Result<QueryStream> {
        if export.destination.is_some()
            && !self.inner.shared.captured_export.load(Ordering::Acquire)
        {
            let mut error = BackendError::transport(
                "The helper does not support captured full export. SQL was not executed.",
            );
            error.category = "validation".into();
            error.connected = true;
            error.sql_not_executed = true;
            return Err(error);
        }
        if sql.is_empty()
            || !export.valid()
            || authorization.as_deref().is_some_and(|a| !valid_id(a))
        {
            return Err(BackendError::invalid());
        }
        let mut command = json!({"type":"execute", "sql":sql, "export":export});
        if let Some(authorization) = authorization {
            command["authorization"] = json!(authorization);
        }
        self.stream(command, session_id, ReplyContext::Execute(Some(export)))
    }
    #[allow(dead_code)]
    pub fn preview_changes(
        &self,
        session_id: &str,
        changes: ChangesRequest,
    ) -> Result<QueryStream> {
        if !changes.valid() {
            return Err(BackendError::invalid());
        }
        self.stream(
            json!({"type":"changes.preview", "changes":changes}),
            session_id,
            ReplyContext::Preview(changes),
        )
    }
    #[allow(dead_code)]
    pub fn apply_changes(
        &self,
        session_id: &str,
        changes: ChangesRequest,
        authorization: Option<String>,
    ) -> Result<QueryStream> {
        if !changes.valid() || authorization.as_deref().is_some_and(|a| !valid_id(a)) {
            return Err(BackendError::invalid());
        }
        let mut command = json!({"type":"changes.apply", "changes":changes});
        if let Some(authorization) = authorization {
            command["authorization"] = json!(authorization);
        }
        self.stream(command, session_id, ReplyContext::Apply(changes))
    }
    pub async fn cancel(&self, session_id: &str, query_id: &str) -> Result<CancelOutcome> {
        self.require_ready()?;
        if !valid_id(session_id) || !valid_id(query_id) {
            return Err(BackendError::invalid());
        }
        let message = self
            .unary(
                json!({"type":"cancel","sessionId":session_id,"queryId":query_id}),
                "cancel.ack",
                Some(session_id.into()),
                Some(query_id.into()),
                None,
                ReplyContext::General,
            )
            .await?;
        Ok(CancelOutcome {
            status: message.status.ok_or_else(BackendError::invalid)?,
        })
    }
    /// Cancel an unused ordered grant without submitting SQL. The helper clears
    /// its session grant on every cancel, including an already-finished query.
    pub async fn revoke_authorization(&self, session_id: &str) -> Result<CancelOutcome> {
        self.cancel(session_id, &id()).await
    }
    pub async fn disconnect(&self, session_id: &str) -> Result<()> {
        self.require_ready()?;
        if !valid_id(session_id) {
            return Err(BackendError::invalid());
        }
        self.unary(
            json!({"type":"disconnect","sessionId":session_id}),
            "disconnect.ack",
            Some(session_id.into()),
            None,
            None,
            ReplyContext::General,
        )
        .await?;
        Ok(())
    }
    /// After the common window graph has drained every operation and received
    /// every live session's disconnect ACK, stop and reap THIS owned child.
    /// A process exit is teardown evidence only, never a database outcome or a
    /// fabricated shutdown/disconnect ACK. No PID lookup or foreign kill exists.
    #[cfg(test)]
    pub(super) async fn retire_owned_for_test(&self) -> Result<()> {
        self.inner.shared.fail(BackendError::transport(
            "The owned test fixture is retiring.",
        ));
        self.await_owned_exit().await
    }
    pub(super) async fn await_owned_exit(&self) -> Result<()> {
        if !self
            .inner
            .shared
            .state
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .pending
            .is_empty()
        {
            return Err(BackendError::transport(
                "The original helper still owns pending requests.",
            ));
        }
        if self.is_alive() {
            let shutdown = self.unary(
                json!({"type":"shutdown"}),
                "shutdown.ack",
                None,
                None,
                None,
                ReplyContext::General,
            );
            let _ = smol::future::race(async { Some(shutdown.await) }, async {
                smol::Timer::after(Duration::from_secs(2)).await;
                None
            })
            .await;
        }
        self.inner.shared.closing.store(true, Ordering::Release);
        self.inner.shared.fail(BackendError::transport(
            "The owned database helper is shutting down.",
        ));
        let child = self.inner.shared.child.clone();
        smol::unblock(move || reap_owned_child(child, Duration::from_millis(250))).await
    }
}

/// Poll without holding the child mutex across a grace period. A failed kill
/// never leads to an unbounded wait while holding ownership away from retry.
fn reap_owned_child(child: Arc<Mutex<Child>>, grace: Duration) -> Result<()> {
    let deadline = Instant::now() + grace;
    loop {
        let mut process = child.lock().unwrap_or_else(|p| p.into_inner());
        match process.try_wait() {
            Ok(Some(_)) => return Ok(()),
            Err(_) => {
                return Err(BackendError::transport(
                    "Cannot observe the owned helper's exit.",
                ));
            }
            Ok(None) => {}
        }
        if Instant::now() >= deadline {
            if process.kill().is_err() {
                return if process.try_wait().ok().flatten().is_some() {
                    Ok(())
                } else {
                    Err(BackendError::transport(
                        "Cannot stop the owned database helper.",
                    ))
                };
            }
            process
                .wait()
                .map_err(|_| BackendError::transport("Cannot reap the owned database helper."))?;
            return Ok(());
        }
        drop(process);
        thread::sleep(Duration::from_millis(10));
    }
}

fn read_frame(reader: &mut impl BufRead) -> Result<Vec<u8>> {
    let mut frame = Vec::new();
    loop {
        let buffer = reader
            .fill_buf()
            .map_err(|_| BackendError::transport("Cannot read from the database helper."))?;
        if buffer.is_empty() {
            return Err(BackendError::transport(
                "The database helper exited unexpectedly.",
            ));
        }
        let newline = buffer.iter().position(|byte| *byte == b'\n');
        let count = newline.unwrap_or(buffer.len());
        if frame.len() + count > MAX_FRAME_BYTES {
            return Err(BackendError::transport(
                "The database helper exceeded the 16 MiB frame limit.",
            ));
        }
        frame.extend_from_slice(&buffer[..count]);
        reader.consume(count + usize::from(newline.is_some()));
        if newline.is_some() {
            return Ok(frame);
        }
    }
}
fn decode_message(frame: &[u8]) -> Result<Message> {
    if frame.len() > MAX_FRAME_BYTES {
        return Err(BackendError::invalid());
    }
    let build_identity = BuildIdentity::optional_from_frame(frame, MAX_FRAME_BYTES)
        .map_err(|_| BackendError::invalid())?;
    // UniqueValue rejects duplicate keys, including nested result and policy objects.
    let value: UniqueValue = serde_json::from_slice(frame).map_err(|_| BackendError::invalid())?;
    let object = value.0.as_object().ok_or_else(BackendError::invalid)?;
    let kind = object
        .get("type")
        .and_then(Value::as_str)
        .ok_or_else(BackendError::invalid)?;
    let fields = match kind {
        "hello.ack" => "protocolVersion|capabilities|buildIdentity",
        "connect.result" => "sessionId|transactionStatus|engine|capabilities",
        "query.started" => "sessionId|queryId",
        "query.progress" => "sessionId|queryId|sequence|resultIndex|rowCount",
        "query.chunk" => "sessionId|queryId|sequence|resultIndex|columns|rows",
        "query.result" => {
            "sessionId|queryId|durationMs|columns|rows|commandTag|rowCount|displayedRowCount|truncated|transactionStatus|displayNotice|resultSets|streamed|exportPath|exportFormat|exportRowCount"
        }
        "cancel.ack" => "sessionId|queryId|status",
        "disconnect.ack" => "sessionId",
        "shutdown.ack" => "",
        "operation.assessment" => "sessionId|queryId|assessment",
        "error" => {
            "sessionId|queryId|category|message|connected|outcomeUnknown|sqlState|errorPosition|transactionStatus|resultSets|streamed|sqlNotExecuted|sqlCompleted|exportPublication"
        }
        _ => return Err(BackendError::invalid()),
    };
    let invalid_fields = object.iter().any(|(key, v)| {
        (v.is_null() && !(kind == "hello.ack" && key == "buildIdentity"))
            || key != "type" && key != "requestId" && !fields.split('|').any(|f| f == key)
    });
    if !invalid_fields && let Ok(mut message) = serde_json::from_value::<Message>(value.0.clone()) {
        message.build_identity = build_identity;
        return Ok(message);
    }
    // A malformed terminal still may carry an independently valid completed
    // prefix and transaction status. Keep only those typed facts; never accept
    // the repaired payload as a successful response or as a known commit.
    if !matches!(kind, "query.result" | "error") {
        return Err(BackendError::invalid());
    }
    let mut recovery = serde_json::Map::new();
    for key in [
        "type",
        "requestId",
        "sessionId",
        "queryId",
        "transactionStatus",
        "streamed",
    ] {
        if let Some(v) = object.get(key) {
            recovery.insert(key.into(), v.clone());
        }
    }
    if let Some(raw_sets) = object.get("resultSets").and_then(Value::as_array) {
        let mut prefix = Vec::new();
        for raw in raw_sets.iter().take(MAX_RESULT_SETS) {
            let Ok(set) = serde_json::from_value::<ResultSet>(raw.clone()) else {
                break;
            };
            if !valid_set(&set, object.get("streamed") == Some(&Value::Bool(true))) {
                break;
            }
            prefix.push(raw.clone());
        }
        recovery.insert("resultSets".into(), Value::Array(prefix));
    }
    // Ignore an untyped transaction field rather than losing valid partial sets.
    if recovery
        .get("transactionStatus")
        .is_some_and(|v| serde_json::from_value::<TransactionStatus>(v.clone()).is_err())
    {
        recovery.remove("transactionStatus");
    }
    let mut message: Message =
        serde_json::from_value(Value::Object(recovery)).map_err(|_| BackendError::invalid())?;
    message.invalid_payload = true;
    Ok(message)
}

struct UniqueValue(Value);
impl<'de> Deserialize<'de> for UniqueValue {
    fn deserialize<D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Self, D::Error> {
        struct Visitor;
        impl<'de> serde::de::Visitor<'de> for Visitor {
            type Value = UniqueValue;
            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("a JSON value with unique object keys")
            }
            fn visit_bool<E: serde::de::Error>(
                self,
                value: bool,
            ) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(json!(value)))
            }
            fn visit_i64<E: serde::de::Error>(
                self,
                value: i64,
            ) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(json!(value)))
            }
            fn visit_u64<E: serde::de::Error>(
                self,
                value: u64,
            ) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(json!(value)))
            }
            fn visit_f64<E: serde::de::Error>(
                self,
                value: f64,
            ) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(json!(value)))
            }
            fn visit_str<E: serde::de::Error>(
                self,
                value: &str,
            ) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(json!(value)))
            }
            fn visit_string<E: serde::de::Error>(
                self,
                value: String,
            ) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(json!(value)))
            }
            fn visit_none<E: serde::de::Error>(self) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::Null))
            }
            fn visit_unit<E: serde::de::Error>(self) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::Null))
            }
            fn visit_seq<A: serde::de::SeqAccess<'de>>(
                self,
                mut seq: A,
            ) -> std::result::Result<Self::Value, A::Error> {
                let mut values = Vec::new();
                while let Some(value) = seq.next_element::<UniqueValue>()? {
                    values.push(value.0);
                }
                Ok(UniqueValue(Value::Array(values)))
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                mut map: A,
            ) -> std::result::Result<Self::Value, A::Error> {
                let mut values = serde_json::Map::new();
                while let Some(key) = map.next_key::<String>()? {
                    if values.contains_key(&key) {
                        return Err(serde::de::Error::custom("duplicate object key"));
                    }
                    let value = map.next_value::<UniqueValue>()?;
                    values.insert(key, value.0);
                }
                Ok(UniqueValue(Value::Object(values)))
            }
        }
        deserializer.deserialize_any(Visitor)
    }
}

#[cfg(test)]
#[path = "backend_contract_tests.rs"]
mod contract_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn transport_unavailable_is_not_observed_exit_and_awaited_teardown_is_owned() {
        let Some(path) = std::env::var_os("DBEER_GPUI_HELPER_PATH") else {
            assert!(
                std::env::var_os("CI").is_none(),
                "CI requires its native helper executable."
            );
            return;
        };
        let original = BackendClient::spawn(&path).unwrap();
        let sibling = BackendClient::spawn(path).unwrap();
        smol::block_on(original.handshake()).unwrap();
        smol::block_on(sibling.handshake()).unwrap();
        let child = original.inner.shared.child.clone();
        {
            let mut owned = child.lock().unwrap();
            assert!(owned.try_wait().unwrap().is_none());
            // Suppress the failure kill to model the separate transport fact.
            // This is the exact retained test child, never a PID/name lookup.
            original.inner.shared.closing.store(true, Ordering::Release);
            original
                .inner
                .shared
                .fail(BackendError::transport("Synthetic broken transport."));
            assert!(!original.is_alive());
            assert!(
                !original.owned_process_exited(),
                "An unavailable process lock cannot prove exit."
            );
        }
        smol::block_on(original.await_owned_exit()).unwrap();
        assert!(original.owned_process_exited());
        assert!(sibling.is_alive() && !sibling.owned_process_exited());
        smol::block_on(sibling.await_owned_exit()).unwrap();
    }

    #[test]
    fn real_helper_handshake_and_shutdown_are_portable() {
        let Some(path) = std::env::var_os("DBEER_GPUI_HELPER_PATH") else {
            assert!(
                std::env::var_os("CI").is_none(),
                "CI must provide the native helper executable for transport verification"
            );
            return;
        };
        let client = BackendClient::spawn(path).expect("Start the native test helper");
        let other = client.clone();
        let child = client.inner.shared.child.clone();
        let (first, second) =
            smol::block_on(smol::future::zip(client.handshake(), other.handshake()));
        first.expect("Complete the native helper handshake");
        second.expect("Share the same concurrent helper handshake");
        assert!(client.is_alive());
        drop(client);
        assert!(child.lock().unwrap().try_wait().unwrap().is_none());
        drop(other);
        let deadline = Instant::now() + Duration::from_secs(3);
        while child.lock().unwrap().try_wait().unwrap().is_none() {
            assert!(
                Instant::now() < deadline,
                "The native helper was not reaped after closing the client"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn message(value: Value) -> Message {
        decode_message(&serde_json::to_vec(&value).unwrap()).unwrap()
    }
    fn columns() -> Value {
        json!([
            {"index":0,"name":"null_value","engine":"postgresql","nativeType":"text"},
            {"index":1,"name":"empty_value","engine":"postgresql","nativeType":"text"},
            {"index":2,"name":"text_null","engine":"postgresql","nativeType":"text"},
            {"index":3,"name":"precise","engine":"postgresql","nativeType":"numeric"},
            {"index":4,"name":"payload","engine":"postgresql","nativeType":"bytea","encoding":"base64"}
        ])
    }
    fn chunk(sequence: usize, index: usize, columns: Option<Value>, rows: Value) -> Message {
        let mut value = json!({"type":"query.chunk","requestId":"request","sessionId":"session","queryId":"query","sequence":sequence,"resultIndex":index,"rows":rows});
        if let Some(columns) = columns {
            value["columns"] = columns;
        }
        message(value)
    }
    fn terminal(sets: Value) -> Message {
        message(
            json!({"type":"query.result","requestId":"request","sessionId":"session","queryId":"query",
        "durationMs":1.5,"columns":[],"rows":[],"commandTag":"SELECT 1","rowCount":1,"displayedRowCount":1,"truncated":false,
        "transactionStatus":"idle","streamed":true,"resultSets":sets}),
        )
    }

    #[test]
    fn shared_protocol_fixtures_decode_and_validate() {
        for frame in include_str!("../../../protocol/fixtures/responses.ndjson").lines() {
            decode_message(frame.as_bytes())
                .unwrap()
                .validate()
                .unwrap();
        }
    }

    #[test]
    fn malformed_frames_and_duplicate_keys_have_only_fixed_diagnostics() {
        for frame in [
            br#"{"type":"hello.ack","requestId":"secret","requestId":"duplicate","protocolVersion":3}"#.as_slice(),
            br#"{"type":"operation.assessment","requestId":"r","assessment":{"decision":"allow","decision":"deny"}}"#,
            b"\xff",
            br#"{"type":"query.chunk","requestId":"r","rows":[[123]]}"#,
        ] {
            let error=decode_message(frame).err().unwrap();
            assert_eq!(error.message,"The database helper sent an invalid protocol message.");
            assert!(!error.message.contains("secret"));
        }
        assert!(
            message(json!({"type":"hello.ack","requestId":"r","protocolVersion":2}))
                .validate()
                .is_err()
        );
    }

    #[test]
    fn framing_requires_newline_and_bounds_every_read() {
        let mut reader = Cursor::new(b"one\ntwo\n".to_vec());
        assert_eq!(read_frame(&mut reader).unwrap(), b"one");
        assert_eq!(read_frame(&mut reader).unwrap(), b"two");
        assert!(read_frame(&mut reader).is_err());
        assert!(read_frame(&mut Cursor::new(b"unterminated")).is_err());
        let mut maximum = vec![b'x'; MAX_FRAME_BYTES];
        maximum.push(b'\n');
        assert_eq!(
            read_frame(&mut Cursor::new(maximum)).unwrap().len(),
            MAX_FRAME_BYTES
        );
        assert!(read_frame(&mut Cursor::new(vec![b'x'; MAX_FRAME_BYTES + 1])).is_err());
    }

    #[test]
    fn streaming_hydrates_exact_null_text_numeric_and_binary_values() {
        let mut accumulator = Accumulator::new();
        accumulator
            .append(&mut chunk(1, 0, Some(columns()), json!([])))
            .unwrap();
        accumulator
            .append(&mut chunk(
                2,
                0,
                None,
                json!([[null, "", "NULL", "9007199254740993.123456789", "AP8="]]),
            ))
            .unwrap();
        let mut terminal = terminal(
            json!([{"columns":columns(),"rows":[],"commandTag":"SELECT 1","rowCount":1,"displayedRowCount":1,"truncated":false}]),
        );
        terminal.validate().unwrap();
        let sets = accumulator.hydrate(&mut terminal).unwrap();
        assert_eq!(
            sets[0].rows[0],
            vec![
                None,
                Some("".into()),
                Some("NULL".into()),
                Some("9007199254740993.123456789".into()),
                Some("AP8=".into())
            ]
        );
        assert_eq!(sets[0].columns[4].encoding.as_deref(), Some("base64"));
    }

    #[test]
    fn streaming_rejects_wrong_sequences_widths_encodings_and_terminal_counts() {
        let mut accumulator = Accumulator::new();
        assert!(
            accumulator
                .append(&mut chunk(2, 0, Some(columns()), json!([])))
                .is_err()
        );
        accumulator
            .append(&mut chunk(1, 0, Some(columns()), json!([])))
            .unwrap();
        assert!(
            accumulator
                .append(&mut chunk(2, 1, None, json!([])))
                .is_err()
        );
        assert!(
            accumulator
                .append(&mut chunk(2, 0, None, json!([["wrong width"]])))
                .is_err()
        );
        assert!(
            accumulator
                .append(&mut chunk(
                    2,
                    0,
                    None,
                    json!([[null, "", "NULL", "1", "invalid base64"]])
                ))
                .is_err()
        );
        assert!(accumulator.hydrate(&mut terminal(json!([{"columns":columns(),"rows":[],"commandTag":"SELECT 1","rowCount":1,"displayedRowCount":1,"truncated":false}]))).is_err());
        assert!(!valid_base64("AB=="));
        assert!(!valid_base64("AAB="));
        assert!(valid_base64(""));
        assert!(valid_base64("AA=="));
    }

    #[test]
    fn streaming_limits_apply_across_result_sets_and_bytes() {
        let one_column = json!([{"index":0,"name":"x"}]);
        let mut accumulator = Accumulator::new();
        accumulator
            .append(&mut chunk(1, 0, Some(one_column.clone()), json!([])))
            .unwrap();
        accumulator
            .append(&mut chunk(
                2,
                0,
                None,
                json!(vec![vec![Some("x")]; MAX_DISPLAY_ROWS]),
            ))
            .unwrap();
        accumulator
            .append(&mut chunk(3, 1, Some(one_column.clone()), json!([])))
            .unwrap();
        assert!(
            accumulator
                .append(&mut chunk(4, 1, None, json!([["one too many"]])))
                .is_err()
        );
        let mut accumulator = Accumulator::new();
        accumulator
            .append(&mut chunk(1, 0, Some(one_column), json!([])))
            .unwrap();
        assert!(
            accumulator
                .append(&mut chunk(
                    2,
                    0,
                    None,
                    json!([["x".repeat(MAX_DISPLAY_BYTES)]])
                ))
                .is_err()
        );
    }

    #[test]
    fn partial_errors_keep_only_completed_result_sets_and_transaction_state() {
        let col = json!([{"index":0,"name":"x"}]);
        let mut accumulator = Accumulator::new();
        accumulator
            .append(&mut chunk(1, 0, Some(col.clone()), json!([["completed"]])))
            .unwrap();
        accumulator
            .append(&mut chunk(2, 1, Some(col.clone()), json!([["unfinished"]])))
            .unwrap();
        let mut error = message(
            json!({"type":"error","requestId":"r","sessionId":"s","queryId":"q","category":"sql","message":"Query failed.",
            "connected":true,"outcomeUnknown":false,"transactionStatus":"failedTransaction","streamed":true,
            "resultSets":[{"columns":col,"rows":[],"commandTag":"SELECT 1","rowCount":1,"displayedRowCount":1,"truncated":false}]}),
        );
        error.validate().unwrap();
        let sets = accumulator.hydrate(&mut error).unwrap();
        assert_eq!(sets.len(), 1);
        assert_eq!(sets[0].rows[0][0].as_deref(), Some("completed"));
        assert_eq!(
            error.transaction_status,
            Some(TransactionStatus::FailedTransaction)
        );
    }

    #[cfg(unix)]
    #[test]
    fn an_exited_helper_fails_all_handshake_waiters_and_caches_the_error() {
        let client = BackendClient::spawn("/usr/bin/true").unwrap();
        let other = client.clone();
        let (first, second) =
            smol::block_on(smol::future::zip(client.handshake(), other.handshake()));
        assert!(first.is_err());
        assert!(second.is_err());
        assert_eq!(first.unwrap_err().message, second.unwrap_err().message);
        assert!(smol::block_on(client.handshake()).is_err());
        assert!(!client.is_alive());
    }

    #[cfg(unix)]
    #[test]
    fn malformed_helper_marks_even_unstarted_submitted_queries_uncertain() {
        // cat deliberately violates the protocol by echoing commands. It exercises
        // a transport failure before query.started can be observed by the client.
        let client = BackendClient::spawn("/bin/cat").unwrap();
        client.inner.shared.ready.store(true, Ordering::Release);
        let stream = client
            .execute("session", "SELECT 'private literal'".into())
            .unwrap();
        let error = stream.events.recv_blocking().unwrap().unwrap_err();
        assert!(error.outcome_unknown);
        assert!(!error.connected);
        assert!(!error.message.contains("private literal"));
        assert!(!client.is_alive());
    }

    #[cfg(unix)]
    #[test]
    fn last_client_drop_reaps_the_helper_without_waiting_on_the_caller() {
        let client = BackendClient::spawn("/bin/cat").unwrap();
        let child = client.inner.shared.child.clone();
        let other = client.clone();
        drop(client);
        assert!(child.lock().unwrap().try_wait().unwrap().is_none());
        drop(other);
        let deadline = Instant::now() + Duration::from_secs(2);
        while child.lock().unwrap().try_wait().unwrap().is_none() {
            assert!(
                Instant::now() < deadline,
                "The helper was not reaped after dropping the last client."
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn terminal_error_survives_a_full_progress_queue_without_blocking() {
        let (sender, receiver) = async_channel::bounded(2);
        let sink = Sink::Stream {
            sender,
            receiver: receiver.clone(),
        };
        sink.progress(QueryEvent::Started);
        sink.progress(QueryEvent::Chunk {
            result_index: 0,
            row_count: 1,
        });
        sink.progress(QueryEvent::Chunk {
            result_index: 0,
            row_count: 2,
        });
        sink.finish(Err(BackendError::transport("The helper exited.")), None);
        assert!(matches!(
            receiver.try_recv(),
            Ok(Ok(QueryEvent::Chunk { .. }))
        ));
        assert_eq!(
            receiver.try_recv().unwrap().unwrap_err().message,
            "The helper exited."
        );
    }
}
