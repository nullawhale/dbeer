import Foundation
import Testing
@testable import DBeer

/// Direct transport against a synthetic stdio peer. No database, persistence,
/// credentials, workspace, application, windows, views or decision presenters.
struct ExplainMetricsTransportTests {
    private func makeClient(_ scenario: String) -> BackendClient {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import copy,json,sys
        scenario,contract=sys.argv[1:]
        with open(contract) as source:evidence=json.load(source)['results'][0]
        support=evidence['support'];cap='explainMetricsV1';connections=0;executions=0
        def send(v):print(json.dumps(v),flush=True)
        for line in sys.stdin:
            c=json.loads(line);kind=c['type'];r=dict(type='',requestId=c['requestId'])
            if 'sessionId' in c:r['sessionId']=c['sessionId']
            if 'queryId' in c:r['queryId']=c['queryId']
            if kind=='hello':r.update(type='hello.ack',protocolVersion=6,capabilities=[] if scenario in ['missingHelper','legacy'] else [cap])
            elif kind=='connect':
                connections+=1
                caps=[] if scenario in ['missingOwner','legacy'] or scenario=='otherOwner' and connections>1 else [cap]
                r.update(type='connect.result',sessionId='owner-'+str(connections),transactionStatus='idle',engine='postgresql',capabilities=caps,explainSupport=support)
            elif kind=='explain.run':
                executions+=1
                send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
                result=copy.deepcopy(evidence)
                if scenario=='wrongSupport':result['support']['serverVersion']='different captured server'
                if scenario=='legacy':
                    result.pop('advancedMetrics',None)
                    for node in result['nodes']:node.pop('advancedMetrics',None)
                r.update(type='explain.result',transactionStatus='idle',sqlCompleted=True,durationMs=1,explain=result)
                if scenario=='physical' and executions==1:r['connected']=False
            elif kind=='disconnect':r.update(type='disconnect.ack')
            elif kind=='shutdown':
                r.update(type='shutdown.ack');send(r);break
            else:raise RuntimeError('unexpected request')
            send(r)
        """, scenario, root.appendingPathComponent("protocol/fixtures/explain-metrics-v1/contract.json").path])
    }
    private var settings: ConnectionSettings { .init(host: "localhost", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable") }
    private func explain(_ client: BackendClient, session: String) async throws -> BackendMessage {
        try await client.request(.explain(sessionId: session, request: .init(sql: "SELECT 1", mode: .analyze)))
    }

    @Test(arguments: ["paired", "legacy", "missingHelper", "missingOwner", "otherOwner", "wrongSupport"])
    func advancedEvidenceRequiresTheExactActiveOwnerAndBothCapabilities(_ scenario: String) async throws {
        let client = makeClient(scenario)
        do {
            try await client.start()
            let connected = try await client.request(.connect(settings))
            var session = try #require(connected.sessionId)
            if scenario == "otherOwner" { session = try #require(await client.request(.connect(settings)).sessionId) }
            if scenario == "paired" || scenario == "legacy" {
                let reply = try await explain(client, session: session)
                #expect(reply.explain?.valid == true)
                #expect((reply.explain?.advancedMetrics != nil) == (scenario == "paired"))
                #expect(await client.shutdown().acknowledged)
            } else {
                do { _ = try await explain(client, session: session); Issue.record("Unnegotiated or foreign advanced evidence must be rejected") }
                catch let error as BackendTransportError { #expect(error.code == .invalidMessage) }
                _ = await client.shutdown()
            }
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test(arguments: ["physical", "explicit"])
    func lostOwnershipRetiresMetricAdmissionWithoutDiscardingCompletedEvidence(_ scenario: String) async throws {
        let client = makeClient(scenario)
        do {
            try await client.start()
            let session = try #require(await client.request(.connect(settings)).sessionId)
            let completed = try await explain(client, session: session)
            #expect(completed.explain?.advancedMetrics != nil && completed.explain?.valid == true)
            if scenario == "explicit" { _ = try await client.request(.disconnect(sessionId: session)) }
            do { _ = try await explain(client, session: session); Issue.record("A retired owner must not admit another advanced plan") }
            catch let error as BackendTransportError { #expect(error.code == .invalidMessage) }
            #expect(completed.explain?.advancedMetrics != nil)
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }
}
