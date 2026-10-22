import Foundation
import Testing
@testable import DBeer

/// Local stores and a controlled protocol helper exercise runtime ownership.
/// These tests never create windows, activate the app, or contact a database.
@Suite(.serialized)
@MainActor
struct InvestigationWorkspaceTests {
    @Test func restorePreservesTextReferencesAndMissingBindingsWithoutHelperOrCredentials() async throws {
        let credentials = InvestigationRuntimeTestSupport.Credentials()
        let missingProfile = UUID()
        let snapshotID = UUID()
        let markdown = StoredInvestigationBlock(kind: .markdown, text: "# Exact source\n\n😀 notes\n")
        let sql = StoredInvestigationBlock(kind: .sql, text: "SELECT 'NULL', NULL;\n", profileID: missingProfile)
        let unbound = StoredInvestigationBlock(kind: .sql, text: "SELECT 2;", profileID: nil)
        let snapshot = StoredInvestigationBlock(kind: .snapshot, snapshotID: snapshotID, explanation: "Retain this explanation.")
        let saved = StoredInvestigation(title: "Offline investigation", blocks: [markdown, sql, unbound, snapshot])
        let storage = InvestigationRuntimeTestSupport.Store(StoredInvestigations(documents: [saved]))
        let reference = StoredSQLDocument(title: saved.title, text: "", kind: .investigation, investigationID: saved.id)
        var launches = 0
        let library = InvestigationLibraryModel(store: storage, autosaveDelay: nil)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: credentials,
            documentStore: MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(documents: [reference], selectedDocumentID: reference.id)),
            investigations: library, automaticallyWatchFiles: false, helperFactory: {
                launches += 1
                return BackendClient(executableURL: URL(fileURLWithPath: "/unused-investigation-helper"))
            })
        await workspace.restoreSavedWorkspace()
        let parent = try #require(workspace.selectedDocument)
        let model = try #require(parent.investigationModel)
        #expect(parent.isInvestigation && !parent.isSQLDocument && parent.profileID == nil)
        #expect(model.storedState == saved)
        #expect(model.sqlDocument(for: sql.id)?.profileID == missingProfile)
        #expect(model.sqlDocument(for: sql.id)?.historyConnectionNotice?.contains("no longer available") == true)
        #expect(model.sqlDocument(for: unbound.id)?.profileID == nil)
        #expect(model.allSQLDocuments.allSatisfy { $0.runtime == nil && $0.executions.isEmpty && $0.fileURL == nil })
        #expect(try library.referencingInvestigations(snapshotID: snapshotID) == [saved.id])
        await workspace.start()
        #expect(launches == 0 && workspace.services.isEmpty)
        #expect(await credentials.accesses == 0)
        await workspace.shutdown()
    }

    @Test func sameProfileBlocksOwnDistinctSessionsAndReorderAndPaneMovesRetainThem() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["BEGIN", "SELECT 2"])
        let workspace = fixture.workspace
        let first = fixture.children[0]
        let second = fixture.children[1]
        await workspace.run(first)
        await workspace.run(second)
        let firstRuntime = try #require(first.runtime)
        let secondRuntime = try #require(second.runtime)
        #expect(firstRuntime.sessionId != secondRuntime.sessionId)
        #expect(workspace.services[fixture.profile.id]?.sessionId != firstRuntime.sessionId)
        #expect(firstRuntime.transactionStatus == .transaction && secondRuntime.transactionStatus == .idle)
        let blockID = try #require(fixture.model.blockID(for: first))
        let session = firstRuntime.sessionId
        fixture.model.moveBlock(blockID, by: 1)
        fixture.model.selectBlock(fixture.model.blockID(for: second))
        workspace.moveDocument(fixture.parent.id, to: .right)
        #expect(fixture.model.sqlDocument(for: blockID) === first)
        #expect(first.runtime === firstRuntime && firstRuntime.sessionId == session)
        #expect(workspace.ownedSQLContext(for: first)?.paneID == .right)
        #expect(workspace.canStartOperation(first))
        #expect(workspace.commandDocument(for: first.id) == nil)
        #expect(!workspace.canBindInvestigationProfile(first))
        #expect(!workspace.bindInvestigationProfile(first, profileID: nil))
        #expect(await workspace.disconnectInvestigationBlock(first))
        #expect(first.runtime == nil && second.runtime === secondRuntime)
        #expect(secondRuntime.connectionState == .connected)
        #expect(workspace.bindInvestigationProfile(first, profileID: nil))
        #expect(first.profileID == nil)
        await workspace.shutdown()
    }

    @Test func profileDisconnectIncludesEveryBlockAndTopLevelTableSession() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["BEGIN", "SELECT 2"])
        let workspace = fixture.workspace
        for child in fixture.children { await workspace.run(child) }
        let table = workspace.newDocument(profileID: fixture.profile.id, text: "Table data")
        table.table = TableReference(schema: "fixture", name: "items", kind: "table")
        await workspace.run(table)
        #expect(table.runtime?.connectionState == .connected)
        #expect(workspace.allOwnedRuntimeDocuments.contains { $0 === table })
        #expect(workspace.allOwnedRuntimeDocuments.count == 3)
        #expect(await workspace.disconnectProfile(fixture.profile.id))
        #expect(fixture.children.allSatisfy { $0.runtime == nil })
        #expect(table.runtime == nil && workspace.services[fixture.profile.id] == nil)
        #expect(fixture.children[0].profileID == fixture.profile.id)
        await workspace.shutdown()
    }

    @Test func cancelledParentCloseRetainsParentAndUnresolvedChildSession() async throws {
        var decisions: [WorkspaceCloseDecision] = [.rollback, .cancel]
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["BEGIN", "BEGIN"], closeDecision: { _ in
            decisions.isEmpty ? .cancel : decisions.removeFirst()
        })
        for child in fixture.children { await fixture.workspace.run(child) }
        let first = try #require(fixture.children[0].runtime)
        let second = try #require(fixture.children[1].runtime)
        await fixture.workspace.closeDocument(fixture.parent)
        #expect(fixture.workspace.documents.contains { $0 === fixture.parent })
        #expect(first.transactionStatus == .idle && first.connectionState == .connected)
        #expect(second.transactionStatus == .transaction && second.connectionState == .connected)
        #expect(fixture.workspace.closedTabs.isEmpty)
        #expect(fixture.workspace.canStartOperation(fixture.children[1]))
        await fixture.workspace.shutdown()
    }

    @Test func rejectingRunningBlockCloseKeepsItOwnedAndStopStillTargetsThatBlock() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["SELECT hold", "SELECT 2"], closeDecision: { _ in .cancel })
        let first = fixture.children[0]
        let running = Task { await fixture.workspace.run(first) }
        try await InvestigationRuntimeTestSupport.eventually { first.runtime?.canStop == true }
        fixture.model.selectBlock(fixture.model.blockID(for: fixture.children[1]))
        await fixture.workspace.closeDocument(fixture.parent)
        #expect(first.isRunning && fixture.workspace.ownedSQLContext(for: first) != nil)
        #expect(fixture.workspace.documents.contains { $0 === fixture.parent })
        await fixture.workspace.stop(first)
        await running.value
        #expect(!first.isRunning && first.runtime?.queryFailure?.category == "cancelled")
        #expect(fixture.children[1].runtime == nil)
        await fixture.workspace.shutdown()
    }

    @Test func closeDuringServiceConnectCannotStartAWorkingSessionOrReviveAClosedChild() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["SELECT 1"], connectDelay: 0.2,
            closeDecision: { _ in .stop })
        let child = fixture.children[0]
        let blockID = try #require(fixture.model.blockID(for: child))
        let running = Task { await fixture.workspace.run(child) }
        try await InvestigationRuntimeTestSupport.eventually { fixture.workspace.services[fixture.profile.id]?.isConnecting == true }
        await fixture.workspace.closeDocument(fixture.parent)
        await running.value
        #expect(fixture.workspace.documents.isEmpty)
        #expect(child.runtime == nil && child.executions.allSatisfy { $0.result == nil })
        #expect(!fixture.workspace.canStartOperation(child))
        let reopened = try #require(fixture.workspace.reopenClosedTab())
        let fresh = try #require(reopened.investigationModel?.sqlDocument(for: blockID))
        #expect(fresh !== child && fresh.id != child.id && fresh.runtime == nil && fresh.executions.isEmpty)
        await fixture.workspace.shutdown()
    }

    @Test func cancellingSQLBlockDeletionPreservesBlockOrderIdentityAndTransaction() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["BEGIN", "SELECT 2"], closeDecision: { _ in .cancel })
        let child = fixture.children[0]
        let blockID = try #require(fixture.model.blockID(for: child))
        let order = fixture.model.blocks.map(\.id)
        await fixture.workspace.run(child)
        let runtime = try #require(child.runtime)
        #expect(!(await fixture.workspace.deleteInvestigationBlock(fixture.parent, blockID: blockID)))
        #expect(fixture.model.blocks.map(\.id) == order && fixture.model.sqlDocument(for: blockID) === child)
        #expect(runtime.transactionStatus == .transaction && runtime.connectionState == .connected)
        #expect(await fixture.store.load().documents[0].blocks.map(\.id) == order)
        await fixture.workspace.shutdown()
    }

    @Test func failedChildDisconnectCannotRemoveParentOrItsOtherSessions() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["SELECT 1", "SELECT 2"], failDisconnect: true)
        for child in fixture.children { await fixture.workspace.run(child) }
        let first = try #require(fixture.children[0].runtime)
        let second = try #require(fixture.children[1].runtime)
        let secondSession = second.sessionId
        await fixture.workspace.closeDocument(fixture.parent)
        #expect(fixture.workspace.documents.contains { $0 === fixture.parent })
        #expect(first.connectionState == .connected && first.sessionId != nil)
        #expect(second.sessionId == secondSession && second.connectionState == .connected)
        #expect(fixture.workspace.closedTabs.isEmpty)
        await fixture.workspace.closeDocument(fixture.parent)
        #expect(!fixture.workspace.documents.contains { $0 === fixture.parent })
        await fixture.workspace.shutdown()
    }

    @Test func uncertainCommitDoesNotForceCloseDeleteOrProfileDisconnect() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["BEGIN"], unknownCommit: true,
            closeDecision: { _ in .commit })
        let child = fixture.children[0]
        await fixture.workspace.run(child)
        await fixture.workspace.closeDocument(fixture.parent)
        #expect(child.runtime?.queryFailure?.outcomeUnknown == true)
        #expect(fixture.workspace.documents.contains { $0 === fixture.parent })
        let blockID = try #require(fixture.model.blockID(for: child))
        #expect(!(await fixture.workspace.deleteInvestigationBlock(fixture.parent, blockID: blockID)))
        #expect(!(await fixture.workspace.disconnectProfile(fixture.profile.id)))
        await fixture.workspace.closeDocument(fixture.parent)
        #expect(fixture.model.sqlDocument(for: blockID) === child)
        #expect(fixture.workspace.documents.contains { $0 === fixture.parent })
        #expect(child.localError?.contains("unknown") == true)
        await fixture.workspace.shutdown()
    }

    @Test func closeFlushesEveryBlockAndReopenHasFreshTransientChildren() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["SELECT 1", "SELECT 2"])
        let markdownID = try #require(fixture.workspace.addInvestigationMarkdown(fixture.parent, text: "# Unsaved Markdown\n"))
        let first = fixture.children[0]
        let firstBlockID = try #require(fixture.model.blockID(for: first))
        fixture.children[1].text = "SELECT 'latest other block';\n"
        first.text = "SELECT 'latest selected block';\n"
        fixture.model.selectBlock(firstBlockID)
        fixture.parent.title = "Latest title"
        fixture.model.setText("# Complete current Markdown\n😀", for: markdownID)
        fixture.workspace.moveDocument(fixture.parent.id, to: .right)
        await fixture.workspace.closeDocument(fixture.parent)
        #expect(fixture.workspace.documents.isEmpty)
        let saved = try #require(await fixture.store.load().documents.first)
        #expect(saved.title == "Latest title")
        #expect(saved.blocks.first { $0.id == firstBlockID }?.text == first.text)
        #expect(saved.blocks.first { $0.id == markdownID }?.text == "# Complete current Markdown\n😀")
        #expect(saved.blocks.filter { $0.kind == .sql }.map(\.text) == [first.text, fixture.children[1].text])
        let reopened = try #require(fixture.workspace.reopenClosedTab())
        let model = try #require(reopened.investigationModel)
        let fresh = try #require(model.sqlDocument(for: firstBlockID))
        #expect(reopened.id != fixture.parent.id && fresh.id != first.id && fresh !== first)
        #expect(fixture.workspace.pane(containing: reopened.id) == .right)
        #expect(fresh.runtime == nil && fresh.executions.isEmpty)
        #expect(fixture.workspace.ownedSQLContext(for: first) == nil)
        #expect(!fixture.workspace.canStartOperation(first))
        first.text = "Late callback on closed child"
        #expect(fresh.text != first.text)
        #expect(fixture.workspace.openInvestigation(id: saved.id) === reopened)
        #expect(fixture.workspace.documents.count == 1 && fixture.workspace.activePaneID == .right)
        await fixture.workspace.shutdown()
    }

    @Test func saveFailureKeepsParentAndDeletingBlockPublishesBeforeDroppingChild() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["SELECT 1", "SELECT 2"])
        let child = fixture.children[0]
        let blockID = try #require(fixture.model.blockID(for: child))
        await fixture.workspace.run(child)
        let session = child.runtime?.sessionId
        child.text = "SELECT 'unsaved';"
        await fixture.store.setFailure(true)
        await fixture.workspace.closeDocument(fixture.parent)
        #expect(fixture.workspace.documents.contains { $0 === fixture.parent })
        #expect(child.runtime?.sessionId == session)
        #expect(!(await fixture.workspace.deleteInvestigationBlock(fixture.parent, blockID: blockID)))
        #expect(fixture.model.sqlDocument(for: blockID) === child && fixture.model.isDirty)
        #expect(await fixture.store.load().documents[0].blocks.contains { $0.id == blockID })
        await fixture.store.setFailure(false)
        #expect(await fixture.workspace.deleteInvestigationBlock(fixture.parent, blockID: blockID))
        #expect(fixture.model.sqlDocument(for: blockID) == nil)
        #expect(!fixture.model.blocks.contains { $0.id == blockID })
        #expect(await !fixture.store.load().documents[0].blocks.contains { $0.id == blockID })
        #expect(!fixture.workspace.canStartOperation(child))
        await fixture.workspace.shutdown()
    }

    @Test func clearingTabsPreservesLibraryAndUnavailableReferencesNeverCreateEmptyContent() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["SELECT 1"])
        let id = fixture.model.id
        fixture.children[0].text = "SELECT 'survives clear';"
        await fixture.workspace.clearRestoredDocuments()
        #expect(fixture.workspace.documents.isEmpty && fixture.workspace.closedTabs.isEmpty)
        #expect(await fixture.store.load().documents.first?.blocks.first?.text == "SELECT 'survives clear';")
        let reopened = try #require(fixture.workspace.openInvestigation(id: id))
        #expect(reopened.investigationModel?.allSQLDocuments.first?.runtime == nil)
        let missingID = UUID()
        let unavailable = try #require(fixture.workspace.openInvestigation(id: missingID))
        #expect(unavailable.investigationID == missingID && unavailable.investigationModel?.isAvailable == false)
        #expect(unavailable.investigationModel?.unavailableReason?.isEmpty == false)
        #expect(!(await fixture.workspace.saveInvestigation(unavailable)))
        #expect(await !fixture.store.load().documents.contains { $0.id == missingID })
        await fixture.workspace.closeDocument(unavailable)
        #expect(fixture.workspace.closedTabs.last?.state.investigationID == missingID)
        await fixture.workspace.shutdown()
    }

    @Test func unreadableLibraryAllowsClosingOpaqueTabsAndQuittingWithoutLibraryWrites() async throws {
        let store = UnreadableStore()
        let id = UUID()
        let reference = StoredSQLDocument(title: "Unavailable saved investigation", text: "", kind: .investigation, investigationID: id)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(documents: [reference], selectedDocumentID: reference.id)),
            investigations: InvestigationLibraryModel(store: store, autosaveDelay: nil), automaticallyWatchFiles: false)
        await workspace.restoreSavedWorkspace()
        let parent = try #require(workspace.selectedDocument)
        #expect(parent.investigationID == id && parent.investigationModel?.isAvailable == false)
        #expect(!(await workspace.saveInvestigation(parent)))
        #expect(await workspace.prepareToClose(.application))
        await workspace.closeDocument(parent)
        #expect(workspace.documents.isEmpty && workspace.closedTabs.last?.state.investigationID == id)
        #expect(await store.saves == 0)
        let reopened = try #require(workspace.reopenClosedTab())
        #expect(reopened.investigationID == id && reopened.investigationModel?.isAvailable == false)
        await workspace.shutdown()
        #expect(await store.saves == 0)
    }

    @Test func duplicateInjectedWorkspaceReferencesNeverCreateTwoMutableOwners() async throws {
        let saved = StoredInvestigation(title: "One owner", blocks: [StoredInvestigationBlock(kind: .sql, text: "SELECT 1;")])
        let first = StoredSQLDocument(title: saved.title, text: "", kind: .investigation, investigationID: saved.id)
        let duplicate = StoredSQLDocument(title: saved.title, text: "", kind: .investigation, investigationID: saved.id)
        var layout = WorkspacePaneLayout()
        layout.insertDocument(first.id, in: .left)
        layout.insertDocument(duplicate.id, in: .right)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(documents: [first, duplicate], paneLayout: layout)),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(snapshot: StoredInvestigations(documents: [saved])), autosaveDelay: nil),
            automaticallyWatchFiles: false)
        await workspace.restoreSavedWorkspace()
        #expect(workspace.documents.count == 1 && workspace.allOwnedRuntimeDocuments.count == 1)
        #expect(workspace.paneLayout.isValid(documentIDs: workspace.documents.map(\.id)))
        let parent = try #require(workspace.documents.first)
        #expect(workspace.openInvestigation(id: saved.id) === parent)
        #expect(workspace.documents.count == 1)
        await workspace.shutdown()
    }

    private actor UnreadableStore: InvestigationStore {
        private(set) var saves = 0
        func load() throws -> StoredInvestigations { throw InvestigationStoreError.read }
        func save(_ value: StoredInvestigations) { saves += 1 }
    }
}

@MainActor
enum InvestigationRuntimeTestSupport {
    actor Store: InvestigationStore {
        private var snapshot: StoredInvestigations
        private var fails = false
        init(_ snapshot: StoredInvestigations) { self.snapshot = snapshot }
        func load() -> StoredInvestigations { snapshot }
        func save(_ value: StoredInvestigations) throws {
            if fails { throw InvestigationStoreError.write }
            snapshot = value
        }
        func setFailure(_ value: Bool) { fails = value }
    }

    actor Credentials: ConnectionCredentialStore {
        private(set) var accesses = 0
        func password(for id: UUID) -> String? { accesses += 1; return nil }
        func savePassword(_ password: String, for id: UUID) { accesses += 1 }
        func deletePassword(for id: UUID) { accesses += 1 }
    }

    struct Fixture {
        let workspace: ApplicationWorkspace
        let parent: SQLDocument
        let model: InvestigationDocumentModel
        let children: [SQLDocument]
        let profile: SavedConnection
        let store: Store
    }

    static func fixture(sql: [String], failDisconnect: Bool = false, unknownCommit: Bool = false, connectDelay: Double = 0,
                        resultSnapshots: ResultSnapshotsModel? = nil,
                        closeDecision: @escaping @MainActor (WorkspaceCloseIssue) async -> WorkspaceCloseDecision = { _ in .rollback }) async throws -> Fixture {
        let profile = SavedConnection(name: "Investigation fixture", settings: ConnectionSettings(host: "fixture.invalid", port: 5432,
            database: "fixture", user: "fixture", password: "", sslMode: "disable"))
        let saved = StoredInvestigation(title: "Investigation fixture", blocks: sql.map {
            StoredInvestigationBlock(kind: .sql, text: $0, profileID: profile.id)
        })
        let store = Store(StoredInvestigations(documents: [saved]))
        let snapshots = resultSnapshots ?? ResultSnapshotsModel()
        let investigations = InvestigationLibraryModel(store: store, snapshotStore: snapshots.store, autosaveDelay: nil)
        let reference = StoredSQLDocument(title: saved.title, text: "", kind: .investigation, investigationID: saved.id)
        let client = helper(failDisconnect: failDisconnect, unknownCommit: unknownCommit, connectDelay: connectDelay)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id)),
            credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(documents: [reference], selectedDocumentID: reference.id)),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), resultSnapshots: snapshots, investigations: investigations,
            automaticallyWatchFiles: false, closeDecision: closeDecision, executionDecision: { _ in true }, helperFactory: { client })
        await workspace.restoreSavedWorkspace()
        await workspace.library.loadConnections()
        let parent = try #require(workspace.selectedDocument)
        let model = try #require(parent.investigationModel)
        return Fixture(workspace: workspace, parent: parent, model: model,
            children: model.allSQLDocuments, profile: profile, store: store)
    }

    static func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    static func helper(failDisconnect: Bool = false, unknownCommit: Bool = false, connectDelay: Double = 0) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time
        transactions = {}
        pending = {}
        failed_disconnect = False
        def send(reply):
            print(json.dumps(reply), flush=True)
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            reply = {'requestId':command['requestId']}
            if kind == 'hello':
                reply.update(type='hello.ack', protocolVersion=5)
            elif kind == 'connect':
                time.sleep(\(connectDelay))
                session = 'investigation-session-' + str(len(transactions))
                transactions[session] = 'idle'
                reply.update(type='connect.result', engine='postgresql', capabilities=['execute','cancel','transactions'],
                             sessionId=session, transactionStatus='idle')
            elif kind == 'operation.assess':
                reply.update(type='operation.assessment', sessionId=command['sessionId'], queryId=command['queryId'],
                             assessment={'decision':'allow','policy':{'environment':'unspecified','readOnly':False},
                             'operations':[{'kind':'read','statements':[]} for op in command['operations']], 'authorization':'test-grant'})
            elif kind in ['execute','catalog']:
                session = command['sessionId']
                sql = command.get('sql','')
                send({'type':'query.started','requestId':command['requestId'],'sessionId':session,'queryId':command['queryId']})
                if sql == 'SELECT hold':
                    pending[(session, command['queryId'])] = command
                    continue
                if sql == 'BEGIN':
                    transactions[session] = 'transaction'
                elif sql in ['COMMIT','ROLLBACK']:
                    if sql == 'COMMIT' and \(unknownCommit ? "True" : "False"):
                        reply.update(type='error', sessionId=session, queryId=command['queryId'], category='connection',
                                     message='Commit acknowledgement unavailable.', connected=True, outcomeUnknown=True,
                                     transactionStatus=transactions[session])
                        send(reply)
                        continue
                    transactions[session] = 'idle'
                reply.update(type='query.result',sessionId=session,queryId=command['queryId'],durationMs=1,
                             transactionStatus=transactions[session],columns=[],rows=[],catalogRecords=[],
                             commandTag=sql or 'SELECT 0',rowCount=0,displayedRowCount=0,truncated=False)
            elif kind == 'cancel':
                key = (command['sessionId'], command['queryId'])
                original = pending.pop(key, None)
                reply.update(type='cancel.ack', sessionId=command['sessionId'], queryId=command['queryId'],
                             status='accepted' if original else 'alreadyFinished')
                send(reply)
                if original:
                    send({'type':'error','requestId':original['requestId'],'sessionId':original['sessionId'],
                          'queryId':original['queryId'],'category':'cancelled','message':'Query cancelled.',
                          'connected':True,'outcomeUnknown':False,'transactionStatus':transactions[original['sessionId']]})
                continue
            elif kind == 'disconnect':
                if \(failDisconnect ? "True" : "False") and not failed_disconnect and command['sessionId'] != 'investigation-session-0':
                    failed_disconnect = True
                    reply.update(type='error',sessionId=command['sessionId'],category='connection',message='Disconnect rejected.',
                                 connected=True,outcomeUnknown=False,transactionStatus=transactions[command['sessionId']])
                else:
                    reply.update(type='disconnect.ack',sessionId=command['sessionId'])
            elif kind == 'shutdown':
                reply.update(type='shutdown.ack')
            else:
                sys.exit(40)
            send(reply)
            if kind == 'shutdown':
                break
        """])
    }
}
