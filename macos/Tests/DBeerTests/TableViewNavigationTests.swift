import Foundation
import Testing
@testable import DBeer

/// Model state, isolated persistence and protocol subprocesses only. These
/// tests do not create windows, controls or desktop input.
@Suite(.serialized)
@MainActor
struct TableViewNavigationTests {
    private final class Evidence {
        let directory: URL
        var mode: URL { directory.appendingPathComponent("mode") }
        var entered: URL { directory.appendingPathComponent("entered") }
        var release: URL { directory.appendingPathComponent("release") }
        init() throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            directory = root.appendingPathComponent("build/r10/fixtures/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try setMode("normal")
        }
        func setMode(_ value: String) throws { try Data(value.utf8).write(to: mode, options: .atomic) }
        func unblock() { FileManager.default.createFile(atPath: release.path, contents: Data()) }
        func events() throws -> [String] {
            try String(contentsOf: directory.appendingPathComponent("events"), encoding: .utf8).split(separator: "\n").map(String.init)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func client(_ evidence: Evidence) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time
        from pathlib import Path
        directory = Path(sys.argv[1])
        connections = 0
        customer = '9007199254740993'
        note = 'original'
        def record(label):
            with (directory / 'events').open('a') as output: output.write(label+'\\n')
        def send(value): print(json.dumps(value),flush=True)
        def columns(names): return [dict(index=i,name=name,engine='postgresql',nativeType='text') for i,name in enumerate(names)]
        def failure(reply, command):
            reply.update(type='error',sessionId=command['sessionId'],queryId=command['queryId'],category='sql',
                message='The target table is unavailable or SELECT access is denied.',sqlState='42501',connected=True,
                outcomeUnknown=False,transactionStatus='idle')
            send(reply)
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            mode = (directory / 'mode').read_text()
            reply = dict(requestId=command['requestId'])
            if kind == 'hello': reply.update(type='hello.ack',protocolVersion=\(BackendProtocol.version))
            elif kind == 'connect':
                connections += 1
                record('connect:'+str(connections))
                reply.update(type='connect.result',sessionId='view-'+str(connections),engine='postgresql',
                    transactionStatus='idle',capabilities=['execute','cancel','catalog','transactions','gridEditing'])
            elif kind == 'operation.assess':
                reply.update(type='operation.assessment',sessionId=command['sessionId'],queryId=command['queryId'],
                    assessment=dict(decision='allow',policy=dict(environment='unspecified',readOnly=False),authorization='fixture-grant',
                        operations=[dict(kind='write',statements=[]) for operation in command['operations']]))
            elif kind in ['catalog','changes.preview','changes.apply']:
                send(dict(type='query.started',requestId=command['requestId'],sessionId=command['sessionId'],queryId=command['queryId']))
                names, rows = [], []
                if kind.startswith('changes.'):
                    record(kind)
                    if kind == 'changes.preview': names,rows = ['sql','parameters'], [['-- fixture preview','[]']]
                    else:
                        for change in command['changes']['changes']:
                            for assignment in change.get('values',[]):
                                if assignment['column'] == 'customer_id': customer = assignment['value'].get('value')
                                elif assignment['column'] == 'note': note = assignment['value'].get('value')
                else:
                    request = command['catalog']
                    operation = request['kind']
                    table = request.get('object','')
                    record(operation+':'+table)
                    if operation == 'columns':
                        if table == 'customers':
                            if mode == 'wait':
                                (directory / 'entered').touch()
                                deadline = time.monotonic()+8
                                while not (directory / 'release').exists() and time.monotonic() < deadline: time.sleep(.005)
                                assert (directory / 'release').exists()
                            if mode == 'denied-columns': failure(reply,command); continue
                            fields = [('tenant','text','1'),('id','bigint','2'),('label','text','0')]
                        else: fields = [('id','bigint','1'),('tenant_id','text','0'),('customer_id','bigint','0'),('note','text','0')]
                        names = ['name','nativeType','nullable','primaryKey','editable']
                        rows = [[name,native,'false',primary,'true'] for name,native,primary in fields]
                        if mode == 'missing-columns' and table == 'customers': rows = []
                    elif operation == 'foreignKeys':
                        names = ['name','targetSchema','targetTable','sourceColumn','targetColumn','position']
                        if table == 'orders':
                            rows = [['orders_customer_fk','linked schema','customers','customer_id','id','2'],
                                    ['orders_customer_fk','linked schema','customers','tenant_id','tenant','1']]
                    elif operation == 'browse':
                        if table == 'customers' and mode in ['wait-browse','denied-browse-wait']:
                            (directory / 'entered').touch()
                            deadline = time.monotonic()+8
                            while not (directory / 'release').exists() and time.monotonic() < deadline: time.sleep(.005)
                            assert (directory / 'release').exists()
                        if mode.startswith('denied-browse') and table == 'customers' or mode == 'denied-orders' and table == 'orders':
                            failure(reply,command); continue
                        if table == 'customers':
                            filters = request.get('filters',[])
                            assert filters[:2] == [dict(column='tenant',operator='eq',value=''),dict(column='id',operator='eq',value=customer)]
                            names,rows = ['tenant','id','label'], [['',customer,'linked']]
                        else:
                            names,rows = ['id','tenant_id','customer_id','note'], [['1','',None if mode == 'null-source' else customer,note]]
                reply.update(type='query.result',sessionId=command['sessionId'],queryId=command['queryId'],transactionStatus='idle',
                    durationMs=1,columns=columns(names),rows=rows,commandTag='SELECT '+str(len(rows)),rowCount=len(rows),
                    displayedRowCount=len(rows),truncated=False)
            elif kind == 'cancel': reply.update(type='cancel.ack',sessionId=command['sessionId'],queryId=command['queryId'],status='alreadyFinished')
            elif kind == 'disconnect':
                record('disconnect:'+command['sessionId'])
                if mode.endswith('delayed-disconnect') and not (directory / 'entered').exists():
                    (directory / 'entered').touch()
                    deadline = time.monotonic()+8
                    while not (directory / 'release').exists() and time.monotonic() < deadline: time.sleep(.005)
                    assert (directory / 'release').exists()
                reply.update(type='disconnect.ack',sessionId=command['sessionId'])
            elif kind == 'shutdown': reply.update(type='shutdown.ack')
            else: sys.exit(42)
            send(reply)
            if kind == 'shutdown': break
        """, evidence.directory.path])
    }

    @MainActor private struct Fixture {
        let workspace: ApplicationWorkspace
        let client: BackendClient
        let evidence: Evidence
        let profile: SavedConnection
        let otherProfile: SavedConnection
        let store: MemorySQLDocumentStore
        var node: CatalogNode {
            CatalogNode(profileID: profile.id, name: "orders", kind: .object, schema: "source schema", objectKind: "table")
        }
        func source() async throws -> SQLDocument {
            let document = try #require(await workspace.openData(node))
            try #require(document.grid != nil && document.localError == nil && document.runtime?.queryFailure == nil)
            try #require(document.tableForeignKeys.count == 1 && document.foreignKeysError == nil)
            return document
        }
        func finish() async {
            await workspace.shutdown()
            #expect(await client.waitForExit().status == 0)
        }
    }

    private func fixture(decision: @escaping @MainActor (WorkspaceCloseIssue) async -> WorkspaceCloseDecision = { _ in .cancel }) async throws -> Fixture {
        let evidence = try Evidence()
        let client = client(evidence)
        let settings = ConnectionSettings(host: "127.0.0.1", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable")
        let profile = SavedConnection(name: "Navigation fixture", settings: settings)
        var other = settings
        other.database = "other_fixture"
        let otherProfile = SavedConnection(name: "Other fixture", settings: other)
        let store = MemorySQLDocumentStore()
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [profile, otherProfile], selectedConnectionId: profile.id)),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store, closeDecision: decision,
            executionDecision: { _ in true }, helperFactory: { client })
        await workspace.start()
        return Fixture(workspace: workspace, client: client, evidence: evidence, profile: profile, otherProfile: otherProfile, store: store)
    }

    @Test func repeatedOpenSelectsExistingWhileNewTabHasIndependentContextAndSession() async throws {
        let fixture = try await fixture()
        let source = try await fixture.source()
        let grid = try #require(source.grid)
        let runtime = try #require(source.runtime)
        source.tableFilters = [CatalogFilter(column: "id", operator: "gte", value: "1")]
        source.tableSort = [CatalogSort(column: "id", direction: "desc")]
        source.page = 6
        grid.set(ChangeValue(kind: "text", value: "draft"), row: 0, column: 3)
        let original = source.storedState
        let events = try fixture.evidence.events()
        #expect(await fixture.workspace.openData(fixture.node) === source)
        #expect(try fixture.evidence.events() == events)
        let duplicate = try #require(await fixture.workspace.openTableInNewTab(source))
        #expect(duplicate !== source && duplicate.tableViewID != source.tableViewID)
        #expect(duplicate.table == source.table && duplicate.tableFilters.isEmpty && duplicate.tableSort.isEmpty && duplicate.page == 0)
        #expect(duplicate.runtime !== runtime && duplicate.runtime?.sessionId != runtime.sessionId)
        #expect(duplicate.grid !== grid && duplicate.grid?.pendingCount == 0 && duplicate.tableBackHistory.isEmpty)
        #expect(source.storedState == original && source.grid === grid && source.runtime === runtime && grid.pendingCount == 1)
        #expect(fixture.workspace.selectedDocumentID == duplicate.id)
        await fixture.finish()
    }

    @Test func compositeFollowAndHistoryPreserveEachViewsBrowsingContext() async throws {
        let fixture = try await fixture()
        let source = try await fixture.source()
        let viewID = source.tableViewID
        let runtime = source.runtime
        source.tableFilters = [CatalogFilter(column: "id", operator: "gte", value: "1")]
        source.tableSort = [CatalogSort(column: "id", direction: "desc")]
        source.page = 3
        let original = source.storedState
        let other = try #require(await fixture.workspace.openTableInNewTab(source))
        let otherGrid = try #require(other.grid)
        otherGrid.set(ChangeValue(kind: "text", value: "other draft"), row: 0, column: 3)
        let otherState = other.storedState
        let key = try #require(source.tableForeignKeys.first)
        let row = try #require(source.grid?.rows.first)
        await fixture.workspace.followForeignKey(key, rowID: row.id, in: source)
        #expect(source.table == key.target && source.tableViewID == viewID && source.runtime === runtime)
        #expect(source.tableFilters == [CatalogFilter(column: "tenant", operator: "eq", value: ""),
            CatalogFilter(column: "id", operator: "eq", value: "9007199254740993")])
        #expect(source.tableBackHistory.count == 1 && source.tableForwardHistory.isEmpty && source.tableNavigationError == nil)
        source.tableFilters.append(CatalogFilter(column: "label", operator: "contains", value: "x"))
        source.tableSort = [CatalogSort(column: "id", direction: "desc")]
        source.page = 4
        let targetState = source.storedState
        await fixture.workspace.navigateTableBack(source)
        #expect(source.storedState == original && source.tableBackHistory.isEmpty && source.tableForwardHistory.count == 1)
        await fixture.workspace.navigateTableForward(source)
        #expect(source.storedState == targetState && source.tableBackHistory.count == 1 && source.tableForwardHistory.isEmpty)
        #expect(other.storedState == otherState && other.grid === otherGrid && otherGrid.pendingCount == 1)
        #expect(other.runtime !== source.runtime && other.runtime?.sessionId != source.runtime?.sessionId)
        await fixture.finish()
    }

    private enum Review: CaseIterable { case cancel, discard, apply }

    @Test(arguments: Review.allCases)
    private func currentViewNavigationUsesExistingDraftReview(_ review: Review) async throws {
        var issues: [WorkspaceCloseIssue] = []
        let fixture = try await fixture { issue in
            issues.append(issue)
            switch review { case .cancel: return .cancel; case .discard: return .discard; case .apply: return .apply }
        }
        let source = try await fixture.source()
        let grid = try #require(source.grid)
        let key = try #require(source.tableForeignKeys.first)
        let row = try #require(grid.rows.first)
        grid.set(ChangeValue(kind: "text", value: "9007199254740995"), row: 0, column: 2)
        grid.set(ChangeValue(kind: "text", value: "edited"), row: 0, column: 3)
        await fixture.workspace.followForeignKey(key, rowID: row.id, in: source)
        #expect(issues == [.changes("orders", count: 1)])
        let events = try fixture.evidence.events()
        switch review {
        case .cancel:
            #expect(source.table?.name == "orders" && source.grid === grid && grid.pendingCount == 1 && source.tableBackHistory.isEmpty)
            #expect(!events.contains("browse:customers"))
        case .discard:
            #expect(source.table == key.target && source.tableFilters.last?.value == "9007199254740993")
            #expect(!events.contains("changes.apply") && source.tableBackHistory.count == 1)
        case .apply:
            #expect(source.table == key.target && source.tableFilters.last?.value == "9007199254740995")
            #expect(events.contains("changes.preview") && events.contains("changes.apply") && source.tableBackHistory.count == 1)
            #expect(source.grid?.pendingCount == 0 && source.tableNavigationError == nil)
        }
        await fixture.finish()
    }

    @Test(arguments: ["denied-columns", "missing-columns", "denied-browse"])
    func unavailableTargetPreservesSourceResultDraftAndHistory(mode: String) async throws {
        let fixture = try await fixture()
        let source = try await fixture.source()
        let grid = try #require(source.grid)
        let state = source.storedState
        let result = source.tableResult
        let key = try #require(source.tableForeignKeys.first)
        let row = try #require(grid.rows.first)
        try fixture.evidence.setMode(mode)
        await fixture.workspace.followForeignKey(key, rowID: row.id, in: source)
        #expect(source.storedState == state && source.grid === grid && source.tableResult == result && source.tableFailure == nil)
        #expect(source.tableBackHistory.isEmpty && source.tableForwardHistory.isEmpty && source.tableNavigationError != nil)
        #expect(source.localError == nil && source.tableForeignKeys == [key] && !source.isNavigatingTable && !grid.isClosing)
        let ids = fixture.workspace.documents.map(\.id)
        let closed = fixture.workspace.closedTabs
        await fixture.workspace.followForeignKey(key, rowID: row.id, in: source, inNewTab: true)
        #expect(fixture.workspace.documents.map(\.id) == ids && fixture.workspace.closedTabs == closed)
        #expect(source.storedState == state && source.grid === grid && source.tableResult == result)
        await fixture.finish()
    }

    @Test func relatedNewTabPreservesUnrelatedPendingEditsAndRejectsEditedOrInsertedKeys() async throws {
        let fixture = try await fixture()
        let source = try await fixture.source()
        let grid = try #require(source.grid)
        let row = try #require(grid.rows.first)
        let key = try #require(source.tableForeignKeys.first)
        grid.set(ChangeValue(kind: "text", value: "local note"), row: 0, column: 3)
        let state = source.storedState
        let runtime = source.runtime
        await fixture.workspace.followForeignKey(key, rowID: row.id, in: source, inNewTab: true)
        let related = try #require(fixture.workspace.selectedDocument)
        #expect(related !== source && related.table == key.target && related.runtime !== runtime)
        #expect(source.storedState == state && source.grid === grid && source.runtime === runtime && grid.pendingCount == 1)
        #expect(source.tableBackHistory.isEmpty && source.tableNavigationError == nil)
        let count = fixture.workspace.documents.count
        grid.set(ChangeValue(kind: "text", value: "9007199254740995"), row: 0, column: 2)
        await fixture.workspace.followForeignKey(key, rowID: row.id, in: source, inNewTab: true)
        #expect(fixture.workspace.documents.count == count && source.tableNavigationError?.contains("Apply or discard") == true)
        grid.insert()
        let insertedRow = grid.rows.first { $0.isInserted }
        let inserted = try #require(insertedRow)
        await fixture.workspace.followForeignKey(key, rowID: inserted.id, in: source, inNewTab: true)
        #expect(fixture.workspace.documents.count == count && source.grid === grid && grid.pendingCount == 2)
        #expect(source.tableNavigationError?.contains("Apply the new row") == true)
        await fixture.finish()
    }

    @Test func nullKeysAndStaleRowsCannotLoadAnUnfilteredTarget() async throws {
        let fixture = try await fixture()
        try fixture.evidence.setMode("null-source")
        let source = try await fixture.source()
        let key = try #require(source.tableForeignKeys.first)
        let grid = try #require(source.grid)
        let row = try #require(grid.rows.first)
        await fixture.workspace.followForeignKey(key, rowID: row.id, in: source)
        #expect(source.tableNavigationError?.contains("NULL") == true && source.grid === grid && source.tableBackHistory.isEmpty)
        await fixture.workspace.followForeignKey(key, rowID: UUID(), in: source)
        #expect(source.tableNavigationError?.contains("row") == true)
        #expect(try !fixture.evidence.events().contains("browse:customers"))
        await fixture.finish()
    }

    @Test func failedRelatedTabCleanupLocksItsRuntimeAndPreservesLaterSelection() async throws {
        let fixture = try await fixture()
        let source = try await fixture.source()
        let other = fixture.workspace.newDocument(text: "SELECT 'other view';")
        fixture.workspace.selectedDocumentID = source.id
        let sourceState = source.storedState
        let sourceGrid = source.grid
        let key = try #require(source.tableForeignKeys.first)
        let row = try #require(source.grid?.rows.first)
        let originalIDs = Set(fixture.workspace.documents.map(\.id))
        try fixture.evidence.setMode("denied-browse-delayed-disconnect")
        let navigation = Task { await fixture.workspace.followForeignKey(key, rowID: row.id, in: source, inNewTab: true) }
        defer { fixture.evidence.unblock() }
        try await eventually { FileManager.default.fileExists(atPath: fixture.evidence.entered.path) }
        let target = try #require(fixture.workspace.documents.first { !originalIDs.contains($0.id) })
        #expect(!fixture.workspace.canStartOperation(target))
        #expect(fixture.workspace.selectedDocumentID == source.id)
        await fixture.workspace.flushDocuments()
        let pending = await fixture.store.load()
        #expect(Set(pending.documents.map(\.id)) == originalIDs && pending.selectedDocumentID == source.id)
        let events = try fixture.evidence.events()
        await fixture.workspace.run(target)
        await fixture.workspace.closeDocument(target)
        #expect(try fixture.evidence.events() == events)
        fixture.workspace.selectedDocumentID = other.id
        fixture.evidence.unblock()
        await navigation.value
        #expect(Set(fixture.workspace.documents.map(\.id)) == originalIDs)
        #expect(fixture.workspace.selectedDocumentID == other.id && fixture.workspace.closedTabs.isEmpty)
        #expect(source.storedState == sourceState && source.grid === sourceGrid && source.tableNavigationError != nil)
        await fixture.finish()
    }

    @Test(arguments: [false, true])
    func tentativeLoadsPersistOnlyConfirmedViewsUntilSuccess(inNewTab: Bool) async throws {
        let fixture = try await fixture()
        let source = try await fixture.source()
        let sourceState = source.storedState
        let key = try #require(source.tableForeignKeys.first)
        let row = try #require(source.grid?.rows.first)
        let originalIDs = fixture.workspace.documents.map(\.id)
        try fixture.evidence.setMode("wait-browse")
        let navigation = Task { await fixture.workspace.followForeignKey(key, rowID: row.id, in: source, inNewTab: inNewTab) }
        defer { fixture.evidence.unblock() }
        try await eventually { FileManager.default.fileExists(atPath: fixture.evidence.entered.path) }
        await fixture.workspace.flushDocuments()
        let pending = await fixture.store.load()
        #expect(pending.documents.map(\.id) == originalIDs && pending.documents.first { $0.id == source.id } == sourceState)
        #expect(pending.selectedDocumentID == source.id)
        fixture.evidence.unblock()
        await navigation.value
        await fixture.workspace.flushDocuments()
        let completed = await fixture.store.load()
        if inNewTab {
            #expect(completed.documents.count == originalIDs.count + 1)
            #expect(completed.documents.first { $0.id == source.id } == sourceState)
            let related = try #require(fixture.workspace.selectedDocument)
            #expect(related !== source && related.table == key.target && !related.isProvisionalTableView)
            #expect(completed.selectedDocumentID == related.id && completed.documents.last == related.storedState)
        } else {
            #expect(completed.documents.count == originalIDs.count && source.table == key.target)
            #expect(completed.documents.first { $0.id == source.id } == source.storedState && source.tableNavigationSourceState == nil)
        }
        await fixture.finish()
    }

    @Test(arguments: [false, true])
    func failedTentativeLoadsNeverPersistTheirTargetContext(inNewTab: Bool) async throws {
        let fixture = try await fixture()
        let source = try await fixture.source()
        let state = source.storedState
        let grid = source.grid
        let key = try #require(source.tableForeignKeys.first)
        let row = try #require(source.grid?.rows.first)
        let originalIDs = fixture.workspace.documents.map(\.id)
        try fixture.evidence.setMode("denied-browse-wait")
        let navigation = Task { await fixture.workspace.followForeignKey(key, rowID: row.id, in: source, inNewTab: inNewTab) }
        defer { fixture.evidence.unblock() }
        try await eventually { FileManager.default.fileExists(atPath: fixture.evidence.entered.path) }
        await fixture.workspace.flushDocuments()
        let pending = await fixture.store.load()
        #expect(pending.documents.map(\.id) == originalIDs && pending.documents.first { $0.id == source.id } == state)
        #expect(pending.selectedDocumentID == source.id)
        fixture.evidence.unblock()
        await navigation.value
        await fixture.workspace.flushDocuments()
        let completed = await fixture.store.load()
        #expect(completed.documents.map(\.id) == originalIDs && completed.documents.first { $0.id == source.id } == state)
        #expect(source.storedState == state && source.grid === grid && source.tableNavigationError != nil)
        #expect(source.tableNavigationSourceState == nil && fixture.workspace.documents.allSatisfy { !$0.isProvisionalTableView })
        await fixture.finish()
    }

    @Test func navigationOwnsTheViewUntilPreflightAndReviewFinish() async throws {
        let fixture = try await fixture()
        let source = try await fixture.source()
        let key = try #require(source.tableForeignKeys.first)
        let row = try #require(source.grid?.rows.first)
        let ids = fixture.workspace.documents.map(\.id)
        try fixture.evidence.setMode("wait")
        let navigation = Task { await fixture.workspace.followForeignKey(key, rowID: row.id, in: source) }
        defer { fixture.evidence.unblock() }
        try await eventually { FileManager.default.fileExists(atPath: fixture.evidence.entered.path) }
        #expect(source.isNavigatingTable && !fixture.workspace.canStartOperation(source))
        #expect(!(await fixture.workspace.prepareToClose(.application)))
        #expect(!(await fixture.workspace.prepareToClose(.profile(fixture.profile.id))))
        #expect(!(await fixture.workspace.prepareToClose(.document(source.id))))
        #expect(!(await fixture.workspace.disconnectProfile(fixture.profile.id)))
        await fixture.workspace.clearRestoredDocuments()
        await fixture.workspace.closeDocument(source)
        #expect(fixture.workspace.documents.map(\.id) == ids && source.table?.name == "orders")
        fixture.evidence.unblock()
        await navigation.value
        #expect(source.table == key.target && !source.isNavigatingTable && source.tableNavigationError == nil)
        await fixture.finish()
    }

    @Test func failedBackAfterDisconnectKeepsSourceFeedbackAndHistory() async throws {
        let fixture = try await fixture()
        let source = try await fixture.source()
        let key = try #require(source.tableForeignKeys.first)
        let row = try #require(source.grid?.rows.first)
        await fixture.workspace.followForeignKey(key, rowID: row.id, in: source)
        let state = source.storedState
        let result = source.tableResult
        try #require(await fixture.workspace.disconnectProfile(fixture.profile.id))
        #expect(source.grid == nil && source.runtime == nil)
        try fixture.evidence.setMode("denied-orders")
        await fixture.workspace.navigateTableBack(source)
        #expect(source.storedState == state && source.grid == nil && source.tableResult == result && source.tableFailure == nil)
        #expect(source.tableBackHistory.count == 1 && source.tableForwardHistory.isEmpty && source.tableNavigationError != nil)
        #expect(source.localError == nil)
        await fixture.finish()
    }

    @Test func persistenceRetainsIndependentViewIDsButNoRuntimeOrNavigationHistory() async throws {
        let fixture = try await fixture()
        let source = try await fixture.source()
        let other = try #require(await fixture.workspace.openTableInNewTab(source))
        let key = try #require(source.tableForeignKeys.first)
        let row = try #require(source.grid?.rows.first)
        await fixture.workspace.followForeignKey(key, rowID: row.id, in: source)
        await fixture.workspace.flushDocuments()
        let saved = await fixture.store.load()
        let restoredStore = MemorySQLDocumentStore(snapshot: saved)
        var starts = 0
        let restored = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [fixture.profile, fixture.otherProfile])),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: restoredStore,
            closeDecision: { _ in .cancel }, helperFactory: { starts += 1; return BackendClient() })
        await restored.restoreSavedWorkspace()
        let tables = restored.documents.filter { $0.table != nil }
        #expect(tables.map(\.id) == [source.id, other.id] && Set(tables.compactMap(\.tableViewID)).count == 2)
        #expect(tables.map(\.storedState) == [source.storedState, other.storedState])
        #expect(tables.allSatisfy { $0.runtime == nil && $0.grid == nil && $0.tableResult == nil && $0.tableBackHistory.isEmpty && $0.tableForwardHistory.isEmpty })
        #expect(starts == 0 && restored.services.isEmpty)
        await restored.shutdown()
        await fixture.finish()
    }

    @Test func changedProfileClearsHistoryAndCannotReuseAnotherProfilesTableSession() async throws {
        let fixture = try await fixture()
        let source = try await fixture.source()
        let key = try #require(source.tableForeignKeys.first)
        let row = try #require(source.grid?.rows.first)
        await fixture.workspace.followForeignKey(key, rowID: row.id, in: source)
        let runtime = try #require(source.runtime)
        let session = runtime.sessionId
        let before = try fixture.evidence.events().filter { $0.hasPrefix("browse:") }
        source.profileID = fixture.otherProfile.id
        #expect(source.tableBackHistory.isEmpty && source.tableForwardHistory.isEmpty && source.tableForeignKeys.isEmpty)
        #expect(source.tableResult == nil && source.tableFailure == nil && source.tableNavigationError == nil)
        await fixture.workspace.run(source)
        #expect(source.runtime === runtime && runtime.sessionId == session)
        #expect(source.localError?.contains("profile changed") == true)
        #expect(try fixture.evidence.events().filter { $0.hasPrefix("browse:") } == before)
        await fixture.finish()
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(predicate())
    }
}
