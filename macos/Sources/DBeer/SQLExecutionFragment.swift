import Foundation

/// One resolver feeds the execution preview and every SQL launch path. All
/// ranges use the original document's UTF-16 offsets, including selections.
struct SQLExecutionFragment: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case selection, statement, script }
    let kind: Kind
    let sourceSQL: String
    let range: NSRange
    let statements: [SQLStatement]
    let diagnostic: SQLDiagnostic?
    let firstLine: Int
    let lastLine: Int

    var summary: String {
        let title = switch kind {
        case .selection: "Selection"
        case .statement: "Current statement"
        case .script: "Entire script"
        }
        let lines = firstLine == lastLine ? "line \(firstLine)" : "lines \(firstLine)–\(lastLine)"
        return "\(title) · \(lines) · \(statements.count) \(statements.count == 1 ? "statement" : "statements")"
    }

    static func resolve(text: String, selection: NSRange, engine: DatabaseEngine, script: Bool = false) -> Self? {
        let selected: SQLStatement
        let kind: Kind
        if script {
            selected = SQLStatement(sql: text, range: NSRange(location: 0, length: text.utf16.count))
            kind = .script
        } else {
            guard let fragment = SQLScriptParser.selectedStatement(in: text, selection: selection, engine: engine) else { return nil }
            selected = fragment
            kind = selection.length > 0 ? .selection : .statement
        }
        let parsed = SQLScriptParser.parse(selected.sql, engine: engine)
        let statements = parsed.statements.map { statement in
            SQLStatement(sql: statement.sql, range: NSRange(location: selected.range.location + statement.range.location,
                length: statement.range.length))
        }
        let diagnostic = parsed.diagnostics.first.map { diagnostic in
            SQLDiagnostic(range: NSRange(location: selected.range.location + diagnostic.range.location,
                length: diagnostic.range.length), message: diagnostic.message)
        }
        let units = Array(text.utf16)
        let start = min(selected.range.location, units.count)
        let end = min(NSMaxRange(selected.range), units.count)
        let firstLine = 1 + units[..<start].filter { $0 == 10 }.count
        let lastLine = firstLine + units[start..<end].filter { $0 == 10 }.count
        return Self(kind: kind, sourceSQL: selected.sql, range: selected.range, statements: statements,
            diagnostic: diagnostic, firstLine: firstLine, lastLine: lastLine)
    }
}
