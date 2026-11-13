import AppKit
import Foundation
import Testing
@testable import DBeer

/// Pure state, fixtures and unattached native tables; no windows or application activation.
@MainActor
struct TableCellFilterTests {
    @Test func addingToAnORPreservesGroupingAndSorting() throws {
        let initial = CatalogFilterExpression.group("or", [
            .predicate(.init(column: "status", operator: "eq", value: "new")),
            .predicate(.init(column: "status", operator: "eq", value: "failed"))])
        let configuration = TableBrowseConfiguration(filterExpression: initial, sort: [.init(column: "id", direction: "desc")])
        let added = try TableCellFilters.adding(.equal, column: .init(index: 0, name: "id"),
            values: [.init(kind: "text", value: "9007199254740993.000000000000000001")], to: configuration)
        #expect(added.sort == configuration.sort)
        #expect(added.filterExpression?.kind == "and")
        #expect(added.filterExpression?.children?.first == initial)
        #expect(added.filterExpression?.children?.last?.condition?.value == "9007199254740993.000000000000000001")
        #expect(configuration.filterExpression == initial)
    }

    @Test func selectedValuesDeduplicateAndKeepNULLDistinctFromTextAndEmpty() throws {
        let added = try TableCellFilters.adding(.selectedValues, column: .init(index: 0, name: "label"),
            values: [.null, .init(kind: "text", value: "NULL"), .init(kind: "text", value: ""), .null], to: .init())
        let children = try #require(added.filterExpression?.children)
        #expect(added.filterExpression?.kind == "or" && children.count == 3)
        #expect(children.map { $0.condition?.operator } == ["isNull", "eq", "eq"])
        #expect(children.map { $0.condition?.value } == [nil, "NULL", ""])
        let excluded = try TableCellFilters.adding(.exclude, column: .init(index: 0, name: "label"),
            values: [.init(kind: "text", value: "")], to: .init())
        #expect(excluded.filterExpression?.children?.map { $0.condition?.operator } == ["ne", "isNull"])
        #expect(try TableCellFilters.adding(.exclude, column: .init(index: 0, name: "label"), values: [.null],
            to: .init()).filterExpression?.condition?.operator == "isNotNull")
    }

    @Test func binaryAndUUIDOperandsKeepTheLoadedRepresentation() throws {
        let binary = try TableCellFilters.adding(.equal,
            column: .init(index: 0, name: "payload", engine: .mysql, nativeType: "varbinary", encoding: "base64"),
            values: [.init(kind: "binary", value: "AP+A")], to: .init())
        #expect(binary.filterExpression?.condition?.value == "AP+A")
        let uuid = "F3D1D2C7-1D66-47A1-9917-B3A880B20E11"
        #expect(try TableCellFilters.adding(.equal, column: .init(index: 0, name: "id", nativeType: "uuid"),
            values: [.init(kind: "text", value: uuid)], to: .init()).filterExpression?.condition?.value == uuid)
        #expect(throws: TableCellFilterError.self) {
            try TableCellFilters.adding(.equal, column: .init(index: 0, name: "value"), values: [.default], to: .init())
        }
    }

    @Test func budgetsRejectTheWholeAdditionAndLeaveExistingConfiguration() throws {
        let existing = TableBrowseConfiguration(filterExpression: .group("and", (0..<32).map {
            .predicate(.init(column: "c\($0)", operator: "eq", value: "1"))
        }))
        #expect(throws: TableCellFilterError.self) {
            try TableCellFilters.adding(.equal, column: .init(index: 0, name: "id"), values: [.init(kind: "text", value: "2")], to: existing)
        }
        #expect(existing.filterExpression?.conditionCount == 32)
        let deep = CatalogFilterExpression.group("or", [.group("and", [.group("or", [.predicate(.init(column: "id", operator: "eq", value: "1"))])])])
        #expect(deep.isValid)
        #expect(throws: TableCellFilterError.self) {
            try TableCellFilters.adding(.equal, column: .init(index: 0, name: "id"), values: [.init(kind: "text", value: "2")], to: .init(filterExpression: deep))
        }
    }

    @Test func sharedTypedOperandFixturesAgreeWithGo() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("protocol/fixtures/cell-filter-operands-v1.json"))
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(raw["capability"] as? String == TableCellFilters.sqliteCapability)
        for condition in try #require(raw["valid"] as? [[String: Any]]) {
            let encoded = try JSONSerialization.data(withJSONObject: condition)
            let filter = try JSONDecoder().decode(CatalogFilter.self, from: encoded)
            #expect(filter.isValid)
            #expect(try JSONDecoder().decode(CatalogFilter.self, from: JSONEncoder().encode(filter)) == filter)
        }
        for condition in try #require(raw["invalid"] as? [[String: Any]]) {
            let encoded = try JSONSerialization.data(withJSONObject: condition)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(CatalogFilter.self, from: encoded) }
        }
    }

    @Test func typedSQLiteValueRequiresCapabilityAndPreservesStorage() throws {
        let value = ChangeValue(kind: "sqliteBlob", value: "AP+A")
        let column = ResultColumn(index: 0, name: "payload", engine: .sqlite)
        #expect(throws: TableCellFilterError.self) { try TableCellFilters.adding(.equal, column: column, values: [value], to: .init()) }
        let filter = try TableCellFilters.adding(.equal, column: column, values: [value], to: .init(), typedSQLite: true)
        #expect(filter.filterExpression?.condition?.sqliteValue == SQLiteValue(type: "blob", value: "AP+A"))
        #expect(filter.filterExpression?.condition?.value == nil)
        let roundTrip = try JSONDecoder().decode(TableBrowseConfiguration.self, from: JSONEncoder().encode(filter))
        #expect(roundTrip == filter)
        let stored = StoredSQLDocument(title: "Typed SQLite", text: "Table data", profileID: UUID(), kind: .table,
            table: .init(reference: .init(schema: "main", name: "items", kind: "table"), filterExpression: filter.filterExpression))
        let document = SQLDocument(restoring: try JSONDecoder().decode(StoredSQLDocument.self, from: JSONEncoder().encode(stored)))
        #expect(document.tableFilterExpression == filter.filterExpression && document.runtime == nil)
    }

    @Test func normalTableActionOnlyChangesDraftAndRejectsPendingEdits() async throws {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore())
        let document = workspace.newDocument()
        let reference = TableReference(schema: "public", name: "items", kind: "table")
        document.table = reference
        let grid = GridDraft(reference: reference,
            result: BackendMessage(type: "query.result", requestId: "fixture", columns: [.init(index: 0, name: "id")], rows: [["7"]]),
            metadata: [["name": "id", "primaryKey": "1", "editable": "true"]])
        document.attachGrid(grid)
        document.page = 4
        let request = TableCellFilterRequest(action: .equal, cell: .init(row: 0, column: 0), rows: [0])
        TableBrowseNavigation.addCellFilter(request, document: document, workspace: workspace, grid: grid)
        #expect(document.hasPendingBrowseChanges && document.tableFilterExpression == nil)
        #expect(document.runtime == nil && document.page == 4 && !document.isRunning)
        let draft = document.browseDraftConfiguration
        grid.hasInlineDraft = true
        TableBrowseNavigation.addCellFilter(request, document: document, workspace: workspace, grid: grid)
        #expect(document.browseDraftConfiguration == draft && document.tableNavigationError != nil)
        grid.hasInlineDraft = false
        await workspace.shutdown()
    }

    @Test func filteredContextUsesSourceRowsForSelectedValueActions() throws {
        let coordinator = ResultTableView.Coordinator()
        let scroll = coordinator.makeScrollView()
        coordinator.update(columns: [.init(index: 0, name: "id"), .init(index: 1, name: "label")],
            rows: [["1", "hidden"], ["2", "match"], ["3", "hidden"], ["4", "match"]], in: scroll)
        coordinator.setSearch(query: "match", matchingOnly: true)
        let table = try #require(scroll.documentView as? ResultGridTableView)
        table.selectRowNumber(1)
        let request = try #require(coordinator.cellFilterRequest(.selectedValues))
        #expect(request.cell.row == 3 && request.rows == [3])
    }
}
