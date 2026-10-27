//! Execution-only Swift-compatible scanner. Tree-sitter and helper policy are independent.
use std::{ops::Range, sync::Arc};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dialect {
    PostgreSQL,
    MySQL,
}
impl Dialect {
    pub fn from_engine(engine: &str) -> Option<Self> {
        match engine {
            "postgresql" => Some(Self::PostgreSQL),
            "mysql" => Some(Self::MySQL),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SourceSpan {
    bytes: Range<usize>,
    utf16: Range<usize>,
}
impl SourceSpan {
    pub fn bytes(&self) -> Range<usize> {
        self.bytes.clone()
    }
    pub fn utf16(&self) -> Range<usize> {
        self.utf16.clone()
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LspPosition {
    pub line: usize,
    pub character: usize,
}

/// Error positions are only mapped when the adapter supplies a scalar offset.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SourcePosition {
    pub byte: usize,
    pub utf16: usize,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MappedAdapterPosition {
    pub source: SourcePosition,
    /// The reference clamps positions past SQL end; callers may disclose that fact.
    pub clamped_to_end: bool,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AdapterPositionError {
    /// The v3 contract never permits a present zero errorPosition.
    ZeroIsNotOneBased,
}

/// An immutable source snapshot. No normalization, newline conversion or grapheme rounding.
#[derive(Clone)]
pub struct SourceText {
    text: Arc<str>,
    units: Arc<[u16]>,
    /// Only Unicode scalar boundaries have a byte address; surrogate interiors do not.
    utf16_bytes: Arc<[Option<usize>]>,
    byte_utf16: Arc<[(usize, usize)]>,
}
impl SourceText {
    pub fn new(text: impl Into<Arc<str>>) -> Self {
        let text = text.into();
        let units: Arc<[u16]> = text.encode_utf16().collect();
        let mut positions = Vec::with_capacity(units.len() + 1);
        let mut byte_utf16 = Vec::with_capacity(text.chars().count() + 1);
        for (byte, ch) in text.char_indices() {
            byte_utf16.push((byte, positions.len()));
            positions.push(Some(byte));
            if ch.len_utf16() == 2 {
                positions.push(None);
            }
        }
        byte_utf16.push((text.len(), positions.len()));
        positions.push(Some(text.len()));
        Self {
            text,
            units,
            utf16_bytes: positions.into(),
            byte_utf16: byte_utf16.into(),
        }
    }
    pub fn text(&self) -> &str {
        &self.text
    }
    pub fn byte_to_utf16(&self, byte: usize) -> Option<usize> {
        if !self.text.is_char_boundary(byte) {
            return None;
        }
        self.byte_utf16
            .binary_search_by_key(&byte, |(b, _)| *b)
            .ok()
            .map(|i| self.byte_utf16[i].1)
    }
    pub fn utf16_to_byte(&self, unit: usize) -> Option<usize> {
        self.utf16_bytes.get(unit).copied().flatten()
    }
    pub fn span_bytes(&self, range: Range<usize>) -> Option<SourceSpan> {
        if range.end < range.start {
            return None;
        }
        Some(SourceSpan {
            utf16: self.byte_to_utf16(range.start)?..self.byte_to_utf16(range.end)?,
            bytes: range,
        })
    }
    pub fn span_utf16(&self, range: Range<usize>) -> Option<SourceSpan> {
        if range.end < range.start {
            return None;
        }
        Some(SourceSpan {
            bytes: self.utf16_to_byte(range.start)?..self.utf16_to_byte(range.end)?,
            utf16: range,
        })
    }
    /// Exact Swift SQLLSPPosition semantics: CRLF is one break; its interior is invalid.
    pub fn byte_to_lsp(&self, byte: usize) -> Option<LspPosition> {
        let offset = self.byte_to_utf16(byte)?;
        let (mut line, mut start, mut index) = (0, 0, 0);
        while index < offset {
            if self.units[index] == 13 {
                if self.units.get(index + 1) == Some(&10) {
                    if index + 1 >= offset {
                        return None;
                    }
                    index += 1;
                }
                line += 1;
                start = index + 1;
            } else if self.units[index] == 10 {
                line += 1;
                start = index + 1;
            }
            index += 1;
        }
        Some(LspPosition {
            line,
            character: offset - start,
        })
    }
    pub fn lsp_to_byte(&self, position: LspPosition) -> Option<usize> {
        let (mut line, mut index) = (0, 0);
        while line < position.line && index < self.units.len() {
            if self.units[index] == 13 {
                if self.units.get(index + 1) == Some(&10) {
                    index += 1;
                }
                line += 1;
            } else if self.units[index] == 10 {
                line += 1;
            }
            index += 1;
        }
        if line != position.line {
            return None;
        }
        let start = index;
        while index < self.units.len() && !matches!(self.units[index], 13 | 10) {
            index += 1;
        }
        if position.character > index - start {
            return None;
        }
        self.utf16_to_byte(start + position.character)
    }
    fn slice(&self, units: Range<usize>) -> &str {
        let span = self
            .span_utf16(units)
            .expect("scanner ranges end on scalar boundaries");
        &self.text[span.bytes]
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct Statement {
    sql: Arc<str>,
    span: SourceSpan,
}
impl Statement {
    pub fn sql(&self) -> &str {
        &self.sql
    }
    pub fn span(&self) -> &SourceSpan {
        &self.span
    }
    /// Missing adapter positions remain absent (not an invented line/caret).
    /// A present zero is a malformed protocol value. A large value follows Swift's
    /// end clamp and reports that clamp explicitly; do not infer byte/UTF-16 units.
    pub fn map_adapter_error(
        &self,
        position: Option<usize>,
    ) -> Result<Option<MappedAdapterPosition>, AdapterPositionError> {
        let Some(position) = position else {
            return Ok(None);
        };
        if position == 0 {
            return Err(AdapterPositionError::ZeroIsNotOneBased);
        }
        Ok(Some(MappedAdapterPosition {
            source: SourcePosition {
                byte: self.adapter_error_byte(position),
                utf16: self.adapter_error_utf16(position),
            },
            clamped_to_end: position.saturating_sub(1) > self.sql.chars().count(),
        }))
    }
    /// Helper/PostgreSQL errorPosition is one-based Unicode scalars in submitted SQL.
    /// Swift clamps out-of-bounds positions to the end, and positions <= 1 to the start.
    pub fn adapter_error_byte(&self, one_based: usize) -> usize {
        self.span.bytes.start
            + self
                .sql
                .char_indices()
                .nth(one_based.saturating_sub(1))
                .map_or(self.sql.len(), |(byte, _)| byte)
    }
    pub fn adapter_error_utf16(&self, one_based: usize) -> usize {
        self.span.utf16.start
            + self
                .sql
                .chars()
                .take(one_based.saturating_sub(1))
                .map(char::len_utf16)
                .sum::<usize>()
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Diagnostic {
    span: SourceSpan,
    message: &'static str,
}
impl Diagnostic {
    pub fn span(&self) -> &SourceSpan {
        &self.span
    }
    pub fn message(&self) -> &'static str {
        self.message
    }
}
#[derive(Clone)]
pub struct ParsedScript {
    statements: Vec<Statement>,
    editor_spans: Vec<SourceSpan>,
    diagnostics: Vec<Diagnostic>,
}
impl ParsedScript {
    pub fn statements(&self) -> &[Statement] {
        &self.statements
    }
    pub fn editor_spans(&self) -> &[SourceSpan] {
        &self.editor_spans
    }
    pub fn diagnostics(&self) -> &[Diagnostic] {
        &self.diagnostics
    }
    pub fn statement_at_utf16(&self, caret: usize) -> Option<&Statement> {
        self.statements
            .iter()
            .find(|s| s.span.utf16.contains(&caret) || s.span.utf16.end == caret)
            .or_else(|| {
                self.statements
                    .iter()
                    .zip(&self.editor_spans)
                    .find(|(_, span)| caret >= span.utf16.start && caret <= span.utf16.end)
                    .map(|(s, _)| s)
            })
            .or_else(|| self.statements.iter().find(|s| s.span.utf16.start > caret))
            .or_else(|| self.statements.last())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FragmentKind {
    Selection,
    Statement,
    Script,
}

/// Typed immutable preparation only; this grants no authority to execute SQL.
#[derive(Clone)]
pub struct PreparedFragment {
    source: SourceText,
    kind: FragmentKind,
    span: SourceSpan,
    statements: Vec<Statement>,
    diagnostic: Option<Diagnostic>,
    first_line: usize,
    last_line: usize,
}
impl PreparedFragment {
    pub fn source(&self) -> &SourceText {
        &self.source
    }
    pub fn kind(&self) -> FragmentKind {
        self.kind
    }
    pub fn span(&self) -> &SourceSpan {
        &self.span
    }
    pub fn source_sql(&self) -> &str {
        &self.source.text[self.span.bytes.clone()]
    }
    pub fn statements(&self) -> &[Statement] {
        &self.statements
    }
    pub fn diagnostic(&self) -> Option<&Diagnostic> {
        self.diagnostic.as_ref()
    }
    pub fn first_line(&self) -> usize {
        self.first_line
    }
    pub fn last_line(&self) -> usize {
        self.last_line
    }
    /// Interim Run path: never dispatch a selection/routine as an accidental batch.
    /// Task 10 owns explicit ordered review and sequential execution of all statements.
    pub fn single_statement(&self) -> Result<&Statement, &'static str> {
        if let Some(diagnostic) = &self.diagnostic {
            return Err(diagnostic.message);
        }
        match self.statements.as_slice() {
            [statement] => Ok(statement),
            [] => Err("No SQL statement at the current selection."),
            _ => Err("Multiple statements require the reviewed script execution workflow."),
        }
    }
}

pub fn parse(source: &SourceText, dialect: Dialect) -> ParsedScript {
    Scanner::new(source, dialect).scan()
}
/// Mirrors SQLExecutionFragment.resolve, including its reparse of selected server SQL.
/// Selection is UTF-8 bytes from GPUI; UTF-16 callers use resolve_utf16 explicitly.
pub fn resolve(
    source: SourceText,
    selection: Range<usize>,
    dialect: Dialect,
    script: bool,
) -> Option<PreparedFragment> {
    if script {
        return resolve_utf16(source, 0..0, dialect, true);
    }
    if selection.end < selection.start {
        return None;
    }
    let selection = source
        .span_bytes(selection.start..selection.end.min(source.text.len()))?
        .utf16;
    resolve_utf16(source, selection, dialect, script)
}
pub fn resolve_utf16(
    source: SourceText,
    selection: Range<usize>,
    dialect: Dialect,
    script: bool,
) -> Option<PreparedFragment> {
    let (kind, span) = if script {
        (
            FragmentKind::Script,
            source.span_utf16(0..source.units.len())?,
        )
    } else {
        if selection.start > source.units.len() || selection.end < selection.start {
            return None;
        }
        source.span_utf16(selection.start..selection.end.min(source.units.len()))?;
        let mut lower = selection.start;
        let mut upper = selection.end.min(source.units.len());
        if lower == upper {
            let selected = parse(&source, dialect)
                .statement_at_utf16(lower)?
                .span
                .clone();
            (FragmentKind::Statement, selected)
        } else {
            while lower < upper && whitespace(source.units[lower]) {
                lower += 1;
            }
            while upper > lower && whitespace(source.units[upper - 1]) {
                upper -= 1;
            }
            if upper == lower {
                return None;
            }
            (FragmentKind::Selection, source.span_utf16(lower..upper)?)
        }
    };
    let selected = SourceText::new(Arc::<str>::from(&source.text[span.bytes.clone()]));
    let parsed = parse(&selected, dialect);
    let shift = |range: &SourceSpan| {
        source
            .span_utf16(
                (span.utf16.start + range.utf16.start)..(span.utf16.start + range.utf16.end),
            )
            .expect("source-preserving ranges")
    };
    let statements = parsed
        .statements
        .into_iter()
        .map(|statement| Statement {
            sql: statement.sql,
            span: shift(&statement.span),
        })
        .collect();
    let diagnostic = parsed.diagnostics.into_iter().next().map(|d| Diagnostic {
        span: shift(&d.span),
        message: d.message,
    });
    let first_line = 1 + source.units[..span.utf16.start]
        .iter()
        .filter(|u| **u == 10)
        .count();
    let last_line = first_line
        + source.units[span.utf16.clone()]
            .iter()
            .filter(|u| **u == 10)
            .count();
    Some(PreparedFragment {
        source,
        kind,
        span,
        statements,
        diagnostic,
        first_line,
        last_line,
    })
}
fn whitespace(unit: u16) -> bool {
    unit == 32 || (9..=13).contains(&unit) || unit == 0xA0
}
fn identifier_start(unit: u16) -> bool {
    (65..=90).contains(&unit) || (97..=122).contains(&unit) || unit == 95 || unit > 127
}
fn identifier_part(unit: u16) -> bool {
    identifier_start(unit) || (48..=57).contains(&unit) || unit == 36
}

struct Scanner<'a> {
    source: &'a SourceText,
    dialect: Dialect,
    statements: Vec<Statement>,
    editor_spans: Vec<SourceSpan>,
    diagnostics: Vec<Diagnostic>,
    delimiter: Vec<u16>,
    index: usize,
    segment_start: usize,
    has_code: bool,
    words: Vec<(String, Range<usize>)>,
    atomic_depth: usize,
    case_depth: usize,
    atomic_start: Option<usize>,
}
impl<'a> Scanner<'a> {
    fn new(source: &'a SourceText, dialect: Dialect) -> Self {
        Self {
            source,
            dialect,
            statements: vec![],
            editor_spans: vec![],
            diagnostics: vec![],
            delimiter: vec![59],
            index: 0,
            segment_start: 0,
            has_code: false,
            words: vec![],
            atomic_depth: 0,
            case_depth: 0,
            atomic_start: None,
        }
    }
    fn units(&self) -> &[u16] {
        &self.source.units
    }
    fn diagnostic(&mut self, range: Range<usize>, message: &'static str) {
        self.diagnostics.push(Diagnostic {
            span: self
                .source
                .span_utf16(range)
                .expect("diagnostic scalar boundaries"),
            message,
        });
    }
    fn matches(&self, value: &[u16], at: usize) -> bool {
        self.units().get(at..at + value.len()) == Some(value)
    }
    fn word(&self, at: usize, expected: &str) -> bool {
        let end = at + expected.encode_utf16().count();
        self.source.span_utf16(at..end).is_some_and(|span| {
            self.source.text[span.bytes].to_uppercase() == expected
                && (end == self.units().len() || !identifier_part(self.units()[end]))
        })
    }
    fn line_start(&self, position: usize) -> bool {
        for unit in self.units()[..position].iter().rev() {
            if matches!(unit, 10 | 13) {
                return true;
            }
            if !whitespace(*unit) {
                return false;
            }
        }
        true
    }
    fn scan(mut self) -> ParsedScript {
        while self.index < self.units().len() {
            let unit = self.units()[self.index];
            if whitespace(unit) {
                self.index += 1;
                continue;
            }
            if !self.has_code && self.line_start(self.index) && self.word(self.index, "DELIMITER") {
                self.delimiter_directive();
                continue;
            }
            if self.matches(&self.delimiter, self.index) {
                let length = self.delimiter.len();
                if self.atomic_depth == 0 {
                    self.finish(self.index, length);
                }
                self.index += length;
                if self.atomic_depth == 0 {
                    self.segment_start = self.index;
                }
                continue;
            }
            if self.matches(&[45, 45], self.index)
                && (self.dialect == Dialect::PostgreSQL
                    || self.index + 2 == self.units().len()
                    || whitespace(self.units()[self.index + 2]))
            {
                self.line_comment();
                continue;
            }
            if self.dialect == Dialect::MySQL && unit == 35 {
                self.line_comment();
                continue;
            }
            if self.matches(&[47, 42], self.index) {
                self.block_comment();
                continue;
            }
            if matches!(unit, 39 | 34) || (self.dialect == Dialect::MySQL && unit == 96) {
                self.quoted(unit);
                continue;
            }
            if self.dialect == Dialect::PostgreSQL
                && unit == 36
                && let Some(tag) = self.dollar_tag()
            {
                self.dollar_quote(&tag);
                continue;
            }
            if identifier_start(unit) {
                let start = self.index;
                self.index += 1;
                while self.index < self.units().len()
                    && identifier_part(self.units()[self.index])
                    && !self.matches(&self.delimiter, self.index)
                {
                    self.index += 1;
                }
                let range = start..self.index;
                let value = self.source.slice(range.clone()).to_uppercase();
                self.atomic_word(&value, &range);
                self.words.push((value, range));
                self.has_code = true;
                continue;
            }
            if (48..=57).contains(&unit) {
                self.index += 1;
                while self.index < self.units().len()
                    && ((48..=57).contains(&self.units()[self.index])
                        || self.units()[self.index] == 46)
                {
                    self.index += 1;
                }
                self.has_code = true;
                continue;
            }
            if unit == 92 {
                let start = self.index;
                self.index += 1;
                while self.index < self.units().len()
                    && !whitespace(self.units()[self.index])
                    && self.units()[self.index] != 59
                {
                    self.index += 1;
                }
                self.diagnostic(
                    start..self.index,
                    "psql and mysql client commands are not supported.",
                );
                self.has_code = true;
                continue;
            }
            self.has_code = true;
            self.index += 1;
        }
        if let Some(start) = self.atomic_start
            && self.atomic_depth > 0
        {
            self.diagnostic(
                start..self.units().len(),
                "Unterminated PostgreSQL BEGIN ATOMIC body.",
            );
        }
        self.finish(self.units().len(), 0);
        ParsedScript {
            statements: self.statements,
            editor_spans: self.editor_spans,
            diagnostics: self.diagnostics,
        }
    }
    fn atomic_word(&mut self, word: &str, range: &Range<usize>) {
        if self.dialect != Dialect::PostgreSQL {
            return;
        }
        let begins_atomic = word == "ATOMIC"
            && self.words.last().is_some_and(|w| w.0 == "BEGIN")
            && self.words.first().is_some_and(|w| w.0 == "CREATE")
            && self
                .words
                .iter()
                .any(|w| matches!(w.0.as_str(), "FUNCTION" | "PROCEDURE"));
        if begins_atomic {
            self.atomic_depth += 1;
            if self.atomic_start.is_none() {
                self.atomic_start = Some(self.words.last().map_or(range.start, |w| w.1.start));
            }
        } else if self.atomic_depth > 0 {
            if word == "CASE" {
                self.case_depth += 1;
            } else if word == "END" {
                if self.case_depth > 0 {
                    self.case_depth -= 1;
                } else {
                    self.atomic_depth -= 1;
                }
            }
        }
    }
    fn delimiter_directive(&mut self) {
        let start = self.index;
        while self.index < self.units().len() && !matches!(self.units()[self.index], 10 | 13) {
            self.index += 1;
        }
        // Foundation whitespacesAndNewlines trims Unicode whitespace, unlike SQL whitespace.
        let value = self
            .source
            .slice(start + 9..self.index)
            .trim_matches(|ch: char| ch.is_whitespace() || ch == '\u{200b}')
            .to_string();
        let delimiter: Vec<_> = value.encode_utf16().collect();
        if self.dialect != Dialect::MySQL
            || self.has_code
            || delimiter.is_empty()
            || delimiter.iter().any(|u| whitespace(*u))
            || delimiter.len() > 32
        {
            self.diagnostic(start..self.index, if self.dialect == Dialect::PostgreSQL { "DELIMITER is a MySQL script directive." } else { "Place DELIMITER and a delimiter without spaces on their own line between statements." });
            return;
        }
        self.delimiter = delimiter;
        self.segment_start = self.index;
        self.words.clear();
    }
    fn line_comment(&mut self) {
        while self.index < self.units().len() && !matches!(self.units()[self.index], 10 | 13) {
            self.index += 1;
        }
    }
    fn block_comment(&mut self) {
        let start = self.index;
        self.index += 2;
        let mut depth = 1;
        while self.index < self.units().len() {
            if self.dialect == Dialect::PostgreSQL && self.matches(&[47, 42], self.index) {
                depth += 1;
                self.index += 2;
            } else if self.matches(&[42, 47], self.index) {
                depth -= 1;
                self.index += 2;
                if depth == 0 {
                    break;
                }
            } else {
                self.index += 1;
            }
        }
        if depth != 0 {
            self.diagnostic(start..self.index, "Unterminated block comment.");
        }
    }
    fn quoted(&mut self, quote: u16) {
        let start = self.index;
        let postgres_escape = quote == 39
            && start > 0
            && matches!(self.units()[start - 1], 69 | 101)
            && (start < 2 || !identifier_part(self.units()[start - 2]));
        let escapes = (self.dialect == Dialect::MySQL && quote != 96) || postgres_escape;
        self.index += 1;
        let mut closed = false;
        while self.index < self.units().len() {
            if escapes && self.units()[self.index] == 92 {
                self.index = (self.index + 2).min(self.units().len());
            } else if self.units()[self.index] == quote {
                self.index += 1;
                if self.index < self.units().len() && self.units()[self.index] == quote {
                    self.index += 1;
                } else {
                    closed = true;
                    break;
                }
            } else {
                self.index += 1;
            }
        }
        self.has_code = true;
        if !closed {
            self.diagnostic(
                start..self.index,
                "Unterminated quoted value or identifier.",
            );
        }
    }
    fn dollar_tag(&self) -> Option<Vec<u16>> {
        if self.index > 0 && identifier_part(self.units()[self.index - 1]) {
            return None;
        }
        let mut end = self.index + 1;
        if self.units().get(end) == Some(&36) {
            return Some(vec![36, 36]);
        }
        if !self.units().get(end).is_some_and(|u| identifier_start(*u)) {
            return None;
        }
        while end < self.units().len()
            && (identifier_start(self.units()[end]) || (48..=57).contains(&self.units()[end]))
        {
            end += 1;
        }
        if self.units().get(end) != Some(&36) {
            return None;
        }
        Some(self.units()[self.index..=end].to_vec())
    }
    fn dollar_quote(&mut self, tag: &[u16]) {
        let start = self.index;
        self.index += tag.len();
        while self.index < self.units().len() && !self.matches(tag, self.index) {
            self.index += 1;
        }
        let closed = self.index < self.units().len();
        if closed {
            self.index += tag.len();
        }
        self.has_code = true;
        if !closed {
            self.diagnostic(
                start..self.index,
                "Unterminated PostgreSQL dollar-quoted value.",
            );
        }
    }
    fn finish(&mut self, end: usize, delimiter_length: usize) {
        if self.has_code {
            let mut lower = self.segment_start;
            let mut upper = end;
            while lower < upper && whitespace(self.units()[lower]) {
                lower += 1;
            }
            while upper > lower && whitespace(self.units()[upper - 1]) {
                upper -= 1;
            }
            if upper > lower {
                let range = lower..upper;
                self.statements.push(Statement {
                    sql: self.source.slice(range.clone()).into(),
                    span: self
                        .source
                        .span_utf16(range.clone())
                        .expect("statement scalar boundaries"),
                });
                self.editor_spans.push(
                    self.source
                        .span_utf16(lower..end + delimiter_length)
                        .expect("delimiter scalar boundaries"),
                );
                let names: Vec<_> = self.words.iter().map(|w| w.0.as_str()).collect();
                let client = names.first().is_some_and(|w| {
                    [
                        "SOURCE", "SYSTEM", "TEE", "NOTEE", "PAGER", "NOPAGER", "CONNECT", "QUIT",
                        "EXIT",
                    ]
                    .contains(w)
                });
                let copy = names.first() == Some(&"COPY")
                    && (names.contains(&"STDIN") || names.contains(&"STDOUT"));
                let local = names.starts_with(&["LOAD", "DATA"])
                    && names.iter().take(5).any(|w| *w == "LOCAL");
                if client {
                    self.diagnostic(
                        self.words[0].1.clone(),
                        "mysql client commands are not supported.",
                    );
                }
                if copy {
                    self.diagnostic(
                        range.clone(),
                        "Streaming COPY is not supported in SQL documents.",
                    );
                }
                if local {
                    self.diagnostic(range, "LOAD DATA LOCAL is not supported in SQL documents.");
                }
            }
        }
        self.has_code = false;
        self.words.clear();
        self.atomic_depth = 0;
        self.case_depth = 0;
        self.atomic_start = None;
    }
}

#[cfg(test)]
#[path = "sql_tests.rs"]
mod tests;
