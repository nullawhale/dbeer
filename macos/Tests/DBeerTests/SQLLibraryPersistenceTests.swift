import Foundation
import Testing
@testable import DBeer

/// Local storage only. No application, native chooser, windows or helpers.
struct SQLLibraryPersistenceTests {
    private func directory() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repository.appendingPathComponent("build/r14/library-persistence/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func encoded(_ snapshot: SQLWorkspaceSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(snapshot)
    }

    @Test func v5MigrationKeepsExactPrivateBackupSharedFilesRecoveryFoldersAndHistory() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shared.sql")
        let recovery = directory.appendingPathComponent("preserved.recovery")
        let text = "\u{FEFF}SELECT 'e\u{301} κόσμος';\r\n"
        let sharedID = UUID()
        let first = StoredSQLDocument(title: "Development", text: text, profileID: UUID(), fileURL: file,
            fileContentSHA256: SQLFileBinding.digestText("accepted"), fileDocumentID: sharedID, fileRecoveryURL: recovery)
        let second = StoredSQLDocument(title: "Staging", text: text, profileID: UUID(), fileURL: file,
            fileContentSHA256: first.fileContentSHA256, fileDocumentID: sharedID, fileRecoveryURL: recovery)
        var favorite = SQLHistoryEntry(date: Date(timeIntervalSince1970: 1_700_000_000), documentID: first.id,
            profileID: first.profileID, sql: "SELECT 'favorite';", outcome: "Completed")
        favorite.isFavorite = true
        let folders = [SQLFolderAttachment(url: directory.appendingPathComponent("queries"))]
        let settings = SQLHistoryRetentionSettings(maxEntries: 23, retentionDays: 7)
        let snapshot = SQLWorkspaceSnapshot(documents: [first, second], selectedDocumentID: second.id,
            history: [favorite], historyEnabled: false, historySettings: settings, sqlFolders: folders)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded(snapshot)) as? [String: Any])
        legacy["version"] = 5
        legacy["sqlLibrary"] = nil
        var documents = try #require(legacy["documents"] as? [[String: Any]])
        for index in documents.indices {
            // JSONSerialization strips a leading BOM when decoding strings.
            documents[index]["text"] = text
            documents[index]["sqlLibraryEntryID"] = nil
        }
        legacy["documents"] = documents
        let original = try JSONSerialization.data(withJSONObject: legacy, options: [.prettyPrinted, .sortedKeys])
        let url = directory.appendingPathComponent("workspace.json")
        try original.write(to: url)
        let store = FileSQLDocumentStore(fileURL: url)
        let restored = try await store.load()
        #expect(restored == snapshot && restored.version == SQLWorkspaceSnapshot.currentVersion && restored.sqlLibrary == SQLLibrarySnapshot())
        #expect(restored.documents.map(\.fileDocumentID) == [sharedID, sharedID])
        #expect(restored.documents.allSatisfy { $0.text.utf8.elementsEqual(text.utf8) && $0.fileRecoveryURL == recovery })
        #expect(restored.sqlFolders == folders && restored.history == [favorite] && restored.historySettings == settings)
        let backup = url.appendingPathExtension("v5.backup")
        #expect(try Data(contentsOf: backup) == original)
        for item in [url, backup] {
            #expect((try FileManager.default.attributesOfItem(atPath: item.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        #expect(try await store.load() == restored)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["workspace.json", "workspace.json.v5.backup"])
    }

    @Test func v6RoundTripsMetadataAndIndependentViewMarkersWithoutIndexingSQLOrSecrets() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = UUID(), secondary = UUID(), sharedID = UUID()
        let group = SQLProfileGroup(name: "Non-production", profileIDs: [primary, secondary])
        let entry = SQLLibraryEntry(fileURL: directory.appendingPathComponent("shared.sql"), folder: "Reports/Daily",
            tags: ["finance", "daily"], scope: .group(group.id))
        let library = SQLLibrarySnapshot(entries: [entry,
            SQLLibraryEntry(fileURL: directory.appendingPathComponent("global.sql")),
            SQLLibraryEntry(fileURL: directory.appendingPathComponent("profile.sql"), scope: .profile(primary))], groups: [group])
        let text = "\u{FEFF}SELECT 'shared source';\r\n"
        let first = StoredSQLDocument(title: "Primary", text: text, profileID: primary, fileURL: entry.fileURL,
            fileContentSHA256: SQLFileBinding.digestText(text), fileDocumentID: sharedID, sqlLibraryEntryID: entry.id)
        let second = StoredSQLDocument(title: "Secondary", text: text, profileID: secondary, fileURL: entry.fileURL,
            fileContentSHA256: first.fileContentSHA256, fileDocumentID: sharedID, sqlLibraryEntryID: entry.id)
        let snapshot = SQLWorkspaceSnapshot(documents: [first, second], selectedDocumentID: second.id, sqlLibrary: library)
        let url = directory.appendingPathComponent("workspace.json")
        let store = FileSQLDocumentStore(fileURL: url)
        try await store.save(snapshot)
        let restored = try await store.load()
        #expect(restored == snapshot && restored.documents.map(\.sqlLibraryEntryID) == [entry.id, entry.id])
        #expect(restored.documents[0].profileID != restored.documents[1].profileID)
        #expect(restored.documents.allSatisfy { $0.text.utf8.elementsEqual(text.utf8) })
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let index = try #require(object["sqlLibrary"] as? [String: Any])
        #expect(Set(index.keys) == ["entries", "groups"])
        let records = try #require(index["entries"] as? [[String: Any]])
        #expect(records.count == 3)
        #expect(records.allSatisfy { Set($0.keys) == ["id", "fileURL", "folder", "tags", "scope"] })
        let groups = try #require(index["groups"] as? [[String: Any]])
        #expect(groups.count == 1 && Set(groups[0].keys) == ["id", "name", "profileIDs"])
        for record in records {
            let scope = try #require(record["scope"] as? [String: Any])
            #expect(Set(scope.keys).isSubset(of: ["kind", "profileID", "groupID"]))
        }
        // Metadata load/save does not read or create any referenced SQL file.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["workspace.json"])
        let memory = MemorySQLDocumentStore(snapshot: restored)
        #expect(await memory.load().sqlLibrary == library)
    }

    @Test func malformedMetadataAndFutureVersionsRemainUntouchedOnLoadAndSave() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = SQLLibraryEntry(fileURL: directory.appendingPathComponent("query.sql"))
        let group = SQLProfileGroup(name: "Team", profileIDs: [UUID()])
        let snapshot = SQLWorkspaceSnapshot(sqlLibrary: SQLLibrarySnapshot(entries: [entry], groups: [group]))
        let object = try #require(JSONSerialization.jsonObject(with: encoded(snapshot)) as? [String: Any])
        let index = try #require(object["sqlLibrary"] as? [String: Any])
        let record = try #require((index["entries"] as? [[String: Any]])?.first)
        let groupRecord = try #require((index["groups"] as? [[String: Any]])?.first)
        var invalid: [[String: Any]] = []
        for changedEntry in [
            record.merging(["text": "unwanted SQL copy"]) { _, newer in newer },
            record.merging(["scope": ["kind": "allConnections", "profileID": UUID().uuidString]]) { _, newer in newer },
            record.merging(["fileURL": "https://example.invalid/query.sql"]) { _, newer in newer },
            record.merging(["tags": ["daily", "DAILY"]]) { _, newer in newer },
        ] {
            var changedIndex = index
            changedIndex["entries"] = [changedEntry]
            invalid.append(object.merging(["sqlLibrary": changedIndex]) { _, newer in newer })
        }
        var changedIndex = index
        changedIndex["entries"] = [record, record]
        invalid.append(object.merging(["sqlLibrary": changedIndex]) { _, newer in newer })
        changedIndex = index
        changedIndex["groups"] = [groupRecord.merging(["password": "unexpected field"]) { _, newer in newer }]
        invalid.append(object.merging(["sqlLibrary": changedIndex]) { _, newer in newer })
        changedIndex = index
        changedIndex["future"] = true
        invalid.append(object.merging(["sqlLibrary": changedIndex]) { _, newer in newer })
        invalid.append(object.merging(["version": SQLWorkspaceSnapshot.currentVersion + 1]) { _, newer in newer })
        invalid.append(object.merging(["version": 5]) { _, newer in newer })
        var missing = object
        missing["sqlLibrary"] = nil
        invalid.append(missing)
        invalid.append(object.merging(["sqlLibrary": NSNull()]) { _, newer in newer })
        let url = directory.appendingPathComponent("workspace.json")
        let store = FileSQLDocumentStore(fileURL: url)
        for malformed in invalid {
            let original = try JSONSerialization.data(withJSONObject: malformed, options: [.prettyPrinted, .sortedKeys])
            try original.write(to: url)
            await #expect(throws: SQLDocumentStoreError.self) { _ = try await store.load() }
            #expect(try Data(contentsOf: url) == original)
            await #expect(throws: SQLDocumentStoreError.self) { try await store.save(snapshot) }
            #expect(try Data(contentsOf: url) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["workspace.json"])
        }
    }

    @Test func invalidLibraryCannotReplaceValidWorkspaceAndMissingReferencesRemainExplicit() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingEntry = UUID(), missingGroup = UUID()
        let entry = SQLLibraryEntry(fileURL: directory.appendingPathComponent("missing.sql"), scope: .group(missingGroup))
        let draft = StoredSQLDocument(title: "Unavailable library view", text: "SELECT 'retained draft';\r\n",
            fileURL: directory.appendingPathComponent("old-location.sql"), sqlLibraryEntryID: missingEntry)
        let snapshot = SQLWorkspaceSnapshot(documents: [draft], selectedDocumentID: draft.id,
            sqlLibrary: SQLLibrarySnapshot(entries: [entry]))
        let url = directory.appendingPathComponent("workspace.json")
        let store = FileSQLDocumentStore(fileURL: url)
        try await store.save(snapshot)
        #expect(try await store.load() == snapshot)
        let original = try Data(contentsOf: url)
        var invalid = snapshot
        invalid.sqlLibrary.entries.append(entry)
        await #expect(throws: SQLDocumentStoreError.self) { try await store.save(invalid) }
        #expect(try Data(contentsOf: url) == original)
        invalid = snapshot
        invalid.documents[0].fileURL = nil
        invalid.documents[0].fileDocumentID = nil
        await #expect(throws: SQLDocumentStoreError.self) { try await store.save(invalid) }
        #expect(try Data(contentsOf: url) == original)
    }
}
