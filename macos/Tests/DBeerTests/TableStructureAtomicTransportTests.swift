import Foundation
import Testing
@testable import DBeer

@MainActor
struct TableStructureAtomicTransportTests {
    @Test func unknownAtomicCommitRetainsSharedHelperAndOriginalStatusEvidence() async throws {
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        def read(): return json.loads(sys.stdin.readline())
        def send(v): print(json.dumps(v),flush=True)
        c=read();send(dict(type='hello.ack',requestId=c['requestId'],protocolVersion=6))
        target=dict(schema='main',table='before',create=False)
        baseline=dict(id='baseline',target=target,engine='sqlite',fingerprint='a'*64,columns=[],limitations=[])
        plan=dict(id='plan',baselineId='baseline',digest='b'*64,target=target,sql=['synthetic atomic step one','synthetic atomic step two'],risks=[])
        outcome=None
        while True:
            c=read()
            if c['type']=='shutdown':
                send(dict(type='shutdown.ack',requestId=c['requestId']));break
            send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
            if c['type']=='structure.load': payload=dict(baseline=baseline)
            elif c['type']=='structure.preview': payload=dict(plan=plan)
            elif c['type']=='structure.apply':
                a=c['structure']['apply']
                outcome=dict(executionId=a['executionId'],planId=a['planId'],state='outcomeUnknown',steps=[dict(state='unknown'),dict(state='unknown')])
                payload=dict(outcome=outcome)
            elif c['type']=='structure.status': payload=dict(outcome=outcome)
            else: payload={}
            send(dict(type=c['type']+'.result',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'],transactionStatus='idle',connected=True,structure=payload))
        """])
        try await client.start()
        let profile = SavedConnection(name: "Synthetic atomic transport", settings: .init(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite, sqlite: .init(path: "/synthetic/unused.sqlite")))
        let model = TableStructureEditorModel(profile: profile, schema: "main", table: "before", create: false,
            connect: { "original-session" }, send: { try await client.request($0) }, authorize: { _, _, _ in "grant" },
            bindingIsCurrent: { true }, authoringSupported: { true }, changed: { _ in })
        await model.load()
        model.draft.columns = ["first", "second"].map { .init(name: $0, type: .init(kind: "integer"), nullable: true, default: .init(kind: "none")) }
        await model.preparePreview()
        try #require(model.canApply)
        await model.apply()
        let original = try #require(model.outcomeReview)
        #expect(original.outcome.state == "outcomeUnknown" && original.outcome.steps.allSatisfy { $0.state == "unknown" })
        #expect(!(await client.hasExited()) && model.canCheckExecutionStatus && !model.canApply)
        await model.checkExecutionStatus()
        #expect(model.error == nil && model.outcomeReview?.outcome.executionId == original.outcome.executionId)
        #expect(model.outcomeReview?.plan == original.plan && model.outcomeReview?.outcome.steps.allSatisfy { $0.state == "unknown" } == true)
        #expect(!(await client.hasExited()) && !model.canApply)
        let shutdown = await client.shutdown()
        #expect(shutdown.acknowledged && !shutdown.forced)
        #expect(await client.waitForExit().status == 0)
    }
}
