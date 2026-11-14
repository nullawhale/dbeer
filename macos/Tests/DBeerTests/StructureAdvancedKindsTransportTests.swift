import Foundation
import Testing
@testable import DBeer

/// Framed synthetic pipe replies only; no database, windows, AppKit or desktop.
@MainActor struct StructureAdvancedKindsTransportTests {
    @Test(arguments: [false, true], [false, true])
    func observationRequiresHelloAndOwningSessionCapabilities(hello: Bool, session: Bool) async throws {
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys
        def read(): return json.loads(sys.stdin.readline())
        def send(v): print(json.dumps(v),flush=True)
        cap='tableStructureAdvancedKindsV1'
        c=read();send(dict(type='hello.ack',requestId=c['requestId'],protocolVersion=6,capabilities=[cap] if \(hello ? "True" : "False") else []))
        kinds=['renameTable','renameColumn','addColumn','dropColumn','default','nullable','type','index','key','foreignKey','generation','reconstruction','hierarchy']
        advanced=dict(kinds=['rowSecurity'],scope='only',familyCount=1,nontransactional=False,operations=[dict(kind=k,available=True,reason='Synthetic concrete prerequisite.') for k in kinds])
        baseline=dict(id='baseline',target=dict(schema='app',table='secured',create=False),engine='postgresql',fingerprint='a'*64,columns=[],limitations=[],advanced=advanced)
        while True:
            c=read()
            if c['type']=='shutdown':
                send(dict(type='shutdown.ack',requestId=c['requestId']));break
            if c['type']=='connect':
                send(dict(type='connect.result',requestId=c['requestId'],sessionId='owning-session',engine='postgresql',transactionStatus='idle',connected=True,capabilities=[cap] if \(session ? "True" : "False") else []));continue
            send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
            send(dict(type=c['type']+'.result',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'],transactionStatus='idle',connected=True,structure=dict(baseline=baseline)))
        """])
        try await client.start()
        _ = try await client.request(.connect(.init(host: "synthetic.invalid", port: 5432, database: "synthetic", user: "synthetic", password: "", sslMode: "disable")))
        let command = BackendCommand(type: "structure.load", requestId: UUID().uuidString, sessionId: "owning-session", queryId: UUID().uuidString, structure: .init(target: .init(schema: "app", table: "secured", create: false)))
        if hello && session {
            let reply = try await client.request(command)
            #expect(reply.structure?.baseline?.advanced?.kinds == ["rowSecurity"])
        } else {
            await #expect(throws: BackendTransportError.self) { try await client.request(command) }
        }
        _ = await client.shutdown()
        _ = await client.waitForExit()
    }
}
