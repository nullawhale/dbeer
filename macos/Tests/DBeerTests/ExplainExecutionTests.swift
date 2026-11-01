import Foundation
import Testing
@testable import DBeer

@MainActor
struct ExplainExecutionTests {
    private func helper(_ body: String) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time
        def read(): return json.loads(sys.stdin.readline())
        def send(value): print(json.dumps(value), flush=True)
        def started(c): send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
        def plan(c, mode=None):
            evidence=dict(support=dict(engine='postgresql',serverVersion='17.6',format='json',modes=['plan','analyze']),mode=mode or c['explain']['mode'],status='rawOnly',raw='original raw plan',complete=True,diagnostic='SQL completed; unsupported visualization',roots=[],nodes=[],metrics={})
            send(dict(type='explain.result',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'],transactionStatus='transaction',durationMs=2.5,sqlCompleted=True,explain=evidence))
        c=read();send(dict(type='hello.ack',requestId=c['requestId'],protocolVersion=5))
        c=read();send(dict(type='connect.result',requestId=c['requestId'],sessionId='tab-a',transactionStatus='idle',engine='postgresql',capabilities=['visualExplainV1']))
        \(body)
        """])
    }
    private func connected(_ client: BackendClient) async -> WorkspaceModel {
        let model = WorkspaceModel(helperFactory: { client })
        await model.start(); await model.connect()
        return model
    }
    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(1)) }
        #expect(condition())
    }
    @Test func explainPreservesNormalResultsAndSessionTransaction() async {
        let client = helper("""
        c=read();started(c)
        send(dict(type='query.result',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'],transactionStatus='transaction',durationMs=1,columns=[dict(index=0,name='id',typeOid=23)],rows=[['42']],commandTag='SELECT 1',rowCount=1,displayedRowCount=1,truncated=False))
        c=read()
        if c['type']!='explain.run' or c.get('sql') is not None or c['explain']['mode']!='plan': sys.exit(31)
        started(c);plan(c)
        c=read();send(dict(type='shutdown.ack',requestId=c['requestId']))
        """)
        let model = await connected(client)
        await model.run(sql: "SELECT 42")
        let previous = model.result
        let source = model.sql
        let completion = await model.run(authorization: "reviewed", explain: ExplainRequest(sql: "SELECT 42", mode: .plan))
        #expect(model.result == previous)
        #expect(model.sql == source)
        #expect(model.transactionStatus == .transaction)
        #expect(completion?.reply?.explain?.status == "rawOnly")
        #expect(completion?.reply?.sqlCompleted == true && completion?.failure == nil)
        #expect(!model.isExecuting)
        await model.shutdown()
    }
    @Test func cancelAcknowledgementDoesNotUnlockBeforeTerminal() async throws {
        let client = helper("""
        c=read();started(c)
        stop=read();send(dict(type='cancel.ack',requestId=stop['requestId'],sessionId=stop['sessionId'],queryId=stop['queryId'],status='accepted'))
        time.sleep(0.2);plan(c)
        c=read();send(dict(type='shutdown.ack',requestId=c['requestId']))
        """)
        let model = await connected(client)
        let task = Task { await model.run(authorization: "reviewed", explain: ExplainRequest(sql: "SELECT 1", mode: .analyze)) }
        try await eventually { model.queryPhase == .running }
        await model.stop()
        #expect(model.isExecuting && model.queryPhase == .cancelling)
        let completion = await task.value
        #expect(completion?.reply?.sqlCompleted == true && completion?.failure == nil)
        #expect(!model.isExecuting && model.transactionStatus == .transaction)
        await model.shutdown()
    }
    @Test func lostCompletionAndWrongModeStayUnknownWithoutReplay() async {
        for wrongMode in [false, true] {
            let client = helper(wrongMode ? "c=read();started(c);plan(c,mode='plan');time.sleep(0.2)" : "c=read();started(c);sys.exit(0)")
            let model = await connected(client)
            let completion = await model.run(authorization: "reviewed", explain: ExplainRequest(sql: "SELECT 1", mode: .analyze))
            #expect(completion?.failure?.outcomeUnknown == true)
            #expect(completion?.reply?.explain == nil)
            await model.shutdown()
        }
    }
}
