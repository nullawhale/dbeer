import Foundation
import Testing
@testable import DBeer

struct SQLDocumentStoreTests {
    @Test func draftAndHistoryRoundTripContainsNoRuntimeStateAndClearsPersistently() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let document = StoredSQLDocument(title: "Analysis", text: "SELECT 'κόσμος 😀';", profileID: UUID())
        var snapshot = SQLWorkspaceSnapshot(documents: [document], selectedDocumentID: document.id)
        snapshot.record(SQLHistoryEntry(documentID: document.id, profileID: document.profileID, sql: "SELECT 1", outcome: "success"))
        let store = FileSQLDocumentStore(fileURL: url)
        try await store.save(snapshot)
        let restored = try await FileSQLDocumentStore(fileURL: url).load()
        #expect(restored.version == 1)
        #expect(restored.documents == [document])
        #expect(restored.selectedDocumentID == document.id)
        #expect(restored.history.map(\.sql) == ["SELECT 1"])
        let data = try Data(contentsOf: url)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["sessions"] == nil && json["passwords"] == nil && json["results"] == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        snapshot.clearDocuments()
        snapshot.clearHistory()
        snapshot.historyEnabled = false
        try await store.save(snapshot)
        let cleared = try await store.load()
        #expect(cleared.documents.isEmpty && cleared.history.isEmpty && !cleared.historyEnabled)
        #expect(cleared.selectedDocumentID == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["workspace.json"])
    }

    @Test func historyKeepsOnlyLastThousandWithinThirtyDaysAndHonorsDisabledRecording() async {
        let now = Date.now
        let entries = (0..<1_005).map {
            SQLHistoryEntry(date: now.addingTimeInterval(-Double($0)), sql: "SELECT \($0)", outcome: "success")
        }
        var snapshot = SQLWorkspaceSnapshot(history: entries + [SQLHistoryEntry(
            date: now.addingTimeInterval(-31 * 24 * 60 * 60), sql: "expired", outcome: "success")])
        snapshot.trimHistory(now: now)
        #expect(snapshot.history.count == 1_000)
        #expect(snapshot.history.first?.sql == "SELECT 999")
        #expect(snapshot.history.last?.sql == "SELECT 0")
        snapshot.historyEnabled = false
        snapshot.record(SQLHistoryEntry(sql: "must not be added", outcome: "success"), now: now)
        #expect(snapshot.history.count == 1_000 && snapshot.history.last?.sql == "SELECT 0")
        let store = MemorySQLDocumentStore(snapshot: snapshot)
        #expect(await store.load().history.count == 1_000)
    }

    @Test func corruptUnknownVersionAndDuplicateDocumentsAreNeverOverwritten() async throws {
        let document = StoredSQLDocument(title: "SQL", text: "SELECT 1")
        let encoder = JSONEncoder()
        let invalid = [Data("{bad".utf8), Data("{\"version\":99,\"documents\":[]}".utf8),
            try encoder.encode(SQLWorkspaceSnapshot(documents: [document, document]))]
        for data in invalid {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("workspace.json")
            try data.write(to: url)
            let store = FileSQLDocumentStore(fileURL: url)
            await #expect(throws: SQLDocumentStoreError.self) { _ = try await store.load() }
            await #expect(throws: SQLDocumentStoreError.self) { try await store.save(SQLWorkspaceSnapshot()) }
            #expect(try Data(contentsOf: url) == data)
        }
    }

    @Test func legacyDraftMigrationBacksUpExactBytesAndPreservesProfileBinding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("workspace.json")
        let id = UUID()
        let profile = UUID()
        let data = Data("""
        {"documents":[{"id":"\(id.uuidString)","title":"Recovered","text":"BEGIN; SELECT 1;","profileID":"\(profile.uuidString)"}],
         "selectedDocumentID":"\(id.uuidString)"}
        """.utf8)
        try data.write(to: url)
        let snapshot = try await FileSQLDocumentStore(fileURL: url).load()
        #expect(snapshot.version == 1)
        #expect(snapshot.documents.first?.id == id)
        #expect(snapshot.documents.first?.profileID == profile)
        #expect(snapshot.history.isEmpty && snapshot.historyEnabled)
        #expect(try Data(contentsOf: url.appendingPathExtension("v0.backup")) == data)
    }
}
