//! Pure loaded-result encoding. No connection, credential or helper dependency.
//! Values and paths deliberately have no Debug/diagnostic representation.
use crate::backend::ResultSet;
use serde::Serialize;
use std::{path::Path, sync::Arc};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Format {
    Json,
    Csv,
}
impl Format {
    pub(super) fn extension(self) -> &'static str {
        match self {
            Self::Json => "json",
            Self::Csv => "csv",
        }
    }
    pub(super) fn suggested_name(self, title: &str, rows: usize) -> String {
        // A title is presentation text, never a directory supplied to the chooser.
        let title = title.replace(['/', '\\', '\0'], "_");
        format!("{title}-loaded-{rows}-rows.{}", self.extension())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ExportError {
    Malformed,
    NullMarker,
    NullCollision,
    Write,
    Changed,
    Locked,
    #[cfg(windows)]
    Uncertain,
}
impl std::fmt::Display for ExportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Malformed => "The loaded result is invalid and could not be exported.",
            Self::NullMarker => "Choose a nonempty NULL marker.",
            Self::NullCollision => "The NULL marker also occurs in a value. Choose a different marker before exporting.",
            Self::Write => "The export file could not be saved. The previous destination was preserved.",
            Self::Changed => "The export destination changed. Choose the destination again.",
            Self::Locked => "The export file is locked or unavailable for replacement. The previous destination was preserved.",
            #[cfg(windows)] Self::Uncertain => "The export publication could not be verified. Inspect the destination before explicitly exporting again.",
        })
    }
}
impl From<crate::files::FileError> for ExportError {
    fn from(error: crate::files::FileError) -> Self {
        use crate::files::FileError;
        match error {
            FileError::Changed => Self::Changed,
            FileError::Locked => Self::Locked,
            #[cfg(windows)]
            FileError::Uncertain => Self::Uncertain,
            _ => Self::Write,
        }
    }
}
pub(super) fn validate(set: &ResultSet) -> Result<(), ExportError> {
    if set.columns.iter().enumerate().any(|(i, c)| i != c.index)
        || set.rows.iter().any(|r| r.len() != set.columns.len())
        || set.displayed_row_count != set.rows.len()
        || set.row_count > i64::MAX as u64
    {
        return Err(ExportError::Malformed);
    }
    Ok(())
}
pub(super) fn validate_marker(set: &ResultSet, marker: &str) -> Result<(), ExportError> {
    validate(set)?;
    if marker.is_empty() {
        return Err(ExportError::NullMarker);
    }
    if set
        .rows
        .iter()
        .flatten()
        .any(|v| v.as_deref() == Some(marker))
    {
        return Err(ExportError::NullCollision);
    }
    Ok(())
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Document<'a> {
    result_sets: Vec<ExportSet<'a>>,
    version: u8,
}
#[derive(Serialize)]
struct ExportSet<'a> {
    metadata: Metadata<'a>,
    rows: &'a [Vec<Option<String>>],
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Metadata<'a> {
    columns: Vec<Column<'a>>,
    command_tag: &'a str,
    displayed_row_count: usize,
    row_count: u64,
    truncated: bool,
}
// Swift/Go omit a zero OID; use a separate export DTO rather than changing wire types.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Column<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    encoding: Option<&'a str>,
    engine: &'a str,
    index: usize,
    name: &'a str,
    native_type: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    type_oid: Option<u32>,
}
pub(super) fn json(sets: &[ResultSet]) -> Result<String, ExportError> {
    for set in sets {
        validate(set)?;
    }
    let document = Document {
        version: 1,
        result_sets: sets
            .iter()
            .map(|s| ExportSet {
                rows: &s.rows,
                metadata: Metadata {
                    columns: s
                        .columns
                        .iter()
                        .map(|c| Column {
                            index: c.index,
                            name: &c.name,
                            engine: &c.engine,
                            native_type: &c.native_type,
                            type_oid: (c.type_oid != 0).then_some(c.type_oid),
                            encoding: c.encoding.as_deref(),
                        })
                        .collect(),
                    command_tag: &s.command_tag,
                    row_count: s.row_count,
                    displayed_row_count: s.displayed_row_count,
                    truncated: s.truncated,
                },
            })
            .collect(),
    };
    // Match Swift's sorted, pretty JSON, including unescaped slashes.
    let value = serde_json::to_value(document).map_err(|_| ExportError::Malformed)?;
    serde_json::to_string_pretty(&value).map_err(|_| ExportError::Malformed)
}
fn csv_field(value: &str, output: &mut String) {
    if value.contains([',', '"', '\r', '\n']) {
        output.push('"');
        for c in value.chars() {
            if c == '"' {
                output.push('"');
            }
            output.push(c);
        }
        output.push('"');
    } else {
        output.push_str(value);
    }
}
pub(super) fn csv(set: &ResultSet, marker: &str) -> Result<String, ExportError> {
    validate_marker(set, marker)?;
    let mut output = String::new();
    for (i, c) in set.columns.iter().enumerate() {
        if i != 0 {
            output.push(',');
        }
        csv_field(&c.name, &mut output);
    }
    output.push_str("\r\n");
    for row in &set.rows {
        for (i, value) in row.iter().enumerate() {
            if i != 0 {
                output.push(',');
            }
            csv_field(value.as_deref().unwrap_or(marker), &mut output);
        }
        output.push_str("\r\n");
    }
    Ok(output)
}
pub(super) fn encode(
    set: &ResultSet,
    format: Format,
    marker: &str,
) -> Result<Arc<str>, ExportError> {
    Ok(Arc::from(match format {
        Format::Json => json(std::slice::from_ref(set))?,
        Format::Csv => csv(set, marker)?,
    }))
}
/// Prepared bytes and chosen destination remain one owned publication value.
/// Dropping it on Cancel/stale origin removes only its unpublished temporary.
pub(super) struct PreparedExport {
    save: crate::files::PreparedSave,
}
impl PreparedExport {
    pub(super) fn prepare(
        bytes: Arc<str>,
        path: &Path,
        destination: &crate::files::CapturedDestination,
    ) -> Result<Self, ExportError> {
        Ok(Self {
            save: crate::files::PreparedSave::prepare_captured(bytes, path, destination)?,
        })
    }
    pub(super) fn matches(&self, bytes: &str, path: &Path) -> bool {
        self.save.matches_capture(bytes, path)
    }
    pub(super) fn publish(self) -> Result<(), ExportError> {
        self.save.publish().map(|_| ()).map_err(Into::into)
    }
}

#[cfg(test)]
mod tests;
