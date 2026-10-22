import Foundation
import Testing
@testable import DBeer

/// Storage and migration only: these tests never create windows or sessions.
struct WorkspacePersistenceTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-workspace-\(UUID())")
    }

    private func tableState(page: Int = 4) -> StoredTableDocument {
        StoredTableDocument(reference: TableReference(schema: "odd\"schema", name: "table.with.dots", kind: "table"),
            page: page, filters: [CatalogFilter(column: "exact", operator: "eq", value: "9007199254740993.123456789"),
                CatalogFilter(column: "empty", operator: "eq", value: ""),
                CatalogFilter(column: "missing", operator: "isNull", value: nil)],
            sort: [CatalogSort(column: "key", direction: "desc")])
    }

    @Test func mixedWorkspaceRoundTripsOrderSelectedTableAndDisconnectedContext() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let sql = StoredSQLDocument(title: "Analysis", text: "SELECT 'κόσμος 😀';\r\nSELECT '';", profileID: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/synthetic-sql/with spaces/query.sql"),
            fileContentSHA256: String(repeating: "a", count: 64))
        let table = StoredSQLDocument(title: "Data", text: "Table data", profileID: UUID(), kind: .table, table: tableState())
        let draft = StoredSQLDocument(title: "Unbound draft", text: "BEGIN; SELECT 1;")
        let snapshot = SQLWorkspaceSnapshot(documents: [sql, table, draft], selectedDocumentID: table.id,
            historyEnabled: false, historySettings: SQLHistoryRetentionSettings(maxEntries: 75, retentionDays: 12))
        try await FileSQLDocumentStore(fileURL: url).save(snapshot)
        let restored = try await FileSQLDocumentStore(fileURL: url).load()
        #expect(restored == snapshot)
        #expect(restored.version == SQLWorkspaceSnapshot.currentVersion)
        #expect(restored.documents.map(\.kind) == [.sql, .table, .sql])
        #expect(restored.documents.map(\.id) == [sql.id, table.id, draft.id])
        #expect(restored.selectedDocumentID == table.id)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let records = try #require(json["documents"] as? [[String: Any]])
        #expect(Set(records[1].keys) == ["id", "title", "text", "profileID", "kind", "table"])
        #expect(records.allSatisfy { $0["runtime"] == nil && $0["grid"] == nil && $0["rows"] == nil && $0["connection"] == nil })
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test(arguments: 0...3)
    func everyLegacyVersionMigratesSQLAndNormalizesAnUnsavedSelectedTable(version: Int) async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("workspace.json")
        let id = UUID(), profileID = UUID()
        var object: [String: Any] = ["documents": [["id": id.uuidString, "title": "Legacy", "text": "SELECT '🧪';", "profileID": profileID.uuidString]],
            "selectedDocumentID": UUID().uuidString, "historyEnabled": false, "history": []]
        if version > 0 { object["version"] = version }
        if version >= 3 { object["historySettings"] = ["maxEntries": 75, "retentionDays": 12] }
        let original = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try original.write(to: url)
        let store = FileSQLDocumentStore(fileURL: url)
        let restored = try await store.load()
        #expect(restored.documents == [StoredSQLDocument(id: id, title: "Legacy", text: "SELECT '🧪';", profileID: profileID)])
        #expect(restored.selectedDocumentID == id && restored.version == SQLWorkspaceSnapshot.currentVersion && !restored.historyEnabled)
        #expect(restored.historySettings == (version >= 3 ? SQLHistoryRetentionSettings(maxEntries: 75, retentionDays: 12) : .default))
        let backup = url.appendingPathExtension("v\(version).backup")
        #expect(try Data(contentsOf: backup) == original)
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try await store.load() == restored)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test func v3MigrationPreservesFavoritesSettingsAndTypedHistory() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("workspace.json")
        let historyID = UUID()
        let now = floor(Date.now.timeIntervalSince1970) * 1_000
        let original = Data("""
        {"version":3,"documents":[],"historyEnabled":false,"historySettings":{"maxEntries":75,"retentionDays":12},"history":[
          {"id":"\(historyID)","date":\(now),"sql":"SELECT 'synthetic';","outcome":"failed","isFavorite":true,
           "startedAt":\(now - 25),"finishedAt":\(now),"durationMs":25,"loadedRowCount":3,"affectedRowCount":2,
           "countsArePartial":true,"truncated":true,"sqlState":"42000","errorMessage":"The database rejected the command."}]}
        """.utf8)
        try original.write(to: url)
        let restored = try await FileSQLDocumentStore(fileURL: url).load()
        #expect(restored.version == SQLWorkspaceSnapshot.currentVersion && !restored.historyEnabled)
        #expect(restored.historySettings == SQLHistoryRetentionSettings(maxEntries: 75, retentionDays: 12))
        let entry = try #require(restored.history.first)
        #expect(entry.id == historyID && entry.isFavorite && entry.outcome == .failed)
        #expect(entry.durationMs == 25 && entry.loadedRowCount == 3 && entry.affectedRowCount == 2)
        #expect(entry.countsArePartial == true && entry.truncated == true && entry.sqlState == "42000")
        #expect(try Data(contentsOf: url.appendingPathExtension("v3.backup")) == original)
    }

    @Test func anExistingMigrationBackupIsNeverReplaced() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("workspace.json")
        let original = Data("{\"version\":3,\"documents\":[],\"historySettings\":{\"maxEntries\":1000,\"retentionDays\":30}}".utf8)
        try original.write(to: url)
        let foreign = Data("previous backup".utf8)
        try foreign.write(to: url.appendingPathExtension("v3.backup"))
        _ = try await FileSQLDocumentStore(fileURL: url).load()
        #expect(try Data(contentsOf: url.appendingPathExtension("v3.backup")) == foreign)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let generated = try #require(names.first { $0.hasPrefix("workspace.json.v3-") && $0.hasSuffix(".backup") })
        #expect(try Data(contentsOf: directory.appendingPathComponent(generated)) == original)
    }

    @Test func invalidTypedDocumentStateCannotReplaceValidWorkspace() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let valid = StoredSQLDocument(title: "Keep", text: "SELECT 1;")
        let store = FileSQLDocumentStore(fileURL: url)
        try await store.save(SQLWorkspaceSnapshot(documents: [valid], selectedDocumentID: valid.id))
        let original = try Data(contentsOf: url)
        let invalid: [StoredSQLDocument] = [
            StoredSQLDocument(title: "Wrong kind", text: "", table: tableState()),
            StoredSQLDocument(title: "Missing reference", text: "", kind: .table),
            StoredSQLDocument(title: "Negative page", text: "", kind: .table, table: tableState(page: -1)),
            StoredSQLDocument(title: "Excessive page", text: "", kind: .table, table: tableState(page: 1_000_001)),
            StoredSQLDocument(title: "Remote URL", text: "", fileURL: URL(string: "https://example.invalid/query.sql")!),
            StoredSQLDocument(title: "Remote file URL", text: "", fileURL: URL(string: "file://example.invalid/query.sql")!),
            StoredSQLDocument(title: "Directory URL", text: "", fileURL: URL(fileURLWithPath: "/tmp/", isDirectory: true)),
            StoredSQLDocument(title: "Hash without path", text: "", fileContentSHA256: String(repeating: "a", count: 64)),
            StoredSQLDocument(title: "Invalid hash", text: "", fileURL: URL(fileURLWithPath: "/tmp/query.sql"), fileContentSHA256: "bad"),
            StoredSQLDocument(title: "Table file binding", text: "", kind: .table, table: tableState(), fileURL: URL(fileURLWithPath: "/tmp/query.sql"))
        ]
        for document in invalid {
            await #expect(throws: SQLDocumentStoreError.self) { try await store.save(SQLWorkspaceSnapshot(documents: [document])) }
            #expect(try Data(contentsOf: url) == original)
        }
        await #expect(throws: SQLDocumentStoreError.self) {
            try await store.save(SQLWorkspaceSnapshot(documents: [valid], selectedDocumentID: UUID()))
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func malformedKindsOperationalFieldsAndFutureVersionsStayUntouched() async throws {
        let id = UUID().uuidString
        let base: [String: Any] = ["id": id, "title": "Keep", "text": "SELECT 1", "kind": "sql"]
        var documents: [[String: Any]] = []
        var unknownKind = base; unknownKind["kind"] = "snapshot"; documents.append(unknownKind)
        var missingKind = base; missingKind.removeValue(forKey: "kind"); documents.append(missingKind)
        var runtime = base; runtime["runtime"] = ["sessionId": "cannot-revive"]; documents.append(runtime)
        var futureFile = base; futureFile["fileBookmark"] = "future-binding"; documents.append(futureFile)
        var invalidTable = base
        invalidTable["kind"] = "table"
        invalidTable["table"] = ["reference": ["schema": "public", "name": "items", "kind": "table"], "page": 0,
            "filters": [["column": "v", "operator": "isNull", "value": "must-be-absent"]], "sort": []]
        documents.append(invalidTable)
        for document in documents {
            let directory = directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("workspace.json")
            let original = try JSONSerialization.data(withJSONObject: ["version": 4, "documents": [document],
                "historySettings": ["maxEntries": 1000, "retentionDays": 30]])
            try original.write(to: url)
            let store = FileSQLDocumentStore(fileURL: url)
            await #expect(throws: SQLDocumentStoreError.self) { _ = try await store.load() }
            await #expect(throws: SQLDocumentStoreError.self) { try await store.save(SQLWorkspaceSnapshot()) }
            #expect(try Data(contentsOf: url) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["workspace.json"])
        }
    }

    @Test(arguments: ["null", "\"4\"", "true", "-1", "5", "4.5"])
    func malformedOrFutureVersionNeverBecomesAnEmptyLegacyWorkspace(version: String) async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("workspace.json")
        let original = Data("{\"version\":\(version),\"documents\":[],\"historySettings\":{\"maxEntries\":75,\"retentionDays\":12}}".utf8)
        try original.write(to: url)
        let store = FileSQLDocumentStore(fileURL: url)
        await #expect(throws: SQLDocumentStoreError.self) { _ = try await store.load() }
        await #expect(throws: SQLDocumentStoreError.self) { try await store.save(SQLWorkspaceSnapshot()) }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["workspace.json"])
    }
}
