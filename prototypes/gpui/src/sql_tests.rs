//! Shared expectations are additive fixtures derived from the Swift reference suites.
//! Compilation is allowed during implementation; execution is deferred to integration.
use super::*;
use serde::Deserialize;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Span {
    bytes: [usize; 2],
    utf16: [usize; 2],
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExpectedStatement {
    sql: String,
    span: Span,
    editor_span: Option<Span>,
}
#[derive(Deserialize)]
struct ExpectedDiagnostic {
    span: Span,
    message: String,
}
#[derive(Deserialize)]
struct Case {
    id: String,
    engine: String,
    source: String,
    statements: Vec<ExpectedStatement>,
    diagnostics: Vec<ExpectedDiagnostic>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExpectedFragment {
    kind: String,
    #[serde(rename = "sourceSQL")]
    source_sql: String,
    span: Span,
    statements: Vec<ExpectedStatement>,
    diagnostic: Option<ExpectedDiagnostic>,
    first_line: usize,
    last_line: usize,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Resolution {
    id: String,
    engine: String,
    source: String,
    #[serde(rename = "selectionUTF16")]
    selection_utf16: [usize; 2],
    script: bool,
    expected: Option<ExpectedFragment>,
}
#[derive(Deserialize)]
struct Position {
    byte: usize,
    utf16: usize,
    lsp: Option<PositionLsp>,
}
#[derive(Deserialize)]
struct PositionLsp {
    line: usize,
    character: usize,
}
impl PositionLsp {
    fn value(&self) -> LspPosition {
        LspPosition {
            line: self.line,
            character: self.character,
        }
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Coordinates {
    source: String,
    positions: Vec<Position>,
    #[serde(rename = "invalidUTF16")]
    invalid_utf16: Vec<usize>,
    invalid_bytes: Vec<usize>,
    #[serde(rename = "invalidLSP")]
    invalid_lsp: Vec<PositionLsp>,
}
#[derive(Deserialize)]
struct ErrorPosition {
    position: usize,
    byte: usize,
    utf16: usize,
}
#[derive(Deserialize)]
struct Adapter {
    source: String,
    engine: String,
    statement: ExpectedStatement,
    positions: Vec<ErrorPosition>,
}
#[derive(Deserialize)]
struct Fixtures {
    version: usize,
    cases: Vec<Case>,
    resolutions: Vec<Resolution>,
    coordinates: Coordinates,
    adapter: Adapter,
}
fn fixtures() -> Fixtures {
    serde_json::from_str(include_str!(
        "../../../protocol/fixtures/sql-execution/v1.json"
    ))
    .unwrap()
}
fn span(actual: &SourceSpan, expected: &Span) {
    assert_eq!(actual.bytes(), expected.bytes[0]..expected.bytes[1]);
    assert_eq!(actual.utf16(), expected.utf16[0]..expected.utf16[1]);
}
fn statements(source: &SourceText, actual: &[Statement], expected: &[ExpectedStatement]) {
    assert_eq!(actual.len(), expected.len());
    for (actual, expected) in actual.iter().zip(expected) {
        assert_eq!(actual.sql(), expected.sql);
        span(actual.span(), &expected.span);
        assert_eq!(&source.text()[actual.span().bytes()], actual.sql());
    }
}
fn diagnostic(actual: &Diagnostic, expected: &ExpectedDiagnostic) {
    assert_eq!(actual.message(), expected.message);
    span(actual.span(), &expected.span);
}
#[test]
fn shared_swift_splitter_goldens_keep_exact_source_sql_ranges_and_diagnostics() {
    let fixtures = fixtures();
    assert_eq!(fixtures.version, 1);
    assert!(fixtures.cases.len() >= 40);
    for case in fixtures.cases {
        let source = SourceText::new(case.source);
        let parsed = parse(&source, Dialect::from_engine(&case.engine).unwrap());
        assert_eq!(
            parsed.statements().len(),
            case.statements.len(),
            "{}",
            case.id
        );
        statements(&source, parsed.statements(), &case.statements);
        assert_eq!(parsed.editor_spans().len(), case.statements.len());
        for (actual, expected) in parsed.editor_spans().iter().zip(&case.statements) {
            span(actual, expected.editor_span.as_ref().unwrap());
        }
        assert_eq!(
            parsed.diagnostics().len(),
            case.diagnostics.len(),
            "{}",
            case.id
        );
        for (actual, expected) in parsed.diagnostics().iter().zip(&case.diagnostics) {
            diagnostic(actual, expected);
        }
    }
}
#[test]
fn shared_swift_fragments_resolve_caret_selection_script_and_original_offsets() {
    for case in fixtures().resolutions {
        let source = SourceText::new(case.source);
        let dialect = Dialect::from_engine(&case.engine).unwrap();
        let actual = resolve_utf16(
            source.clone(),
            case.selection_utf16[0]..case.selection_utf16[1],
            dialect,
            case.script,
        );
        let Some(expected) = case.expected else {
            assert!(actual.is_none(), "{}", case.id);
            continue;
        };
        let actual = actual.unwrap_or_else(|| panic!("{}", case.id));
        let kind = match expected.kind.as_str() {
            "selection" => FragmentKind::Selection,
            "statement" => FragmentKind::Statement,
            "script" => FragmentKind::Script,
            _ => panic!("invalid fixture"),
        };
        assert_eq!(actual.kind(), kind, "{}", case.id);
        assert_eq!(actual.source_sql(), expected.source_sql, "{}", case.id);
        span(actual.span(), &expected.span);
        statements(&source, actual.statements(), &expected.statements);
        assert_eq!(actual.first_line(), expected.first_line);
        assert_eq!(actual.last_line(), expected.last_line);
        match (actual.diagnostic(), expected.diagnostic.as_ref()) {
            (Some(a), Some(e)) => diagnostic(a, e),
            (None, None) => {}
            _ => panic!("diagnostic {}", case.id),
        }
        assert_eq!(
            actual.single_statement().is_ok(),
            actual.diagnostic().is_none() && actual.statements().len() == 1
        );
        // GPUI's byte API selects exactly the same immutable fragment.
        if case.selection_utf16[1] <= source.units.len() {
            let bytes = source
                .span_utf16(case.selection_utf16[0]..case.selection_utf16[1])
                .unwrap()
                .bytes();
            let from_bytes = resolve(source, bytes, dialect, case.script).unwrap();
            assert_eq!(actual.source_sql(), from_bytes.source_sql());
            assert_eq!(actual.span(), from_bytes.span());
            assert!(actual.statements() == from_bytes.statements());
        }
    }
}
#[test]
fn shared_coordinates_match_swift_lsp_surrogate_combining_crlf_and_eof() {
    let fixture = fixtures().coordinates;
    let source = SourceText::new(fixture.source);
    for position in fixture.positions {
        assert_eq!(source.byte_to_utf16(position.byte), Some(position.utf16));
        assert_eq!(source.utf16_to_byte(position.utf16), Some(position.byte));
        assert_eq!(
            source.byte_to_lsp(position.byte),
            position.lsp.as_ref().map(PositionLsp::value)
        );
        if let Some(lsp) = position.lsp {
            assert_eq!(source.lsp_to_byte(lsp.value()), Some(position.byte));
        }
    }
    for offset in fixture.invalid_utf16 {
        assert_eq!(source.utf16_to_byte(offset), None);
    }
    for offset in fixture.invalid_bytes {
        assert_eq!(source.byte_to_utf16(offset), None);
    }
    for position in fixture.invalid_lsp {
        assert_eq!(source.lsp_to_byte(position.value()), None);
    }
}
#[test]
fn shared_adapter_scalar_positions_map_back_through_removed_mysql_directives() {
    let fixture = fixtures().adapter;
    let source = SourceText::new(fixture.source);
    let parsed = parse(&source, Dialect::from_engine(&fixture.engine).unwrap());
    statements(&source, parsed.statements(), &[fixture.statement]);
    for position in fixture.positions {
        let statement = &parsed.statements()[0];
        assert_eq!(
            statement.adapter_error_byte(position.position),
            position.byte
        );
        assert_eq!(
            statement.adapter_error_utf16(position.position),
            position.utf16
        );
        match position.position {
            0 => assert_eq!(
                statement.map_adapter_error(Some(0)),
                Err(AdapterPositionError::ZeroIsNotOneBased)
            ),
            positive => {
                let mapped = statement
                    .map_adapter_error(Some(positive))
                    .unwrap()
                    .unwrap();
                assert_eq!(
                    mapped.source,
                    SourcePosition {
                        byte: position.byte,
                        utf16: position.utf16
                    }
                );
                assert_eq!(
                    mapped.clamped_to_end,
                    positive - 1 > statement.sql().chars().count()
                );
            }
        }
        assert_eq!(statement.map_adapter_error(None), Ok(None));
    }
}
#[test]
fn invalid_scalar_boundaries_refuse_preparation_and_sql_snapshot_stays_immutable() {
    let source = SourceText::new("SELECT '😀'; SELECT 2;");
    assert!(resolve(source.clone(), 9..9, Dialect::PostgreSQL, false).is_none());
    assert!(resolve_utf16(source.clone(), 9..9, Dialect::PostgreSQL, false).is_none());
    let fragment = resolve(source, 0..0, Dialect::PostgreSQL, false).unwrap();
    let replacement = SourceText::new("SELECT 3;");
    assert_eq!(fragment.single_statement().unwrap().sql(), "SELECT '😀'");
    assert_eq!(replacement.text(), "SELECT 3;");
}
