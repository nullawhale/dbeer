import Foundation
import Testing
@testable import DBeer

/// Workspace/closed-tab value and byte tests only. No windows or connections.
struct InvestigationWorkspacePersistenceTests {
    private func directory() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/r18/workspace-persistence/\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func object(_ snapshot: SQLWorkspaceSnapshot) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try #require(JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any])
    }

    @Test func workspaceAndClosedTabsContainOnlyOpaqueInvestigationReferences() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let investigation = StoredSQLDocument(title: "Investigation title fallback", text: "", kind: .investigation, investigationID: UUID())
        let sql = StoredSQLDocument(title: "Independent draft", text: "SELECT 'independent draft';", profileID: UUID())
        let layout = WorkspacePaneLayout(
            left: WorkspacePaneState(documentIDs: [sql.id], selectedDocumentID: sql.id),
            right: WorkspacePaneState(documentIDs: [investigation.id], selectedDocumentID: investigation.id),
            activePaneID: .right, splitFraction: 0.64)
        let value = SQLWorkspaceSnapshot(documents: [sql, investigation], paneLayout: layout)
        let url = directory.appendingPathComponent("workspace.json")
        let store = FileSQLDocumentStore(fileURL: url)
        try await store.save(value)
        let restored = try await store.load()
        #expect(restored == value && restored.version == 9)
        let records = try #require(try object(restored)["documents"] as? [[String: Any]])
        #expect(Set(records[1].keys) == ["id", "title", "kind", "investigationID"])
        #expect(records[1]["investigationID"] as? String == investigation.investigationID?.uuidString)
        let closed = ClosedWorkspaceTab(state: restored.documents[1], originalIndex: 1, paneID: .right, originalPaneIndex: 0)
        #expect(closed.state == investigation && closed.paneID == .right && closed.originalPaneIndex == 0)
        #expect(closed.state.text.isEmpty && closed.state.profileID == nil && closed.state.snapshotID == nil)
        #expect(closed.state.table == nil && closed.state.fileURL == nil && closed.state.fileDocumentID == nil)
        #expect(closed.state.sqlLibraryEntryID == nil && closed.state.fileRecoveryURL == nil)
    }

    @Test func v8MigrationPreservesBothPaneOrdersSelectionsAndExactPrivateBackup() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = StoredSQLDocument(title: "First", text: "SELECT 'e\u{301} preserved';\r\n", profileID: UUID())
        let second = StoredSQLDocument(title: "Second", text: "SELECT 9007199254740993;")
        let offline = StoredSQLDocument(title: "Offline", text: "", kind: .snapshot, snapshotID: UUID())
        let table = StoredSQLDocument(title: "Items", text: "Table data", profileID: UUID(), kind: .table,
            table: StoredTableDocument(reference: TableReference(schema: "fixture", name: "items", kind: "table"), page: 3))
        let layout = WorkspacePaneLayout(
            left: WorkspacePaneState(documentIDs: [second.id, first.id], selectedDocumentID: first.id),
            right: WorkspacePaneState(documentIDs: [table.id, offline.id], selectedDocumentID: offline.id),
            activePaneID: .right, splitFraction: 0.73)
        let expected = SQLWorkspaceSnapshot(documents: [first, second, offline, table], historyEnabled: false, paneLayout: layout)
        var old = try object(expected)
        old["version"] = 8
        let bytes = try JSONSerialization.data(withJSONObject: old, options: [.prettyPrinted, .sortedKeys])
        let url = directory.appendingPathComponent("workspace.json")
        try bytes.write(to: url)
        let store = FileSQLDocumentStore(fileURL: url)
        let restored = try await store.load()
        #expect(restored == expected && restored.paneLayout == layout && restored.version == 9)
        let backup = url.appendingPathExtension("v8.backup")
        #expect(try Data(contentsOf: backup) == bytes)
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try await store.load() == expected)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["workspace.json", "workspace.json.v8.backup"])
    }

    @Test(arguments: 0...8)
    func everyOlderVersionRejectsInvestigationKindOrKeyWithoutMigration(version: Int) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let id = UUID()
        for record in [
            ["id": id.uuidString, "title": "Newer document", "kind": "investigation", "investigationID": UUID().uuidString],
            ["id": id.uuidString, "title": "SQL", "kind": "sql", "text": "SELECT 'retain';", "investigationID": NSNull()]
        ] as [[String: Any]] {
            var legacy: [String: Any] = ["documents": [record], "selectedDocumentID": id.uuidString, "history": [], "historyEnabled": false]
            if version > 0 { legacy["version"] = version }
            if version >= 3 { legacy["historySettings"] = ["maxEntries": 17, "retentionDays": 6] }
            if version >= 5 { legacy["sqlFolders"] = [] }
            if version >= 6 { legacy["sqlLibrary"] = ["entries": [], "groups": []] }
            if version >= 8 {
                legacy["paneLayout"] = ["left": ["documentIDs": [id.uuidString], "selectedDocumentID": id.uuidString],
                    "right": ["documentIDs": []], "activePaneID": "left", "splitFraction": 0.5]
            }
            let bytes = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
            try bytes.write(to: url)
            let store = FileSQLDocumentStore(fileURL: url)
            await #expect(throws: SQLDocumentStoreError.self) { _ = try await store.load() }
            await #expect(throws: SQLDocumentStoreError.self) { try await store.save(SQLWorkspaceSnapshot()) }
            #expect(try Data(contentsOf: url) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["workspace.json"])
        }
    }

    @Test func malformedMixedAndFutureInvestigationWorkspacesStayByteForByteIntact() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = StoredSQLDocument(title: "Investigation", text: "", kind: .investigation, investigationID: UUID())
        let valid = try object(SQLWorkspaceSnapshot(documents: [reference], selectedDocumentID: reference.id))
        let record = try #require((valid["documents"] as? [[String: Any]])?.first)
        var malformed = [valid.merging(["version": 10]) { _, new in new }]
        for field in ["text", "profileID", "snapshotID", "table", "fileURL", "fileContentSHA256", "fileDocumentID", "fileRecoveryURL", "sqlLibraryEntryID",
                      "blocks", "rows", "sessionId", "password"] {
            for payload in [NSNull(), "forbidden fixture"] as [Any] {
                let changed = record.merging([field: payload]) { _, new in new }
                malformed.append(valid.merging(["documents": [changed]]) { _, new in new })
            }
        }
        for payload in [NSNull(), "../../library.json", "not-a-uuid"] as [Any] {
            malformed.append(valid.merging(["documents": [record.merging(["investigationID": payload]) { _, new in new }]]) { _, new in new })
        }
        var missing = record; missing.removeValue(forKey: "investigationID")
        malformed.append(valid.merging(["documents": [missing]]) { _, new in new })
        let url = directory.appendingPathComponent("workspace.json")
        let store = FileSQLDocumentStore(fileURL: url)
        for value in malformed {
            let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            try bytes.write(to: url)
            await #expect(throws: SQLDocumentStoreError.self) { _ = try await store.load() }
            await #expect(throws: SQLDocumentStoreError.self) { try await store.save(SQLWorkspaceSnapshot()) }
            #expect(try Data(contentsOf: url) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["workspace.json"])
        }
    }

    @Test func invalidInMemoryInvestigationReferencesCannotReplaceAnIntactWorkspace() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = StoredSQLDocument(title: "Investigation", text: "", kind: .investigation, investigationID: UUID())
        let url = directory.appendingPathComponent("workspace.json")
        let store = FileSQLDocumentStore(fileURL: url)
        try await store.save(SQLWorkspaceSnapshot(documents: [reference], selectedDocumentID: reference.id))
        let bytes = try Data(contentsOf: url)
        var malformed: [StoredSQLDocument] = []
        var changed = reference; changed.investigationID = nil; malformed.append(changed)
        changed = reference; changed.text = "SELECT 'never restore from workspace';"; malformed.append(changed)
        changed = reference; changed.profileID = UUID(); malformed.append(changed)
        changed = reference; changed.snapshotID = UUID(); malformed.append(changed)
        changed = reference; changed.fileURL = directory.appendingPathComponent("query.sql"); malformed.append(changed)
        changed = reference; changed.kind = .sql; malformed.append(changed)
        changed = reference; changed.kind = .table; malformed.append(changed)
        changed = reference; changed.kind = .snapshot; malformed.append(changed)
        for value in malformed {
            #expect(!value.isValid)
            await #expect(throws: SQLDocumentStoreError.self) {
                try await store.save(SQLWorkspaceSnapshot(documents: [value], selectedDocumentID: value.id))
            }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func duplicateMutableInvestigationOwnersAreRejectedButDistinctReferencesRoundTrip() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = StoredSQLDocument(title: "First investigation", text: "", kind: .investigation, investigationID: UUID())
        let second = StoredSQLDocument(title: "Second investigation", text: "", kind: .investigation, investigationID: UUID())
        let valid = SQLWorkspaceSnapshot(documents: [first, second], selectedDocumentID: second.id)
        let url = directory.appendingPathComponent("workspace.json")
        let store = FileSQLDocumentStore(fileURL: url)
        try await store.save(valid)
        #expect(try await store.load() == valid)
        let intact = try Data(contentsOf: url)
        var duplicate = second
        duplicate.investigationID = first.investigationID
        let invalid = SQLWorkspaceSnapshot(documents: [first, duplicate], selectedDocumentID: duplicate.id)
        await #expect(throws: SQLDocumentStoreError.self) { try await store.save(invalid) }
        #expect(try Data(contentsOf: url) == intact)
        var corrupt = try object(valid)
        var records = try #require(corrupt["documents"] as? [[String: Any]])
        records[1]["investigationID"] = first.investigationID?.uuidString
        corrupt["documents"] = records
        let bytes = try JSONSerialization.data(withJSONObject: corrupt, options: [.sortedKeys])
        try bytes.write(to: url)
        await #expect(throws: SQLDocumentStoreError.self) { _ = try await store.load() }
        await #expect(throws: SQLDocumentStoreError.self) { try await store.save(valid) }
        #expect(try Data(contentsOf: url) == bytes)
    }
}
