import Foundation
import Testing
@testable import DBeer

/// Additive shared Swift/Rust execution expectations; run only at final integration.
struct SQLExecutionFixturesTests {
    private struct Span: Decodable {
        let bytes: [Int]
        let utf16: [Int]
        var range: NSRange { NSRange(location: utf16[0], length: utf16[1] - utf16[0]) }
    }
    private struct Statement: Decodable { let sql: String; let span: Span; let editorSpan: Span? }
    private struct Diagnostic: Decodable { let span: Span; let message: String }
    private struct Case: Decodable {
        let id: String; let engine: DatabaseEngine; let source: String
        let statements: [Statement]; let diagnostics: [Diagnostic]
    }
    private struct Fragment: Decodable {
        let kind: String; let sourceSQL: String; let span: Span; let statements: [Statement]
        let diagnostic: Diagnostic?; let firstLine: Int; let lastLine: Int
    }
    private struct Resolution: Decodable {
        let id: String; let engine: DatabaseEngine; let source: String
        let selectionUTF16: [Int]; let script: Bool; let expected: Fragment?
    }
    private struct LSP: Decodable { let line: Int; let character: Int
        var json: SQLLSPJSON { .object(["line": .int(line), "character": .int(character)]) }
    }
    private struct Position: Decodable { let byte: Int; let utf16: Int; let lsp: LSP? }
    private struct Coordinates: Decodable {
        let source: String; let positions: [Position]; let invalidUTF16: [Int]
        let invalidBytes: [Int]; let invalidLSP: [LSP]
    }
    private struct ErrorPosition: Decodable { let position: Int; let byte: Int; let utf16: Int }
    private struct Adapter: Decodable {
        let source: String; let engine: DatabaseEngine; let statement: Statement; let positions: [ErrorPosition]
    }
    private struct Fixtures: Decodable {
        let version: Int; let cases: [Case]; let resolutions: [Resolution]
        let coordinates: Coordinates; let adapter: Adapter
    }
    private func fixtures() throws -> Fixtures {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/sql-execution/v1.json")))
    }
    private func check(_ actual: SQLStatement, _ expected: Statement, source: String) {
        #expect(actual.sql == expected.sql)
        #expect(actual.range == expected.span.range)
        #expect((source as NSString).substring(with: actual.range) == expected.sql)
        let before = (source as NSString).substring(to: actual.range.location).utf8.count
        #expect([before, before + actual.sql.utf8.count] == expected.span.bytes)
    }
    private func check(_ actual: SQLDiagnostic, _ expected: Diagnostic) {
        #expect(actual.range == expected.span.range)
        #expect(actual.message == expected.message)
    }
    @Test func splitterMatchesSharedSQLSourceSpansEditorHitAreasAndDiagnostics() throws {
        let data = try fixtures()
        #expect(data.version == 1 && data.cases.count >= 40)
        for item in data.cases {
            let parsed = SQLScriptParser.parse(item.source, engine: item.engine)
            #expect(parsed.statements.count == item.statements.count, "\(item.id)")
            #expect(parsed.statementEditorRanges.count == item.statements.count)
            for (index, pair) in zip(parsed.statements, item.statements).enumerated() {
                check(pair.0, pair.1, source: item.source)
                #expect(parsed.statementEditorRanges[index] == pair.1.editorSpan?.range)
            }
            #expect(parsed.diagnostics.count == item.diagnostics.count, "\(item.id)")
            for pair in zip(parsed.diagnostics, item.diagnostics) { check(pair.0, pair.1) }
        }
    }
    @Test func resolverMatchesSharedSelectionsCaretBoundariesScriptAndOriginalSpans() throws {
        for item in try fixtures().resolutions {
            let selection = NSRange(location: item.selectionUTF16[0], length: item.selectionUTF16[1] - item.selectionUTF16[0])
            let actual = SQLExecutionFragment.resolve(text: item.source, selection: selection, engine: item.engine, script: item.script)
            guard let expected = item.expected else { #expect(actual == nil, "\(item.id)"); continue }
            let fragment = try #require(actual, "\(item.id)")
            let kind: SQLExecutionFragment.Kind = expected.kind == "script" ? .script : expected.kind == "selection" ? .selection : .statement
            #expect(fragment.kind == kind)
            #expect(fragment.sourceSQL == expected.sourceSQL)
            #expect(fragment.range == expected.span.range)
            let before = (item.source as NSString).substring(to: fragment.range.location).utf8.count
            #expect([before, before + fragment.sourceSQL.utf8.count] == expected.span.bytes)
            #expect(fragment.firstLine == expected.firstLine && fragment.lastLine == expected.lastLine)
            #expect(fragment.statements.count == expected.statements.count, "\(item.id)")
            for pair in zip(fragment.statements, expected.statements) { check(pair.0, pair.1, source: item.source) }
            if let diagnostic = expected.diagnostic { check(try #require(fragment.diagnostic), diagnostic) }
            else { #expect(fragment.diagnostic == nil) }
        }
    }
    @Test func sharedUTF16AndLSPPositionsPreserveScalarsCombiningMarksCRLFAndLineEnds() throws {
        let fixture = try fixtures().coordinates
        for position in fixture.positions {
            let before = (fixture.source as NSString).substring(to: position.utf16)
            #expect(before.utf8.count == position.byte)
            let actual = SQLLSPPosition.position(offset: position.utf16, in: fixture.source)
            if let lsp = position.lsp {
                #expect(actual?["line"]?.integer == lsp.line && actual?["character"]?.integer == lsp.character)
                #expect(SQLLSPPosition.offset(position: lsp.json, in: fixture.source) == position.utf16)
            } else { #expect(actual == nil) }
        }
        for offset in fixture.invalidUTF16 { #expect(SQLLSPPosition.position(offset: offset, in: fixture.source) == nil) }
        for position in fixture.invalidLSP { #expect(SQLLSPPosition.offset(position: position.json, in: fixture.source) == nil) }
        // Swift/LSP never accepts UTF-8 continuation-byte coordinates as editor offsets.
        for byte in fixture.invalidBytes {
            #expect(String(bytes: Array(fixture.source.utf8).prefix(byte), encoding: .utf8) == nil || byte > fixture.source.utf8.count)
        }
    }
    @Test func adapterScalarErrorPositionsMatchWorkspaceMappingInOriginalSource() throws {
        let fixture = try fixtures().adapter
        let parsed = SQLScriptParser.parse(fixture.source, engine: fixture.engine)
        #expect(parsed.statements.count == 1)
        let statement = try #require(parsed.statements.first)
        check(statement, fixture.statement, source: fixture.source)
        for position in fixture.positions {
            let scalars = statement.sql.unicodeScalars
            let end = scalars.index(scalars.startIndex, offsetBy: min(max(0, position.position - 1), scalars.count))
            let utf16 = statement.range.location + String(scalars[..<end]).utf16.count
            #expect(utf16 == position.utf16)
            #expect((fixture.source as NSString).substring(to: utf16).utf8.count == position.byte)
        }
    }
}
