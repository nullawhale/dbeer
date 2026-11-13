import AppKit
import Foundation
import Testing
@testable import DBeer

/// Local values, model objects and a private pasteboard only; no window or desktop actions.
struct NativeConsumerValueTests {
    private let column = ResultColumn(index: 0, name: "value", typeOid: 1700, nativeType: "numeric")

    private func payload(_ values: [NativeValue], column: ResultColumn? = nil) throws -> ResultClipboardPayload {
        try ResultCopy.selection(columns: [column ?? self.column], rows: values.map { _ in ["display is not authority"] },
            valueKinds: values.map { _ in ["unresolved"] }, nativeValues: values.map { [$0] },
            rowIndices: Array(values.indices), columnIndices: [0])
    }

    @Test func selectionAndJSONPreserveNativeOrderDuplicatesAndExactValues() throws {
        let object = NativeValue(kind: "object", entries: [
            .init(key: .init(kind: "text", value: "n"), value: .init(kind: "integer", value: "9007199254740993")),
            .init(key: .init(kind: "text", value: "n"), value: .init(kind: "decimal", value: "0.000000000000000001"))])
        let matrix = [[NativeValue(kind: "integer", value: "9007199254740993"), object],
                      [NativeValue(kind: "null"), NativeValue(kind: "binary", value: "AP8=")]]
        let columns = [column, ResultColumn(index: 1, name: "value", nativeType: "document")]
        let selected = try ResultCopy.selection(columns: columns, rows: [["wrong", "wrong"], ["wrong", "wrong"]],
            valueKinds: [["unresolved", "unresolved"], ["unresolved", "unresolved"]], nativeValues: matrix,
            rowIndices: [1, 0], columnIndices: [1, 0])
        #expect(selected.version == 2 && selected.sourceRows == [1, 0] && selected.sourceColumnIndices == [1, 0])
        #expect(selected.nativeValues == [[matrix[1][1], matrix[1][0]], [matrix[0][1], matrix[0][0]]])
        #expect(selected.values[0][0].kind == .binary && selected.values[0][0].value == "AP8=")
        #expect(selected.values[0][1].kind == .null && selected.values[1][1].value == "9007199254740993")
        let json = try ResultCopy.text(selected, format: .json, includesHeaders: false)
        let decoded = try JSONDecoder().decode(ResultClipboardPayload.self, from: Data(json.utf8))
        try ResultCopy.validate(decoded)
        #expect(decoded.nativeValues == selected.nativeValues)
        #expect(decoded.nativeValues?[1][0].entries?.map(\.key.value) == ["n", "n"])
        #expect(try ResultCopy.text(selected, format: .tsv, includesHeaders: false).hasPrefix("<BINARY:AP8=>\t\\N"))
        var altered = selected
        altered = .init(version: altered.version, columns: altered.columns, sourceRows: altered.sourceRows,
            sourceColumnIndices: altered.sourceColumnIndices,
            values: [[.init(kind: .binary, value: "AP8="), .init(kind: .null, value: nil)],
                     [altered.values[1][0], .init(kind: .text, value: "rounded")]], nativeValues: altered.nativeValues)
        #expect(throws: (any Error).self) { try ResultCopy.validate(altered) }
    }

    @Test func inspectionRetainsRecursiveEvidenceAndFloatBits() throws {
        let object = NativeValue(kind: "object", entries: [
            .init(key: .init(kind: "text", value: "é"), value: .init(kind: "integer", value: "9007199254740993")),
            .init(key: .init(kind: "text", value: "e\u{301}"), value: .init(kind: "text", value: "NULL"))])
        let captured = try #require(InspectedValue.capture(cell: .init(row: 0, column: 0), columns: [column],
            rows: [["not the original"]], valueKinds: [["unresolved"]], nativeValues: [[object]]))
        #expect(captured.nativeValue == object && captured.description.contains("duplicate keys"))
        let original = captured.text
        let content = try ValueInspectorProcessing.prepare(captured)
        let formatted = try #require(content.formatted)
        #expect(try JSONDecoder().decode(NativeValue.self, from: Data(formatted.utf8)) == object)
        #expect(captured.text == original && captured.text.contains("9007199254740993"))
        let negativeZero = NativeValue(kind: "float64", value: "8000000000000000")
        let float = try #require(InspectedValue.capture(cell: .init(row: 0, column: 0), columns: [column],
            rows: [["0"]], nativeValues: [[negativeZero]]))
        #expect(float.text == "-0.0" && float.description.contains("8000000000000000"))
        let opaque = NativeValue(kind: "opaque", value: "AP8=", engine: "postgresql", nativeType: "custom")
        let unavailable = try #require(InspectedValue.capture(cell: .init(row: 0, column: 0), columns: [column],
            rows: [["display"]], nativeValues: [[opaque]]))
        #expect(unavailable.description.contains("Semantics unavailable"))
        #expect(try ValueInspectorProcessing.prepare(unavailable).notice != nil)
        #expect(InspectedValue.capture(cell: .init(row: 0, column: 0), columns: [column], rows: [["x"]], nativeValues: [[]]) == nil)
    }


    @Test func validMaximumDepthCanBeCopiedAndInspected() throws {
        var nested = NativeValue(kind: "text", value: "end")
        for _ in 0..<NativeValue.maximumDepth { nested = .init(kind: "list", items: [nested]) }
        let selected = try payload([nested])
        let json = try ResultCopy.text(selected, format: .json, includesHeaders: false)
        #expect(try JSONDecoder().decode(ResultClipboardPayload.self, from: Data(json.utf8)).nativeValues == [[nested]])
        let captured = try #require(InspectedValue.capture(cell: .init(row: 0, column: 0), columns: [column], rows: [["display"]], nativeValues: [[nested]]))
        #expect(try ValueInspectorProcessing.prepare(captured).formatted != nil)
    }
}

@MainActor
struct NativeConsumerGridTests {

}

@MainActor
struct NativeConsumerServerProfileTests {

}
