import Foundation
import Testing
@testable import DBeer

@MainActor
struct GridPresentationTests {
    private func draft() -> GridDraft {
        let columns = [ResultColumn(index: 0, name: "id", typeOid: 23, nativeType: "int4"),
            ResultColumn(index: 1, name: "label", typeOid: 25, nativeType: "text"),
            ResultColumn(index: 2, name: "payload", typeOid: 17, nativeType: "bytea", encoding: "base64")]
        return GridDraft(reference: TableReference(schema: "public", name: "fixture", kind: "table"),
            result: BackendMessage(type: "query.result", requestId: "fixture", columns: columns,
                rows: [["1", "", "AP8="], ["2", nil, ""]]),
            metadata: [["name": "id", "primaryKey": "1", "editable": "true"],
                ["name": "label", "editable": "true"], ["name": "payload", "editable": "true"]])
    }

    @Test func selectionAndOperationStateReuseTableContent() {
        let grid = draft()
        let snapshot = grid.presentation
        for row in 0..<grid.rows.count {
            grid.selectedRows.insert(row)
            #expect(grid.presentation === snapshot)
        }
        grid.isPreviewing = true
        grid.error = "Fixture"
        #expect(grid.presentation === snapshot)
        #expect(snapshot.rows == [["1", "", "AP8="], ["2", nil, ""]])
        #expect(snapshot.valueKinds == [["text", "text", "binary"], ["text", "null", "binary"]])
    }

    @Test func stagingCreatesNewContentAndPreservesThePreviousSnapshot() {
        let grid = draft()
        let original = grid.presentation
        grid.set(.default, row: 0, column: 1)
        let staged = grid.presentation
        #expect(staged !== original)
        #expect(original.rows[0][1] == "")
        #expect(staged.rows[0][1] == "<DEFAULT>")
        #expect(staged.valueKinds[0][1] == "default")
        #expect(staged.pendingCount == 1)
        #expect(staged.modifiedCells == [ResultGridCell(row: 0, column: 1)])
        grid.set(ChangeValue(kind: "text", value: "NULL"), row: 0, column: 1)
        #expect(grid.presentation.rows[0][1] == "NULL")
        #expect(grid.presentation.valueKinds[0][1] == "text")
        grid.set(.null, row: 0, column: 1)
        #expect(grid.presentation.rows[0][1] == nil)
        #expect(grid.presentation.valueKinds[0][1] == "null")
        grid.discard()
        #expect(grid.presentation.rows == original.rows)
        #expect(grid.presentation.pendingCount == 0)
        #expect(grid.presentation.modifiedCells.isEmpty)
    }

    @Test func deletionAndInsertedRowsRefreshDecorationsAndIndicesTogether() {
        let grid = draft()
        grid.insert()
        #expect(grid.presentation.pendingCount == 1)
        #expect(grid.presentation.modifiedCells.count == 3)
        #expect(grid.presentation.valueKinds[2] == ["default", "default", "default"])
        grid.selectedRows = IndexSet([0, 2])
        grid.deleteSelected()
        #expect(grid.presentation.rows.count == 2)
        #expect(grid.presentation.deletedRows == IndexSet(integer: 0))
        #expect(grid.presentation.modifiedCells.isEmpty)
        #expect(grid.presentation.pendingCount == 1)
    }
}

struct GridColumnEditingTests {
    @Test func explicitNullabilityAndEditabilityControlSpecialValues() {
        let column = ResultColumn(index: 0, name: "id", typeOid: 23, nativeType: "int4")
        let required = GridColumnEditing(column: column, metadata: ["editable": "true", "nullable": "false"])
        #expect(required.isEditable)
        #expect(!required.allowsNull)
        #expect(required.allowsDefault)
        #expect(!required.allowsEmptyString)
        #expect(!required.usesMultilineEditor(for: ChangeValue(kind: "text", value: "1")))
        let generated = GridColumnEditing(column: column, metadata: ["editable": "false", "nullable": "true", "generated": "identity always"])
        #expect(!generated.isEditable && !generated.allowsNull && !generated.allowsDefault)
        let nullable = GridColumnEditing(column: column, metadata: ["editable": "true", "nullable": "true"])
        #expect(nullable.allowsNull)
    }

    @Test func emptyStringIsOfferedOnlyForStringColumns() {
        let types: [(DatabaseEngine, String, UInt32, Bool)] = [
            (.postgresql, "text", 25, true), (.postgresql, "character varying(120)", 1043, true),
            (.postgresql, "numeric(30,10)", 1700, false), (.postgresql, "jsonb", 3802, false),
            (.postgresql, "date", 1082, false), (.mysql, "varchar(255)", 0, true),
            (.mysql, "longtext", 0, true), (.mysql, "decimal(30,10)", 0, false),
            (.mysql, "json", 0, false), (.mysql, "enum('a','b')", 0, false)]
        for (engine, type, oid, expected) in types {
            let column = ResultColumn(index: 0, name: "value", typeOid: oid, engine: engine, nativeType: type)
            let policy = GridColumnEditing(column: column, metadata: ["editable": "true"])
            #expect(policy.allowsEmptyString == expected, "Unexpected empty string action for \(type)")
        }
    }

    @Test func largeStructuredAndBinaryValuesUseTheExpandedEditor() {
        let metadata = ["editable": "true"]
        let varchar = GridColumnEditing(column: ResultColumn(index: 0, name: "label", nativeType: "varchar(255)"), metadata: metadata)
        #expect(!varchar.usesMultilineEditor(for: ChangeValue(kind: "text", value: "short")))
        #expect(varchar.usesMultilineEditor(for: ChangeValue(kind: "text", value: "first\nsecond")))
        #expect(varchar.usesMultilineEditor(for: ChangeValue(kind: "text", value: String(repeating: "x", count: 161))))
        let json = GridColumnEditing(column: ResultColumn(index: 0, name: "data", nativeType: "jsonb"), metadata: metadata)
        #expect(json.usesMultilineEditor(for: ChangeValue(kind: "text", value: "{}")))
        let binary = GridColumnEditing(column: ResultColumn(index: 0, name: "payload", nativeType: "bytea", encoding: "base64"), metadata: metadata)
        #expect(binary.isBinary && !binary.allowsEmptyString)
        #expect(binary.usesMultilineEditor(for: ChangeValue(kind: "binary", value: "AP8=")))
    }
}
