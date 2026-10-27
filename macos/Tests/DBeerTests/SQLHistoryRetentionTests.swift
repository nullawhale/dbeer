import Foundation
import Testing
@testable import DBeer

struct SQLHistoryRetentionTests {
    @Test func defaultsAndSupportedRangesAreExplicit() {
        #expect(SQLHistoryRetentionSettings.default == SQLHistoryRetentionSettings(maxEntries: 1_000, retentionDays: 30))
        #expect(SQLHistoryRetentionSettings(maxEntries: 1, retentionDays: 1).isValid)
        #expect(SQLHistoryRetentionSettings(maxEntries: 100_000, retentionDays: 3_650).isValid)
        #expect(!SQLHistoryRetentionSettings(maxEntries: 0).isValid)
        #expect(!SQLHistoryRetentionSettings(maxEntries: 100_001).isValid)
        #expect(!SQLHistoryRetentionSettings(retentionDays: 0).isValid)
        #expect(!SQLHistoryRetentionSettings(retentionDays: 3_651).isValid)
    }

    @Test func favoritesSurviveAgeAndDoNotConsumeOrdinaryCapacity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldFavorite = entry("Old favorite", date: now.addingTimeInterval(-365 * 86_400), favorite: true)
        let recentFavorite = entry("Recent favorite", date: now, favorite: true)
        let ordinary = (0..<4).map { entry("Ordinary \($0)", date: now.addingTimeInterval(Double($0 - 10))) }
        var snapshot = SQLWorkspaceSnapshot(history: [recentFavorite] + ordinary + [oldFavorite,
            entry("Expired", date: now.addingTimeInterval(-3 * 86_400))],
            historySettings: SQLHistoryRetentionSettings(maxEntries: 2, retentionDays: 1))
        snapshot.trimHistory(now: now)
        #expect(snapshot.history.map(\.sql) == ["Old favorite", "Ordinary 2", "Ordinary 3", "Recent favorite"])
        #expect(snapshot.history.filter(\.isFavorite).count == 2)
        #expect(snapshot.history.filter { !$0.isFavorite }.count == 2)
    }

    @Test func insertionOrderBreaksDateTiesIncludingFavorites() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = SQLWorkspaceSnapshot(history: [entry("First", date: now), entry("Pinned", date: now, favorite: true),
            entry("Second", date: now), entry("Third", date: now)],
            historySettings: SQLHistoryRetentionSettings(maxEntries: 2, retentionDays: 1))
        snapshot.trimHistory(now: now)
        #expect(snapshot.history.map(\.sql) == ["Pinned", "Second", "Third"])
    }

    @Test func removingFavoriteImmediatelyRestoresAgeAndCountEligibility() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = SQLWorkspaceSnapshot(history: [entry("Old", date: now.addingTimeInterval(-2 * 86_400), favorite: true),
            entry("Earlier", date: now.addingTimeInterval(-1), favorite: true), entry("Latest", date: now)],
            historySettings: SQLHistoryRetentionSettings(maxEntries: 1, retentionDays: 1))
        snapshot.trimHistory(now: now)
        #expect(snapshot.history.count == 3)
        for index in snapshot.history.indices { snapshot.history[index].isFavorite = false }
        snapshot.trimHistory(now: now)
        #expect(snapshot.history.map(\.sql) == ["Latest"])
    }

    @Test func disabledRecordingRejectsOrdinaryAndFavoriteEntries() {
        let now = Date.now
        let existing = entry("Saved", date: now, favorite: true)
        var snapshot = SQLWorkspaceSnapshot(history: [existing], historyEnabled: false)
        snapshot.record(entry("Ordinary", date: now), now: now)
        snapshot.record(entry("Favorite", date: now, favorite: true), now: now)
        #expect(snapshot.history == [existing])
    }

    @Test func clearHistoryKeepsFavoritesUnlessExplicitlyIncluded() {
        let favorite = entry("Favorite", date: .now, favorite: true)
        var snapshot = SQLWorkspaceSnapshot(history: [entry("Ordinary", date: .now), favorite])
        snapshot.clearHistory()
        #expect(snapshot.history == [favorite])
        snapshot.clearHistory(includeFavorites: true)
        #expect(snapshot.history.isEmpty)
    }

    @Test func memoryStorePreservesSettingsAndFavoritesAcrossSaveAndLoad() async {
        let now = Date.now
        let favorite = entry("Favorite", date: now.addingTimeInterval(-90 * 86_400), favorite: true)
        let settings = SQLHistoryRetentionSettings(maxEntries: 1, retentionDays: 2)
        let store = MemorySQLDocumentStore()
        await store.save(SQLWorkspaceSnapshot(history: [favorite, entry("Earlier", date: now.addingTimeInterval(-1)),
            entry("Latest", date: now)], historyEnabled: false, historySettings: settings))
        let restored = await store.load()
        #expect(restored.historySettings == settings && !restored.historyEnabled)
        #expect(restored.history.map(\.sql) == ["Favorite", "Latest"])
        #expect(restored.history.first == favorite)
    }

    @Test func fileStoreRoundTripsSettingsAndFavoriteMetadata() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
        let favorite = entry("Favorite", date: now.addingTimeInterval(-100 * 86_400), favorite: true)
        let settings = SQLHistoryRetentionSettings(maxEntries: 1, retentionDays: 7)
        let snapshot = SQLWorkspaceSnapshot(history: [favorite, entry("Earlier", date: now.addingTimeInterval(-1)),
            entry("Latest", date: now)], historySettings: settings)
        try await FileSQLDocumentStore(fileURL: url).save(snapshot)
        let restored = try await FileSQLDocumentStore(fileURL: url).load()
        #expect(restored.historySettings == settings)
        #expect(restored.history.map(\.sql) == ["Favorite", "Latest"])
        #expect(restored.history.first == favorite)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let histories = try #require(json["history"] as? [[String: Any]])
        #expect(histories.first?["isFavorite"] as? Bool == true)
        #expect(histories.last?["isFavorite"] as? Bool == false)
    }

    @Test func v2MigrationPreservesTypedMetadataAndExactPrivateBackup() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("workspace.json")
        let document = StoredSQLDocument(title: "Recovered", text: "SELECT 'κόσμος';", profileID: UUID())
        let timestamp = floor(Date.now.timeIntervalSince1970) * 1_000
        let entryID = UUID()
        let data = Data("""
        { "version": 2, "documents":[{"id":"\(document.id)","title":"Recovered","text":"SELECT 'κόσμος';","profileID":"\(document.profileID!)"}],
          "selectedDocumentID":"\(document.id)","historyEnabled":false,"history":[
          {"id":"\(entryID)","date":\(timestamp),"documentID":"\(document.id)","profileID":"\(document.profileID!)",
           "sql":"SELECT '😀'","outcome":"failed","startedAt":\(timestamp - 12),"finishedAt":\(timestamp),
           "durationMs":12,"loadedRowCount":4,"affectedRowCount":2,"exportedRowCount":3,"truncated":true,
           "countsArePartial":true,"sqlState":"42000","errorMessage":"The database rejected the command.","sqlCompleted":false}] }
        """.utf8)
        try data.write(to: url)
        let store = FileSQLDocumentStore(fileURL: url)
        let migrated = try await store.load()
        #expect(migrated.version == SQLWorkspaceSnapshot.currentVersion)
        #expect(migrated.documents == [document] && migrated.selectedDocumentID == document.id)
        #expect(!migrated.historyEnabled && migrated.historySettings == .default)
        let history = try #require(migrated.history.first)
        #expect(history.id == entryID && history.documentID == document.id && history.profileID == document.profileID)
        #expect(history.outcome == .failed && history.legacyOutcome == nil && !history.isFavorite)
        #expect(history.durationMs == 12 && history.loadedRowCount == 4 && history.affectedRowCount == 2)
        #expect(history.exportedRowCount == 3 && history.truncated == true && history.countsArePartial == true)
        #expect(history.startedAt != nil && history.finishedAt != nil && history.sqlCompleted == false)
        #expect(history.sqlState == "42000" && history.errorMessage == "The database rejected the command.")
        let backup = url.appendingPathExtension("v2.backup")
        #expect(try Data(contentsOf: backup) == data)
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try await store.load() == migrated)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test(arguments: ["null", "{}", "{\"maxEntries\":0,\"retentionDays\":30}",
        "{\"maxEntries\":100001,\"retentionDays\":30}", "{\"maxEntries\":1000,\"retentionDays\":0}",
        "{\"maxEntries\":1000,\"retentionDays\":3651}", "{\"maxEntries\":\"1000\",\"retentionDays\":30}"])
    func malformedSettingsAreNeverReplacedOrBackedUp(settings: String) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("workspace.json")
        let data = Data("{\"version\":3,\"documents\":[],\"historySettings\":\(settings)}".utf8)
        try data.write(to: url)
        let store = FileSQLDocumentStore(fileURL: url)
        await #expect(throws: SQLDocumentStoreError.self) { _ = try await store.load() }
        await #expect(throws: SQLDocumentStoreError.self) { try await store.save(SQLWorkspaceSnapshot()) }
        #expect(try Data(contentsOf: url) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["workspace.json"])
    }

    @Test func malformedFavoriteAndDuplicateEntriesLeaveOriginalFileUnchanged() async throws {
        let entryID = UUID()
        let history = "{\"id\":\"\(entryID)\",\"date\":0,\"sql\":\"SELECT 1\",\"outcome\":\"succeeded\"}"
        let malformed = history.dropLast() + ",\"isFavorite\":\"yes\"}"
        for entries in [String(malformed), history + "," + history] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("workspace.json")
            let data = Data("{\"version\":3,\"documents\":[],\"historySettings\":{\"maxEntries\":1000,\"retentionDays\":30},\"history\":[\(entries)]}".utf8)
            try data.write(to: url)
            let store = FileSQLDocumentStore(fileURL: url)
            await #expect(throws: SQLDocumentStoreError.self) { _ = try await store.load() }
            await #expect(throws: SQLDocumentStoreError.self) { try await store.save(SQLWorkspaceSnapshot()) }
            #expect(try Data(contentsOf: url) == data)
        }
    }

    @Test func invalidSettingsCannotReplaceAValidSavedSnapshot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let store = FileSQLDocumentStore(fileURL: url)
        try await store.save(SQLWorkspaceSnapshot(historySettings: SQLHistoryRetentionSettings(maxEntries: 50, retentionDays: 14)))
        let original = try Data(contentsOf: url)
        let invalid = SQLWorkspaceSnapshot(historySettings: SQLHistoryRetentionSettings(maxEntries: -1, retentionDays: 14))
        await #expect(throws: SQLDocumentStoreError.self) { try await store.save(invalid) }
        #expect(try Data(contentsOf: url) == original)
    }

    private func entry(_ sql: String, date: Date, favorite: Bool = false) -> SQLHistoryEntry {
        var entry = SQLHistoryEntry(date: date, sql: sql, outcome: "Completed")
        entry.isFavorite = favorite
        return entry
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}
