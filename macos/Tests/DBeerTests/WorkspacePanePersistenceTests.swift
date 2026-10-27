import Darwin
import Foundation
import Testing
@testable import DBeer

/// Workspace bytes and value types only. No windows, helper or connections.
struct WorkspacePanePersistenceTests {
    private func directory() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let result = repository.appendingPathComponent("build/r11/pane-persistence/\(UUID())")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    private func object(_ snapshot: SQLWorkspaceSnapshot) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try #require(JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any])
    }

    private func fixture(directory: URL, splitFraction: Double = 0.63) -> SQLWorkspaceSnapshot {
        let entry = SQLLibraryEntry(fileURL: directory.appendingPathComponent("analysis.sql"),
            folder: "Reports", tags: ["retained"])
        let sql = StoredSQLDocument(title: "Analysis", text: "SELECT 'e\u{301} κόσμος 🐋';\r\nSELECT '';", profileID: UUID(),
            fileURL: entry.fileURL, fileContentSHA256: String(repeating: "a", count: 64),
            fileRecoveryURL: directory.appendingPathComponent("analysis.recovery"), sqlLibraryEntryID: entry.id)
        let table = StoredSQLDocument(title: "Items", text: "Table data", profileID: UUID(), kind: .table,
            table: StoredTableDocument(reference: TableReference(schema: "fixture", name: "items", kind: "table"),
                page: 7, filters: [CatalogFilter(column: "id", operator: "eq", value: "9007199254740993")]))
        let offline = StoredSQLDocument(title: "Offline result", text: "", kind: .snapshot, snapshotID: UUID())
        let draft = StoredSQLDocument(title: "Unbound", text: "BEGIN; SELECT 'retained draft';")
        var favorite = SQLHistoryEntry(date: Date(timeIntervalSince1970: 1_700_000_000), documentID: sql.id,
            profileID: sql.profileID, sql: "SELECT 'retained favorite';", outcome: "Completed")
        favorite.isFavorite = true
        let layout = WorkspacePaneLayout(
            left: WorkspacePaneState(documentIDs: [draft.id, sql.id], selectedDocumentID: sql.id),
            right: WorkspacePaneState(documentIDs: [offline.id, table.id], selectedDocumentID: offline.id),
            activePaneID: .right, splitFraction: splitFraction)
        return SQLWorkspaceSnapshot(documents: [sql, table, offline, draft], history: [favorite], historyEnabled: false,
            historySettings: SQLHistoryRetentionSettings(maxEntries: 23, retentionDays: 7),
            sqlFolders: [SQLFolderAttachment(url: directory.appendingPathComponent("queries"))],
            sqlLibrary: SQLLibrarySnapshot(entries: [entry]), paneLayout: layout)
    }

    @Test(arguments: [0.2, 0.63, 0.8])
    func paneLayoutRoundTripsIndependentOrderSelectionsWidthAndUnrelatedState(splitFraction: Double) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = fixture(directory: directory, splitFraction: splitFraction)
        let url = directory.appendingPathComponent("workspace.json")
        let store = FileSQLDocumentStore(fileURL: url)
        try await store.save(snapshot)
        let restored = try await store.load()
        #expect(restored == snapshot && restored.version == SQLWorkspaceSnapshot.currentVersion)
        #expect(restored.selectedDocumentID == snapshot.paneLayout.right.selectedDocumentID)
        #expect(restored.paneLayout.left.selectedDocumentID != restored.paneLayout.right.selectedDocumentID)
        let memory = MemorySQLDocumentStore(snapshot: restored)
        #expect(await memory.load() == snapshot)
        let encoded = try object(restored)
        let layout = try #require(encoded["paneLayout"] as? [String: Any])
        #expect(Set(layout.keys) == ["left", "right", "activePaneID", "splitFraction"])
        for name in ["left", "right"] {
            let pane = try #require(layout[name] as? [String: Any])
            #expect(Set(pane.keys) == ["documentIDs", "selectedDocumentID"])
        }
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["workspace.json"])
    }

    @Test func clearingDocumentsClearsEveryPaneReferenceAndKeepsWidthHistoryAndLibrary() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = fixture(directory: directory)
        var cleared = original
        cleared.clearDocuments()
        #expect(cleared.documents.isEmpty && cleared.selectedDocumentID == nil)
        #expect(cleared.paneLayout.left == WorkspacePaneState() && cleared.paneLayout.right == WorkspacePaneState())
        #expect(cleared.paneLayout.activePaneID == original.paneLayout.activePaneID)
        #expect(cleared.paneLayout.splitFraction == original.paneLayout.splitFraction)
        #expect(cleared.history == original.history && cleared.historySettings == original.historySettings)
        #expect(cleared.historyEnabled == original.historyEnabled && cleared.sqlFolders == original.sqlFolders)
        #expect(cleared.sqlLibrary == original.sqlLibrary)
        let store = FileSQLDocumentStore(fileURL: directory.appendingPathComponent("workspace.json"))
        try await store.save(original)
        try await store.save(cleared)
        #expect(try await store.load() == cleared)
        #expect(await MemorySQLDocumentStore(snapshot: cleared).load() == cleared)
    }

    @Test func defaultLayoutSelectsTheFirstDraftAndAnExplicitEmptyActivePaneStaysEmpty() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = StoredSQLDocument(title: "Draft", text: "SELECT 1;")
        let defaults = SQLWorkspaceSnapshot(documents: [document])
        #expect(defaults.paneLayout == .singlePane(documentIDs: [document.id], selectedDocumentID: document.id))
        #expect(defaults.selectedDocumentID == document.id)
        let layout = WorkspacePaneLayout(left: defaults.paneLayout.left, activePaneID: .right, splitFraction: 0.7)
        let explicit = SQLWorkspaceSnapshot(documents: [document], paneLayout: layout)
        #expect(explicit.selectedDocumentID == nil)
        let store = FileSQLDocumentStore(fileURL: directory.appendingPathComponent("workspace.json"))
        try await store.save(explicit)
        #expect(try await store.load() == explicit)
        #expect(await MemorySQLDocumentStore(snapshot: explicit).load() == explicit)
    }

    @Test(arguments: 0...7)
    func everyPreviousVersionMigratesToOneLeftPaneWithAnExactPrivateBackup(version: Int) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sql = StoredSQLDocument(title: "First draft", text: "SELECT 'e\u{301} κόσμος';\r\n", profileID: UUID())
        let other = StoredSQLDocument(title: "Selected draft", text: "SELECT 'second';")
        var documents = [sql, other]
        if version >= 4 {
            documents.append(StoredSQLDocument(title: "Items", text: "Table data", profileID: UUID(), kind: .table,
                table: StoredTableDocument(reference: TableReference(schema: "fixture", name: "items", kind: "table"), page: 4)))
        }
        if version >= 7 { documents.append(StoredSQLDocument(title: "Offline", text: "", kind: .snapshot, snapshotID: UUID())) }
        let selected = try #require(documents.last)
        var favorite = SQLHistoryEntry(date: Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970)),
            documentID: sql.id, profileID: sql.profileID,
            sql: "SELECT 'history';", outcome: "Completed")
        favorite.isFavorite = version >= 3
        let settings = version >= 3 ? SQLHistoryRetentionSettings(maxEntries: 17, retentionDays: 6) : .default
        let folders = version >= 5 ? [SQLFolderAttachment(url: directory.appendingPathComponent("queries"))] : []
        let library = version >= 6 ? SQLLibrarySnapshot(entries: [SQLLibraryEntry(
            fileURL: directory.appendingPathComponent("library.sql"), tags: ["kept"])]) : SQLLibrarySnapshot()
        let expected = SQLWorkspaceSnapshot(documents: documents, selectedDocumentID: selected.id, history: [favorite],
            historyEnabled: false, historySettings: settings, sqlFolders: folders, sqlLibrary: library)
        var legacy = try object(expected)
        if version > 0 { legacy["version"] = version } else { legacy["version"] = nil }
        legacy["paneLayout"] = nil
        if version < 5 { legacy["sqlFolders"] = nil }
        if version < 6 { legacy["sqlLibrary"] = nil }
        if version < 3 { legacy["historySettings"] = nil }
        if version < 4 {
            legacy["documents"] = documents.map { document -> [String: Any] in
                var record: [String: Any] = ["id": document.id.uuidString, "title": document.title, "text": document.text]
                record["profileID"] = document.profileID?.uuidString
                return record
            }
        }
        if version < 2 {
            legacy["history"] = [["id": favorite.id.uuidString, "date": favorite.date.timeIntervalSince1970 * 1_000,
                "documentID": sql.id.uuidString, "profileID": try #require(sql.profileID).uuidString,
                "sql": favorite.sql, "outcome": "Completed"]]
        }
        let bytes = try JSONSerialization.data(withJSONObject: legacy, options: [.prettyPrinted, .sortedKeys])
        let url = directory.appendingPathComponent("workspace.json")
        try bytes.write(to: url)
        let store = FileSQLDocumentStore(fileURL: url)
        let restored = try await store.load()
        #expect(restored == expected)
        #expect(restored.paneLayout.left.documentIDs == documents.map(\.id))
        #expect(restored.paneLayout.left.selectedDocumentID == selected.id)
        #expect(restored.paneLayout.right == WorkspacePaneState())
        #expect(restored.paneLayout.activePaneID == .left && restored.paneLayout.splitFraction == 0.5)
        let backup = url.appendingPathExtension("v\(version).backup")
        #expect(try Data(contentsOf: backup) == bytes)
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try await store.load() == restored)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test func savingOverV7PreservesItsExactBytesAndNeverReplacesAnExistingBackup() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = fixture(directory: directory)
        var legacy = try object(snapshot)
        legacy["version"] = 7
        legacy["paneLayout"] = nil
        let bytes = try JSONSerialization.data(withJSONObject: legacy, options: [.prettyPrinted, .sortedKeys])
        let url = directory.appendingPathComponent("workspace.json")
        try bytes.write(to: url)
        let existingBackup = url.appendingPathExtension("v7.backup")
        let previous = Data("an existing backup must remain byte-for-byte intact".utf8)
        try previous.write(to: existingBackup)
        let store = FileSQLDocumentStore(fileURL: url)
        try await store.save(snapshot)
        #expect(try await store.load() == snapshot)
        #expect(try Data(contentsOf: existingBackup) == previous)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let added = try #require(names.first { $0.hasPrefix("workspace.json.v7-") && $0.hasSuffix(".backup") })
        let backup = directory.appendingPathComponent(added)
        #expect(try Data(contentsOf: backup) == bytes)
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(names.count == 3)
    }

    @Test func failedPrivateBackupPreventsMigrationAndReplacement() async throws {
        let directory = try directory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let snapshot = fixture(directory: directory)
        var legacy = try object(snapshot)
        legacy["version"] = 7
        legacy["paneLayout"] = nil
        let bytes = try JSONSerialization.data(withJSONObject: legacy, options: [.prettyPrinted, .sortedKeys])
        let url = directory.appendingPathComponent("workspace.json")
        try bytes.write(to: url)
        // This is an actual filesystem fault: the source stays readable but a
        // private backup cannot be created in the containing directory.
        try #require(geteuid() != 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let store = FileSQLDocumentStore(fileURL: url)
        await #expect(throws: SQLDocumentStoreError.self) { _ = try await store.load() }
        await #expect(throws: SQLDocumentStoreError.self) { try await store.save(snapshot) }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["workspace.json"])
    }

    @Test(arguments: 0...7)
    func aPaneLayoutSmuggledIntoAnyOlderVersionIsPreservedAndRejected(version: Int) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for payload in [NSNull(), ["left": ["documentIDs": []], "right": ["documentIDs": []],
                                    "activePaneID": "left", "splitFraction": 0.5]] as [Any] {
            var legacy: [String: Any] = ["documents": [], "history": [], "historyEnabled": false,
                "paneLayout": payload]
            if version > 0 { legacy["version"] = version }
            if version >= 3 { legacy["historySettings"] = ["maxEntries": 17, "retentionDays": 6] }
            if version >= 5 { legacy["sqlFolders"] = [] }
            if version >= 6 { legacy["sqlLibrary"] = ["entries": [], "groups": []] }
            let bytes = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
            let url = directory.appendingPathComponent("workspace.json")
            try bytes.write(to: url)
            let store = FileSQLDocumentStore(fileURL: url)
            await #expect(throws: SQLDocumentStoreError.self) { _ = try await store.load() }
            await #expect(throws: SQLDocumentStoreError.self) { try await store.save(SQLWorkspaceSnapshot()) }
            #expect(try Data(contentsOf: url) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["workspace.json"])
        }
    }

    @Test func malformedOrFuturePaneWorkspacesKeepOriginalBytesAndExistingBackup() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = fixture(directory: directory)
        let valid = try object(snapshot)
        let layout = try #require(valid["paneLayout"] as? [String: Any])
        let left = try #require(layout["left"] as? [String: Any])
        let right = try #require(layout["right"] as? [String: Any])
        let leftIDs = try #require(left["documentIDs"] as? [String])
        let rightIDs = try #require(right["documentIDs"] as? [String])
        var malformed: [[String: Any]] = []
        func withLayout(_ changed: [String: Any]) -> [String: Any] {
            valid.merging(["paneLayout": changed]) { _, new in new }
        }
        var missing = valid; missing.removeValue(forKey: "paneLayout"); malformed.append(missing)
        malformed.append(valid.merging(["paneLayout": NSNull()]) { _, new in new })
        malformed.append(valid.merging(["paneLayout": []]) { _, new in new })
        malformed.append(valid.merging(["version": SQLWorkspaceSnapshot.currentVersion + 1]) { _, new in new })
        malformed.append(valid.merging(["sessions": ["unexpected"]]) { _, new in new })
        for field in ["left", "right", "activePaneID", "splitFraction"] {
            var changed = layout; changed.removeValue(forKey: field); malformed.append(withLayout(changed))
        }
        malformed.append(withLayout(layout.merging(["center": left]) { _, new in new }))
        for field in ["runtime", "rows", "sql", "sessionId"] {
            malformed.append(withLayout(layout.merging(["left": left.merging([field: "unexpected"]) { _, new in new }]) { _, new in new }))
        }
        for ids in [[leftIDs[0], leftIDs[0]], [leftIDs[0], rightIDs[0]], Array(leftIDs.dropLast()),
                    [leftIDs[0], UUID().uuidString]] {
            let changedLeft = left.merging(["documentIDs": ids, "selectedDocumentID": leftIDs[0]]) { _, new in new }
            malformed.append(withLayout(layout.merging(["left": changedLeft]) { _, new in new }))
        }
        for selection in [NSNull(), rightIDs[0], UUID().uuidString] as [Any] {
            malformed.append(withLayout(layout.merging(["left": left.merging(["selectedDocumentID": selection]) { _, new in new }]) { _, new in new }))
        }
        let emptyWithSelection: [String: Any] = ["documentIDs": [], "selectedDocumentID": leftIDs[0]]
        let allLeft: [String: Any] = ["documentIDs": leftIDs + rightIDs, "selectedDocumentID": leftIDs[0]]
        malformed.append(withLayout(layout.merging(["left": allLeft, "right": emptyWithSelection]) { _, new in new }))
        for active in [NSNull(), "center", true] as [Any] {
            malformed.append(withLayout(layout.merging(["activePaneID": active]) { _, new in new }))
        }
        for fraction in [NSNull(), -1, 0, 0.199999, 0.800001, 1, "0.5", true] as [Any] {
            malformed.append(withLayout(layout.merging(["splitFraction": fraction]) { _, new in new }))
        }
        malformed.append(valid.merging(["selectedDocumentID": leftIDs[0]]) { _, new in new })
        malformed.append(valid.merging(["selectedDocumentID": NSNull()]) { _, new in new })
        missing = valid; missing.removeValue(forKey: "selectedDocumentID"); malformed.append(missing)
        let url = directory.appendingPathComponent("workspace.json")
        let backup = url.appendingPathExtension("v7.backup")
        let oldBackup = Data("preserve this existing backup".utf8)
        try oldBackup.write(to: backup)
        let store = FileSQLDocumentStore(fileURL: url)
        for changed in malformed {
            let bytes = try JSONSerialization.data(withJSONObject: changed, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: url)
            await #expect(throws: SQLDocumentStoreError.self) { _ = try await store.load() }
            await #expect(throws: SQLDocumentStoreError.self) { try await store.save(snapshot) }
            #expect(try Data(contentsOf: url) == bytes)
            #expect(try Data(contentsOf: backup) == oldBackup)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["workspace.json", "workspace.json.v7.backup"])
        }
    }

    @Test func anInvalidInMemoryLayoutCannotReplaceAnIntactWorkspace() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = fixture(directory: directory)
        let url = directory.appendingPathComponent("workspace.json")
        let store = FileSQLDocumentStore(fileURL: url)
        try await store.save(snapshot)
        let bytes = try Data(contentsOf: url)
        for fraction in [Double.nan, .infinity, -.infinity, 0.199999, 0.800001] {
            var changed = snapshot; changed.paneLayout.splitFraction = fraction
            await #expect(throws: SQLDocumentStoreError.self) { try await store.save(changed) }
            #expect(try Data(contentsOf: url) == bytes)
        }
        var changed = snapshot
        changed.selectedDocumentID = snapshot.paneLayout.left.selectedDocumentID
        await #expect(throws: SQLDocumentStoreError.self) { try await store.save(changed) }
        changed = snapshot
        changed.paneLayout.left.documentIDs.append(try #require(changed.paneLayout.right.documentIDs.first))
        await #expect(throws: SQLDocumentStoreError.self) { try await store.save(changed) }
        #expect(try Data(contentsOf: url) == bytes)
    }
}
