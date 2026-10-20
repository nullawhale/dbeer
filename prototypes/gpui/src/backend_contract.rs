//! Existing protocol-v3 operations, without dialect SQL or UI state.
//!
//! Some entry points intentionally precede their screens. All dispatched requests
//! and their corresponding outcomes are validated by backend.rs.
#![allow(dead_code)]

use super::{BackendError, Result, ResultSet, TransactionStatus};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, path::Path};

fn zero(value: &u32) -> bool {
    *value == 0
}
fn text(value: &str, maximum: usize, nonempty: bool) -> bool {
    (!nonempty || !value.is_empty()) && value.len() <= maximum && !value.contains('\0')
}
fn name(value: &str) -> bool {
    text(value, 1024, true)
}
fn engine(value: &str) -> bool {
    matches!(value, "postgresql" | "mysql")
}

#[derive(Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CatalogRequest {
    pub kind: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub schema: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub object: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub object_kind: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub identity: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub search: String,
    #[serde(default, skip_serializing_if = "zero")]
    pub page: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sort: Vec<CatalogSort>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub filters: Vec<CatalogFilter>,
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CatalogSort {
    pub column: String,
    pub direction: SortDirection,
}
#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SortDirection {
    Asc,
    Desc,
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CatalogFilter {
    pub column: String,
    pub operator: FilterOperator,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
}
#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum FilterOperator {
    Eq,
    Ne,
    Lt,
    Lte,
    Gt,
    Gte,
    Contains,
    IsNull,
    IsNotNull,
}
impl CatalogRequest {
    pub fn valid(&self) -> bool {
        if self.page > 1_000_000
            || self.sort.len() > 32
            || self.filters.len() > 32
            || (self.kind != "browse"
                && (!self.sort.is_empty()
                    || !self.filters.is_empty()
                    || (self.page != 0 && self.kind != "completion")))
            || !self.sort.iter().all(|s| name(&s.column))
            || !self.filters.iter().all(|f| {
                name(&f.column)
                    && match f.operator {
                        FilterOperator::IsNull | FilterOperator::IsNotNull => f.value.is_none(),
                        _ => f
                            .value
                            .as_ref()
                            .is_some_and(|v| text(v, 1024 * 1024, false)),
                    }
            })
            || [&self.schema, &self.object, &self.object_kind, &self.search]
                .iter()
                .any(|s| !text(s, 1024, false))
            || !text(&self.identity, 128, false)
            || (self.kind != "search" && !self.search.is_empty())
        {
            return false;
        }
        let object_kind = matches!(
            self.object_kind.as_str(),
            "table" | "view" | "function" | "procedure" | "trigger"
        );
        match self.kind.as_str() {
            "completion" => {
                self.object.is_empty() && self.object_kind.is_empty() && self.identity.is_empty()
            }
            "search" => {
                !self.search.is_empty()
                    && self.object.is_empty()
                    && self.object_kind.is_empty()
                    && self.identity.is_empty()
            }
            "schemas" => {
                self.schema.is_empty()
                    && self.object.is_empty()
                    && self.object_kind.is_empty()
                    && self.identity.is_empty()
            }
            "objects" => {
                !self.schema.is_empty()
                    && self.object.is_empty()
                    && object_kind
                    && self.identity.is_empty()
            }
            "columns" | "keys" | "indexes" | "constraints" | "triggers" => {
                !self.schema.is_empty()
                    && !self.object.is_empty()
                    && matches!(self.object_kind.as_str(), "" | "table" | "view")
                    && self.identity.is_empty()
            }
            "definition" => !self.schema.is_empty() && !self.object.is_empty() && object_kind,
            "name" => {
                !self.schema.is_empty()
                    && !self.object.is_empty()
                    && object_kind
                    && (self.identity.is_empty()
                        || matches!(
                            self.object_kind.as_str(),
                            "function" | "procedure" | "trigger"
                        ))
            }
            "select" | "browse" => {
                !self.schema.is_empty()
                    && !self.object.is_empty()
                    && matches!(self.object_kind.as_str(), "table" | "view")
                    && self.identity.is_empty()
            }
            _ => false,
        }
    }
}

/// These values never pass through JSON numbers or a SQL string interpolator.
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(
    tag = "kind",
    content = "value",
    rename_all = "lowercase",
    deny_unknown_fields
)]
pub enum CellValue {
    Null,
    Default,
    Text(String),
    Binary(String),
}
impl CellValue {
    pub fn valid(&self, allow_default: bool) -> bool {
        match self {
            Self::Null => true,
            Self::Default => allow_default,
            Self::Text(v) => v.len() <= 8 * 1024 * 1024,
            Self::Binary(v) => v.len() <= 12 * 1024 * 1024 && valid_binary_input(v),
        }
    }
}
// Match Go base64.StdEncoding for request values: CR/LF and unused trailing
// bits are accepted there. Responses still require the helper's canonical form.
fn valid_binary_input(value: &str) -> bool {
    let compact: Vec<u8> = value
        .bytes()
        .filter(|b| !matches!(b, b'\r' | b'\n'))
        .collect();
    if !compact.len().is_multiple_of(4) {
        return false;
    }
    let padding = compact.iter().rev().take_while(|b| **b == b'=').count();
    padding <= 2
        && compact[..compact.len() - padding]
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/'))
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SnapshotColumn {
    pub name: String,
    pub engine: String,
    pub native_type: String,
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ColumnAssignment {
    pub column: String,
    pub value: CellValue,
}
#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ChangeKind {
    Insert,
    Update,
    Delete,
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RowChange {
    pub kind: ChangeKind,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub original: Vec<CellValue>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub values: Vec<ColumnAssignment>,
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ChangesRequest {
    pub schema: String,
    pub table: String,
    pub columns: Vec<SnapshotColumn>,
    pub changes: Vec<RowChange>,
}
impl ChangesRequest {
    pub fn valid(&self) -> bool {
        if !name(&self.schema)
            || !name(&self.table)
            || self.columns.is_empty()
            || self.columns.len() > 4096
            || self.changes.is_empty()
            || self.changes.len() > 1000
        {
            return false;
        }
        let mut columns = HashSet::new();
        if !self.columns.iter().all(|c| {
            name(&c.name) && columns.insert(&c.name) && engine(&c.engine) && name(&c.native_type)
        }) {
            return false;
        }
        self.changes.iter().all(|c| {
            let mut assigned = HashSet::new();
            (if c.kind == ChangeKind::Insert {
                c.original.is_empty()
            } else {
                c.original.len() == self.columns.len()
            }) && (c.kind != ChangeKind::Update || !c.values.is_empty())
                && (c.kind != ChangeKind::Delete || c.values.is_empty())
                && c.values.len() <= self.columns.len()
                && c.original.iter().all(|v| v.valid(false))
                && c.values.iter().all(|a| {
                    columns.contains(&a.column) && assigned.insert(&a.column) && a.value.valid(true)
                })
        })
    }
}
#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum ExportFormat {
    Csv,
    Json,
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExportDestination {
    pub exists: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub identity: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_identity: Option<String>,
    pub size: u64,
    pub sha256: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub modified_nanoseconds: Option<String>,
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExportRequest {
    pub path: String,
    pub format: ExportFormat,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub null_marker: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destination: Option<ExportDestination>,
}
impl ExportRequest {
    pub fn valid(&self) -> bool {
        !(self.format == ExportFormat::Csv
            && self.null_marker.as_ref().is_some_and(|m| m.is_empty()))
            && self.destination.as_ref().is_none_or(|d| {
                if [&d.identity, &d.parent_identity].iter().any(|value| {
                    value.as_ref().is_some_and(|v| {
                        v.is_empty()
                            || v.len() > 128
                            || !v.bytes().all(|b| b.is_ascii_digit() || b == b':')
                    })
                }) {
                    return false;
                }

                if d.exists {
                    d.size <= i64::MAX as u64
                        && d.sha256.len() == 64
                        && d.sha256
                            .bytes()
                            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                        && d.modified_nanoseconds.as_ref().is_none_or(|v| {
                            !v.is_empty() && v.len() <= 32 && v.bytes().all(|b| b.is_ascii_digit())
                        })
                } else {
                    d.size == 0
                        && d.sha256.is_empty()
                        && d.modified_nanoseconds.is_none()
                        && d.identity.is_none()
                }
            })
            && Path::new(&self.path).is_absolute()
            && text(&self.path, 4096, true)
            && self
                .null_marker
                .as_ref()
                .is_none_or(|v| text(v, 1024, false))
    }
}
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct ExportOutcome {
    pub path: String,
    pub format: ExportFormat,
    pub row_count: u64,
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "type", deny_unknown_fields)]
pub enum OperationRequest {
    #[serde(rename = "execute")]
    Execute {
        sql: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        export: Option<ExportRequest>,
    },
    #[serde(rename = "changes.apply")]
    Apply { changes: ChangesRequest },
}
impl OperationRequest {
    pub fn valid(&self) -> bool {
        match self {
            Self::Execute { sql, export } => {
                !sql.is_empty() && export.as_ref().is_none_or(ExportRequest::valid)
            }
            Self::Apply { changes } => changes.valid(),
        }
    }
}
#[derive(Clone, Copy)]
pub enum Capability {
    Execute,
    Cancel,
    Transactions,
    Catalog,
    QuoteIdentifiers,
    ExecutionPolicy,
    OperationAssessment,
}
impl Capability {
    pub fn wire_name(self) -> &'static str {
        match self {
            Self::Execute => "execute",
            Self::Cancel => "cancel",
            Self::Transactions => "transactions",
            Self::Catalog => "catalog",
            Self::QuoteIdentifiers => "quoteIdentifiers",
            Self::ExecutionPolicy => "executionPolicy",
            Self::OperationAssessment => "operationAssessment",
        }
    }
}

/// Catalog values remain ordinal arrays; metadata access never folds duplicate
/// SQL column names into a map. Known metadata fields are resolved uniquely.
fn field<'a>(set: &ResultSet, row: &'a [Option<String>], key: &str) -> Result<Option<&'a str>> {
    let mut positions = set
        .columns
        .iter()
        .enumerate()
        .filter(|(_, c)| c.name == key);
    let index = positions.next().ok_or_else(BackendError::invalid)?.0;
    if positions.next().is_some() {
        return Err(BackendError::invalid());
    }
    Ok(row.get(index).ok_or_else(BackendError::invalid)?.as_deref())
}
fn required<'a>(set: &ResultSet, row: &'a [Option<String>], key: &str) -> Result<&'a str> {
    field(set, row, key)?.ok_or_else(BackendError::invalid)
}
fn json<T: serde::de::DeserializeOwned>(value: &str) -> Result<T> {
    let unique: super::UniqueValue =
        serde_json::from_str(value).map_err(|_| BackendError::invalid())?;
    serde_json::from_value(unique.0).map_err(|_| BackendError::invalid())
}
#[derive(Clone, PartialEq, Eq)]
pub struct TableColumnMetadata {
    pub name: String,
    pub native_type: String,
    pub nullable: bool,
    pub default: Option<String>,
    pub generated: String,
    pub primary_key: u32,
    pub editable: bool,
    pub edit_reason: String,
}
fn boolean(value: &str) -> Result<bool> {
    match value {
        "true" => Ok(true),
        "false" => Ok(false),
        _ => Err(BackendError::invalid()),
    }
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ForeignKey {
    pub name: String,
    pub target_schema: String,
    pub target_table: String,
    pub columns: Vec<ForeignKeyColumn>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ForeignKeyColumn {
    pub source: String,
    pub target: String,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FunctionSignature {
    pub return_type: String,
    pub parameters: Vec<FunctionParameter>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct FunctionParameter {
    pub name: String,
    #[serde(rename = "type")]
    pub native_type: String,
    #[serde(default)]
    pub position: u32,
    #[serde(default)]
    pub optional: bool,
    #[serde(default)]
    pub variadic: bool,
}
#[derive(Clone)]
pub struct CompletionMetadata {
    pub name: String,
    pub kind: String,
    pub schema: String,
    pub columns: Vec<String>,
    pub foreign_keys: Vec<ForeignKey>,
    pub signatures: Vec<FunctionSignature>,
}
#[derive(Clone)]
pub struct PreviewStatement {
    pub operation: ChangeKind,
    pub sql: String,
    pub parameters: Vec<CellValue>,
}
impl ResultSet {
    pub fn table_metadata(&self) -> Result<Vec<TableColumnMetadata>> {
        let mut names = HashSet::new();
        let mut primary = HashSet::new();
        self.rows
            .iter()
            .map(|r| {
                let m = TableColumnMetadata {
                    name: required(self, r, "name")?.into(),
                    native_type: required(self, r, "nativeType")?.into(),
                    nullable: boolean(required(self, r, "nullable")?)?,
                    default: field(self, r, "default")?.map(str::to_owned),
                    generated: required(self, r, "generated")?.into(),
                    primary_key: required(self, r, "primaryKey")?
                        .parse()
                        .map_err(|_| BackendError::invalid())?,
                    editable: boolean(required(self, r, "editable")?)?,
                    edit_reason: required(self, r, "editReason")?.into(),
                };
                if !name(&m.name)
                    || !name(&m.native_type)
                    || !names.insert(m.name.clone())
                    || m.primary_key > 4096
                    || (m.primary_key != 0 && !primary.insert(m.primary_key))
                {
                    return Err(BackendError::invalid());
                }
                Ok(m)
            })
            .collect()
    }
    pub fn completion_metadata(&self) -> Result<Vec<CompletionMetadata>> {
        self.rows
            .iter()
            .map(|r| {
                let m = CompletionMetadata {
                    name: required(self, r, "name")?.into(),
                    kind: required(self, r, "kind")?.into(),
                    schema: required(self, r, "schema")?.into(),
                    columns: json(required(self, r, "columns")?)?,
                    foreign_keys: json(required(self, r, "foreignKeys")?)?,
                    signatures: json(required(self, r, "signatures")?)?,
                };
                if !name(&m.name)
                    || !name(&m.schema)
                    || !matches!(m.kind.as_str(), "table" | "view" | "function")
                    || !m.columns.iter().all(|c| name(c))
                    || !m.foreign_keys.iter().all(|f| {
                        name(&f.name)
                            && name(&f.target_schema)
                            && name(&f.target_table)
                            && !f.columns.is_empty()
                            && f.columns.iter().all(|c| name(&c.source) && name(&c.target))
                    })
                    || !m.signatures.iter().all(|s| {
                        !s.return_type.is_empty()
                            && s.parameters.iter().enumerate().all(|(i, p)| {
                                !p.native_type.is_empty()
                                    && (p.position == 0 || p.position as usize == i + 1)
                            })
                    })
                {
                    return Err(BackendError::invalid());
                }
                Ok(m)
            })
            .collect()
    }
    pub fn preview_statements(&self) -> Result<Vec<PreviewStatement>> {
        self.rows
            .iter()
            .map(|r| {
                let operation = match required(self, r, "operation")? {
                    "insert" => ChangeKind::Insert,
                    "update" => ChangeKind::Update,
                    "delete" => ChangeKind::Delete,
                    _ => return Err(BackendError::invalid()),
                };
                let sql = required(self, r, "sql")?.to_owned();
                // PostgreSQL's zero-parameter preview historically encodes nil as null.
                let parameters: Option<Vec<CellValue>> = json(required(self, r, "parameters")?)?;
                let parameters = parameters.unwrap_or_default();
                if sql.is_empty() || !parameters.iter().all(|p| p.valid(false)) {
                    return Err(BackendError::invalid());
                }
                Ok(PreviewStatement {
                    operation,
                    sql,
                    parameters,
                })
            })
            .collect()
    }
}

/// Context-specific validation happens after generic row/ordinal validation.
/// Generic SQL sets are intentionally free to contain repeated column names.
pub(super) fn validate_catalog(request: &CatalogRequest, sets: &[ResultSet]) -> Result<()> {
    if sets.len() != 1 {
        return Err(BackendError::invalid());
    }
    let set = &sets[0];
    let fields: &[&str] = match request.kind.as_str() {
        "schemas" => &["name", "kind"],
        "objects" | "search" => &["name", "kind", "schema", "identity"],
        "columns" => &[
            "name",
            "nativeType",
            "nullable",
            "default",
            "generated",
            "primaryKey",
            "editable",
            "editReason",
        ],
        "keys" | "indexes" | "constraints" | "triggers" => &["name", "kind", "definition"],
        "definition" => &["name", "definition"],
        "name" => &["name"],
        "select" => &["sql"],
        "completion" => &[
            "name",
            "kind",
            "schema",
            "columns",
            "foreignKeys",
            "signatures",
        ],
        "browse" => return Ok(()),
        _ => return Err(BackendError::invalid()),
    };
    if set.columns.len() != fields.len()
        || !set.columns.iter().zip(fields).all(|(c, f)| c.name == *f)
    {
        return Err(BackendError::invalid());
    }
    match request.kind.as_str() {
        "columns" => {
            set.table_metadata()?;
        }
        "completion" => {
            set.completion_metadata()?;
        }
        _ => {
            for r in &set.rows {
                for key in fields {
                    required(set, r, key)?;
                }
            }
        }
    }
    Ok(())
}

/// Required response fields are also bound to the submitted operation, so a
/// valid-shaped export/assessment cannot authorize or report another batch.
#[derive(Clone, Default)]
pub(super) enum ReplyContext {
    #[default]
    General,
    Catalog(CatalogRequest),
    Preview(ChangesRequest),
    Apply(ChangesRequest),
    Execute(Option<ExportRequest>),
    Assessment(Vec<OperationRequest>),
}
impl ReplyContext {
    pub(super) fn streamed(&self) -> bool {
        matches!(self, Self::Catalog(_) | Self::Execute(_))
    }
    pub(super) fn validate(&self, message: &super::Message, sets: &[ResultSet]) -> Result<()> {
        if message.kind == "error" {
            return Ok(());
        }
        match self {
            Self::Catalog(r) => validate_catalog(r, sets)?,
            Self::Preview(r) => {
                if sets.len() != 1
                    || message.transaction_status != Some(TransactionStatus::Idle)
                    || sets[0].truncated
                    || sets[0].rows.len() != r.changes.len()
                {
                    return Err(BackendError::invalid());
                }
                let preview = sets[0].preview_statements()?;
                if !preview
                    .iter()
                    .zip(&r.changes)
                    .all(|(p, c)| p.operation == c.kind)
                {
                    return Err(BackendError::invalid());
                }
            }
            Self::Apply(r) => {
                if message.transaction_status != Some(TransactionStatus::Idle)
                    || message.row_count != Some(r.changes.len() as u64)
                    || sets
                        .iter()
                        .any(|s| !s.columns.is_empty() || !s.rows.is_empty())
                {
                    return Err(BackendError::invalid());
                }
            }
            Self::Execute(export) => match (export, message.export_outcome()?) {
                (Some(r), Some(o))
                    if o.path == r.path
                        && o.format == r.format
                        && (r.format != ExportFormat::Csv || sets.len() <= 1) => {}
                (None, None) => {}
                _ => return Err(BackendError::invalid()),
            },
            Self::Assessment(operations) => {
                let a = message
                    .assessment
                    .as_ref()
                    .ok_or_else(BackendError::invalid)?;
                if a.operations.len() != operations.len() {
                    return Err(BackendError::invalid());
                }
                for (operation, assessed) in operations.iter().zip(&a.operations) {
                    if matches!(operation, OperationRequest::Apply { .. })
                        && !assessed.statements.is_empty()
                    {
                        return Err(BackendError::invalid());
                    }
                    if let OperationRequest::Execute { sql, .. } = operation {
                        if assessed.statements.is_empty() && assessed.kind != "unknown" {
                            return Err(BackendError::invalid());
                        }
                        let mut end = 0;
                        for s in &assessed.statements {
                            if s.start < end
                                || s.end > sql.len()
                                || !sql.is_char_boundary(s.start)
                                || !sql.is_char_boundary(s.end)
                            {
                                return Err(BackendError::invalid());
                            }
                            end = s.end;
                        }
                    }
                }
            }
            Self::General => {
                if message.export_outcome()?.is_some() {
                    return Err(BackendError::invalid());
                }
            }
        }
        Ok(())
    }
}

/// Complete command union used at the transport submission boundary as well as
/// by the shared fixtures. Credentials and SQL intentionally have no Debug.
#[derive(Deserialize, Serialize)]
#[serde(tag = "type", rename_all_fields = "camelCase", deny_unknown_fields)]
pub(super) enum WireCommand {
    #[serde(rename = "hello")]
    Hello {
        request_id: String,
        protocol_version: u32,
    },
    #[serde(rename = "connect")]
    Connect {
        request_id: String,
        connection: super::Connection,
    },
    #[serde(rename = "execute")]
    Execute {
        request_id: String,
        session_id: String,
        query_id: String,
        sql: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        stream: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        export: Option<ExportRequest>,
        #[serde(skip_serializing_if = "Option::is_none")]
        authorization: Option<String>,
    },
    #[serde(rename = "catalog")]
    Catalog {
        request_id: String,
        session_id: String,
        query_id: String,
        catalog: CatalogRequest,
        #[serde(skip_serializing_if = "Option::is_none")]
        stream: Option<bool>,
    },
    #[serde(rename = "changes.preview")]
    Preview {
        request_id: String,
        session_id: String,
        query_id: String,
        changes: ChangesRequest,
    },
    #[serde(rename = "changes.apply")]
    Apply {
        request_id: String,
        session_id: String,
        query_id: String,
        changes: ChangesRequest,
        #[serde(skip_serializing_if = "Option::is_none")]
        authorization: Option<String>,
    },
    #[serde(rename = "operation.assess")]
    Assess {
        request_id: String,
        session_id: String,
        query_id: String,
        operations: Vec<OperationRequest>,
    },
    #[serde(rename = "cancel")]
    Cancel {
        request_id: String,
        session_id: String,
        query_id: String,
    },
    #[serde(rename = "disconnect")]
    Disconnect {
        request_id: String,
        session_id: String,
    },
    #[serde(rename = "stream.ack")]
    Ack {
        request_id: String,
        session_id: String,
        query_id: String,
        sequence: usize,
    },
    #[serde(rename = "shutdown")]
    Shutdown { request_id: String },
}
impl WireCommand {
    pub(super) fn valid(&self) -> bool {
        use super::valid_id;
        let (request, session, query) = match self {
            Self::Hello { request_id, .. }
            | Self::Connect { request_id, .. }
            | Self::Shutdown { request_id } => (request_id, None, None),
            Self::Disconnect {
                request_id,
                session_id,
            } => (request_id, Some(session_id), None),
            Self::Execute {
                request_id,
                session_id,
                query_id,
                ..
            }
            | Self::Catalog {
                request_id,
                session_id,
                query_id,
                ..
            }
            | Self::Preview {
                request_id,
                session_id,
                query_id,
                ..
            }
            | Self::Apply {
                request_id,
                session_id,
                query_id,
                ..
            }
            | Self::Assess {
                request_id,
                session_id,
                query_id,
                ..
            }
            | Self::Cancel {
                request_id,
                session_id,
                query_id,
            }
            | Self::Ack {
                request_id,
                session_id,
                query_id,
                ..
            } => (request_id, Some(session_id), Some(query_id)),
        };
        valid_id(request)
            && session.is_none_or(|v| valid_id(v))
            && query.is_none_or(|v| valid_id(v))
            && match self {
                Self::Hello {
                    protocol_version, ..
                } => *protocol_version == super::VERSION,
                Self::Connect { connection, .. } => connection.valid(),
                Self::Execute {
                    sql,
                    export,
                    authorization,
                    ..
                } => {
                    !sql.is_empty()
                        && export.as_ref().is_none_or(ExportRequest::valid)
                        && authorization.as_ref().is_none_or(|a| valid_id(a))
                }
                Self::Catalog { catalog, .. } => catalog.valid(),
                Self::Preview { changes, .. } => changes.valid(),
                Self::Apply {
                    changes,
                    authorization,
                    ..
                } => changes.valid() && authorization.as_ref().is_none_or(|a| valid_id(a)),
                Self::Assess { operations, .. } => {
                    !operations.is_empty()
                        && operations.len() <= super::MAX_RESULT_SETS
                        && operations.iter().all(OperationRequest::valid)
                }
                Self::Ack { sequence, .. } => *sequence > 0,
                Self::Cancel { .. } | Self::Disconnect { .. } | Self::Shutdown { .. } => true,
            }
    }
}
impl super::Connection {
    fn valid(&self) -> bool {
        engine(&self.engine)
            && !self.host.is_empty()
            && !self.database.is_empty()
            && !self.user.is_empty()
            && self.port != 0
            && matches!(
                self.ssl_mode.as_str(),
                "disable" | "allow" | "prefer" | "require" | "verify-ca" | "verify-full"
            )
            && matches!(
                self.policy.environment.as_str(),
                "unspecified" | "development" | "staging" | "production"
            )
    }
}
impl super::ConnectionOutcome {
    pub fn supports(&self, capability: Capability) -> bool {
        self.capabilities
            .iter()
            .any(|v| v == capability.wire_name())
    }
}
