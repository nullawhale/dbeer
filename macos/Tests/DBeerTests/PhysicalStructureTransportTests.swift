import Foundation
import Testing
@testable import DBeer

/// Private framed Python peers only. No credentials, real databases, native
/// presenters, views, windows, preferences or application activation.
struct PhysicalStructureTransportTests {
    private func client(hello: Bool = true, owner: Bool = true, malformedApply: Bool = false, statusIdentity: String = "normal") -> BackendClient {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("protocol/fixtures/table-structure-physical-v1.json")
        return BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys
        cap='tableStructurePhysicalV1';serial=0;status_identity='\(statusIdentity)'
        hello=\(hello ? "True" : "False");owner=\(owner ? "True" : "False");malformed=\(malformedApply ? "True" : "False")
        fixture=json.load(open(sys.argv[1]))
        plan=next(x['structure']['physical']['plan'] for x in fixture['validReplies'] if x['type']=='structure.physical.preview.result')
        def send(v): print(json.dumps(v),flush=True)
        for line in sys.stdin:
            c=json.loads(line);typ=c['type'];base=dict(requestId=c['requestId'])
            if typ=='hello':send(dict(base,type='hello.ack',protocolVersion=6,capabilities=[cap] if hello else []));continue
            if typ=='shutdown':send(dict(base,type='shutdown.ack'));break
            if typ=='connect':
                serial+=1;send(dict(base,type='connect.result',sessionId='owner-'+str(serial),engine='postgresql',transactionStatus='idle',connected=True,capabilities=[cap] if owner and serial==1 else []));continue
            base['sessionId']=c['sessionId']
            if typ=='disconnect':send(dict(base,type='disconnect.ack'));continue
            base['queryId']=c['queryId']
            if typ!='structure.physical.status':send(dict(base,type='query.started'))
            if typ=='structure.physical.apply' and malformed:
                apply=c['structure']['physical']['apply']
                outcome=dict(executionId='wrong-execution',planId=apply['planId'],state='applied',phase='finished',steps=[dict(state='applied')],reconciled=True)
                send(dict(base,type=typ+'.result',transactionStatus='idle',connected=True,structure=dict(physical=dict(draft=plan['draft'],outcome=outcome))));continue
            if typ not in ['structure.physical.status','structure.physical.close']:
                send(dict(base,type='error',category='syntheticUnexpectedCommand',message='Unexpected command reached peer',connected=True,outcomeUnknown=False,sqlNotExecuted=True));continue
            if typ=='structure.physical.status' and status_identity!='normal':
                if status_identity=='request':base.pop('requestId')
                elif status_identity=='session':base['sessionId']='different-owner'
                else:base['queryId']='different-query'
            send(dict(base,type=typ+'.result',connected=False,structure=dict(physical={})))
        """, fixture.path])
    }
    private var settings: ConnectionSettings { .init(host: "synthetic.invalid", port: 5432, database: "synthetic", user: "synthetic", password: "", sslMode: "disable") }
    private func command(_ operation: String, owner: String = "owner-1", payload: StructurePhysicalRequest = .init()) -> BackendCommand {
        .init(type: "structure.physical." + operation, requestId: UUID().uuidString, sessionId: owner, queryId: UUID().uuidString, structure: .init(physical: payload))
    }
    @Test(arguments: [(false, true), (true, false)])
    func bothHelperAndOriginalLogicalOwnerMustAdvertisePhysicalCapability(_ capabilities: (Bool, Bool)) async throws {
        let client = client(hello: capabilities.0, owner: capabilities.1)
        try await client.start(); _ = try await client.request(.connect(settings))
        do { _ = try await client.request(command("status")); Issue.record("Physical request without paired capability was sent.") }
        catch { #expect(error as? BackendRequestError == .invalidCommand) }
        let shutdown = await client.shutdown(); #expect(shutdown.acknowledged && !shutdown.forced)
    }
    @Test func disconnectedPhysicalOwnerRetainsOnlyLocalStatusAndClose() async throws {
        let client = client()
        try await client.start(); _ = try await client.request(.connect(settings))
        let first = try await client.request(command("status"))
        #expect(first.connected == false && first.structure?.physical != nil)
        _ = try await client.request(command("status"))
        let apply = StructureApply(planId: "plan", digest: String(repeating: "a", count: 64), executionId: "execution")
        let target = StructureTarget(schema: "app", table: "p", create: false)
        let draft = StructurePhysicalDraft(version: 1, target: target, intent: .init(kind: "concurrentIndex", index: .init(action: "drop", name: "index")))
        for payload in [("apply", StructurePhysicalRequest(apply: apply)), ("preview", .init(draft: draft)), ("inspect", .init(target: target)), ("reconcile", .init())] {
            do { _ = try await client.request(command(payload.0, payload: payload.1)); Issue.record("Retired owner admitted active physical work.") }
            catch { #expect(error as? BackendRequestError == .invalidCommand) }
        }
        do { _ = try await client.request(.assess(sessionId: "owner-1", operations: [.init(type: "structure.physical.apply", structure: apply)])); Issue.record("Retired owner admitted assessment.") }
        catch { #expect(error as? BackendRequestError == .invalidCommand) }
        _ = try await client.request(.connect(settings))
        do { _ = try await client.request(command("status", owner: "owner-2")); Issue.record("New owner inherited old physical capability.") }
        catch { #expect(error as? BackendRequestError == .invalidCommand) }
        _ = try await client.request(command("close")); _ = try await client.request(command("status"))
        _ = try await client.request(.disconnect(sessionId: "owner-1"))
        do { _ = try await client.request(command("status")); Issue.record("Positively disconnected owner kept status admission.") }
        catch { #expect(error as? BackendRequestError == .invalidCommand) }
        let shutdown = await client.shutdown(); #expect(shutdown.acknowledged && !shutdown.forced)
    }
    @Test(arguments: ["request", "session", "query"])
    func retainedStatusWithoutStartedStillRequiresEveryOriginalIdentifier(_ identity: String) async throws {
        let client = client(statusIdentity: identity)
        try await client.start(); _ = try await client.request(.connect(settings))
        do { _ = try await client.request(command("status")); Issue.record("Mismatched retained status identity was accepted.") }
        catch let failure as BackendTransportError { #expect(failure.code == .invalidMessage && !failure.outcomeUnknown) }
        _ = await client.shutdown()
    }
    @Test func wrongExecutionTerminalFailsClosedWithPossibleApplyOutcome() async throws {
        let client = client(malformedApply: true)
        try await client.start(); _ = try await client.request(.connect(settings))
        let apply = StructureApply(planId: "plan", digest: String(repeating: "a", count: 64), executionId: "exact-execution")
        do { _ = try await client.request(command("apply", payload: .init(apply: apply))); Issue.record("Wrong execution ID was accepted.") }
        catch let failure as BackendTransportError { #expect(failure.code == .invalidMessage && failure.outcomeUnknown) }
        _ = await client.shutdown()
    }
}
