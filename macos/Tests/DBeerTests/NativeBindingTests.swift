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

    @Test func mariaDBStoredChoicesRequireRowWitnessWithoutBecomingFlatBindings() throws {
        let token = "mariadb.storage.v1:" + String(repeating: "a", count: 64)
        let enumIdentity = #"unresolved:{"engine":"mariadb","type":254,"charset":45,"flags":256}"#
        let setIdentity = #"unresolved:{"engine":"mariadb","type":254,"charset":45,"flags":2048}"#
        let binaryIdentity = #"unresolved:{"engine":"mariadb","type":254,"charset":63,"flags":256}"#
        let columns = [ResultColumn(index: 0, name: "id", engine: .mariadb, nativeType: "BIGINT"),
            ResultColumn(index: 1, name: "e", engine: .mariadb, nativeType: "ENUM", typeIdentity: enumIdentity),
            ResultColumn(index: 2, name: "s", engine: .mariadb, nativeType: "SET", typeIdentity: setIdentity),
            ResultColumn(index: 3, name: "b", engine: .mariadb, nativeType: "ENUM", encoding: "base64", typeIdentity: binaryIdentity)]
        let native: [[NativeValue]] = [[.init(kind: "integer", value: "1", engine: "mariadb", nativeType: "BIGINT"),
            .init(kind: "native", value: "", engine: "mariadb", nativeType: "ENUM", typeIdentity: enumIdentity),
            .init(kind: "null", engine: "mariadb", nativeType: "SET", typeIdentity: setIdentity),
            .init(kind: "binary", value: "AP8=", engine: "mariadb", nativeType: "ENUM", typeIdentity: binaryIdentity)]]
        let metadata = [["name":"id", "primaryKey":"1", "editable":"true"], ["name":"e", "editable":"true"],
            ["name":"s", "editable":"true"], ["name":"b", "editable":"true"]]
        let reply = BackendMessage(type: "query.result", requestId: "r", columns: columns,
            rows: [["1", "", nil, "AP8="]], nativeValues: native, storageTokens: [token])
        let grid = GridDraft(reference: .init(schema: "fixture", name: "choices", kind: "table"), result: reply, metadata: metadata)
        #expect(grid.canEditRow(0) && grid.nativeValues == native)
        let view = GridDraft(reference: .init(schema: "fixture", name: "choices", kind: "view"), result: reply, metadata: metadata)
        #expect(!view.canEditRow(0) && view.rows[0].nativeBindingUnavailable)
        grid.set(.init(kind: "text", value: "2"), row: 0, column: 0)
        let change = try #require(grid.request().changes.first)
        #expect(change.storageToken == token && change.original == [.init(kind: "text", value: "1"),
            .init(kind: "text", value: ""), .null, .init(kind: "binary", value: "AP8=")])
        grid.discard()
        #expect(grid.canEditRow(0) && grid.nativeValues == native && grid.rows[0].originalStorageToken == token)
        for invalid in [Optional<String>.none, "mysql.storage.v1:" + String(repeating: "a", count: 64),
                        "mariadb.storage.v1:", "mariadb.storage.v1:" + String(repeating: "A", count: 64)] {
            var missing = reply; missing.storageTokens = invalid.map { [$0] }
            let fenced = GridDraft(reference: grid.reference, result: missing, metadata: metadata)
            #expect(!fenced.canEditRow(0) && fenced.nativeValues == native)
        }
        for index in 1..<columns.count {
            let cell = native[0][index], column = columns[index]
            #expect(cell.flatChangeValue(for: column) == nil)
            var mismatched = cell; mismatched.engine = "mysql"
            #expect(mismatched.mariaDBStoredChoiceOriginal(for: column, storageToken: token) == nil)
            mismatched = cell; mismatched.typeIdentity = "unresolved:{}"
            #expect(mismatched.mariaDBStoredChoiceOriginal(for: column, storageToken: token) == nil)
        }
        let selectedSet = NativeValue(kind: "native", value: "a,b", engine: "mariadb", nativeType: "SET", typeIdentity: setIdentity)
        #expect(selectedSet.mariaDBStoredChoiceOriginal(for: columns[2], storageToken: token) == .init(kind: "text", value: "a,b"))
        for identity in [#"unresolved:{"engine":"mysql","type":254,"flags":256}"#,
                         #"unresolved:{"engine":"mariadb","type":254,"flags":0}"#,
                         #"unresolved:{"engine":"mariadb","type":255,"flags":256}"#] {
            var cell = native[0][1]; cell.typeIdentity = identity
            let column = ResultColumn(index: 1, name: "e", engine: .mariadb, nativeType: "ENUM", typeIdentity: identity)
            #expect(cell.mariaDBStoredChoiceOriginal(for: column, storageToken: token) == nil)
        }
        var unrelated = native[0][1]; unrelated.nativeType = "GEOMETRY"
        let geometry = ResultColumn(index: 0, name: "g", engine: .mariadb, nativeType: "GEOMETRY", typeIdentity: enumIdentity)
        #expect(unrelated.mariaDBStoredChoiceOriginal(for: geometry, storageToken: token) == nil)
        unrelated = native[0][1]; unrelated.kind = "opaque"; unrelated.value = "AP8="
        #expect(unrelated.mariaDBStoredChoiceOriginal(for: columns[1], storageToken: token) == nil)
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
    @Test func nativeArrayAndDomainNavigationRetainsCapturedOIDGuards() throws {
        let profile = SavedConnection(name: "Fixture", settings: .init(host: "fixture.invalid", port: 5432,
            database: "fixture", user: "fixture", password: "", sslMode: "disable"))
        let endpoint = LogicalRelationshipEndpoint(profile: profile, reference: .init(schema: "public", name: "source", kind: "table"))
        let identity = "pgtype-v1:" + String(repeating: "a", count: 64)
        for (declaration, wireName, wireOID, declaredOID, baseOID, native, encoding) in [
            ("integer[]", "_int4", UInt32(1007), UInt32(1007), UInt32(1007),
                NativeValue(kind: "native", value: "[0:1]={1,2}", engine: "postgresql", nativeType: "_int4", typeIdentity: identity), Optional<String>.none),
            ("fixture.binary_key", "bytea", UInt32(17), UInt32(20_001), UInt32(17),
                NativeValue(kind: "binary", value: "AP8=", engine: "postgresql", nativeType: "bytea", typeIdentity: identity), Optional("base64"))
        ] {
            let column = ResultColumn(index: 0, name: "value", typeOid: wireOID, nativeType: wireName, encoding: encoding, typeIdentity: identity)
            let grid = GridDraft(reference: endpoint.reference,
                result: .init(type: "query.result", requestId: "r", columns: [column], rows: [["formatted"]], nativeValues: [[native]]),
                metadata: [["name":"value", "nativeType": declaration, "typeOid":String(declaredOID), "baseTypeOid":String(baseOID), "primaryKey":"1", "editable":"true"]])
            let relationship = LogicalRelationship(name: "Exact navigation", source: endpoint, target: endpoint,
                columns: [.init(source: "value", target: "value", sourceType: declaration, targetType: declaration)])
            #expect(grid.canEdit)
            let values = try #require(grid.rows[0].original)
            let filters = try LogicalRelationshipNavigation.filters(relationship, sourceColumns: [column], sourceDeclarations: [declaration],
                sourceTypeOIDs: [declaredOID], sourceBaseTypeOIDs: [baseOID], values: values)
            #expect(filters.first?.nativeValue?.cell.value == native.value)
            #expect(filters.first?.nativeValue?.cell.kind == (encoding == nil ? "text" : "binary"))
            #expect(throws: LogicalRelationshipError.self) {
                try LogicalRelationshipNavigation.filters(relationship, sourceColumns: [column], sourceDeclarations: [declaration],
                    sourceTypeOIDs: [20_002], sourceBaseTypeOIDs: [25], values: values)
            }
        }
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
