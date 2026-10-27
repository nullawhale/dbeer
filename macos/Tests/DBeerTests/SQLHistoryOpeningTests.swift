import Foundation
import Testing
@testable import DBeer

// Model and protocol tests only; no windows, dialogs, or application activation.
@MainActor
struct SQLHistoryOpeningTests {
    private var settings: ConnectionSettings {
        ConnectionSettings(host: "db.example.test", port: 5432, database: "history", user: "reader",
            password: "", sslMode: "disable", policy: ExecutionPolicy(environment: .production))
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
                reply.update(type='connect.result',sessionId='history-open-'+str(sessions),engine='postgresql',
                    capabilities=['execute','cancel','catalog','transactions'],transactionStatus='idle')
            elif kind == 'operation.assess':
                reply.update(type='operation.assessment',sessionId=command['sessionId'],queryId=command['queryId'],
                    assessment=dict(decision='allow',policy=dict(environment='production',readOnly=False),authorization='grant',
                        operations=[dict(kind='read',statements=[]) for operation in command['operations']]))
            elif kind in ['catalog', 'execute']:
                send(dict(type='query.started',requestId=command['requestId'],sessionId=command['sessionId'],queryId=command['queryId']))
                reply.update(type='query.result',sessionId=command['sessionId'],queryId=command['queryId'],
                    transactionStatus='idle',durationMs=1,columns=[],rows=[],commandTag='SELECT 0',
                    rowCount=0,displayedRowCount=0,truncated=False)
                if kind == 'execute':
                    reply.update(columns=[dict(index=0,name='value',typeOid=23)],rows=[['7']],commandTag='SELECT 1',
                        rowCount=1,displayedRowCount=1)
            elif kind == 'cancel':
                reply.update(type='cancel.ack',sessionId=command['sessionId'],queryId=command['queryId'],status='alreadyFinished')
            elif kind == 'disconnect':
                reply.update(type='disconnect.ack',sessionId=command['sessionId'])
            elif kind == 'shutdown':
                reply.update(type='shutdown.ack')
            else:
                sys.exit(41)
            send(reply)
            if kind == 'shutdown': break
        """])
    }

    @Test func availableProfileOpensExactSQLInANewDisconnectedDocument() async throws {
        var helperStarts = 0
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), helperFactory: {
                helperStarts += 1
                return self.client()
            })
        try #require(await workspace.library.saveConnection(name: "Original", settings: settings))
        let originalID = try #require(workspace.library.selectedConnectionId)
        try #require(await workspace.library.saveConnection(name: "Currently selected", settings: settings))
        let selectedProfileID = try #require(workspace.library.selectedConnectionId)
        let existing = workspace.newDocument(profileID: originalID, text: "SELECT 'keep this tab';")
        let sql = "  -- History: 日本語, café, 🐋\nSELECT 'Первая строка';\n\nSELECT 7;  \n"
        let entry = SQLHistoryEntry(documentID: existing.id, profileID: originalID, sql: sql, outcome: "Completed")

        let document = workspace.openHistoryEntry(entry)
        let secondOpening = workspace.openHistoryEntry(entry)

        #expect(document.id != existing.id && document.id != secondOpening.id)
        #expect(workspace.documents.count == 3 && workspace.selectedDocumentID == secondOpening.id)
        #expect(document.text == sql && secondOpening.text == sql)
        #expect(document.profileID == originalID && document.profileID != selectedProfileID)
        #expect(document.runtime == nil && secondOpening.runtime == nil)
        #expect(!document.isRunning && document.executions.isEmpty && document.grid == nil)
        #expect(document.historyConnectionNotice == nil)
        #expect(existing.text == "SELECT 'keep this tab';")
        #expect(workspace.services.isEmpty && workspace.history.isEmpty && helperStarts == 0)
        await workspace.shutdown()
    }

    @Test(arguments: [false, true])
    func missingProfileStaysUnassignedUntilTheUserChoosesAReplacement(deleted: Bool) async throws {
        var helperStarts = 0
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: { _ in .rollback },
            executionDecision: { _ in true }, helperFactory: {
                helperStarts += 1
                return self.client()
            })
        var originalID: UUID?
        if deleted {
            try #require(await workspace.library.saveConnection(name: "Deleted original", settings: settings))
            let savedID = try #require(workspace.library.selectedConnectionId)
            originalID = savedID
        }
        try #require(await workspace.library.saveConnection(name: "Replacement", settings: settings))
        let replacementID = try #require(workspace.library.selectedConnectionId)
        if let originalID { try #require(await workspace.library.deleteConnection(originalID)) }
        let entry = SQLHistoryEntry(profileID: originalID, sql: "SELECT 7;", outcome: "Completed")

        let document = workspace.openHistoryEntry(entry)
        let context = AppCommandContext(documentID: document.id, focus: .sqlEditor, isWorkspaceWindow: true, hasModal: false)
        #expect(document.profileID == nil && workspace.library.selectedConnectionId == replacementID)
        #expect(document.historyConnectionNotice?.contains("Choose a connection") == true)
        #expect(!workspace.commands.canPerform(.runCurrent, context: context))
        await workspace.run(document)
        #expect(document.runtime == nil && !document.isRunning && document.executions.isEmpty)
        #expect(workspace.services.isEmpty && workspace.history.isEmpty && helperStarts == 0)

        document.profileID = replacementID
        #expect(document.historyConnectionNotice == nil)
        #expect(workspace.commands.canPerform(.runCurrent, context: context))
        #expect(document.runtime == nil && workspace.services.isEmpty && helperStarts == 0)
        let run = try #require(workspace.commands.perform(.runCurrent, context: context))
        await run.value
        #expect(helperStarts == 1 && document.runtime?.connectionState == .connected)
        #expect(document.runtime?.result?.rows == [["7"]])
        #expect(workspace.history.count == 1 && workspace.history.first?.profileID == replacementID)
        #expect(workspace.history.first?.sql == "SELECT 7" && workspace.history.first?.outcome == .succeeded)
        await workspace.shutdown()
    }
}
