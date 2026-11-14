import Foundation
import Testing
@testable import DBeer

/// Synthetic framed helper on private pipes; no database, UI, credentials,
/// preferences, application activation or default callbacks are used.
struct MigrationTransportTests {
    private func client(hello: Bool, owner: Bool) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        hello_cap=\(hello ? "True" : "False")
        owner_cap=\(owner ? "True" : "False")
        cap='tableStructureMigrationsV1'
        connects=0
        def send(v): print(json.dumps(v),flush=True)
        for line in sys.stdin:
            c=json.loads(line);typ=c['type'];base=dict(requestId=c['requestId'])
            if typ=='hello': send(dict(base,type='hello.ack',protocolVersion=6,capabilities=[cap] if hello_cap else []));continue
            if typ=='shutdown': send(dict(base,type='shutdown.ack'));break
            if typ=='connect':
                connects+=1
                send(dict(base,type='connect.result',sessionId='owner-'+str(connects),engine='postgresql',transactionStatus='idle',connected=True,capabilities=[cap] if owner_cap and connects==1 else []));continue
            base['sessionId']=c['sessionId']
            if typ=='disconnect':send(dict(base,type='disconnect.ack'));continue
            base['queryId']=c['queryId']
            send(dict(base,type='query.started'))
            if typ not in ['structure.migration.status','structure.migration.close']:
                send(dict(base,type='error',category='syntheticUnexpectedCommand',message='Unexpected command reached synthetic helper',connected=True,outcomeUnknown=False,sqlNotExecuted=True));continue
            send(dict(base,type=typ+'.result',connected=False,structure=dict(migration={})))
        """])
    }
    private var settings: ConnectionSettings { .init(host: "synthetic.invalid", port: 5432, database: "synthetic", user: "synthetic", password: "", sslMode: "disable") }
    private func command(_ operation: String, owner: String = "owner-1", apply: StructureApply? = nil, draft: StructureMigrationDraft? = nil) -> BackendCommand {
        .init(type: "structure.migration." + operation, requestId: UUID().uuidString, sessionId: owner, queryId: UUID().uuidString,
            structure: .init(migration: .init(draft: draft, apply: apply)))
    }
    @Test(arguments: [(false, true), (true, false)])
    func bothHelloAndLogicalOwnerMustAdvertiseMigrations(_ capabilities: (Bool, Bool)) async throws {
        let client = client(hello: capabilities.0, owner: capabilities.1)
        try await client.start(); _ = try await client.request(.connect(settings))
        do { _ = try await client.request(command("status")); Issue.record("A migration command without paired capability was sent.") }
        catch { #expect(error as? BackendRequestError == .invalidCommand) }
        let shutdown = await client.shutdown(); #expect(shutdown.acknowledged && !shutdown.forced)
    }
    @Test func retiredOwnerPermitsOnlyLocalStatusAndCloseUntilPositiveDisconnect() async throws {
        let client = client(hello: true, owner: true)
        try await client.start(); _ = try await client.request(.connect(settings))
        let first = try await client.request(command("status"))
        #expect(first.connected == false && first.structure?.migration != nil)
        _ = try await client.request(command("status"))
        let apply = StructureApply(planId: "plan", digest: String(repeating: "a", count: 64), executionId: "execution")
        for operation in ["apply", "export", "reconcile"] {
            do { _ = try await client.request(command(operation, apply: operation == "reconcile" ? nil : apply)); Issue.record("A retired owner admitted an active migration operation.") }
            catch { #expect(error as? BackendRequestError == .invalidCommand) }
        }
        let intent = StructureMigrationDraft(version: 1, objects: [.init(id: "object", target: .init(schema: "public", table: "sample", create: false), draft: .init(columns: [.init(name: "added", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))]), after: [])], repairs: [])
        do { _ = try await client.request(command("preview", draft: intent)); Issue.record("A retired owner admitted Preview.") }
        catch { #expect(error as? BackendRequestError == .invalidCommand) }
        do { _ = try await client.request(.assess(sessionId: "owner-1", operations: [.init(type: "structure.migration.apply", structure: apply)])); Issue.record("A retired owner admitted authorization.") }
        catch { #expect(error as? BackendRequestError == .invalidCommand) }
        // A new owner cannot inherit the old owner's capability or status.
        _ = try await client.request(.connect(settings))
        do { _ = try await client.request(command("status", owner: "owner-2")); Issue.record("A new owner inherited retained capability.") }
        catch { #expect(error as? BackendRequestError == .invalidCommand) }
        _ = try await client.request(command("close"))
        _ = try await client.request(command("status"))
        _ = try await client.request(.disconnect(sessionId: "owner-1"))
        do { _ = try await client.request(command("status")); Issue.record("A disconnected owner retained admission.") }
        catch { #expect(error as? BackendRequestError == .invalidCommand) }
        let shutdown = await client.shutdown(); #expect(shutdown.acknowledged && !shutdown.forced)
    }
}
