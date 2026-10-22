import Foundation
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct GridLifecycleTests {
    private final class Gate {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var entered: URL { directory.appendingPathComponent("entered") }
        var release: URL { directory.appendingPathComponent("release") }
        var changes: URL { directory.appendingPathComponent("changes") }
        var connections: URL { directory.appendingPathComponent("connections") }
        var previewQuery: URL { directory.appendingPathComponent("preview-query") }
        var cancelledQuery: URL { directory.appendingPathComponent("cancelled-query") }
        var confirmations = 0
        init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        func open() { FileManager.default.createFile(atPath: release.path, contents: Data()) }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func helper(_ gate: Gate, delay: String) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time
        from pathlib import Path
        directory = Path(sys.argv[1])
        delay = sys.argv[2]
        connections = 0
        columns_calls = 0
        def wait():
            (directory / 'entered').touch()
            deadline = time.monotonic() + 5
            while not (directory / 'release').exists() and time.monotonic() < deadline:
                time.sleep(.005)
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            reply = {'requestId': command['requestId']}
            if kind == 'hello':
                reply.update(type='hello.ack', protocolVersion=5)
            elif kind == 'operation.assess':
                reply.update(type='operation.assessment', sessionId=command['sessionId'], queryId=command['queryId'],
                             assessment={'decision':'confirm' if delay == 'apply-preview' else 'allow','policy':{'environment':'unspecified','readOnly':False},
                             'operations':[{'kind':'read','statements':[]} for op in command['operations']], 'authorization':'test-grant'})
            elif kind == 'connect':
                connections += 1
                with (directory / 'connections').open('a') as recorded:
                    recorded.write('connect\\n')
                if delay == 'apply-connect' and connections == 3:
                    wait()
                reply.update(type='connect.result', engine='postgresql', capabilities=['execute','cancel','transactions','catalog','gridEditing'],
                             sessionId='session-' + str(connections), transactionStatus='idle')
            elif kind in ['execute', 'catalog', 'changes.preview', 'changes.apply']:
                session = command['sessionId']
                print(json.dumps({'type':'query.started', 'requestId':command['requestId'],
                    'sessionId':session, 'queryId':command['queryId']}), flush=True)
                if delay == 'browse' and kind == 'catalog' and command['catalog']['kind'] == 'browse':
                    wait()
                if kind.startswith('changes.'):
                    with (directory / 'changes').open('a') as recorded:
                        recorded.write(kind + '\\n')
                if kind == 'changes.preview' and delay == 'apply-preview':
                    (directory / 'preview-query').write_text(command['queryId'])
                    wait()
                columns = [{'index':0,'name':'id','engine':'postgresql','nativeType':'int8' if delay == 'metadata' and columns_calls > 1 else 'int4'},
                           {'index':1,'name':'label','engine':'postgresql','nativeType':'text'}]
                rows = [['1','original']]
                if kind == 'catalog' and command['catalog']['kind'] == 'columns':
                    columns_calls += 1
                    if delay == 'metadata-error' and columns_calls > 1:
                        reply.update(type='error', sessionId=session, queryId=command['queryId'], category='sql',
                                     message='Catalog access was denied.', sqlState='42501', connected=True,
                                     outcomeUnknown=False, transactionStatus='idle')
                        print(json.dumps(reply), flush=True)
                        continue
                    names = ['name','nativeType','nullable','default','generated','primaryKey','editable','editReason']
                    columns = [{'index':i,'name':name,'engine':'postgresql','nativeType':'text'} for i,name in enumerate(names)]
                    changed = delay == 'metadata' and columns_calls > 1
                    rows = [['id', 'bigint' if changed else 'integer', 'false', None, '', '1', 'true', ''],
                            ['label', 'text', 'true', None, 'upper(id::text)' if changed else '', '0',
                             'false' if changed else 'true', 'The server generates this value.' if changed else '']]
                reply.update(type='query.result', sessionId=session, queryId=command['queryId'], durationMs=1,
                             transactionStatus='idle', columns=columns, rows=rows, commandTag='SELECT ' + str(len(rows)),
                             rowCount=len(rows), displayedRowCount=len(rows), truncated=False)
            elif kind == 'cancel':
                if delay == 'apply-preview':
                    (directory / 'cancelled-query').write_text(command['queryId'])
                reply.update(type='cancel.ack', sessionId=command['sessionId'], queryId=command['queryId'], status='accepted')
            elif kind == 'disconnect':
                if delay == 'disconnect':
                    wait()
                reply.update(type='disconnect.ack', sessionId=command['sessionId'])
            elif kind == 'shutdown':
                reply.update(type='shutdown.ack')
            else:
                sys.exit(40)
            print(json.dumps(reply), flush=True)
            if kind == 'shutdown':
                break
        """, gate.directory.path, delay])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    private func workspace(_ gate: Gate, delay: String,
                           close: @escaping @MainActor (WorkspaceCloseIssue) async -> WorkspaceCloseDecision = { _ in .discard }) async throws -> (ApplicationWorkspace, SQLDocument) {
        let client = helper(gate, delay: delay)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: close,
            executionDecision: { _ in gate.confirmations += 1; return true }, helperFactory: { client })
        await workspace.start()
        try #require(await workspace.library.saveConnection(name: "Lifecycle fixture",
            settings: ConnectionSettings(host: "localhost", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable")))
        let profile = try #require(workspace.library.selectedConnectionId)
        let document = workspace.newDocument(profileID: profile)
        document.table = TableReference(schema: "public", name: "fixture", kind: "table")
        document.tableColumns = [
            ["name":"id", "nativeType":"integer", "primaryKey":"1", "editable":"true", "generated":""],
            ["name":"label", "nativeType":"text", "primaryKey":"0", "editable":"true", "generated":""]
        ]
        let result = BackendMessage(type: "query.result", requestId: "fixture", columns: [
            ResultColumn(index: 0, name: "id", nativeType: "int4"), ResultColumn(index: 1, name: "label", nativeType: "text")
        ], rows: [["1", "original"]])
        document.attachGrid(GridDraft(reference: document.table!, result: result, metadata: document.tableColumns))
        return (workspace, document)
    }

    @Test func delayedBrowseLocksTheOldSnapshotUntilReplacement() async throws {
        let gate = try Gate()
        let (workspace, document) = try await workspace(gate, delay: "browse")
        defer { gate.open(); Task { await workspace.shutdown() } }
        let grid = try #require(document.grid)
        let browse = Task { await workspace.run(document) }
        try await waitUntil { FileManager.default.fileExists(atPath: gate.entered.path) }
        #expect(document.isRunning && grid.isReloading && !grid.canEdit)
        grid.set(ChangeValue(kind: "text", value: "must not be lost"), row: 0, column: 1)
        grid.insert()
        grid.selectedRows = IndexSet(integer: 0)
        grid.deleteSelected()
        #expect(grid.pendingCount == 0)
        #expect(grid.rows.count == 1 && grid.rows[0].values[1].value == "original")
        gate.open()
        await browse.value
        #expect(document.grid !== grid)
        #expect(!grid.isReloading && document.grid?.canEdit == true)
        let fresh = try #require(document.grid)
        fresh.set(ChangeValue(kind: "text", value: "pending"), row: 0, column: 1)
        document.isRunning = true
        #expect(!(await workspace.applyGrid(document)))
        await workspace.previewGrid(document)
        #expect(fresh.preview == nil && fresh.error == nil && fresh.pendingCount == 1)
        document.isRunning = false
        #expect(!FileManager.default.fileExists(atPath: gate.changes.path))
        await workspace.shutdown()
    }

    @Test func refreshReplacesExactNativeTypesAndGeneratedFlagsWithCurrentMetadata() async throws {
        let gate = try Gate()
        let (workspace, document) = try await workspace(gate, delay: "metadata")
        defer { Task { await workspace.shutdown() } }
        await workspace.run(document)
        let first = try #require(document.grid)
        #expect(first.request().columns[0].nativeType == "integer")
        #expect(first.editableColumns.contains(1))
        await workspace.run(document)
        let refreshed = try #require(document.grid)
        #expect(refreshed !== first)
        #expect(refreshed.request().columns[0].nativeType == "bigint")
        #expect(refreshed.columns[0].nativeType == "int8")
        #expect(!refreshed.editableColumns.contains(1))
        #expect(document.tableColumns[1]["generated"] == "upper(id::text)")
        refreshed.set(.null, row: 0, column: 1)
        #expect(refreshed.pendingCount == 0)
        await workspace.shutdown()
    }

    @Test func failedMetadataRefreshKeepsThePreviousSnapshotAndShowsTheError() async throws {
        let gate = try Gate()
        let (workspace, document) = try await workspace(gate, delay: "metadata-error")
        defer { Task { await workspace.shutdown() } }
        await workspace.run(document)
        let grid = try #require(document.grid)
        let metadata = document.tableColumns
        await workspace.run(document)
        #expect(document.grid === grid)
        #expect(document.tableColumns == metadata)
        #expect(document.localError?.contains("Catalog access was denied.") == true)
        #expect(!document.isRunning && !grid.isReloading)
        await workspace.shutdown()
    }

    @Test func documentCloseKeepsTheSnapshotLockedUntilDisconnectAcknowledgement() async throws {
        let gate = try Gate()
        let (workspace, document) = try await workspace(gate, delay: "disconnect")
        defer { gate.open(); Task { await workspace.shutdown() } }
        await workspace.run(document)
        let grid = try #require(document.grid)
        let profile = try #require(document.profileID)
        let closing = Task { await workspace.closeDocument(document) }
        try await waitUntil { FileManager.default.fileExists(atPath: gate.entered.path) }
        #expect(!workspace.isClosing && grid.isClosing && !grid.canEdit)
        #expect(!workspace.canStartOperation(document))
        #expect(!(await workspace.disconnectProfile(profile)))
        await workspace.clearRestoredDocuments()
        #expect(grid.isClosing && workspace.documents.contains { $0.id == document.id })
        grid.set(.null, row: 0, column: 1)
        grid.insert()
        #expect(grid.pendingCount == 0)
        await workspace.run(document)
        #expect(!document.isRunning)
        gate.open()
        await closing.value
        #expect(!workspace.documents.contains { $0.id == document.id })
        await workspace.shutdown()
    }

    @Test func profileDisconnectRejectsNewOperationsUntilAllSessionsAreClosed() async throws {
        let gate = try Gate()
        let (workspace, document) = try await workspace(gate, delay: "disconnect")
        defer { gate.open(); Task { await workspace.shutdown() } }
        await workspace.run(document)
        let grid = try #require(document.grid)
        let profile = try #require(document.profileID)
        let disconnecting = Task { await workspace.disconnectProfile(profile) }
        try await waitUntil { FileManager.default.fileExists(atPath: gate.entered.path) }
        #expect(!workspace.isClosing && grid.isClosing && !workspace.canStartOperation(document))
        await workspace.closeDocument(document)
        await workspace.clearRestoredDocuments()
        #expect(!(await workspace.disconnectProfile(profile)))
        #expect(grid.isClosing && workspace.documents.contains { $0.id == document.id })
        grid.set(.null, row: 0, column: 1)
        #expect(grid.pendingCount == 0)
        await workspace.run(document)
        #expect(!document.isRunning)
        gate.open()
        #expect(await disconnecting.value)
        #expect(document.runtime == nil && document.grid == nil && workspace.services[profile] == nil)
        await workspace.shutdown()
    }

    @Test func changedProfileEndpointCannotApplyAnOldTablesSnapshotToANewServer() async throws {
        let gate = try Gate()
        let (workspace, document) = try await workspace(gate, delay: "none")
        defer { Task { await workspace.shutdown() } }
        await workspace.run(document)
        let grid = try #require(document.grid)
        let profileID = try #require(document.profileID)
        let original = try #require(workspace.library.savedConnections.first { $0.id == profileID }).settings(password: "")
        let connectionLog = try Data(contentsOf: gate.connections)
        grid.set(.null, row: 0, column: 1)
        for field in 0..<8 {
            var target = original
            switch field {
            case 0: target.host = "another-server.example"
            case 1: target.port += 1
            case 2: target.database = "another_database"
            case 3: target.user = "another_user"
            case 4: target.engine = .mysql
            case 5: target.sslMode = "require"
            case 6: target.sslRootCert = "/tmp/another-ca.pem"
            default: target.host = "another-server.example"; target.database = "another_database"
            }
            try #require(await workspace.library.saveConnection(name: "Changed endpoint", settings: target, id: profileID))
            #expect(!(await workspace.applyGrid(document)))
            #expect(grid.error?.contains("Reconnect") == true)
            #expect(document.grid === grid && grid.pendingCount == 1 && !grid.outcomeUnknown)
            await workspace.previewGrid(document)
            #expect(grid.preview == nil)
            #expect(try Data(contentsOf: gate.connections) == connectionLog)
            #expect(!FileManager.default.fileExists(atPath: gate.changes.path))
        }
        await workspace.shutdown()
    }

    @Test func profileChangeWhileApplyConnectsIsRecheckedBeforeSubmittingChanges() async throws {
        let gate = try Gate()
        let (workspace, document) = try await workspace(gate, delay: "apply-connect")
        defer { gate.open(); Task { await workspace.shutdown() } }
        await workspace.run(document)
        let grid = try #require(document.grid)
        grid.set(.null, row: 0, column: 1)
        let applying = Task { await workspace.applyGrid(document) }
        try await waitUntil { FileManager.default.fileExists(atPath: gate.entered.path) }
        let profileID = try #require(document.profileID)
        var target = try #require(workspace.library.savedConnections.first { $0.id == profileID }).settings(password: "")
        target.host = "another-server.example"
        try #require(await workspace.library.saveConnection(name: "Changed during connection", settings: target, id: profileID))
        gate.open()
        #expect(!(await applying.value))
        #expect(grid.error?.contains("Reconnect") == true)
        #expect(document.grid === grid && grid.pendingCount == 1 && !grid.outcomeUnknown)
        #expect(!FileManager.default.fileExists(atPath: gate.changes.path))
        await workspace.shutdown()
    }

    @Test func stopWhileApplyConnectsNeverSubmitsTheChangesAfterConnectionReturns() async throws {
        let gate = try Gate()
        var sawStop = false
        let (workspace, document) = try await workspace(gate, delay: "apply-connect", close: { issue in
            if case .runningQuery = issue { sawStop = true; return .stop }
            return .cancel
        })
        defer { gate.open(); Task { await workspace.shutdown() } }
        await workspace.run(document)
        let grid = try #require(document.grid)
        grid.set(.null, row: 0, column: 1)
        let applying = Task { await workspace.applyGrid(document) }
        try await waitUntil { FileManager.default.fileExists(atPath: gate.entered.path) }
        let closing = Task { await workspace.closeDocument(document) }
        try await waitUntil { sawStop && grid.cancelRequested }
        gate.open()
        #expect(!(await applying.value))
        await closing.value
        #expect(workspace.documents.contains { $0.id == document.id })
        #expect(document.grid === grid && grid.pendingCount == 1 && !grid.outcomeUnknown && grid.canEdit)
        #expect(!FileManager.default.fileExists(atPath: gate.changes.path))
        await workspace.shutdown()
        do {
            _ = try await workspace.ensureHelper()
            Issue.record("A shut down workspace reopened its helper.")
        } catch {}
    }

    @Test func stopDuringApplyPreviewCancelsItsActualQueryAndNeverConfirmsOrApplies() async throws {
        let gate = try Gate()
        let (workspace, document) = try await workspace(gate, delay: "apply-preview")
        defer { gate.open(); Task { await workspace.shutdown() } }
        await workspace.run(document)
        let grid = try #require(document.grid)
        grid.set(.null, row: 0, column: 1)
        let applying = Task { await workspace.applyGrid(document) }
        try await waitUntil { FileManager.default.fileExists(atPath: gate.entered.path) }
        let previewID = try String(contentsOf: gate.previewQuery, encoding: .utf8)
        #expect(grid.isApplying && grid.applyQueryID == previewID)
        let stopping = Task { await workspace.stopGridApply(document) }
        try await waitUntil { grid.cancelRequested }
        gate.open()
        await stopping.value
        #expect(!(await applying.value))
        #expect(try String(contentsOf: gate.cancelledQuery, encoding: .utf8) == previewID)
        #expect(try String(contentsOf: gate.changes, encoding: .utf8) == "changes.preview\n")
        #expect(gate.confirmations == 0)
        #expect(document.grid === grid && grid.pendingCount == 1 && !grid.outcomeUnknown && grid.canEdit)
        #expect(grid.error?.contains("cancelled") == true)
        await workspace.shutdown()
    }
}
