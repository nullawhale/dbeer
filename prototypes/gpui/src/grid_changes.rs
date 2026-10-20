//! Local-only typed drafts. Database capabilities and SQL remain authoritative in Go.
use crate::{backend, grid_clipboard::Value};
use std::collections::BTreeMap;

#[derive(Clone, PartialEq, Eq)]
pub(super) struct Fingerprint {
    pub columns: Vec<backend::Column>,
    pub metadata: Vec<backend::TableColumnMetadata>,
    pub snapshot: u64,
}
#[derive(Clone)]
pub(super) struct Row {
    pub id: u64,
    /// Never replaced by display/selection/copy/editor projection.
    pub original: Option<Vec<backend::CellValue>>,
    pub values: Vec<backend::CellValue>,
    pub assignments: BTreeMap<usize, backend::CellValue>,
    pub deleted: bool,
}
impl Row {
    pub fn pending(&self) -> bool {
        self.original.is_none() || self.deleted || !self.assignments.is_empty()
    }
}
#[derive(Clone)]
pub(super) struct Draft {
    pub fingerprint: Fingerprint,
    pub rows: Vec<Row>,
    pub revision: u64,
    next_id: u64,
}
/// Presentation choices only, never a frontend editability/type whitelist.
pub(super) struct ColumnPolicy {
    pub editable: bool,
    pub null: bool,
    pub default: bool,
    pub empty: bool,
    pub binary: bool,
    pub multiline: bool,
}
impl ColumnPolicy {
    pub fn new(column: &backend::Column, meta: &backend::TableColumnMetadata) -> Self {
        let binary = column.encoding.as_deref() == Some("base64");
        let native = meta.native_type.trim().to_lowercase();
        let base = native.split('(').next().unwrap_or("").trim();
        let string = matches!(
            base,
            "char"
                | "character"
                | "bpchar"
                | "name"
                | "varchar"
                | "character varying"
                | "text"
                | "tinytext"
                | "mediumtext"
                | "longtext"
        ) || (column.engine == "postgresql"
            && [18, 19, 25, 1042, 1043].contains(&column.type_oid));
        Self {
            editable: meta.editable,
            null: meta.editable && meta.nullable,
            default: meta.editable,
            empty: meta.editable && !binary && string,
            binary,
            multiline: binary
                || matches!(
                    base,
                    "text" | "tinytext" | "mediumtext" | "longtext" | "json" | "jsonb" | "xml"
                ),
        }
    }
    pub fn accepts(&self, value: &backend::CellValue) -> bool {
        self.editable
            && value.valid(true)
            && match value {
                backend::CellValue::Null => self.null,
                backend::CellValue::Default => self.default,
                backend::CellValue::Binary(_) => self.binary,
                backend::CellValue::Text(_) => !self.binary,
            }
    }
}
pub(super) fn readonly_reason(
    table: bool,
    configured: bool,
    readonly: bool,
    columns: &[backend::TableColumnMetadata],
) -> Option<String> {
    if !configured {
        return Some("Connect this profile explicitly before editing.".into());
    }
    if readonly {
        return Some("Readonly is enabled for this connection.".into());
    }
    if !table {
        return Some("Views are read only.".into());
    }
    if !columns.iter().any(|m| m.primary_key != 0) {
        return Some("This table has no primary key.".into());
    }
    // Swift allows a generated-only table to insert a DEFAULT row. Restrict the
    // exception to the adapter's generated-column reason: engine/privilege/type
    // restrictions must never be overridden merely because generated is nonempty.
    let generated_only = columns.iter().all(|m| {
        !m.generated.is_empty()
            && matches!(
                m.edit_reason.as_str(),
                "" | "Generated columns are read-only." | "The server generates this value."
            )
    });
    if !columns.iter().any(|m| m.editable) && !generated_only {
        return Some(
            columns
                .iter()
                .find(|m| !m.edit_reason.is_empty())
                .map(|m| m.edit_reason.clone())
                .unwrap_or_else(|| {
                    "This table cannot be edited with its current types and permissions.".into()
                }),
        );
    }
    None
}
pub(super) fn original_value(
    column: &backend::Column,
    value: &Option<String>,
) -> backend::CellValue {
    let v = Value::original(column, value);
    match v.kind.as_str() {
        "null" => backend::CellValue::Null,
        "binary" => backend::CellValue::Binary(v.value.unwrap_or_default()),
        _ => backend::CellValue::Text(v.value.unwrap_or_default()),
    }
}
pub(super) fn clipboard(value: &backend::CellValue) -> Value {
    let (kind, value) = match value {
        backend::CellValue::Null => ("null", None),
        backend::CellValue::Default => ("default", None),
        backend::CellValue::Text(v) => ("text", Some(v.clone())),
        backend::CellValue::Binary(v) => ("binary", Some(v.clone())),
    };
    Value {
        kind: kind.into(),
        value,
    }
}
impl Draft {
    pub fn new(
        set: &backend::ResultSet,
        metadata: Vec<backend::TableColumnMetadata>,
        snapshot: u64,
        ids: &[u64],
    ) -> Option<Self> {
        if metadata.len() != set.columns.len()
            || ids.len() != set.rows.len()
            || set
                .columns
                .iter()
                .enumerate()
                .any(|(i, c)| c.index != i || c.name != metadata[i].name)
            || set.rows.iter().any(|r| r.len() != set.columns.len())
        {
            return None;
        }
        let rows = set
            .rows
            .iter()
            .zip(ids)
            .map(|(row, &id)| {
                let values: Vec<_> = row
                    .iter()
                    .zip(&set.columns)
                    .map(|(v, c)| original_value(c, v))
                    .collect();
                Row {
                    id,
                    original: Some(values.clone()),
                    values,
                    assignments: BTreeMap::new(),
                    deleted: false,
                }
            })
            .collect();
        Some(Self {
            fingerprint: Fingerprint {
                columns: set.columns.clone(),
                metadata,
                snapshot,
            },
            rows,
            revision: 0,
            next_id: ids.iter().max().copied().unwrap_or(0).checked_add(1)?,
        })
    }
    pub fn touch(&mut self) {
        self.revision += 1;
    }
    pub fn pending(&self) -> usize {
        self.rows.iter().filter(|r| r.pending()).count()
    }
    pub fn set(&mut self, id: u64, column: usize, value: backend::CellValue) -> bool {
        let Some(meta) = self.fingerprint.metadata.get(column) else {
            return false;
        };
        if !ColumnPolicy::new(&self.fingerprint.columns[column], meta).accepts(&value) {
            return false;
        }
        let Some(row) = self.rows.iter_mut().find(|r| r.id == id && !r.deleted) else {
            return false;
        };
        if row.values[column] == value {
            return true;
        }
        row.values[column] = value.clone();
        if row
            .original
            .as_ref()
            .is_some_and(|original| original[column] == value)
        {
            row.assignments.remove(&column);
        } else {
            row.assignments.insert(column, value);
        }
        self.touch();
        true
    }
    pub fn insert(&mut self) -> Option<u64> {
        if self.rows.len() >= 1000 {
            return None;
        }
        let id = self.next_id;
        self.next_id = self.next_id.checked_add(1)?;
        self.rows.push(Row {
            id,
            original: None,
            values: vec![backend::CellValue::Default; self.fingerprint.columns.len()],
            assignments: BTreeMap::new(),
            deleted: false,
        });
        self.touch();
        Some(id)
    }
    pub fn delete(&mut self, ids: &[u64]) {
        let mut changed = false;
        self.rows.retain_mut(|row| {
            if !ids.contains(&row.id) {
                return true;
            }
            if row.original.is_none() {
                changed = true;
                return false;
            }
            changed |= !row.deleted;
            row.deleted = true;
            true
        });
        if changed {
            self.touch();
        }
    }
    pub fn discard(&mut self) {
        self.rows.retain_mut(|row| {
            let Some(original) = &row.original else {
                return false;
            };
            row.values = original.clone();
            row.assignments.clear();
            row.deleted = false;
            true
        });
        self.touch();
    }
    /// Exact ordered originals (all columns, including composite keys) for helper CAS.
    pub fn request(&self, schema: String, table: String) -> backend::ChangesRequest {
        backend::ChangesRequest {
            schema,
            table,
            columns: self
                .fingerprint
                .columns
                .iter()
                .zip(&self.fingerprint.metadata)
                .map(|(c, m)| backend::SnapshotColumn {
                    name: c.name.clone(),
                    engine: c.engine.clone(),
                    native_type: m.native_type.clone(),
                })
                .collect(),
            changes: self
                .rows
                .iter()
                .filter(|r| r.pending())
                .map(|r| {
                    let kind = if r.original.is_none() {
                        backend::ChangeKind::Insert
                    } else if r.deleted {
                        backend::ChangeKind::Delete
                    } else {
                        backend::ChangeKind::Update
                    };
                    backend::RowChange {
                        kind,
                        original: r.original.clone().unwrap_or_default(),
                        values: if r.deleted {
                            vec![]
                        } else {
                            r.assignments
                                .iter()
                                .map(|(&i, v)| backend::ColumnAssignment {
                                    column: self.fingerprint.columns[i].name.clone(),
                                    value: v.clone(),
                                })
                                .collect()
                        },
                    }
                })
                .collect(),
        }
    }
}
#[cfg(test)]
mod tests;
