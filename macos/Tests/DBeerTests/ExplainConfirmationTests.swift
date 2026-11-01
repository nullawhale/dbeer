import Foundation
import Testing
@testable import DBeer

@MainActor
struct ExplainConfirmationTests {
    @Test func analyzeUsesOneInjectedReviewAndCancelSendsNoExecution() async throws {
        let profile = SavedConnection(name: "Synthetic Explain", settings: ConnectionSettings(host: "localhost", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable"))
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys
        def read():return json.loads(sys.stdin.readline())
        def send(v):print(json.dumps(v),flush=True)
        c=read();send(dict(type='hello.ack',requestId=c['requestId'],protocolVersion=5))
        c=read()
        if c['type']!='operation.assess' or c['operations'][0]['explain']['mode']!='analyze':sys.exit(31)
        support=dict(engine='postgresql',serverVersion='17.6',format='json',modes=['plan','analyze'])
        preview=dict(sql='EXPLAIN (ANALYZE TRUE, FORMAT JSON)\\nSELECT 1',mode='analyze',support=support)
        assessment=dict(decision='confirm',policy=dict(environment='unspecified',readOnly=False),operations=[dict(kind='read',statements=[],explain=preview)],authorization='once')
        send(dict(type='operation.assessment',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'],assessment=assessment))
        c=read()
        if c['type']!='cancel':sys.exit(32)
        send(dict(type='cancel.ack',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'],status='alreadyFinished'))
        c=read()
        if c['type']!='shutdown':sys.exit(33)
        send(dict(type='shutdown.ack',requestId=c['requestId']))
        """])
        var reviews: [OperationConfirmation] = []
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            executionDecision: { review in reviews.append(review); return false })
        try await client.start()
        let request = ExplainRequest(sql: "SELECT 1", mode: .analyze)
        let authorization = try await workspace.authorizeOperations([OperationRequest(type: "explain.run", explain: request)],
            sessionID: "tab-a", profile: profile, client: client, sourceSQL: request.sql)
        #expect(authorization == nil && reviews.count == 1)
        #expect(reviews.first?.sourceSQL == request.sql)
        #expect(reviews.first?.assessment.operations.first?.explain?.sql == "EXPLAIN (ANALYZE TRUE, FORMAT JSON)\nSELECT 1")
        #expect(reviews.first?.operations.first?.explain?.mode == .analyze)
        _ = await client.shutdown()
    }
}
