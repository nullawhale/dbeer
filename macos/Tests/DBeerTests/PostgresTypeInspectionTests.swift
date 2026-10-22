import Foundation
import Testing
@testable import DBeer

actor PostgresTypeTestCredentials: ConnectionCredentialStore {
    private(set) var reads = 0
    func password(for id: UUID) -> String? { reads += 1; return "" }
    func savePassword(_ password: String, for id: UUID) {}
    func deletePassword(for id: UUID) {}
}

/// Synthetic framed transport shared with the separately classified window
/// suite. The helper never opens a database or executes generated SQL. Its log
/// excludes passwords, provider configuration, SQL text and query results.
@MainActor
final class PostgresTypeTestFixture {
    let workspace: ApplicationWorkspace
    let profile: SavedConnection
    let otherProfile: SavedConnection
    let credentials: PostgresTypeTestCredentials
    let directory: URL
    private let logURL: URL
    private let gateURL: URL

    private init(readOnly: Bool, engine: DatabaseEngine, reuseSessionID: Bool) throws {
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/r28/native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("commands.ndjson")
        gateURL = directory.appendingPathComponent("release")
        profile = SavedConnection(name: "Type fixture", settings: ConnectionSettings(host: "fixture.invalid",
            port: engine.defaultPort, database: "fixture", user: "fixture", password: "", sslMode: "disable",
            engine: engine, policy: ExecutionPolicy(environment: .development, readOnly: readOnly)))
        otherProfile = SavedConnection(name: "Other fixture", settings: ConnectionSettings(host: "other.invalid",
            port: 5432, database: "other", user: "fixture", password: "", sslMode: "disable"))
        credentials = PostgresTypeTestCredentials()
        let log = Data(logURL.path.utf8).base64EncodedString()
        let gate = Data(gateURL.path.utf8).base64EncodedString()
        let source = #"""
        import base64, json, sys, os, select
        log_path=base64.b64decode('\#(log)').decode('utf-8')
        gate_path=base64.b64decode('\#(gate)').decode('utf-8')
        policies, engines, pending = {}, {}, {}
        buffered=b''
        def send(value): print(json.dumps(value), flush=True)
        def result(command, columns, rows, truncated=False):
            return dict(type='query.result', requestId=command['requestId'], sessionId=command['sessionId'],
                queryId=command['queryId'], transactionStatus='idle', durationMs=1,
                columns=[dict(index=i,name=name,nativeType='text',engine='postgresql') for i,name in enumerate(columns)],
                rows=rows, commandTag='SELECT '+str(len(rows)), rowCount=len(rows), displayedRowCount=len(rows), truncated=truncated)
        def error(command):
            return dict(type='error', requestId=command['requestId'], sessionId=command['sessionId'], queryId=command['queryId'],
                transactionStatus='idle', category='catalog', message='Synthetic private SQL and credential text must not be displayed.',
                connected=True, outcomeUnknown=False)
        def ident(value): return '"'+value.replace('"','""')+'"'
        def literal(value): return "E'"+value.replace('\\','\\\\').replace("'","\\'")+"'"
        def labels(name):
            if 'empty' in name: return []
            return ['a\\b',' spaced ','🌍','NULL'] if name.startswith('append_') else ['','a\\b',' spaced ','🌍','NULL']
        def catalog(command):
            request=command['catalog']; kind=request['kind']; name=request.get('object','status')
            oid=request.get('identity','40001'); object_kind=request.get('objectKind','enum')
            if kind=='schemas': return result(command,['name'],[['public']])
            if kind in ['completion','foreignKeys']: return result(command,[],[])
            if kind in ['objects','search']:
                rows=[['status','enum','public','40001','enum'],['account_code','type','public','40002','domain']]
                if kind=='objects': rows=[row for row in rows if row[1]==object_kind]
                return result(command,['name','kind','schema','identity','typeKind'],rows)
            if kind=='name': return result(command,['name'],[[ident(request['schema'])+'.'+ident(name)]])
            if kind=='typeDetails':
                if name.startswith('denied'): return error(command)
                category='enum' if object_kind=='enum' else 'domain'
                definition='CREATE TYPE '+ident(request['schema'])+'.'+ident(name)+' AS ENUM ('+', '.join(literal(label) for label in labels(name))+');'
                flags=['true','true','true'] if object_kind=='enum' else ['true','false','false']
                status='complete'
                details='Synthetic unused type'
                limitations='No removal, reordering, or CASCADE workflow.'
                if name.startswith('bounded'):
                    definition,status,flags=None,'partial',['true','false','false']
                    details='Category: enum\nType properties exceed the metadata bound. A complete CREATE definition is unavailable.'
                    limitations='Enum labels exceed the metadata bound, so value previews are unavailable.'
                if name.startswith('unavailable'): category,definition,status,flags='base',None,'unavailable',['false','false','false']
                return result(command,\#(String(decoding: try JSONEncoder().encode(PostgresTypeCatalog.detailColumns), as: UTF8.self)),
                    [[name,object_kind,request['schema'],oid,category,'fixture_owner',definition,status,details]+flags+
                     [limitations,'Ownership and server privileges are checked when SQL runs.']])
            if kind=='enumValues':
                if name.startswith('values-denied'): return error(command)
                rows=[[label,str(i+1),str(i+1)+'.5'] for i,label in enumerate(labels(name))]
                if 'empty' in name: rows=[]
                return result(command,['label','position','sortOrder'],rows,truncated=name.startswith('partial') or name.startswith('bounded'))
            if kind=='typeDependencies':
                if name.startswith('deps-denied'): return error(command)
                rows=[['incoming','table column','public','orders','public.orders.state','normal','1259','42001','2','1247',oid,'0'],
                      ['outgoing','schema','public','public','public','normal','1247',oid,'0','2615','2200','0']]
                if 'empty' in name: rows=[]
                return result(command,\#(String(decoding: try JSONEncoder().encode(PostgresTypeCatalog.dependencyColumns), as: UTF8.self)),rows,
                    truncated=name.startswith('partial'))
            if kind=='typeDDL':
                change=request['typeChange']; operation=change['operation']; target=ident(request['schema'])+'.'+ident(name)
                if operation=='addEnumValue' and change['value'] in labels(name): return error(command)
                if operation=='renameEnumValue' and (change['oldValue'] not in labels(name) or change['value'] in labels(name)): return error(command)
                if operation=='renameType': sql='ALTER TYPE '+target+' RENAME TO '+ident(change['newName'])+';'
                elif operation=='addEnumValue': sql='ALTER TYPE '+target+' ADD VALUE '+literal(change['value'])+';'
                else: sql='ALTER TYPE '+target+' RENAME VALUE '+literal(change['oldValue'])+' TO '+literal(change['value'])+';'
                return result(command,['sql','warnings'],[[sql,'Use Run for policy authorization. Added labels are usable after commit.']])
            return result(command,[],[])
        while True:
            if pending and os.path.exists(gate_path):
                for command in list(pending.values()):
                    send(error(command) if 'error' in command['catalog'].get('object','') else catalog(command))
                pending.clear()
                os.unlink(gate_path)
            if b'\n' not in buffered:
                ready,_,_=select.select([sys.stdin],[],[],0.01)
                if not ready: continue
                data=os.read(sys.stdin.fileno(),65536)
                if not data: break
                buffered+=data
                if b'\n' not in buffered: continue
            line,buffered=buffered.split(b'\n',1)
            command=json.loads(line); kind=command['type']
            logged=dict(command)
            logged.pop('sql',None)
            if 'connection' in logged:
                logged['connection']=dict(logged['connection']); logged['connection']['password']=''
                logged['connection'].pop('passwordCommand',None)
            with open(log_path,'a') as stream: stream.write(json.dumps(logged)+'\n')
            reply=dict(requestId=command['requestId'])
            if kind=='hello': reply.update(type='hello.ack',protocolVersion=\#(BackendProtocol.version),capabilities=['passwordCommandV1'])
            elif kind=='connect':
                sid='type-session-1' if \#(reuseSessionID ? "True" : "False") else 'type-session-'+str(len(policies)+1)
                policies[sid]=command['connection']['policy']; engines[sid]=command['connection']['engine']
                reply.update(type='connect.result',sessionId=sid,engine=engines[sid],transactionStatus='idle',capabilities=['execute','cancel','catalog','transactions'])
            elif kind=='catalog':
                request=command['catalog']; change=request.get('typeChange',{})
                hold=request['kind']=='typeDetails' and request.get('object','').startswith('hold-details')
                hold=hold or request['kind']=='typeDDL' and (change.get('newName')=='hold-preview' or change.get('value')=='hold-preview')
                hold=hold or request['kind']=='objects' and request.get('schema')=='hold-objects'
                hold=hold or request['kind']=='search' and request.get('search')=='hold-search'
                send(dict(type='query.started',requestId=command['requestId'],sessionId=command['sessionId'],queryId=command['queryId']))
                if hold: pending[command['queryId']]=command; continue
                reply=catalog(command)
            elif kind=='cancel':
                active=pending.pop(command['queryId'],None)
                reply.update(type='cancel.ack',sessionId=command['sessionId'],queryId=command['queryId'],status='accepted' if active else 'alreadyFinished')
                send(reply)
                if active: send(error(active) if 'error' in active['catalog'].get('object','') else catalog(active))
                continue
            elif kind=='operation.assess':
                readonly=policies[command['sessionId']]['readOnly']
                assessment=dict(decision='deny' if readonly else 'confirm',policy=policies[command['sessionId']],operations=[dict(kind='write',statements=[])])
                if not readonly: assessment['authorization']='fixture-grant'
                reply.update(type='operation.assessment',sessionId=command['sessionId'],queryId=command['queryId'],assessment=assessment)
            elif kind=='execute': reply=result(command,[],[])
            elif kind=='disconnect': reply.update(type='disconnect.ack',sessionId=command['sessionId'])
            elif kind=='shutdown': reply.update(type='shutdown.ack')
            else: sys.exit(42)
            send(reply)
            if kind=='shutdown': break
        """#
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", source])
        workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [profile, otherProfile], selectedConnectionId: profile.id)),
            credentialStore: credentials, documentStore: MemorySQLDocumentStore(),
            resultSnapshots: ResultSnapshotsModel(store: ResultSnapshotStore(rootURL: directory.appendingPathComponent("snapshots"))),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in true }, helperFactory: { client })
    }

    static func make(readOnly: Bool = false, engine: DatabaseEngine = .postgresql, reuseSessionID: Bool = false) async throws -> PostgresTypeTestFixture {
        let fixture = try PostgresTypeTestFixture(readOnly: readOnly, engine: engine, reuseSessionID: reuseSessionID)
        await fixture.workspace.restoreSavedWorkspace()
        await fixture.workspace.library.loadConnections()
        return fixture
    }

    func connect() async throws {
        await workspace.connectProfile(profile.id)
        guard let service = workspace.services[profile.id], service.connectionState == .connected, service.sessionId != nil else {
            let reason = workspace.services[profile.id]?.errorMessage ?? workspace.error ?? "No connected service session was created."
            await finish()
            throw PostgresTypeCatalogFailure(message: "Synthetic type helper startup failed: " + reason)
        }
        if service.engine == .postgresql, workspace.currentPostgresTypeCatalogOrigin(profileID: profile.id) == nil {
            await finish()
            throw PostgresTypeCatalogFailure(message: "Synthetic type helper connected with settings that do not match the saved profile.")
        }
    }
    func node(_ name: String = "status", oid: String = "40001", kind: String = "enum", typeKind: String = "enum") -> CatalogNode {
        CatalogNode(profileID: profile.id, name: name, kind: .object, schema: "public", object: name,
            objectKind: kind, identity: oid, engine: profile.engine, localOID: oid, typeKind: typeKind,
            typeOrigin: workspace.currentPostgresTypeCatalogOrigin(profileID: profile.id))
    }
    func commands() throws -> [BackendCommand] {
        guard let data = try? Data(contentsOf: logURL) else { return [] }
        return try data.split(separator: 10).map { try JSONDecoder().decode(BackendCommand.self, from: Data($0)) }
    }
    func waitForCatalog(_ kind: String, count: Int = 1) async throws {
        try await Self.waitFor { ((try? self.commands().filter { $0.catalog?.kind == kind }.count) ?? 0) >= count }
    }
    func releaseHeld() throws { try Data().write(to: gateURL) }
    static func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }
    func finish() async {
        workspace.dismissPostgresTypeInspection()
        await workspace.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Non-UI model/transport tests. They never show windows, activate the app,
/// inspect the desktop, or connect to a database.
@Suite(.serialized)
@MainActor
struct PostgresTypeInspectionTests {
    @Test func groupsSearchAndInspectionUseTypedHandlesWithoutUsingRows() async throws {
        let fixture = try await PostgresTypeTestFixture.make()
        try await fixture.connect()
        let workspace = fixture.workspace
        await workspace.loadSchemas(fixture.profile.id)
        let schema = try #require(workspace.catalogRoots[fixture.profile.id]?.first)
        await workspace.expand(schema)
        #expect(schema.children?.filter { ["enum", "type"].contains($0.objectKind) }.map(\.name) == ["Enums", "User-defined Types"])
        let group = try #require(schema.children?.first { $0.objectKind == "enum" })
        await workspace.expand(group)
        let type = try #require(group.children?.first)
        #expect(type.isPostgresType && !type.isExpandable && type.localOID == "40001" && type.typeKind == "enum")
        workspace.catalogSearch = "status"
        await workspace.searchCatalog()
        let result = try #require(workspace.catalogSearchResults[fixture.profile.id]?.first)
        #expect(result.isPostgresType && result.localOID == type.localOID)
        await workspace.inspect(result)
        let model = try #require(workspace.typeInspection)
        #expect(workspace.inspection == nil && model.details?.definitionStatus == .complete)
        #expect(model.enumValues?.map(\.label) == ["", "a\\b", " spaced ", "🌍", "NULL"])
        #expect(model.enumValues?.map(\.position) == [1, 2, 3, 4, 5] && model.enumValuesComplete)
        #expect(model.dependencies?.first?.objectSubID == "2" && model.dependenciesComplete)
        let requests = try fixture.commands().compactMap(\.catalog).filter { ["typeDetails", "enumValues", "typeDependencies"].contains($0.kind) }
        #expect(requests.map(\.kind) == ["typeDetails", "enumValues", "typeDependencies"])
        #expect(requests.allSatisfy { $0.identity == "40001" && $0.schema == "public" && $0.objectKind == "enum" })
        #expect(!requests.contains { $0.kind == "columns" || $0.kind == "browse" })
        await fixture.finish()
    }

    @Test func readonlyPreviewAndDraftRemainCapturedAndNeverExecuteOrReconnect() async throws {
        let fixture = try await PostgresTypeTestFixture.make(readOnly: true)
        try await fixture.connect()
        let workspace = fixture.workspace
        let left = workspace.newDocument(profileID: fixture.profile.id, in: .left)
        let right = workspace.newDocument(profileID: fixture.otherProfile.id, in: .right)
        workspace.activatePane(.left)
        await workspace.inspect(fixture.node())
        await workspace.previewPostgresTypeChange(TypeChange(operation: "addEnumValue", value: ""))
        #expect(workspace.typeInspection?.preview == nil && workspace.typeInspection?.previewError != nil)
        await workspace.inspect(fixture.node("append_status"))
        let reference = try #require(workspace.typeInspection?.reference)
        #expect(workspace.typeInspection?.enumValues?.contains { $0.label.isEmpty } == false)
        let credentialReads = await fixture.credentials.reads
        await workspace.library.selectConnection(fixture.otherProfile.id)
        workspace.selectDocument(right.id, in: .right)
        await workspace.previewPostgresTypeChange(TypeChange(operation: "addEnumValue", value: ""))
        let preview = try #require(workspace.typeInspection?.preview)
        #expect(preview.sql.hasSuffix("ADD VALUE E'';") && reference.policy.readOnly)
        let draft = try #require(workspace.openPostgresTypeSQLDraft())
        #expect(draft.profileID == fixture.profile.id && draft.runtime == nil && !draft.isRunning)
        #expect(workspace.pane(containing: draft.id) == .left && workspace.activePaneID == .right)
        #expect(workspace.selectedDocument(in: .left) !== left && workspace.selectedDocument(in: .right) === right)
        let commands = try fixture.commands()
        #expect(commands.filter { $0.type == "connect" }.count == 1)
        #expect(!commands.contains { $0.type == "execute" || $0.type == "operation.assess" })
        #expect(commands.filter { $0.catalog?.kind == "typeDDL" }.allSatisfy { $0.sessionId == reference.serviceSessionID })
        #expect(await fixture.credentials.reads == credentialReads)
        await workspace.run(draft)
        #expect(draft.runtime?.queryFailure == nil && draft.localError?.contains("Readonly") == true)
        #expect(!((try fixture.commands()).contains { $0.type == "execute" }))
        await fixture.finish()
    }

    @Test func stopCancelsOnlyItsCorrelatedCatalogQueryAndDropsLateSuccess() async throws {
        let fixture = try await PostgresTypeTestFixture.make()
        try await fixture.connect()
        let workspace = fixture.workspace
        await workspace.inspect(fixture.node())
        let preview = Task { await workspace.previewPostgresTypeChange(TypeChange(operation: "renameType", newName: "hold-preview")) }
        try await fixture.waitForCatalog("typeDDL")
        let request = try #require(fixture.commands().last { $0.catalog?.kind == "typeDDL" })
        workspace.stopPostgresTypeInspection()
        await preview.value
        try await PostgresTypeTestFixture.waitFor { workspace.typeInspection?.cancellationNotice?.contains("accepted") == true }
        #expect(workspace.typeInspection?.preview == nil && workspace.typeInspection?.previewError == nil)
        let cancel = try #require(fixture.commands().last { $0.type == "cancel" })
        #expect(cancel.queryId == request.queryId && cancel.sessionId == request.sessionId)
        await workspace.previewPostgresTypeChange(TypeChange(operation: "renameType", newName: "after_stop"))
        #expect(workspace.typeInspection?.preview?.sql.contains("after_stop") == true)
        #expect(try fixture.commands().filter { $0.type == "connect" }.count == 1)
        await fixture.finish()
    }

    @Test func replacementDismissAndRefreshDiscardPendingMetadataAndStaleErrors() async throws {
        let fixture = try await PostgresTypeTestFixture.make()
        try await fixture.connect()
        let workspace = fixture.workspace
        let old = Task { await workspace.inspect(fixture.node("hold-details-error")) }
        try await fixture.waitForCatalog("typeDetails")
        let oldID = workspace.typeInspection?.id
        await workspace.inspect(fixture.node())
        await old.value
        #expect(workspace.typeInspection?.id != oldID && workspace.typeInspection?.metadataError == nil)
        #expect(workspace.typeInspection?.details != nil && workspace.typeInspection?.dependencies != nil)
        let pending = Task { await workspace.previewPostgresTypeChange(TypeChange(operation: "renameType", newName: "hold-preview")) }
        try await fixture.waitForCatalog("typeDDL")
        await workspace.refreshPostgresTypeInspection()
        await pending.value
        #expect(workspace.typeInspection?.preview == nil && workspace.typeInspection?.details != nil)
        let closing = Task { await workspace.previewPostgresTypeChange(TypeChange(operation: "renameType", newName: "hold-preview")) }
        try await fixture.waitForCatalog("typeDDL", count: 2)
        workspace.dismissPostgresTypeInspection()
        await closing.value
        #expect(workspace.typeInspection == nil)
        #expect(try fixture.commands().filter { $0.type == "cancel" }.count >= 3)
        await fixture.finish()
    }

    @Test func profilePolicyEditDeletionAndReconnectInvalidateDrafts() async throws {
        let fixture = try await PostgresTypeTestFixture.make()
        try await fixture.connect()
        let workspace = fixture.workspace
        await workspace.inspect(fixture.node())
        await workspace.previewPostgresTypeChange(TypeChange(operation: "renameType", newName: "fresh"))
        let old = try #require(workspace.typeInspection?.reference)
        var settings = fixture.profile.settings(password: "")
        settings.policy.readOnly = true
        try #require(await workspace.library.saveConnection(name: fixture.profile.name, settings: settings, id: fixture.profile.id))
        #expect(workspace.typeInspection?.invalidationReason != nil && workspace.openPostgresTypeSQLDraft() == nil)
        try #require(await workspace.disconnectProfile(fixture.profile.id))
        try await fixture.connect()
        #expect(!workspace.postgresTypeReferenceIsCurrent(old))
        await workspace.inspect(fixture.node())
        let updated = try #require(workspace.typeInspection?.reference)
        #expect(updated.settingsRevision != old.settingsRevision && updated.serviceGeneration != old.serviceGeneration)
        await workspace.previewPostgresTypeChange(TypeChange(operation: "renameType", newName: "fresh"))
        try #require(await workspace.library.deleteConnection(fixture.profile.id))
        #expect(workspace.typeInspection?.invalidationReason != nil && workspace.openPostgresTypeSQLDraft() == nil)
        await fixture.finish()
    }

    @Test func cachedNodeCannotRebindItsOIDAfterReconnectOrEndpointEdit() async throws {
        let fixture = try await PostgresTypeTestFixture.make(reuseSessionID: true)
        try await fixture.connect()
        let workspace = fixture.workspace
        let cached = fixture.node()
        await workspace.inspect(cached)
        let original = try #require(workspace.typeInspection)
        try #require(await workspace.disconnectProfile(fixture.profile.id))
        try await fixture.connect()
        await workspace.inspect(cached)
        #expect(workspace.typeInspection === original && original.invalidationReason != nil)
        await workspace.inspect(fixture.node())
        let current = try #require(workspace.typeInspection)
        #expect(current !== original)
        #expect(current.reference.serviceSessionID == original.reference.serviceSessionID)
        #expect(current.reference.serviceGeneration != original.reference.serviceGeneration)
        let otherCached = fixture.node()
        var settings = fixture.profile.settings(password: "")
        settings.host = "changed.invalid"
        try #require(await workspace.library.saveConnection(name: fixture.profile.name, settings: settings, id: fixture.profile.id))
        await workspace.inspect(otherCached)
        #expect(workspace.typeInspection === current && current.invalidationReason != nil)
        await workspace.inspect(fixture.node())
        #expect(workspace.typeInspection === current)
        #expect(try fixture.commands().filter { $0.catalog?.kind == "typeDetails" }.count == 2)
        await fixture.finish()
    }

    @Test func canonicallyEquivalentDatabaseEditRequiresAReconnectedService() async throws {
        let fixture = try await PostgresTypeTestFixture.make()
        let workspace = fixture.workspace
        let composed = "caf\u{e9}"
        let decomposed = "cafe\u{301}"
        #expect(composed == decomposed && Data(composed.utf8) != Data(decomposed.utf8))
        var settings = fixture.profile.settings(password: "")
        settings.database = composed
        try #require(await workspace.library.saveConnection(name: fixture.profile.name, settings: settings, id: fixture.profile.id))
        try await fixture.connect()
        await workspace.inspect(fixture.node())
        let original = try #require(workspace.typeInspection)
        #expect(workspace.currentPostgresTypeCatalogOrigin(profileID: fixture.profile.id) != nil)
        settings.database = decomposed
        try #require(await workspace.library.saveConnection(name: fixture.profile.name, settings: settings, id: fixture.profile.id))
        #expect(Data((workspace.services[fixture.profile.id]?.database ?? "").utf8) == Data(composed.utf8))
        #expect(workspace.currentPostgresTypeCatalogOrigin(profileID: fixture.profile.id) == nil)
        await workspace.loadSchemas(fixture.profile.id, refresh: true)
        let schema = try #require(workspace.catalogRoots[fixture.profile.id]?.first)
        await workspace.expand(schema)
        let enums = try #require(schema.children?.first { $0.objectKind == "enum" })
        await workspace.expand(enums)
        #expect(enums.children == nil && enums.error != nil)
        await workspace.inspect(fixture.node())
        #expect(workspace.typeInspection === original && original.invalidationReason != nil)
        #expect(try fixture.commands().filter { $0.catalog?.kind == "typeDetails" }.count == 1)
        try #require(await workspace.disconnectProfile(fixture.profile.id))
        try await fixture.connect()
        #expect(workspace.currentPostgresTypeCatalogOrigin(profileID: fixture.profile.id) != nil)
        await workspace.inspect(fixture.node())
        let reconnected = try #require(workspace.typeInspection)
        #expect(reconnected !== original && Data(reconnected.reference.database.utf8) == Data(decomposed.utf8))
        #expect(reconnected.reference.serviceGeneration != original.reference.serviceGeneration)
        await fixture.finish()
    }

    @Test func heldPostgresGroupSuccessStaysStaleAcrossEngineEditAndDeletion() async throws {
        for deleteProfile in [false, true] {
            let fixture = try await PostgresTypeTestFixture.make()
            let workspace = fixture.workspace
            try await fixture.connect()
            let enums = CatalogNode(profileID: fixture.profile.id, name: "Enums", kind: .group,
                schema: "hold-objects", objectKind: "enum", engine: .postgresql)
            let pending = Task { await workspace.expand(enums) }
            try await fixture.waitForCatalog("objects")
            if deleteProfile {
                try #require(await workspace.library.deleteConnection(fixture.profile.id))
            } else {
                var settings = fixture.profile.settings(password: "")
                settings.engine = .mysql
                try #require(await workspace.library.saveConnection(name: fixture.profile.name, settings: settings, id: fixture.profile.id))
            }
            try fixture.releaseHeld()
            await pending.value
            #expect(enums.children == nil && enums.error == nil && !enums.isLoading)
            #expect(workspace.currentPostgresTypeCatalogOrigin(profileID: fixture.profile.id) == nil)
            await fixture.finish()
        }
    }

    @Test func heldPostgresSearchSuccessStaysStaleAcrossEngineEditAndDeletion() async throws {
        for deleteProfile in [false, true] {
            let fixture = try await PostgresTypeTestFixture.make()
            let workspace = fixture.workspace
            try await fixture.connect()
            workspace.catalogSearch = "hold-search"
            let pending = Task { await workspace.searchCatalog() }
            try await fixture.waitForCatalog("search")
            if deleteProfile {
                try #require(await workspace.library.deleteConnection(fixture.profile.id))
            } else {
                var settings = fixture.profile.settings(password: "")
                settings.engine = .mysql
                try #require(await workspace.library.saveConnection(name: fixture.profile.name, settings: settings, id: fixture.profile.id))
            }
            try fixture.releaseHeld()
            await pending.value
            #expect(workspace.catalogSearchResults[fixture.profile.id] == nil && workspace.catalogErrors[fixture.profile.id] == nil)
            #expect(workspace.currentPostgresTypeCatalogOrigin(profileID: fixture.profile.id) == nil)
            await fixture.finish()
        }
    }

    @Test func boundedDefinitionKeepsRenamePreviewAvailableWithExplicitLimitations() async throws {
        let fixture = try await PostgresTypeTestFixture.make()
        try await fixture.connect()
        let workspace = fixture.workspace
        await workspace.inspect(fixture.node("bounded_type"))
        let model = try #require(workspace.typeInspection)
        #expect(model.metadataError == nil && model.details?.definitionStatus == .partial && model.details?.definition == nil)
        #expect(model.details?.details?.contains("metadata bound") == true && model.enumValuesComplete == false)
        #expect(model.details?.renameSupported == true && model.details?.addEnumValueSupported == false)
        await workspace.previewPostgresTypeChange(TypeChange(operation: "renameType", newName: "bounded_renamed"))
        #expect(model.preview?.sql.contains("bounded_renamed") == true && model.previewError == nil)
        await fixture.finish()
    }

    @Test func pendingProfilePolicyChangeAndFormEditDiscardLatePreview() async throws {
        let fixture = try await PostgresTypeTestFixture.make()
        try await fixture.connect()
        let workspace = fixture.workspace
        await workspace.inspect(fixture.node())
        let first = Task { await workspace.previewPostgresTypeChange(TypeChange(operation: "addEnumValue", value: "hold-preview")) }
        try await fixture.waitForCatalog("typeDDL")
        workspace.discardPostgresTypePreview()
        await first.value
        #expect(workspace.typeInspection?.preview == nil && workspace.openPostgresTypeSQLDraft() == nil)
        let second = Task { await workspace.previewPostgresTypeChange(TypeChange(operation: "renameType", newName: "hold-preview")) }
        try await fixture.waitForCatalog("typeDDL", count: 2)
        var settings = fixture.profile.settings(password: "")
        settings.policy.readOnly = true
        try #require(await workspace.library.saveConnection(name: fixture.profile.name, settings: settings, id: fixture.profile.id))
        await second.value
        #expect(workspace.typeInspection?.preview == nil && workspace.typeInspection?.previewError == nil)
        #expect(workspace.typeInspection?.invalidationReason != nil && workspace.openPostgresTypeSQLDraft() == nil)
        await fixture.finish()
    }

    @Test func emptyPartialAndUnavailableMetadataAreDistinct() async throws {
        let fixture = try await PostgresTypeTestFixture.make()
        try await fixture.connect()
        let workspace = fixture.workspace
        await workspace.inspect(fixture.node("empty_type"))
        #expect(workspace.typeInspection?.enumValues == [] && workspace.typeInspection?.enumValuesComplete == true)
        #expect(workspace.typeInspection?.dependencies == [] && workspace.typeInspection?.dependenciesComplete == true)
        await workspace.inspect(fixture.node("partial_type"))
        #expect(workspace.typeInspection?.enumValues?.isEmpty == false && workspace.typeInspection?.enumValuesComplete == false)
        #expect(workspace.typeInspection?.dependencies?.isEmpty == false && workspace.typeInspection?.dependenciesComplete == false)
        await workspace.inspect(fixture.node("partial_empty_type"))
        #expect(workspace.typeInspection?.enumValues == [] && workspace.typeInspection?.enumValuesComplete == false)
        #expect(workspace.typeInspection?.dependencies == [] && workspace.typeInspection?.dependenciesComplete == false)
        await workspace.inspect(fixture.node("values-denied"))
        #expect(workspace.typeInspection?.enumValues == nil && workspace.typeInspection?.enumValuesError != nil)
        #expect(workspace.typeInspection?.dependencies != nil && workspace.typeInspection?.dependenciesComplete == true)
        await workspace.inspect(fixture.node("denied_type"))
        #expect(workspace.typeInspection?.details == nil && workspace.typeInspection?.metadataError != nil)
        #expect(workspace.typeInspection?.metadataError?.contains("private SQL") == false)
        await workspace.inspect(fixture.node("unavailable_type", kind: "type", typeKind: "base"))
        #expect(workspace.typeInspection?.details?.definitionStatus == .unavailable && workspace.typeInspection?.details?.definition == nil)
        await workspace.previewPostgresTypeChange(TypeChange(operation: "renameType", newName: "blocked"))
        #expect(workspace.typeInspection?.preview == nil && workspace.typeInspection?.previewError != nil)
        await fixture.finish()
    }

    @Test func typeCopyNameUsesValidatedOriginAndNeverConsultsCredentialsAgain() async throws {
        let fixture = try await PostgresTypeTestFixture.make()
        try await fixture.connect()
        let reads = await fixture.credentials.reads
        let node = fixture.node()
        #expect(await fixture.workspace.generatedName(node) == "\"public\".\"status\"")
        let request = try #require(fixture.commands().last { $0.catalog?.kind == "name" })
        #expect(request.catalog?.identity == "40001" && request.sessionId == node.typeOrigin?.serviceSessionID)
        #expect(await fixture.credentials.reads == reads)
        try #require(await fixture.workspace.disconnectProfile(fixture.profile.id))
        #expect(await fixture.workspace.generatedName(node) == nil)
        #expect(try fixture.commands().filter { $0.type == "connect" }.count == 1)
        await fixture.finish()
    }

    @Test func unsupportedEngineDoesNotInspectOrStartHelper() async throws {
        let fixture = try await PostgresTypeTestFixture.make(engine: .mysql)
        await fixture.workspace.inspectPostgresType(fixture.node())
        #expect(fixture.workspace.typeInspection == nil && fixture.workspace.services.isEmpty)
        #expect(try fixture.commands().isEmpty)
        let cassandra = CatalogNode(profileID: UUID(), name: "udt", kind: .object, schema: "ks", objectKind: "type", engine: .cassandra)
        #expect(cassandra.isExpandable && !cassandra.isPostgresType)
        await fixture.finish()
    }
}
