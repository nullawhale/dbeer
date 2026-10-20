import AppKit
import Foundation
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct CassandraNativeTests {
    private func settings(password: String = "") -> ConnectionSettings {
        ConnectionSettings(host: "node-a", port: 9042, database: "", user: "", password: password,
            sslMode: "verify-full", engine: .cassandra, contactPoints: ["node-a", "node-b"],
            localDatacenter: "dc1", consistency: "LOCAL_QUORUM")
    }

    @Test func draftUsesOptionalKeyspaceAndAuthenticationAndSecureDefaults() throws {
        var draft = ConnectionDraft(connection: nil)
        draft.selectEngine(.cassandra)
        draft.name = "Cluster"
        draft.host = "node-a, node-b"
        #expect(draft.port == "9042" && draft.database.isEmpty && draft.user.isEmpty)
        #expect(draft.sslMode == "verify-full" && draft.isValid)
        let connection = try #require(draft.settings)
        #expect(connection.contactPoints == ["node-a", "node-b"])
        #expect(connection.consistency == "LOCAL_QUORUM")
        draft.password = "only-in-keychain"
        #expect(!draft.isValid)
        draft.user = "reader"
        #expect(draft.isValid)
        draft.consistency = "unsupported"
        #expect(!draft.isValid)
    }

    @Test func profileRoundTripKeepsTopologyAndNeverTransfersSecrets() async throws {
        let secret = "cassandra-secret-fixture"
        var connection = settings(password: secret)
        connection.user = "reader"
        let profile = SavedConnection(name: "Cluster", settings: connection)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("connections.json")
        let store = FileConnectionLibraryStore(fileURL: url)
        try await store.save(SavedConnectionLibrary(connections: [profile]))
        let loaded = try await store.load()
        #expect(loaded.connections == [profile])
        #expect(loaded.connections[0].settings(password: secret) == connection)
        let exported = try ProfileTransfer.encode([profile])
        let text = String(decoding: exported, as: UTF8.self)
        #expect(!text.contains(secret) && !text.contains("password") && !text.contains("privateKey"))
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(secret))
        let imported = try #require(ProfileTransfer.preview(exported).first)
        #expect(imported.profile.id != profile.id)
        #expect(imported.profile.settings(password: secret) == connection)
    }

    @Test func cqlBatchesRetainInternalSemicolonsAndUseNativeRanges() throws {
        let batch = "BEGIN UNLOGGED BATCH\nINSERT INTO items (id, label) VALUES (1, 'a; b');\n// no split;\nUPDATE items SET label = 'next' WHERE id = 1;\nAPPLY BATCH"
        let text = "USE work;\n" + batch + "; SELECT * FROM items;"
        let parsed = SQLScriptParser.parse(text, engine: .cassandra)
        #expect(parsed.diagnostics.isEmpty && parsed.statements.count == 3)
        #expect(parsed.statements[1].sql == batch)
        let cursor = (text as NSString).range(of: "UPDATE").location
        #expect(parsed.statement(atUTF16: cursor)?.sql == batch)
        #expect(parsed.tokens.contains { $0.kind == .keyword && (text as NSString).substring(with: $0.range) == "UNLOGGED" })
        let unterminated = SQLScriptParser.parse("BEGIN BATCH INSERT INTO items (id) VALUES (1);", engine: .cassandra)
        #expect(unterminated.diagnostics.count == 1)
        let function = SQLScriptParser.parse("CREATE FUNCTION f() RETURNS NULL ON NULL INPUT RETURNS int LANGUAGE java AS $$ return 1; $$; SELECT 1;", engine: .cassandra)
        #expect(function.statements.count == 2 && function.diagnostics.isEmpty)
    }

    @Test func cursorsResetWithFiltersAndSortAndGridCannotBeEdited() {
        let document = SQLDocument()
        document.page = 3
        document.tableCursor = "opaque-current"
        document.tableNextCursor = "opaque-next"
        document.tableFilters = [CatalogFilter(column: "tenant", operator: "eq", value: "one")]
        #expect(document.page == 0 && document.tableCursor == nil && document.tableNextCursor == nil)
        document.tableNextCursor = "another"
        document.tableSort = [CatalogSort(column: "time", direction: "desc")]
        #expect(document.tableNextCursor == nil)
        let table = TableReference(schema: "work", name: "items", kind: "table")
        let grid = GridDraft(reference: table, result: BackendMessage(type: "query.result", requestId: "test",
            columns: [ResultColumn(index: 0, name: "id", engine: .cassandra, nativeType: "int")], rows: [["1"]]),
            metadata: [["name": "id", "primaryKey": "1", "editable": "true"]])
        grid.supportsEditing = false
        #expect(!grid.canEdit && grid.readOnlyReason?.contains("not supported") == true)
        grid.insert()
        grid.set(ChangeValue(kind: "text", value: "2"), row: 0, column: 0)
        #expect(grid.pendingCount == 0 && grid.rows.count == 1)
    }

    @Test func generatedFiltersAndSortRequireCompleteKeys() {
        let document = SQLDocument()
        document.tableColumns = [["name": "tenant", "nativeType": "text", "partitionKeyPosition": "1"],
            ["name": "bucket", "nativeType": "text", "partitionKeyPosition": "2"],
            ["name": "time", "nativeType": "text", "clusteringPosition": "1"],
            ["name": "id", "nativeType": "text", "clusteringPosition": "2"],
            ["name": "label"], ["name": "tag", "nativeType": "text", "indexed": "true"]]
        document.tableFilters = [CatalogFilter(column: "tenant", operator: "eq", value: "one")]
        #expect(!CassandraBrowseRules.canApplyFilters(document))
        #expect(!CassandraBrowseRules.canSort("time", in: document))
        document.tableFilters.append(CatalogFilter(column: "bucket", operator: "eq", value: "two"))
        #expect(CassandraBrowseRules.canApplyFilters(document))
        #expect(CassandraBrowseRules.canSort("time", in: document))
        #expect(!CassandraBrowseRules.canSort("id", in: document))
        document.tableFilters.append(CatalogFilter(column: "time", operator: "eq", value: "three"))
        #expect(CassandraBrowseRules.canSort("id", in: document))
        #expect(!CassandraBrowseRules.canFilter(document.tableColumns[4], in: document))
        #expect(CassandraBrowseRules.canFilter(document.tableColumns[5], in: document))
    }

    @Test func completionPreservesKeyMetadataAndUserDefinedTypes() throws {
        let id = UUID()
        var catalog = SQLCompletionCatalog()
        catalog.record([["schema": "work", "name": "items", "kind": "table"]], request: CatalogRequest(kind: "objects", schema: "work", objectKind: "table"), profileID: id)
        catalog.record([["name": "tenant", "nativeType": "text", "partitionKeyPosition": "1"], ["name": "time", "nativeType": "text", "clusteringPosition": "1"],
            ["name": "label", "static": "true"]], request: CatalogRequest(kind: "columns", schema: "work", object: "items", objectKind: "table"), profileID: id)
        catalog.record([["schema": "work", "name": "address", "kind": "type"]], request: CatalogRequest(kind: "objects", schema: "work", objectKind: "type"), profileID: id)
        let relations = catalog.context(profileID: id).catalog
        let relation = try #require(relations.first { $0.name == "items" })
        #expect(relation.partitionKeys == ["tenant"] && relation.clusteringColumns == ["time"] && relation.staticColumns == ["label"])
        let wire = SQLLanguageService.boundedCatalog(relations)
        let item = try #require(wire.first { $0["name"]?.string == "items" })
        #expect(item["partitionKeys"]?.array?.first?.string == "tenant")
        #expect(wire.contains { $0["kind"]?.string == "type" })
    }
    @Test func scalarGridStagesMultipleRowsAndDisablesUnsupportedOperations() throws {
        let columns = [ResultColumn(index: 0, name: "id", engine: .cassandra, nativeType: "int"),
            ResultColumn(index: 1, name: "label", engine: .cassandra, nativeType: "text")]
        let metadata = [["name": "id", "primaryKey": "1", "editable": "false", "nullable": "false"],
            ["name": "label", "editable": "true", "nullable": "true"]]
        let grid = GridDraft(reference: TableReference(schema: "work", name: "items", kind: "table"),
            result: BackendMessage(type: "query.result", requestId: "grid", columns: columns, rows: [["1", "one"], ["2", "two"]]), metadata: metadata)
        #expect(grid.canEdit && !grid.supportsRowInsertionAndDeletion)
        let policy = GridColumnEditing(column: columns[1], metadata: metadata[1])
        #expect(policy.allowsNull && policy.allowsEmptyString && !policy.allowsDefault)
        grid.insert()
        grid.selectedRows = IndexSet(integer: 0)
        grid.deleteSelected()
        grid.set(ChangeValue(kind: "text", value: "changed-key"), row: 0, column: 0)
        grid.set(.default, row: 0, column: 1)
        #expect(grid.pendingCount == 0 && grid.rows.count == 2)
        grid.set(ChangeValue(kind: "text", value: ""), row: 0, column: 1)
        grid.set(.null, row: 1, column: 1)
        #expect(grid.pendingCount == 2 && grid.rows[1].values[1] == .null)
        #expect(grid.error == nil)
        let change = try #require(grid.request().changes.first)
        #expect(change.kind == "update" && change.values?.first?.value.value == "")
        #expect(change.original?[1].value == "one")
        grid.discard()
        #expect(grid.rows[0].values[1].value == "one" && grid.rows[1].values[1].value == "two")
        grid.set(.null, row: 1, column: 1)
        #expect(grid.request().changes.first?.values?.first?.value == .null)
        grid.policyReadOnly = true
        grid.set(ChangeValue(kind: "text", value: "blocked"), row: 1, column: 1)
        #expect(grid.rows[1].values[1] == .null)
    }

    @Test func gridPreviewAndApplyKeepTopologyAndRestartCursorPaging() async throws {
        let profile = SavedConnection(name: "Cluster", settings: settings())
        let store = MemoryConnectionLibraryStore(library: SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id))
        let workspace = ApplicationWorkspace(connectionStore: store, credentialStore: MemoryConnectionCredentialStore(),
            helperFactory: { sessionHelper(editing: true) })
        await workspace.start()
        let document = workspace.newDocument(profileID: profile.id)
        document.table = TableReference(schema: "work", name: "items", kind: "table")
        await workspace.run(document)
        let grid = try #require(document.grid)
        #expect(grid.canEdit && document.runtime?.supportsGridEditing == true)
        grid.set(ChangeValue(kind: "text", value: "updated"), row: 0, column: 1)
        await workspace.previewGrid(document)
        #expect(grid.preview?.commandTag == "PREVIEW" && grid.error == nil)
        document.tableCursor = "already-consumed"
        document.page = 1
        #expect(await workspace.applyGrid(document))
        #expect(document.page == 0 && document.tableCursor == nil)
        #expect(document.grid?.displayedRows == [["first", "updated", "one"], ["second", "original-two", "one"], ["third", "original-three", "one"]])
        #expect(document.grid?.pendingCount == 0 && document.grid?.notice == "APPLY 1")
        await workspace.shutdown()
    }

    @Test func atomicApplyRetainsEveryDraftOnFailureAndBlocksUncertainBatches() async throws {
        for failure in ["", "conflict", "timeout", "partition"] {
            let profile = SavedConnection(name: "Cluster", settings: settings())
            let store = MemoryConnectionLibraryStore(library: SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id))
            let workspace = ApplicationWorkspace(connectionStore: store, credentialStore: MemoryConnectionCredentialStore(),
                helperFactory: { sessionHelper(editing: true, applyFailure: failure) })
            await workspace.start()
            let document = workspace.newDocument(profileID: profile.id)
            document.table = TableReference(schema: "work", name: "items", kind: "table")
            await workspace.run(document)
            let grid = try #require(document.grid)
            for row in 0..<3 { grid.set(ChangeValue(kind: "text", value: "updated-\(row)"), row: row, column: 1) }
            #expect(grid.pendingCount == 3)
            let request = grid.request()
            await workspace.previewGrid(document)
            if failure == "partition" {
                #expect(grid.preview == nil && grid.error != nil)
            } else {
                #expect(grid.preview?.rows?.count == 1 && grid.preview?.catalogRecords.first?["sql"]?.contains("BEGIN BATCH") == true)
            }
            let savedID = grid.rows[0].id
            let succeeded = await workspace.applyGrid(document)
            #expect(succeeded == failure.isEmpty)
            if failure.isEmpty {
                #expect(document.grid?.pendingCount == 0 && document.grid?.notice == "APPLY 3")
                #expect(document.grid?.displayedRows == [["first", "updated-0", "one"], ["second", "updated-1", "one"], ["third", "updated-2", "one"]])
            } else {
                #expect(document.grid === grid && grid.pendingCount == 3 && grid.rows[0].id == savedID)
                #expect(grid.rows[0].original?[1].value == "original" && !grid.rows[0].assignments.isEmpty)
                #expect(grid.request() == request)
                #expect(grid.outcomeUnknown == (failure == "timeout"))
                #expect(grid.canEdit == (failure != "timeout"))
                #expect(grid.preview == nil && grid.notice == nil)
            }
            await workspace.shutdown()
        }
    }

    private func sessionHelper(editing: Bool = false, applyFailure: String = "") -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        sessions = {}
        serial = 0
        cursors = set()
        consumed = set()
        browse_serial = 0
        editing = \(editing ? "True" : "False")
        saved_labels = {'first':'original','second':'original-two','third':'original-three'}
        apply_failure = '\(applyFailure)'
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            reply = {'requestId':command['requestId']}
            if kind == 'hello':
                reply.update(type='hello.ack', protocolVersion=4)
            elif kind == 'connect':
                serial += 1
                session = 'cassandra-session-' + str(serial)
                sessions[session] = command['connection']['database']
                reply.update(type='connect.result', engine='cassandra', capabilities=['execute','cancel','catalog','localReadOnly','cursorPagination'] + (['gridEditing'] if editing else []), sessionId=session, transactionStatus='unsupported', currentKeyspace=sessions[session])
            elif kind == 'operation.assess':
                reply.update(type='operation.assessment', sessionId=command['sessionId'], queryId=command['queryId'],
                    assessment={'decision':'allow','policy':{'environment':'unspecified','readOnly':False},
                    'operations':[{'kind':'write','statements':[]} for op in command['operations']], 'authorization':'grid-grant'})
            elif kind in ['changes.preview','changes.apply']:
                reply.update(type='query.result', sessionId=command['sessionId'], queryId=command['queryId'], transactionStatus='unsupported', durationMs=1, truncated=False, columns=[], rows=[], rowCount=1, displayedRowCount=0, commandTag='APPLY 1')
                if kind == 'changes.preview':
                    names = ['operation','sql','parameters']
                    sql = 'BEGIN BATCH ' + '; '.join('UPDATE work.items SET label = ? WHERE tenant = ? AND id = ? IF label = ?' for change in command['changes']['changes']) + '; APPLY BATCH'
                    rows = [['atomic update',sql,'[]']]
                    reply.update(columns=[{'index':i,'name':name,'engine':'cassandra','nativeType':'text'} for i,name in enumerate(names)], rows=rows, rowCount=len(rows), displayedRowCount=len(rows), commandTag='PREVIEW')
                    if apply_failure == 'partition':
                        reply.update(type='error',category='validation',message='Atomic Apply requires a single partition. No changes were applied.',connected=True,outcomeUnknown=False)
                else:
                    assert command.get('authorization') == 'grid-grant'
                    changes = command['changes']['changes']
                    if apply_failure:
                        reply.update(type='error', category=apply_failure, message='The atomic batch was not confirmed.', connected=True, outcomeUnknown=apply_failure=='timeout')
                        if apply_failure != 'timeout': reply.update(appliedChangeCount=0)
                    else:
                        for change in changes:
                            saved_labels[change['original'][0]['value']] = change['values'][0]['value'].get('value')
                        reply.update(rowCount=len(changes), appliedChangeCount=len(changes), commandTag='APPLY '+str(len(changes)))
            elif kind == 'catalog':
                session = command['sessionId']
                request = command['catalog']
                reply.update(type='query.result', sessionId=session, queryId=command['queryId'], transactionStatus='unsupported', durationMs=1, columns=[], rows=[], rowCount=0, displayedRowCount=0, truncated=False, commandTag='CATALOG')
                if request['kind'] == 'columns':
                    names = ['name','nativeType','primaryKey','partitionKeyPosition','editable']
                    reply.update(columns=[{'index':i,'name':name,'engine':'cassandra','nativeType':'text'} for i,name in enumerate(names)], rows=[['id','text','1','1','false']], rowCount=1, displayedRowCount=1)
                    if editing:
                        reply['rows'][0][2:4] = ['2','0']
                        reply['rows'].append(['label','text','0','0','true'])
                        reply['rows'].append(['tenant','text','1','1','false'])
                        reply.update(rowCount=3, displayedRowCount=3)
                elif request['kind'] == 'browse':
                    cursor = request.get('cursor')
                    if cursor and (cursor not in cursors or cursor in consumed):
                        reply.update(type='error', category='cursor', message='Consumed cursor.', connected=True)
                    else:
                        if cursor: consumed.add(cursor)
                        browse_serial += 1
                        next_cursor = 'cursor-' + str(browse_serial)
                        cursors.add(next_cursor)
                        reply.update(columns=[{'index':0,'name':'id','engine':'cassandra','nativeType':'text'}], rows=[['next' if cursor else 'first']], rowCount=1, displayedRowCount=1, nextCursor=next_cursor)
                        if editing:
                            reply['columns'].append({'index':1,'name':'label','engine':'cassandra','nativeType':'text'})
                            reply['columns'].append({'index':2,'name':'tenant','engine':'cassandra','nativeType':'text'})
                            reply.update(rows=[[key,value,'one'] for key,value in saved_labels.items()], rowCount=3, displayedRowCount=3)
            elif kind == 'execute':
                session = command['sessionId']
                sql = command['sql'].strip().rstrip(';')
                if sql.startswith('USE '): sessions[session] = sql[4:]
                reply.update(sessionId=session, queryId=command['queryId'], transactionStatus='unsupported', currentKeyspace=sessions[session])
                if sql.startswith('UPDATE '):
                    reply.update(type='error', category='timeout', message='The write response was lost.', connected=True, outcomeUnknown=True)
                else:
                    reply.update(type='query.result', durationMs=1, columns=[], rows=[], rowCount=0, displayedRowCount=0, truncated=False, commandTag='USE' if sql.startswith('USE ') else 'SELECT', affectedRowCountKnown=False)
            elif kind == 'disconnect':
                sessions.pop(command['sessionId'])
                reply.update(type='disconnect.ack', sessionId=command['sessionId'])
            elif kind == 'shutdown':
                reply.update(type='shutdown.ack')
            else: sys.exit(22)
            print(json.dumps(reply), flush=True)
            if kind == 'shutdown': break
        """])
    }

    @Test func keyspaceAndCapabilitiesRemainPerTabAndUncertainWritesStayVisible() async throws {
        let client = sessionHelper()
        try await client.start()
        let profile = SavedConnection(name: "Cluster", settings: settings())
        let store = MemoryConnectionLibraryStore(library: SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id))
        let credentials = MemoryConnectionCredentialStore()
        let first = WorkspaceModel(connectionStore: store, credentialStore: credentials)
        let second = WorkspaceModel(connectionStore: store, credentialStore: credentials)
        await first.start(sharedHelper: client)
        await second.start(sharedHelper: client)
        await first.connectSavedConnection(profile.id)
        await second.connectSavedConnection(profile.id)
        #expect(first.sessionId != second.sessionId && first.connectionState == .connected && second.connectionState == .connected)
        #expect(first.transactionStatus == .unsupported && !first.supportsGridEditing && first.usesCursorPagination)
        #expect(first.readOnlyScope == "Local readonly")
        await first.run(sql: "USE work")
        #expect(first.currentKeyspace == "work" && second.currentKeyspace == "")
        #expect(first.database == "" && first.connectionSummary.contains("work") && first.connectionSummary.contains("LOCAL_QUORUM"))
        await first.run(sql: "UPDATE items SET label = 'next' WHERE id = 1")
        #expect(first.queryFailure?.outcomeUnknown == true && first.errorMessage?.contains("not repeated") == true)
        #expect(first.connectionState == .connected && first.currentKeyspace == "work")
        await first.shutdown()
        await second.run(sql: "USE independent")
        #expect(second.queryFailure == nil && second.currentKeyspace == "independent" && second.connectionState == .connected)
        await second.shutdown()
        _ = await client.shutdown()
    }

    @Test func restoredCassandraDocumentsRemainDisconnected() async throws {
        let profile = SavedConnection(name: "Cluster", settings: settings())
        let document = StoredSQLDocument(title: "Recovered CQL", text: "SELECT * FROM work.items;", profileID: profile.id)
        let store = MemoryConnectionLibraryStore(library: SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id))
        let workspace = ApplicationWorkspace(connectionStore: store, credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(documents: [document], selectedDocumentID: document.id)),
            helperFactory: { sessionHelper() })
        await workspace.start()
        let restored = try #require(workspace.documents.first)
        #expect(restored.id == document.id && restored.profileID == profile.id && restored.runtime == nil)
        #expect(workspace.services.isEmpty)
        #expect(workspace.library.connectionState == .disconnected)
        let fresh = workspace.newDocument(profileID: profile.id)
        #expect(fresh.text.contains("system.local"))
        await workspace.shutdown()
    }

    @Test func nativeValidationMatchesHelperConsistencyAndTopologyBounds() {
        var connection = settings()
        connection.consistency = "ANY"
        #expect(!connection.hasValidNativeFields)
        #expect(!CassandraSettings.consistencyLevels.contains("ANY"))
        connection.consistency = "LOCAL_QUORUM"
        connection.contactPoints = (0..<33).map { "node-\($0)" }
        #expect(!connection.hasValidNativeFields)
        connection.contactPoints?.removeLast()
        #expect(connection.hasValidNativeFields)
        connection.engine = .postgresql
        connection.database = "work"
        connection.user = "reader"
        #expect(!connection.hasValidNativeFields)
    }

    @Test func unsupportedFilterCombinationsCannotApplyAndRemovingKeysClearsSort() {
        let document = SQLDocument()
        document.tableColumns = [["name": "tenant", "nativeType": "text", "partitionKeyPosition": "1"],
            ["name": "time", "nativeType": "text", "clusteringPosition": "1"], ["name": "id", "nativeType": "text", "clusteringPosition": "2"],
            ["name": "tag", "nativeType": "text", "indexed": "true"], ["name": "label", "nativeType": "text", "indexed": "true"]]
        let partition = CatalogFilter(column: "tenant", operator: "eq", value: "one")
        let indexed = CatalogFilter(column: "tag", operator: "eq", value: "tag")
        document.tableFilters = [indexed]
        #expect(CassandraBrowseRules.canApplyFilters(document))
        document.tableFilters.append(CatalogFilter(column: "label", operator: "eq", value: "label"))
        #expect(!CassandraBrowseRules.canApplyFilters(document))
        document.tableFilters = [partition, indexed]
        #expect(!CassandraBrowseRules.canApplyFilters(document))
        document.tableFilters = [partition, CatalogFilter(column: "time", operator: "gt", value: "1"),
            CatalogFilter(column: "time", operator: "gte", value: "2")]
        #expect(!CassandraBrowseRules.canApplyFilters(document))
        document.tableFilters = [partition, CatalogFilter(column: "time", operator: "gt", value: "1"),
            CatalogFilter(column: "time", operator: "lt", value: "5")]
        #expect(CassandraBrowseRules.canApplyFilters(document))
        document.tableFilters.append(CatalogFilter(column: "id", operator: "eq", value: "1"))
        #expect(!CassandraBrowseRules.canApplyFilters(document))
        document.tableFilters = [partition]
        document.tableSort = [CatalogSort(column: "time", direction: "desc")]
        #expect(CassandraBrowseRules.canApplyFilters(document))
        document.tableFilters = []
        #expect(document.tableSort.isEmpty && CassandraBrowseRules.canApplyFilters(document))
    }

    @Test func cassandraLogoLoadsTheOriginalBundledSVG() throws {
        let resource = try #require(DatabaseEngineIcon.resourceURL(for: .cassandra))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let original = root.appendingPathComponent("assets/cassandra-logo.svg")
        #expect(try Data(contentsOf: resource) == Data(contentsOf: original))
        let image = try #require(NSImage(contentsOf: resource))
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    @Test func sharedRefreshCommandDiscardsConsumedCursorWhileNextContinues() async throws {
        let profile = SavedConnection(name: "Cluster", settings: settings())
        let store = MemoryConnectionLibraryStore(library: SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id))
        let workspace = ApplicationWorkspace(connectionStore: store, credentialStore: MemoryConnectionCredentialStore(),
            helperFactory: { sessionHelper() })
        await workspace.start()
        let document = workspace.newDocument(profileID: profile.id)
        document.table = TableReference(schema: "work", name: "items", kind: "table")
        await workspace.run(document)
        #expect(document.grid?.displayedRows == [["first"]])
        let next = try #require(TableBrowseNavigation.nextPage(document: document, workspace: workspace))
        await next.value
        #expect(document.page == 1 && document.grid?.displayedRows == [["next"]])
        #expect(document.tableCursor != nil && document.runtime?.queryFailure == nil)
        let context = AppCommandContext(documentID: document.id, focus: .grid, isWorkspaceWindow: true, hasModal: false)
        let refresh = try #require(workspace.commands.perform(.runCurrent, context: context))
        await refresh.value
        #expect(document.runtime?.queryFailure == nil)
        #expect(document.page == 0 && document.tableCursor == nil)
        #expect(document.grid?.displayedRows == [["first"]])
        await workspace.shutdown()
    }

    @Test func userDefinedTypeExpansionOffersOnlyFields() async throws {
        let profile = SavedConnection(name: "Cluster", settings: settings())
        let store = MemoryConnectionLibraryStore(library: SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id))
        let workspace = ApplicationWorkspace(connectionStore: store, credentialStore: MemoryConnectionCredentialStore(),
            helperFactory: { sessionHelper() })
        await workspace.start()
        let type = CatalogNode(profileID: profile.id, name: "address", kind: .object,
            schema: "work", object: "address", objectKind: "type")
        #expect(type.isExpandable)
        await workspace.expand(type)
        let fields = try #require(type.children?.first)
        #expect(type.children?.count == 1 && fields.name == "Columns" && fields.objectKind == "columns" && fields.identity == "type")
        await workspace.expand(fields)
        #expect(fields.error == nil && fields.children?.map(\.name) == ["id"])
        await workspace.shutdown()
    }

    @Test func generatedFiltersExcludeCompositeAndUnknownKeyTypes() {
        let document = SQLDocument()
        let unsupportedTypes = ["tuple<int, text>", "frozen<tuple<int, text>>", "frozen<address>", "work.address",
            "list<int>", "set<text>", "map<text, int>", "frozen<map<text, int>>", "vector<float, 3>", "custom"]
        for nativeType in unsupportedTypes {
            let key = ["name": "key", "nativeType": nativeType, "partitionKeyPosition": "1", "indexed": "true"]
            document.tableColumns = [key, ["name": "time", "nativeType": "timestamp", "clusteringPosition": "1"]]
            document.tableFilters = [CatalogFilter(column: "key", operator: "eq", value: "value")]
            #expect(!CassandraBrowseRules.canFilter(key, in: document))
            #expect(!CassandraBrowseRules.canApplyFilters(document))
            #expect(!CassandraBrowseRules.canSort("time", in: document))
        }
        #expect(!CassandraBrowseRules.isSupportedFilterType(["name": "missing-type"]))
        for nativeType in ["ascii", "text", "varchar", "int", "bigint", "smallint", "tinyint", "counter", "uuid", "timeuuid", "inet", "date", "duration", "blob", "boolean", "varint", "decimal", "float", "double", "timestamp", "time"] {
            #expect(CassandraBrowseRules.isSupportedFilterType(["nativeType": nativeType]))
        }
    }

}
