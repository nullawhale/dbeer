import Foundation
import Testing
@testable import DBeer

/// Exercise publication ownership without reading or writing a native clipboard.
struct ResultCopyPublicationTests {
    private func payload() throws -> ResultClipboardPayload {
        try ResultCopy.selection(columns: [
            ResultColumn(index: 0, name: "duplicate", typeOid: 1700),
            ResultColumn(index: 1, name: "duplicate", typeOid: 25),
            ResultColumn(index: 2, name: "bytes", engine: .mysql, nativeType: "BLOB", encoding: "base64")
        ], rows: [["9007199254740993.123456789", nil, "AAEC"], ["", nil, nil]],
        valueKinds: [["text", "null", "binary"], ["text", "default", "null"]],
        rowIndices: [0, 1], columnIndices: [0, 1, 2])
    }

    @Test func everyTextFormatKeepsTheSameTypedSelection() throws {
        let source = try payload()
        for format in ResultCopyFormat.allCases {
            let prepared = try PreparedResultCopy(payload: source, format: format, includesHeaders: true,
                insertSQL: format == .sqlInsert ? "INSERT INTO fixture VALUES ('exact');" : nil)
            let decoded = try JSONDecoder().decode(ResultClipboardPayload.self, from: prepared.typedData)
            #expect(decoded == source)
            #expect(!prepared.text.isEmpty)
            #expect(decoded.columns.map(\.name) == ["duplicate", "duplicate", "bytes"])
            #expect(decoded.values[0][0].value == "9007199254740993.123456789")
            #expect(decoded.values[1][1].kind == .default)
        }
        #expect(throws: ResultCopyError.self) {
            try PreparedResultCopy(payload: source, format: .sqlInsert, includesHeaders: false)
        }
    }

    @Test @MainActor func newerCopiesAndExternalChangesRevokeDelayedPublication() {
        let publisher = ResultCopyPublication()
        let first = publisher.capture(changeCount: 42)
        #expect(publisher.canPublish(first, changeCount: 42))
        #expect(!publisher.canPublish(first, changeCount: 43))
        let second = publisher.capture(changeCount: 42)
        #expect(!publisher.isCurrent(first))
        #expect(!publisher.canPublish(first, changeCount: 42))
        #expect(publisher.canPublish(second, changeCount: 42))
    }

    @Test func explicitTargetMappingKeepsDuplicateSourceNamesAndTypedValues() throws {
        let source = try payload()
        let target = InsertCopyTarget(engine: .postgresql, schema: "public", table: "destination",
            columnNames: ["amount", "description", "bytes"])
        let request = try target.request(payload: source)
        #expect(request.columns.map(\.name) == ["amount", "description", "bytes"])
        #expect(request.rows[0][0] == ChangeValue(kind: "text", value: "9007199254740993.123456789"))
        #expect(request.rows[0][1].kind == "null")
        #expect(request.rows[0][2] == ChangeValue(kind: "binary", value: "AAEC"))
        #expect(request.rows[1][0] == ChangeValue(kind: "text", value: ""))
        #expect(request.rows[1][1].kind == "default")
        #expect(request.rows[1][2].kind == "null")
        #expect(source.columns.map(\.name) == ["duplicate", "duplicate", "bytes"])
        #expect(throws: ResultCopyError.self) {
            try InsertCopyTarget(engine: .postgresql, schema: "public", table: "destination",
                columnNames: ["duplicate", "duplicate", "bytes"]).request(payload: source)
        }
        #expect(throws: ResultCopyError.self) {
            try InsertCopyTarget(engine: .cassandra, schema: "fixture", table: "destination",
                columnNames: ["amount", "description", "bytes"]).request(payload: source)
        }
    }
}
