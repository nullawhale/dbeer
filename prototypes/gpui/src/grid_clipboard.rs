//! Swift ResultClipboardPayload v1. No float conversions or name-keyed columns.
use crate::backend::Column;
use serde::{Deserialize, Serialize};

pub(super) const TYPE: &str = "dev.dbeer.result-selection+json";
#[cfg(any(test, target_os = "linux"))]
pub(super) const MIME: &str = "application/vnd.dbeer.result-selection+json";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Value {
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
}

impl Value {
    pub fn original(column: &Column, value: &Option<String>) -> Self {
        let Some(value) = value else {
            return Self {
                kind: "null".into(),
                value: None,
            };
        };
        if column.encoding.as_deref() == Some("base64") {
            return Self {
                kind: "binary".into(),
                value: Some(value.clone()),
            };
        }
        if column.engine == "postgresql"
            && column.type_oid == 17
            && let Some(hex) = value.strip_prefix("\\x")
        {
            let bytes = hex
                .as_bytes()
                .chunks(2)
                .map(|pair| {
                    if pair.len() != 2 {
                        return None;
                    }
                    u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok()
                })
                .collect::<Option<Vec<_>>>();
            if let Some(bytes) = bytes {
                use base64::Engine as _;
                return Self {
                    kind: "binary".into(),
                    value: Some(base64::engine::general_purpose::STANDARD.encode(bytes)),
                };
            }
        }
        Self {
            kind: "text".into(),
            value: Some(value.clone()),
        }
    }

    pub fn tsv(&self) -> String {
        if self.kind == "default" {
            return "<DEFAULT>".into();
        }
        let Some(value) = &self.value else {
            return "\\N".into();
        };
        if value.is_empty() || value == "\\N" || value.contains(['\t', '\n', '\r', '"']) {
            format!("\"{}\"", value.replace('"', "\"\""))
        } else {
            value.clone()
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Payload {
    pub version: u32,
    pub columns: Vec<Column>,
    pub source_rows: Vec<usize>,
    pub source_column_indices: Vec<usize>,
    pub values: Vec<Vec<Value>>,
}

/// Both representations are prepared before the platform can replace the clipboard.
#[derive(Clone)]
pub(super) struct Publication {
    pub text: String,
    pub json: String,
}

impl Payload {
    pub fn prepare(&self) -> Result<Publication, &'static str> {
        let text = self
            .values
            .iter()
            .map(|row| row.iter().map(Value::tsv).collect::<Vec<_>>().join("\t"))
            .collect::<Vec<_>>()
            .join("\n");
        let json =
            serde_json::to_string(self).map_err(|_| "The selection could not be encoded.")?;
        Ok(Publication { text, json })
    }
}
