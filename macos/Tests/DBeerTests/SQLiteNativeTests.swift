import Foundation
import Testing
@testable import DBeer

/// Pure model, parser and private artifact tests; no windows or application activation.
struct SQLiteNativeTests {
    private func settings(path: String = "/fixture/local.sqlite") -> ConnectionSettings {
        ConnectionSettings(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable",
            engine: .sqlite, sqlite: SQLiteSettings(path: path))
    }

    @Test func sharedProtocolFixtureDecodesExactTypes() throws {
        struct Fixture: Decodable { var version: Int; var connection: ConnectionSettings; var typedValues: [SQLiteValue] }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("protocol/fixtures/sqlite-v1.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
        #expect(fixture.version == BackendProtocol.version && fixture.connection.hasValidNativeFields)
        let validValues = fixture.typedValues.allSatisfy { $0.valid }
        #expect(validValues)
        #expect(fixture.typedValues[1].changeValue.value == "9223372036854775807")
    }

    @Test func typedClipboardCarriesStorageClassesForMixedColumns() throws {
        let columns = [ResultColumn(index: 0, name: "mixed", engine: .sqlite, nativeType: "dynamic")]
        let values = [[SQLiteValue(type: "text", value: "TlVMTA==")], [SQLiteValue(type: "blob", value: "AP8=")]]
        let payload = try ResultCopy.selection(columns: columns, rows: [["NULL"], ["AP8="]], sqliteValues: values,
            rowIndices: [0, 1], columnIndices: [0])
        #expect(payload.sqliteValues == values)
        #expect(payload.values[0][0].kind == .text && payload.values[1][0].kind == .binary)
        #expect(try InsertCopyTarget(engine: .sqlite, schema: "main", table: "target", columnNames: ["mixed"]).request(payload: payload).sqliteValues == values)
    }

    @Test func fileProfilesValidateWithoutNetworkFieldsAndRoundtrip() throws {
        let valid = settings()
        #expect(valid.hasValidNativeFields)
        let saved = SavedConnection(name: "Local", settings: valid)
        #expect(try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(saved)) == saved)
        #expect(saved.settings(password: "") == valid)
        #expect(!settings(path: "relative.sqlite").hasValidNativeFields)
        #expect(!settings(path: "//server/share.sqlite").hasValidNativeFields)
        var invalid = valid
        invalid.password = "unexpected"
        #expect(!invalid.hasValidNativeFields)
        invalid = valid
        invalid.ssh = SSHConfiguration(host: "ssh.example.test", user: "user", authMethod: .agent).runtime(profileId: UUID())
        #expect(!invalid.hasValidNativeFields)
    }

    @Test func portableProfileIncludesOnlyFilenameAndRequiresLocalSelection() throws {
        let data = try ProfileTransfer.encode([SavedConnection(name: "Local", settings: settings())])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("local.sqlite") && !text.contains("/fixture/"))
        let preview = try #require(ProfileTransfer.preview(data).first)
        #expect(preview.requiresSQLiteSelection && preview.profile.sqlite?.path == "")
        #expect(preview.sqliteFileNameHint == "local.sqlite")
    }

    @Test func sqliteTriggersCasesAndQuotedIdentifiersStayWhole() {
        let sql = """
        CREATE TEMP TRIGGER audit AFTER INSERT ON [source;table] BEGIN
          INSERT INTO audit VALUES (CASE WHEN NEW.id = 1 THEN 'semi;colon' ELSE 'END' END);
          UPDATE `other;table` SET value = NEW.id;
        END;
        ATTACH DATABASE '/fixture/other.sqlite' AS other;
        SELECT * FROM other.audit;
        """
        let result = SQLScriptParser.parse(sql, engine: .sqlite)
        #expect(result.diagnostics.isEmpty && result.statements.count == 3)
        #expect(result.statements.first?.sql.hasSuffix("END") == true)
        for statement in result.statements {
            #expect((sql as NSString).substring(with: statement.range) == statement.sql)
        }
        #expect(!SQLScriptParser.parse("CREATE TRIGGER t AFTER INSERT ON source BEGIN SELECT 1;", engine: .sqlite).diagnostics.isEmpty)
    }

    @MainActor @Test func typedOriginalsPreserveStorageClassesAndMissingTypesPreventEditing() {
        let columns = [ResultColumn(index: 0, name: "id", engine: .sqlite, nativeType: "INTEGER"),
                       ResultColumn(index: 1, name: "value", engine: .sqlite, nativeType: "BLOB")]
        var message = BackendMessage(type: "query.result", requestId: "fixture", columns: columns, rows: [["1", "NULL"]])
        let metadata = [["name": "id", "nativeType": "INTEGER", "primaryKey": "1", "editable": "true"],
                        ["name": "value", "nativeType": "BLOB", "primaryKey": "0", "editable": "true"]]
        let table = TableReference(schema: "main", name: "fixture", kind: "table")
        #expect(GridDraft(reference: table, result: message, metadata: metadata).readOnlyReason != nil)
        message.sqliteValues = [[SQLiteValue(type: "integer", value: "1"), SQLiteValue(type: "text", value: "TlVMTA==")]]
        let grid = GridDraft(reference: table, result: message, metadata: metadata)
        #expect(grid.canEdit && grid.displayedRows == [["1", "NULL"]])
        grid.set(ChangeValue(kind: "sqliteBlob", value: "AP8="), row: 0, column: 1)
        let change = grid.request().changes.first
        #expect(change?.original?[1] == ChangeValue(kind: "sqliteText", value: "TlVMTA=="))
        #expect(change?.values?.first?.value == ChangeValue(kind: "sqliteBlob", value: "AP8="))
    }

    @Test func snapshotsAndJSONRetainTypedBytes() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/sqlite/native-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let values = [[SQLiteValue(type: "integer", value: "9223372036854775807")],
                      [SQLiteValue(type: "blob", value: "AP8=")], [SQLiteValue(type: "text", value: "/w==")]]
        let rows: [[String?]] = [["9223372036854775807"], ["AP8="], ["<TEXT bytes: /w==>"]]
        let columns = [ResultColumn(index: 0, name: "mixed", engine: .sqlite, nativeType: "BLOB")]
        let store = ResultSnapshotStore(rootURL: root)
        let capture = ResultSnapshotCapture(title: "Typed", sql: "SELECT mixed FROM fixture", engine: .sqlite,
            columns: columns, rows: rows, sqliteValues: values)
        let saved = try await store.save(capture)
        let loaded = try await store.load(id: saved.id, offset: 1, limit: 2)
        #expect(loaded.sqliteValues == Array(values.suffix(2)) && loaded.rows == Array(rows.suffix(2)))
        let export = ExportResultSet(columns: columns, rows: rows, sqliteValues: values)
        #expect(String(decoding: try ResultExport.json([export]), as: UTF8.self).contains("sqliteValues"))
        #expect(throws: ResultExportError.self) { try ResultExport.csv(export, nullMarker: "\\N") }
    }
}


extension SQLiteNativeTests {
    @Test func realHelperCreatesStreamsBindsAndBrowsesSQLiteWithoutUI() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/sqlite/backend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fixture.sqlite").path
        let connection = settings(path: path)
        let client = BackendClient(executableURL: repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core"))
        var stage = "helper startup"
        do {
            try await client.start()
            stage = "database creation"
            _ = try await client.request(.sqliteCreate(connection))
            #expect(FileManager.default.fileExists(atPath: path))
            await #expect(throws: Error.self) { try await client.request(.sqliteCreate(connection)) }
            stage = "connection"
            let connected = try await client.request(.connect(connection))
            let session = try #require(connected.sessionId)
            #expect(connected.engine == .sqlite && connected.transactionStatus == .idle)
            func execute(_ sql: String, parameters: [QueryParameterBinding]? = nil) async throws -> BackendMessage {
                let operation = OperationRequest(type: "execute", sql: sql, parameters: parameters)
                let reviewed = try await client.request(.assess(sessionId: session, operations: [operation]))
                let assessment = try #require(reviewed.assessment)
                try #require(assessment.decision != "deny")
                var command = BackendCommand.execute(sessionId: session, sql: sql, parameters: parameters)
                command.authorization = assessment.authorization
                return try await client.request(command)
            }
            stage = "table creation"
            _ = try await execute("CREATE TABLE mixed(id INTEGER PRIMARY KEY, value)")
            stage = "fixture insertion"
            _ = try await execute("INSERT INTO mixed VALUES(1,NULL),(2,9223372036854775807),(3,1.5),(4,'NULL'),(5,X'00ff')")
            stage = "mixed-value streaming"
            let result = try await execute("SELECT id,value FROM mixed ORDER BY id")
            let typed = try #require(result.sqliteValues)
            #expect(result.rows?.count == 5 && result.resultSets?.first?.sqliteValues == typed)
            #expect(typed[0][1].type == "null" && typed[1][1].value == "9223372036854775807")
            #expect(typed[2][1].type == "real" && typed[3][1].type == "text" && typed[4][1].type == "blob")
            stage = "parameter binding"
            let parameterized = try await execute("SELECT :n AS number,:d AS date", parameters: [
                QueryParameterBinding(name: "n", type: .integer, value: "9223372036854775807"),
                QueryParameterBinding(name: "d", type: .date, value: "2026-11-04")])
            #expect(parameterized.sqliteValues?.first?[0].value == "9223372036854775807")
            #expect(parameterized.sqliteValues?.first?[1].displayText == "2026-11-04")
            stage = "schema catalog"
            let schemas = try await client.request(.catalog(sessionId: session, request: CatalogRequest(kind: "schemas")))
            #expect(schemas.catalogRecords.contains { $0["name"] == "main" })
            stage = "table catalog"
            let tables = try await client.request(.catalog(sessionId: session,
                request: CatalogRequest(kind: "objects", schema: "main", objectKind: "table")))
            #expect(tables.catalogRecords.contains { $0["name"] == "mixed" })
            stage = "typed export"
            let destination = directory.appendingPathComponent("typed.json")
            let export = ExportRequest(path: destination.path, format: "json")
            let exportSQL = "SELECT id,value FROM mixed ORDER BY id"
            let review = try await client.request(.assess(sessionId: session,
                operations: [OperationRequest(type: "execute", sql: exportSQL, export: export)]))
            var exportCommand = BackendCommand.runToFile(sessionId: session, sql: exportSQL, export: export)
            exportCommand.authorization = try #require(review.assessment?.authorization)
            let exported = try await client.request(exportCommand)
            #expect(exported.exportRowCount == 5)
            let data = try Data(contentsOf: destination)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["version"] as? Int == 2 && object["nativeValuesFormat"] as? String == "nativeV1")
            let exportedSet = try #require(ResultExport.decodeJSON(data).first)
            #expect(exportedSet.sqliteValues == typed && exportedSet.rows == result.rows)
            let native = try #require(result.nativeValues)
            #expect(exportedSet.nativeValues == native)
            stage = "disconnect"
            _ = try await client.request(.disconnect(sessionId: session))
            _ = await client.shutdown()
        } catch {
            _ = await client.shutdown()
            Issue.record("SQLite helper integration failed during \(stage): \(error)")
            throw error
        }
    }
}
