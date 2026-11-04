import Foundation
import Testing
@testable import DBeer

/// Model and pipe-helper checks only; no windows or application activation.
@MainActor
struct SQLiteSessionCompletionTests {
    private func profile() -> SavedConnection {
        SavedConnection(name: "SQLite fixture", settings: ConnectionSettings(host: "", port: 0, database: "", user: "", password: "",
            sslMode: "disable", engine: .sqlite, sqlite: SQLiteSettings(path: "/fixture/local.sqlite")))
    }

    private func metadata(_ names: [(String, String)], sessionID: String = "session", truncated: Bool = false) -> BackendMessage {
        let fields = ["schema", "name", "kind", "columns", "foreignKeys", "signatures", "columnTypes"]
        return BackendMessage(type: "query.result", requestId: "metadata", sessionId: sessionID,
            columns: fields.enumerated().map { ResultColumn(index: $0.offset, name: $0.element, engine: .sqlite, nativeType: "text") },
            rows: names.map { [$0.0, $0.1, "table", "[\"id\"]", "[]", "[]", "{\"id\":\"INTEGER\"}"] }, truncated: truncated)
    }

    @Test func onlyCatalogNeutralStatementsPreserveAnOpenTransactionCache() {
        func statement(_ text: String) -> SQLStatement {
            SQLStatement(sql: text, range: NSRange(location: 0, length: (text as NSString).length))
        }
        for sql in ["BEGIN DEFERRED", "SAVEPOINT edit", "RELEASE edit", "SELECT 'CREATE TABLE ignored'", "WITH x AS (SELECT 1) SELECT * FROM x",
                    "INSERT INTO records VALUES(1)", "UPDATE records SET id=2", "DELETE FROM records", "REPLACE INTO records VALUES(1)", "COMMIT", "END"] {
            #expect(SQLiteSessionCompletionPolicy.preservesCatalog([statement(sql)]))
        }
        for sql in ["CREATE TEMP TABLE changed(id)", "ALTER TABLE records ADD value", "DROP TABLE records", "ATTACH '/fixture/extra.sqlite' AS extra",
                    "DETACH extra", "PRAGMA schema_version=2", "ROLLBACK TO edit", "ROLLBACK TRANSACTION TO SAVEPOINT edit", "ROLLBACK", "UNKNOWN operation"] {
            #expect(!SQLiteSessionCompletionPolicy.preservesCatalog([statement(sql)]))
        }
        #expect(!SQLiteSessionCompletionPolicy.preservesCatalog([statement("BEGIN"), statement("CREATE TABLE changed(id)")]))
    }

    @Test func loaderBoundsPagesAndReportsPartialMetadata() async throws {
        let profile = profile()
        var requests = 0
        let snapshot = try await SQLiteSessionCompletionLoader.load(profile: profile, sessionID: "session", request: { page in
            requests += 1
            return metadata((0..<200).map { ("main", "table_\(page * 200 + $0)") })
        }, isCurrent: { true })
        #expect(requests == 50 && snapshot.context.catalog.count == 10_000)
        #expect(snapshot.notice != nil)
        let partial = try await SQLiteSessionCompletionLoader.load(profile: profile, sessionID: "session", request: { _ in
            metadata([("extra", "visible")], truncated: true)
        }, isCurrent: { true })
        #expect(partial.context.catalog.map(\.name) == ["visible"] && partial.notice != nil)
    }

    @Test func loaderDiscardsStaleResponsesAndKeepsExactProfileBinding() async throws {
        let profile = profile()
        var current = true
        await #expect(throws: CancellationError.self) {
            try await SQLiteSessionCompletionLoader.load(profile: profile, sessionID: "session", request: { _ in
                current = false
                return metadata([("extra", "stale")])
            }, isCurrent: { current })
        }
        let snapshot = try await SQLiteSessionCompletionLoader.load(profile: profile, sessionID: "session",
            request: { _ in metadata([("extra", "current")]) }, isCurrent: { true })
        #expect(snapshot.matches(profile: profile, sessionID: "session"))
        #expect(!snapshot.matches(profile: profile, sessionID: "replacement"))
        var moved = profile
        moved.sqlite = SQLiteSettings(path: "/fixture/replaced.sqlite")
        #expect(!snapshot.matches(profile: moved, sessionID: "session"))
    }

    @Test func loaderRetainsSQLiteSearchOrderAndQualifiedDuplicateNames() async throws {
        let profile = profile()
        let names = [("a_new", "records"), ("main", "records"), ("z_old", "records"), ("temp", "records"), ("z_old", "second")]
        var reply = metadata(names)
        reply.columns?.append(ResultColumn(index: 7, name: "schemaOrder", engine: .sqlite, nativeType: "text"))
        let ranks = [3, 1, 2, 0, 2]
        for index in names.indices {
            reply.rows?[index][3] = "[\"column_\(index)\"]"
            reply.rows?[index].append(String(ranks[index]))
        }
        let ordered = try await SQLiteSessionCompletionLoader.load(profile: profile, sessionID: "session", request: { _ in reply }, isCurrent: { true })
        #expect(ordered.context.catalog.map(\.schema) == ["temp", "main", "z_old", "z_old", "a_new"])
        #expect(ordered.context.catalog.map(\.columns) == [["column_3"], ["column_1"], ["column_2"], ["column_4"], ["column_0"]])
        let legacy = try await SQLiteSessionCompletionLoader.load(profile: profile, sessionID: "session", request: { _ in
            metadata([("z_old", "records"), ("a_new", "records"), ("main", "records"), ("temp", "records")])
        }, isCurrent: { true })
        #expect(legacy.context.catalog.map(\.schema) == ["temp", "main", "z_old", "a_new"])
    }

    @Test func editorLookupDoesNotConnectOrRestoreSessionMetadata() async {
        var launches = 0
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            helperFactory: {
                launches += 1
                return BackendClient(executableURL: URL(fileURLWithPath: "/nonexistent/helper"))
            })
        let document = workspace.newDocument(profileID: UUID(), text: "SELECT * FROM extra.records")
        #expect(workspace.completionContext(document: document).catalog.isEmpty)
        #expect(document.sqliteCompletion == nil && document.runtime == nil && launches == 0)
        await workspace.shutdown()
    }

    private func helper() -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys
        def send(x): print(json.dumps(x),flush=True)
        sessions={}; connected=0
        for line in sys.stdin:
            c=json.loads(line);kind=c['type'];r={'requestId':c['requestId']}
            if kind=='hello':r.update(type='hello.ack',protocolVersion=6)
            elif kind=='connect':
                connected+=1;sid='session-'+str(connected);sessions[sid]=0
                r.update(type='connect.result',sessionId=sid,engine='sqlite',transactionStatus='transaction',capabilities=['execute','catalog','transactions'])
            elif kind=='catalog':
                sid=c['sessionId'];sessions[sid]+=1
                send(dict(type='query.started',requestId=c['requestId'],sessionId=sid,queryId=c['queryId']))
                names=[('main','records')]
                if sid=='session-1' and sessions[sid]==1:names += [('extra','records'),('temp','scratch')]
                fields=['schema','name','kind','columns','foreignKeys','signatures','columnTypes']
                r.update(type='query.result',sessionId=sid,queryId=c['queryId'],durationMs=0,
                    columns=[dict(index=i,name=n,engine='sqlite',nativeType='text') for i,n in enumerate(fields)],
                    rows=[[s,n,'table','["id"]','[]','[]','{"id":"INTEGER"}'] for s,n in names],
                    commandTag='CATALOG',rowCount=len(names),displayedRowCount=len(names),truncated=False,transactionStatus='transaction')
            elif kind=='disconnect':r.update(type='disconnect.ack',sessionId=c['sessionId'])
            elif kind=='shutdown':
                r.update(type='shutdown.ack');send(r);break
            else:sys.exit(41)
            send(r)
        """])
    }

    private func transactionHelper() -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys
        def send(x): print(json.dumps(x),flush=True)
        sessions={};connected=0
        for line in sys.stdin:
            c=json.loads(line);kind=c['type'];r={'requestId':c['requestId']}
            if kind=='hello':r.update(type='hello.ack',protocolVersion=6)
            elif kind=='connect':
                connected+=1;sid='session-'+str(connected);sessions[sid]='idle'
                r.update(type='connect.result',sessionId=sid,engine='sqlite',transactionStatus='idle',capabilities=['execute','catalog','transactions'])
            elif kind=='operation.assess':
                r.update(type='operation.assessment',sessionId=c['sessionId'],queryId=c['queryId'],assessment=dict(
                    decision='allow',policy={'environment':'unspecified','readOnly':False},authorization='fixture-grant',
                    operations=[dict(kind='read',statements=[dict(start=0,end=len(o['sql']),kind='read',reason='fixture')]) for o in c['operations']]))
            elif kind=='execute' or kind=='catalog':
                sid=c['sessionId'];fields=[];rows=[];tag='OK'
                if kind=='catalog':
                    if sessions[sid]!='idle':sys.exit(45)
                    fields=['schema','name','kind','columns','foreignKeys','signatures','columnTypes']
                    rows=[['main','records','table','["id"]','[]','[]','{"id":"INTEGER"}']]
                    tag='CATALOG'
                else:
                    token=c['sql'].strip().split()[0].upper()
                    if token=='BEGIN':sessions[sid]='transaction'
                    elif token=='ROLLBACK' and 'TO' not in c['sql'].upper():sessions[sid]='idle'
                send(dict(type='query.started',requestId=c['requestId'],sessionId=sid,queryId=c['queryId']))
                r.update(type='query.result',sessionId=sid,queryId=c['queryId'],durationMs=0,
                    columns=[dict(index=i,name=n,engine='sqlite',nativeType='text') for i,n in enumerate(fields)],rows=rows,
                    commandTag=tag,rowCount=len(rows),displayedRowCount=len(rows),truncated=False,transactionStatus=sessions[sid])
            elif kind=='cancel':r.update(type='cancel.ack',sessionId=c['sessionId'],queryId=c['queryId'],status='alreadyFinished')
            elif kind=='disconnect':r.update(type='disconnect.ack',sessionId=c['sessionId'])
            elif kind=='shutdown':r.update(type='shutdown.ack');send(r);break
            else:sys.exit(41)
            send(r)
        """])
    }

    @Test func automaticBeginDoesNotReadCatalogAndRollbackToCannotRestoreStaleNames() async throws {
        let profile = profile()
        let client = transactionHelper()
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id)), credentialStore: MemoryConnectionCredentialStore(),
            closeDecision: { _ in .discard }, executionDecision: { _ in true }, helperFactory: { client })
        await workspace.library.loadConnections()
        let document = workspace.newDocument(profileID: profile.id, text: "SELECT 1")
        func run(_ sql: String) async throws {
            document.text = sql
            await workspace.run(document, sql: sql)
            try #require(document.localError == nil && document.runtime?.queryFailure == nil)
        }
        do {
            try await run("SELECT 1")
            let before = try #require(document.sqliteCompletion).context
            try await run("BEGIN DEFERRED")
            #expect(document.runtime?.transactionStatus == .transaction)
            #expect(document.sqliteCompletion?.context == before && document.sqliteCompletionNotice == nil)
            try await run("SELECT 2")
            try await run("SAVEPOINT edit")
            #expect(document.sqliteCompletion?.context == before)
            try await run("CREATE TEMP TABLE changed(id)")
            #expect(document.sqliteCompletion == nil && document.sqliteCompletionNotice != nil)
            #expect(workspace.completionContext(document: document).catalog.isEmpty)
            try await run("ROLLBACK TO edit")
            #expect(document.sqliteCompletion == nil && workspace.completionContext(document: document).catalog.isEmpty)
            try await run("SELECT 3")
            #expect(document.sqliteCompletion == nil)
            try await run("ROLLBACK")
            #expect(document.sqliteCompletion?.context == before && document.sqliteCompletionNotice == nil)
            await workspace.shutdown()
        } catch {
            await workspace.shutdown()
            _ = await client.shutdown()
            throw error
        }
    }

    @Test func pipeMetadataIsTabLocalReplacesDetachedNamesAndLeavesResultsUntouched() async throws {
        let profile = profile()
        let store = MemoryConnectionLibraryStore(library: SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id))
        let secrets = MemoryConnectionCredentialStore()
        let client = helper()
        try await client.start()
        let workspace = ApplicationWorkspace(connectionStore: store, credentialStore: secrets, helperFactory: {
            Issue.record("Completion must reuse the supplied helper")
            return client
        })
        await workspace.library.loadConnections()
        let first = workspace.newDocument(profileID: profile.id, text: "SELECT * FROM extra.records")
        let second = workspace.newDocument(profileID: profile.id, text: "SELECT * FROM main.records")
        for document in [first, second] {
            let runtime = WorkspaceModel(connectionStore: store, credentialStore: secrets)
            document.attach(runtime)
            await runtime.start(sharedHelper: client)
            await runtime.connectSavedConnection(profile.id)
            try #require(runtime.connectionState == .connected)
        }
        await workspace.refreshSQLiteSessionCompletion(first, client: client, allowOpenTransaction: true)
        #expect(Set(workspace.completionContext(document: first).catalog.map(\.schema)) == ["main", "extra", "temp"])
        #expect(workspace.completionContext(document: second).catalog.isEmpty)
        #expect(workspace.completionContext(profileID: profile.id).catalog.isEmpty)
        #expect(first.runtime?.transactionStatus == .transaction && first.runtime?.result == nil)
        #expect(first.text == "SELECT * FROM extra.records" && first.executions.isEmpty)
        await workspace.refreshSQLiteSessionCompletion(second, client: client, allowOpenTransaction: true)
        #expect(workspace.completionContext(document: second).catalog.map(\.schema) == ["main"])
        await workspace.refreshSQLiteSessionCompletion(first, client: client, allowOpenTransaction: true)
        #expect(workspace.completionContext(document: first).catalog.map(\.schema) == ["main"])
        first.sqliteCompletion = nil
        first.sqliteCompletionNotice = "Previous refresh failed"
        let previousLoad = first.sqliteCompletionLoadID
        await first.runtime?.disconnect()
        #expect(first.sqliteCompletion == nil && first.sqliteCompletionNotice == nil)
        #expect(first.sqliteCompletionLoadID != previousLoad)
        #expect(workspace.completionContext(document: first).catalog.isEmpty)
        await second.runtime?.disconnect()
        _ = await client.shutdown()
        await workspace.shutdown()
    }

    @Test func realWorkspaceRefreshesAttachmentsAndTempOnlyAfterExplicitSQL() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/sqlite/completion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var profile = profile()
        profile.sqlite = SQLiteSettings(path: directory.appendingPathComponent("main.sqlite").path)
        var extra = profile.settings(password: "")
        extra.sqlite = SQLiteSettings(path: directory.appendingPathComponent("extra.sqlite").path)
        let executable = repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let creator = BackendClient(executableURL: executable)
        do {
            try await creator.start()
            _ = try await creator.request(.sqliteCreate(profile.settings(password: "")))
            _ = try await creator.request(.sqliteCreate(extra))
        } catch {
            _ = await creator.shutdown()
            throw error
        }
        _ = await creator.shutdown()
        // ApplicationWorkspace owns starting its helper; never pass a process
        // that has already completed its handshake to helperFactory.
        let client = BackendClient(executableURL: executable)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id)), credentialStore: MemoryConnectionCredentialStore(),
            closeDecision: { _ in .discard }, executionDecision: { _ in true }, helperFactory: { client })
        await workspace.library.loadConnections()
        let first = workspace.newDocument(profileID: profile.id, text: "SELECT 1")
        let second = workspace.newDocument(profileID: profile.id, text: "SELECT 2")
        var executionStep = 0
        func run(_ document: SQLDocument, _ sql: String) async throws {
            executionStep += 1
            document.text = sql
            await workspace.run(document, sql: sql)
            let diagnostic = document.localError ?? document.runtime?.queryFailure?.category ?? "none"
            try #require(document.localError == nil && document.runtime?.queryFailure == nil,
                "SQLite completion execution step \(executionStep) failed: \(diagnostic)")
            try #require(!document.isRunning && document.sqliteCompletionNotice == nil)
        }
        do {
            try await run(first, "CREATE TABLE records(id INTEGER PRIMARY KEY)")
            let path = extra.sqlite!.path.replacingOccurrences(of: "'", with: "''")
            try await run(first, "ATTACH DATABASE '\(path)' AS extra")
            try await run(first, "CREATE TABLE extra.records(id INTEGER PRIMARY KEY)")
            try await run(first, "CREATE TEMP TABLE scratch(id INTEGER)")
            let beforeTransaction = try #require(first.sqliteCompletion).context
            try await run(first, "BEGIN")
            #expect(first.runtime?.transactionStatus == .transaction)
            #expect(first.sqliteCompletion?.context == beforeTransaction)
            #expect(Set(workspace.completionContext(document: first).catalog.map(\.schema)) == ["main", "temp", "extra"])
            #expect(first.executions.first?.result?.commandTag == "OK")
            // A deferred transaction must not read schema metadata before the
            // user's first SELECT: that would take a snapshot and block this
            // independent writer's autocommit on the default rollback journal.
            let writer = try await client.request(.connect(profile.settings(password: "")))
            let writerSession = try #require(writer.sessionId)
            #expect(writerSession != first.runtime?.sessionId)
            let writerSQL = "INSERT INTO main.records(id) VALUES(77)"
            let review = try await client.request(.assess(sessionId: writerSession,
                operations: [OperationRequest(type: "execute", sql: writerSQL)]))
            var insertion = BackendCommand.execute(sessionId: writerSession, sql: writerSQL)
            insertion.authorization = try #require(review.assessment?.authorization)
            let inserted = try await client.request(insertion)
            #expect(inserted.transactionStatus == .idle)
            _ = try await client.request(.disconnect(sessionId: writerSession))
            try await run(first, "SELECT id FROM main.records")
            #expect(first.runtime?.result?.rows == [["77"]])
            #expect(first.runtime?.transactionStatus == .transaction)
            #expect(first.sqliteCompletion?.context == beforeTransaction)
            try await run(second, "SELECT 2")
            #expect(workspace.completionContext(document: second).catalog.map(\.schema) == ["main"])
            try await run(first, "ROLLBACK")
            try await run(first, "DETACH extra")
            #expect(Set(workspace.completionContext(document: first).catalog.map(\.schema)) == ["main", "temp"])
            first.stopRequested = true
            await workspace.loadSchemas(profile.id, refresh: true)
            #expect(!first.stopRequested && first.sqliteCompletion != nil)
            #expect(Set(workspace.completionContext(document: first).catalog.map(\.schema)) == ["main", "temp"])
            await workspace.shutdown()
        } catch {
            await workspace.shutdown()
            _ = await client.shutdown()
            throw error
        }
    }
}
