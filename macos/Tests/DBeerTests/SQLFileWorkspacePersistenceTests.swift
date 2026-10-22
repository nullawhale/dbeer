import Foundation
import Testing
@testable import DBeer

/// Local storage and SQL parsing only. No application, window or chooser.
struct SQLFileWorkspacePersistenceTests {
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("build/r12-r13/persistence/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func v5PersistsFolderAttachmentsAndSharedFileIdentityWithIndependentViews() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("query.sql")
        let modelID = UUID()
        let first = StoredSQLDocument(title: "Development", text: "SELECT 'shared';\r\n", profileID: UUID(),
            fileURL: fileURL, fileContentSHA256: SQLFileBinding.digestText("SELECT 'saved';\r\n"), fileDocumentID: modelID)
        let second = StoredSQLDocument(title: "Production", text: first.text, profileID: UUID(), fileURL: fileURL,
            fileContentSHA256: first.fileContentSHA256, fileDocumentID: modelID)
        let folder = SQLFolderAttachment(url: directory)
        let snapshot = SQLWorkspaceSnapshot(documents: [first, second], selectedDocumentID: second.id, sqlFolders: [folder])
        let store = FileSQLDocumentStore(fileURL: directory.appendingPathComponent("workspace.json"))
        try await store.save(snapshot)
        let saved = try await store.load()
        #expect(saved == snapshot && saved.version == 5 && saved.sqlFolders == [folder])
        #expect(saved.documents[0].id != saved.documents[1].id && first.profileID != second.profileID)
        #expect(saved.documents.map(\.fileDocumentID) == [modelID, modelID])
        let memory = MemorySQLDocumentStore(snapshot: saved)
        #expect(await memory.load().sqlFolders == [folder])
    }

    @Test func v4MigrationPreservesExactBackupAndEveryBoundDraft() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "\u{FEFF}SELECT 'κόσμος';\r\nSELECT '';\n"
        let draft = StoredSQLDocument(title: "Recovered", text: text, profileID: UUID(),
            fileURL: directory.appendingPathComponent("query.sql"), fileContentSHA256: SQLFileBinding.digestText("saved"))
        let snapshot = SQLWorkspaceSnapshot(documents: [draft], selectedDocumentID: draft.id)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object["version"] = 4
        object["sqlFolders"] = nil
        var documents = try #require(object["documents"] as? [[String: Any]])
        // JSONSerialization strips a leading BOM when decoding string values.
        // Restore the exact source text before emitting the legacy fixture.
        documents[0]["text"] = text
        documents[0]["fileDocumentID"] = nil
        object["documents"] = documents
        let original = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let url = directory.appendingPathComponent("workspace.json")
        try original.write(to: url)
        let migrated = try await FileSQLDocumentStore(fileURL: url).load()
        #expect(migrated.version == 5 && migrated.sqlFolders.isEmpty && migrated.documents == [draft])
        #expect(migrated.documents[0].text.utf8.elementsEqual(text.utf8))
        let backup = url.appendingPathExtension("v4.backup")
        #expect(try Data(contentsOf: backup) == original)
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func inconsistentSharedFileDraftsCannotReplaceTheExistingWorkspace() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let modelID = UUID()
        let first = StoredSQLDocument(title: "First", text: "SELECT 'e\u{301}';", fileURL: directory.appendingPathComponent("query.sql"),
            fileContentSHA256: String(repeating: "a", count: 64), fileDocumentID: modelID)
        let second = StoredSQLDocument(title: "Second", text: first.text, fileURL: first.fileURL,
            fileContentSHA256: first.fileContentSHA256, fileDocumentID: modelID)
        let snapshot = SQLWorkspaceSnapshot(documents: [first, second])
        let store = FileSQLDocumentStore(fileURL: url)
        try await store.save(snapshot)
        let original = try Data(contentsOf: url)
        var invalid = snapshot
        invalid.documents[1].text = "SELECT 'é';"
        await #expect(throws: SQLDocumentStoreError.self) { try await store.save(invalid) }
        #expect(try Data(contentsOf: url) == original)
        invalid = snapshot
        invalid.documents[1].fileURL = directory.appendingPathComponent("other.sql")
        await #expect(throws: SQLDocumentStoreError.self) { try await store.save(invalid) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func malformedFolderMetadataAndFutureVersionsStayUnchanged() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let valid = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SQLWorkspaceSnapshot())) as? [String: Any])
        for folders: [[String: Any]] in [
            [["id": UUID().uuidString, "url": "https://example.invalid/sql"]],
            [["id": UUID().uuidString, "url": directory.absoluteString, "session": "not-persisted"]],
        ] {
            var object = valid
            object["sqlFolders"] = folders
            let data = try JSONSerialization.data(withJSONObject: object)
            try data.write(to: url)
            await #expect(throws: SQLDocumentStoreError.self) { _ = try await FileSQLDocumentStore(fileURL: url).load() }
            #expect(try Data(contentsOf: url) == data)
        }
        var future = valid
        future["version"] = SQLWorkspaceSnapshot.currentVersion + 1
        let data = try JSONSerialization.data(withJSONObject: future)
        try data.write(to: url)
        await #expect(throws: SQLDocumentStoreError.self) { _ = try await FileSQLDocumentStore(fileURL: url).load() }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func attachmentLimitMatchesLibraryWithoutReplacingSavedWorkspace() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let folders = (0..<32).map { SQLFolderAttachment(url: directory.appendingPathComponent("folder-\($0)")) }
        let store = FileSQLDocumentStore(fileURL: url)
        var snapshot = SQLWorkspaceSnapshot(sqlFolders: folders)
        try await store.save(snapshot)
        #expect(try await store.load().sqlFolders == folders)
        let original = try Data(contentsOf: url)
        snapshot.sqlFolders.append(SQLFolderAttachment(url: directory.appendingPathComponent("one-too-many")))
        await #expect(throws: SQLDocumentStoreError.self) { try await store.save(snapshot) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func utf8BOMStaysInFileTextButNotInExecutedStatements() {
        let text = "\u{FEFF}SELECT 'κόσμος';\r\nSELECT 2;\r\n"
        for engine: DatabaseEngine in [.postgresql, .mysql, .cassandra] {
            let parsed = SQLScriptParser.parse(text, engine: engine)
            #expect(parsed.diagnostics.isEmpty && parsed.statements.count == 2)
            #expect(parsed.statements.first?.sql == "SELECT 'κόσμος'")
            #expect(parsed.statements.first?.range.location == 1)
            for statement in parsed.statements {
                #expect((text as NSString).substring(with: statement.range).utf8.elementsEqual(statement.sql.utf8))
                #expect(!statement.sql.hasPrefix("\u{FEFF}"))
            }
        }
        #expect(text.utf8.starts(with: [0xef, 0xbb, 0xbf]))
    }
}
