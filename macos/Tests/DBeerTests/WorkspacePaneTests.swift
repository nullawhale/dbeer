import Foundation
import Testing
@testable import DBeer

/// Pure workspace models and a framed helper subprocess. No windows, native
/// views, clipboard access, application activation or desktop input.
@Suite(.serialized)
@MainActor
struct WorkspacePaneTests {
    private func workspace(store: any SQLDocumentStore = MemorySQLDocumentStore()) async -> ApplicationWorkspace {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store,
            automaticallyWatchFiles: false, closeDecision: { _ in .discard })
        await workspace.restoreSavedWorkspace()
        return workspace
    }

    @Test func eachPaneRetainsItsSelectionAndTheActiveProjectionDoesNotFallBack() async {
        let workspace = await workspace()
        let first = workspace.newDocument(text: "SELECT 'left first'", in: .left)
        let second = workspace.newDocument(text: "SELECT 'left second'", in: .left)
        workspace.activatePane(.right)
        #expect(workspace.selectedDocument == nil && workspace.selectedDocumentID == nil)
        #expect(workspace.selectedDocument(in: .left) === second)
        let third = workspace.newDocument(text: "SELECT 'right first'")
        let fourth = workspace.newDocument(text: "SELECT 'right second'")
        workspace.selectDocument(first.id, in: .left)
        #expect(workspace.selectedDocument === first && workspace.activePaneID == .left)
        #expect(workspace.selectedDocument(in: .right) === fourth)
        #expect(workspace.isSelectedVisibleDocument(first.id) && workspace.isSelectedVisibleDocument(fourth.id))
        #expect(!workspace.isSelectedVisibleDocument(second.id) && !workspace.isSelectedVisibleDocument(third.id))
        workspace.selectedDocumentID = third.id
        #expect(workspace.activePaneID == .right && workspace.selectedDocument === third)
        #expect(workspace.selectedDocument(in: .left) === first)
        workspace.selectDocument(first.id, in: .right)
        workspace.selectedDocumentID = UUID()
        #expect(workspace.selectedDocument === third)
        #expect(workspace.paneLayout.isValid(documentIDs: workspace.documents.map(\.id)))
        await workspace.shutdown()
    }

    @Test func movingAndReorderingRepairOnlyTheSourceAndClosingReopensAtThePanePosition() async throws {
        let workspace = await workspace()
        let left = (0..<3).map { workspace.newDocument(text: "SELECT \($0)", in: .left) }
        let right = (3..<5).map { workspace.newDocument(text: "SELECT \($0)", in: .right) }
        workspace.selectDocument(left[1].id, in: .left)
        workspace.moveDocument(left[1].id, to: .right, at: 1)
        #expect(workspace.documents(in: .left).map(\.id) == [left[0].id, left[2].id])
        #expect(workspace.selectedDocument(in: .left) === left[2])
        #expect(workspace.documents(in: .right).map(\.id) == [right[0].id, left[1].id, right[1].id])
        #expect(workspace.selectedDocument === left[1] && workspace.activePaneID == .right)
        workspace.moveDocument(right[1].id, to: .right, at: 0)
        #expect(workspace.documents(in: .right).map(\.id) == [right[1].id, right[0].id, left[1].id])
        await workspace.closeDocument(right[0])
        #expect(workspace.selectedDocument(in: .right) === right[1])
        #expect(workspace.closedTabs.last?.paneID == .right && workspace.closedTabs.last?.originalPaneIndex == 1)
        workspace.activatePane(.left)
        let reopened = try #require(workspace.reopenClosedTab())
        #expect(reopened.id != right[0].id && reopened.text == right[0].text)
        #expect(reopened.runtime == nil && reopened.grid == nil)
        #expect(workspace.documents(in: .right).map(\.id) == [right[1].id, reopened.id, left[1].id])
        #expect(workspace.selectedDocument(in: .left) === left[2])
        #expect(workspace.selectedDocument === reopened && workspace.activePaneID == .right)
        await workspace.closeDocument(left[1])
        #expect(workspace.selectedDocument === reopened)
        await workspace.closeDocument(reopened)
        #expect(workspace.selectedDocument === right[1])
        await workspace.closeDocument(right[1])
        #expect(workspace.selectedDocument == nil && workspace.selectedDocumentID == nil)
        #expect(workspace.selectedDocument(in: .left) === left[2])
        #expect(workspace.paneLayout.isValid(documentIDs: workspace.documents.map(\.id)))
        await workspace.shutdown()
    }

    @Test func movesPreserveTheExactDocumentRuntimeDraftCursorAndEditorStateObjects() async throws {
        let workspace = await workspace()
        let document = workspace.newDocument(text: "Table data", in: .left)
        let reference = TableReference(schema: "fixture", name: "items", kind: "table")
        document.table = reference
        document.tableFilters = [CatalogFilter(column: "id", operator: "gte", value: "1")]
        document.tableSort = [CatalogSort(column: "id", direction: "desc")]
        let runtime = WorkspaceModel(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        document.attach(runtime)
        document.page = 9
        document.tableCursor = "session-bound-cursor"
        document.tableNextCursor = "session-bound-next"
        document.selection = NSRange(location: 2, length: 4)
        document.executions = [SQLExecution(sql: "SELECT 1", range: NSRange(location: 0, length: 8))]
        let grid = GridDraft(reference: reference,
            result: BackendMessage(type: "query.result", requestId: "fixture",
                columns: [ResultColumn(index: 0, name: "id", nativeType: "int4")], rows: [["1"]]),
            metadata: [["name": "id", "primaryKey": "1", "editable": "true"]])
        document.attachGrid(grid)
        grid.set(ChangeValue(kind: "text", value: "9007199254740993"), row: 0, column: 0)
        grid.outcomeUnknown = true
        grid.isApplying = true
        document.isRunning = true
        let state = document.storedState
        let executionID = try #require(document.executions.first?.id)
        let editorState = workspace.editorState
        for index in 0..<8 {
            workspace.moveDocument(document.id, to: index.isMultiple(of: 2) ? .right : .left)
            #expect(workspace.selectedDocument === document && document.runtime === runtime && document.grid === grid)
            #expect(workspace.editorState === editorState && document.storedState == state)
            #expect(document.tableCursor == "session-bound-cursor" && document.tableNextCursor == "session-bound-next")
            #expect(document.executions.first?.id == executionID && document.selection == NSRange(location: 2, length: 4))
            #expect(grid.pendingCount == 1 && grid.outcomeUnknown && grid.isApplying && document.isRunning)
        }
        grid.isApplying = false
        document.isRunning = false
        await workspace.shutdown()
    }

    @Test func autosaveFiltersBothProvisionalPaneReferencesAndPreservesTheSplit() async throws {
        let store = MemorySQLDocumentStore()
        let workspace = await workspace(store: store)
        let left = workspace.newDocument(text: "SELECT 'left'", in: .left)
        let right = workspace.newDocument(text: "SELECT 'right'", in: .right)
        let provisional = workspace.newDocument(text: "Table data", in: .left)
        provisional.isProvisionalTableView = true
        provisional.provisionalPreviousSelection = left.id
        workspace.setSplitFraction(0.62)
        await workspace.flushDocuments()
        var saved = await store.load()
        #expect(saved.documents.map(\.id) == [left.id, right.id])
        #expect(saved.paneLayout.left == WorkspacePaneState(documentIDs: [left.id], selectedDocumentID: left.id))
        #expect(saved.paneLayout.right == WorkspacePaneState(documentIDs: [right.id], selectedDocumentID: right.id))
        #expect(saved.selectedDocumentID == left.id && saved.paneLayout.splitFraction == 0.62)
        workspace.moveDocument(provisional.id, to: .right)
        await workspace.flushDocuments()
        saved = await store.load()
        #expect(saved.paneLayout.right.documentIDs == [right.id] && saved.paneLayout.right.selectedDocumentID == right.id)
        #expect(saved.paneLayout.left.selectedDocumentID == left.id && saved.selectedDocumentID == right.id)
        #expect(saved.paneLayout.isValid(documentIDs: saved.documents.map(\.id)))
        workspace.setSplitFraction(.nan)
        workspace.setSplitFraction(.infinity)
        #expect(workspace.paneLayout.splitFraction == 0.62)
        workspace.setSplitFraction(9)
        #expect(workspace.paneLayout.splitFraction == 0.8)
        workspace.setSplitFraction(-9)
        #expect(workspace.paneLayout.splitFraction == 0.2)
        provisional.isProvisionalTableView = false
        await workspace.clearRestoredDocuments()
        saved = await store.load()
        #expect(saved.documents.isEmpty && saved.paneLayout.left.documentIDs.isEmpty && saved.paneLayout.right.documentIDs.isEmpty)
        #expect(saved.paneLayout.activePaneID == .right && saved.paneLayout.splitFraction == 0.2)
        await workspace.shutdown()
    }

    @Test func existingFilesActivateTheirOwningPaneAndNewViewsUseTheSourcePane() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/r11/pane-files/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("draft.sql")
        try Data("SELECT 'file'".utf8).write(to: file)
        let workspace = await workspace()
        let source = try #require(await workspace.openSQLFile(at: file))
        let right = workspace.newDocument(text: "SELECT 'right'", in: .right)
        #expect(await workspace.openSQLFile(at: file) === source)
        #expect(workspace.activePaneID == .left && workspace.selectedDocument === source)
        #expect(workspace.selectedDocument(in: .right) === right)
        workspace.activatePane(.right)
        let duplicate = try #require(workspace.openSQLFileInNewTab(source))
        #expect(workspace.pane(containing: duplicate.id) == .left && workspace.selectedDocument === duplicate)
        #expect(duplicate !== source && duplicate.fileDocument === source.fileDocument)
        #expect(duplicate.runtime == nil && source.runtime == nil && workspace.services.isEmpty)
        await workspace.shutdown()
    }

    private func queryClient() -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        policies, transactions, pending = {}, {}, {}
        def send(value): print(json.dumps(value), flush=True)
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            reply = dict(requestId=command['requestId'])
            if kind == 'hello': reply.update(type='hello.ack', protocolVersion=\(BackendProtocol.version))
            elif kind == 'connect':
                sid = 'pane-session-' + str(len(policies)+1)
                policies[sid] = command['connection']['policy']
                transactions[sid] = 'idle'
                reply.update(type='connect.result', sessionId=sid, engine='postgresql', transactionStatus='idle',
                    capabilities=['execute','cancel','catalog','transactions'])
            elif kind == 'operation.assess':
                reply.update(type='operation.assessment', sessionId=command['sessionId'], queryId=command['queryId'],
                    assessment=dict(decision='allow', policy=policies[command['sessionId']], authorization='fixture-grant',
                        operations=[dict(kind='read', statements=[]) for _ in command['operations']]))
            elif kind in ['execute', 'catalog']:
                sid = command['sessionId']
                send(dict(type='query.started', requestId=command['requestId'], sessionId=sid, queryId=command['queryId']))
                sql = command.get('sql','')
                if sql == 'SELECT pane_wait':
                    assert sid == 'pane-session-2' and len(policies) == 3
                    pending[sid] = command
                    continue
                if sql == 'BEGIN': transactions[sid] = 'transaction'
                if sql == 'ROLLBACK': transactions[sid] = 'idle'
                rows = [[sid]] if kind == 'execute' else []
                reply.update(type='query.result', sessionId=sid, queryId=command['queryId'],
                    transactionStatus=transactions[sid], durationMs=1, columns=[dict(index=0,name='session',nativeType='text')],
                    rows=rows, commandTag='SELECT '+str(len(rows)), rowCount=len(rows), displayedRowCount=len(rows), truncated=False)
            elif kind == 'cancel':
                sid = command['sessionId']
                if sid not in pending:
                    reply.update(type='cancel.ack',sessionId=sid,queryId=command['queryId'],status='alreadyFinished')
                    send(reply)
                    continue
                assert sid == 'pane-session-2' and len(policies) == 3
                active = pending.pop(sid)
                assert active['queryId'] == command['queryId']
                send(dict(type='cancel.ack',requestId=command['requestId'],sessionId=sid,queryId=command['queryId'],status='accepted'))
                send(dict(type='error',requestId=active['requestId'],sessionId=sid,queryId=active['queryId'],category='cancelled',
                    message='Query cancelled.',sqlState='57014',connected=True,outcomeUnknown=False,transactionStatus=transactions[sid]))
                continue
            elif kind == 'disconnect': reply.update(type='disconnect.ack',sessionId=command['sessionId'])
            elif kind == 'shutdown': reply.update(type='shutdown.ack')
            else: sys.exit(42)
            send(reply)
            if kind == 'shutdown': break
        """])
    }

    @Test func movingAnInFlightQueryKeepsItsSessionAndStopCancelsOnlyThatDocument() async throws {
        let profile = SavedConnection(name: "Pane fixture", settings: ConnectionSettings(host: "127.0.0.1", port: 5432,
            database: "fixture", user: "fixture", password: "", sslMode: "disable"))
        let client = queryClient()
        var starts = 0
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id)),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: { _ in .rollback },
            executionDecision: { _ in true }, helperFactory: { starts += 1; return client })
        await workspace.restoreSavedWorkspace()
        await workspace.library.loadConnections()
        let first = workspace.newDocument(profileID: profile.id, text: "BEGIN", in: .left)
        let second = workspace.newDocument(profileID: profile.id, text: "SELECT 2", in: .right)
        await workspace.run(first)
        await workspace.run(second)
        let firstRuntime = try #require(first.runtime)
        let secondRuntime = try #require(second.runtime)
        try #require(firstRuntime.transactionStatus == .transaction && secondRuntime.transactionStatus == .idle)
        let firstSession = firstRuntime.sessionId
        let secondSession = secondRuntime.sessionId
        let execution = Task { await workspace.run(first, sql: "SELECT pane_wait") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !firstRuntime.canStop, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(firstRuntime.canStop)
        let queryID = try #require(firstRuntime.activeQueryId)
        workspace.moveDocument(first.id, to: .right, at: 0)
        workspace.moveDocument(first.id, to: .left)
        workspace.selectDocument(second.id, in: .right)
        #expect(first.runtime === firstRuntime && firstRuntime.sessionId == firstSession && firstRuntime.activeQueryId == queryID)
        #expect(firstRuntime.transactionStatus == .transaction && first.isRunning && workspace.canStartOperation(first))
        await workspace.run(second, sql: "SELECT independent")
        #expect(secondRuntime.result?.rows == [[secondSession]] && secondRuntime.transactionStatus == .idle)
        await workspace.stop(first)
        await execution.value
        #expect(firstRuntime.queryFailure?.category == "cancelled" && firstRuntime.transactionStatus == .transaction)
        #expect(firstRuntime.sessionId == firstSession && secondRuntime.sessionId == secondSession && starts == 1)
        #expect(workspace.selectedDocument === second && secondRuntime.queryFailure == nil)
        await workspace.run(first, sql: "SELECT after_stop")
        #expect(firstRuntime.result?.rows == [[firstSession]] && firstRuntime.queryFailure == nil)
        await workspace.shutdown()
        #expect(await client.waitForExit().status == 0)
    }
}
