import AppKit
import Combine
import Foundation
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct ForeignKeyPickerTests {
    private let key = TableForeignKey(name: "customer", target: .init(schema: "public", name: "customers", kind: "table"), columns: [
        .init(source: "tenant", target: "tenant", position: 1),
        .init(source: "customer_id", target: "id", position: 2)
    ])
    private let sourceColumns = [ResultColumn(index: 0, name: "row_id", nativeType: "integer"),
        ResultColumn(index: 1, name: "tenant", nativeType: "numeric"),
        ResultColumn(index: 2, name: "customer_id", nativeType: "bytea", encoding: "base64")]
    private var targetColumns: [ResultColumn] {
        [.init(index: 0, name: "id", nativeType: "bytea", encoding: "base64"),
         .init(index: 1, name: "name", nativeType: "text"), .init(index: 2, name: "tenant", nativeType: "numeric")]
    }
    private func metadata() -> BackendMessage {
        let fields = ["name", "nativeType"]
        return .init(type: "query.result", requestId: "columns", columns: fields.enumerated().map { .init(index: $0.offset, name: $0.element) },
                     rows: targetColumns.map { [$0.name, $0.nativeType] }, rowCount: 3)
    }
    private func page(_ rows: [[String?]] = [["AP8=", "Customer", "9007199254740993.123456789"]]) -> BackendMessage {
        .init(type: "query.result", requestId: "browse", columns: targetColumns, rows: rows, rowCount: Int64(rows.count))
    }
    private func grid() -> GridDraft {
        GridDraft(reference: .init(schema: "public", name: "orders", kind: "table"),
            result: .init(type: "query.result", requestId: "source", columns: sourceColumns, rows: [["1", "1", "AA=="]], storageTokens: ["original-token"]),
            metadata: [["name": "row_id", "primaryKey": "1", "editable": "false"],
                       ["name": "tenant", "editable": "true"], ["name": "customer_id", "editable": "true"]])
    }
    @Test func compositeSelectionStagesOneLocalChangeAndRetainsOriginalEvidence() async throws {
        let grid = grid(), before = grid.rows[0].values, rowID = grid.rows[0].id
        var requests: [CatalogRequest] = [], publications = 0
        let token = grid.$rows.dropFirst().sink { _ in publications += 1 }
        let model = ForeignKeyPickerModel(key: key, engine: .postgresql, sourceColumns: sourceColumns,
            isCurrent: { true }, read: { request in
                requests.append(request)
                return request.kind == "columns" ? self.metadata() : self.page()
            }, cancel: {}, stage: { try grid.stageForeignKey($0, rowID: rowID, expectedValues: before) })
        await model.load()
        #expect(requests.map(\.kind) == ["columns", "browse"])
        #expect(model.displayColumns == [Data("name".utf8)])
        let row = try #require(model.rows.first)
        #expect(model.choose(row))
        #expect(publications == 1)
        #expect(grid.rows[0].values[1].value == "9007199254740993.123456789")
        #expect(grid.rows[0].values[2] == .init(kind: "binary", value: "AP8="))
        #expect(grid.rows[0].original == before && grid.rows[0].originalStorageToken == "original-token")
        #expect(grid.request().changes.count == 1 && grid.request().changes[0].values?.count == 2)
        #expect(requests.allSatisfy { $0.kind != "execute" })
        withExtendedLifetime(token) {}
    }
    @Test func protectedOrChangedSourceRejectsTheEntireCompositeEdit() throws {
        let grid = grid(), original = grid.rows[0].values, rowID = grid.rows[0].id
        #expect(throws: ForeignKeyPickerFailure.self) {
            try grid.stageForeignKey([0: .init(kind: "text", value: "2"), 1: .init(kind: "text", value: "3")], rowID: rowID, expectedValues: original)
        }
        #expect(grid.rows[0].values == original && grid.pendingCount == 0)
        grid.set(.init(kind: "text", value: "4"), row: 0, column: 1)
        let edited = grid.rows[0].values
        #expect(throws: ForeignKeyPickerFailure.self) {
            try grid.stageForeignKey([2: .init(kind: "binary", value: "AP8=")], rowID: rowID, expectedValues: original)
        }
        #expect(grid.rows[0].values == edited)
        grid.outcomeUnknown = true
        #expect(throws: ForeignKeyPickerFailure.self) {
            try grid.stageForeignKey([2: .init(kind: "binary", value: "AP8=")], rowID: rowID, expectedValues: edited)
        }
        #expect(grid.rows[0].values == edited)
    }
    @Test func nullDefaultAmbiguousAndInexactKeyValuesAreRejected() throws {
        for value in [ChangeValue.null, .default, .init(kind: "binary", value: "not-base64"), .init(kind: "text", value: "AP8=")] {
            #expect(throws: ForeignKeyPickerFailure.self) {
                try ForeignKeyPickerValues.assignments(key: key, sourceColumns: sourceColumns, targetColumns: targetColumns,
                    values: [value, .init(kind: "text", value: "label"), .init(kind: "text", value: "1")])
            }
        }
        #expect(throws: ForeignKeyPickerFailure.self) {
            try ForeignKeyPickerValues.sourceIndices(key: key, columns: sourceColumns + [sourceColumns[1]])
        }
    }
    @Test func sqliteStorageTypesRemainExactAcrossCompositeMapping() throws {
        let source = [ResultColumn(index: 0, name: "tenant", engine: .sqlite), ResultColumn(index: 1, name: "customer_id", engine: .sqlite)]
        let target = [ResultColumn(index: 0, name: "id", engine: .sqlite), ResultColumn(index: 1, name: "tenant", engine: .sqlite)]
        let values = [SQLiteValue(type: "blob", value: "AP8=").changeValue, SQLiteValue(type: "integer", value: "9223372036854775807").changeValue]
        let result = try ForeignKeyPickerValues.assignments(key: key, sourceColumns: source, targetColumns: target, values: values)
        #expect(result[0] == values[1] && result[1] == values[0])
        #expect(throws: ForeignKeyPickerFailure.self) {
            try ForeignKeyPickerValues.assignments(key: key, sourceColumns: source, targetColumns: target,
                values: [.init(kind: "text", value: "AP8="), values[1]])
        }
    }
    @Test func changedContextRejectsLateReadAndSelection() async throws {
        var current = true, staged = false
        let model = ForeignKeyPickerModel(key: key, engine: .postgresql, sourceColumns: sourceColumns,
            isCurrent: { current }, read: { request in
                if request.kind == "browse" { current = false }
                return request.kind == "columns" ? self.metadata() : self.page()
            }, cancel: {}, stage: { _ in staged = true })
        await model.load()
        #expect(model.rows.isEmpty && model.error != nil && !staged)
        current = true
        await model.searchRows()
        #expect(model.rows.isEmpty && !staged)
    }
    @Test func changedSearchBlocksPagingAndChoiceUntilExplicitSearch() async throws {
        var requests: [CatalogRequest] = [], staged = false
        let model = ForeignKeyPickerModel(key: key, engine: .postgresql, sourceColumns: sourceColumns,
            isCurrent: { true }, read: { request in
                requests.append(request)
                return request.kind == "columns" ? self.metadata() : self.page()
            }, cancel: {}, stage: { _ in staged = true })
        await model.load()
        let row = try #require(model.rows.first)
        model.search = "Custom"
        #expect(model.hasUnappliedSearch && !model.choose(row) && !staged)
        await model.searchRows(page: 1)
        #expect(requests.count == 2)
        await model.searchRows()
        #expect(requests.last?.filterExpression?.condition?.value == "Custom")
        #expect(requests.last?.filterExpression?.condition?.operator == "contains")
        #expect(model.choose(try #require(model.rows.first)) && staged)
    }
    @Test func incompleteMetadataAndChangedTargetColumnsNeverYieldChoices() async {
        var browseReads = 0
        let model = ForeignKeyPickerModel(key: key, engine: .postgresql, sourceColumns: sourceColumns,
            isCurrent: { true }, read: { request in
                if request.kind == "browse" { browseReads += 1; return self.page() }
                var reply = self.metadata(); reply.truncated = true; return reply
            }, cancel: {}, stage: { _ in Issue.record("Incomplete metadata was staged") })
        await model.load()
        #expect(browseReads == 0 && model.rows.isEmpty && model.error != nil)
        let changed = ForeignKeyPickerModel(key: key, engine: .postgresql, sourceColumns: sourceColumns,
            isCurrent: { true }, read: { request in
                if request.kind == "columns" { return self.metadata() }
                var reply = self.page(); reply.columns?.removeLast(); return reply
            }, cancel: {}, stage: { _ in Issue.record("Changed target schema was staged") })
        await changed.load()
        #expect(changed.rows.isEmpty && changed.error != nil)
    }
    @Test func stopRetiresLateResultsAndCloseRetiresChoices() async throws {
        var suspended: CheckedContinuation<BackendMessage, Error>?, cancels = 0
        let model = ForeignKeyPickerModel(key: key, engine: .postgresql, sourceColumns: sourceColumns,
            isCurrent: { true }, read: { request in
                if request.kind == "columns" { return self.metadata() }
                return try await withCheckedThrowingContinuation { suspended = $0 }
            }, cancel: { cancels += 1 }, stage: { _ in Issue.record("Cancelled row was staged") })
        let load = Task { await model.load() }
        while suspended == nil { await Task.yield() }
        await model.stop()
        suspended?.resume(returning: page())
        await load.value
        #expect(model.rows.isEmpty && model.error != nil && cancels == 1)
        await model.close()
        #expect(cancels == 2)
    }
    @Test func keyStagingComparesUnicodeBytesAndPreservesDistinctOriginals() throws {
        let columns = [ResultColumn(index: 0, name: "id"), ResultColumn(index: 1, name: "key", nativeType: "text")]
        let grid = GridDraft(reference: .init(schema: "public", name: "fixture", kind: "table"),
            result: .init(type: "query.result", requestId: "unicode", columns: columns, rows: [["1", "e\u{301}"]]),
            metadata: [["name": "id", "primaryKey": "1", "editable": "false"], ["name": "key", "editable": "true"]])
        let before = grid.rows[0].values, rowID = grid.rows[0].id
        try grid.stageForeignKey([1: .init(kind: "text", value: "\u{e9}")], rowID: rowID, expectedValues: before)
        #expect(grid.pendingCount == 1 && grid.rows[0].assignments.count == 1)
        #expect(Data(try #require(grid.rows[0].original?[1].value).utf8) != Data(try #require(grid.rows[0].values[1].value).utf8))
        #expect(throws: ForeignKeyPickerFailure.self) {
            try grid.stageForeignKey([1: .init(kind: "text", value: "other")], rowID: rowID, expectedValues: before)
        }
    }
    @Test func filteredContextActionUsesOriginalSourceRow() {
        let coordinator = ResultTableView.Coordinator()
        let scroll = coordinator.makeScrollView()
        let columns = [ResultColumn(index: 0, name: "label"), ResultColumn(index: 1, name: "customer_id")]
        var selected: ResultGridCell?
        coordinator.editableColumns = [1]
        coordinator.relatedKeyColumns = [1]
        coordinator.onChooseRelatedCell = { selected = $0 }
        coordinator.update(columns: columns, rows: [["hidden", "1"], ["shown", "2"]], in: scroll)
        coordinator.setSearch(query: "shown", matchingOnly: true)
        coordinator.chooseRelatedCell(.init(row: 0, column: 1))
        #expect(selected == .init(row: 1, column: 1))
    }
    @Test func canonicalUnicodeIdentifiersAndSearchBytesRemainDistinct() async throws {
        let composed = "\u{e9}", decomposed = "e\u{301}"
        let key = TableForeignKey(name: "fk", target: .init(schema: "public", name: "p", kind: "table"),
            columns: [.init(source: "source", target: composed, position: 1)])
        let target = [ResultColumn(index: 0, name: composed, nativeType: "text"), ResultColumn(index: 1, name: decomposed, nativeType: "text")]
        let model = ForeignKeyPickerModel(key: key, engine: .postgresql,
            sourceColumns: [.init(index: 0, name: "source", nativeType: "text")], isCurrent: { true }, read: { request in
                if request.kind == "columns" {
                    return .init(type: "query.result", requestId: "columns",
                        columns: [.init(index: 0, name: "name"), .init(index: 1, name: "nativeType")],
                        rows: [[composed, "text"], [decomposed, "text"]])
                }
                return .init(type: "query.result", requestId: "rows", columns: target, rows: [["key-value", "description-value"]])
            }, cancel: {}, stage: { _ in Issue.record("Unapplied byte-distinct query was selected") })
        await model.load()
        let row = try #require(model.rows.first)
        #expect(model.displayColumns == [Data(decomposed.utf8)])
        #expect(model.label(row, keysOnly: true).contains("key-value"))
        #expect(!model.label(row, keysOnly: true).contains("description-value"))
        model.displayColumns.insert(Data(composed.utf8))
        #expect(model.displayColumns.count == 2)
        model.searchColumn = composed
        #expect(model.hasUnappliedSearch && !model.choose(row))
        model.search = decomposed
        await model.searchRows()
        model.search = composed
        let previousChoice = try #require(model.rows.first)
        #expect(model.hasUnappliedSearch && !model.choose(previousChoice))
        let changed = TableForeignKey(name: "fk", target: key.target,
            columns: [.init(source: "source", target: decomposed, position: 1)])
        #expect(!ForeignKeyPickerValues.sameKey(key, changed))
        #expect(!ForeignKeyPickerValues.sameTable(.init(schema: "public", name: composed, kind: "table"),
            .init(schema: "public", name: decomposed, kind: "table")))
    }
    @Test func sqliteExactSearchUsesAnExplicitStorageTypeForHeterogeneousKeys() async throws {
        let key = TableForeignKey(name: "fk", target: .init(schema: "main", name: "p", kind: "table"),
            columns: [.init(source: "source", target: "key", position: 1)])
        var reads: [CatalogRequest] = []
        let model = ForeignKeyPickerModel(key: key, engine: .sqlite,
            sourceColumns: [.init(index: 0, name: "source", engine: .sqlite, nativeType: "ANY")], typedSQLiteFilters: true,
            isCurrent: { true }, read: { request in
                reads.append(request)
                if request.kind == "columns" {
                    return .init(type: "query.result", requestId: "columns",
                        columns: [.init(index: 0, name: "name"), .init(index: 1, name: "nativeType")], rows: [["key", "ANY"]])
                }
                let value = request.filterExpression?.condition?.sqliteValue ?? .init(type: "blob", value: "AP8=")
                return .init(type: "query.result", requestId: "rows", columns: [.init(index: 0, name: "key", engine: .sqlite, nativeType: "ANY")],
                    rows: [[value.displayText]], sqliteValues: [[value]])
            }, cancel: {}, stage: { _ in })
        await model.load()
        for (type, input, expected) in [
            ("blob", "AP8=", SQLiteValue(type: "blob", value: "AP8=")),
            ("integer", "9223372036854775807", SQLiteValue(type: "integer", value: "9223372036854775807")),
            ("real", "1.5", SQLiteValue(type: "real", value: "3ff8000000000000")),
            ("text", "a\0b", SQLiteValue(type: "text", value: "YQBi"))
        ] {
            model.sqliteSearchType = type
            model.search = input
            await model.searchRows()
            #expect(model.error == nil && reads.last?.filterExpression?.condition?.sqliteValue == expected)
        }
        model.sqliteSearchType = "blob"
        #expect(model.hasUnappliedSearch)
    }
    @Test func aliasedShuffledResultsUseVerifiedCanonicalSourceColumns() throws {
        let displayed = [ResultColumn(index: 0, name: "tenant", nativeType: "bytea", encoding: "base64"),
            ResultColumn(index: 1, name: "customer_id", nativeType: "integer"),
            ResultColumn(index: 2, name: "row_id", nativeType: "numeric")]
        let source = SQLResultSource(schema: "public", table: "orders", columns: [
            .init(name: "customer_id", nativeType: "bytea", tableIndex: 2, primaryKey: 0, editable: true, generated: false),
            .init(name: "row_id", nativeType: "integer", tableIndex: 0, primaryKey: 1, editable: false, generated: false),
            .init(name: "tenant", nativeType: "numeric", tableIndex: 1, primaryKey: 0, editable: true, generated: false)
        ])
        let grid = GridDraft(reference: .init(schema: "public", name: "orders", kind: "table"),
            result: .init(type: "query.result", requestId: "aliased", sessionId: "query-session", columns: displayed,
                rows: [["AA==", "1", "1"]]), metadata: [], querySource: source)
        let canonical = try ForeignKeyPickerValues.canonicalColumns(grid)
        #expect(canonical.map(\.name) == ["customer_id", "row_id", "tenant"])
        let assignments = try ForeignKeyPickerValues.assignments(key: key, sourceColumns: canonical, targetColumns: targetColumns,
            values: [.init(kind: "binary", value: "AP8="), .init(kind: "text", value: "Customer"), .init(kind: "text", value: "9007199254740993.123456789")])
        try grid.stageForeignKey(assignments, rowID: grid.rows[0].id, expectedValues: grid.rows[0].values)
        #expect(grid.rows[0].values[0] == .init(kind: "binary", value: "AP8="))
        #expect(grid.rows[0].values[1] == .init(kind: "text", value: "1"))
        #expect(grid.rows[0].values[2].value == "9007199254740993.123456789")
        #expect(grid.request().columns.map(\.name) == ["row_id", "tenant", "customer_id"])
        #expect(grid.request().changes[0].values?.map(\.column) == ["customer_id", "tenant"])
    }
    @Test func unsupportedOrAmbiguousProvenanceNeverInfersSourceNamesFromLabels() {
        let columns = [ResultColumn(index: 0, name: "tenant", nativeType: "integer")]
        for source in [
            SQLResultSource(schema: "public", table: "orders", columns: [
                .init(name: "row_id", nativeType: "integer", tableIndex: 0, primaryKey: 1, editable: true, generated: false)
            ], readOnlyReason: "The query joins multiple tables."),
            SQLResultSource(schema: "public", table: "orders", columns: [
                .init(name: "row_id", nativeType: "integer", tableIndex: 3, primaryKey: 1, editable: true, generated: false)
            ])
        ] {
            let grid = GridDraft(reference: .init(schema: "public", name: "orders", kind: "table"),
                result: .init(type: "query.result", requestId: "invalid", columns: columns, rows: [["1"]]),
                metadata: [], querySource: source)
            #expect(throws: ForeignKeyPickerFailure.self) { try ForeignKeyPickerValues.canonicalColumns(grid) }
        }
    }
}
