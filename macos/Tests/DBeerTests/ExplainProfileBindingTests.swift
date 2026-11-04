import Foundation
import Testing
@testable import DBeer

/// Synthetic profiles and a pipe helper only; no windows or database access.
@MainActor
struct ExplainProfileBindingTests {
    private func profile() -> SavedConnection {
        SavedConnection(name: "Synthetic Unicode", settings: ConnectionSettings(host: "localhost", port: 5432,
            database: "\u{00e9}", user: "fixture", password: "", sslMode: "disable"))
    }

    @Test func canonicalEquivalentProfileCannotMatchRuntimeOrRetainedPlan() throws {
        let original = profile()
        var changed = original
        changed.database = "e\u{0301}"
        #expect(original == changed) // Swift's canonical equality is insufficient here.
        let binding = try #require(ExplainProfileBinding(original))
        #expect(binding.matches(original))
        #expect(!binding.matches(changed))
        let runtime = WorkspaceModel()
        runtime.host = original.host
        runtime.port = String(original.port)
        runtime.database = original.database
        runtime.user = original.user
        runtime.sslMode = original.sslMode
        #expect(binding.matchesRuntime(runtime))
        runtime.database = changed.database
        #expect(!binding.matchesRuntime(runtime))
        let plan = ExplainPlanModel(request: ExplainRequest(sql: "SELECT 1", mode: .plan), sourceText: "SELECT 1",
            sourceRange: NSRange(location: 0, length: 8), profileID: original.id, profile: original, profileBinding: binding)
        #expect(!plan.isStale(text: "SELECT 1", profileID: original.id, profile: original))
        #expect(plan.isStale(text: "SELECT 1", profileID: changed.id, profile: changed))
    }

    @Test func registryInvocationKeepsExactProfileBeforeItsTaskStarts() throws {
        let original = profile()
        var changed = original
        changed.database = "e\u{0301}"
        let invocation = AppCommandInvocation(command: .explainAnalyze, documentID: UUID(), documentText: "SELECT 1",
            profile: original, explainProfileBinding: try #require(ExplainProfileBinding(original)), fragment: nil,
            parentDocumentID: UUID(), investigationID: nil, blockID: nil, paneID: WorkspacePaneID())
        #expect(invocation.matchesExplainProfile(original))
        #expect(!invocation.matchesExplainProfile(changed))
    }

    @Test func capturedProfileCannotRetargetAtAsyncExplainEntry() async throws {
        let original = profile()
        var changed = original
        changed.database = "e\u{0301}"
        let store = MemoryConnectionLibraryStore(library: SavedConnectionLibrary(connections: [changed], selectedConnectionId: changed.id))
        var helperRequested = false
        let workspace = ApplicationWorkspace(connectionStore: store, credentialStore: MemoryConnectionCredentialStore(),
            automaticallyWatchFiles: false, helperFactory: { helperRequested = true; return BackendClient() })
        await workspace.library.loadConnections()
        let document = workspace.newDocument(profileID: changed.id, text: "SELECT 1")
        let fragment = try #require(workspace.executionFragment(document))
        await workspace.explainResolved(document, fragment: fragment, mode: .analyze,
            profileBinding: try #require(ExplainProfileBinding(original)))
        #expect(!helperRequested && document.runtime == nil)
        #expect(document.localError != nil && document.explainPlan == nil)
        await workspace.shutdown()
    }

    private final class ReviewState {
        weak var workspace: ApplicationWorkspace?
        var count = 0
        var changedProfile = false
    }

    @Test func canonicallyEquivalentDatabaseChangeDuringConfirmationSendsNoExplain() async throws {
        let original = profile()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("explain-not-dispatched-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys
        serial=0
        def send(v):print(json.dumps(v),flush=True)
        def started(c):send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
        support=dict(engine='postgresql',serverVersion='17.6',format='json',modes=['plan','analyze'])
        for line in sys.stdin:
            c=json.loads(line);kind=c['type'];r=dict(type='',requestId=c['requestId'])
            if 'sessionId' in c:r['sessionId']=c['sessionId']
            if 'queryId' in c:r['queryId']=c['queryId']
            if kind=='hello':r.update(type='hello.ack',protocolVersion=6)
            elif kind=='connect':
                serial+=1;r.update(type='connect.result',sessionId='session-'+str(serial),transactionStatus='idle',engine='postgresql',capabilities=['execute','cancel','transactions','visualExplainV1'],explainSupport=support)
            elif kind=='catalog':
                started(c);r.update(type='query.result',transactionStatus='idle',durationMs=0,columns=[],rows=[],commandTag='SELECT 0',rowCount=0,displayedRowCount=0,truncated=False)
            elif kind=='operation.assess':
                request=c['operations'][0]['explain']
                preview=dict(sql='EXPLAIN (ANALYZE TRUE, FORMAT JSON)\\n'+request['sql'],mode=request['mode'],support=support)
                r.update(type='operation.assessment',assessment=dict(decision='confirm',policy=dict(environment='unspecified',readOnly=False),operations=[dict(kind='read',statements=[],explain=preview)],authorization='single-use'))
            elif kind=='cancel':r.update(type='cancel.ack',status='alreadyFinished')
            elif kind=='disconnect':r.update(type='disconnect.ack')
            elif kind=='explain.run':
                open(sys.argv[1],'w').write('unexpected dispatch')
                started(c);r.update(type='error',category='validation',message='Unexpected dispatch',connected=True,outcomeUnknown=False,sqlNotExecuted=True,transactionStatus='idle')
            elif kind=='shutdown':
                r.update(type='shutdown.ack');send(r);break
            else:sys.exit(31)
            send(r)
        """, marker.path])
        let store = MemoryConnectionLibraryStore(library: SavedConnectionLibrary(connections: [original], selectedConnectionId: original.id))
        let state = ReviewState()
        let workspace = ApplicationWorkspace(connectionStore: store, credentialStore: MemoryConnectionCredentialStore(),
            automaticallyWatchFiles: false, closeDecision: { _ in .rollback }, executionDecision: { _ in
                state.count += 1
                var settings = original.settings(password: "")
                settings.database = "e\u{0301}"
                state.changedProfile = await state.workspace?.library.saveConnection(name: original.name, settings: settings, id: original.id) == true
                return true
            }, helperFactory: { client })
        state.workspace = workspace
        await workspace.start()
        let document = workspace.newDocument(profileID: original.id, text: "SELECT 1")
        let fragment = try #require(workspace.executionFragment(document))
        await workspace.explainResolved(document, fragment: fragment, mode: .analyze)
        #expect(state.count == 1 && state.changedProfile)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(document.explainPlan?.status == "Not executed — context changed or stopped")
        #expect(document.explainPlan?.result == nil)
        #expect(document.explainPlan?.isStale(text: document.text, profileID: document.profileID,
            profile: workspace.library.savedConnections.first { $0.id == original.id }) == true)
        await workspace.shutdown()
    }
}
