import Foundation
import Testing
@testable import DBeer

/// Production factory/ownership with a deferred helper reply. No windows or UI.
@Suite(.serialized)
@MainActor
struct GridProfileWorkspaceTests {
    @MainActor private final class Gate {
        let root: URL
        var entered: URL { root.appendingPathComponent("entered") }
        var hold: URL { root.appendingPathComponent("hold") }
        var holdTerminal: URL { root.appendingPathComponent("hold-terminal") }
        var release: URL { root.appendingPathComponent("release") }
        var sampleSessions: URL { root.appendingPathComponent("sample-sessions") }
        var disconnected: URL { root.appendingPathComponent("disconnected") }
        var canceled: URL { root.appendingPathComponent("canceled") }
        var decision: WorkspaceCloseDecision = .rollback
        var holdDecision = false
        var pending: CheckedContinuation<WorkspaceCloseDecision, Never>?
        init() throws {
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            root = repository.appendingPathComponent("build/profiling-workspace/" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        func pauseRead() { _ = FileManager.default.createFile(atPath: hold.path, contents: Data()) }
        func pauseTerminal() { _ = FileManager.default.createFile(atPath: holdTerminal.path, contents: Data()) }
        func releaseRead() { _ = FileManager.default.createFile(atPath: release.path, contents: Data()) }
        func resolve(_ value: WorkspaceCloseDecision) { pending?.resume(returning: value); pending = nil }
        func choose() async -> WorkspaceCloseDecision {
            if !holdDecision { return decision }
            return await withCheckedContinuation { pending = $0 }
        }
        func finished() { releaseRead(); resolve(.cancel) }
        func lines(_ url: URL) -> [String] {
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }
    private func helper(_ gate: Gate) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time, threading
        from pathlib import Path
        root = Path(sys.argv[1])
        sessions, canceled = {}, set()
        output_lock = threading.Lock()
        count = 0
        def send(reply):
            with output_lock: print(json.dumps(reply), flush=True)
        def append(name, value):
            with (root / name).open('a') as output: output.write(value + '\\n')
        def browse(command):
            session, query = command['sessionId'], command['queryId']
            page = command['catalog'].get('page', 0)
            if page == 1 and (root / 'hold').exists():
                (root / 'entered').touch()
                deadline = time.monotonic() + 5
                while not (root / 'release').exists() and time.monotonic() < deadline:
                    if query in canceled and not (root / 'hold-terminal').exists(): break
                    time.sleep(.005)
            rows = [['1']] * 200 if page == 0 else [['2']]
            send(dict(type='query.result',requestId=command['requestId'],sessionId=session,queryId=query,
                transactionStatus='idle',durationMs=1,commandTag='SELECT',rowCount=len(rows),displayedRowCount=len(rows),
                truncated=False,columns=[dict(index=0,name='n',engine='postgresql',typeOid=1700,nativeType='numeric')],rows=rows))
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            reply = dict(requestId=command['requestId'])
            if kind == 'hello': reply.update(type='hello.ack',protocolVersion=6)
            elif kind == 'connect':
                count += 1
                session = 'profile-fixture-' + str(count)
                policy = command['connection'].get('policy',dict(environment='unspecified',readOnly=False))
                sessions[session] = dict(state='idle',policy=policy)
                if policy.get('readOnly'): append('sample-sessions', session)
                reply.update(type='connect.result',engine='postgresql',capabilities=['execute','cancel','transactions','catalog','serverReadOnly'],
                    sessionId=session,transactionStatus='idle')
            elif kind == 'operation.assess':
                reply.update(type='operation.assessment',sessionId=command['sessionId'],queryId=command['queryId'],
                    assessment=dict(decision='allow',policy=sessions[command['sessionId']]['policy'],
                    operations=[dict(kind='read',statements=[]) for item in command['operations']],authorization='fixture-grant'))
            elif kind in ['execute','catalog']:
                session = command['sessionId']
                send(dict(type='query.started',requestId=command['requestId'],sessionId=session,queryId=command['queryId']))
                if kind == 'catalog' and command['catalog']['kind'] == 'browse':
                    threading.Thread(target=browse,args=(command,),daemon=True).start()
                    continue
                names, rows = [], []
                if kind == 'execute':
                    sql = command.get('sql','')
                    if sql == 'BEGIN': sessions[session]['state'] = 'transaction'
                    elif sql in ['COMMIT','ROLLBACK']: sessions[session]['state'] = 'idle'
                elif command['catalog']['kind'] == 'schemas': names, rows = ['name','kind'], [['public','schema']]
                elif command['catalog']['kind'] == 'objects': names = ['name','kind','schema']
                elif command['catalog']['kind'] == 'columns': names = ['name','nativeType']
                reply.update(type='query.result',sessionId=session,queryId=command['queryId'],durationMs=1,
                    transactionStatus=sessions[session]['state'],commandTag='SELECT',rowCount=len(rows),displayedRowCount=len(rows),
                    truncated=False,columns=[dict(index=i,name=n,engine='postgresql',typeOid=25,nativeType='text') for i,n in enumerate(names)],rows=rows)
            elif kind == 'cancel':
                canceled.add(command['queryId'])
                append('canceled',command['sessionId'])
                reply.update(type='cancel.ack',sessionId=command['sessionId'],queryId=command['queryId'],status='accepted')
            elif kind == 'disconnect':
                append('disconnected',command['sessionId'])
                sessions.pop(command['sessionId'],None)
                reply.update(type='disconnect.ack',sessionId=command['sessionId'])
            elif kind == 'shutdown':
                append('shutdown', 'requested')
                reply.update(type='shutdown.ack')
            else: sys.exit(40)
            send(reply)
            if kind == 'shutdown': break
        """, gate.root.path])
    }
    private func fixture(_ gate: Gate) async throws -> (ApplicationWorkspace, SavedConnection, SavedConnection) {
        let client = helper(gate)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(), automaticallyWatchFiles: false,
            closeDecision: { _ in await gate.choose() }, executionDecision: { _ in true }, helperFactory: { client })
        await workspace.start()
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable")
        try #require(await workspace.library.saveConnection(name: "Sample source", settings: settings))
        let sourceID = try #require(workspace.library.selectedConnectionId)
        let source = try #require(workspace.library.savedConnections.first { $0.id == sourceID })
        try #require(await workspace.library.saveConnection(name: "Other source", settings: settings))
        let otherID = try #require(workspace.library.selectedConnectionId)
        let other = try #require(workspace.library.savedConnections.first { $0.id == otherID })
        return (workspace, source, other)
    }
    private func table(_ document: SQLDocument) -> GridDraft {
        document.table = .init(schema: "public", name: "fixture_é", kind: "table")
        let grid = GridDraft(reference: document.table!, result: .init(type: "query.result", requestId: "fixture",
            columns: [.init(index: 0, name: "n", typeOid: 1700, nativeType: "numeric")], rows: [["1"]]),
            metadata: [["name":"n", "nativeType":"numeric", "primaryKey":"1", "editable":"true"]])
        document.attachGrid(grid)
        return grid
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test(arguments: ["unrelatedTab", "sourceTab", "sourceProfile"])
    func pendingCanceledClosePreservesSourceAndCompletedRead(scope: String) async throws {
        let gate = try Gate()
        let (workspace, source, other) = try await fixture(gate)
        do {
            let document = workspace.newDocument(profileID: source.id)
            let transaction = scope == "sourceTab" ? document : workspace.newDocument(profileID: scope == "sourceProfile" ? source.id : other.id)
            await workspace.run(transaction, sql: "BEGIN")
            try #require(transaction.runtime?.transactionStatus == .transaction)
            let grid = table(document)
            let model = try workspace.makeGridProfileServer(document: document, grid: grid, column: grid.columns[0])
            let idle = try workspace.makeGridProfileServer(document: document, grid: grid, column: grid.columns[0])
            gate.pauseRead()
            let capture = Task { await model.capture() }
            try await waitUntil { FileManager.default.fileExists(atPath: gate.entered.path) }
            #expect(model.rowsCaptured == 200)
            gate.holdDecision = true
            let closing = Task { @MainActor in
                if scope == "sourceProfile" { return await workspace.disconnectProfile(source.id) }
                await workspace.closeDocument(scope == "sourceTab" ? document : transaction)
                return !workspace.documents.contains { $0 === (scope == "sourceTab" ? document : transaction) }
            }
            try await waitUntil { gate.pending != nil }
            #expect(!idle.canStartAction)
            await idle.capture()
            #expect(gate.lines(gate.sampleSessions).count == 1)
            #expect(throws: (any Error).self) { try workspace.makeGridProfileServer(document: document, grid: grid, column: grid.columns[0]) }
            gate.releaseRead()
            await capture.value
            #expect(model.report?.rowCount == 201 && model.report?.columns[0].sum == "202")
            #expect(model.report?.scope.partial == false && model.notice == nil && !model.isClosed)
            gate.resolve(.cancel)
            #expect(!(await closing.value))
            #expect(workspace.documents.contains { $0 === document } && document.grid === grid)
            #expect(transaction.runtime?.transactionStatus == .transaction && model.canStartAction && idle.canStartAction)
            gate.holdDecision = false
            await transaction.runtime?.run(sql: "ROLLBACK")
            await workspace.shutdown()
            #expect(workspace.gridProfileServers.isEmpty)
        } catch { gate.finished(); await workspace.shutdown(); throw error }
    }

    @Test(arguments: ["document", "profile", "shutdown"])
    func acceptedRelevantActionClosesHeadlessOwnerOnly(scope: String) async throws {
        let gate = try Gate()
        let (workspace, source, other) = try await fixture(gate)
        do {
            let document = workspace.newDocument(profileID: source.id), grid = table(document)
            let unrelated = workspace.newDocument(profileID: source.id)
            await workspace.run(unrelated, sql: "BEGIN")
            let model = try workspace.makeGridProfileServer(document: document, grid: grid, column: grid.columns[0])
            gate.pauseRead()
            let capture = Task { await model.capture() }
            try await waitUntil { FileManager.default.fileExists(atPath: gate.entered.path) }
            let session = try #require(gate.lines(gate.sampleSessions).first)
            #expect(await workspace.disconnectProfile(other.id))
            await workspace.closeDocument(unrelated)
            #expect(!workspace.documents.contains { $0 === unrelated })
            #expect(!model.isClosed && model.rowsCaptured == 200 && workspace.gridProfileServers[model.id]?.model === model)
            let priorCancels = gate.lines(gate.canceled)
            if scope == "document" { await workspace.closeDocument(document) }
            else if scope == "profile" { #expect(await workspace.disconnectProfile(source.id)) }
            else { await workspace.shutdown() }
            await capture.value
            #expect(model.isClosed && !model.isBusy && model.report == nil && model.rowsCaptured == 200)
            #expect(workspace.gridProfileServers.isEmpty)
            let newCancels = Array(gate.lines(gate.canceled).dropFirst(priorCancels.count))
            #expect(newCancels == [session])
            #expect(gate.lines(gate.disconnected).filter { $0 == session }.count == 1)
            await model.capture()
            #expect(gate.lines(gate.sampleSessions).count == 1)
            await workspace.shutdown()
        } catch { gate.finished(); await workspace.shutdown(); throw error }
    }

    @Test func normalFactoryStopRetainsCompletedPageAndSQLTransaction() async throws {
        let gate = try Gate()
        let (workspace, source, _) = try await fixture(gate)
        do {
            let transaction = workspace.newDocument(profileID: source.id)
            await workspace.run(transaction, sql: "BEGIN")
            let runtimeSession = try #require(transaction.runtime?.sessionId)
            let document = workspace.newDocument(profileID: source.id), grid = table(document)
            let model = try workspace.makeGridProfileServer(document: document, grid: grid, column: grid.columns[0])
            gate.pauseRead()
            let capture = Task { await model.capture() }
            try await waitUntil { FileManager.default.fileExists(atPath: gate.entered.path) }
            let session = try #require(gate.lines(gate.sampleSessions).first)
            let priorCancels = gate.lines(gate.canceled)
            await model.stop(); await capture.value
            #expect(model.report?.rowCount == 200 && model.report?.scope.partial == true && model.report?.columns[0].sum == "200")
            #expect(transaction.runtime?.sessionId == runtimeSession && transaction.runtime?.transactionStatus == .transaction)
            let newCancels = Array(gate.lines(gate.canceled).dropFirst(priorCancels.count))
            #expect(newCancels == [session] && !model.isClosed)
            await model.close()
            #expect(workspace.gridProfileServers.isEmpty && gate.lines(gate.disconnected).filter { $0 == session }.count == 1)
            await workspace.shutdown()
        } catch { gate.finished(); await workspace.shutdown(); throw error }
    }

    @Test(arguments: ["grid", "profile", "runtime", "tableBytes"])
    func permanentSourceChangesRejectLaterPages(scope: String) async throws {
        let gate = try Gate()
        let (workspace, source, other) = try await fixture(gate)
        do {
            let document = workspace.newDocument(profileID: source.id), grid = table(document)
            let model = try workspace.makeGridProfileServer(document: document, grid: grid, column: grid.columns[0])
            gate.pauseRead()
            let capture = Task { await model.capture() }
            try await waitUntil { FileManager.default.fileExists(atPath: gate.entered.path) }
            if scope == "grid" { _ = table(document) }
            else if scope == "profile" { document.profileID = other.id }
            else if scope == "runtime" { document.runtime = WorkspaceModel(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore()) }
            else { document.table = .init(schema: "public", name: "fixture_e\u{301}", kind: "table") }
            gate.releaseRead(); await capture.value
            #expect(model.report?.rowCount == 200 && model.report?.scope.partial == true)
            #expect(model.report?.scope.notice.contains("earlier captured context") == true && !model.canStartAction)
            await workspace.shutdown()
        } catch { gate.finished(); await workspace.shutdown(); throw error }
    }
    @Test func changedSavedProfileClosesHeadlessOwnerWithoutReconnecting() async throws {
        let gate = try Gate()
        let (workspace, source, _) = try await fixture(gate)
        do {
            let document = workspace.newDocument(profileID: source.id), grid = table(document)
            let model = try workspace.makeGridProfileServer(document: document, grid: grid, column: grid.columns[0])
            gate.pauseRead()
            let capture = Task { await model.capture() }
            try await waitUntil { FileManager.default.fileExists(atPath: gate.entered.path) }
            let session = try #require(gate.lines(gate.sampleSessions).first)
            let settings = ConnectionSettings(host: "other.example", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable")
            #expect(await workspace.library.saveConnection(name: "Changed sample source", settings: settings, id: source.id))
            try await waitUntil { model.isClosed && workspace.gridProfileServers.isEmpty }
            await capture.value
            #expect(model.report == nil && gate.lines(gate.canceled) == [session])
            #expect(gate.lines(gate.disconnected).filter { $0 == session }.count == 1 && gate.lines(gate.sampleSessions).count == 1)
            await model.capture()
            #expect(gate.lines(gate.sampleSessions).count == 1)
            await workspace.shutdown()
        } catch { gate.finished(); await workspace.shutdown(); throw error }
    }

    @Test func shutdownFencesNewAndIdleSamplersBeforeAwaitingAnOwnedTerminalReply() async throws {
        let gate = try Gate()
        let (workspace, source, _) = try await fixture(gate)
        do {
            let document = workspace.newDocument(profileID: source.id), grid = table(document)
            let active = try workspace.makeGridProfileServer(document: document, grid: grid, column: grid.columns[0])
            let idle = try workspace.makeGridProfileServer(document: document, grid: grid, column: grid.columns[0])
            gate.pauseRead(); gate.pauseTerminal()
            let capture = Task { await active.capture() }
            try await waitUntil { FileManager.default.fileExists(atPath: gate.entered.path) }
            let session = try #require(gate.lines(gate.sampleSessions).first)
            let shuttingDown = Task { await workspace.shutdown() }
            try await waitUntil { active.isClosed && gate.lines(gate.canceled).contains(session) }
            // The readonly cancel ACK has arrived, but its original catalog
            // request is still pending, before final helper teardown begins.
            #expect(active.isBusy && workspace.gridProfileServers[active.id] != nil)
            #expect(!workspace.canManageWorkspace && !workspace.canStartOperation(document))
            #expect(workspace.canStartOperation(document, forClosing: true))
            var concurrentEntered = false, concurrentFinished = false
            let concurrentShutdown = Task {
                concurrentEntered = true
                await workspace.shutdown()
                concurrentFinished = true
            }
            try await waitUntil { concurrentEntered }
            #expect(!concurrentFinished)
            let binding = try #require(SessionMonitorProfileBinding(source))
            #expect(!workspace.gridProfileBindingIsCurrent(binding))
            #expect(!workspace.databaseSearchBindingIsCurrent(binding) && !workspace.schemaBundleBindingIsCurrent(binding))
            #expect(!workspace.relationshipServiceContextIsAvailable)
            #expect(throws: (any Error).self) {
                try workspace.makeGridProfileServer(document: document, grid: grid, column: grid.columns[0])
            }
            await idle.capture()
            #expect(!idle.canStartAction && gate.lines(gate.sampleSessions).count == 1)
            gate.releaseRead()
            await capture.value; await shuttingDown.value; await concurrentShutdown.value
            #expect(concurrentFinished)
            #expect(workspace.gridProfileServers.isEmpty && active.isClosed && idle.isClosed)
            #expect(gate.lines(gate.disconnected).filter { $0 == session }.count == 1)
            #expect(throws: (any Error).self) {
                try workspace.makeGridProfileServer(document: document, grid: grid, column: grid.columns[0])
            }
            await idle.capture()
            #expect(gate.lines(gate.sampleSessions).count == 1)
            await workspace.shutdown()
            #expect(gate.lines(gate.root.appendingPathComponent("shutdown")) == ["requested"])
        } catch { gate.finished(); await workspace.shutdown(); throw error }
    }

}
