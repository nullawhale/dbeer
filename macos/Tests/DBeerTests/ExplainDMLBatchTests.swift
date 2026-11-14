import Foundation
import Testing
@testable import DBeer

/// Private stores, pipe peer and injected decisions. No default prompts,
/// application, windows, views, credentials, SSH or database connections.
@Suite(.serialized)
@MainActor
struct ExplainDMLBatchTests {
    private final class Decisions { var reviews: [OperationConfirmation] = []; var helperStarts = 0; var options = 0 }
    private struct Fixture {
        let workspace: ApplicationWorkspace
        let client: BackendClient
        let profile: SavedConnection
        let decisions: Decisions
        let root: URL
        let defaultsName: String
    }
    private func fixture(transaction: String = "idle", scenario: String = "", readOnly: Bool = false,
                         review: (@MainActor (OperationConfirmation) async -> Bool)? = nil,
                         options: (@MainActor (ExplainOptionsConfiguration) async -> ExplainOptionsDecision?)? = nil) async throws -> Fixture {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent("build/explain-dml-batch/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys,os,copy
        root,initial,scenario=sys.argv[1:];sessions={};grants={};counts=dict(connects=0,classifications=0,assessments=0,executions=0)
        caps=['execute','cancel','transactions','visualExplainV1','explainDMLV1','explainParametersV1','queryParametersV1','explainOptionsV1']
        support=dict(engine='postgresql',serverVersion='17.6',format='json',modes=['plan','analyze'],dml=dict(estimated=True,analyze=['insert','update','delete','dataModifyingCTE'],analyzeTargetExecution='executes'),options=dict(postgresql=dict(plan=['buffers'],analyze=['timing'])))
        def send(v):print(json.dumps(v),flush=True)
        def started(c):send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
        def record():
            with open(os.path.join(root,'counts.json'),'w') as f:json.dump(counts,f)
        for line in sys.stdin:
            c=json.loads(line);kind=c['type'];r=dict(type='',requestId=c['requestId'])
            for key in ['sessionId','queryId']:
                if key in c:r[key]=c[key]
            if kind=='hello':r.update(type='hello.ack',protocolVersion=6,capabilities=caps)
            elif kind=='connect':
                counts['connects']+=1;sid='owner-'+str(counts['connects']);sessions[sid]=(initial,c['connection'].get('policy',dict(environment='unspecified',readOnly=False)))
                r.update(type='connect.result',sessionId=sid,transactionStatus=initial,engine='postgresql',capabilities=caps,explainSupport=support)
            elif kind=='catalog':
                started(c);r.update(type='query.result',transactionStatus=sessions[c['sessionId']][0],durationMs=0,columns=[],rows=[],commandTag='SELECT 0',rowCount=0,displayedRowCount=0,truncated=False)
            elif kind=='operation.assess':
                assert len(c['operations'])==1 and c['operations'][0]['type']=='explain.run'
                q=c['operations'][0]['explain'];tx,policy=sessions[c['sessionId']];assert q['context']['sessionId']==c['sessionId'] and q['context']['transactionStatus']==tx
                if q['mode']=='plan':
                    counts['classifications']+=1;assert 'writeIntent' not in q and 'options' not in q
                else:
                    counts['assessments']+=1;assert q['writeIntent']==dict(disposition='currentSession',expectedTransactionStatus=tx)
                    assert q['options']==dict(postgresql=dict(timing=False))
                target=dict(statement=q['sql'].split()[0].lower(),dataModifyingCTE=False,mysqlMultiTable=False)
                preview=dict(sql='EXPLAIN '+q['sql'],mode=q['mode'],support=support,dml=target,format='json')
                if 'options' in q:preview['options']=q['options']
                token='grant-'+str(counts['classifications'])+'-'+str(counts['assessments']);grants[token]=(c['sessionId'],copy.deepcopy(q),target)
                r.update(type='operation.assessment',assessment=dict(decision='confirm',policy=policy,operations=[dict(kind='write',statements=[],explain=preview)],authorization=token))
            elif kind=='explain.run':
                sid,q,target=grants.pop(c['authorization']);assert sid==c['sessionId'] and q==c['explain'] and q['mode']=='analyze'
                counts['executions']+=1;started(c);tx,policy=sessions[sid]
                after='transaction' if scenario=='implicitTransaction' else tx
                facts=dict(target=target,execution='completed',persistence='transactionPending' if after=='transaction' else 'committed',transactionBefore=tx,transactionAfter=after,affectedRowsUnavailableReason='notReported',targetExecution='executed')
                if scenario in ['lostReady','unknownCommit']:
                    facts.update(execution='unknown' if scenario=='lostReady' else 'completed',persistence='unknown',transactionAfter='unknown',targetExecution='unknown' if scenario=='lostReady' else 'executed')
                    r.update(type='error',category='connection',message='Synthetic acknowledgement loss',connected=False,outcomeUnknown=True,explainDML=facts)
                    if scenario=='unknownCommit':r['sqlCompleted']=True
                else:
                    sessions[sid]=(after,policy)
                    result=dict(support=support,mode='analyze',status='rawOnly',raw='Synthetic DML plan',complete=True,diagnostic='Synthetic capture',roots=[],nodes=[],metrics={},dml=facts,options=q['options'],format='json')
                    r.update(type='explain.result',transactionStatus=after,durationMs=1,sqlCompleted=True,explain=result)
            elif kind=='cancel':r.update(type='cancel.ack',status='alreadyFinished')
            elif kind=='disconnect':r.update(type='disconnect.ack')
            elif kind=='shutdown':r.update(type='shutdown.ack');record();send(r);break
            else:raise RuntimeError('No setup, hidden transaction or retry is permitted: '+kind)
            record();send(r)
        """, root.path, transaction, scenario])
        let profile = SavedConnection(name: "Synthetic DML target", settings: .init(host: "127.0.0.1", port: 5432,
            database: "fixture", user: "fixture", password: "", sslMode: "disable", policy: .init(environment: .production, readOnly: readOnly)))
        let decisions = Decisions()
        let defaultsName = "dbeer-explain-dml-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let themes = EditorThemeStore(defaults: defaults, directory: root.appendingPathComponent("themes"))
        let snapshots = ResultSnapshotStore(rootURL: root.appendingPathComponent("snapshots"))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id)),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
            commandShortcuts: AppShortcutStore(defaults: defaults), copySettings: ResultCopySettings(defaults: defaults),
            editorThemes: themes, appearance: AppAppearance(defaults: defaults, editorThemes: themes),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: SQLLibrary(),
            tableBrowsePresets: TableBrowsePresetStore(fileURL: root.appendingPathComponent("presets.json")),
            logicalRelationships: LogicalRelationshipStore(fileURL: root.appendingPathComponent("relationships.json")),
            resultSnapshots: ResultSnapshotsModel(store: snapshots),
            planArtifacts: PlanArtifactsModel(store: PlanArtifactStore(rootURL: root.appendingPathComponent("plans"))),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .rollback }, executionDecision: {
                decisions.reviews.append($0)
                return await review?($0) ?? true
            }, queryParameterDecision: { _, _ in [.init(name: "p", type: .text, value: "e\u{0301}' ; DELETE FROM excluded; --")] },
            explainOptionsDecision: {
                decisions.options += 1
                if let options { return await options($0) }
                return .use(.init(postgresql: .init(timing: false)))
            }, helperFactory: { decisions.helperStarts += 1; return client })
        await workspace.library.loadConnections()
        return Fixture(workspace: workspace, client: client, profile: profile, decisions: decisions, root: root, defaultsName: defaultsName)
    }
    private func run(_ fixture: Fixture, text: String = "UPDATE fixture SET value = :p; DELETE FROM fixture WHERE value = :p") async throws -> SQLDocument {
        let document = fixture.workspace.newDocument(profileID: fixture.profile.id, text: text)
        document.queryParameters = [.init(name: "p", type: .text)]
        fixture.workspace.beginExplainSelection(document, mode: .analyze, selections: [NSRange(location: 0, length: text.utf16.count)])
        let draft = try #require(fixture.workspace.explainSelection)
        fixture.workspace.explainSelection = nil
        await fixture.workspace.runExplainSelection(draft, selected: Set(draft.statements.map(\.id)), targetID: draft.defaultTargetID, planKind: nil)
        return document
    }
    private func counts(_ fixture: Fixture) throws -> [String: Int] {
        try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: fixture.root.appendingPathComponent("counts.json")))
    }
    private func finish(_ fixture: Fixture) async {
        await fixture.workspace.shutdown()
        if fixture.decisions.helperStarts > 0 { #expect(await fixture.client.waitForExit().status == 0) }
        UserDefaults(suiteName: fixture.defaultsName)?.removePersistentDomain(forName: fixture.defaultsName)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @Test(arguments: ["idle", "transaction"])
    func everyActualDMLHasSeparateClassificationExactReviewAndCurrentSessionIntent(_ transaction: String) async throws {
        let f = try await fixture(transaction: transaction)
        let source = try await run(f)
        #expect(f.decisions.reviews.count == 2 && f.decisions.options == 2)
        #expect(try counts(f)["classifications"] == 2 && counts(f)["assessments"] == 2 && counts(f)["executions"] == 2)
        #expect(try counts(f)["connects"] == 2) // Service and the chosen physical SQL tab.
        #expect(source.explainExecutions.allSatisfy { $0.plan?.request.writeIntent?.expectedTransactionStatus == transaction })
        #expect(source.explainExecutions.allSatisfy { $0.plan?.dmlOutcome?.persistence == (transaction == "transaction" ? "transactionPending" : "committed") })
        #expect(source.runtime?.transactionStatus?.rawValue == transaction)
        #expect(f.decisions.reviews.allSatisfy { $0.operations.first?.explain?.parameters?.first?.value == "e\u{0301}' ; DELETE FROM excluded; --" })
        await finish(f)
    }

    @Test func implicitTransactionIsReportedFromTheAcknowledgedAfterState() async throws {
        let f = try await fixture(scenario: "implicitTransaction")
        let source = try await run(f, text: "UPDATE fixture SET value = :p")
        #expect(source.explainPlan?.dmlOutcome?.transactionBefore == "idle")
        #expect(source.explainPlan?.dmlOutcome?.transactionAfter == "transaction")
        #expect(source.explainPlan?.dmlOutcome?.persistence == "transactionPending")
        #expect(source.runtime?.transactionStatus == .transaction)
        await finish(f)
    }

    @Test(arguments: ["lostReady", "unknownCommit"])
    func uncertainFirstDMLNeverClassifiesOrRunsTheNextStatement(_ scenario: String) async throws {
        let f = try await fixture(scenario: scenario)
        let source = try await run(f)
        #expect(try counts(f)["classifications"] == 1 && counts(f)["assessments"] == 1 && counts(f)["executions"] == 1)
        #expect(source.explainExecutions[1].status == "Not executed")
        #expect(source.explainPlan?.dmlOutcome?.persistence == "unknown")
        #expect(source.explainPlan?.failure?.sqlCompleted == (scenario == "unknownCommit"))
        #expect(source.runtime?.sessionId == nil)
        await finish(f)
    }

    @Test func decliningActualDMLConsumesNoExecutionAndDoesNotFallBack() async throws {
        let f = try await fixture(review: { _ in false })
        let source = try await run(f)
        #expect(try counts(f)["classifications"] == 1 && counts(f)["assessments"] == 1 && counts(f)["executions"] == 0)
        #expect(f.decisions.reviews.count == 1 && source.explainPlan?.status == "Not executed — review cancelled")
        await finish(f)
    }

    @Test func readonlyNeverClassifiesOrReviewsActualDML() async throws {
        let f = try await fixture(readOnly: true)
        let source = try await run(f)
        #expect(try counts(f)["classifications"] == 0 && counts(f)["assessments"] == 0 && counts(f)["executions"] == 0)
        #expect(f.decisions.reviews.isEmpty && source.localError != nil)
        await finish(f)
    }

    @Test(arguments: ["source", "disconnect"])
    func changedContextAfterActualReviewNeverExecutesOrReconnects(_ mutation: String) async throws {
        var source: SQLDocument?
        let f = try await fixture(review: { _ in
            if mutation == "source" { source?.text += " " }
            else { await source?.runtime?.disconnect() }
            return true
        })
        let text = "UPDATE fixture SET value = :p"
        let document = f.workspace.newDocument(profileID: f.profile.id, text: text)
        source = document
        document.queryParameters = [.init(name: "p", type: .text)]
        f.workspace.beginExplainSelection(document, mode: .analyze, selections: [NSRange(location: 0, length: text.utf16.count)])
        let draft = try #require(f.workspace.explainSelection); f.workspace.explainSelection = nil
        await f.workspace.runExplainSelection(draft, selected: Set(draft.statements.map(\.id)), targetID: draft.defaultTargetID, planKind: nil)
        #expect(try counts(f)["classifications"] == 1 && counts(f)["assessments"] == 1 && counts(f)["executions"] == 0)
        #expect(try counts(f)["connects"] == 2)
        if mutation == "disconnect" { #expect(document.runtime?.sessionId == nil) }
        await finish(f)
    }

    @Test func cancellingOptionsStartsNoClassificationReviewOrMutation() async throws {
        let f = try await fixture(options: { _ in nil })
        _ = try await run(f)
        #expect(try counts(f)["classifications"] == 0 && counts(f)["assessments"] == 0 && counts(f)["executions"] == 0)
        #expect(f.decisions.options == 1 && f.decisions.reviews.isEmpty)
        await finish(f)
    }

}
