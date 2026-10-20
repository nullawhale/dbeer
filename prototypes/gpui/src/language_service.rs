//! Optional offline SQL assistance. The bundled Go service owns SQL analysis.
//!
//! This core deliberately has no BackendClient, credentials, connection, SQL
//! session or GPUI editor access. The catalog pager is a pure DTO boundary.
//! UI integration is tracked separately; ordinary editor/execution state must
//! remain usable after any error returned here.

#[cfg(test)]
mod completion_contract_tests;
mod framing;
pub mod metadata;
pub mod positions;
#[cfg(test)]
pub(crate) mod tests;
pub(crate) mod transport;

pub use metadata::CatalogSnapshot;
pub use positions::{TextRange, byte_range, label_range, position_at};

use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    fmt,
    ops::Range,
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use transport::Transport;

pub type Result<T> = std::result::Result<T, Error>;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Unavailable,
    InvalidFrame,
    InvalidMessage,
    InvalidPosition,
    Limit,
    Backpressure,
    Timeout,
    Cancelled,
    Remote,
    Stale,
}
impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Unavailable => "SQL assistance is unavailable.",
            Self::InvalidFrame | Self::InvalidMessage => {
                "SQL assistance returned an invalid response."
            }
            Self::InvalidPosition => "The editor position is no longer valid.",
            Self::Limit | Self::Backpressure => "SQL assistance reached its resource limit.",
            Self::Timeout => "SQL assistance timed out.",
            Self::Cancelled => "SQL assistance was cancelled.",
            Self::Remote => "SQL assistance could not complete the request.",
            Self::Stale => "The editor context changed.",
        })
    }
}
impl std::error::Error for Error {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dialect {
    PostgreSQL,
    MySQL,
}
impl Dialect {
    fn wire(self) -> &'static str {
        match self {
            Self::PostgreSQL => "postgresql",
            Self::MySQL => "mysql",
        }
    }
}

/// Transient identity only, never serialized to the offline service. Integrators
/// must advance settings_revision for any endpoint/TLS/policy/profile mutation,
/// and catalog_revision whenever metadata is invalidated or replaced.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ContextKey {
    pub profile_id: Option<String>,
    pub settings_revision: u64,
    pub catalog_revision: u64,
}

/// Owns the exact source used for request coordinates and reply ranges. No Debug:
/// document text is private and must never enter diagnostics/logging.
#[derive(Clone)]
pub struct DocumentCapture {
    pub document_id: String,
    pub uri: String,
    pub version: u32,
    pub context: ContextKey,
    pub process_generation: u64,
    /// Optional frontend source revision; never serialized or used as an LSP version.
    pub editor_revision: Option<u64>,
    pub dialect: Dialect,
    source: Arc<str>,
}
impl DocumentCapture {
    pub fn source(&self) -> &str {
        &self.source
    }
}

struct Document {
    capture: DocumentCapture,
    catalog: CatalogSnapshot,
    sent_version: Option<u32>,
    configuration_dirty: bool,
}
struct Facade {
    transport: Transport,
    documents: Mutex<HashMap<String, Document>>,
    ready: AtomicBool,
    initializing: AtomicBool,
    timeout: Duration,
}

#[derive(Clone)]
pub struct LanguageService {
    inner: Arc<Facade>,
}

impl LanguageService {
    pub const MAX_DOCUMENT_BYTES: usize = 2 * 1024 * 1024;
    const MAX_TOTAL_DOCUMENT_BYTES: usize = 8 * 1024 * 1024;

    /// The caller supplies existing platform::helper_path(), never a PATH name
    /// or shell command. Spawn and final teardown belong on an executor worker.
    pub fn spawn(path: impl AsRef<Path>) -> Result<Self> {
        Self::spawn_with_timeout(path, Duration::from_secs(2))
    }
    pub fn spawn_with_timeout(path: impl AsRef<Path>, timeout: Duration) -> Result<Self> {
        if timeout.is_zero() || timeout > Duration::from_secs(30) {
            return Err(Error::Limit);
        }
        Ok(Self {
            inner: Arc::new(Facade {
                transport: Transport::spawn(path)?,
                documents: Mutex::new(HashMap::new()),
                ready: AtomicBool::new(false),
                initializing: AtomicBool::new(false),
                timeout,
            }),
        })
    }
    pub fn process_generation(&self) -> u64 {
        self.inner.transport.generation()
    }
    pub fn available(&self) -> bool {
        self.inner.ready.load(Ordering::Acquire) && self.inner.transport.available()
    }

    /// One initialization per owned process. Explicit restart creates a fresh
    /// LanguageService, initializes it, and resynchronizes current documents.
    /// A new generation can never accept a capture from the old service.
    pub async fn initialize(&self) -> Result<()> {
        if self.inner.initializing.swap(true, Ordering::AcqRel) {
            return Err(Error::Unavailable);
        }
        let result = async {
            let response = self.inner.transport.request("initialize", json!({
                "processId":null,"rootUri":null,"capabilities":{
                    "general":{"positionEncodings":["utf-16"]},
                    "textDocument":{
                        "completion":{"completionItem":{"snippetSupport":false}},
                        "signatureHelp":{"signatureInformation":{
                            "parameterInformation":{"labelOffsetSupport":true},"activeParameterSupport":true}},
                        "publishDiagnostics":{"versionSupport":true}
                    }
                }
            }), self.inner.timeout)?.finish().await?;
            if response.get("capabilities").and_then(|v| v.get("positionEncoding")).and_then(Value::as_str) != Some("utf-16") {
                return Err(Error::InvalidMessage);
            }
            self.inner.transport.notify_batch(&[notification("initialized", json!({}))])?;
            self.inner.ready.store(true, Ordering::Release);
            let mut documents = self.inner.documents.lock().unwrap_or_else(|p| p.into_inner());
            for document in documents.values_mut() { self.send_document(document)?; }
            Ok(())
        }.await;
        if result.is_err() {
            self.inner.ready.store(false, Ordering::Release);
            self.inner.transport.shutdown().await;
        }
        result
    }

    /// Coalescing/debounce belongs to the UI scheduler. This bounded operation
    /// only synchronizes the newest captured source; it performs no DB work.
    /// It is safe to retain initial documents before initialize completes.
    pub fn update(
        &self,
        document_id: &str,
        source: impl Into<Arc<str>>,
        dialect: Dialect,
        context: ContextKey,
        catalog: CatalogSnapshot,
    ) -> Result<DocumentCapture> {
        let source = source.into();
        let mut documents = self
            .inner
            .documents
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        let other_bytes: usize = documents
            .iter()
            .filter(|(id, _)| id.as_str() != document_id)
            .map(|(_, document)| document.capture.source.len())
            .sum();
        if document_id.is_empty()
            || document_id.len() > 128
            || source.len() > Self::MAX_DOCUMENT_BYTES
            || other_bytes.saturating_add(source.len()) > Self::MAX_TOTAL_DOCUMENT_BYTES
            || (!documents.contains_key(document_id) && documents.len() == 32)
        {
            drop(documents);
            self.close(document_id);
            return Err(Error::Limit);
        }
        if let Some(document) = documents.get(document_id)
            && document.capture.source == source
            && document.capture.dialect == dialect
            && document.capture.context == context
        {
            return Ok(document.capture.clone());
        }
        let previous = documents.remove(document_id);
        let version = match previous.as_ref().map(|doc| doc.capture.version) {
            Some(version) if version < i32::MAX as u32 => version + 1,
            Some(_) => {
                drop(documents);
                self.close_removed(previous);
                return Err(Error::Limit);
            }
            None => 1,
        };
        let identity_changed = previous.as_ref().is_some_and(|doc| {
            doc.capture.dialect != dialect || doc.capture.context.profile_id != context.profile_id
        });
        let configuration_dirty = previous.as_ref().is_none_or(|doc| {
            doc.configuration_dirty || doc.capture.context != context || identity_changed
        });
        let uri = if !identity_changed {
            previous.as_ref().map(|doc| doc.capture.uri.clone())
        } else {
            None
        }
        .unwrap_or_else(|| {
            format!(
                "dbeer-sql:///{}/{}.sql",
                uuid::Uuid::new_v4(),
                uuid::Uuid::new_v4()
            )
        });
        let sent_version = if identity_changed {
            None
        } else {
            previous.as_ref().and_then(|doc| doc.sent_version)
        };
        let capture = DocumentCapture {
            document_id: document_id.into(),
            uri,
            version,
            context,
            process_generation: self.process_generation(),
            editor_revision: None,
            dialect,
            source,
        };
        let mut document = Document {
            capture: capture.clone(),
            catalog,
            sent_version,
            configuration_dirty,
        };
        if identity_changed {
            self.close_removed(previous);
        }
        let result = if self.available() {
            self.send_document(&mut document)
        } else {
            Ok(())
        };
        documents.insert(document_id.into(), document);
        if result.is_err() {
            self.inner.ready.store(false, Ordering::Release);
        }
        result.map(|()| capture)
    }

    fn send_document(&self, document: &mut Document) -> Result<()> {
        if document.sent_version == Some(document.capture.version) {
            return Ok(());
        }
        let capture = &document.capture;
        let mut messages = Vec::new();
        if document.configuration_dirty {
            messages.push(notification("workspace/didChangeConfiguration", json!({"settings":{"dbeer":{
                "uri":capture.uri,"engine":capture.dialect.wire(),"catalog":document.catalog.relations()
            }}})));
        }
        if document.sent_version.is_none() {
            messages.push(notification("textDocument/didOpen", json!({"textDocument":{
                "uri":capture.uri,"languageId":"sql","version":capture.version,"text":capture.source()
            }})));
        } else {
            messages.push(notification(
                "textDocument/didChange",
                json!({
                    "textDocument":{"uri":capture.uri,"version":capture.version},
                    "contentChanges":[{"text":capture.source()}]
                }),
            ));
        }
        self.inner.transport.notify_batch(&messages)?;
        document.sent_version = Some(capture.version);
        document.configuration_dirty = false;
        Ok(())
    }

    pub fn close(&self, document_id: &str) {
        let document = self
            .inner
            .documents
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(document_id);
        self.close_removed(document);
    }
    fn close_removed(&self, document: Option<Document>) {
        if let Some(document) = document
            && document.sent_version.is_some()
            && self
                .inner
                .transport
                .notify_batch(&[notification(
                    "textDocument/didClose",
                    json!({"textDocument":{"uri":document.capture.uri}}),
                )])
                .is_err()
        {
            self.inner.ready.store(false, Ordering::Release);
        }
    }
    pub fn capture_current(&self, capture: &DocumentCapture) -> bool {
        self.available() && self.capture_matches(capture)
    }
    fn capture_matches(&self, capture: &DocumentCapture) -> bool {
        if capture.process_generation != self.process_generation() {
            return false;
        }
        self.inner
            .documents
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .get(&capture.document_id)
            .is_some_and(|document| {
                document.capture.uri == capture.uri
                    && document.capture.version == capture.version
                    && document.capture.context == capture.context
                    && document.capture.dialect == capture.dialect
                    && document.sent_version == Some(capture.version)
            })
    }

    fn request_at(
        &self,
        method: &str,
        capture: &DocumentCapture,
        byte_offset: usize,
    ) -> Result<transport::Request> {
        if !self.capture_current(capture) {
            return Err(Error::Stale);
        }
        let position = position_at(capture.source(), byte_offset)?;
        self.inner.transport.request(
            method,
            json!({"textDocument":{"uri":capture.uri},"position":position,
            "context":{"triggerKind":1}}),
            self.inner.timeout,
        )
    }
    pub async fn completion(
        &self,
        capture: &DocumentCapture,
        byte_offset: usize,
    ) -> Result<CompletionBatch> {
        let response = self
            .request_at("textDocument/completion", capture, byte_offset)?
            .finish()
            .await;
        if !self.capture_matches(capture) {
            return Err(Error::Stale);
        }
        parse_completion(response?, capture.clone(), byte_offset)
    }
    pub async fn signature_help(
        &self,
        capture: &DocumentCapture,
        byte_offset: usize,
    ) -> Result<Option<SignatureHelp>> {
        let response = self
            .request_at("textDocument/signatureHelp", capture, byte_offset)?
            .finish()
            .await;
        if !self.capture_matches(capture) {
            return Err(Error::Stale);
        }
        parse_signature(response?, capture.clone())
    }
    /// Poll on one coalesced UI timer. Returned source-bearing batches retain
    /// their capture; recheck capture_current before applying to an editor.
    pub fn drain_diagnostics(&self) -> Vec<DiagnosticsBatch> {
        if !self.available() {
            return Vec::new();
        }
        let documents = self
            .inner
            .documents
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        self.inner
            .transport
            .notifications()
            .into_iter()
            .filter_map(|message| {
                let params = message.get("params")?;
                let uri = params.get("uri")?.as_str()?;
                let document = documents
                    .values()
                    .find(|document| document.capture.uri == uri)?;
                if params.get("version")?.as_u64()? != u64::from(document.capture.version)
                    || document.sent_version != Some(document.capture.version)
                {
                    return None;
                }
                parse_diagnostics(params.clone(), document.capture.clone()).ok()
            })
            .collect()
    }
    pub async fn flush(&self) -> Result<()> {
        self.inner.transport.flush().await
    }

    /// Await on an executor worker during actual workspace teardown. Explicit
    /// restart must await old shutdown before replacing this instance.
    pub async fn shutdown(&self) {
        self.inner.ready.store(false, Ordering::Release);
        self.inner
            .documents
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clear();
        self.inner.transport.shutdown().await;
    }
}

fn notification(method: &str, params: Value) -> Value {
    json!({"jsonrpc":"2.0","method":method,"params":params})
}

// Typed responses are presentation data, not logs. No source-bearing type below
// implements Debug. All SQL semantics remain in helper/internal/sqlcomplete.
#[allow(dead_code)] // Presentation fields are consumed by Tasks 24/25.
pub struct CompletionBatch {
    pub capture: DocumentCapture,
    pub items: Vec<CompletionItem>,
    pub incomplete: bool,
}
#[allow(dead_code)] // Presentation fields are consumed by Tasks 24/25.
pub struct CompletionItem {
    pub label: String,
    pub detail: Option<String>,
    pub kind: Option<u32>,
    pub replacement: String,
    pub replacement_range: Range<usize>,
    /// Byte ranges within label, converted from the Go UTF-16 match spans.
    pub match_ranges: Vec<Range<usize>>,
}
#[allow(dead_code)] // Presentation fields are consumed by Tasks 24/25.
pub struct DiagnosticsBatch {
    pub capture: DocumentCapture,
    pub diagnostics: Vec<Diagnostic>,
}
#[allow(dead_code)] // Presentation fields are consumed by Tasks 24/25.
pub struct Diagnostic {
    pub range: Range<usize>,
    pub message: String,
    pub severity: u32,
}
#[allow(dead_code)] // Presentation fields are consumed by Tasks 24/25.
pub struct SignatureHelp {
    pub capture: DocumentCapture,
    pub signatures: Vec<SignatureInformation>,
    pub active_signature: usize,
}
#[allow(dead_code)] // Presentation fields are consumed by Tasks 24/25.
pub struct SignatureInformation {
    pub label: String,
    pub parameter_ranges: Vec<Range<usize>>,
    pub active_parameter: Option<usize>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireCompletion {
    label: String,
    detail: Option<String>,
    kind: Option<u32>,
    insert_text: Option<String>,
    text_edit: Option<WireEdit>,
    insert_text_format: Option<u32>,
    additional_text_edits: Option<Value>,
    data: Option<WireMatches>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireEdit {
    range: TextRange,
    new_text: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireMatches {
    dbeer_match_ranges: Option<Vec<[usize; 2]>>,
}

fn parse_completion(
    value: Value,
    capture: DocumentCapture,
    offset: usize,
) -> Result<CompletionBatch> {
    let incomplete = value
        .get("isIncomplete")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let items = value
        .as_array()
        .or_else(|| value.get("items").and_then(Value::as_array))
        .ok_or(Error::InvalidMessage)?;
    let mut result = Vec::new();
    for item in items.iter().take(256) {
        let Ok(item) = serde_json::from_value::<WireCompletion>(item.clone()) else {
            continue;
        };
        if item.label.is_empty()
            || item.label.len() > 1024
            || item.detail.as_ref().is_some_and(|v| v.len() > 8192)
            || item.insert_text_format == Some(2)
            || item.additional_text_edits.is_some()
        {
            continue;
        }
        let (replacement, range) = if let Some(edit) = item.text_edit {
            let Ok(range) = byte_range(capture.source(), edit.range) else {
                continue;
            };
            (edit.new_text, range)
        } else {
            (
                item.insert_text.unwrap_or_else(|| item.label.clone()),
                offset..offset,
            )
        };
        if replacement.len() > LanguageService::MAX_DOCUMENT_BYTES {
            continue;
        }
        let mut ranges = Vec::new();
        if let Some(spans) = item.data.and_then(|v| v.dbeer_match_ranges)
            && spans.len() <= 64
        {
            let mut previous = 0;
            for span in spans {
                if span[0] < previous || span[1] <= span[0] {
                    ranges.clear();
                    break;
                }
                let Ok(range) = label_range(&item.label, span) else {
                    ranges.clear();
                    break;
                };
                previous = span[1];
                ranges.push(range);
            }
        }
        result.push(CompletionItem {
            label: item.label,
            detail: item.detail,
            kind: item.kind,
            replacement,
            replacement_range: range,
            match_ranges: ranges,
        });
    }
    Ok(CompletionBatch {
        capture,
        items: result,
        incomplete,
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireSignatureHelp {
    signatures: Vec<WireSignature>,
    #[serde(default)]
    active_signature: usize,
    active_parameter: Option<usize>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireSignature {
    label: String,
    parameters: Vec<WireParameter>,
    active_parameter: Option<usize>,
}
#[derive(Deserialize)]
struct WireParameter {
    label: [usize; 2],
}
fn parse_signature(value: Value, capture: DocumentCapture) -> Result<Option<SignatureHelp>> {
    if value.is_null() {
        return Ok(None);
    }
    let help: WireSignatureHelp =
        serde_json::from_value(value).map_err(|_| Error::InvalidMessage)?;
    if help.signatures.is_empty()
        || help.signatures.len() > 32
        || help.active_signature >= help.signatures.len()
    {
        return Err(Error::InvalidMessage);
    }
    let mut signatures = Vec::new();
    for signature in help.signatures {
        if signature.label.is_empty()
            || signature.label.len() > 8192
            || signature.parameters.len() > 256
        {
            return Err(Error::Limit);
        }
        let parameter_ranges = signature
            .parameters
            .into_iter()
            .map(|parameter| label_range(&signature.label, parameter.label))
            .collect::<Result<Vec<_>>>()?;
        let active_parameter = signature
            .active_parameter
            .or(help.active_parameter)
            .filter(|index| *index < parameter_ranges.len());
        signatures.push(SignatureInformation {
            label: signature.label,
            parameter_ranges,
            active_parameter,
        });
    }
    Ok(Some(SignatureHelp {
        capture,
        signatures,
        active_signature: help.active_signature,
    }))
}

#[derive(Deserialize)]
struct WireDiagnostics {
    diagnostics: Vec<WireDiagnostic>,
}
#[derive(Deserialize)]
struct WireDiagnostic {
    range: TextRange,
    message: String,
    severity: Option<u32>,
}
fn parse_diagnostics(value: Value, capture: DocumentCapture) -> Result<DiagnosticsBatch> {
    let values: WireDiagnostics =
        serde_json::from_value(value).map_err(|_| Error::InvalidMessage)?;
    let mut diagnostics = Vec::new();
    for diagnostic in values.diagnostics.into_iter().take(256) {
        if diagnostic.message.len() > 8192 {
            continue;
        }
        let Ok(range) = byte_range(capture.source(), diagnostic.range) else {
            continue;
        };
        diagnostics.push(Diagnostic {
            range,
            message: diagnostic.message,
            severity: diagnostic.severity.unwrap_or(1),
        });
    }
    Ok(DiagnosticsBatch {
        capture,
        diagnostics,
    })
}
