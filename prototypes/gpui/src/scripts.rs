//! Immutable script preparation and bounded, ordered execution feedback.
//! Splitting grants no authority: the originating helper assesses the exact batch.
use crate::{backend, sql};
use std::ops::Range;

pub const MAX_STATEMENTS: usize = 1024;
pub const MAX_ROWS: usize = 1000;
pub const MAX_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_SETS: usize = 1024;

pub fn validate(fragment: &sql::PreparedFragment) -> Result<(), &'static str> {
    if fragment.kind() != sql::FragmentKind::Script {
        fragment.single_statement()?;
    }
    if let Some(diagnostic) = fragment.diagnostic() {
        return Err(diagnostic.message());
    }
    if fragment.statements().is_empty() {
        return Err("No SQL statement at the current selection.");
    }
    if fragment.statements().len() > MAX_STATEMENTS {
        return Err("A script may contain at most 1,024 statements.");
    }
    Ok(())
}

pub fn operations(fragment: &sql::PreparedFragment) -> Vec<backend::OperationRequest> {
    fragment
        .statements()
        .iter()
        .map(|s| backend::OperationRequest::Execute {
            sql: s.sql().to_owned(),
            export: None,
        })
        .collect()
}

/// Classification coordinates are helper UTF-8 byte ranges relative to each
/// exact submitted SQL. Preserve every range, including several in one routine.
pub struct Classification {
    pub operation: usize,
    pub range: Range<usize>,
    pub utf16: Range<usize>,
    pub kind: String,
    pub reason: String,
}
pub fn classifications(
    fragment: &sql::PreparedFragment,
    assessment: &backend::OperationAssessment,
) -> Result<Vec<Classification>, &'static str> {
    if assessment.operations.len() != fragment.statements().len() {
        return Err("The helper assessed a different operation batch.");
    }
    let mut result = Vec::new();
    for (operation, (statement, assessed)) in fragment
        .statements()
        .iter()
        .zip(&assessment.operations)
        .enumerate()
    {
        if assessed.statements.is_empty() {
            result.push(Classification {
                operation,
                range: statement.span().bytes(),
                utf16: statement.span().utf16(),
                kind: assessed.kind.clone(),
                reason: "No statement classification supplied; review the entire operation.".into(),
            });
        }
        for item in &assessed.statements {
            let start = statement.span().bytes().start;
            if item.start > item.end || item.end > statement.sql().len() {
                return Err("Invalid helper classification range.");
            }
            let span = fragment
                .source()
                .span_bytes(start + item.start..start + item.end)
                .ok_or("Invalid helper classification boundary.")?;
            result.push(Classification {
                operation,
                range: span.bytes(),
                utf16: span.utf16(),
                kind: item.kind.clone(),
                reason: item.reason.clone(),
            });
        }
    }
    Ok(result)
}

/// One budget belongs to the entire run. No statement can reset it. Set metadata
/// and JSON encoding overhead count too; row values are retained unchanged.
#[derive(Default)]
pub struct DisplayBudget {
    rows: usize,
    bytes: usize,
    sets: usize,
    pub truncated: bool,
}
impl DisplayBudget {
    pub fn retain(
        &mut self,
        incoming: Vec<backend::ResultSet>,
        output: &mut Vec<backend::ResultSet>,
    ) -> Range<usize> {
        let start = output.len();
        for mut set in incoming {
            if self.sets == MAX_SETS {
                self.truncated = true;
                continue;
            }
            let all_rows = std::mem::take(&mut set.rows);
            let original_count = all_rows.len();
            set.displayed_row_count = 0;
            // Reserve maximum notice/count overhead before admitting row bytes.
            let metadata = serde_json::to_vec(&set).map_or(MAX_BYTES + 1, |v| v.len()) + 160;
            if self.bytes.saturating_add(metadata) > MAX_BYTES {
                self.truncated = true;
                continue;
            }
            self.bytes += metadata;
            for row in all_rows {
                let bytes = serde_json::to_vec(&row).map_or(MAX_BYTES + 1, |v| v.len()) + 1;
                if self.rows == MAX_ROWS || self.bytes.saturating_add(bytes) > MAX_BYTES {
                    self.truncated = true;
                    break;
                }
                self.rows += 1;
                self.bytes += bytes;
                set.rows.push(row);
            }
            set.displayed_row_count = set.rows.len();
            if set.rows.len() < original_count {
                set.truncated = true;
                set.display_notice =
                    "Script display limit reached; SQL completed without retaining all rows."
                        .into();
            }
            self.truncated |= set.truncated;
            self.sets += 1;
            output.push(set);
        }
        start..output.len()
    }
}

/// Synthetic fixtures use the same typed result display and batch budget.
pub fn demo_result(result: crate::demo::QueryResult) -> backend::ResultSet {
    let columns = result
        .columns
        .iter()
        .enumerate()
        .map(|(index, c)| backend::Column {
            index,
            name: c.name.clone(),
            engine: "postgresql".into(),
            native_type: c.data_type.clone(),
            type_oid: 0,
            encoding: result
                .rows
                .iter()
                .any(|r| matches!(r.get(index), Some(crate::demo::Cell::Binary(_))))
                .then(|| "base64".into()),
        })
        .collect();
    let rows: Vec<_> = result
        .rows
        .into_iter()
        .map(|row| {
            row.into_iter()
                .map(|cell| match cell {
                    crate::demo::Cell::Null => None,
                    crate::demo::Cell::Text(s)
                    | crate::demo::Cell::Number(s)
                    | crate::demo::Cell::Binary(s) => Some(s),
                    crate::demo::Cell::Bool(v) => Some(v.to_string()),
                })
                .collect()
        })
        .collect();
    backend::ResultSet {
        columns,
        row_count: rows.len() as u64,
        displayed_row_count: rows.len(),
        rows,
        command_tag: "DEMO SELECT".into(),
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn prepare(source: &str, dialect: sql::Dialect) -> sql::PreparedFragment {
        sql::resolve(sql::SourceText::new(source.to_owned()), 0..0, dialect, true).unwrap()
    }
    #[test]
    fn full_mysql_routine_is_one_exact_operation_and_current_pieces_stay_refused() {
        let source = "DELIMITER $$\r\nCREATE PROCEDURE p() BEGIN SELECT '😀'; SELECT 2; END$$\r\nDELIMITER ;\r\nCALL p();";
        let script = prepare(source, sql::Dialect::MySQL);
        assert!(validate(&script).is_ok());
        assert_eq!(script.statements().len(), 2);
        assert!(
            script.statements()[0]
                .sql()
                .contains("SELECT '😀'; SELECT 2;")
        );
        let current = sql::resolve(
            sql::SourceText::new(source.to_owned()),
            source.find("PROCEDURE").unwrap()..source.find("PROCEDURE").unwrap(),
            sql::Dialect::MySQL,
            false,
        )
        .unwrap();
        assert!(validate(&current).is_err());
    }
    #[test]
    fn bounds_reject_incomplete_input_before_preflight() {
        assert!(validate(&prepare("SELECT 'unfinished", sql::Dialect::PostgreSQL)).is_err());
        assert!(
            validate(&prepare(
                &"SELECT 1;".repeat(1025),
                sql::Dialect::PostgreSQL
            ))
            .is_err()
        );
    }
    #[test]
    fn display_budget_is_shared_across_statements_command_sets_and_exact_values() {
        let mut budget = DisplayBudget::default();
        let mut output = Vec::new();
        let set = backend::ResultSet {
            columns: vec![backend::Column {
                index: 0,
                name: "v".into(),
                engine: "postgresql".into(),
                native_type: "text".into(),
                type_oid: 0,
                encoding: None,
            }],
            rows: vec![
                vec![None],
                vec![Some(String::new())],
                vec![Some("NULL".into())],
                vec![Some("9007199254740993.123456789".into())],
            ],
            displayed_row_count: 4,
            row_count: 4,
            ..Default::default()
        };
        for _ in 0..300 {
            budget.retain(vec![set.clone()], &mut output);
        }
        assert_eq!(output.iter().map(|s| s.rows.len()).sum::<usize>(), MAX_ROWS);
        assert!(output[0].rows == set.rows);
        assert!(budget.truncated);
        budget.retain(vec![backend::ResultSet::default(); 1000], &mut output);
        assert_eq!(output.len(), MAX_SETS);
        assert!(serde_json::to_vec(&output).unwrap().len() <= MAX_BYTES);
        let mut bytes = DisplayBudget::default();
        let mut output = Vec::new();
        let mut big = set;
        big.rows = vec![vec![Some("😀".repeat(MAX_BYTES / 4))]];
        bytes.retain(vec![big], &mut output);
        assert!(bytes.truncated && output[0].rows.is_empty());
    }
    #[test]
    fn helper_ranges_and_errors_address_original_unicode_crlf_source() {
        let fragment = prepare(
            "-- 😀\r\nSELECT 'é';\r\nSELECT '😀x';",
            sql::Dialect::PostgreSQL,
        );
        let assessment = backend::OperationAssessment {
            decision: "allow".into(),
            policy: backend::ExecutionPolicy::default(),
            authorization: Some("exact-ordered-batch".into()),
            operations: fragment
                .statements()
                .iter()
                .map(|s| backend::AssessedOperation {
                    kind: "read".into(),
                    statements: vec![backend::StatementAssessment {
                        start: 0,
                        end: s.sql().len(),
                        kind: "read".into(),
                        reason: "read".into(),
                    }],
                })
                .collect(),
        };
        let classified = classifications(&fragment, &assessment).unwrap();
        assert_eq!(classified[1].range, fragment.statements()[1].span().bytes());
        assert_eq!(classified[1].utf16, fragment.statements()[1].span().utf16());
        let p = fragment.statements()[1]
            .map_adapter_error(Some(10))
            .unwrap()
            .unwrap();
        assert_eq!(
            fragment.source().byte_to_utf16(p.source.byte),
            Some(p.source.utf16)
        );
        assert!(
            fragment.statements()[1]
                .map_adapter_error(None)
                .unwrap()
                .is_none()
        );
    }
}
