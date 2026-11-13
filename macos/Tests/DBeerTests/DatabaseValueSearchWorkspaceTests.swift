import Foundation
import Testing
@testable import DBeer

/// Exercises production workspace ownership and close decisions without native windows.
@Suite(.serialized)
@MainActor
struct DatabaseValueSearchWorkspaceTests {
    @MainActor private final class Gate {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-search-close-" + UUID().uuidString, isDirectory: true)
        var hold: URL { root.appendingPathComponent("hold") }
        var entered: URL { root.appendingPathComponent("entered") }
        var release: URL { root.appendingPathComponent("release") }
        var searchSession: URL { root.appendingPathComponent("search-session") }
        var disconnected: URL { root.appendingPathComponent("disconnected") }
        var decision: WorkspaceCloseDecision = .cancel
        var holdDecision = false
        var pending: CheckedContinuation<WorkspaceCloseDecision, Never>?

        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        func pauseRead() { _ = FileManager.default.createFile(atPath: hold.path, contents: Data()) }
        func releaseRead() { _ = FileManager.default.createFile(atPath: release.path, contents: Data()) }
        func resolve(_ value: WorkspaceCloseDecision) { pending?.resume(returning: value); pending = nil }
        func choose() async -> WorkspaceCloseDecision {
            if !holdDecision { return decision }
            return await withCheckedContinuation { pending = $0 }
        }
        func finished() { releaseRead(); resolve(.cancel) }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private func helper(_ gate: Gate) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time
        from pathlib import Path
        root = Path(sys.argv[1])
        sessions = {}
        count = 0
        def send(reply):
            print(json.dumps(reply), flush=True)
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            reply = {'requestId':command['requestId']}
            if kind == 'hello':
                reply.update(type='hello.ack', protocolVersion=6)
            elif kind == 'connect':
                count += 1
                session = 'search-fixture-' + str(count)
                policy = command['connection'].get('policy', {'environment':'unspecified','readOnly':False})
                sessions[session] = dict(state='idle',policy=policy)
                if policy.get('readOnly'):
                    (root / 'search-session').write_text(session)
                reply.update(type='connect.result', engine='postgresql', capabilities=['execute','cancel','transactions','catalog','serverReadOnly'],
                    sessionId=session, transactionStatus='idle')
            elif kind == 'operation.assess':
                reply.update(type='operation.assessment', sessionId=command['sessionId'],queryId=command['queryId'],
                    assessment={'decision':'allow','policy':sessions[command['sessionId']]['policy'],
                    'operations':[{'kind':'read','statements':[]} for item in command['operations']], 'authorization':'test-grant'})
            elif kind in ['execute','catalog']:
                session = command['sessionId']
                send(dict(type='query.started',requestId=command['requestId'],sessionId=session,queryId=command['queryId']))
                names, rows = [], []
                if kind == 'execute':
                    sql = command.get('sql','')
                    if sql == 'BEGIN': sessions[session]['state'] = 'transaction'
                    elif sql in ['COMMIT','ROLLBACK']: sessions[session]['state'] = 'idle'
                else:
                    selector = command['catalog']
                    branch = selector['kind']
                    if branch == 'schemas': names,rows = ['name','kind'],[['public','schema']]
                    elif branch == 'objects':
                        names = ['name','kind','schema']
                        if selector.get('objectKind') == 'table': rows = [['fixture','table','public']]
                    elif branch == 'columns':
                        names,rows = ['name','nativeType'],[['label','text']]
                    elif branch == 'browse':
                        if (root / 'hold').exists():
                            (root / 'entered').touch()
                            deadline = time.monotonic() + 5
                            while not (root / 'release').exists() and time.monotonic() < deadline: time.sleep(.005)
                        names,rows = ['label'],[['needle']]
                columns = [dict(index=i,name=name,engine='postgresql',nativeType='text',typeOid=25) for i,name in enumerate(names)]
                reply.update(type='query.result',sessionId=session,queryId=command['queryId'],durationMs=1,
                    transactionStatus=sessions[session]['state'],columns=columns,rows=rows,commandTag='SELECT',
                    rowCount=len(rows),displayedRowCount=len(rows),truncated=False,connected=True)
            elif kind == 'cancel':
                reply.update(type='cancel.ack',sessionId=command['sessionId'],queryId=command['queryId'],status='alreadyFinished')
            elif kind == 'disconnect':
                with (root / 'disconnected').open('a') as output: output.write(command['sessionId'] + '\\n')
                sessions.pop(command['sessionId'],None)
                reply.update(type='disconnect.ack',sessionId=command['sessionId'])
            elif kind == 'shutdown': reply.update(type='shutdown.ack')
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
        try #require(await workspace.library.saveConnection(name: "Search source", settings: settings))
        let sourceID = try #require(workspace.library.selectedConnectionId)
        let source = try #require(workspace.library.savedConnections.first { $0.id == sourceID })
        try #require(await workspace.library.saveConnection(name: "Other source", settings: settings))
        let otherID = try #require(workspace.library.selectedConnectionId)
        let other = try #require(workspace.library.savedConnections.first { $0.id == otherID })
        return (workspace, source, other)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    private func loadedModel(_ workspace: ApplicationWorkspace, profile: SavedConnection) async throws -> DatabaseValueSearchModel {
        let model = try #require(workspace.makeDatabaseValueSearch(profile))
        await model.loadTables()
        try #require(model.error == nil && model.objects.count == 1)
        model.selectedTables = Set(model.objects.map(\.id)); model.query.text = "needle"
        return model
    }

    @Test(arguments: [false, true])
    func pendingCloseDecisionDoesNotInvalidateAnOwnedSearch(sourceProfile: Bool) async throws {
        let gate = try Gate()
        let (workspace, source, other) = try await fixture(gate)
        do {
            let document = workspace.newDocument(profileID: sourceProfile ? source.id : other.id)
            await workspace.run(document, sql: "BEGIN")
            try #require(document.runtime?.transactionStatus == .transaction)
            let model = try await loadedModel(workspace, profile: source)
            gate.pauseRead()
            let searching = Task { await model.search() }
            try await waitUntil { FileManager.default.fileExists(atPath: gate.entered.path) }
            gate.holdDecision = true
            let closing = Task { @MainActor in
                if sourceProfile { return await workspace.disconnectProfile(source.id) }
                await workspace.closeDocument(document)
                return false
            }
            try await waitUntil { gate.pending != nil }
            #expect(!workspace.canManageWorkspace && !model.canStartAction)
            gate.releaseRead()
            await searching.value
            let hasMatches = model.observations.contains { $0.hasMatches }
            #expect(hasMatches)
            #expect(model.error == nil && workspace.databaseSearchModel === model)
            gate.resolve(.cancel)
            #expect(!(await closing.value))
            #expect(workspace.documents.contains { $0 === document })
            #expect(document.runtime?.transactionStatus == .transaction)
            #expect(model.canSearch)
            gate.holdDecision = false
            await workspace.run(document, sql: "ROLLBACK")
            await workspace.closeDatabaseValueSearch()
            await workspace.shutdown()
        } catch {
            gate.finished(); await workspace.shutdown(); throw error
        }
    }

    @Test func acceptedProfileDisconnectClosesOnlyItsOwnedSearch() async throws {
        let gate = try Gate()
        let (workspace, source, other) = try await fixture(gate)
        do {
            let document = workspace.newDocument(profileID: source.id)
            await workspace.run(document, sql: "BEGIN")
            let model = try await loadedModel(workspace, profile: source)
            await model.search()
            let session = try String(contentsOf: gate.searchSession, encoding: .utf8)
            #expect(await workspace.disconnectProfile(other.id))
            #expect(workspace.databaseSearchModel === model && !model.isClosing && model.canSearch)
            #expect(!(await workspace.disconnectProfile(source.id)))
            #expect(workspace.databaseSearchModel === model && !model.isClosing)
            gate.decision = .rollback
            #expect(await workspace.disconnectProfile(source.id))
            #expect(workspace.databaseSearchModel == nil && model.isClosing && !model.canSearch)
            let closed = try String(contentsOf: gate.disconnected, encoding: .utf8).split(separator: "\n").map(String.init)
            let sessionDisconnects = closed.filter { $0 == session }
            #expect(sessionDisconnects.count == 1)
            await model.search()
            #expect(workspace.databaseSearchModel == nil)
            await workspace.shutdown()
        } catch { gate.finished(); await workspace.shutdown(); throw error }
    }
}
