import Foundation
import Testing
@testable import DBeer

// Model and protocol subprocess coverage only; no windows, dialogs, or application activation.
@MainActor
struct SQLHistoryManagementTests {
    private let day: TimeInterval = 24 * 60 * 60

    private func entry(_ sql: String = "SELECT 1", age: TimeInterval = 0, profileID: UUID? = nil,
                       outcome: SQLHistoryOutcome = .succeeded, favorite: Bool = false) -> SQLHistoryEntry {
        var entry = SQLHistoryEntry(date: .now.addingTimeInterval(-age), profileID: profileID,
            sql: sql, outcome: "legacy")
        entry.outcome = outcome
        entry.legacyOutcome = nil
        entry.isFavorite = favorite
        return entry
    }

    private func client() -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        sessions = 0
        def send(reply): print(json.dumps(reply), flush=True)
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            reply = dict(requestId=command['requestId'])
            if kind == 'hello':
                reply.update(type='hello.ack',protocolVersion=\(BackendProtocol.version))
            elif kind == 'connect':
                sessions += 1
                reply.update(type='connect.result',sessionId='history-management-'+str(sessions),engine='postgresql',
                    capabilities=['execute','cancel','catalog','transactions'],transactionStatus='idle')
            elif kind == 'operation.assess':
                reply.update(type='operation.assessment',sessionId=command['sessionId'],queryId=command['queryId'],
                    assessment=dict(decision='allow',policy=dict(environment='development',readOnly=False),authorization='grant',
                        operations=[dict(kind='read',statements=[]) for operation in command['operations']]))
            elif kind in ['catalog', 'execute']:
                send(dict(type='query.started',requestId=command['requestId'],sessionId=command['sessionId'],queryId=command['queryId']))
                reply.update(type='query.result',sessionId=command['sessionId'],queryId=command['queryId'],
                    transactionStatus='idle',durationMs=1,columns=[],rows=[],commandTag='SELECT 0',
                    rowCount=0,displayedRowCount=0,truncated=False)
            elif kind == 'cancel':
                reply.update(type='cancel.ack',sessionId=command['sessionId'],queryId=command['queryId'],status='alreadyFinished')
            elif kind == 'disconnect':
                reply.update(type='disconnect.ack',sessionId=command['sessionId'])
            elif kind == 'shutdown':
                reply.update(type='shutdown.ack')
            else:
                sys.exit(42)
            send(reply)
            if kind == 'shutdown': break
        """])
    }

    private func workspace(store: any SQLDocumentStore) async throws -> ApplicationWorkspace {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store,
            closeDecision: { _ in .rollback }, executionDecision: { _ in true }, helperFactory: { self.client() })
        await workspace.start()
        try #require(workspace.error == nil)
        return workspace
    }

    @Test func favoritesPreferencesAndDisabledRecordingSurviveRestart() async throws {
        let first = entry("SELECT 'favorite';")
        let second = entry("SELECT 'ordinary';", age: day)
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(history: [second, first], historyEnabled: false))
        let initial = try await workspace(store: store)
        let settings = SQLHistoryRetentionSettings(maxEntries: 70, retentionDays: 10)

        try #require(await initial.updateHistorySettings(settings))
        await initial.setHistoryFavorite(first.id, isFavorite: true)
        #expect(!initial.historyEnabled)
        await initial.shutdown()

        let restored = try await workspace(store: store)
        #expect(restored.historySettings == settings && !restored.historyEnabled)
        #expect(Set(restored.history.map(\.id)) == [first.id, second.id])
        #expect(restored.history.first { $0.id == first.id }?.isFavorite == true)
        #expect(restored.history.first { $0.id == second.id }?.isFavorite == false)
        #expect(restored.services.isEmpty && restored.documents.allSatisfy { $0.runtime == nil })
        await restored.shutdown()
    }

    @Test func ordinaryClearPreservesFavoritesAndExplicitInclusionRemovesThem() async throws {
        let favorite = entry(favorite: true)
        let first = entry()
        let second = entry()
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(history: [favorite, first, second]))
        let workspace = try await workspace(store: store)

        await workspace.clearHistory()
        #expect(workspace.history.map(\.id) == [favorite.id])
        #expect(await store.load().history.map(\.id) == [favorite.id])
        await workspace.clearHistory(entryIDs: [favorite.id], includeFavorites: true)
        #expect(workspace.history.isEmpty)
        #expect(await store.load().history.isEmpty)
        await workspace.shutdown()
    }

    @Test func explicitEntryDeletionRemovesOnlyThatIdentityIncludingAFavorite() async throws {
        let first = entry("SELECT 'identical';", favorite: true)
        let target = entry("SELECT 'identical';", favorite: true)
        let last = entry("SELECT 'identical';")
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(history: [first, target, last]))
        let workspace = try await workspace(store: store)

        await workspace.deleteHistoryEntry(first.id)
        await workspace.deleteHistoryEntry(target.id, includeFavorite: true)
        await workspace.deleteHistoryEntry(UUID())
        #expect(Set(workspace.history.map(\.id)) == [first.id, last.id])
        #expect(Set(await store.load().history.map(\.id)) == [first.id, last.id])
        #expect(workspace.history.first { $0.id == first.id }?.isFavorite == true)
        await workspace.shutdown()
    }

    @Test func clearingCombinedSearchResultsKeepsEveryNonmatchingEntryAndRequiresFavoriteOptIn() async throws {
        let profileID = UUID()
        let matching = entry("SELECT 'Café target';", age: day, profileID: profileID, outcome: .failed, favorite: true)
        let others = [
            entry("SELECT 'other';", age: day, profileID: profileID, outcome: .failed, favorite: true),
            entry("SELECT 'Café target';", age: day, profileID: UUID(), outcome: .failed, favorite: true),
            entry("SELECT 'Café target';", age: 5 * day, profileID: profileID, outcome: .failed, favorite: true),
            entry("SELECT 'Café target';", age: day, profileID: profileID, outcome: .succeeded, favorite: true),
            entry("SELECT 'Café target';", age: day, profileID: profileID, outcome: .failed)
        ]
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(history: others + [matching]))
        let workspace = try await workspace(store: store)
        let filter = SQLHistoryFilter(query: "CAFE TARGET", profile: .profile(profileID),
            from: .now.addingTimeInterval(-2 * day), before: .now, outcome: .failed, favoritesOnly: true)
        let results = try SQLHistorySearch.results(entries: workspace.history, filter: filter)
        let selectedIDs = Set(results.map(\.id))
        try #require(selectedIDs == [matching.id])

        await workspace.clearHistory(entryIDs: selectedIDs, includeFavorites: false)
        #expect(Set(workspace.history.map(\.id)) == Set(others.map(\.id) + [matching.id]))
        await workspace.clearHistory(entryIDs: selectedIDs, includeFavorites: true)
        #expect(Set(workspace.history.map(\.id)) == Set(others.map(\.id)))
        #expect(Set(await store.load().history.map(\.id)) == Set(others.map(\.id)))
        await workspace.shutdown()
    }

    @Test func frozenClearSelectionKeepsLaterExecutionsAndEntriesFavoritedAfterSelection() async throws {
        let removable = entry("SELECT 'capture';")
        let protected = entry("SELECT 'capture';")
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(history: [removable, protected]))
        let workspace = try await workspace(store: store)
        let selection = SQLHistoryClearSelection(entries: try SQLHistorySearch.results(entries: workspace.history,
            filter: SQLHistoryFilter(query: "capture")), scope: .matchingFilters)
        let selectedIDs = selection.entryIDs
        try #require(selectedIDs == [removable.id, protected.id])
        #expect(selection.ordinaryCount == 2 && selection.favoriteCount == 0)
        try #require(await workspace.library.saveConnection(name: "History fixture", settings: ConnectionSettings(
            host: "db.example.test", port: 5432, database: "history", user: "reader", password: "", sslMode: "disable",
            policy: ExecutionPolicy(environment: .development))))
        let profileID = try #require(workspace.library.selectedConnectionId)
        let document = workspace.newDocument(profileID: profileID, text: "SELECT 'capture';")
        await workspace.run(document)
        let later = try #require(workspace.history.first { !selectedIDs.contains($0.id) })
        try #require(later.sql == "SELECT 'capture'" && later.outcome == .succeeded)
        await workspace.setHistoryFavorite(protected.id, isFavorite: true)
        await workspace.deleteHistoryEntry(protected.id)
        #expect(workspace.history.contains { $0.id == protected.id && $0.isFavorite })
        #expect(selection.entryIDs == selectedIDs && selection.ordinaryCount == 2 && selection.favoriteCount == 0)

        await workspace.clearHistory(entryIDs: selectedIDs, includeFavorites: false)
        #expect(Set(workspace.history.map(\.id)) == [protected.id, later.id])
        #expect(Set(await store.load().history.map(\.id)) == [protected.id, later.id])
        await workspace.shutdown()
    }

    @Test func smallerRetentionSettingsTrimOnlyOrdinaryHistoryAndPersistTheResult() async throws {
        let favorite = entry("SELECT 'old favorite';", age: 200 * day, favorite: true)
        let expired = entry("SELECT 'expired';", age: 40 * day)
        let older = entry("SELECT 'older';", age: 2 * day)
        let newest = entry("SELECT 'newest';", age: 60)
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(history: [favorite, expired, older, newest],
            historySettings: SQLHistoryRetentionSettings(maxEntries: 20, retentionDays: 90)))
        let workspace = try await workspace(store: store)
        try #require(workspace.history.count == 4)
        let settings = SQLHistoryRetentionSettings(maxEntries: 1, retentionDays: 3)

        try #require(await workspace.updateHistorySettings(settings))
        #expect(workspace.historySettings == settings)
        #expect(Set(workspace.history.map(\.id)) == [favorite.id, newest.id])
        let persisted = await store.load()
        #expect(persisted.historySettings == settings)
        #expect(Set(persisted.history.map(\.id)) == [favorite.id, newest.id])
        await workspace.shutdown()
    }

    @Test func invalidSettingsNeverChangePreferencesOrRemoveHistory() async throws {
        let entries = [entry(), entry(favorite: true)]
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(history: entries))
        let workspace = try await workspace(store: store)
        let originalSettings = workspace.historySettings
        let originalHistory = workspace.history
        let invalid = [
            SQLHistoryRetentionSettings(maxEntries: 0, retentionDays: 30),
            SQLHistoryRetentionSettings(maxEntries: 1_000, retentionDays: 0),
            SQLHistoryRetentionSettings(maxEntries: Int.max, retentionDays: 30),
            SQLHistoryRetentionSettings(maxEntries: 1_000, retentionDays: Int.max)
        ]

        for settings in invalid {
            #expect(!(await workspace.updateHistorySettings(settings)))
            #expect(workspace.historySettings == originalSettings && workspace.history == originalHistory)
            let persisted = await store.load()
            #expect(persisted.historySettings == originalSettings && persisted.history == originalHistory)
        }
        await workspace.shutdown()
    }

    @Test func failedSaveReportsUnsavedChangesAndSuccessfulRetryPersistsThem() async throws {
        let entry = entry()
        let store = FailableHistoryManagementStore(snapshot: SQLWorkspaceSnapshot(history: [entry]))
        let workspace = try await workspace(store: store)
        await store.setFailing(true)
        let settings = SQLHistoryRetentionSettings(maxEntries: 50, retentionDays: 15)

        #expect(!(await workspace.updateHistorySettings(settings)))
        #expect(workspace.historySettings == settings)
        #expect(workspace.history.map(\.id) == [entry.id])
        #expect(workspace.historyError?.isEmpty == false)
        #expect(await store.load().historySettings == .default)
        await store.setFailing(false)
        await workspace.setHistoryFavorite(entry.id, isFavorite: true)
        #expect(workspace.historyError == nil)
        let persisted = await store.load()
        #expect(persisted.historySettings == settings)
        #expect(persisted.history.first?.isFavorite == true)
        await workspace.shutdown()
    }
}

private actor FailableHistoryManagementStore: SQLDocumentStore {
    private var snapshot: SQLWorkspaceSnapshot
    private var failing = false

    init(snapshot: SQLWorkspaceSnapshot) { self.snapshot = snapshot }
    func load() -> SQLWorkspaceSnapshot { snapshot }
    func setFailing(_ value: Bool) { failing = value }
    func save(_ snapshot: SQLWorkspaceSnapshot) throws {
        if failing { throw SQLDocumentStoreError.write }
        self.snapshot = snapshot
    }
}
