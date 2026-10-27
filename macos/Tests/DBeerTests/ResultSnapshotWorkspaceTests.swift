import Foundation
import Testing
@testable import DBeer

/// Local workspace models and private artifacts only. No windows, native
/// controls, desktop input, credentials, helper process or database are used.
@MainActor
struct ResultSnapshotWorkspaceTests {
    private let finishedAt = Date(timeIntervalSince1970: 1_700_000_123)

    private func directory() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/r15/workspace-\(UUID().uuidString)")
    }

    private func profile() -> SavedConnection {
        SavedConnection(name: "Historical connection", settings: ConnectionSettings(host: "127.0.0.1", port: 5432,
            database: "fixture", user: "fixture", password: "", sslMode: "disable",
            policy: ExecutionPolicy(environment: .staging)))
    }

    private func result(_ value: String = "9007199254740993.000000001") -> BackendMessage {
        BackendMessage(type: "query.result", requestId: "fixture", columns: [
            ResultColumn(index: 0, name: "value", nativeType: "numeric")], rows: [[value]],
            commandTag: "SELECT 1", rowCount: 1, displayedRowCount: 1)
    }

    private func source(sql: String = "SELECT fixture", result: BackendMessage? = nil,
                        failure: WorkspaceModel.QueryFailure? = nil, isTablePage: Bool = false) throws -> ResultSnapshotSource {
        let saved = profile()
        return try #require(ResultSnapshotSource(sql: sql, profileID: saved.id, profile: SQLHistoryProfile(saved),
            completion: WorkspaceModel.QueryCompletion(startedAt: finishedAt.addingTimeInterval(-1),
                finishedAt: finishedAt, durationMs: 1_000, reply: result ?? self.result(), failure: failure),
            isTablePage: isTablePage))
    }

    @Test func pinUsesSelectedSetAndFrozenExecutionContextAfterEditorAndProfileChanges() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ResultSnapshotsModel(store: ResultSnapshotStore(rootURL: root))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), resultSnapshots: manager)
        await workspace.restoreSavedWorkspace()
        var reply = result("aggregate must not be captured")
        reply.resultSets = [
            QueryResultSet(columns: [ResultColumn(index: 0, name: "first", nativeType: "text")],
                rows: [["other set"]], commandTag: "SELECT 1", rowCount: 1, displayedRowCount: 1),
            QueryResultSet(columns: [ResultColumn(index: 0, name: "duplicate", nativeType: "numeric"),
                ResultColumn(index: 1, name: "duplicate", nativeType: "text")],
                rows: [["9007199254740993.000000001", nil], ["0.000000001", "NULL"]], commandTag: "SELECT 7",
                rowCount: 7, displayedRowCount: 2, truncated: true)]
        let frozen = try source(sql: "CALL historical_fixture();", result: reply)
        let other = try source(sql: "SELECT other_execution")
        let document = workspace.newDocument(text: "CALL historical_fixture(); SELECT other_execution;")
        document.executions = [SQLExecution(sql: frozen.sql, range: NSRange(location: 0, length: 26),
            status: "Completed", result: reply, snapshotSource: frozen),
            SQLExecution(sql: other.sql, range: NSRange(location: 27, length: 22), status: "Completed",
                result: other.result, snapshotSource: other)]
        document.selectedExecution = 0
        document.text = "SELECT newly_edited_sql;"
        document.profileID = UUID()
        let saved = try #require(await workspace.pinResult(document, resultSetIndex: 1))
        let artifact = try await manager.store.load(id: saved.id)
        #expect(artifact.manifest.sql == "CALL historical_fixture();")
        #expect(artifact.manifest.capturedAt == finishedAt)
        #expect(artifact.manifest.profileID == frozen.profileID)
        #expect(artifact.manifest.profileName == "Historical connection" && artifact.manifest.environment == .staging)
        #expect(artifact.manifest.columns.map(\.name) == ["duplicate", "duplicate"])
        #expect(artifact.rows == [["9007199254740993.000000001", nil], ["0.000000001", "NULL"]])
        #expect(artifact.manifest.sourceRowCount == 7 && artifact.manifest.truncated && artifact.manifest.partial)
        #expect(artifact.manifest.outcome == .succeeded)
        #expect(workspace.snapshotCapture(for: document, resultSetIndex: 2) == nil)
        document.isRunning = true
        #expect(await workspace.pinResult(document, resultSetIndex: 1) == nil)
        #expect(try await manager.store.list().count == 1)
        document.isRunning = false
        await workspace.shutdown()
    }

    @Test func tablePinExcludesDraftValuesAndKeepsOriginalBrowseQuery() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ResultSnapshotsModel(store: ResultSnapshotStore(rootURL: root))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), resultSnapshots: manager)
        await workspace.restoreSavedWorkspace()
        let document = workspace.newDocument(text: "Table data")
        let table = TableReference(schema: "fixture", name: "items", kind: "table")
        document.table = table
        let reply = result("1")
        document.tableResult = reply
        document.tableSnapshotSource = try source(sql: "SELECT * FROM \"fixture\".\"items\" LIMIT 200 OFFSET 400",
            result: reply, isTablePage: true)
        let grid = GridDraft(reference: table, result: reply,
            metadata: [["name": "value", "nativeType": "numeric", "primaryKey": "1", "editable": "true"]])
        document.attachGrid(grid)
        grid.set(ChangeValue(kind: "text", value: "edited draft"), row: 0, column: 0)
        grid.hasInlineDraft = true
        try #require(grid.pendingCount > 0)
        let saved = try #require(await workspace.pinResult(document))
        let artifact = try await manager.store.load(id: saved.id)
        #expect(artifact.rows == [["1"]] && artifact.manifest.partial)
        #expect(artifact.manifest.sql.hasSuffix("OFFSET 400"))
        #expect(grid.rows[0].values[0].value == "edited draft" && grid.pendingCount > 0)
        grid.isApplying = true
        #expect(workspace.snapshotCapture(for: document) == nil)
        grid.isApplying = false
        grid.discard()
        grid.hasInlineDraft = false
        await workspace.shutdown()
    }

    @Test func terminalFailurePreservesOutcomeAndMarksLoadedValuesPartial() throws {
        for (category, outcome) in [("cancelled", SQLHistoryOutcome.cancelled), ("timeout", .timedOut), ("sql", .failed)] {
            let failure = WorkspaceModel.QueryFailure(category: category, message: "Transient fixture", sqlState: nil,
                outcomeUnknown: false)
            let capture = try #require(source(failure: failure).capture(title: "Fixture", resultSetIndex: 0))
            #expect(capture.outcome == outcome && capture.partial && capture.capturedAt == finishedAt)
        }
        var reply = result()
        reply.outcomeUnknown = true
        let capture = try #require(source(result: reply).capture(title: "Fixture", resultSetIndex: 0))
        #expect(capture.outcome == .unknown && capture.partial)
        let saved = profile()
        let notExecuted = WorkspaceModel.QueryFailure(category: "policy", message: "Not executed", sqlState: nil,
            outcomeUnknown: false, sqlNotExecuted: true)
        #expect(ResultSnapshotSource(sql: "SELECT fixture", profileID: saved.id, profile: SQLHistoryProfile(saved),
            completion: WorkspaceModel.QueryCompletion(startedAt: finishedAt, finishedAt: finishedAt,
                durationMs: 0, reply: reply, failure: notExecuted)) == nil)
    }

    @Test func snapshotOpenCloseReopenAndRestartUseOnlyLocalReferences() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ResultSnapshotsModel(store: ResultSnapshotStore(rootURL: root))
        let capture = try #require(source().capture(title: "Offline fixture", resultSetIndex: 0))
        let saved = try await manager.store.save(capture)
        let drafts = MemorySQLDocumentStore()
        var starts = 0
        let makeWorkspace = { @MainActor in
            ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
                documentStore: drafts, resultSnapshots: manager, helperFactory: {
                    starts += 1
                    return BackendClient(executableURL: root.appendingPathComponent("unused-helper"))
                })
        }
        let workspace = makeWorkspace()
        await workspace.restoreSavedWorkspace()
        let opened = try #require(workspace.openResultSnapshot(id: saved.id, title: saved.title))
        await opened.snapshotModel?.load()
        #expect(starts == 0 && opened.runtime == nil && workspace.services.isEmpty)
        #expect(opened.snapshotModel?.manifest?.capturedAt == finishedAt)
        await workspace.closeDocument(opened)
        #expect(try await manager.store.list().map(\.id) == [saved.id])
        let reopened = try #require(workspace.reopenClosedTab())
        #expect(reopened.id != opened.id && reopened.snapshotID == saved.id && reopened.text.isEmpty)
        #expect(reopened.runtime == nil && reopened.profileID == nil && reopened.table == nil && reopened.fileURL == nil)
        await reopened.snapshotModel?.load()
        await workspace.flushDocuments()
        let persisted = await drafts.load()
        #expect(persisted.documents.first?.snapshotID == saved.id && persisted.documents.first?.text == "")
        await workspace.shutdown()
        let restarted = makeWorkspace()
        await restarted.start()
        let restored = try #require(restarted.selectedDocument)
        #expect(restored.snapshotID == saved.id && restored.snapshotModel != nil && starts == 0)
        await restored.snapshotModel?.load()
        #expect(restored.snapshotModel?.result?.rows == capture.rows)
        #expect(restored.runtime == nil && restarted.services.isEmpty)
        await restarted.shutdown()
    }

    @Test func snapshotCommandsStayOfflineAndOpenSQLRequiresAChosenConnection() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ResultSnapshotsModel(store: ResultSnapshotStore(rootURL: root))
        let saved = try await manager.store.save(try #require(source().capture(title: "Offline", resultSetIndex: 0)))
        let selectedProfile = profile()
        let connections = MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [selectedProfile], selectedConnectionId: selectedProfile.id))
        var starts = 0
        let workspace = ApplicationWorkspace(connectionStore: connections, credentialStore: MemoryConnectionCredentialStore(),
            resultSnapshots: manager, helperFactory: {
                starts += 1
                return BackendClient(executableURL: root.appendingPathComponent("unused-helper"))
            })
        await workspace.restoreSavedWorkspace()
        await workspace.library.loadConnections()
        let snapshot = try #require(workspace.openResultSnapshot(id: saved.id))
        await snapshot.snapshotModel?.load()
        let context = AppCommandContext(documentID: snapshot.id, focus: .workspace, isWorkspaceWindow: true, hasModal: false)
        for command in [AppCommandID.runCurrent, .runScript, .runToJSON, .runToCSV, .saveSQL, .saveSQLAs] {
            #expect(!workspace.commands.canPerform(command, context: context))
        }
        snapshot.profileID = selectedProfile.id
        await workspace.run(snapshot, sql: "SELECT must_not_run")
        await workspace.runScript(snapshot)
        await workspace.runToFile(snapshot, format: "json")
        workspace.saveSQLFile(snapshot)
        #expect(workspace.executionFragment(snapshot) == nil && starts == 0 && snapshot.runtime == nil)
        #expect(snapshot.storedState.profileID == nil && snapshot.storedState.text.isEmpty)
        let draft = try #require(workspace.openSnapshotSQLInNewTab(snapshot))
        #expect(workspace.library.selectedConnectionId == selectedProfile.id)
        #expect(draft.profileID == nil && draft.text == "SELECT fixture" && draft.runtime == nil && !draft.isSnapshot)
        await workspace.run(draft)
        #expect(starts == 0 && draft.runtime == nil && workspace.services.isEmpty)
        await workspace.shutdown()
    }

    @Test func missingArtifactStaysUnavailableAfterReopenWithoutSQLFallback() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ResultSnapshotsModel(store: ResultSnapshotStore(rootURL: root))
        let missing = UUID()
        let stored = StoredSQLDocument(title: "Missing", text: "", kind: .snapshot, snapshotID: missing)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore:
                MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(documents: [stored], selectedDocumentID: stored.id)),
            resultSnapshots: manager)
        await workspace.restoreSavedWorkspace()
        let document = try #require(workspace.selectedDocument)
        await document.snapshotModel?.load()
        #expect(document.isSnapshot && document.snapshotModel?.error != nil && document.runtime == nil)
        #expect(workspace.openSnapshotSQLInNewTab(document) == nil)
        await workspace.closeDocument(document)
        let reopened = try #require(workspace.reopenClosedTab())
        await reopened.snapshotModel?.load()
        #expect(reopened.snapshotID == missing && reopened.snapshotModel?.error != nil)
        #expect(reopened.profileID == nil && reopened.text.isEmpty && workspace.services.isEmpty)
        await workspace.shutdown()
    }

    @Test func browseSQLIsAcceptedOnlyOnSuccessfulResultMessages() throws {
        var reply = result()
        reply.sessionId = "session"
        reply.queryId = "query"
        reply.transactionStatus = .idle
        reply.durationMs = 1
        reply.truncated = false
        reply.sql = "SELECT * FROM \"fixture\".\"items\" LIMIT 200 OFFSET 400"
        try reply.validate()
        reply.sql = ""
        #expect(throws: BackendTransportError.self) { try reply.validate() }
        reply.sql = "SELECT\0fixture"
        #expect(throws: BackendTransportError.self) { try reply.validate() }
        var failure = BackendMessage(type: "error", requestId: "fixture", category: "sql", message: "Fixture",
            connected: true, outcomeUnknown: false, sql: "SELECT fixture")
        #expect(throws: BackendTransportError.self) { try failure.validate() }
        failure.sql = nil
        try failure.validate()
    }

    @Test func executeAndBrowseCompletionsSupplyPinContextThroughTheFramedHelperProtocol() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ResultSnapshotsModel(store: ResultSnapshotStore(rootURL: root))
        let savedProfile = profile()
        let connections = MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [savedProfile], selectedConnectionId: savedProfile.id))
        var starts = 0
        let workspace = ApplicationWorkspace(connectionStore: connections,
            credentialStore: MemoryConnectionCredentialStore(), resultSnapshots: manager,
            executionDecision: { _ in true }, helperFactory: {
                starts += 1
                return BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
                import json, sys
                policies = {}
                def send(reply): print(json.dumps(reply), flush=True)
                column = dict(index=0, name='value', engine='postgresql', nativeType='numeric')
                for line in sys.stdin:
                    command = json.loads(line)
                    kind = command['type']
                    reply = dict(requestId=command['requestId'])
                    if kind == 'hello':
                        reply.update(type='hello.ack', protocolVersion=\(BackendProtocol.version))
                    elif kind == 'connect':
                        sid = 'snapshot-session-' + str(len(policies))
                        policies[sid] = command['connection']['policy']
                        reply.update(type='connect.result', sessionId=sid, engine='postgresql',
                            capabilities=['execute','cancel','catalog','transactions','gridEditing'], transactionStatus='idle')
                    elif kind == 'operation.assess':
                        reply.update(type='operation.assessment', sessionId=command['sessionId'], queryId=command['queryId'],
                            assessment=dict(decision='allow', policy=policies[command['sessionId']], authorization='fixture-grant',
                                operations=[dict(kind='read', statements=[]) for _ in command['operations']]))
                    elif kind in ['execute', 'catalog']:
                        send(dict(type='query.started', requestId=command['requestId'],
                            sessionId=command['sessionId'], queryId=command['queryId']))
                        reply.update(type='query.result', sessionId=command['sessionId'], queryId=command['queryId'],
                            transactionStatus='idle', durationMs=1, columns=[], rows=[], commandTag='SELECT 0',
                            rowCount=0, displayedRowCount=0, truncated=False)
                        if kind == 'execute':
                            sets = [dict(columns=[column], rows=[[value]], commandTag='SELECT 1', rowCount=1,
                                displayedRowCount=1, truncated=False) for value in ['first set','9007199254740993.000000001']]
                            reply.update(sets[0]); reply['resultSets'] = sets
                        elif command['catalog']['kind'] == 'columns':
                            reply.update(columns=[dict(index=i,name=n,engine='postgresql',nativeType='text')
                                for i,n in enumerate(['name','nativeType','primaryKey','editable'])],
                                rows=[['value','numeric','1','true']], commandTag='SELECT 1', rowCount=1, displayedRowCount=1)
                        elif command['catalog']['kind'] == 'browse':
                            reply.update(columns=[column], rows=[['42']], commandTag='SELECT 1', rowCount=1, displayedRowCount=1,
                                sql='SELECT * FROM "fixture"."items" WHERE "value" >= 1 ORDER BY "value" LIMIT 200 OFFSET 400')
                    elif kind == 'cancel':
                        reply.update(type='cancel.ack', sessionId=command['sessionId'], queryId=command['queryId'], status='alreadyFinished')
                    elif kind == 'disconnect':
                        reply.update(type='disconnect.ack', sessionId=command['sessionId'])
                    elif kind == 'shutdown':
                        reply.update(type='shutdown.ack')
                    else:
                        sys.exit(41)
                    send(reply)
                    if kind == 'shutdown': break
                """])
            })
        await workspace.start()
        let document = workspace.newDocument(profileID: savedProfile.id, text: "SELECT fixture_multi();")
        #expect(workspace.snapshotCapture(for: document) == nil)
        let began = Date.now
        await workspace.run(document)
        let finished = try #require(workspace.history.last?.finishedAt)
        try #require(document.localError == nil && document.executions.first?.snapshotSource != nil)
        let table = workspace.newDocument(profileID: savedProfile.id, text: "Table data")
        table.table = TableReference(schema: "fixture", name: "items", kind: "table")
        table.page = 2
        table.tableFilters = [CatalogFilter(column: "value", operator: "gte", value: "1")]
        // Changing filters resets paging, exactly as the production browse controls do.
        table.page = 2
        await workspace.run(table)
        try #require(table.localError == nil && table.grid != nil && table.tableSnapshotSource != nil)
        let tableCapture = try #require(workspace.snapshotCapture(for: table))
        #expect(tableCapture.sql == "SELECT * FROM \"fixture\".\"items\" WHERE \"value\" >= 1 ORDER BY \"value\" LIMIT 200 OFFSET 400")
        #expect(tableCapture.rows == [["42"]] && tableCapture.partial)
        try #require(await workspace.library.saveConnection(name: "Edited after completion",
            settings: savedProfile.settings(password: ""), id: savedProfile.id))
        document.text = "SELECT edited_after_completion;"
        let selected = try #require(workspace.snapshotCapture(for: document, resultSetIndex: 1))
        #expect(selected.sql == "SELECT fixture_multi()" && selected.profileName == "Historical connection")
        #expect(selected.capturedAt == finished && selected.capturedAt >= began)
        #expect(selected.rows == [["9007199254740993.000000001"]] && selected.outcome == .succeeded)
        let pinned = try #require(await workspace.pinResult(document, resultSetIndex: 1))
        let opened = try #require(workspace.openResultSnapshot(id: pinned.id))
        await opened.snapshotModel?.load()
        #expect(opened.snapshotModel?.result?.rows == selected.rows && opened.runtime == nil && starts == 1)
        await workspace.shutdown()
    }
}
