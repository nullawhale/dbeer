import Foundation
import Testing
@testable import DBeer

// Pure parsing and model coverage: no AppKit objects, windows or desktop interaction.
struct ValueInspectorTests {
    private func value(_ text: String, type: String = "jsonb", kind: String = "text") -> InspectedValue {
        InspectedValue(row: 0, column: 0, name: "fixture", nativeType: type,
            value: ChangeValue(kind: kind, value: text))
    }

    @Test func formattingPreservesExactNumbersDuplicateKeysAndEscapedStrings() throws {
        let source = #" {"n":9007199254740993.123456789,"n":-0.0000e+9999,"a":["\u0061","🧪",true,null,{},[]]} "#
        let snapshot = value(source)
        let content = try ValueInspectorProcessing.prepare(snapshot)
        let formatted = try #require(content.formatted)
        #expect(formatted.contains("9007199254740993.123456789"))
        #expect(formatted.contains("-0.0000e+9999"))
        #expect(formatted.components(separatedBy: #""n""#).count == 3)
        #expect(formatted.contains(#""\u0061""#))
        #expect(formatted.contains("{}") && formatted.contains("[]"))
        #expect(snapshot.text == source)
        #expect(content.notice == nil)
        let rawLexemes = content.tokens.map { (source as NSString).substring(with: $0.range) }
        let prettyLexemes = content.formattedTokens.map { (formatted as NSString).substring(with: $0.range) }
        #expect(rawLexemes == prettyLexemes)
        #expect(rawLexemes.contains(#""🧪""#))
        #expect(content.tokens.filter { $0.kind == .key }.count == 3)
        #expect(content.tokens.filter { $0.kind == .number }.count == 2)
    }

    @Test(arguments: ["null", "true", "false", "1e9999", "-0", #""🧪\n\u0041""#, "{}", "[]"])
    func supportsJSONScalarAndEmptyValues(_ source: String) throws {
        let content = try ValueInspectorProcessing.prepare(value(source, type: "json"))
        #expect(content.formatted == source)
        #expect(content.notice == nil)
    }

    @Test(arguments: ["{", "[1,]", #"{"x":1,}"#, "01", "+1", "1.", ".1", "1e", "NaN", "true false",
        #"{"x" 1}"#, #"{"x":"\q"}"#, #"{"x":"\u00XZ"}"#, "\"raw\nnewline\"", "[}"])
    func malformedJSONKeepsTheOriginalWithoutAPrettyPreview(_ source: String) throws {
        let snapshot = value(source)
        let content = try ValueInspectorProcessing.prepare(snapshot)
        #expect(content.formatted == nil)
        #expect(content.tokens.isEmpty)
        #expect(content.notice != nil)
        #expect(snapshot.text == source)
    }

    @Test func XMLUsesUTF16RangesAndNeverExpandsDTDOrExternalEntities() throws {
        let source = #"<root label="🧪"><!-- comment --><item>café &amp; tea</item><![CDATA[<raw>]]></root>"#
        let content = try ValueInspectorProcessing.prepare(value(source, type: "xml"))
        #expect(content.notice == nil)
        #expect(content.formatted == nil)
        let lexemes = content.tokens.map { (source as NSString).substring(with: $0.range) }
        #expect(lexemes.contains(#"<root label="🧪">"#))
        #expect(lexemes.contains("<!-- comment -->"))
        #expect(lexemes.contains("<![CDATA[<raw>]]>"))
        #expect(content.tokens.contains { $0.kind == .comment })
        for source in [
            #"<!DOCTYPE root SYSTEM "file:///synthetic/private.xml"><root/>"#,
            #"<!DOCTYPE root [<!ENTITY remote SYSTEM "https://example.invalid/entity">]><root>&remote;</root>"#,
            #"<!DOCTYPE root [<!ENTITY bomb "&bomb;&bomb;">]><root>&bomb;</root>"#,
            "<root><mismatch></root>"
        ] {
            let content = try ValueInspectorProcessing.prepare(value(source, type: "xml"))
            #expect(content.notice != nil)
            #expect(content.tokens.isEmpty)
            #expect(content.formatted == nil)
        }
    }

    @Test func limitsKeepFullSourceAvailable() throws {
        for source in [String(repeating: "[", count: 129) + "0" + String(repeating: "]", count: 129),
            "[" + Array(repeating: "0", count: 25_000).joined(separator: ",") + "]",
            String(repeating: "x", count: ValueInspectorProcessing.maximumBytes + 1)] {
            let snapshot = value(source)
            let content = try ValueInspectorProcessing.prepare(snapshot)
            #expect(content.formatted == nil)
            #expect(content.notice != nil)
            #expect(snapshot.text == source)
        }
    }

    @Test func literalUnicodeSearchIsCaseInsensitiveAndBounded() throws {
        let source = "🧪 café\nCAFÉ [a-z].*"
        let ranges = try ValueInspectorProcessing.matches(in: source, query: "café")
        #expect(ranges.count == 2)
        #expect(ranges.first?.location == 3)
        #expect(ranges.map { (source as NSString).substring(with: $0) } == ["café", "CAFÉ"])
        #expect(try ValueInspectorProcessing.matches(in: source, query: "[a-z].*").count == 1)
        #expect(try ValueInspectorProcessing.matches(in: source, query: "").isEmpty)
        #expect(try ValueInspectorProcessing.matches(in: String(repeating: "a", count: 20_000), query: "a").count == 10_000)
    }

    @Test func capturePreservesTypesColumnOrdinalsAndEmptyValues() throws {
        let columns = [ResultColumn(index: 0, name: "same", nativeType: "text"),
            ResultColumn(index: 1, name: "same", nativeType: "bytea", encoding: "base64")]
        let rows: [[String?]] = [[nil, ""], ["NULL", "AP8="], ["", "<DEFAULT>"]]
        let kinds = [["null", "binary"], ["text", "binary"], ["text", "default"]]
        func capture(_ row: Int, _ column: Int) throws -> InspectedValue {
            try #require(InspectedValue.capture(cell: ResultGridCell(row: row, column: column),
                columns: columns, rows: rows, valueKinds: kinds))
        }
        #expect(try capture(0, 0).description == "SQL NULL")
        #expect(try capture(1, 0).description == "Text")
        #expect(try capture(2, 0).description == "Empty string")
        #expect(try capture(0, 1).description == "Empty binary · Base64")
        #expect(try capture(1, 1).value == ChangeValue(kind: "binary", value: "AP8="))
        #expect(try capture(2, 1).value == .default)
        #expect(try capture(2, 1).column == 1)
        #expect(InspectedValue.capture(cell: nil, columns: columns, rows: rows) == nil)
        #expect(InspectedValue.capture(cell: ResultGridCell(row: 3, column: 0), columns: columns, rows: rows) == nil)
        #expect(InspectedValue.capture(cell: ResultGridCell(row: 0, column: -1), columns: columns, rows: rows) == nil)
        #expect(InspectedValue.capture(cell: ResultGridCell(row: 0, column: 1), columns: columns, rows: [["short"]]) == nil)
    }

    @Test func queryResultsInferBinaryAndNeverParseSpecialValuesAsMarkup() throws {
        let binary = try #require(InspectedValue.capture(cell: ResultGridCell(row: 0, column: 0),
            columns: [ResultColumn(index: 0, name: "binary", encoding: "base64")], rows: [["AP8="]]))
        #expect(binary.value.kind == "binary")
        for kind in ["binary", "null", "default"] {
            let content = try ValueInspectorProcessing.prepare(value("{\"n\":1}", kind: kind))
            #expect(content.tokens.isEmpty)
            #expect(content.formatted == nil)
        }
    }

    @Test func canonicallyEquivalentTextRetainsItsExactSourceEncoding() {
        let composed = value("é", type: "text")
        let decomposed = value("e\u{301}", type: "text")
        #expect(composed.text == decomposed.text)
        #expect(composed != decomposed)
    }

    @Test func cancelledParsingAndSearchStopBeforePublishing() async throws {
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try ValueInspectorProcessing.prepare(value("{}"))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let search = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try ValueInspectorProcessing.matches(in: "fixture", query: "fixture")
        }
        search.cancel()
        await #expect(throws: CancellationError.self) { try await search.value }
    }
}

@MainActor
struct ValueInspectorModelTests {
    private nonisolated static func backgroundPreview(_ value: InspectedValue) throws -> InspectorContent {
        #expect(!Thread.isMainThread)
        return try ValueInspectorProcessing.prepare(value)
    }

    private actor Gate {
        var waiting: [String: CheckedContinuation<InspectorContent, Never>] = [:]
        func prepare(_ value: InspectedValue) async -> InspectorContent {
            await withCheckedContinuation { waiting[value.name] = $0 }
        }
        func contains(_ key: String) -> Bool { waiting[key] != nil }
        func finish(_ key: String) { waiting.removeValue(forKey: key)?.resume(returning: InspectorContent(formatted: key)) }
    }

    private func value(_ name: String, text: String = "{\"n\":1}") -> InspectedValue {
        InspectedValue(row: 0, column: 0, name: name, nativeType: "json", value: ChangeValue(kind: "text", value: text))
    }

    private func wait(_ gate: Gate, for key: String) async throws {
        for _ in 0..<200 {
            if await gate.contains(key) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Preview worker did not start")
    }

    @Test func staleWorkersCannotReplaceANewerCellOrClearedSelection() async throws {
        let gate = Gate()
        let model = ValueInspectorModel(worker: { await gate.prepare($0) })
        let first = model.select(value("first"))
        try await wait(gate, for: "first")
        let second = model.select(value("second"))
        try await wait(gate, for: "second")
        await gate.finish("second")
        await second?.value
        #expect(model.selection?.name == "second")
        #expect(model.content.formatted == "second")
        await gate.finish("first")
        await first?.value
        #expect(model.content.formatted == "second")
        let third = model.select(value("third"))
        try await wait(gate, for: "third")
        model.select(nil)
        await gate.finish("third")
        await third?.value
        #expect(model.selection == nil && !model.isProcessing)
        #expect(model.text.isEmpty && model.content.formatted == nil)
    }

    @Test func previewRunsOffMainAndModeSearchAndNavigationNeverMutateSource() async throws {
        let model = ValueInspectorModel(worker: { value in
            try Self.backgroundPreview(value)
        })
        let source = #"{"n":9007199254740993,"n":1}"#
        await model.select(value("fixture", text: source))?.value
        #expect(model.text == source)
        model.formatted = true
        #expect(model.text.contains("\n"))
        #expect(model.selection?.text == source)
        model.query = "n"
        await model.search().value
        #expect(model.matches.count == 2)
        model.moveMatch(-1)
        #expect(model.matchIndex == 1)
        model.moveMatch(1)
        #expect(model.matchIndex == 0)
        model.formatted = false
        await model.search().value
        #expect(model.text == source)
        #expect(model.matches.first?.location == 2)
        model.cancel()
        #expect(model.selection == nil && model.matches.isEmpty)
        await model.select(value("fixture", text: source))?.value
        #expect(model.content.formatted != nil)
    }

    @Test func inspectingStagedValuesDoesNotChangeGridEditsOrOtherInspectors() async throws {
        let grid = GridDraft(reference: TableReference(schema: "public", name: "fixture", kind: "table"),
            result: BackendMessage(type: "query.result", requestId: "fixture",
                columns: [ResultColumn(index: 0, name: "value", nativeType: "jsonb")], rows: [["{\"n\":1}"]]),
            metadata: [["name": "value", "editable": "true", "primaryKey": "1"]])
        let first = ValueInspectorModel()
        let second = ValueInspectorModel()
        func selected() throws -> InspectedValue {
            try #require(InspectedValue.capture(cell: ResultGridCell(row: 0, column: 0), columns: grid.columns,
                rows: grid.presentation.rows, valueKinds: grid.presentation.valueKinds))
        }
        await first.select(try selected())?.value
        await second.select(try selected())?.value
        first.formatted = true
        first.query = "n"
        await first.search().value
        #expect(grid.pendingCount == 0)
        grid.set(.default, row: 0, column: 0)
        let request = grid.request()
        await first.select(try selected())?.value
        #expect(first.selection?.value == .default)
        #expect(first.text == "DEFAULT" && first.content.formatted == nil)
        #expect(second.selection?.value.value == "{\"n\":1}")
        #expect(grid.request() == request && grid.pendingCount == 1)
        #expect(grid.rows[0].original?.first?.value == "{\"n\":1}")
    }
}
