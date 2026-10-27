import Foundation
import Testing
@testable import DBeer

struct TableForeignKeyTests {
    private let names = ["name", "targetSchema", "targetTable", "sourceColumn", "targetColumn", "position"]

    private func response(_ rows: [[String?]], truncated: Bool = false) -> BackendMessage {
        BackendMessage(type: "query.result", requestId: "fixture", columns: names.enumerated().map {
            ResultColumn(index: $0.offset, name: $0.element)
        }, rows: rows, rowCount: Int64(rows.count), truncated: truncated)
    }

    @Test func compositeMappingsUseConstraintOrderAndPreserveQuotedNames() throws {
        let keys = try TableForeignKey.parse(response([
            ["two.part fk", "odd\"schema", "parent.with.dots", "customer", "id", "2"],
            ["two.part fk", "odd\"schema", "parent.with.dots", "tenant", "tenant key", "1"],
        ]))
        let key = try #require(keys.first)
        #expect(keys.count == 1 && key.target == TableReference(schema: "odd\"schema", name: "parent.with.dots", kind: "table"))
        #expect(key.columns.map(\.source) == ["tenant", "customer"])
        #expect(key.columns.map(\.target) == ["tenant key", "id"])
        #expect(key.columns.map(\.position) == [1, 2])
    }

    @Test func incompleteDuplicateAndInconsistentMappingsAreRejected() {
        let invalid: [[[String?]]] = [
            [["fk", "s", "p", "a", "x", "2"]],
            [["fk", "s", "p", "a", "x", "1"], ["fk", "s", "p", "b", "y", "1"]],
            [["fk", "s", "p", "a", "x", "1"], ["fk", "s", "p", "a", "y", "2"]],
            [["fk", "s", "p", "a", "x", "1"], ["fk", "s", "p", "b", "x", "2"]],
            [["fk", "s", "p", "a", "x", "1"], ["fk", "s", "other", "b", "y", "2"]],
            [["fk", "s", "p", "a", "x", nil]],
            [["fk", "s", "p", "a", "x", "0"]],
            [["fk", "s", "p", "a", "x", "33"]],
            [["fk", "s", "p", "", "x", "1"]],
        ]
        for rows in invalid { #expect(throws: TableNavigationFailure.self) { try TableForeignKey.parse(response(rows)) } }
        #expect(throws: TableNavigationFailure.self) { try TableForeignKey.parse(response([["fk", "s", "p", "a", "x", "1"]], truncated: true)) }
        var missing = response([["fk", "s", "p", "a", "x", "1"]])
        missing.rowCount = 2
        #expect(throws: TableNavigationFailure.self) { try TableForeignKey.parse(missing) }
        var duplicate = response([["fk", "s", "p", "a", "x", "1"]])
        duplicate.columns?[1] = ResultColumn(index: 1, name: "name")
        #expect(throws: TableNavigationFailure.self) { try TableForeignKey.parse(duplicate) }
    }

    @Test func keyFiltersPreserveEmptyTextExactNumbersAndBinary() throws {
        let key = TableForeignKey(name: "fk", target: TableReference(schema: "s", name: "p", kind: "table"), columns: [
            TableForeignKeyColumn(source: "tenant", target: "tenant", position: 1),
            TableForeignKeyColumn(source: "customer", target: "id", position: 2),
            TableForeignKeyColumn(source: "bytes", target: "key", position: 3),
        ])
        let columns = ["customer", "bytes", "tenant"].enumerated().map { ResultColumn(index: $0.offset, name: $0.element) }
        let values = [ChangeValue(kind: "text", value: "9007199254740993.123456789"),
            ChangeValue(kind: "binary", value: "AP8="), ChangeValue(kind: "text", value: "")]
        #expect(try key.filters(sourceColumns: columns, values: values) == [
            CatalogFilter(column: "tenant", operator: "eq", value: ""),
            CatalogFilter(column: "id", operator: "eq", value: "9007199254740993.123456789"),
            CatalogFilter(column: "key", operator: "eq", value: "AP8="),
        ])
    }

    @Test func nullDefaultMissingAndAmbiguousSourceValuesNeverBecomeUnfilteredTargets() {
        let key = TableForeignKey(name: "fk", target: TableReference(schema: "s", name: "p", kind: "table"),
            columns: [TableForeignKeyColumn(source: "source", target: "id", position: 1)])
        let column = ResultColumn(index: 0, name: "source")
        for value in [ChangeValue.null, .default, ChangeValue(kind: "text"), ChangeValue(kind: "future", value: "1"),
                      ChangeValue(kind: "binary", value: "not base64"), ChangeValue(kind: "text", value: "a\0b")] {
            #expect(throws: TableNavigationFailure.self) { try key.filters(sourceColumns: [column], values: [value]) }
        }
        #expect(throws: TableNavigationFailure.self) { try key.filters(sourceColumns: [column], values: []) }
        #expect(throws: TableNavigationFailure.self) { try key.filters(sourceColumns: [], values: []) }
        #expect(throws: TableNavigationFailure.self) {
            try key.filters(sourceColumns: [column, ResultColumn(index: 1, name: "source")],
                values: [ChangeValue(kind: "text", value: "1"), ChangeValue(kind: "text", value: "2")])
        }
        #expect((try? key.filters(sourceColumns: [column], values: [ChangeValue(kind: "text", value: "NULL")])) ==
            [CatalogFilter(column: "id", operator: "eq", value: "NULL")])
    }

    @Test func emptyMetadataIsAValidNoRelationshipsResult() throws {
        #expect(try TableForeignKey.parse(response([])).isEmpty)
    }
}
