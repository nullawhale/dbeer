import Foundation

struct SQLStatement: Equatable, Sendable {
    let sql: String
    /// Cocoa editor offsets, measured in UTF-16 code units.
    let range: NSRange
}

struct SQLToken: Equatable, Sendable {
    enum Kind: Sendable { case keyword, string, identifier, number, comment }
    let range: NSRange
    let kind: Kind
}

struct SQLDiagnostic: Equatable, Sendable {
    let range: NSRange
    let message: String
}

struct SQLParseResult: Sendable {
    let statements: [SQLStatement]
    /// Cursor hit areas include client delimiters, which are never sent to the server.
    let statementEditorRanges: [NSRange]
    let tokens: [SQLToken]
    let diagnostics: [SQLDiagnostic]

    func statement(atUTF16 location: Int) -> SQLStatement? {
        statements.first { location >= $0.range.location && location <= NSMaxRange($0.range) } ??
            zip(statements, statementEditorRanges).first {
                location >= $0.1.location && location <= NSMaxRange($0.1)
            }?.0 ??
            statements.first { $0.range.location > location } ?? statements.last
    }
}

/// Splits server SQL without interpreting client commands. Ranges always refer
/// to the original document, including after MySQL DELIMITER directives.
enum SQLScriptParser {
    static let keywords = ["SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AS",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "ALTER", "DROP", "TABLE", "VIEW",
        "INDEX", "SCHEMA", "DATABASE", "FUNCTION", "PROCEDURE", "TRIGGER", "RETURNS", "RETURN", "LANGUAGE",
        "BEGIN", "ATOMIC", "END", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "IF", "THEN", "ELSE", "LOOP", "WHILE",
        "DECLARE", "WITH", "RECURSIVE", "UNION", "ALL", "DISTINCT", "GROUP", "BY", "HAVING", "ORDER", "LIMIT",
        "OFFSET", "ASC", "DESC", "NULL", "TRUE", "FALSE", "AND", "OR", "NOT", "IS", "IN", "EXISTS", "CASE",
        "WHEN", "DEFAULT", "PRIMARY", "KEY", "REFERENCES", "CONSTRAINT", "EXPLAIN", "ANALYZE", "DELIMITER"]
    static let cqlKeywords = ["SELECT", "FROM", "WHERE", "AS", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "ALTER", "DROP", "TABLE", "MATERIALIZED", "VIEW", "INDEX", "KEYSPACE", "TYPE", "FUNCTION", "AGGREGATE", "TRUNCATE", "USE", "BEGIN", "UNLOGGED", "COUNTER", "BATCH", "APPLY", "IF", "EXISTS", "NOT", "IN", "AND", "OR", "IS", "NULL", "TRUE", "FALSE", "PRIMARY", "KEY", "WITH", "CLUSTERING", "ORDER", "BY", "ASC", "DESC", "LIMIT", "PER", "PARTITION", "ALLOW", "FILTERING", "USING", "TTL", "TIMESTAMP", "STATIC", "FROZEN", "CONTAINS", "TOKEN", "JSON", "DISTINCT", "GROUP", "ANN", "OF", "TO"]
    static func keywords(for engine: DatabaseEngine) -> [String] { engine == .cassandra ? cqlKeywords : keywords }

    static func parse(_ text: String, engine: DatabaseEngine) -> SQLParseResult {
        Scanner(text: text, engine: engine).scan()
    }

    static func selectedStatement(in text: String, selection: NSRange, engine: DatabaseEngine) -> SQLStatement? {
        let source = text as NSString
        guard selection.location != NSNotFound, selection.location <= source.length else { return nil }
        let safe = NSRange(location: selection.location, length: min(selection.length, source.length - selection.location))
        if safe.length == 0 { return parse(text, engine: engine).statement(atUTF16: safe.location) }
        let units = Array(text.utf16)
        var lower = safe.location
        var upper = NSMaxRange(safe)
        while lower < upper, isWhitespace(units[lower]) { lower += 1 }
        while upper > lower, isWhitespace(units[upper - 1]) { upper -= 1 }
        guard upper > lower else { return nil }
        let range = NSRange(location: lower, length: upper - lower)
        return SQLStatement(sql: source.substring(with: range), range: range)
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 32 || (9...13).contains(unit) || unit == 0xA0
    }

    private final class Scanner {
        let text: NSString
        let units: [UInt16]
        let engine: DatabaseEngine
        var statements: [SQLStatement] = []
        var statementEditorRanges: [NSRange] = []
        var tokens: [SQLToken] = []
        var diagnostics: [SQLDiagnostic] = []
        var delimiter: [UInt16] = [59]
        var index = 0
        var segmentStart = 0
        var hasCode = false
        var words: [(String, NSRange)] = []
        var atomicDepth = 0
        var caseDepth = 0
        var atomicStart: Int?
        var cqlBatchStart: Int?
        var cqlBatchOpen = false

        init(text: String, engine: DatabaseEngine) {
            self.text = text as NSString
            units = Array(text.utf16)
            self.engine = engine
        }

        func scan() -> SQLParseResult {
            while index < units.count {
                if SQLScriptParser.isWhitespace(units[index]) { index += 1; continue }
                if !hasCode, isLineStart(index), word(at: index, is: "DELIMITER") {
                    scanDelimiterDirective()
                    continue
                }
                if matches(delimiter, at: index) {
                    if atomicDepth > 0 || cqlBatchOpen { index += delimiter.count; continue }
                    finishStatement(at: index, delimiterLength: delimiter.count)
                    index += delimiter.count
                    segmentStart = index
                    continue
                }
                if matches([45, 45], at: index), engine != .mysql || index + 2 == units.count ||
                    SQLScriptParser.isWhitespace(units[index + 2]) {
                    scanLineComment()
                    continue
                }
                if engine == .cassandra, matches([47, 47], at: index) { scanLineComment(); continue }
                if engine == .mysql, units[index] == 35 { scanLineComment(); continue }
                if matches([47, 42], at: index) { scanBlockComment(); continue }
                let unit = units[index]
                if unit == 39 || unit == 34 || (engine == .mysql && unit == 96) {
                    scanQuoted(unit)
                    continue
                }
                if engine == .postgresql || (engine == .cassandra && matches([36, 36], at: index)), unit == 36, let tag = dollarTag(at: index) {
                    scanDollarQuote(tag)
                    continue
                }
                if isIdentifierStart(unit) {
                    let start = index
                    index += 1
                    while index < units.count, isIdentifierPart(units[index]), !matches(delimiter, at: index) { index += 1 }
                    let range = NSRange(location: start, length: index - start)
                    let value = text.substring(with: range).uppercased()
                    tokens.append(SQLToken(range: range, kind: SQLScriptParser.keywords(for: engine).contains(value) ? .keyword : .identifier))
                    trackAtomicBody(word: value, range: range)
                    trackCQLBatch(word: value, range: range)
                    words.append((value, range))
                    hasCode = true
                    continue
                }
                if (48...57).contains(unit) {
                    let start = index
                    index += 1
                    while index < units.count, (48...57).contains(units[index]) || units[index] == 46 { index += 1 }
                    tokens.append(SQLToken(range: NSRange(location: start, length: index - start), kind: .number))
                    hasCode = true
                    continue
                }
                if unit == 92 {
                    let start = index
                    index += 1
                    while index < units.count, !SQLScriptParser.isWhitespace(units[index]), units[index] != 59 { index += 1 }
                    diagnostics.append(SQLDiagnostic(range: NSRange(location: start, length: max(1, index - start)),
                        message: "psql and mysql client commands are not supported."))
                    hasCode = true
                    continue
                }
                hasCode = true
                index += 1
            }
            if let atomicStart, atomicDepth > 0 {
                diagnostics.append(SQLDiagnostic(range: NSRange(location: atomicStart, length: units.count - atomicStart),
                    message: "Unterminated PostgreSQL BEGIN ATOMIC body."))
            }
            if cqlBatchOpen, let cqlBatchStart {
                diagnostics.append(SQLDiagnostic(range: NSRange(location: cqlBatchStart, length: units.count - cqlBatchStart),
                    message: "Unterminated CQL batch. End the batch with APPLY BATCH."))
            }
            finishStatement(at: units.count)
            return SQLParseResult(statements: statements, statementEditorRanges: statementEditorRanges,
                tokens: tokens, diagnostics: diagnostics)
        }

        private func trackCQLBatch(word: String, range: NSRange) {
            guard engine == .cassandra, word == "BATCH" else { return }
            if cqlBatchOpen, words.last?.0 == "APPLY" { cqlBatchOpen = false; return }
            let prefix = words.map(\.0)
            if prefix == ["BEGIN"] || prefix == ["BEGIN", "UNLOGGED"] || prefix == ["BEGIN", "COUNTER"] {
                cqlBatchOpen = true
                cqlBatchStart = words.first?.1.location ?? range.location
            }
        }

        private func trackAtomicBody(word: String, range: NSRange) {
            guard engine == .postgresql else { return }
            let beginsAtomic = word == "ATOMIC" && words.last?.0 == "BEGIN" &&
                words.first?.0 == "CREATE" && words.contains(where: { $0.0 == "FUNCTION" || $0.0 == "PROCEDURE" })
            if beginsAtomic {
                atomicDepth += 1
                if atomicStart == nil { atomicStart = words.last?.1.location ?? range.location }
            } else if atomicDepth > 0 {
                if word == "CASE" { caseDepth += 1 }
                else if word == "END" {
                    if caseDepth > 0 { caseDepth -= 1 }
                    else { atomicDepth -= 1 }
                }
            }
        }

        private func matches(_ value: [UInt16], at position: Int) -> Bool {
            guard position + value.count <= units.count else { return false }
            for offset in value.indices where units[position + offset] != value[offset] { return false }
            return true
        }

        private func word(at position: Int, is expected: String) -> Bool {
            let count = expected.utf16.count
            guard position + count <= units.count,
                  text.substring(with: NSRange(location: position, length: count)).uppercased() == expected else { return false }
            return position + count == units.count || !isIdentifierPart(units[position + count])
        }

        private func isLineStart(_ position: Int) -> Bool {
            var previous = position
            while previous > 0 {
                previous -= 1
                if units[previous] == 10 || units[previous] == 13 { return true }
                if !SQLScriptParser.isWhitespace(units[previous]) { return false }
            }
            return true
        }

        private func scanDelimiterDirective() {
            let start = index
            while index < units.count, units[index] != 10, units[index] != 13 { index += 1 }
            let range = NSRange(location: start, length: index - start)
            let value = text.substring(with: NSRange(location: start + 9, length: max(0, index - start - 9)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard engine == .mysql, !hasCode, !value.isEmpty,
                  !value.utf16.contains(where: SQLScriptParser.isWhitespace), value.utf16.count <= 32 else {
                diagnostics.append(SQLDiagnostic(range: range,
                    message: engine == .postgresql ? "DELIMITER is a MySQL script directive." :
                        "Place DELIMITER and a delimiter without spaces on their own line between statements."))
                return
            }
            delimiter = Array(value.utf16)
            tokens.append(SQLToken(range: range, kind: .keyword))
            segmentStart = index
            words.removeAll()
        }

        private func scanLineComment() {
            let start = index
            while index < units.count, units[index] != 10, units[index] != 13 { index += 1 }
            tokens.append(SQLToken(range: NSRange(location: start, length: index - start), kind: .comment))
        }

        private func scanBlockComment() {
            let start = index
            index += 2
            var depth = 1
            while index < units.count {
                if engine == .postgresql, matches([47, 42], at: index) { depth += 1; index += 2 }
                else if matches([42, 47], at: index) {
                    depth -= 1
                    index += 2
                    if depth == 0 { break }
                } else { index += 1 }
            }
            let range = NSRange(location: start, length: index - start)
            tokens.append(SQLToken(range: range, kind: .comment))
            if depth != 0 { diagnostics.append(SQLDiagnostic(range: range, message: "Unterminated block comment.")) }
        }

        private func scanQuoted(_ quote: UInt16) {
            let start = index
            let postgresEscape = engine == .postgresql && quote == 39 && start > 0 && (units[start - 1] == 69 || units[start - 1] == 101) &&
                (start < 2 || !isIdentifierPart(units[start - 2]))
            let escapes = (engine == .mysql && quote != 96) || postgresEscape
            index += 1
            var closed = false
            while index < units.count {
                if escapes, units[index] == 92 { index = min(index + 2, units.count) }
                else if units[index] == quote {
                    index += 1
                    if index < units.count, units[index] == quote { index += 1 }
                    else { closed = true; break }
                } else { index += 1 }
            }
            let range = NSRange(location: start, length: index - start)
            let kind: SQLToken.Kind = quote == 39 || (engine == .mysql && quote == 34) ? .string : .identifier
            tokens.append(SQLToken(range: range, kind: kind))
            hasCode = true
            if !closed { diagnostics.append(SQLDiagnostic(range: range, message: "Unterminated quoted value or identifier.")) }
        }

        private func dollarTag(at position: Int) -> [UInt16]? {
            guard position == 0 || !isIdentifierPart(units[position - 1]) else { return nil }
            var end = position + 1
            if end < units.count, units[end] == 36 { return [36, 36] }
            guard end < units.count, isIdentifierStart(units[end]) else { return nil }
            while end < units.count, isIdentifierStart(units[end]) || (48...57).contains(units[end]) { end += 1 }
            guard end < units.count, units[end] == 36 else { return nil }
            return Array(units[position...end])
        }

        private func scanDollarQuote(_ tag: [UInt16]) {
            let start = index
            index += tag.count
            while index < units.count, !matches(tag, at: index) { index += 1 }
            let closed = index < units.count
            if closed { index += tag.count }
            let range = NSRange(location: start, length: index - start)
            tokens.append(SQLToken(range: range, kind: .string))
            hasCode = true
            if !closed { diagnostics.append(SQLDiagnostic(range: range, message: "Unterminated PostgreSQL dollar-quoted value.")) }
        }

        private func finishStatement(at end: Int, delimiterLength: Int = 0) {
            defer { hasCode = false; words.removeAll(); atomicDepth = 0; caseDepth = 0; atomicStart = nil; cqlBatchStart = nil; cqlBatchOpen = false }
            guard hasCode else { return }
            var lower = segmentStart
            var upper = end
            while lower < upper, SQLScriptParser.isWhitespace(units[lower]) { lower += 1 }
            while upper > lower, SQLScriptParser.isWhitespace(units[upper - 1]) { upper -= 1 }
            guard upper > lower else { return }
            let range = NSRange(location: lower, length: upper - lower)
            statements.append(SQLStatement(sql: text.substring(with: range), range: range))
            statementEditorRanges.append(NSRange(location: lower, length: end + delimiterLength - lower))
            let names = words.map(\.0)
            if let first = names.first, ["SOURCE", "SYSTEM", "TEE", "NOTEE", "PAGER", "NOPAGER", "CONNECT", "QUIT", "EXIT"].contains(first) {
                diagnostics.append(SQLDiagnostic(range: words[0].1, message: "mysql client commands are not supported."))
            }
            if names.first == "COPY", names.contains("STDIN") || names.contains("STDOUT") {
                diagnostics.append(SQLDiagnostic(range: range, message: "Streaming COPY is not supported in SQL documents."))
            }
            if names.starts(with: ["LOAD", "DATA"]), names.prefix(5).contains("LOCAL") {
                diagnostics.append(SQLDiagnostic(range: range, message: "LOAD DATA LOCAL is not supported in SQL documents."))
            }
        }

        private func isIdentifierStart(_ unit: UInt16) -> Bool {
            (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit > 127
        }

        private func isIdentifierPart(_ unit: UInt16) -> Bool {
            isIdentifierStart(unit) || (48...57).contains(unit) || unit == 36
        }
    }
}
