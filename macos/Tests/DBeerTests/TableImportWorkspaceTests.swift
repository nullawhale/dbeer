import Foundation
import Testing
@testable import DBeer

/// Memory persistence and a counts-only protocol child. No windows, native
/// import panels, confirmations, application activation or database connections.
@Suite(.serialized)
@MainActor
struct TableImportWorkspaceTests {
    private struct Counts: Decodable {
        var connections: Int
        var importConnections: Int
        var sqlExecutions: Int
        var importAssessments: Int
        var applies: Int
        var importDisconnects: Int
        var otherDisconnects: Int
    }

    private func helper(_ countsURL: URL) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        sessions = {}
        counts = dict(connections=0,importConnections=0,sqlExecutions=0,importAssessments=0,applies=0,importDisconnects=0,otherDisconnects=0)
        def record():
            with open(sys.argv[1], 'w') as handle: json.dump(counts,handle)
        def send(value): print(json.dumps(value),flush=True)
        def started(command):
            send(dict(type='query.started',requestId=command['requestId'],sessionId=command['sessionId'],queryId=command['queryId']))
        record()
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            reply = dict(requestId=command['requestId'])
            if kind == 'hello':
                reply.update(type='hello.ack',protocolVersion=\(BackendProtocol.version),capabilities=['tableImportV1'])
            elif kind == 'connect':
                counts['connections'] += 1
                purpose = command['connection'].get('sessionPurpose','ordinary')
                if purpose == 'import': counts['importConnections'] += 1
                session_id = 'workspace-session-' + str(counts['connections'])
                sessions[session_id] = dict(purpose=purpose,tx='idle',policy=command['connection']['policy'],pending=[])
                reply.update(type='connect.result',sessionId=session_id,engine='postgresql',transactionStatus='idle',
                    capabilities=['execute','cancel','catalog','transactions','tableImportV1'])
            elif kind == 'operation.assess':
                session = sessions[command['sessionId']]
                operations = command['operations']
                importing = operations[0]['type'] == 'import.apply'
                if importing:
                    assert session['purpose'] == 'import' and not session['policy']['readOnly']
                    assert len(operations) == 1 and operations[0]['tableImport'] == session['preview']
                    counts['importAssessments'] += 1
                else:
                    assert session['purpose'] == 'ordinary'
                session['pending'] = operations
                reply.update(type='operation.assessment',sessionId=command['sessionId'],queryId=command['queryId'],
                    assessment=dict(decision='allow',policy=session['policy'],authorization='workspace-reviewed',
                        operations=[dict(kind='write' if importing else 'read',statements=[]) for _ in operations]))
            elif kind in ['execute','catalog']:
                session = sessions[command['sessionId']]
                assert session['purpose'] == 'ordinary'
                if kind == 'execute':
                    if command['sql'].strip().upper() == 'BEGIN':
                        assert command['authorization'] == 'workspace-reviewed'
                        counts['sqlExecutions'] += 1
                        session['tx'] = 'transaction'
                    else:
                        assert command['sql'].strip().upper() == 'ROLLBACK'
                        session['tx'] = 'idle'
                started(command)
                reply.update(type='query.result',sessionId=command['sessionId'],queryId=command['queryId'],
                    transactionStatus=session['tx'],durationMs=1,columns=[],rows=[],commandTag='BEGIN' if session['tx']=='transaction' else 'SELECT 0',
                    rowCount=0,displayedRowCount=0,truncated=False)
            elif kind in ['import.describe','import.preview','import.apply']:
                session = sessions[command['sessionId']]
                assert session['purpose'] == 'import' and session['tx'] == 'idle'
                payload = command['tableImport']
                assert payload['schema'] == 'public' and payload['table'] == 'samples'
                started(command)
                if kind == 'import.describe':
                    imported = dict(fingerprint='a'*64,columns=[
                        dict(name='id',nativeType='bigint',nullable=False,hasDefault=True,generated=False,binary=False),
                        dict(name='label',nativeType='text',nullable=False,hasDefault=False,generated=False,binary=False)])
                elif kind == 'import.preview':
                    assert payload['columns'] == ['label'] and len(payload['rows']) == 2
                    session['preview'] = payload
                    imported = dict(fingerprint='a'*64,rowCount=2,sql='INSERT INTO public.samples (label) VALUES ($1)')
                else:
                    assert not session['policy']['readOnly'] and command['authorization'] == 'workspace-reviewed'
                    assert payload == session['preview'] == session['pending'][0]['tableImport']
                    counts['applies'] += 1
                    imported = dict(rowCount=2)
                reply.update(type=kind+'.result',sessionId=command['sessionId'],queryId=command['queryId'],
                    connected=True,transactionStatus='idle',tableImport=imported)
            elif kind == 'disconnect':
                session = sessions.pop(command['sessionId'])
                counts['importDisconnects' if session['purpose']=='import' else 'otherDisconnects'] += 1
                reply.update(type='disconnect.ack',sessionId=command['sessionId'])
            elif kind == 'cancel':
                sessions[command['sessionId']]['pending'] = []
                reply.update(type='cancel.ack',sessionId=command['sessionId'],queryId=command['queryId'],status='alreadyFinished')
            elif kind == 'shutdown': reply.update(type='shutdown.ack')
            else: sys.exit(73)
            record()
            send(reply)
            if kind == 'shutdown': break
        """, countsURL.path])
    }

    @Test(arguments: [false, true])
    func importerOwnsOnlyItsDedicatedSessionAndPreservesIndependentSqlTransaction(readOnly: Bool) async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/table-import/workspace/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let countsURL = directory.appendingPathComponent("counts.json")
        let client = helper(countsURL)
        let profile = SavedConnection(name: "Import fixture", settings: .init(host: "127.0.0.1", port: 5432,
            database: "fixture", user: "fixture", password: "", sslMode: "disable",
            policy: .init(environment: .development, readOnly: readOnly)))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id)),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), automaticallyWatchFiles: false,
            closeDecision: { issue in
                if case .importDraft = issue { return .discard }
                return .rollback
            }, executionDecision: { _ in true }, helperFactory: { client })
        defer { Task { await workspace.shutdown() } }
        await workspace.restoreSavedWorkspace()
        await workspace.library.loadConnections()
        await workspace.connectProfile(profile.id)
        let service = try #require(workspace.services[profile.id])
        #expect(service.connectionState == .connected)
        let serviceSession = try #require(service.sessionId)
        await workspace.loadCompletionCatalog(profile.id)
        let document = workspace.newDocument(profileID: profile.id, text: "BEGIN;")
        await workspace.runScript(document)
        let runtime = try #require(document.runtime)
        let sqlSession = try #require(runtime.sessionId)
        #expect(runtime.transactionStatus == .transaction && sqlSession != serviceSession)
        var pendingTable: SQLDocument?
        var pendingGrid: GridDraft?
        if !readOnly {
            let tableDocument = workspace.newDocument(profileID: profile.id, text: "")
            let reference = TableReference(schema: "public", name: "samples", kind: "table")
            tableDocument.table = reference
            let grid = GridDraft(reference: reference, result: BackendMessage(type: "query.result", requestId: "local-grid",
                columns: [.init(index: 0, name: "id", nativeType: "bigint")], rows: [["1"]]),
                metadata: [["name": "id", "nativeType": "bigint", "primaryKey": "1", "editable": "true"]])
            tableDocument.attachGrid(grid)
            grid.set(ChangeValue(kind: "text", value: "2"), row: 0, column: 0)
            let hasPendingEdits = grid.pendingCount == 1 && grid.canApply
            try #require(hasPendingEdits)
            pendingTable = tableDocument
            pendingGrid = grid
        }
        let node = CatalogNode(profileID: profile.id, name: "samples", kind: .object,
            schema: "public", object: "samples", objectKind: "table")
        #expect(workspace.canImportTableData(node))
        await workspace.openTableImport(node)
        let importer = try #require(workspace.tableImporter)
        let metadataError = importer.error
        try #require(metadataError == nil)
        let names = importer.columns.map(\.name)
        try #require(names == ["id", "label"])
        await importer.loadFile(data: Data("label\nAlpha\n\"\"\n".utf8), name: "fixture.csv")
        let canPreview = importer.canPreview
        try #require(canPreview)
        await importer.preparePreview()
        let previewCount = importer.preview?.rowCount
        let canApply = importer.canApply
        try #require(previewCount == 2 && canApply == !readOnly)
        await importer.apply()
        let appliedCount = importer.appliedRowCount
        let retainsPreview = importer.preview != nil
        let applyError = importer.error
        if readOnly { #expect(appliedCount == nil && retainsPreview) }
        else { #expect(appliedCount == 2 && applyError == nil) }
        await workspace.closeTableImport()
        #expect(workspace.tableImporter == nil)
        let serviceUnchanged = workspace.services[profile.id] === service && service.sessionId == serviceSession && service.connectionState == .connected
        let sqlTransactionUnchanged = document.runtime === runtime && runtime.sessionId == sqlSession && runtime.transactionStatus == .transaction
        #expect(serviceUnchanged && sqlTransactionUnchanged)
        if let pendingTable, let pendingGrid {
            let draftPreserved = pendingTable.grid === pendingGrid && pendingGrid.pendingCount == 1 &&
                pendingGrid.canApply && !pendingGrid.resultIsStale
            #expect(draftPreserved)
        }
        let counts = try JSONDecoder().decode(Counts.self, from: Data(contentsOf: countsURL))
        #expect(counts.connections == 3 && counts.importConnections == 1 && counts.sqlExecutions == 1)
        #expect(counts.importAssessments == (readOnly ? 0 : 1) && counts.applies == (readOnly ? 0 : 1))
        #expect(counts.importDisconnects == 1 && counts.otherDisconnects == 0)
        await workspace.shutdown()
    }
}
