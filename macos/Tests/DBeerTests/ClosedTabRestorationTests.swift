import Foundation
import Testing
@testable import DBeer

/// Models, isolated stores and protocol subprocesses only. No windows, native
/// controls, desktop input, clipboard access or application activation.
@Suite(.serialized)
@MainActor
struct ClosedTabRestorationTests {
    private func workspace(store: any SQLDocumentStore = MemorySQLDocumentStore(),
                           decision: @escaping @MainActor (WorkspaceCloseIssue) async -> WorkspaceCloseDecision = { _ in .discard }) async -> ApplicationWorkspace {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store,
            closeDecision: decision)
        await workspace.restoreSavedWorkspace()
        return workspace
    }

    private func table(in workspace: ApplicationWorkspace, title: String = "Items") -> SQLDocument {
        let document = workspace.newDocument(text: "Table data")
        document.title = title
        document.profileID = UUID()
        document.table = TableReference(schema: "odd\"schema", name: "items.with.dots", kind: "table")
        document.tableFilters = [CatalogFilter(column: "amount", operator: "gte", value: "9007199254740993.123456789"),
            CatalogFilter(column: "empty", operator: "eq", value: ""), CatalogFilter(column: "missing", operator: "isNull")]
        document.tableSort = [CatalogSort(column: "id", direction: "desc")]
        document.page = 7
        return document
    }

    private func attachDraft(_ document: SQLDocument) throws -> GridDraft {
        let reference = try #require(document.table)
        let result = BackendMessage(type: "query.result", requestId: "fixture",
            columns: [ResultColumn(index: 0, name: "id", typeOid: 23, nativeType: "int4"),
                ResultColumn(index: 1, name: "label", typeOid: 25, nativeType: "text")], rows: [["1", "original"]])
        let grid = GridDraft(reference: reference, result: result,
            metadata: [["name": "id", "nativeType": "integer", "primaryKey": "1", "editable": "true"],
                ["name": "label", "nativeType": "text", "primaryKey": "0", "editable": "true"]])
        document.attachGrid(grid)
        return grid
    }

    private func expectContext(_ restored: SQLDocument, matches original: StoredSQLDocument) {
        var expected = original
        expected.id = restored.id
        #expect(restored.id != original.id)
        #expect(restored.storedState == expected)
        #expect(restored.runtime == nil && restored.grid == nil && !restored.isRunning && !restored.stopRequested)
        #expect(restored.executions.isEmpty && restored.successfulExecutionRanges.isEmpty && restored.localError == nil)
        #expect(restored.tableCursor == nil && restored.tableNextCursor == nil && restored.tableColumns.isEmpty)
    }

    @Test func mixedTabsReopenInReverseCloseOrderAtTheirOriginalPositions() async throws {
        let workspace = await workspace()
        let first = workspace.newDocument(text: "  SELECT 'κόσμος 🐋';\r\nSELECT '';\r\n")
        first.title = "Analysis"
        first.profileID = UUID()
        first.fileURL = URL(fileURLWithPath: "/workspace-fixtures/with spaces/analysis.sql")
        first.fileContentSHA256 = String(repeating: "a", count: 64)
        let middle = table(in: workspace)
        let last = workspace.newDocument(text: "SELECT 'last';")
        last.title = "Last"
        let states = [first.storedState, middle.storedState, last.storedState]
        await workspace.closeDocument(middle)
        await workspace.closeDocument(first)
        await workspace.closeDocument(last)
        #expect(workspace.documents.isEmpty && workspace.closedTabs.count == 3 && workspace.canReopenClosedTab)

        let reopenedLast = try #require(workspace.reopenClosedTab())
        expectContext(reopenedLast, matches: states[2])
        #expect(workspace.selectedDocumentID == reopenedLast.id)
        let reopenedFirst = try #require(workspace.reopenClosedTab())
        expectContext(reopenedFirst, matches: states[0])
        #expect(reopenedFirst.restoredFileBinding)
        let reopenedMiddle = try #require(workspace.reopenClosedTab())
        expectContext(reopenedMiddle, matches: states[1])
        #expect(reopenedMiddle.tableNeedsExplicitLoad)
        #expect(workspace.documents.map(\.title) == ["Analysis", "Items", "Last"])
        #expect(workspace.selectedDocumentID == reopenedMiddle.id)
        #expect(workspace.closedTabs.isEmpty && !workspace.canReopenClosedTab && workspace.reopenClosedTab() == nil)
        #expect(!workspace.canStartOperation(first) && !workspace.canStartOperation(middle) && !workspace.canStartOperation(last))
        await workspace.shutdown()
    }

    @Test func stackRetainsOnlyTheTwentyMostRecentlyClosedTabs() async throws {
        let workspace = await workspace()
        for index in 0..<25 {
            let document = workspace.newDocument(text: "SELECT \(index);")
            document.title = "Tab \(index)"
            await workspace.closeDocument(document)
        }
        #expect(workspace.documents.isEmpty && workspace.closedTabs.count == 20)
        var titles: [String] = []
        while let document = workspace.reopenClosedTab() { titles.append(document.title) }
        #expect(titles == (5..<25).reversed().map { "Tab \($0)" })
        #expect(Set(workspace.documents.map(\.id)).count == 20)
        await workspace.shutdown()
    }

    @Test func cancelledClosePreservesDraftAndOnlyASuccessfulCloseAddsOneEntry() async throws {
        var decision: WorkspaceCloseDecision = .cancel
        var issues: [WorkspaceCloseIssue] = []
        let workspace = await workspace { issue in issues.append(issue); return decision }
        let document = table(in: workspace)
        let grid = try attachDraft(document)
        grid.set(ChangeValue(kind: "text", value: "unsaved"), row: 0, column: 1)
        try #require(grid.pendingCount == 1)
        await workspace.closeDocument(document)
        #expect(workspace.documents.first === document && document.grid === grid && grid.pendingCount == 1)
        #expect(issues == [.changes(document.title, count: 1)])
        #expect(workspace.closedTabs.isEmpty && workspace.reopenClosedTab() == nil)
        decision = .discard
        await workspace.closeDocument(document)
        #expect(workspace.documents.isEmpty && workspace.closedTabs.count == 1)
        await workspace.closeDocument(document)
        #expect(workspace.closedTabs.count == 1)
        let reopened = try #require(workspace.reopenClosedTab())
        #expect(reopened.grid == nil && reopened.runtime == nil && reopened.tableNeedsExplicitLoad)
        #expect(reopened.id != document.id && !workspace.canStartOperation(document))
        await workspace.shutdown()
    }

    @Test func reopeningCannotReviveCursorsResultsOrAnUncertainApplyDraft() async throws {
        let workspace = await workspace()
        let document = table(in: workspace)
        let grid = try attachDraft(document)
        grid.set(.null, row: 0, column: 1)
        grid.outcomeUnknown = true
        document.tableCursor = "old-session-cursor"
        document.tableNextCursor = "old-session-next"
        document.tableColumns = grid.metadata
        document.executions = [SQLExecution(sql: "SELECT 1", range: NSRange(location: 0, length: 8))]
        document.localError = "Transient failure"
        let state = document.storedState
        await workspace.closeDocument(document)
        let reopened = try #require(workspace.reopenClosedTab())
        expectContext(reopened, matches: state)
        #expect(reopened.tableNeedsExplicitLoad)
        await workspace.shutdown()
    }

    @Test func missingConnectionBindingStaysOpaqueUntilExplicitReplacement() async throws {
        let workspace = await workspace()
        let document = workspace.newDocument(text: "SELECT 'keep original';")
        let missingID = UUID()
        document.profileID = missingID
        await workspace.closeDocument(document)
        let reopened = try #require(workspace.reopenClosedTab())
        #expect(reopened.profileID == missingID && reopened.text == document.text)
        #expect(reopened.historyConnectionNotice?.contains("connection") == true)
        await workspace.run(reopened)
        #expect(reopened.runtime == nil && workspace.services.isEmpty)
        await workspace.shutdown()
    }

    @Test func closedStackIsNotPersistedAndDoesNotSurviveWorkspaceRestart() async throws {
        let store = MemorySQLDocumentStore()
        let first = await workspace(store: store)
        let keep = first.newDocument(text: "SELECT 'open';")
        let closed = first.newDocument(text: "SELECT 'closed';")
        await first.closeDocument(closed)
        #expect(first.closedTabs.count == 1)
        await first.flushDocuments()
        let saved = await store.load()
        #expect(saved.documents.map(\.id) == [keep.id])
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        #expect(object["closedTabs"] == nil && object["closedDocuments"] == nil)
        await first.shutdown()
        #expect(first.closedTabs.isEmpty && first.reopenClosedTab() == nil)
        let second = await workspace(store: store)
        #expect(second.documents.map(\.id) == [keep.id])
        #expect(second.closedTabs.isEmpty && !second.canReopenClosedTab && second.reopenClosedTab() == nil)
        await second.shutdown()
    }

    @Test func clearDraftsRetainsUndoOnCancelAndClearsItOnlyAfterSuccessfulReview() async throws {
        var decision: WorkspaceCloseDecision = .cancel
        let workspace = await workspace(decision: { _ in decision })
        let closed = workspace.newDocument(text: "SELECT 'already closed';")
        await workspace.closeDocument(closed)
        let document = table(in: workspace)
        let grid = try attachDraft(document)
        grid.set(ChangeValue(kind: "text", value: "pending"), row: 0, column: 1)
        await workspace.clearRestoredDocuments()
        #expect(workspace.documents.first === document && workspace.closedTabs.count == 1 && grid.pendingCount == 1)
        decision = .discard
        await workspace.clearRestoredDocuments()
        #expect(workspace.documents.isEmpty && workspace.closedTabs.isEmpty && workspace.reopenClosedTab() == nil)
        await workspace.shutdown()
    }

    @Test func failedClearDraftsSaveKeepsOpenTabsAndExistingClosedEntries() async {
        let store = ClosedTabFailableStore()
        let workspace = await workspace(store: store)
        let closed = workspace.newDocument(text: "SELECT 'closed';")
        await workspace.closeDocument(closed)
        let open = workspace.newDocument(text: "SELECT 'open';")
        await store.setFailure(true)
        await workspace.clearRestoredDocuments()
        #expect(workspace.documents.first === open && workspace.closedTabs.count == 1)
        #expect(workspace.historyError != nil)
        await store.setFailure(false)
        await workspace.clearRestoredDocuments()
        #expect(workspace.documents.isEmpty && workspace.closedTabs.isEmpty)
        await workspace.shutdown()
    }

    private final class HelperEvidence {
        let directory: URL
        var entered: URL { directory.appendingPathComponent("disconnect-entered") }
        var released: URL { directory.appendingPathComponent("release") }
        var events: URL { directory.appendingPathComponent("events") }

        init() throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            directory = root.appendingPathComponent("build/r08/fixtures/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func release() { FileManager.default.createFile(atPath: released.path, contents: Data()) }
        func recorded() throws -> [String] {
            try String(contentsOf: events, encoding: .utf8).split(separator: "\n").map(String.init)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func client(_ evidence: HelperEvidence, mode: String = "normal") -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time
        from pathlib import Path
        directory = Path(sys.argv[1])
        mode = sys.argv[2]
        sessions = {}
        sequence = 0
        disconnects = 0
        def record(value):
            with (directory / 'events').open('a') as output:
                output.write(value + '\\n')
        def send(value): print(json.dumps(value), flush=True)
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            record(kind)
            reply = dict(requestId=command['requestId'])
            if kind == 'hello':
                reply.update(type='hello.ack',protocolVersion=\(BackendProtocol.version))
            elif kind == 'connect':
                sequence += 1
                session = 'reopen-'+str(sequence)
                sessions[session] = 'idle'
                reply.update(type='connect.result',sessionId=session,engine='postgresql',
                    capabilities=['execute','cancel','catalog','transactions'],transactionStatus='idle')
            elif kind == 'operation.assess':
                reply.update(type='operation.assessment',sessionId=command['sessionId'],queryId=command['queryId'],
                    assessment=dict(decision='allow',policy=dict(environment='unspecified',readOnly=False),authorization='grant',
                        operations=[dict(kind='read',statements=[]) for operation in command['operations']]))
            elif kind in ['execute','catalog']:
                session = command['sessionId']
                assert session in sessions
                sql = command.get('sql','').strip()
                if sql == 'BEGIN':
                    sessions[session] = 'transaction'
                    record('transaction-open')
                elif sql in ['COMMIT','ROLLBACK']:
                    sessions[session] = 'idle'
                    record('transaction-closed')
                send(dict(type='query.started',requestId=command['requestId'],sessionId=session,queryId=command['queryId']))
                reply.update(type='query.result',sessionId=session,queryId=command['queryId'],transactionStatus=sessions[session],
                    durationMs=1,columns=[],rows=[],commandTag='SELECT 0',rowCount=0,displayedRowCount=0,truncated=False)
            elif kind == 'cancel':
                assert command['sessionId'] in sessions
                reply.update(type='cancel.ack',sessionId=command['sessionId'],queryId=command['queryId'],status='alreadyFinished')
            elif kind == 'disconnect':
                disconnects += 1
                if mode == 'reject-once' and disconnects == 1:
                    reply.update(type='error',sessionId=command['sessionId'],category='busy',message='The session is still active.',
                        connected=True,outcomeUnknown=False,transactionStatus='idle')
                    send(reply)
                    continue
                if mode == 'delay' and disconnects == 1:
                    (directory / 'disconnect-entered').touch()
                    deadline = time.monotonic()+5
                    while not (directory / 'release').exists() and time.monotonic() < deadline: time.sleep(.005)
                    assert (directory / 'release').exists()
                assert sessions[command['sessionId']] == 'idle'
                del sessions[command['sessionId']]
                record('session-closed')
                reply.update(type='disconnect.ack',sessionId=command['sessionId'])
            elif kind == 'shutdown':
                reply.update(type='shutdown.ack')
            else:
                sys.exit(42)
            send(reply)
            if kind == 'shutdown': break
        """, evidence.directory.path, mode])
    }

    private func connectedWorkspace(_ client: BackendClient,
                                    decision: @escaping @MainActor (WorkspaceCloseIssue) async -> WorkspaceCloseDecision = { _ in .rollback }) async throws -> (ApplicationWorkspace, SQLDocument) {
        let settings = ConnectionSettings(host: "127.0.0.1", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable")
        let profile = SavedConnection(name: "Reopen fixture", settings: settings)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id)),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: decision,
            executionDecision: { _ in true }, helperFactory: { client })
        await workspace.start()
        let document = try #require(workspace.documents.first)
        document.profileID = profile.id
        return (workspace, document)
    }

    @Test func transactionSessionClosesBeforeReopenAndOnlyExplicitRunCreatesANewOne() async throws {
        let evidence = try HelperEvidence()
        let client = client(evidence)
        let (workspace, original) = try await connectedWorkspace(client)
        await workspace.run(original, sql: "BEGIN")
        let oldRuntime = try #require(original.runtime)
        let oldSession = try #require(oldRuntime.sessionId)
        try #require(oldRuntime.queryFailure == nil && oldRuntime.result != nil && oldRuntime.queryPhase == .idle)
        try #require(oldRuntime.transactionStatus == .transaction)
        await workspace.closeDocument(original)
        #expect(oldRuntime.sessionId == nil && oldRuntime.transactionStatus == nil)
        #expect(workspace.closedTabs.count == 1)
        let before = try evidence.recorded()
        #expect(before.contains("transaction-closed") && before.contains("session-closed"))
        let reopened = try #require(workspace.reopenClosedTab())
        #expect(reopened.runtime == nil && reopened.id != original.id)
        await workspace.run(original, sql: "SELECT 1")
        try await Task.sleep(for: .milliseconds(20))
        #expect(try evidence.recorded() == before)
        await workspace.run(reopened, sql: "SELECT 1")
        #expect(reopened.runtime !== oldRuntime)
        #expect(reopened.runtime?.sessionId != oldSession && reopened.runtime?.transactionStatus == .idle)
        #expect(oldRuntime.sessionId == nil)
        await workspace.shutdown()
        #expect(await client.waitForExit().status == 0)
    }

    @Test func inFlightDisconnectDoesNotPublishAnUndoEntryOrAllowAnEarlierReopen() async throws {
        let evidence = try HelperEvidence()
        let client = client(evidence, mode: "delay")
        let (workspace, original) = try await connectedWorkspace(client)
        let earlier = workspace.newDocument(text: "SELECT 'earlier';")
        await workspace.closeDocument(earlier)
        await workspace.run(original, sql: "SELECT 1")
        let runtime = try #require(original.runtime)
        try #require(runtime.sessionId != nil && runtime.connectionState == .connected)
        try #require(runtime.queryFailure == nil && runtime.result != nil && runtime.queryPhase == .idle)
        let closing = Task { await workspace.closeDocument(original) }
        defer { evidence.release() }
        try await eventually { FileManager.default.fileExists(atPath: evidence.entered.path) }
        #expect(workspace.closedTabs.count == 1 && workspace.documents.contains { $0 === original })
        #expect(!workspace.canReopenClosedTab && workspace.reopenClosedTab() == nil)
        await workspace.closeDocument(original)
        #expect(workspace.closedTabs.count == 1)
        original.text = "  SELECT 'edited while disconnecting';\r\n"
        original.title = "Edited during disconnect"
        let latest = original.storedState
        evidence.release()
        await closing.value
        #expect(workspace.closedTabs.count == 2 && !workspace.documents.contains { $0 === original })
        let reopened = try #require(workspace.reopenClosedTab())
        expectContext(reopened, matches: latest)
        await workspace.shutdown()
        #expect(await client.waitForExit().status == 0)
    }

    @Test func rejectedDisconnectDoesNotCloseOrRememberTheTabUntilAcknowledgedRetry() async throws {
        let evidence = try HelperEvidence()
        let client = client(evidence, mode: "reject-once")
        let (workspace, original) = try await connectedWorkspace(client)
        await workspace.run(original, sql: "SELECT 1")
        let runtime = try #require(original.runtime)
        let session = try #require(runtime.sessionId)
        try #require(runtime.queryFailure == nil && runtime.result != nil && runtime.queryPhase == .idle)
        await workspace.closeDocument(original)
        #expect(workspace.documents.contains { $0 === original })
        #expect(runtime.sessionId == session && runtime.connectionState == .connected)
        #expect(workspace.closedTabs.isEmpty && workspace.reopenClosedTab() == nil)
        await workspace.closeDocument(original)
        #expect(!workspace.documents.contains { $0 === original } && workspace.closedTabs.count == 1)
        let reopened = try #require(workspace.reopenClosedTab())
        #expect(reopened.runtime == nil && reopened.id != original.id)
        await workspace.shutdown()
        #expect(await client.waitForExit().status == 0)
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(predicate())
    }
}

private actor ClosedTabFailableStore: SQLDocumentStore {
    private var snapshot = SQLWorkspaceSnapshot()
    private var fails = false
    func load() -> SQLWorkspaceSnapshot { snapshot }
    func save(_ snapshot: SQLWorkspaceSnapshot) throws {
        guard !fails else { throw SQLDocumentStoreError.write }
        self.snapshot = snapshot
    }
    func setFailure(_ value: Bool) { fails = value }
}
