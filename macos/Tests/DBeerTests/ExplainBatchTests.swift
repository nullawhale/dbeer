import Foundation
import Testing
@testable import DBeer

struct ExplainBatchModelTests {
    @Test func setupIsNeverSelectedByDefault() throws {
        let text = "BEGIN;\nSET LOCAL work_mem = '8MB';\nSELECT 1;\nCOMMIT"
        let candidates = try ExplainBatchStatement.candidates(text: text,
            selections: [NSRange(location: 0, length: text.utf16.count)], engine: .postgresql)
        #expect(candidates.map(\.action) == [.execute, .execute, .plan, .execute])
        #expect(candidates.filter(\.selectedByDefault).map(\.sql) == ["SELECT 1"])
    }

    @Test func multipleSelectionsKeepOriginalUTF16RangesAndOrder() throws {
        let text = "SELECT '🍺';\r\nSELECT 2;\r\nSELECT 3"
        let parsed = SQLScriptParser.parse(text, engine: .postgresql).statements
        let candidates = try ExplainBatchStatement.candidates(text: text,
            selections: [parsed[2].range, parsed[0].range], engine: .postgresql)
        #expect(candidates.map(\.range) == parsed.map(\.range))
        #expect(candidates.filter(\.selectedByDefault).map(\.range) == [parsed[0].range, parsed[2].range])
        #expect(candidates.allSatisfy { $0.matches(text) })
    }

    @Test func partialSelectionIsCapturedWithoutExpandingIt() throws {
        let text = "SELECT 1 + 2; SELECT 3"
        let range = NSRange(location: 0, length: 8)
        let candidates = try ExplainBatchStatement.candidates(text: text, selections: [range], engine: .postgresql)
        #expect(candidates.first?.sql == "SELECT 1" && candidates.first?.range == range)
        #expect(candidates.first?.selectedByDefault == true)
    }

    @Test func unrelatedIncompleteSQLDoesNotBlockAValidSelection() throws {
        let text = "SELECT 1; SELECT 'unfinished"
        let candidates = try ExplainBatchStatement.candidates(text: text,
            selections: [NSRange(location: 0, length: 8)], engine: .postgresql)
        #expect(candidates.count == 1 && candidates[0].sql == "SELECT 1")
        #expect(candidates[0].range == NSRange(location: 0, length: 8) && candidates[0].selectedByDefault)
    }

    @Test func duplicateSelectionsAreNotRepeated() throws {
        let candidates = try ExplainBatchStatement.candidates(text: "SELECT 1", selections:
            [NSRange(location: 0, length: 8), NSRange(location: 0, length: 8)], engine: .postgresql)
        #expect(candidates.count == 1)
    }

    @Test func sourceMatchingUsesExactBytes() throws {
        let text = "SELECT '\u{00e9}'"
        let item = try #require(ExplainBatchStatement.candidates(text: text,
            selections: [NSRange(location: 0, length: 0)], engine: .postgresql).first)
        #expect(item.matches(text))
        #expect(!item.matches("SELECT 'e\u{0301}'"))
    }

    @Test func statementLimitIsBounded() {
        #expect(throws: ExecutionPolicyError.self) {
            try ExplainBatchStatement.candidates(text: Array(repeating: "SELECT 1", count: 257).joined(separator: ";"),
                selections: [], engine: .postgresql)
        }
    }

    @Test func artifactsKeepValuesAndRangesButStripRuntimeOwnership() throws {
        let result = try #require(ExplainFixture.load().results.first { $0.mode == .plan })
        let sql = "SELECT :p"
        let request = ExplainRequest(sql: sql, mode: .plan,
            parameters: [.init(name: "p", type: .decimal, value: "9007199254740993.1200")], planKind: .generic,
            context: .init(documentId: "private-source", targetDocumentId: "private-target", rangeLocation: 42,
                rangeLength: sql.utf16.count, profileId: "private-profile", sessionId: "private-session", transactionStatus: "transaction"))
        var plan = ExplainPlanModel(request: request, sourceText: sql, sourceRange: NSRange(location: 42, length: sql.utf16.count), profileID: UUID())
        plan.sourceEvidence = .init(rangeLocation: 42, rangeLength: sql.utf16.count, transactionStatus: "transaction")
        plan.result = result
        let artifact = try PlanArtifact.capture(plan, title: "Generic historical evidence")
        let encoded = try artifact.encoded()
        let restored = try PlanArtifact.decode(encoded)
        #expect(restored.version == 2 && restored.request.context == nil)
        #expect(restored.request.parameters == request.parameters && restored.request.planKind == .generic)
        #expect(restored.source == plan.sourceEvidence)
        #expect(!encoded.contains("private-") && !encoded.contains("targetDocumentId") && !encoded.contains("authorization"))
    }

    @Test func oldArtifactsRemainReadableAndFutureOrInjectedOwnershipIsRejected() throws {
        let result = try #require(ExplainFixture.load().results.first { $0.mode == .plan })
        var plan = ExplainPlanModel(request: .init(sql: "SELECT 1", mode: .plan), sourceText: "SELECT 1",
            sourceRange: NSRange(location: 0, length: 8), profileID: UUID())
        plan.result = result
        let encoded = try PlanArtifact.capture(plan, title: "Legacy").encoded()
        var object = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        object["version"] = 1
        func text() throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        #expect(try PlanArtifact.decode(text()).version == 1)
        object["version"] = 3
        #expect(throws: (any Error).self) { try PlanArtifact.decode(text()) }
        object["version"] = 2
        object["request"] = ["sql": "SELECT 1", "mode": "plan", "context": ["sessionId": "injected"]]
        #expect(throws: (any Error).self) { try PlanArtifact.decode(text()) }
    }
}

/// Memory stores, pipe helper and injected parameter/review/close decisions.
/// No windows, application activation, credentials, SSH or native prompts.
@Suite(.serialized)
@MainActor
struct ExplainBatchExecutionTests {
    private final class Counter { var helperStarts = 0; var reviews: [OperationConfirmation] = [] }
    private struct Fixture {
        let workspace: ApplicationWorkspace
        let client: BackendClient
        let profiles: [SavedConnection]
        let counter: Counter
        let root: URL
    }
    private let values = [QueryParameterBinding(name: "p", type: .text, value: "e\u{0301}' ; DROP TABLE excluded; --")]

    private func fixture(capability: Bool = true, failure: String = "",
                         parameters: (@MainActor ([SQLParameterDefinition], SavedConnection) async -> [QueryParameterBinding]?)? = nil,
                         review: (@MainActor (OperationConfirmation) async -> Bool)? = nil) async throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/explain-batch/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys,os
        root,extended,failure=sys.argv[1],sys.argv[2]=='true',sys.argv[3]
        counts=dict(connects=0,assessments=0,executions=0,setups=0)
        sessions={};grants={}
        support=dict(engine='postgresql',serverVersion='17.6',format='json',modes=['plan','analyze'],planKinds=['custom','generic'])
        caps=['execute','cancel','transactions','visualExplainV1','queryParametersV1']+(['explainParametersV1'] if extended else [])
        def send(v):print(json.dumps(v),flush=True)
        def started(c):send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
        def record():
            with open(os.path.join(root,'counts.json'),'w') as f:json.dump(counts,f)
        for line in sys.stdin:
            c=json.loads(line);kind=c['type'];r=dict(requestId=c['requestId'],type='')
            if 'sessionId' in c:r['sessionId']=c['sessionId']
            if 'queryId' in c:r['queryId']=c['queryId']
            if kind=='hello':r.update(type='hello.ack',protocolVersion=6,capabilities=caps)
            elif kind=='connect':
                counts['connects']+=1;sid='session-'+str(counts['connects']);sessions[sid]='idle'
                r.update(type='connect.result',sessionId=sid,transactionStatus='idle',engine='postgresql',capabilities=caps,explainSupport=support)
            elif kind=='catalog':
                started(c);r.update(type='query.result',transactionStatus=sessions[c['sessionId']],durationMs=0,columns=[],rows=[],commandTag='SELECT 0',rowCount=0,displayedRowCount=0,truncated=False)
            elif kind=='operation.assess':
                assert len(c['operations'])==1
                counts['assessments']+=1;op=c['operations'][0];token='grant-'+str(counts['assessments']);grants[token]=(c['sessionId'],op)
                if op['type']=='explain.run':
                    q=op['explain'];ctx=q.get('context')
                    if extended:assert ctx and ctx['sessionId']==c['sessionId'] and ctx['transactionStatus']==sessions[c['sessionId']]
                    preview=dict(sql='EXPLAIN '+q['sql'],mode=q['mode'],support=support)
                    assessed=dict(kind='read',statements=[],explain=preview)
                else:assessed=dict(kind='unknown',statements=[dict(start=0,end=len(op['sql']),kind='unknown',reason='Explicit setup')])
                r.update(type='operation.assessment',assessment=dict(decision='confirm',policy=dict(environment='unspecified',readOnly=False),operations=[assessed],authorization=token))
            elif kind in ['execute','explain.run']:
                sid,op=grants.pop(c['authorization']);assert sid==c['sessionId'] and op['type']==kind
                counts['executions']+=1;started(c)
                if kind=='explain.run':
                    assert op['explain']==c['explain']
                    evidence=dict(support=support,mode=c['explain']['mode'],status='rawOnly',raw='fixture plan',complete=True,diagnostic='Fixture raw plan',roots=[],nodes=[],metrics={})
                    r.update(type='explain.result',transactionStatus=sessions[sid],durationMs=1,sqlCompleted=True,explain=evidence)
                else:
                    counts['setups']+=1;assert op['sql']==c['sql'] and op.get('parameters')==c.get('parameters')
                    if failure:
                        r.update(type='error',category='cancelled',message='Setup stopped',connected=True,outcomeUnknown=failure=='unknown',sqlNotExecuted=failure!='unknown',transactionStatus=sessions[sid])
                    else:
                        if c['sql'].upper()=='BEGIN':sessions[sid]='transaction'
                        r.update(type='query.result',transactionStatus=sessions[sid],durationMs=1,columns=[],rows=[],commandTag='SET',rowCount=0,displayedRowCount=0,truncated=False)
            elif kind=='cancel':r.update(type='cancel.ack',status='alreadyFinished')
            elif kind=='disconnect':r.update(type='disconnect.ack')
            elif kind=='shutdown':r.update(type='shutdown.ack');record();send(r);break
            else:sys.exit(31)
            record();send(r)
        """, root.path, String(capability), failure])
        let profiles = ["Source", "Other"].map { SavedConnection(name: $0,
            settings: ConnectionSettings(host: "127.0.0.1", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable")) }
        let counter = Counter()
        let supplied = values
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: profiles, selectedConnectionId: profiles[0].id)),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), automaticallyWatchFiles: false,
            closeDecision: { _ in .rollback }, executionDecision: {
                counter.reviews.append($0)
                return await review?($0) ?? true
            }, queryParameterDecision: { definitions, profile in
                if let parameters { return await parameters(definitions, profile) }
                return supplied
            }, helperFactory: { counter.helperStarts += 1; return client })
        await workspace.library.loadConnections()
        return Fixture(workspace: workspace, client: client, profiles: profiles, counter: counter, root: root)
    }

    private func makeDraft(_ fixture: Fixture, text: String, parameters: Bool = false) throws -> (SQLDocument, ExplainBatchDraft) {
        let document = fixture.workspace.newDocument(profileID: fixture.profiles[0].id, text: text)
        if parameters { document.queryParameters = [.init(name: "p", type: .text)] }
        fixture.workspace.beginExplainSelection(document, mode: .plan,
            selections: [NSRange(location: 0, length: text.utf16.count)])
        let draft = try #require(fixture.workspace.explainSelection)
        fixture.workspace.explainSelection = nil
        return (document, draft)
    }

    private func counts(_ fixture: Fixture) throws -> [String: Int] {
        try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: fixture.root.appendingPathComponent("counts.json")))
    }
    private func finish(_ fixture: Fixture) async {
        await fixture.workspace.shutdown()
        if fixture.counter.helperStarts > 0 { #expect(await fixture.client.waitForExit().status == 0) }
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @Test func typedValuesAndEachStatementHaveTheirOwnExactGrant() async throws {
        let f = try await fixture()
        let (document, draft) = try makeDraft(f, text: "SELECT :p; SELECT :p", parameters: true)
        await f.workspace.runExplainSelection(draft, selected: Set(draft.statements.map(\.id)), targetID: draft.defaultTargetID, planKind: .custom)
        #expect(document.explainExecutions.count == 2 && document.explainExecutions.allSatisfy { $0.status == "Completed" })
        #expect(f.counter.reviews.count == 2)
        #expect(document.explainExecutions.allSatisfy { $0.plan?.request.parameters == values })
        #expect(try counts(f)["executions"] == 2)
        await finish(f)
    }

    @Test func unselectedSetupNeverRuns() async throws {
        let f = try await fixture()
        let (document, draft) = try makeDraft(f, text: "SET work_mem = '8MB'; SELECT 1")
        await f.workspace.runExplainSelection(draft, selected: Set(draft.statements.filter(\.selectedByDefault).map(\.id)), targetID: draft.defaultTargetID, planKind: nil)
        #expect(try counts(f)["setups"] == 0)
        #expect(document.explainExecutions.count == 1)
        await finish(f)
    }

    @Test func explicitlySelectedSetupKeepsPhysicalSessionAndRefreshesCapturedTransaction() async throws {
        let f = try await fixture()
        let (document, draft) = try makeDraft(f, text: "BEGIN; SELECT 1")
        await f.workspace.runExplainSelection(draft, selected: Set(draft.statements.map(\.id)), targetID: draft.defaultTargetID, planKind: nil)
        #expect(try counts(f)["setups"] == 1)
        #expect(document.explainExecutions.last?.plan?.sessionID == document.runtime?.sessionId)
        #expect(document.explainExecutions.last?.plan?.request.context?.transactionStatus == "transaction")
        #expect(document.runtime?.transactionStatus == .transaction)
        await finish(f)
    }

    @Test(arguments: ["unknown", "cancelled"])
    func uncertainOrCancelledSetupStopsBeforeAnyExplain(_ failure: String) async throws {
        let f = try await fixture(failure: failure)
        let (document, draft) = try makeDraft(f, text: "SET work_mem = '8MB'; SELECT 1")
        await f.workspace.runExplainSelection(draft, selected: Set(draft.statements.map(\.id)), targetID: draft.defaultTargetID, planKind: nil)
        #expect(try counts(f)["executions"] == 1 && counts(f)["assessments"] == 1)
        #expect(document.explainExecutions.last?.status == "Not executed")
        #expect(document.explainExecutions.first?.failure?.message == "Setup stopped")
        #expect(document.explainExecutions.first?.failure?.outcomeUnknown == (failure == "unknown"))
        #expect(document.explainExecutions.first?.context?.targetDocumentId == document.id.uuidString)
        await finish(f)
    }

    @Test func alternateProfileCreatesItsOwnTabWithoutRetargetingSource() async throws {
        let f = try await fixture()
        let (document, draft) = try makeDraft(f, text: "SELECT :p", parameters: true)
        let choice = try #require(draft.targets.first { $0.documentID == nil && $0.profile.id == f.profiles[1].id })
        await f.workspace.runExplainSelection(draft, selected: Set(draft.statements.map(\.id)), targetID: choice.id, planKind: nil)
        let plan = try #require(document.explainExecutions.first?.plan)
        #expect(document.profileID == f.profiles[0].id && document.runtime == nil && document.text == draft.sourceText)
        #expect(plan.profileID == f.profiles[1].id && plan.targetDocumentID != document.id)
        #expect(plan.request.context?.documentId == document.id.uuidString)
        #expect(plan.request.context?.targetDocumentId == plan.targetDocumentID?.uuidString)
        await finish(f)
    }

    @Test func alternateExistingTabReusesItsActualSession() async throws {
        let f = try await fixture()
        let (target, first) = try makeDraft(f, text: "SELECT 1")
        await f.workspace.runExplainSelection(first, selected: Set(first.statements.map(\.id)), targetID: first.defaultTargetID, planKind: nil)
        let session = target.runtime?.sessionId
        let (source, next) = try makeDraft(f, text: "SELECT 2")
        await f.workspace.runExplainSelection(next, selected: Set(next.statements.map(\.id)), targetID: target.id.uuidString, planKind: nil)
        #expect(source.runtime == nil && target.runtime?.sessionId == session)
        #expect(source.explainExecutions.first?.plan?.sessionID == session)
        #expect(try counts(f)["connects"] == 2) // Service plus the one physical SQL tab.
        await finish(f)
    }

    @Test(arguments: ["text", "profile", "definitions"])
    func changesAfterChoosingStatementsCannotStartHelper(_ mutation: String) async throws {
        let f = try await fixture()
        let (document, draft) = try makeDraft(f, text: "SELECT :p", parameters: true)
        if mutation == "text" { document.text += " " }
        if mutation == "profile" { document.profileID = f.profiles[1].id }
        if mutation == "definitions" { document.queryParameters = [.init(name: "p", type: .integer)] }
        await f.workspace.runExplainSelection(draft, selected: Set(draft.statements.map(\.id)), targetID: draft.defaultTargetID, planKind: nil)
        #expect(f.counter.helperStarts == 0 && document.localError != nil)
        await finish(f)
    }

    @Test func missingCapabilityCannotAssessParameterizedExplain() async throws {
        let f = try await fixture(capability: false)
        let (document, draft) = try makeDraft(f, text: "SELECT :p", parameters: true)
        await f.workspace.runExplainSelection(draft, selected: Set(draft.statements.map(\.id)), targetID: draft.defaultTargetID, planKind: .custom)
        #expect(try counts(f)["assessments"] == 0 && document.localError != nil)
        await finish(f)
    }

    @Test func genericChoiceIsCapturedWithoutChangingSQLOrSessionSettings() async throws {
        let f = try await fixture()
        let (document, draft) = try makeDraft(f, text: "SELECT :p", parameters: true)
        await f.workspace.runExplainSelection(draft, selected: Set(draft.statements.map(\.id)), targetID: draft.defaultTargetID, planKind: .generic)
        #expect(document.explainExecutions.first?.plan?.request.planKind == .generic)
        #expect(document.explainExecutions.first?.plan?.request.sql == "SELECT :p")
        #expect(try counts(f)["setups"] == 0 && document.runtime?.transactionStatus == .idle)
        await finish(f)
    }
    @Test func changingTheSourceDuringReviewConsumesNoExecution() async throws {
        var source: SQLDocument?
        let f = try await fixture(review: { _ in source?.text += " "; return true })
        let pair = try makeDraft(f, text: "SELECT 1; SELECT 2")
        source = pair.0
        await f.workspace.runExplainSelection(pair.1, selected: Set(pair.1.statements.map(\.id)),
            targetID: pair.1.defaultTargetID, planKind: nil)
        #expect(try counts(f)["assessments"] == 1 && counts(f)["executions"] == 0)
        #expect(source?.explainExecutions.last?.status == "Not executed")
        await finish(f)
    }

    @Test func changingParametersDuringEntryStartsNoHelper() async throws {
        var source: SQLDocument?
        let supplied = values
        let f = try await fixture(parameters: { _, _ in
            source?.queryParameters = [.init(name: "p", type: .integer)]
            return supplied
        })
        let pair = try makeDraft(f, text: "SELECT :p", parameters: true)
        source = pair.0
        await f.workspace.runExplainSelection(pair.1, selected: Set(pair.1.statements.map(\.id)),
            targetID: pair.1.defaultTargetID, planKind: nil)
        #expect(f.counter.helperStarts == 0 && source?.explainExecutions.first?.plan == nil)
        await finish(f)
    }

    @Test func disconnectingTheChosenTargetDuringParameterEntryDoesNotReconnectIt() async throws {
        var disconnectTarget: SQLDocument?
        let supplied = values
        let f = try await fixture(parameters: { _, _ in
            await disconnectTarget?.runtime?.disconnect()
            return supplied
        })
        let (target, first) = try makeDraft(f, text: "SELECT 1")
        await f.workspace.runExplainSelection(first, selected: Set(first.statements.map(\.id)),
            targetID: first.defaultTargetID, planKind: nil)
        disconnectTarget = target
        let (source, next) = try makeDraft(f, text: "SELECT :p", parameters: true)
        await f.workspace.runExplainSelection(next, selected: Set(next.statements.map(\.id)),
            targetID: target.id.uuidString, planKind: nil)
        #expect(try counts(f)["connects"] == 2 && counts(f)["executions"] == 1)
        #expect(source.explainExecutions.first?.plan == nil && target.runtime?.sessionId == nil)
        await finish(f)
    }

}
