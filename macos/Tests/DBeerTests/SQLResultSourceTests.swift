import Foundation
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct SQLResultSourceTests {
    private func fixtures() throws -> [BackendMessage] {
        struct Fixture: Decodable { var responses: [BackendMessage] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/sql-result-source-v1.json"))).responses
    }

    @Test func sharedEvidenceKeepsAliasesCanonicalOriginalsAndExactKeys() throws {
        let messages = try fixtures()
        for message in messages { try message.validate() }
        let result = messages[0]
        let source = try #require(result.source)
        let grid = GridDraft(reference: TableReference(schema: source.schema, name: source.table, kind: "table"), result: result, metadata: [], querySource: source)
        #expect(grid.columns.map(\.name) == ["shown", "id"])
        grid.set(.null, row: 0, column: 0)
        let request = grid.request()
        #expect(request.columns.map(\.name) == ["id", "label"])
        #expect(request.columns.map(\.nativeType) == ["bigint", "text"])
        #expect(request.changes[0].original == [ChangeValue(kind: "text", value: "9223372036854775807"), ChangeValue(kind: "text", value: "")])
        #expect(request.changes[0].values == [ColumnAssignment(column: "label", value: .null)])
        #expect(source.filters(row: grid.rows[0].original!) == [CatalogFilter(column: "id", operator: "eq", value: "9223372036854775807")])
        grid.insert(); grid.selectedRows = [0]; grid.deleteSelected()
        #expect(grid.rows.count == 2 && !grid.rows[0].isDeleted)
        #expect(!grid.supportsRowInsertionAndDeletion)
        let projection = messages[1].source!
        #expect(projection.canOpenRow && !projection.isEditable)
        #expect(!messages[2].source!.canOpenRow)
    }

    @Test func malformedEvidenceCannotEnableEditingOrNavigateWithIncompleteCells() throws {
        let result = try fixtures()[0]
        var source = try #require(result.source)
        source.columns[1].tableIndex = 1
        #expect(!source.valid(for: result.columns!))
        source = result.source!; source.columns[1].primaryKey = 2
        #expect(!source.valid(for: result.columns!))
        source = result.source!; source.columns[1].name = source.columns[0].name
        #expect(!source.valid(for: result.columns!))
        source = result.source!; source.columns[0].generated = true
        #expect(!source.valid(for: result.columns!))
        source = result.source!
        #expect(source.filters(row: [.null, .null]) == nil)
        #expect(source.filters(row: [.null, .default]) == nil)
        #expect(source.filters(row: [.null]) == nil)
        source.columns[1].primaryKey = 0; source.columns[0].primaryKey = 1
        #expect(source.filters(row: [ChangeValue(kind: "binary", value: "AP8="), .null])?.first?.value == "AP8=")
        #expect(source.filters(row: [ChangeValue(kind: "binary", value: "invalid!"), .null]) == nil)
    }

    @Test func streamSummaryValidatesEvidenceBeforeHydrationAndProjectsSelectedSet() throws {
        var message = try fixtures()[0]
        let source = message.source!
        message.resultSets = [QueryResultSet(columns: message.columns!, rows: [], commandTag: "SELECT 2", rowCount: 2, displayedRowCount: 2, source: source)]
        message.streamed = true
        message.columns = []; message.rows = []
        try message.validate()
        #expect(ResultSnapshotSource.project(message, resultSetIndex: 0)?.source == source)
        message.resultSets![0].source!.columns[0].tableIndex = 0
        #expect(throws: BackendTransportError.self) { try message.validate() }
    }

    private func makeWorkspace(mode: String = "success") async throws -> (ApplicationWorkspace, SQLDocument, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        from pathlib import Path
        directory, mode = Path(sys.argv[1]), sys.argv[2]
        columns = [dict(index=0,name='shown',engine='postgresql',nativeType='text'), dict(index=1,name='id',engine='postgresql',nativeType='int8')]
        source = dict(schema='fixture',table='items',columns=[dict(name='label',nativeType='text',tableIndex=1,primaryKey=0,editable=True,generated=False),dict(name='id',nativeType='bigint',tableIndex=0,primaryKey=1,editable=True,generated=False)])
        connections = 0
        def send(reply): print(json.dumps(reply),flush=True)
        for line in sys.stdin:
            c = json.loads(line); kind = c['type']
            if kind == 'stream.ack': continue
            with (directory/'commands').open('a') as log: log.write(kind+(':'+c['catalog']['kind'] if kind == 'catalog' else '')+'\\n')
            r = dict(requestId=c['requestId'])
            if kind == 'hello': r.update(type='hello.ack',protocolVersion=5,capabilities=['resultSourceV1'])
            elif kind == 'connect':
                connections += 1
                r.update(type='connect.result',engine='postgresql',sessionId='session-'+str(connections),transactionStatus='idle',capabilities=['execute','cancel','catalog','gridEditing'])
            elif kind == 'operation.assess':
                r.update(type='operation.assessment',sessionId=c['sessionId'],queryId=c['queryId'],assessment=dict(decision='allow',policy=dict(environment='unspecified',readOnly=False),operations=[dict(kind='read',statements=[]) for o in c['operations']],authorization='grant'))
            elif kind in ['execute','catalog','changes.preview','changes.apply']:
                send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
                r.update(type='query.result',sessionId=c['sessionId'],queryId=c['queryId'],transactionStatus='idle',durationMs=1,columns=[],rows=[],commandTag='UPDATE 1',rowCount=0,displayedRowCount=0,truncated=False)
                if kind == 'execute':
                    assert c['sql'].strip().rstrip(';') == 'SELECT label AS shown, id FROM fixture.items'
                    if mode == 'stream':
                        send(dict(type='query.chunk',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'],sequence=1,resultIndex=0,columns=columns,rows=[['original','9223372036854775807']]))
                        r.update(streamed=True,source=source,resultSets=[dict(columns=columns,rows=[],commandTag='SELECT 1',rowCount=1,displayedRowCount=1,truncated=False,source=source)])
                    else: r.update(columns=columns,rows=[['original','9223372036854775807']],source=source,commandTag='SELECT 1',rowCount=1,displayedRowCount=1)
                elif kind.startswith('changes.'):
                    changes = c['changes']
                    assert [x['name'] for x in changes['columns']] == ['id','label']
                    assert changes['changes'][0]['original'][0]['value'] == '9223372036854775807'
                    assert changes['changes'][0]['values'][0]['column'] == 'label'
                    if kind == 'changes.apply' and mode in ['conflict','unknown']:
                        r = dict(type='error',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'],category='conflict' if mode == 'conflict' else 'connection',message='The original row changed.' if mode == 'conflict' else 'The write outcome is unknown.',connected=True,transactionStatus='idle',outcomeUnknown=mode=='unknown')
                elif kind == 'catalog':
                    request = c['catalog']
                    operation = request['kind']
                    if operation == 'completion': pass
                    elif mode != 'navigate': raise AssertionError('Source row navigation must reject edited keys before metadata reads')
                    else:
                        assert request.get('schema') == 'fixture' and request.get('object') == 'items'
                        if operation == 'columns':
                            names = ['name','nativeType','nullable','primaryKey','editable']
                            metadata = [['id','bigint','false','1','true'],['label','text','true','0','true']]
                            r.update(columns=[dict(index=i,name=name,engine='postgresql',nativeType='text') for i,name in enumerate(names)],rows=metadata,rowCount=2,displayedRowCount=2,commandTag='SELECT 2')
                        elif operation == 'browse':
                            assert request.get('filters') == [dict(column='id',operator='eq',value='9223372036854775807')]
                            (directory/'source-filter').write_text(json.dumps(request))
                            r.update(columns=[dict(index=0,name='id',engine='postgresql',nativeType='int8'),dict(index=1,name='label',engine='postgresql',nativeType='text')],rows=[['9223372036854775807','original']],commandTag='SELECT 1',rowCount=1,displayedRowCount=1)
                        elif operation != 'foreignKeys': raise AssertionError(operation)
            elif kind == 'cancel': r.update(type='cancel.ack',sessionId=c['sessionId'],queryId=c['queryId'],status='alreadyFinished')
            elif kind == 'disconnect': r.update(type='disconnect.ack',sessionId=c['sessionId'])
            elif kind == 'shutdown': r.update(type='shutdown.ack')
            else: raise AssertionError(kind)
            send(r)
            if kind == 'shutdown': break
        """, directory.path, mode])
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            closeDecision: { _ in .cancel }, executionDecision: { _ in true }, helperFactory: { client })
        await workspace.start()
        try #require(await workspace.library.saveConnection(name: "Result source fixture", settings: ConnectionSettings(host: "localhost", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable")))
        let document = workspace.newDocument(profileID: workspace.library.selectedConnectionId)
        document.text = "SELECT label AS shown, id FROM fixture.items;"
        await workspace.run(document)
        try #require(document.grid != nil, "Source grid unavailable: local=\(document.localError ?? "none"), runtime=\(document.runtime?.errorMessage ?? "none"), commands=\((try? String(contentsOf: directory.appendingPathComponent("commands"), encoding: .utf8)) ?? "none")")
        return (workspace, document, directory)
    }

    private func commands(_ directory: URL) throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent("commands"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test(arguments: ["success", "stream"])
    func applyMarksResultStaleWithoutReplayingSQL(mode: String) async throws {
        let (workspace, document, directory) = try await makeWorkspace(mode: mode)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grid = try #require(document.grid)
        #expect(workspace.snapshotCapture(for: document) != nil)
        grid.hasInlineDraft = true
        #expect(workspace.snapshotCapture(for: document) == nil)
        grid.hasInlineDraft = false
        grid.set(ChangeValue(kind: "text", value: "edited"), row: 0, column: 0)
        #expect(document.queryResultSelectionLocked)
        await workspace.previewGrid(document)
        #expect(grid.preview != nil && grid.error == nil)
        #expect(await workspace.applyGrid(document))
        #expect(document.grid === grid && grid.resultIsStale && !grid.canEdit && grid.pendingCount == 0)
        #expect(grid.rows[0].values[0].value == "edited")
        #expect(try commands(directory).filter { $0 == "execute" }.count == 1)
        #expect(workspace.snapshotCapture(for: document) == nil)
        #expect(!(await workspace.applyGrid(document)))
        #expect(document.selectQueryResult() && document.grid === grid)
        await workspace.shutdown()
    }

    @Test(arguments: ["conflict", "unknown"])
    func failedApplyRetainsDraftAndBlocksAnotherApply(mode: String) async throws {
        let (workspace, document, directory) = try await makeWorkspace(mode: mode)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grid = try #require(document.grid)
        grid.set(ChangeValue(kind: "text", value: "edited"), row: 0, column: 0)
        #expect(!(await workspace.applyGrid(document)))
        #expect(grid.pendingCount == 1 && !grid.canEdit)
        #expect(grid.rows[0].values[0].value == "edited")
        #expect(grid.outcomeUnknown == (mode == "unknown"))
        #expect(!(await workspace.applyGrid(document)))
        #expect(try commands(directory).filter { $0 == "changes.apply" }.count == 1)
        await workspace.run(document) // Cancel must preserve the current result and its draft.
        #expect(document.grid === grid && grid.pendingCount == 1)
        #expect(try commands(directory).filter { $0 == "execute" }.count == 1)
        await workspace.discardGrid(document)
        #expect(grid.pendingCount == 0 && !grid.canEdit)
        #expect(try commands(directory).filter { $0 == "execute" }.count == 1)
        await workspace.shutdown()
    }

    @Test func inlinePrimaryKeyChangeCannotNavigateAndSessionRebindingCannotApply() async throws {
        let (workspace, document, directory) = try await makeWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grid = try #require(document.grid)
        let id = grid.rows[0].id
        grid.commitEditing = { grid.set(ChangeValue(kind: "text", value: "2"), row: 0, column: 1) }
        await workspace.openSQLSourceRow(document, rowID: id)
        #expect(grid.error?.contains("primary-key") == true)
        #expect(try !commands(directory).contains { $0 == "catalog:columns" || $0 == "catalog:browse" })
        grid.commitEditing = nil
        grid.discard()
        grid.set(ChangeValue(kind: "text", value: "edited"), row: 0, column: 0)
        let runtime = try #require(document.runtime)
        let originalSession = try #require(runtime.sessionId)
        let profileID = try #require(document.profileID)
        await runtime.disconnect()
        await runtime.connectSavedConnection(profileID)
        #expect(runtime.sessionId != nil && runtime.sessionId != originalSession)
        #expect(!(await workspace.applyGrid(document)))
        #expect(try !commands(directory).contains("changes.apply"))
        await workspace.shutdown()
    }

    @Test func sourceNavigationUsesExactOriginalKeyInAnIndependentTableTab() async throws {
        let (workspace, document, directory) = try await makeWorkspace(mode: "navigate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let grid = try #require(document.grid)
        let sourceSession = try #require(document.runtime?.sessionId)
        let executionIDs = document.executions.map(\.id)
        // A non-key local change must remain in the SQL result while navigation
        // reads the stored row in a separate working session.
        grid.set(ChangeValue(kind: "text", value: "local draft"), row: 0, column: 0)
        await workspace.openSQLSourceRow(document, rowID: grid.rows[0].id)
        let target = try #require(workspace.documents.first { $0 !== document && $0.table != nil })
        #expect(target.table == TableReference(schema: "fixture", name: "items", kind: "table"))
        #expect(target.tableFilters == [CatalogFilter(column: "id", operator: "eq", value: "9223372036854775807")])
        #expect(target.runtime?.sessionId != nil && target.runtime?.sessionId != sourceSession)
        #expect(target.grid?.rows.first?.values.first?.value == "9223372036854775807")
        #expect(document.grid === grid && grid.pendingCount == 1)
        #expect(grid.rows[0].values[0].value == "local draft")
        #expect(document.executions.map(\.id) == executionIDs && document.text == "SELECT label AS shown, id FROM fixture.items;")
        #expect(try commands(directory).filter { $0 == "execute" }.count == 1)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("source-filter").path))
        await workspace.shutdown()
    }

    @Test func pendingDraftCannotBeReplacedByAnotherResultSetOrExecution() async throws {
        let (workspace, document, directory) = try await makeWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grid = try #require(document.grid)
        var result = try #require(document.executions[0].result)
        let first = QueryResultSet(columns: result.columns!, rows: result.rows!, commandTag: "SELECT 1", rowCount: 1, displayedRowCount: 1, source: result.source)
        var second = first
        second.rows = [["other result", "2"]]
        result.resultSets = [first, second]
        document.executions[0].result = result
        let originalSelection = document.queryResultSelection
        grid.set(ChangeValue(kind: "text", value: "pending"), row: 0, column: 0)
        #expect(!document.selectQueryResult(1))
        #expect(document.grid === grid && document.queryResultSelection == originalSelection)
        #expect(grid.rows[0].values[0].value == "pending" && grid.pendingCount == 1)
        document.executions.append(SQLExecution(sql: "SELECT id, label FROM fixture.items;", range: NSRange(location: 0, length: 0), result: result))
        #expect(!document.selectSQLExecution(1))
        #expect(document.selectedExecution == 0)
        #expect(document.grid === grid && document.queryResultSelection == originalSelection)
        grid.discard()
        #expect(document.selectQueryResult(1))
        let selected = try #require(document.grid)
        #expect(selected !== grid && selected.rows[0].values[0].value == "other result")
        #expect(document.selectSQLExecution(1))
        #expect(document.grid?.rows[0].values[0].value == "original")
        #expect(try commands(directory).filter { $0 == "execute" }.count == 1)
        await workspace.shutdown()
    }

}
