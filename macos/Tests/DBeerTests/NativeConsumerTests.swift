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

    @Test func profilesRequireNumericSemanticsAndRetainExactRepresentations() throws {
        let exact = try payload([.init(kind: "integer", value: "9007199254740993"), .init(kind: "decimal", value: "0.1"), .init(kind: "null")])
        let report = try GridDataProfiler.profile(.init(payload: exact, scope: .init(title: "Native selection", notice: "Loaded only")))
        #expect(report.columns[0].sum == "9007199254740993.1" && report.columns[0].nullCount == 1)
        for (native, metadata) in [
            (NativeValue(kind: "integer", value: "1700000000000", engine: "cassandra", nativeType: "timestamp"), ResultColumn(index: 0, name: "t", engine: .cassandra, nativeType: "timestamp")),
            (NativeValue(kind: "integer", value: "1700000000000", engine: "cassandra", nativeType: "timestamp"), column),
            (NativeValue(kind: "integer", value: "4", typeIdentity: "unresolved:custom"), column),
            (NativeValue(kind: "native", value: "5", engine: "postgresql", nativeType: "custom"), column),
            (NativeValue(kind: "opaque", value: "NQ==", engine: "mongodb", nativeType: "custom"), column)] {
            let value = try GridDataProfiler.profile(.init(payload: payload([native], column: metadata), scope: .init(title: "Captured", notice: "")))
            #expect(value.columns[0].sum == nil && value.columns[0].numericNotice != nil)
        }
        let floating = try GridDataProfiler.profile(.init(payload: payload([
            .init(kind: "float64", value: "7ff8000000000001"), .init(kind: "float64", value: "7ff8000000000002")]),
            scope: .init(title: "Captured floats", notice: "")))
        #expect(floating.columns[0].sum == nil && floating.columns[0].distinctCount == 2)
        #expect(floating.columns[0].frequencies.contains { $0.value?.contains("7ff8000000000001") == true })
        let unicode = try GridDataProfiler.profile(.init(payload: payload([.init(kind: "text", value: "é"), .init(kind: "text", value: "e\u{301}")]),
            scope: .init(title: "Captured text", notice: "")))
        #expect(unicode.columns[0].distinctCount == 2)
        let sqliteColumn = ResultColumn(index: 0, name: "stored", engine: .sqlite, nativeType: "INTEGER")
        let stored = try ResultCopy.selection(columns: [sqliteColumn], rows: [["rounded"]],
            sqliteValues: [[.init(type: "integer", value: "9007199254740993")]],
            nativeValues: [[.init(kind: "integer", value: "9007199254740993", engine: "sqlite", nativeType: "integer")]],
            rowIndices: [0], columnIndices: [0])
        #expect(try GridDataProfiler.profile(.init(payload: stored, scope: .init(title: "SQLite storage", notice: ""))).columns[0].sum == "9007199254740993")
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
    @Test func filteredSelectionInspectionAndProfileKeepOriginalNativeOrdinals() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let coordinator = ResultTableView.Coordinator(pasteboard: board)
        let scroll = coordinator.makeScrollView()
        let columns = [ResultColumn(index: 0, name: "n", typeOid: 1700, nativeType: "numeric"),
                       ResultColumn(index: 1, name: "label", typeOid: 25, nativeType: "text")]
        let matrix: [[NativeValue]] = [[.init(kind: "integer", value: "1"), .init(kind: "text", value: "hidden")],
            [.init(kind: "integer", value: "9007199254740993"), .init(kind: "text", value: "shown")],
            [.init(kind: "integer", value: "2"), .init(kind: "text", value: "hidden")],
            [.init(kind: "integer", value: "3"), .init(kind: "text", value: "shown")]]
        coordinator.nativeValues = matrix
        coordinator.onShowRowDetails = {}
        var inspected: InspectedValue?
        coordinator.onInspectValue = { inspected = $0 }
        coordinator.update(columns: columns, rows: Array(repeating: ["wrong", "wrong"], count: 4), in: scroll)
        coordinator.setSearch(query: "shown", columns: [1], matchingOnly: true)
        coordinator.activateCell(.init(row: 1, column: 0))
        for _ in 0..<10 { await Task.yield() }
        guard case .values(let selection) = coordinator.captureProfileSelection() else { Issue.record("Missing native selection"); return }
        #expect(selection.payload.sourceRows == [3] && selection.payload.nativeValues == [[matrix[3][0]]])
        #expect(inspected?.row == 3 && inspected?.nativeValue == matrix[3][0])
        let copy = try #require(coordinator.captureCopy(format: .json))
        await copy()
        let copied = try #require(board.data(forType: ResultTableView.clipboardType))
        #expect(try JSONDecoder().decode(ResultClipboardPayload.self, from: copied).nativeValues == [[matrix[3][0]]])
        guard case .values(let visible) = coordinator.captureProfileSelection(visibleColumn: 0) else { Issue.record("Missing native visible column"); return }
        #expect(visible.payload.sourceRows == [1, 3])
        #expect(try GridDataProfiler.profile(visible).columns[0].sum == "9007199254740996")
        coordinator.editableColumns = [0]
        coordinator.uneditableRows = [3]
        #expect(coordinator.canEditCell(.init(row: 0, column: 0)))
        #expect(!coordinator.canEditCell(.init(row: 1, column: 0)))
        var changed = matrix
        changed[1][1] = .init(kind: "text", value: "hidden")
        coordinator.nativeValues = changed
        coordinator.update(columns: columns, rows: Array(repeating: ["wrong", "wrong"], count: 4), in: scroll)
        guard case .values(let retained) = coordinator.captureProfileSelection() else { Issue.record("Native update lost selection"); return }
        #expect(retained.payload.sourceRows == [3])
        #expect(coordinator.numberOfRows(in: try #require(scroll.documentView as? ResultGridTableView)) == 1)
    }
}

@MainActor
struct NativeConsumerServerProfileTests {
    @Test func serverSampleUsesNativeValuesAndRejectsAFormatChange() async throws {
        let column = ResultColumn(index: 0, name: "n", typeOid: 1700, nativeType: "numeric")
        var pages = 0
        var disconnected = 0
        let model = GridProfileServerModel(table: .init(schema: "public", name: "sample", kind: "table"), column: column, engine: .postgresql,
            connect: { "owned" }, send: { command in
                if command.type == "disconnect" { disconnected += 1; return .init(type: "disconnect.result", requestId: command.requestId) }
                pages += 1
                var response = BackendMessage(type: "query.result", requestId: command.requestId, sessionId: command.sessionId,
                    queryId: command.queryId, transactionStatus: .idle, columns: [column], rows: [["formatted"]])
                if pages == 1 { response.nativeValues = [[.init(kind: "integer", value: "9007199254740993")]]; response.nextCursor = "next" }
                return response
            }, isCurrent: { true })
        await model.capture()
        let report = try #require(model.report)
        #expect(report.rowCount == 1 && report.columns[0].sum == "9007199254740993")
        #expect(report.scope.partial && report.scope.notice.contains("native-value format"))
        #expect(pages == 2 && disconnected == 1)
        await model.close()
    }
}
