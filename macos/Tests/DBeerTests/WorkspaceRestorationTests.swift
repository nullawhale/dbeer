import Foundation
import Testing
@testable import DBeer

/// Models, isolated stores and helper subprocesses only. No windows, dialogs,
/// application activation, desktop input or native clipboard access.
@MainActor
struct WorkspaceRestorationTests {
    private func profile(engine: DatabaseEngine = .postgresql) -> SavedConnection {
        SavedConnection(name: "Workspace fixture", settings: ConnectionSettings(
            host: "127.0.0.1", port: engine.defaultPort, database: "work", user: "fixture",
            password: "", sslMode: "disable", engine: engine,
            contactPoints: engine == .cassandra ? ["127.0.0.1"] : nil,
            localDatacenter: engine == .cassandra ? "dc1" : nil))
    }

    private func table(profileID: UUID? = nil, page: Int = 7) -> StoredSQLDocument {
        StoredSQLDocument(title: "Items", text: "Table data", profileID: profileID, kind: .table,
            table: StoredTableDocument(reference: TableReference(schema: "work", name: "items", kind: "table"),
                page: page, filters: [CatalogFilter(column: "id", operator: "gte", value: "1")],
                sort: [CatalogSort(column: "id", direction: "desc")]))
    }

    @Test func mixedWorkspaceRestoresOrderSelectionBindingsAndHistoryWithoutStartingHelper() async throws {
        let available = profile()
        let missing = UUID()
        let sql = StoredSQLDocument(title: "Analysis", text: "  SELECT 'κόσμος 🐋';\r\n", profileID: available.id,
            fileURL: URL(fileURLWithPath: "/workspace-fixtures/not-present.sql"), fileContentSHA256: String(repeating: "a", count: 64))
        let browse = table(profileID: missing)
        var favorite = SQLHistoryEntry(date: .now, profileID: available.id, sql: "SELECT 1", outcome: "Completed")
        favorite.isFavorite = true
        let settings = SQLHistoryRetentionSettings(maxEntries: 19, retentionDays: 6)
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(documents: [sql, browse],
            selectedDocumentID: browse.id, history: [favorite], historyEnabled: false, historySettings: settings))
        var starts = 0
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [available], selectedConnectionId: available.id)),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store, helperFactory: {
                starts += 1
                return BackendClient(executableURL: URL(fileURLWithPath: "/workspace-fixtures/unused-helper"))
            })

        await workspace.restoreSavedWorkspace()
        #expect(workspace.error == nil && starts == 0 && workspace.services.isEmpty)
        #expect(workspace.documents.map(\.id) == [sql.id, browse.id])
        #expect(workspace.documents.map(\.storedState) == [sql, browse])
        #expect(workspace.selectedDocumentID == browse.id)
        #expect(workspace.history == [favorite] && !workspace.historyEnabled && workspace.historySettings == settings)
        for document in workspace.documents {
            #expect(document.runtime == nil && document.grid == nil && !document.isRunning)
            #expect(document.executions.isEmpty && document.successfulExecutionRanges.isEmpty)
            #expect(document.tableCursor == nil && document.tableNextCursor == nil)
        }
        let restoredSQL = try #require(workspace.documents.first)
        #expect(restoredSQL.restoredFileBinding && restoredSQL.fileURL == sql.fileURL)
        #expect(restoredSQL.historyConnectionNotice == nil)
        let restoredTable = try #require(workspace.documents.last)
        #expect(restoredTable.tableNeedsExplicitLoad && restoredTable.profileID == missing)
        #expect(restoredTable.historyConnectionNotice?.contains("original connection") == true)
        #expect(restoredTable.profileID != available.id)
        await workspace.run(restoredTable)
        #expect(starts == 0 && restoredTable.runtime == nil)
        await workspace.flushDocuments()
        #expect(await store.load().documents == [sql, browse])
        await workspace.shutdown()
    }

    @Test func runtimeResultAndPendingApplyStateCannotEnterRestoredDocument() throws {
        let original = SQLDocument(title: "Table", text: "Table data", profileID: UUID())
        original.table = TableReference(schema: "work", name: "items", kind: "table")
        original.tableFilters = [CatalogFilter(column: "id", operator: "eq", value: "1")]
        original.tableSort = [CatalogSort(column: "id", direction: "asc")]
        original.page = 9
        original.attach(WorkspaceModel(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore()), preserveTablePage: true)
        original.tableCursor = "old-session-cursor"
        original.tableNextCursor = "old-session-next"
        original.isRunning = true
        original.stopRequested = true
        original.localError = "Transient execution failure"
        original.executions = [SQLExecution(sql: "SELECT 1", range: NSRange(location: 0, length: 8))]
        let result = BackendMessage(type: "query.result", requestId: "fixture",
            columns: [ResultColumn(index: 0, name: "id", typeOid: 23, nativeType: "int4")], rows: [["1"]])
        let draft = GridDraft(reference: try #require(original.table), result: result,
            metadata: [["name": "id", "nativeType": "integer", "primaryKey": "1", "editable": "true"]])
        draft.set(ChangeValue(kind: "text", value: "2"), row: 0, column: 0)
        draft.outcomeUnknown = true
        draft.isApplying = true
        original.attachGrid(draft)

        let saved = original.storedState
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        for key in ["runtime", "grid", "executions", "isRunning", "stopRequested", "localError", "tableCursor", "tableNextCursor"] {
            #expect(object[key] == nil)
        }
        let restored = SQLDocument(restoring: saved)
        #expect(restored.page == 9 && restored.tableFilters == original.tableFilters && restored.tableSort == original.tableSort)
        #expect(restored.runtime == nil && restored.grid == nil && !restored.isRunning && !restored.stopRequested)
        #expect(restored.executions.isEmpty && restored.localError == nil)
        #expect(restored.tableCursor == nil && restored.tableNextCursor == nil && restored.tableNeedsExplicitLoad)
        #expect(restored.storedState == saved)
    }

    @Test func navigationFileBindingAndSelectionAutosaveWithoutHelperOrQueries() async throws {
        let sql = StoredSQLDocument(title: "Draft", text: "SELECT 1")
        let browse = table()
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(documents: [sql, browse], selectedDocumentID: sql.id))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store)
        await workspace.restoreSavedWorkspace()
        let restoredSQL = try #require(workspace.documents.first)
        let restoredTable = try #require(workspace.documents.last)
        restoredSQL.fileURL = URL(fileURLWithPath: "/workspace-fixtures/analysis.sql")
        restoredSQL.fileContentSHA256 = String(repeating: "b", count: 64)
        restoredTable.tableFilters = [CatalogFilter(column: "id", operator: "isNotNull")]
        restoredTable.tableSort = [CatalogSort(column: "id", direction: "asc")]
        restoredTable.page = 13
        workspace.selectedDocumentID = restoredTable.id
        try await eventually {
            let saved = await store.load()
            return saved.documents.last?.table?.page == 13 && saved.documents.first?.fileURL == restoredSQL.fileURL
        }
        let saved = await store.load()
        #expect(saved.documents == workspace.documents.map(\.storedState))
        #expect(saved.selectedDocumentID == restoredTable.id)
        await workspace.shutdown()
    }

    @Test func anInFlightSaveCannotOverwriteANewerMixedWorkspaceSnapshot() async throws {
        let initial = table()
        let store = DeferredWorkspaceStore(snapshot: SQLWorkspaceSnapshot(documents: [initial], selectedDocumentID: initial.id),
            delayFirstSave: true)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store)
        await workspace.restoreSavedWorkspace()
        let document = try #require(workspace.documents.first)
        document.page = 4
        let first = Task { await workspace.flushDocuments() }
        try await eventually { await store.saveCalls == 1 }
        document.page = 11
        let second = Task { await workspace.flushDocuments() }
        for _ in 0..<10 { await Task.yield() }
        #expect(await store.saveCalls == 1)
        await store.releaseSave()
        await first.value
        await second.value
        #expect(try await store.load().documents.first?.table?.page == 11)
        #expect(await store.saveCalls == 2)
        await workspace.shutdown()
    }

    @Test func tabsCreatedDuringRestorationKeepTheirTextAndSelection() async throws {
        let saved = StoredSQLDocument(title: "Saved", text: "SELECT 'saved'")
        let store = DeferredWorkspaceStore(snapshot: SQLWorkspaceSnapshot(documents: [saved], selectedDocumentID: saved.id),
            delayLoad: true)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store)
        let restore = Task { await workspace.restoreSavedWorkspace() }
        try await eventually { await store.waitingForLoad }
        let local = workspace.newDocument(text: "SELECT 'new local tab'")
        await store.releaseLoad()
        await restore.value
        #expect(workspace.documents.map(\.id) == [saved.id, local.id])
        #expect(workspace.selectedDocumentID == local.id && local.text == "SELECT 'new local tab'")
        await workspace.flushDocuments()
        #expect(try await store.load().documents.map(\.id) == [saved.id, local.id])
        await workspace.shutdown()
    }

    @Test func failedRestorationCannotPublishAnEmptyOrReplacementWorkspace() async {
        let store = DeferredWorkspaceStore(snapshot: SQLWorkspaceSnapshot(), failLoad: true)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store)
        await workspace.restoreSavedWorkspace()
        #expect(workspace.error != nil)
        workspace.newDocument(text: "SELECT 'keep in memory'")
        await workspace.flushDocuments()
        await workspace.shutdown()
        #expect(await store.saveCalls == 0)
    }

    @Test(arguments: [false, true])
    func finalSaveFailureKeepsWorkspaceOpenAndRetryClearsOnlyItsOwnError(unrelatedError: Bool) async throws {
        let initial = table()
        let store = DeferredWorkspaceStore(snapshot: SQLWorkspaceSnapshot(documents: [initial], selectedDocumentID: initial.id),
            failSave: true)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store, closeDecision: { _ in .cancel })
        await workspace.restoreSavedWorkspace()
        let document = try #require(workspace.documents.first)
        document.page = 21
        #expect(await workspace.prepareToClose(.application) == false)
        #expect(workspace.error != nil && workspace.historyError != nil && !workspace.isClosing)
        #expect(workspace.documents.first === document)
        #expect(try await store.load().documents.first?.table?.page == initial.table?.page)
        if unrelatedError { workspace.reportCopyError("A separate operation failed.") }
        await store.setSaveFailure(false)
        #expect(await workspace.prepareToClose(.application))
        #expect(try await store.load().documents.first == document.storedState)
        #expect(workspace.historyError == nil)
        #expect(workspace.error == (unrelatedError ? "A separate operation failed." : nil))
        await workspace.shutdown()
    }

    private func client(expectedPage: Int, engine: DatabaseEngine) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        def send(value): print(json.dumps(value), flush=True)
        count = 0
        engine = '\(engine.rawValue)'
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            reply = dict(requestId=command['requestId'])
            if kind == 'hello':
                reply.update(type='hello.ack',protocolVersion=\(BackendProtocol.version))
            elif kind == 'connect':
                count += 1
                caps = ['execute','cancel','catalog']
                caps += ['cursorPagination','localReadOnly'] if engine == 'cassandra' else ['transactions','gridEditing']
                reply.update(type='connect.result',sessionId='restored-'+str(count),engine=engine,capabilities=caps,
                    transactionStatus='unsupported' if engine == 'cassandra' else 'idle')
            elif kind == 'catalog':
                request = command['catalog']
                send(dict(type='query.started',requestId=command['requestId'],sessionId=command['sessionId'],queryId=command['queryId']))
                reply.update(type='query.result',sessionId=command['sessionId'],queryId=command['queryId'],
                    transactionStatus='unsupported' if engine == 'cassandra' else 'idle',durationMs=1,
                    columns=[],rows=[],commandTag='SELECT 0',rowCount=0,displayedRowCount=0,truncated=False)
                if request['kind'] == 'columns':
                    names = ['name','nativeType','primaryKey','editable']
                    reply.update(columns=[dict(index=i,name=name,engine=engine,nativeType='text') for i,name in enumerate(names)],
                        rows=[['id','int','1','true']],commandTag='SELECT 1',rowCount=1,displayedRowCount=1)
                elif request['kind'] == 'browse':
                    assert request.get('page',0) == \(expectedPage)
                    assert request.get('cursor') is None
                    assert request['schema'] == 'work' and request['object'] == 'items'
                    assert request['sort'] == [dict(column='id',direction='desc')]
                    assert request['filters'] == [dict(column='id',operator='gte',value='1')]
                    reply.update(columns=[dict(index=0,name='id',engine=engine,nativeType='int')],
                        rows=[['1']],commandTag='SELECT 1',rowCount=1,displayedRowCount=1)
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

    @Test(arguments: [DatabaseEngine.postgresql, .mysql, .cassandra])
    func explicitLoadPreservesOffsetPagesAndRestartsCursorPages(engine: DatabaseEngine) async throws {
        let profile = profile(engine: engine)
        let saved = table(profileID: profile.id)
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(documents: [saved], selectedDocumentID: saved.id))
        let client = client(expectedPage: engine == .cassandra ? 0 : 7, engine: engine)
        var starts = 0
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id)),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store,
            closeDecision: { _ in .cancel }, helperFactory: { starts += 1; return client })
        await workspace.start()
        let document = try #require(workspace.documents.first)
        #expect(starts == 1 && document.runtime == nil && document.grid == nil && document.page == 7)
        #expect(workspace.services.isEmpty && document.tableNeedsExplicitLoad)
        await workspace.run(document)
        #expect(document.localError == nil)
        #expect(document.runtime?.result?.rows == [["1"]])
        #expect(document.page == (engine == .cassandra ? 0 : 7))
        #expect(document.grid != nil && !document.tableNeedsExplicitLoad)
        await workspace.shutdown()
        #expect(await client.waitForExit().status == 0)
    }

    private func eventually(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await predicate())
    }
}

private actor DeferredWorkspaceStore: SQLDocumentStore {
    private var snapshot: SQLWorkspaceSnapshot
    private var delayLoad: Bool
    private let delayFirstSave: Bool
    private let failLoad: Bool
    private var failSave: Bool
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private(set) var waitingForLoad = false
    private(set) var saveCalls = 0

    init(snapshot: SQLWorkspaceSnapshot, delayLoad: Bool = false, delayFirstSave: Bool = false,
         failLoad: Bool = false, failSave: Bool = false) {
        self.snapshot = snapshot
        self.delayLoad = delayLoad
        self.delayFirstSave = delayFirstSave
        self.failLoad = failLoad
        self.failSave = failSave
    }

    func load() async throws -> SQLWorkspaceSnapshot {
        if failLoad { throw SQLDocumentStoreError.read }
        if delayLoad {
            waitingForLoad = true
            await withCheckedContinuation { loadContinuation = $0 }
            delayLoad = false
        }
        return snapshot
    }

    func save(_ snapshot: SQLWorkspaceSnapshot) async throws {
        saveCalls += 1
        if failSave { throw SQLDocumentStoreError.write }
        if delayFirstSave, saveCalls == 1 {
            await withCheckedContinuation { saveContinuation = $0 }
        }
        self.snapshot = snapshot
    }

    func releaseLoad() { loadContinuation?.resume(); loadContinuation = nil }
    func releaseSave() { saveContinuation?.resume(); saveContinuation = nil }
    func setSaveFailure(_ fail: Bool) { failSave = fail }
}
