import Foundation
import Testing
@testable import DBeer

// These tests use protocol subprocesses and model objects only: no windows,
// application activation, native dialogs, or desktop input.
@MainActor
struct SQLHistoryTests {
    private func client(decision: String = "allow") -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time
        sessions = 0
        pending = None
        def send(r): print(json.dumps(r), flush=True)
        def started(c): send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
        def result(c, **extra):
            r = dict(type='query.result',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'],
                     transactionStatus='idle',durationMs=12.5,columns=[],rows=[],commandTag='SELECT 0',
                     rowCount=0,displayedRowCount=0,truncated=False)
            r.update(extra)
            send(r)
        def failure(c, category='sql', **extra):
            r = dict(type='error',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'],
                     category=category,message='Safe fixture diagnostic.',sqlState='22012',connected=True,
                     transactionStatus='idle',outcomeUnknown=False)
            r.update(extra)
            send(r)
        for line in sys.stdin:
            c = json.loads(line)
            kind = c['type']
            if kind == 'hello': send(dict(type='hello.ack',requestId=c['requestId'],protocolVersion=\(BackendProtocol.version)))
            elif kind == 'connect':
                sessions += 1
                send(dict(type='connect.result',requestId=c['requestId'],sessionId='s'+str(sessions),engine='postgresql',
                          capabilities=['execute','cancel','catalog','transactions'],transactionStatus='idle'))
            elif kind == 'operation.assess':
                send(dict(type='operation.assessment',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'],
                     assessment=dict(decision=sys.argv[1],policy=dict(environment='production',readOnly=False),authorization='grant',
                                     operations=[dict(kind='read',statements=[]) for op in c['operations']])))
            elif kind == 'catalog':
                started(c)
                result(c)
            elif kind == 'execute':
                started(c)
                sql = c['sql'].strip().rstrip(';')
                if sql in ['SELECT WAIT', 'SELECT RACE']: pending = c
                elif sql == 'SELECT FAIL': failure(c)
                elif sql == 'SELECT TIMEOUT': failure(c, 'timeout', sqlState='57014')
                elif sql == 'UPDATE LOST': sys.exit(23)
                elif sql == 'UPDATE REJECTED': failure(c, 'policy', sqlNotExecuted=True)
                elif sql.startswith('UPDATE'):
                    result(c, commandTag='UPDATE 7',rowCount=7)
                else:
                    result(c,columns=[dict(index=0,name='n',typeOid=20)],rows=[['9007199254740993']],
                           displayedRowCount=1,rowCount=1200,truncated=True,commandTag='SELECT 1200')
                    if sql == 'SELECT END': sys.exit(23)
            elif kind == 'cancel':
                race = pending is not None and pending['sql'].strip().rstrip(';') == 'SELECT RACE'
                send(dict(type='cancel.ack',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'],
                          status='alreadyFinished' if pending is None or race else 'accepted'))
                if pending is not None:
                    time.sleep(.05)
                    if race: result(pending)
                    else: failure(pending,'cancelled',sqlState='57014')
                    pending = None
            elif kind == 'disconnect': send(dict(type='disconnect.ack',requestId=c['requestId'],sessionId=c['sessionId']))
            elif kind == 'shutdown':
                send(dict(type='shutdown.ack',requestId=c['requestId']))
                break
            else: sys.exit(40)
        """, decision])
    }

    private func setup(decision: String = "allow", confirm: Bool = true,
                       store: any SQLDocumentStore = MemorySQLDocumentStore()) async throws -> (ApplicationWorkspace, SQLDocument) {
        let backend = client(decision: decision)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store,
            closeDecision: { _ in .rollback }, executionDecision: { _ in confirm }, helperFactory: { backend })
        await workspace.start()
        try #require(await workspace.library.saveConnection(name: "Original production", settings: ConnectionSettings(
            host: "db.example.test", port: 5432, database: "sales", user: "analyst", password: "credential-sentinel",
            sslMode: "disable", policy: ExecutionPolicy(environment: .production))))
        let id = try #require(workspace.library.selectedConnectionId)
        return (workspace, workspace.newDocument(profileID: id, text: "SELECT 1;"))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(condition())
    }

    @Test func scriptRecordsTerminalCommandsOnceWithCountsAndStopsBeforeSkippedSQL() async throws {
        let store = MemorySQLDocumentStore()
        let (workspace, document) = try await setup(store: store)
        document.text = "SELECT 1; UPDATE demo SET n=1; SELECT FAIL; SELECT 999;"
        let before = Date.now
        await workspace.runScript(document)
        let entries = workspace.history
        #expect(entries.map(\.sql) == ["SELECT 1", "UPDATE demo SET n=1", "SELECT FAIL"])
        #expect(entries.map(\.outcome) == [.succeeded, .succeeded, .failed])
        #expect(document.executions.last?.status == "Skipped")
        #expect(Set(entries.map(\.id)).count == 3)
        let selected = try #require(entries.first)
        #expect(selected.documentID == document.id && selected.profileID == document.profileID)
        #expect(selected.startedAt! >= before && selected.finishedAt! >= selected.startedAt!)
        #expect(selected.date == selected.finishedAt)
        #expect(selected.durationMs == 12.5)
        #expect(selected.loadedRowCount == 1 && selected.affectedRowCount == nil)
        #expect(selected.truncated == true && selected.sqlCompleted == true)
        #expect(!selected.executionSummary.contains("1200"))
        #expect(entries[1].loadedRowCount == 0 && entries[1].affectedRowCount == 7)
        #expect(entries[1].truncated == false)
        #expect(entries[2].sqlState == "22012" && entries[2].errorMessage == "The database rejected a value or expression.")
        #expect(entries[2].durationMs! >= 0 && entries[2].loadedRowCount == nil)
        await workspace.flushDocuments()
        #expect(await store.load().history == entries)
        let json = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
        #expect(!json.contains("credential-sentinel") && !json.contains("9007199254740993"))
        await workspace.shutdown()
    }

    @Test(arguments: [false, true])
    func stopWaitsForTerminalAndSuccessfulCompletionCanWinTheRace(successWins: Bool) async throws {
        let (workspace, document) = try await setup()
        document.text = successWins ? "SELECT RACE; SELECT 99;" : "SELECT WAIT; SELECT 99;"
        let run = Task { await workspace.runScript(document) }
        try await waitUntil { document.runtime?.canStop == true }
        #expect(workspace.history.isEmpty)
        await workspace.stop(document)
        #expect(workspace.history.isEmpty) // A cancel acknowledgement is not a terminal outcome.
        await run.value
        #expect(workspace.history.count == 1)
        #expect(workspace.history.first?.outcome == (successWins ? .succeeded : .cancelled))
        #expect(workspace.history.first?.sqlState == (successWins ? nil : "57014"))
        #expect(document.executions.last?.status == "Skipped")
        await workspace.shutdown()
    }

    @Test func timeoutAndLostHelperRemainDistinctAndAreNotReplayed() async throws {
        let (workspace, document) = try await setup()
        await workspace.run(document, sql: "SELECT TIMEOUT")
        #expect(workspace.history.first?.outcome == .timedOut)
        #expect(workspace.history.first?.durationMs != nil)
        await workspace.run(document, sql: "UPDATE LOST")
        #expect(workspace.history.map(\.outcome) == [.timedOut, .unknown])
        #expect(workspace.history.last?.loadedRowCount == nil && workspace.history.last?.affectedRowCount == nil)
        try await Task.sleep(for: .milliseconds(50)) // Failure observers must not append another entry.
        #expect(workspace.history.count == 2)
        await workspace.shutdown()
    }

    @Test func terminalSuccessSurvivesImmediateHelperExit() async throws {
        let (workspace, document) = try await setup()
        await workspace.run(document, sql: "SELECT END")
        try await Task.sleep(for: .milliseconds(50))
        #expect(workspace.history.count == 1)
        #expect(workspace.history.first?.outcome == .succeeded)
        #expect(workspace.history.first?.loadedRowCount == 1)
        await workspace.shutdown()
    }

    @Test func declinedReviewNotExecutedAndDisabledHistoryCreateNoEntries() async throws {
        let (cancelled, document) = try await setup(decision: "confirm", confirm: false)
        await cancelled.run(document)
        #expect(cancelled.history.isEmpty)
        await cancelled.shutdown()
        let (workspace, next) = try await setup()
        await workspace.run(next, sql: "UPDATE REJECTED")
        #expect(workspace.history.isEmpty)
        workspace.historyEnabled = false
        await workspace.run(next)
        #expect(next.runtime?.result != nil && workspace.history.isEmpty)
        await workspace.shutdown()
    }

    @Test func profileSnapshotSurvivesRenameDeletionAndDisconnectedRestore() async throws {
        let store = MemorySQLDocumentStore()
        let (workspace, document) = try await setup(store: store)
        await workspace.run(document)
        let profileID = try #require(document.profileID)
        let original = try #require(workspace.library.savedConnections.first)
        try #require(await workspace.library.saveConnection(name: "Renamed", settings: original.settings(password: ""), id: profileID))
        try #require(await workspace.library.deleteConnection(profileID))
        #expect(workspace.history.first?.profile?.name == "Original production")
        #expect(workspace.history.first?.profile?.database == "sales")
        #expect(workspace.history.first?.profile?.policy.environment == .production)
        let entries = workspace.history
        await workspace.shutdown()
        let restored = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store,
            helperFactory: { self.client(decision: "restore") })
        await restored.start()
        #expect(restored.history == entries)
        #expect(restored.error == nil && restored.services.isEmpty)
        #expect(restored.documents.allSatisfy { $0.runtime == nil })
        await restored.shutdown()
    }

    @Test func inFlightEntryKeepsTheOriginalDocumentProfileBinding() async throws {
        let (workspace, document) = try await setup()
        let originalID = document.profileID
        let run = Task { await workspace.run(document, sql: "SELECT WAIT") }
        try await waitUntil { document.runtime?.canStop == true }
        document.profileID = UUID()
        await workspace.stop(document)
        await run.value
        #expect(workspace.history.count == 1)
        #expect(workspace.history.first?.profileID == originalID)
        #expect(workspace.history.first?.profile?.name == "Original production")
        #expect(workspace.history.first?.outcome == .cancelled)
        await workspace.shutdown()
    }

    @Test func multipleResultsReturningUnknownAffectedCountsAndConfirmedExportFailure() throws {
        let profile = SavedConnection(name: "Fixture", settings: ConnectionSettings(host: "db", port: 5432,
            database: "db", user: "user", password: "secret", sslMode: "disable"))
        var reply = BackendMessage(type: "query.result", requestId: "r", resultSets: [
            QueryResultSet(columns: [ResultColumn(index: 0, name: "n", typeOid: 23)], commandTag: "UPDATE 2",
                rowCount: 2, displayedRowCount: 1, truncated: true),
            QueryResultSet(commandTag: "UPDATE 3", rowCount: 3)
        ])
        func entry(_ reply: BackendMessage, failure: WorkspaceModel.QueryFailure? = nil) throws -> SQLHistoryEntry {
            try #require(SQLHistoryEntry(documentID: UUID(), profileID: profile.id, profile: SQLHistoryProfile(profile),
                sql: "CALL fixture()", completion: WorkspaceModel.QueryCompletion(startedAt: .now, finishedAt: .now,
                    durationMs: 1, reply: reply, failure: failure)))
        }
        let returning = try entry(reply)
        #expect(returning.loadedRowCount == 1 && returning.affectedRowCount == 5 && returning.truncated == true)
        reply.resultSets?[1].affectedRowCountKnown = false
        #expect(try entry(reply).affectedRowCount == nil)
        reply = BackendMessage(type: "error", requestId: "r", resultSets: reply.resultSets, sqlCompleted: true)
        let failedExport = try entry(reply, failure: WorkspaceModel.QueryFailure(category: "export", message: "Export failed.",
            sqlState: nil, outcomeUnknown: false))
        #expect(failedExport.outcome == .failed && failedExport.sqlCompleted == true)
        #expect(failedExport.loadedRowCount == 1 && failedExport.countsArePartial == true)
        var cassandra = profile
        cassandra.engine = .cassandra
        cassandra.contactPoints = ["192.0.2.1", "192.0.2.2"]
        cassandra.localDatacenter = "dc_test"
        cassandra.consistency = "LOCAL_QUORUM"
        let keyspace = SQLHistoryProfile(cassandra, currentKeyspace: "selected_keyspace")
        #expect(keyspace.database == "selected_keyspace")
        #expect(keyspace.contactPoints == cassandra.contactPoints && keyspace.localDatacenter == "dc_test")
        #expect(keyspace.consistency == "LOCAL_QUORUM" && keyspace.sslMode == "disable")
        #expect(keyspace.summary.contains("192.0.2.2") && keyspace.summary.contains("LOCAL_QUORUM"))
        #expect(try JSONDecoder().decode(SQLHistoryProfile.self, from: JSONEncoder().encode(keyspace)) == keyspace)
    }
}
