import Foundation
import Testing
@testable import DBeer

/// Production ER entry points with a deferred protocol reply; no native windows.
@Suite(.serialized)
@MainActor
struct ERDiagramCloseIntentTests {
    @MainActor private final class Gate {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-er-intent-\(UUID().uuidString)")
        var pending: CheckedContinuation<WorkspaceCloseDecision, Never>?
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
        func choose() async -> WorkspaceCloseDecision { await withCheckedContinuation { pending = $0 } }
        func resolve() { pending?.resume(returning: .cancel); pending = nil }
        func release() { _ = FileManager.default.createFile(atPath: root.appendingPathComponent("release").path, contents: Data()) }
        deinit { try? FileManager.default.removeItem(at: root) }
    }
    private func helper(_ gate: Gate) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, threading, time
        from pathlib import Path
        root = Path(sys.argv[1]); sessions = {}; count = 0; output = threading.Lock()
        def send(reply):
            with output: print(json.dumps(reply), flush=True)
        def work(c):
            kind = c['type']; branch = c.get('catalog',{}).get('kind','')
            if kind == 'catalog.page': branch = c['catalogMetadata']['selectors'][0]['kind']
            if kind == 'monitor.schema': branch = kind
            if (root/'hold').exists() and (root/'hold').read_text() == branch:
                (root/'entered').touch(); deadline = time.monotonic()+5
                while not (root/'release').exists() and time.monotonic()<deadline: time.sleep(.005)
            reply = dict(requestId=c['requestId'],sessionId=c['sessionId'],queryId=c.get('queryId'),transactionStatus='idle',connected=True)
            if kind == 'monitor.schema':
                reply.update(type='monitor.schema.result',schemaObservation=dict(engine='postgresql',action='poll',tables=c['schemaObservation']['tables'],mode='notifications',revision='1',observedAt='2026-11-05T12:00:00Z',installed=True,canInstall=False,canRemove=False,complete=True,notices=[]))
            else:
                fields,rows = [],[]
                if branch == 'columns': fields,rows=['name','nativeType','nullable','primaryKey'],[['id','integer','false','1']]
                elif branch == 'foreignKeys': fields=['name','targetSchema','targetTable','sourceColumn','targetColumn','position']
                elif branch in ['objects','search']: fields,rows=['name','kind','schema'],[['parent','table','public']]
                elif branch == 'schemas': fields,rows=['name','kind'],[['public','schema']]
                columns=[dict(index=i,name=name,engine='postgresql',nativeType='text',typeOid=25) for i,name in enumerate(fields)]
                if kind == 'catalog.page':
                    selector=c['catalogMetadata']['selectors'][0]
                    collection=dict(selector=selector,captureId='capture-'+c['queryId'],observedAt='2026-11-05T12:00:00Z',consistency='repeatableRead',state='complete',columns=columns,rows=rows)
                    reply.update(type='catalog.page.result',catalogMetadata=dict(collections=[collection]))
                else: reply.update(type='query.result',durationMs=1,columns=columns,rows=rows,commandTag='SELECT',rowCount=len(rows),displayedRowCount=len(rows),truncated=False)
            send(reply)
        for line in sys.stdin:
            c=json.loads(line); kind=c['type']; reply=dict(requestId=c['requestId'])
            if kind == 'hello': reply.update(type='hello.ack',protocolVersion=6,capabilities=['schemaObservationV1','sessionMonitorV1'])
            elif kind == 'connect':
                count+=1; sid='er-fixture-'+str(count); sessions[sid]=dict(state='idle',policy=c['connection'].get('policy',dict(environment='unspecified',readOnly=False)))
                reply.update(type='connect.result',engine='postgresql',sessionId=sid,transactionStatus='idle',capabilities=['execute','catalog','cancel','transactions','serverReadOnly','catalogMetadataV1','schemaObservationV1'])
            elif kind == 'operation.assess': reply.update(type='operation.assessment',sessionId=c['sessionId'],queryId=c['queryId'],assessment=dict(decision='allow',policy=sessions[c['sessionId']]['policy'],operations=[dict(kind='read',statements=[]) for op in c['operations']],authorization='fixture-grant'))
            elif kind == 'execute':
                sid=c['sessionId']; sql=c.get('sql','')
                if sql=='BEGIN': sessions[sid]['state']='transaction'
                elif sql in ['COMMIT','ROLLBACK']: sessions[sid]['state']='idle'
                send(dict(type='query.started',requestId=c['requestId'],sessionId=sid,queryId=c['queryId']))
                reply.update(type='query.result',sessionId=sid,queryId=c['queryId'],transactionStatus=sessions[sid]['state'],connected=True,durationMs=1,columns=[],rows=[],commandTag='SELECT',rowCount=0,displayedRowCount=0,truncated=False)
            elif kind in ['catalog','catalog.page','monitor.schema']:
                send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
                threading.Thread(target=work,args=(c,),daemon=True).start(); continue
            elif kind == 'catalog.close':
                send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
                reply.update(type='catalog.close.result',sessionId=c['sessionId'],queryId=c['queryId'],transactionStatus='idle',connected=True,catalogMetadata=dict(collections=[],closed=True))
            elif kind == 'cancel': reply.update(type='cancel.ack',sessionId=c['sessionId'],queryId=c['queryId'],status='alreadyFinished')
            elif kind == 'disconnect': reply.update(type='disconnect.ack',sessionId=c['sessionId'])
            elif kind == 'shutdown': reply.update(type='shutdown.ack')
            else: sys.exit(45)
            send(reply)
            if kind=='shutdown': break
        """, gate.root.path])
    }
    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(predicate())
    }
    @Test(arguments: ["build", "search", "observation"])
    func canceledProfileClosePreservesActiveEROperation(operation: String) async throws {
        let gate = try Gate(), client = helper(gate)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(), automaticallyWatchFiles: false, closeDecision: { _ in await gate.choose() }, executionDecision: { _ in true }, helperFactory: { client })
        await workspace.start()
        do {
            let observationSupported = await client.supportsSchemaObservation()
            let monitorSupported = await client.supportsSessionMonitor()
            try #require(observationSupported && monitorSupported)
            let settings = ConnectionSettings(host: "localhost", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable")
            try #require(await workspace.library.saveConnection(name: "ER lifecycle", settings: settings))
            let profile = try #require(workspace.library.selectedConnectionId)
            let sql = workspace.newDocument(profileID: profile)
            await workspace.run(sql, sql: "BEGIN")
            try #require(sql.runtime?.transactionStatus == .transaction)
            let document = try #require(workspace.openERDiagram(.init(profileID: profile, name: "parent", kind: .object, schema: "public", object: "parent", objectKind: "table")))
            let model = try #require(document.erDiagramModel)
            try (operation == "build" ? "columns" : operation == "search" ? "objects" : "monitor.schema").write(to: gate.root.appendingPathComponent("hold"), atomically: true, encoding: .utf8)
            let reading = Task { @MainActor in
                if operation == "build" { await workspace.buildERDiagram(document) }
                else if operation == "search" { await workspace.searchERDiagram(document, schema: "public", search: "") }
                else { await workspace.toggleERSchemaObservation(document) }
            }
            try await waitUntil { FileManager.default.fileExists(atPath: gate.root.appendingPathComponent("entered").path) }
            let closing = Task { await workspace.disconnectProfile(profile) }
            try await waitUntil { gate.pending != nil }
            let mayStart = workspace.canStartOperation(document)
            #expect(!mayStart)
            gate.release()
            await reading.value
            if operation == "build" { #expect(model.metadata.values.first?.columnState.isAvailable == true && model.metadata.values.first?.relationshipState.isAvailable == true) }
            else if operation == "search" { #expect(model.candidates.count == 1 && model.candidateNotice == nil) }
            else { #expect(model.schemaObservation?.enabled == true && model.schemaObservation?.isBusy == false) }
            gate.resolve()
            let closed = await closing.value
            #expect(!closed && workspace.erDiagramContext(model) != nil)
            if operation == "observation" { await workspace.toggleERSchemaObservation(document) }
            await workspace.run(sql, sql: "ROLLBACK")
            await workspace.shutdown()
        } catch { gate.release(); gate.resolve(); await workspace.shutdown(); throw error }
    }
}
