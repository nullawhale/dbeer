import Foundation
import Testing
@testable import DBeer

/// Synthetic stdio only. No databases, stores, workspace, windows or views.
struct MariaDBExplainTransportTests {
    private func client(_ scenario: String) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import copy,json,sys
        scenario=sys.argv[1];boundary=scenario.split('-')[-1];cap='explainDMLV1';connections=0;executions=0
        support=dict(engine='mariadb',serverVersion='10.11.19-MariaDB',format='json',modes=['plan','analyze'],dml=dict(estimated=True,estimatedForms=['update','delete'],analyze=['update','delete'],analyzeTargetExecution='executes'))
        if scenario=='legacyMySQL':support.update(engine='mysql',serverVersion='8.4.6');support.pop('dml')
        def send(v):print(json.dumps(v),flush=True)
        for line in sys.stdin:
            c=json.loads(line);kind=c['type'];r=dict(type='',requestId=c['requestId'])
            for key in ['sessionId','queryId']:
                if key in c:r[key]=c[key]
            if kind=='hello':r.update(type='hello.ack',protocolVersion=6,capabilities=[] if boundary=='missingHelper' else [cap])
            elif kind=='connect':
                connections+=1
                caps=[] if boundary=='missingOwner' or boundary=='otherOwner' and connections>1 else [cap]
                r.update(type='connect.result',sessionId='owner-'+str(connections),transactionStatus='idle',engine=support['engine'],capabilities=caps,explainSupport=support)
            elif kind=='operation.assess':
                q=c['operations'][0]['explain'];observed=copy.deepcopy(support)
                if scenario=='foreignPreview':observed['serverVersion']='11.4.9-MariaDB'
                if scenario=='missingPreviewDML':observed.pop('dml')
                if scenario=='mysqlPreview' or scenario.startswith('formatlessPreview-'):observed.update(engine='mysql',serverVersion='8.4.6');observed.pop('dml')
                preview=dict(sql='EXPLAIN FORMAT=JSON '+q['sql'],mode=q['mode'],support=observed,format='json')
                if scenario=='legacyMySQL' or scenario.startswith('formatlessPreview-'):preview.pop('format')
                if scenario=='unknownPreviewField':preview['retry']=True
                r.update(type='operation.assessment',assessment=dict(decision='allow',policy=dict(environment='unspecified',readOnly=False),operations=[dict(kind='read',statements=[],explain=preview)],authorization='once'))
            elif kind=='explain.run':
                executions+=1
                send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
                observed=copy.deepcopy(support)
                if scenario=='foreignResult':observed['serverVersion']='11.4.9-MariaDB'
                if scenario=='missingResultDML':observed.pop('dml')
                formatless=scenario.startswith('formatlessResult-') and (boundary!='physicalLoss' or executions>1)
                if scenario=='mysqlResult' or formatless:observed.update(engine='mysql',serverVersion='8.4.6');observed.pop('dml')
                result=dict(support=observed,mode=c['explain']['mode'],status='rawOnly',raw='Synthetic JSON plan',complete=True,diagnostic='Synthetic capture',roots=[],nodes=[],metrics={},format='json')
                if scenario=='legacyMySQL' or formatless:result.pop('format')
                if scenario=='unknownResultField':result['retry']=True
                r.update(type='explain.result',transactionStatus='idle',sqlCompleted=True,durationMs=1,explain=result)
                if boundary=='physicalLoss' and executions==1:r['connected']=False
            elif kind=='disconnect':r.update(type='disconnect.ack')
            elif kind=='shutdown':r.update(type='shutdown.ack');send(r);break
            else:raise RuntimeError('unexpected command')
            send(r)
        """, scenario])
    }

    private var settings: ConnectionSettings {
        .init(host: "localhost", port: 3306, database: "fixture", user: "fixture", password: "", sslMode: "disable", engine: .mariadb)
    }
    private func assess(_ client: BackendClient, session: String, request: ExplainRequest) async throws -> BackendMessage {
        try await client.request(.assess(sessionId: session, operations: [.init(type: "explain.run", explain: request)]))
    }
    private func formatlessSession(_ client: BackendClient, boundary: String) async throws -> String {
        var session = try #require(await client.request(.connect(settings)).sessionId)
        if boundary == "otherOwner" { session = try #require(await client.request(.connect(settings)).sessionId) }
        if boundary == "unknownOwner" { session = "unrecorded-owner" }
        if boundary == "retired" { _ = try await client.request(.disconnect(sessionId: session)) }
        if boundary == "physicalLoss" {
            let completed = try await client.request(.explain(sessionId: session, request: .init(sql: "SELECT 1", mode: .plan)))
            #expect(completed.connected == false && completed.explain?.valid == true && completed.explain?.format == "json")
        }
        return session
    }

    @Test(arguments: [ExplainMode.plan, .analyze])
    func fixedJSONNeedsNoOptionsNegotiation(_ mode: ExplainMode) async throws {
        let client = client("paired")
        do {
            try await client.start()
            let session = try #require(await client.request(.connect(settings)).sessionId)
            #expect(await client.supportsExplainOptions() == false)
            let request = ExplainRequest(sql: "SELECT 1", mode: mode)
            let assessment = try await assess(client, session: session, request: request)
            #expect(assessment.assessment?.operations.first?.explain?.format == "json")
            let result = try await client.request(.explain(sessionId: session, request: request))
            #expect(result.explain?.valid == true && result.explain?.format == "json" && result.explain?.options == nil)
            var forbidden = request
            forbidden.options = .init(mysql: .init(format: .json))
            do { _ = try await assess(client, session: session, request: forbidden); Issue.record("MariaDB must reject MySQL options") }
            catch { #expect(error as? BackendRequestError == .invalidCommand) }
            #expect(await client.shutdown().acknowledged)
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test(arguments: ["missingHelper", "missingOwner", "otherOwner", "foreignPreview", "missingPreviewDML", "mysqlPreview", "unknownPreviewField", "retired"])
    func previewRequiresExactActiveOwner(_ scenario: String) async throws {
        let client = client(scenario)
        do {
            try await client.start()
            var session = try #require(await client.request(.connect(settings)).sessionId)
            if scenario == "otherOwner" { session = try #require(await client.request(.connect(settings)).sessionId) }
            if scenario == "retired" { _ = try await client.request(.disconnect(sessionId: session)) }
            do { _ = try await assess(client, session: session, request: .init(sql: "SELECT 1", mode: .plan)); Issue.record("A foreign or retired MariaDB preview was accepted") }
            catch let error as BackendTransportError { #expect(error.code == .invalidMessage) }
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test(arguments: ["missingHelper", "missingOwner", "otherOwner", "foreignResult", "missingResultDML", "mysqlResult", "unknownResultField", "retired"])
    func resultRequiresExactActiveOwner(_ scenario: String) async throws {
        let client = client(scenario)
        do {
            try await client.start()
            var session = try #require(await client.request(.connect(settings)).sessionId)
            if scenario == "otherOwner" { session = try #require(await client.request(.connect(settings)).sessionId) }
            if scenario == "retired" { _ = try await client.request(.disconnect(sessionId: session)) }
            do { _ = try await client.request(.explain(sessionId: session, request: .init(sql: "SELECT 1", mode: .analyze))); Issue.record("A foreign or retired MariaDB result was accepted") }
            catch let error as BackendTransportError { #expect(error.code == .invalidMessage) }
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test(arguments: ["live", "missingHelper", "missingOwner", "otherOwner", "unknownOwner", "retired", "physicalLoss"])
    func formatlessForeignPreviewCannotSelectItsOwnPolicy(_ boundary: String) async throws {
        let client = client("formatlessPreview-" + boundary)
        do {
            try await client.start()
            let session = try await formatlessSession(client, boundary: boundary)
            do { _ = try await assess(client, session: session, request: .init(sql: "SELECT 1", mode: .plan)); Issue.record("A formatless foreign preview bypassed its MariaDB owner") }
            catch let error as BackendTransportError { #expect(error.code == .invalidMessage) }
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test(arguments: ["live", "missingHelper", "missingOwner", "otherOwner", "unknownOwner", "retired", "physicalLoss"])
    func formatlessForeignResultCannotSelectItsOwnPolicy(_ boundary: String) async throws {
        let client = client("formatlessResult-" + boundary)
        do {
            try await client.start()
            let session = try await formatlessSession(client, boundary: boundary)
            do { _ = try await client.request(.explain(sessionId: session, request: .init(sql: "SELECT 1", mode: .analyze))); Issue.record("A formatless foreign result bypassed its MariaDB owner") }
            catch let error as BackendTransportError { #expect(error.code == .invalidMessage) }
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test
    func formatlessMySQLKeepsExistingAdmission() async throws {
        let client = client("legacyMySQL")
        do {
            try await client.start()
            var connection = settings
            connection.engine = .mysql
            let session = try #require(await client.request(.connect(connection)).sessionId)
            let request = ExplainRequest(sql: "SELECT 1", mode: .plan)
            let assessment = try await assess(client, session: session, request: request)
            let preview = try #require(assessment.assessment?.operations.first?.explain)
            #expect(preview.support.engine == .mysql && preview.support.dml == nil && preview.format == nil)
            let completed = try await client.request(.explain(sessionId: session, request: request))
            let result = try #require(completed.explain)
            #expect(result.valid && result.support.engine == .mysql && result.support.dml == nil && result.format == nil)
            #expect(await client.shutdown().acknowledged)
        } catch { _ = await client.shutdown(); throw error }
    }
}
