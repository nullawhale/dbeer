import Foundation
import Testing
@testable import DBeer

@MainActor
struct NativeBindingTests {
    @Test func gridOriginalBindingsUseExactCapturedScalarsAndKeepDisplaySeparate() throws {
        let columns = [ResultColumn(index: 0, name: "id", nativeType: "bigint"), ResultColumn(index: 1, name: "value", nativeType: "numeric")]
        let native: [[NativeValue]] = [[.init(kind: "integer", value: "9007199254740993"), .init(kind: "decimal", value: "1234567890.123456789")]]
        let grid = GridDraft(reference: .init(schema: "public", name: "values", kind: "table"),
            result: .init(type: "query.result", requestId: "r", columns: columns, rows: [["rounded key", "formatted value"]], nativeValues: native),
            metadata: [["name":"id", "primaryKey":"1", "editable":"false"], ["name":"value", "editable":"true"]])
        #expect(grid.canEdit && grid.nativeValues == native)
        #expect(grid.displayedRows == [["rounded key", "formatted value"]])
        #expect(grid.rows[0].original?[0].value == "9007199254740993")
        grid.set(.init(kind: "text", value: "2"), row: 0, column: 1)
        #expect(grid.nativeValues == nil && grid.displayedRows == [["rounded key", "2"]])
        let change = try #require(grid.request().changes.first)
        #expect(change.original?[0].value == "9007199254740993")
        #expect(change.original?[1].value == "1234567890.123456789")
    }

    @Test func unsupportedOriginalNeverBecomesEditFilterOrKeyAuthority() throws {
        let columns = [ResultColumn(index: 0, name: "id", nativeType: "bigint"), ResultColumn(index: 1, name: "value", nativeType: "custom")]
        for native in [NativeValue(kind: "opaque", value: "AP8=", engine: "postgresql", nativeType: "custom"),
                       .init(kind: "text", value: "actual", typeIdentity: "unresolved:custom"),
                       .init(kind: "list", items: [.init(kind: "integer", value: "1")]),
                       .init(kind: "float64", value: "8000000000000000")] {
            let grid = GridDraft(reference: .init(schema: "public", name: "values", kind: "table"),
                result: .init(type: "query.result", requestId: "r", columns: columns, rows: [["1", "formatted"]],
                    nativeValues: [[.init(kind: "integer", value: "1"), native]]),
                metadata: [["name":"id", "primaryKey":"1", "editable":"false"], ["name":"value", "editable":"true"]])
            grid.supportsEditing = true // Runtime capability cannot overrule missing value evidence.
            #expect(!grid.canEditRow(0) && grid.rowReadOnlyReason(0)?.contains("lossless edit binding") == true)
            #expect(grid.rows[0].values[1].kind == "unresolved")
            #expect(grid.nativeValues?[0][1] == native)
            #expect(throws: TableCellFilterError.self) {
                try TableCellFilters.adding(.equal, column: columns[1], values: [grid.rows[0].values[1]], to: .init())
            }
        }
    }

    @Test func sqliteStorageAndNativeTreesMustAgreeBeforeTheyAreTransported() throws {
        let columns = [ResultColumn(index: 0, name: "value", engine: .sqlite)]
        let storage = [[SQLiteValue(type: "integer", value: "1")]]
        let mismatched = [[NativeValue(kind: "integer", value: "2", engine: "sqlite", nativeType: "integer")]]
        let set = QueryResultSet(columns: columns, rows: [["1"]], rowCount: 1, displayedRowCount: 1,
            sqliteValues: storage, nativeValues: mismatched)
        #expect(!set.valid())
        let reply = BackendMessage(type: "query.result", requestId: "r", sessionId: "s", queryId: "q", transactionStatus: .idle,
            durationMs: 0, columns: columns, rows: [["1"]], sqliteValues: storage, nativeValues: mismatched,
            commandTag: "SELECT", rowCount: 1, displayedRowCount: 1, truncated: false)
        #expect(throws: BackendTransportError.self) { try reply.validate() }
    }


    @Test func referencedKeyChoiceUsesNativeEvidenceInsteadOfFormattedRows() async throws {
        let key = TableForeignKey(name: "key", target: .init(schema: "public", name: "parent", kind: "table"),
            columns: [.init(source: "fk", target: "id", position: 1)])
        let source = [ResultColumn(index: 0, name: "fk", typeOid: 20, nativeType: "int8")]
        let target = [ResultColumn(index: 0, name: "id", typeOid: 20, nativeType: "int8")]
        let fields = [ResultColumn(index: 0, name: "name"), ResultColumn(index: 1, name: "nativeType")]
        var staged: [Int: ChangeValue]?
        let model = ForeignKeyPickerModel(key: key, engine: .postgresql, sourceColumns: source, isCurrent: { true }, read: { request in
            if request.kind == "columns" { return .init(type: "query.result", requestId: "metadata", columns: fields, rows: [["id", "bigint"]]) }
            return .init(type: "query.result", requestId: "browse", columns: target, rows: [["rounded"]],
                nativeValues: [[.init(kind: "integer", value: "9007199254740993")]])
        }, cancel: {}, stage: { staged = $0 })
        await model.load()
        let row = try #require(model.rows.first)
        #expect(model.choose(row))
        #expect(staged?[0]?.value == "9007199254740993")
        await model.close()
    }

    @Test func insertCopyUsesProvenNativePrimitivesAndRejectsRepresentations() throws {
        let columns = [ResultColumn(index: 0, name: "value", nativeType: "numeric")]
        let primitive = try ResultCopy.selection(columns: columns, rows: [["rounded"]],
            nativeValues: [[.init(kind: "decimal", value: "9007199254740993.123456789")]], rowIndices: [0], columnIndices: [0])
        let target = InsertCopyTarget(engine: .postgresql, schema: "public", table: "target", columnNames: ["value"])
        #expect(try target.request(payload: primitive).rows[0][0].value == "9007199254740993.123456789")
        for native in [NativeValue(kind: "list", items: [.init(kind: "integer", value: "1")]),
                       .init(kind: "opaque", value: "AP8=", engine: "postgresql", nativeType: "unknown"),
                       .init(kind: "float64", value: "3ff0000000000000")] {
            let selected = try ResultCopy.selection(columns: columns, rows: [["formatted"]],
                nativeValues: [[native]], rowIndices: [0], columnIndices: [0])
            #expect(throws: ResultCopyError.self) { try target.request(payload: selected) }
        }
    }

    @Test func finiteFloatBindingsUseCapturedWidthAndBitsForEditsAndInsertCopy() throws {
        let identity = "pgtype-v1:" + String(repeating: "b", count: 64)
        let column = ResultColumn(index: 1, name: "value", typeOid: 700, nativeType: "float4", typeIdentity: identity)
        let native = NativeValue(kind: "float32", value: "80000000", engine: "postgresql", nativeType: "float4", typeIdentity: identity)
        let columns = [ResultColumn(index: 0, name: "id", typeOid: 23, nativeType: "int4"), column]
        let grid = GridDraft(reference: .init(schema: "public", name: "floats", kind: "table"),
            result: .init(type: "query.result", requestId: "r", columns: columns, rows: [["1", "formatted"]],
                nativeValues: [[.init(kind: "integer", value: "1"), native]]),
            metadata: [["name":"id", "primaryKey":"1", "editable":"false"], ["name":"value", "editable":"true"]])
        #expect(grid.canEdit && grid.displayedRows[0][1] == "formatted")
        let original = try #require(grid.rows[0].original?[1].value)
        #expect(Float(original)?.bitPattern == 0x80000000)
        grid.set(.init(kind: "text", value: "1.5"), row: 0, column: 1)
        #expect(Float(try #require(grid.request().changes.first?.original?[1].value))?.bitPattern == 0x80000000)
        let payload = try ResultCopy.selection(columns: [ResultColumn(index: 0, name: "value", typeOid: 700, nativeType: "float4", typeIdentity: identity)],
            rows: [["formatted"]], nativeValues: [[native]], rowIndices: [0], columnIndices: [0])
        let request = try InsertCopyTarget(engine: .postgresql, schema: "public", table: "target", columnNames: ["value"]).request(payload: payload)
        #expect(Float(try #require(request.rows[0][0].value))?.bitPattern == 0x80000000)
        for bits in ["7f800000", "7fc00001"] {
            let special = NativeValue(kind: "float32", value: bits, engine: "postgresql", nativeType: "float4", typeIdentity: identity)
            #expect(special.flatChangeValue(for: column) == nil)
        }
        let wrongWidth = ResultColumn(index: 1, name: "value", typeOid: 701, nativeType: "float4", typeIdentity: identity)
        #expect(native.flatChangeValue(for: wrongWidth) == nil)
        let unresolved = NativeValue(kind: "float32", value: "80000000", engine: "postgresql", nativeType: "float4", typeIdentity: "unresolved:" + identity)
        #expect(unresolved.flatChangeValue(for: column) == nil)
        let mysqlIdentity = "{\"engine\":\"mysql\",\"type\":5,\"decimals\":31}"
        let mysql = NativeValue(kind: "float64", value: "3fb999999999999a", engine: "mysql", nativeType: "DOUBLE", typeIdentity: mysqlIdentity)
        let mysqlColumn = ResultColumn(index: 0, name: "value", engine: .mysql, nativeType: "DOUBLE", typeIdentity: mysqlIdentity)
        #expect(Double(try #require(mysql.flatChangeValue(for: mysqlColumn)?.value))?.bitPattern == 0x3fb999999999999a)
    }

    @Test func mixedRowsKeepProvenEditsAvailableAndFenceOnlyUnboundOriginals() throws {
        let columns = [ResultColumn(index: 0, name: "id", typeOid: 23, nativeType: "int4"),
            ResultColumn(index: 1, name: "value", typeOid: 1700, nativeType: "numeric")]
        let native: [[NativeValue]] = [[.init(kind: "integer", value: "1"), .init(kind: "decimal", value: "1.000000000000000001")],
            [.init(kind: "integer", value: "2"), .init(kind: "opaque", value: "AP8=", engine: "postgresql", nativeType: "numeric")]]
        let original = BackendMessage(type: "query.result", requestId: "r", columns: columns, rows: [["1", "rounded"], ["2", "opaque display"]], nativeValues: native)
        let metadata = [["name":"id", "primaryKey":"1", "editable":"false"], ["name":"value", "editable":"true"]]
        let grid = GridDraft(reference: .init(schema: "public", name: "mixed", kind: "table"), result: original, metadata: metadata)
        #expect(grid.canEdit && grid.canEditRow(0) && !grid.canEditRow(1) && grid.uneditableRows == [1])
        grid.set(.init(kind: "text", value: "3"), row: 0, column: 1)
        grid.set(.init(kind: "text", value: "should not bind"), row: 1, column: 1)
        let changes = grid.request().changes
        #expect(changes.count == 1 && changes[0].original?[1].value == "1.000000000000000001" && grid.canApply)
        #expect(grid.rows[1].assignments.isEmpty && grid.rows[1].values[1].kind == "unresolved")
        grid.selectedRows = [0, 1]; grid.deleteSelected()
        #expect(!grid.rows[0].isDeleted && !grid.rows[1].isDeleted)
        grid.discard()
        #expect(grid.nativeValues == native && grid.uneditableRows == [1] && grid.pendingCount == 0)
        var malformed = original; malformed.nativeValues = [native[0]]
        let invalid = GridDraft(reference: grid.reference, result: malformed, metadata: metadata)
        #expect(!invalid.canEdit && invalid.readOnlyReason?.contains("matrix is invalid") == true)
    }

    private struct ScalarBindingsFixture: Decodable {
        struct Record: Decodable { var column: ResultColumn; var native: NativeValue }
        var cassandra: [Record]; var mysql: [Record]; var cassandraUnsupported: [Record]
    }
    @Test func resolvedNativeScalarBindingsPreserveExistingRowsAndOriginals() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(ScalarBindingsFixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/native-scalar-bindings-v1.json")))
        #expect(fixture.cassandra.count == 5 && fixture.mysql.count == 6 && fixture.cassandraUnsupported.count == 2)
        for entry in fixture.cassandra + fixture.mysql {
            #expect(entry.native.flatChangeValue(for: entry.column) == .init(kind: "text", value: entry.native.value))
            let label = ResultColumn(index: 1, name: "label", engine: entry.column.engine, nativeType: "text")
            let grid = GridDraft(reference: .init(schema: "fixture", name: "scalars", kind: "table"),
                result: .init(type: "query.result", requestId: "r", columns: [entry.column, label], rows: [["formatted", "old"]],
                    nativeValues: [[entry.native, .init(kind: "text", value: "old")]]),
                metadata: [["name": entry.column.name, "primaryKey": "1", "partitionKeyPosition": "1", "editable": "false"], ["name": "label", "editable": "true"]])
            #expect(grid.canEditRow(0))
            grid.set(.init(kind: "text", value: "edited"), row: 0, column: 1)
            #expect(grid.request().changes.first?.original?[0].value == entry.native.value)
            #expect(grid.pendingCount == 1 && grid.canApply)
        }
    }
    @Test func resolvedNativeScalarBridgeRejectsUnknownOrMismatchedAuthority() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(ScalarBindingsFixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/native-scalar-bindings-v1.json")))
        for entry in fixture.cassandra + fixture.mysql {
            for mutation in 0..<5 {
                var native = entry.native
                switch mutation {
                case 0: native.typeIdentity = "unresolved:" + (native.typeIdentity ?? "")
                case 1: native.typeIdentity = nil
                case 2: native.nativeType = "unknown"
                case 3: native.engine = "mongodb"
                default: native.typeIdentity = "{}"
                }
                #expect(native.flatChangeValue(for: entry.column) == nil)
            }
        }
        for entry in fixture.cassandraUnsupported {
            #expect(entry.native.kind == "opaque" && entry.native.flatChangeValue(for: entry.column) == nil)
        }
        for type in ["TIMESTAMP", "FLOAT", "ENUM", "SET", "duration", "custom"] {
            let engine: DatabaseEngine = type == "duration" || type == "custom" ? .cassandra : .mysql
            let column = ResultColumn(index: 0, name: "v", engine: engine, nativeType: type, typeIdentity: "{}")
            #expect(NativeValue(kind: "native", value: "text", engine: engine.rawValue, nativeType: type, typeIdentity: "{}").flatChangeValue(for: column) == nil)
        }
    }

}
