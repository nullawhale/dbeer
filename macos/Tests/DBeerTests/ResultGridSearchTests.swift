import AppKit
import Foundation
import Testing
@testable import DBeer

@MainActor
struct ResultGridSearchTests {
    @Test func filteringRetainsSourceOrdinalsAndSelectedColumnScope() {
        let rows: [[String?]] = [["x", "alpha"], ["alpha", "βeta"], ["x", "ALPHA"]]
        let result = ResultGridSearch.find("alpha", rows: rows, columns: [1], matchingOnly: true)
        #expect(result.sourceRows == [0, 2])
        #expect(result.matches == [.init(row: 0, column: 1), .init(row: 2, column: 1)])
        #expect(result.sourceCell(.init(row: 1, column: 1)) == .init(row: 2, column: 1))
        #expect(result.displayedCell(.init(row: 1, column: 1)) == nil)
        #expect(result.sourceSelection([0, 1]) == [0, 2])
        #expect(result.displayedSelection([1, 2]) == [1])
        #expect(ResultGridSearch.find("", rows: rows, columns: [], matchingOnly: true).sourceRows == [0, 1, 2])
    }

    @Test func searchPreservesExactRepresentationsAndSpecialValueKinds() {
        let rows: [[String?]] = [[nil], ["NULL"], [""], ["9007199254740993.123456789"], [nil], ["AAEC"]]
        let kinds = [["null"], ["text"], ["text"], ["text"], ["default"], ["binary"]]
        #expect(ResultGridSearch.find("null", rows: rows, columns: [0], valueKinds: kinds).matches ==
            [.init(row: 0, column: 0), .init(row: 1, column: 0)])
        #expect(ResultGridSearch.find("DEFAULT", rows: rows, columns: [0], valueKinds: kinds).matches == [.init(row: 4, column: 0)])
        #expect(ResultGridSearch.find("993.123456789", rows: rows, columns: [0], valueKinds: kinds).matches == [.init(row: 3, column: 0)])
        #expect(ResultGridSearch.find("AAEC", rows: rows, columns: [0], valueKinds: kinds).matches == [.init(row: 5, column: 0)])
        #expect(ResultGridSearch.find("missing", rows: rows, columns: [0], matchingOnly: true).sourceRows.isEmpty)
    }

    @Test func filteredEditingCopyAndInspectionAddressTheOriginalRow() async throws {
        let board = NSPasteboard(name: .init("dev.dbeer.tests.grid-search.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let coordinator = ResultTableView.Coordinator(pasteboard: board)
        let scroll = coordinator.makeScrollView()
        let columns = [ResultColumn(index: 0, name: "id"), ResultColumn(index: 1, name: "value")]
        let rows: [[String?]] = [["1", "other"], ["2", "match"], ["3", "other"], ["4", "match"]]
        var edited: ResultGridCell?
        var selected = IndexSet()
        var inspected: InspectedValue?
        coordinator.editableColumns = [1]
        coordinator.onEditCell = { edited = $0 }
        coordinator.onSelectedRows = { selected = $0 }
        coordinator.onInspectValue = { inspected = $0 }
        coordinator.update(columns: columns, rows: rows, in: scroll)
        coordinator.setSearch(query: "match", matchingOnly: true)
        let table = try #require(scroll.documentView as? ResultGridTableView)
        #expect(table.numberOfRows == 2)
        coordinator.editCell(.init(row: 1, column: 1))
        #expect(edited == .init(row: 3, column: 1))
        coordinator.moveSearchMatch(-1)
        #expect(selected == [3])
        coordinator.copyRows(nil)
        let payload = try JSONDecoder().decode(ResultClipboardPayload.self, from: #require(board.data(forType: ResultTableView.clipboardType)))
        #expect(payload.sourceRows == [3])
        #expect(payload.values[0][0].value == "4")
        for _ in 0..<3 { await Task.yield() }
        #expect(inspected?.row == 3 && inspected?.value.value == "match")
        coordinator.closeSearch()
        #expect(table.numberOfRows == 4)
        #expect(table.selectedRowIndexes == [3])
    }

    @Test func clearingSearchRestoresHiddenSelectionWhenNoOtherCellWasChosen() throws {
        let coordinator = ResultTableView.Coordinator()
        let scroll = coordinator.makeScrollView()
        coordinator.update(columns: [.init(index: 0, name: "value")], rows: [["hidden"], ["shown"]], in: scroll)
        let table = try #require(scroll.documentView as? ResultGridTableView)
        var selected = IndexSet()
        coordinator.onSelectedRows = { selected = $0 }
        table.selectRowNumber(0)
        coordinator.setSearch(query: "shown", matchingOnly: true)
        #expect(table.selectedRowIndexes.isEmpty && selected.isEmpty)
        coordinator.setSearch(query: "show", matchingOnly: true)
        coordinator.closeSearch()
        #expect(table.selectedRowIndexes == [0])
        #expect(selected == [0])
        #expect(table.cellSelection?.focus == .init(row: 0, column: 0))
    }

    @Test func replacementResultInvalidatesTheSearchSelectionBookmark() throws {
        let coordinator = ResultTableView.Coordinator()
        let scroll = coordinator.makeScrollView()
        let columns = [ResultColumn(index: 0, name: "value")]
        let rows: [[String?]] = [["hidden"], ["shown"]]
        coordinator.update(columns: columns, rows: rows, dataIdentity: NSObject(), in: scroll)
        let table = try #require(scroll.documentView as? ResultGridTableView)
        table.selectRowNumber(0)
        coordinator.setSearch(query: "shown", matchingOnly: true)
        coordinator.update(columns: columns, rows: rows, dataIdentity: NSObject(), in: scroll)
        coordinator.closeSearch()
        #expect(table.selectedRowIndexes.isEmpty)
    }

    @Test func filteringClearsHiddenSelectionWithoutSelectingADifferentSourceRow() throws {
        let coordinator = ResultTableView.Coordinator()
        let scroll = coordinator.makeScrollView()
        coordinator.update(columns: [.init(index: 0, name: "value")], rows: [["hidden"], ["shown"]], in: scroll)
        let table = try #require(scroll.documentView as? ResultGridTableView)
        var selected = IndexSet()
        coordinator.onSelectedRows = { selected = $0 }
        table.selectRowNumber(0)
        #expect(selected == [0])
        coordinator.setSearch(query: "shown", matchingOnly: true)
        #expect(table.selectedRowIndexes.isEmpty)
        #expect(selected.isEmpty)
        coordinator.moveSearchMatch(1)
        #expect(selected == [1])
        coordinator.closeSearch()
        #expect(table.selectedRowIndexes == [1])
    }
}
