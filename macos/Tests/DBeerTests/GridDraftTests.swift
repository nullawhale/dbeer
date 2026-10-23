import Foundation
import Testing
@testable import DBeer

@MainActor
struct GridDraftTests {
    private func draft() -> GridDraft {
        let columns = [ResultColumn(index: 0, name: "id", typeOid: 23, nativeType: "int4"),
            ResultColumn(index: 1, name: "value", typeOid: 25, nativeType: "text"),
            ResultColumn(index: 2, name: "payload", typeOid: 17, nativeType: "bytea", encoding: "base64"),
            ResultColumn(index: 3, name: "computed", typeOid: 23, nativeType: "int4")]
        let result = BackendMessage(type: "query.result", requestId: "fixture", columns: columns,
            rows: [["1", "", "AP8=", "2"], ["2", nil, "", "4"]])
        let metadata = [
            ["name": "id", "nativeType": "integer", "primaryKey": "1", "editable": "true", "generated": ""],
            ["name": "value", "nativeType": "text", "primaryKey": "0", "editable": "true", "generated": ""],
            ["name": "payload", "nativeType": "bytea", "primaryKey": "0", "editable": "true", "generated": ""],
            ["name": "computed", "nativeType": "integer", "primaryKey": "0", "editable": "false", "generated": "id * 2"]
        ]
        return GridDraft(reference: TableReference(schema: "odd\"schema", name: "table", kind: "table"), result: result, metadata: metadata)
    }

    @Test func stagingKeepsFullTypedOriginalAndNeverInterpolatesSQL() throws {
        let grid = draft()
        #expect(grid.pendingCount == 0)
        grid.set(.null, row: 0, column: 1)
        grid.set(ChangeValue(kind: "text", value: "'; DROP TABLE important; --"), row: 0, column: 0)
        let request = grid.request()
        #expect(request.changes.count == 1)
        #expect(request.changes[0].kind == "update")
        #expect(request.changes[0].original?[1] == ChangeValue(kind: "text", value: ""))
        #expect(request.changes[0].original?[2] == ChangeValue(kind: "binary", value: "AP8="))
        #expect(request.changes[0].values?.last?.value == .null)
        #expect(request.columns[0].nativeType == "integer")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ChangesRequest.self, from: data)
        #expect(decoded == request)
        #expect(request.changes[0].values?.first?.value.value == "'; DROP TABLE important; --")
        grid.set(ChangeValue(kind: "text", value: "1"), row: 0, column: 0)
        grid.set(ChangeValue(kind: "text", value: ""), row: 0, column: 1)
        #expect(grid.pendingCount == 0)
    }

    @Test func insertDefaultsNullEmptyAndGeneratedCellsStayDistinct() {
        let grid = draft()
        grid.insert()
        #expect(grid.rows.count == 3)
        #expect(grid.request().changes[0].kind == "insert")
        #expect(grid.request().changes[0].values?.isEmpty == true)
        grid.set(ChangeValue(kind: "text", value: "3"), row: 2, column: 0)
        grid.set(ChangeValue(kind: "text", value: ""), row: 2, column: 1)
        grid.set(.null, row: 2, column: 2)
        grid.set(ChangeValue(kind: "text", value: "99"), row: 2, column: 3)
        #expect(grid.rows[2].values[3] == .default)
        #expect(grid.request().changes[0].values?.map(\.column) == ["id", "value", "payload"])
        grid.selectedRows = IndexSet([0, 2])
        grid.deleteSelected()
        #expect(grid.rows.count == 2)
        #expect(grid.request().changes.count == 1)
        #expect(grid.request().changes[0].kind == "delete")
        grid.discard()
        #expect(grid.pendingCount == 0)
        #expect(grid.displayedRows[0][1] == "")
        #expect(grid.displayedRows[1][1] == nil)
    }

    @Test func unknownCommitKeepsApplyDisabledUntilAFreshSnapshot() {
        let grid = draft()
        grid.set(.default, row: 0, column: 1)
        grid.outcomeUnknown = true
        #expect(!grid.canEdit)
        let before = grid.request()
        grid.set(.null, row: 0, column: 1)
        #expect(grid.request() == before)
        grid.discard()
        #expect(grid.outcomeUnknown)
        #expect(!grid.canEdit)
        #expect(draft().canEdit)
    }

    @Test func originalStorageEvidenceSurvivesStagingDiscardAndDelete() throws {
        let reference = TableReference(schema: "fixture", name: "items", kind: "table")
        let result = BackendMessage(type: "query.result", requestId: "storage", columns: [ResultColumn(index: 0, name: "id", nativeType: "int4")],
            rows: [["1"]], storageTokens: ["123/(0,1)/456"])
        let metadata = [["name": "id", "nativeType": "integer", "primaryKey": "1", "editable": "true"]]
        let grid = GridDraft(reference: reference, result: result, metadata: metadata)
        grid.set(ChangeValue(kind: "text", value: "2"), row: 0, column: 0)
        let request = grid.request()
        #expect(request.changes[0].storageToken == result.storageTokens?[0])
        #expect(try JSONDecoder().decode(ChangesRequest.self, from: JSONEncoder().encode(request)) == request)
        grid.discard()
        grid.selectedRows = IndexSet(integer: 0); grid.deleteSelected()
        #expect(grid.request().changes[0].storageToken == result.storageTokens?[0])
        grid.discard(); grid.insert()
        #expect(grid.request().changes[0].kind == "insert" && grid.request().changes[0].storageToken == nil)
    }

    @Test func viewsAndTablesWithoutPrimaryKeysExplainTheirRestriction() {
        let view = GridDraft(reference: TableReference(schema: "public", name: "v", kind: "view"),
            result: BackendMessage(type: "query.result", requestId: "fixture", columns: [], rows: []), metadata: [])
        #expect(view.readOnlyReason == "Views are read only.")
        let noPK = GridDraft(reference: TableReference(schema: "public", name: "t", kind: "table"),
            result: BackendMessage(type: "query.result", requestId: "fixture", columns: [], rows: []), metadata: [])
        #expect(noPK.readOnlyReason == "This table has no primary key.")
    }
}
