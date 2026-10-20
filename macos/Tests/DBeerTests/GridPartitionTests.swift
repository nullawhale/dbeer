import Foundation
import Testing
@testable import DBeer

@MainActor
struct GridPartitionTests {
    private func draft(engine: DatabaseEngine = .cassandra, missingKey: Bool = false) -> GridDraft {
        let names = ["order_id", "amount", "year", "customer_id"]
        let columns = names.enumerated().map { ResultColumn(index: $0.offset, name: $0.element, engine: engine, nativeType: "text") }
        let metadata = names.map { name -> [String: String] in
            ["name": name, "primaryKey": name == "order_id" ? "3" : name == "customer_id" ? "1" : name == "year" ? "2" : "0",
             "partitionKeyPosition": name == "customer_id" ? "1" : name == "year" ? "2" : "0", "editable": name == "amount" ? "true" : "false"]
        }
        return GridDraft(reference: TableReference(schema: "shop", name: "orders", kind: "table"),
            result: BackendMessage(type: "query.result", requestId: "partitions", columns: columns, rows: [
                ["101", "120.00", "2026", "10"], ["102", "89.50", "2026", "10"],
                ["103", "45.00", "2026", missingKey ? nil : "20"], ["104", "60.00", "2026", "10"],
                ["105", "32.00", "2025", "10"],
            ]), metadata: metadata)
    }

    @Test func completeCompositeKeysGroupNonAdjacentRowsAndStayStableDuringEdits() throws {
        let grid = draft()
        let markers = try #require(grid.partitionMarkers)
        #expect(markers.map { $0?.label } == ["P1", "P1", "P2", "P1", "P3"])
        #expect(markers[0] == markers[3])
        #expect(markers[0]?.keyDescription == "customer_id = 10\nyear = 2026")
        #expect(grid.partitionStatus == nil)
        let originalPresentation = grid.presentation
        grid.selectedRows = IndexSet([2, 4])
        #expect(grid.presentation === originalPresentation && grid.partitionStatus == nil)
        grid.set(ChangeValue(kind: "text", value: "130.00"), row: 0, column: 1)
        grid.set(.null, row: 3, column: 1)
        #expect(grid.pendingCount == 2 && grid.partitionStatus?.label == "1 partition · P1" && grid.canApply)
        grid.set(ChangeValue(kind: "text", value: "46.00"), row: 2, column: 1)
        #expect(grid.partitionStatus == .multiple(2) && !grid.canApply && grid.canEdit)
        #expect(grid.partitionMarkers == markers)
        grid.set(ChangeValue(kind: "text", value: "45.00"), row: 2, column: 1)
        #expect(grid.partitionStatus?.label == "1 partition · P1" && grid.canApply)
        grid.discard()
        #expect(grid.partitionStatus == nil && grid.partitionMarkers == markers)
    }

    @Test func missingKeysCannotClaimAtomicCompatibilityAndOtherEnginesKeepTheirGrid() {
        let grid = draft(missingKey: true)
        #expect(grid.partitionMarkers?[2] == nil)
        grid.set(.null, row: 2, column: 1)
        #expect(grid.partitionStatus == .unavailable && !grid.canApply)
        let other = draft(engine: .postgresql)
        other.set(.null, row: 0, column: 1)
        other.set(.null, row: 2, column: 1)
        #expect(other.partitionMarkers == nil && other.partitionStatus == nil && other.canApply)
    }

    @Test func compositeComponentBoundariesAndEmptyAndLiteralNullValuesRemainDistinct() throws {
        let columns = ["a", "b", "value"].enumerated().map { ResultColumn(index: $0.offset, name: $0.element, engine: .cassandra, nativeType: "text") }
        let rows: [[String?]] = [["ab", "c", "x"], ["a", "bc", "x"], ["", "NULL", "x"], ["NULL", "", "x"], [nil, "", "x"]]
        let metadata = [["partitionKeyPosition": "1"], ["partitionKeyPosition": "2"], [:]]
        let source = rows.map { row -> GridRow in
            let values = row.map { value in value.map { ChangeValue(kind: "text", value: $0) } ?? .null }
            return GridRow(original: values, values: values)
        }
        let markers = try #require(GridPartitions.markers(columns: columns, metadata: metadata, rows: source))
        #expect(markers.map { $0?.label } == ["P1", "P2", "P3", "P4", nil])
        #expect(markers[2]?.keyDescription.contains("a = \"\"") == true)
        #expect(GridPartitions.markers(columns: columns, metadata: [["partitionKeyPosition": "2"], [:], [:]], rows: source)?.allSatisfy { $0 == nil } == true)
    }

    @Test func canonicallyEquivalentUnicodeKeysRemainSeparatePartitions() throws {
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        #expect(composed == decomposed)
        let column = ResultColumn(index: 0, name: "key", engine: .cassandra, nativeType: "text")
        let rows = [composed, decomposed, composed].map { text -> GridRow in
            let values = [ChangeValue(kind: "text", value: text)]
            return GridRow(original: values, values: values)
        }
        let markers = try #require(GridPartitions.markers(columns: [column], metadata: [["partitionKeyPosition": "1"]], rows: rows))
        #expect(markers.map { $0?.label } == ["P1", "P2", "P1"])
    }
}
