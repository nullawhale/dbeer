import Foundation
import Testing
@testable import DBeer

/// In-memory owners, injected decisions and framed synthetic subprocesses only.
/// No AppKit, views, windows, application activation, SSH or credential access.
@MainActor
private final class ReconstructionBackend {
    var available = true
    var current = true
    var approve = true
    var loseApply = false
    var concurrentChange = false
    var holdApply = false
    var applyGate: CheckedContinuation<Void, Never>?
    var state = "applied"
    var commands: [BackendCommand] = []
    var confirmations: [StructurePlan] = []
    var grants = 0
    var connections = 0
    var beforeConfirmation: (() -> Void)?
    var retained: StructureOutcome?
    var submitted = StructureDraft(columns: [])
    let target = StructureTarget(schema: "public", table: "synthetic", create: false)
    var baseline: StructureBaseline {
        .init(id: "baseline", target: target, engine: "postgresql", fingerprint: String(repeating: "a", count: 64),
            columns: ["é", "é"].map { .init(name: $0, nativeType: "text", nullable: true) }, limitations: [], dependencyProof: true)
    }
    var plan: StructurePlan {
        .init(id: "plan", baselineId: "baseline", digest: String(repeating: "b", count: 64), target: target,
            sql: submitted.backfills?.isEmpty == false ? ["synthetic add", "synthetic UPDATE with exact expression", "synthetic require"] : ["synthetic physical reconstruction"], risks: ["Stored rows may be rewritten."], destructive: true)
    }
    var physical: StructureDraft { .init(columns: [], allowDestructive: true, columnOrder: ["é", "é"], reconstruct: true) }
    func model() -> TableStructureEditorModel {
        .init(profile: .init(name: "Synthetic", settings: .init(host: "synthetic.invalid", port: 5432, database: "synthetic", user: "fixture", password: "", sslMode: "disable")),
            schema: target.schema, table: target.table, create: false,
            connect: { self.connections += 1; return "session" }, send: request,
            authorize: { _, _, _ in self.grants += 1; return "grant" }, bindingIsCurrent: { self.current },
            authoringSupported: { true }, indexAuthoringSupported: { true }, destructiveSupported: { true }, reconstructionSupported: { self.available },
            confirmPlan: { plan, _ in self.confirmations.append(plan); self.beforeConfirmation?(); return self.approve },
            authorizeValidation: { _, _, _ in Issue.record("No validation checks were disclosed."); return nil },
            sessionIsKnownClosed: { false }, changed: { _ in })
    }
    func request(_ command: BackendCommand) async throws -> BackendMessage {
        commands.append(command)
        if command.type == "disconnect" { return .init(type: "disconnect.ack", requestId: command.requestId, sessionId: command.sessionId) }
        if command.type == "cancel" { return .init(type: "cancel.ack", requestId: command.requestId, sessionId: command.sessionId, queryId: command.queryId) }
        var reply = BackendMessage(type: command.type + ".result", requestId: command.requestId, sessionId: command.sessionId, queryId: command.queryId, transactionStatus: .idle, connected: true)
        switch command.type {
        case "structure.load": reply.structure = .init(baseline: baseline)
        case "structure.preview": submitted = try #require(command.structure?.draft); reply.structure = .init(plan: plan)
        case "structure.apply":
            let apply = try #require(command.structure?.apply)
            if holdApply { await withCheckedContinuation { applyGate = $0 } }
            if concurrentChange {
                var failure = BackendMessage(type: "error", requestId: command.requestId, sessionId: command.sessionId, queryId: command.queryId)
                failure.connected = true; failure.sqlNotExecuted = true; failure.outcomeUnknown = false
                failure.message = "The loaded structure changed concurrently."
                throw BackendRemoteError(reply: failure)
            }
            let states = state == "partiallyApplied" ? ["applied", "failed", "notStarted"] : state == "cancelled" ? ["rolledBack", "notStarted", "notStarted"] : plan.sql.map { _ in "applied" }
            retained = .init(executionId: apply.executionId, planId: apply.planId, state: state, steps: states.map { .init(state: $0) }, observed: baseline)
            if loseApply { throw BackendTransportError(.unexpectedEOF, outcomeUnknown: true) }
            reply.structure = .init(outcome: retained)
        case "structure.status": reply.structure = .init(outcome: retained)
        default: throw BackendTransportError(.invalidMessage)
        }
        return reply
    }
}

@MainActor
struct TableStructureReconstructionModelTests {
    @Test func physicalOnlyIntentRequiresCapabilityOptInAndExactConfirmation() async throws {
        let backend = ReconstructionBackend(), model = backend.model()
        await model.load(); backend.available = false; model.draft = backend.physical
        #expect(model.draft.authoringVersion == 5 && model.canSaveDraft && !model.canPreview)
        backend.available = true; model.draft.allowDestructive = nil
        #expect(!model.canPreview)
        model.draft.allowDestructive = true; await model.preparePreview()
        let plan = try #require(model.preview)
        #expect(plan.validationChecks.isEmpty && !model.canValidateData && backend.confirmations.isEmpty)
        await model.validateData()
        backend.approve = false; await model.apply()
        #expect(backend.confirmations == [plan] && backend.grants == 0 && model.preview == plan && model.outcome == nil)
        backend.approve = true; await model.apply()
        #expect(backend.confirmations == [plan, plan] && backend.grants == 1 && model.outcome?.state == "applied")
        #expect(backend.commands.filter { $0.type == "structure.validate" }.isEmpty)
    }

    @Test(arguments: ["draft", "capability", "binding"])
    func suspendedConfirmationCannotAuthorizeChangedIntent(change: String) async {
        let backend = ReconstructionBackend(), model = backend.model()
        await model.load(); model.draft = backend.physical; await model.preparePreview()
        backend.beforeConfirmation = {
            if change == "draft" { model.draft.reconstruct = nil }
            else if change == "capability" { backend.available = false }
            else { backend.current = false }
        }
        await model.apply()
        #expect(backend.grants == 0 && !backend.commands.contains { $0.type == "structure.apply" } && model.error != nil)
    }

    @Test func exactOrderDistinguishesCanonicallyEquivalentIdentifiersAndRejectsStaleLists() async {
        let backend = ReconstructionBackend(), model = backend.model()
        await model.load(); model.draft = backend.physical
        #expect(model.hasExactReconstructionOrder && model.canPreview)
        model.draft.columnOrder = ["é", "é"]
        #expect(!model.hasExactReconstructionOrder && !model.canPreview)
        model.draft.columnOrder = ["é", "é"]; model.moveReconstructionColumn(at: 0, by: 1)
        #expect(model.draft.columnOrder?.first?.utf8.elementsEqual("é".utf8) == true && model.draft.allowDestructive == nil)
        model.draft.allowDestructive = true
        model.draft.columns = [.init(name: "required", type: .init(kind: "integer"), nullable: false, default: .init(kind: "none"))]
        model.draft.backfills = [.init(column: "required", expression: "7")]
        #expect(!model.hasExactReconstructionOrder && !model.canPreview)
        model.draft.columnOrder = model.reconstructionColumnNames
        #expect(model.hasExactReconstructionOrder && model.canPreview)
    }

    @Test func removingE4IntentDowngradesToActualRemainingIntent() async {
        let backend = ReconstructionBackend(), model = backend.model()
        model.draft = .init(columns: [], changes: [.init(name: "é", type: .init(kind: "integer"))], authoringVersion: 5, reconstruct: true)
        #expect(model.draft.authoringVersion == 5)
        model.draft.reconstruct = nil
        #expect(model.draft.authoringVersion == 4)
        model.draft.changes = nil
        model.draft.indexes = [.init(action: "add", name: "rich", definition: .init(method: "btree", terms: [.init(column: "é")]))]
        #expect(model.draft.authoringVersion == 3)
        model.draft.indexes = nil; model.draft.renameTable = "result"
        #expect(model.draft.authoringVersion == 2)
        model.draft.renameTable = nil
        #expect(model.draft.authoringVersion == nil)
    }

    @Test func concurrentChangeFailsBeforeExecutionAndNeverReplays() async {
        let backend = ReconstructionBackend(), model = backend.model()
        await model.load(); model.draft = backend.physical; await model.preparePreview()
        backend.concurrentChange = true; await model.apply()
        #expect(model.outcome?.state == "failed" && model.outcome?.steps.allSatisfy { $0.state == "notStarted" } == true)
        #expect(model.outcomeReview?.draft.columnOrder == backend.physical.columnOrder && !model.canApply)
        await model.apply()
        #expect(backend.commands.filter { $0.type == "structure.apply" }.count == 1)
    }

    @Test func stopWaitsForTerminalBackfillEvidenceAndKeepsExactIntent() async throws {
        let backend = ReconstructionBackend(), model = backend.model()
        await model.load()
        model.draft = .init(columns: [.init(name: "required", type: .init(kind: "integer"), nullable: false, default: .init(kind: "none"))], allowDestructive: true, backfills: [.init(column: "required", expression: "7")])
        await model.preparePreview(); let intended = model.draft
        backend.holdApply = true; backend.state = "cancelled"
        let applying = Task { await model.apply() }
        defer { backend.applyGate?.resume(); backend.applyGate = nil; applying.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while backend.applyGate == nil && ContinuousClock.now < deadline { await Task.yield() }
        let gate = try #require(backend.applyGate)
        await model.stop()
        #expect(model.isBusy && model.outcome == nil && !model.canApply && backend.commands.contains { $0.type == "cancel" })
        backend.applyGate = nil; gate.resume(); await applying.value
        #expect(model.outcome?.state == "cancelled" && model.outcome?.steps.map(\.state) == ["rolledBack", "notStarted", "notStarted"])
        #expect(model.outcomeReview?.draft == intended && !model.canApply)
    }

    @Test(arguments: ["partiallyApplied", "cancelled", "lost"])
    func partialCancellationAndUnknownRetainExactIntentWithoutReplay(result: String) async throws {
        let backend = ReconstructionBackend(), model = backend.model()
        await model.load()
        model.draft = .init(columns: [.init(name: "required", type: .init(kind: "text"), nullable: false, default: .init(kind: "none"))],
            allowDestructive: true, backfills: [.init(column: "required", expression: "'NULL'")], reconstruct: true)
        backend.state = result == "lost" ? "applied" : result; backend.loseApply = result == "lost"
        await model.preparePreview(); let intended = model.draft; await model.apply()
        #expect(model.outcome?.state == (result == "lost" ? "outcomeUnknown" : result))
        #expect(model.outcomeReview?.draft == intended && model.portableDraft.draft.backfills == intended.backfills && !model.canApply && !model.canPreview)
        if result == "lost" { await model.checkExecutionStatus(); #expect(model.outcome?.state == "applied") }
        await model.apply()
        #expect(backend.commands.filter { $0.type == "structure.apply" }.count == 1 && backend.connections == 1)
        await model.load()
        #expect(model.historyReviews.last?.draft == intended && model.preview == nil && model.draft.backfills == nil)
    }
}

struct TableStructureReconstructionFormatTests {
    private let target = StructureTarget(schema: "public", table: "synthetic", create: false)
    private var draft: StructureDraft { .init(columns: [.init(name: "required", type: .init(kind: "text"), nullable: false, default: .init(kind: "none"))], allowDestructive: true, authoringVersion: 5,
        backfills: [.init(column: "required", expression: "'NULL' || 'é'")], columnOrder: ["required", "é", "é"], reconstruct: true) }
    @Test func versionFivePortableDraftPreservesExactIntentAndRejectsOldHeaders() throws {
        let document = StructureDraftDocument(engine: .postgresql, target: target, draft: draft)
        let text = try StructureDraftStore.text(document)
        let restored = try JSONDecoder().decode(StructureDraftDocument.self, from: Data(text.utf8))
        #expect(restored == document && restored.formatVersion == 5 && restored.draft.allowDestructive == nil)
        #expect(restored.draft.backfills?.first?.expression.utf8.elementsEqual("'NULL' || 'é'".utf8) == true)
        for version in 1...4 {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(StructureDraftDocument.self, from: Data(text.replacingOccurrences(of: "\"formatVersion\" : 5", with: "\"formatVersion\" : \(version)").utf8)) }
            let empty = "{\"formatVersion\":\(version),\"engine\":\"postgresql\",\"target\":{\"schema\":\"public\",\"table\":\"synthetic\",\"create\":false},\"draft\":{\"columns\":[]"
            for field in [",\"reconstruct\":false", ",\"columnOrder\":[]", ",\"backfills\":[]", ",\"reconstruct\":null", ",\"authoringVersion\":5"] {
                #expect(throws: (any Error).self) { try JSONDecoder().decode(StructureDraftDocument.self, from: Data((empty + field + "}}").utf8)) }
            }
            let legacy = empty + "}}"
            #expect(try JSONDecoder().decode(StructureDraftDocument.self, from: Data(legacy.utf8)).formatVersion == 5)
        }
    }
    @Test func versionFourEvidenceRetainsExactIntentWithoutRestoringExecutionAuthority() throws {
        let plan = StructurePlan(id: "historical", baselineId: "discard-baseline", digest: String(repeating: "b", count: 64), target: target,
            sql: ["synthetic copy SELECT 'NULL' || 'é'"], risks: ["Full table rewrite."], destructive: true)
        let outcome = StructureOutcome(executionId: "execution", planId: plan.id, state: "outcomeUnknown", steps: [.init(state: "unknown")])
        let artifact = SavedEvidenceArtifact(id: UUID(), kind: .structure, title: "Reconstruction", savedAt: Date(timeIntervalSince1970: 1), engine: .postgresql,
            environment: .unspecified, sourceWasStale: false, structure: try SavedStructureEvidence(.init(outcome: outcome, plan: plan, draft: draft)))
        let text = try artifact.encoded(), restored = try SavedEvidenceArtifact.decode(text)
        #expect(restored.version == 4 && restored.structure?.draft == draft && restored.structure?.sql == plan.sql && !restored.complete)
        #expect(!text.contains("discard-baseline") && !text.contains("authorization") && !text.contains("sessionId"))
        for version in 1...3 {
            #expect(throws: (any Error).self) { try SavedEvidenceArtifact.decode(text.replacingOccurrences(of: "\"version\" : 4", with: "\"version\" : \(version)")) }
        }
    }
    @Test func oldEvidenceHeadersRejectNewFieldPresenceEvenWithoutActualE4Intent() throws {
        let legacyDraft = StructureDraft(columns: [.init(name: "ordinary", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))])
        let plan = StructurePlan(id: "historical", baselineId: "discard", digest: String(repeating: "b", count: 64), target: target, sql: ["synthetic legacy step"], risks: [])
        let outcome = StructureOutcome(executionId: "execution", planId: plan.id, state: "applied", steps: [.init(state: "applied")])
        let artifact = SavedEvidenceArtifact(id: UUID(), kind: .structure, title: "Legacy", savedAt: Date(timeIntervalSince1970: 1), engine: .postgresql,
            environment: .unspecified, sourceWasStale: false, structure: try SavedStructureEvidence(.init(outcome: outcome, plan: plan, draft: legacyDraft)))
        let encoded = try artifact.encoded()
        let original = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        for version in 1...3 {
            var envelope = original; envelope["version"] = version
            let legacy = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
            #expect(try SavedEvidenceArtifact.decode(legacy).version == 4)
            let additions: [(String, Any)] = [("reconstruct", false), ("columnOrder", [String]()), ("backfills", [String]()), ("reconstruct", NSNull()), ("authoringVersion", 5)]
            for (key, value) in additions {
                var record = try #require(envelope["structure"] as? [String: Any])
                var intent = try #require(record["draft"] as? [String: Any]); intent[key] = value
                record["draft"] = intent; var changed = envelope; changed["structure"] = record
                let text = String(decoding: try JSONSerialization.data(withJSONObject: changed), as: UTF8.self)
                #expect(throws: (any Error).self) { try SavedEvidenceArtifact.decode(text) }
            }
        }
    }

    @Test func sharedFixtureClosesReconstructionCommandVariants() throws {
        struct Fixture: Decodable { let valid: [BackendCommand]; let invalid: [String] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/table-structure-reconstruction-v1.json")))
        for command in fixture.valid {
            #expect(command.structure?.valid(for: command.type) == true)
            #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command)) == command)
        }
        for raw in fixture.invalid {
            var accepted = false
            do { let command = try JSONDecoder().decode(BackendCommand.self, from: Data(raw.utf8)); accepted = command.structure?.valid(for: command.type) == true } catch {}
            #expect(!accepted)
        }
    }
}

@MainActor
struct TableStructureReconstructionTransportTests {
    private func client(hello: Bool, session: Bool, disconnected: Bool = false, churnLimit: Int = 0) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys
        def send(v): print(json.dumps(v),flush=True)
        cap='tableStructureReconstructionV1'
        base=['tableStructureDestructiveV1']
        hc=base+([cap] if \(hello ? "True" : "False") else [])
        sc=base+([cap] if \(session ? "True" : "False") else [])
        previews=0;connects=0;limit=\(churnLimit)
        for line in sys.stdin:
            c=json.loads(line);k=c['type'];r=dict(requestId=c['requestId'])
            if k=='hello':send(dict(r,type='hello.ack',protocolVersion=6,capabilities=hc));continue
            if k=='connect':
                connects+=1;sid='session' if connects==1 or limit==0 else 'session-'+str(connects)
                send(dict(r,type='connect.result',sessionId=sid,engine='postgresql',transactionStatus='idle',connected=True,capabilities=sc));continue
            if k=='disconnect':send(dict(r,type='disconnect.ack',sessionId=c['sessionId']));continue
            if k=='shutdown':send(dict(r,type='shutdown.ack'));break
            r.update(sessionId=c['sessionId'],queryId=c.get('queryId'))
            if k=='operation.assess':
                send(dict(r,type='operation.assessment',assessment=dict(decision='allow',policy=dict(environment='unspecified',readOnly=False),operations=[dict(kind='read',statements=[])],authorization='grant')));continue
            send(dict(r,type='query.started'))
            if k=='structure.preview':
                previews+=1
                payload=dict(plan=dict(id='plan-'+str(previews) if limit else 'plan',baselineId='baseline',digest='b'*64,target=dict(schema='public',table='synthetic',create=False),sql=['synthetic physical rewrite'],risks=[]))
            elif k=='structure.validate':
                a=c['structure']['validation'];payload=dict(validation=dict(executionId=a['executionId'],planId=a['planId'],digest=a['digest'],state='completed',checks=[]))
            elif k=='structure.apply':
                a=c['structure']['apply'];payload=dict(outcome=dict(executionId=a['executionId'],planId=a['planId'],state='applied',steps=[dict(state='applied')]))
            else:payload=dict(outcome=dict(executionId='execution',planId='plan',state='applied',steps=[dict(state='applied')]))
            send(dict(r,type=k+'.result',transactionStatus='idle',connected=\(disconnected ? "False" : "True") and not(limit and previews>=limit),structure=payload))
        """])
    }
    private func connect(_ client: BackendClient) async throws {
        try await client.start()
        _ = try await client.request(.connect(.init(host: "synthetic.invalid", port: 5432, database: "synthetic", user: "fixture", password: "", sslMode: "disable")))
    }
    private func command(_ type: String, _ request: StructureRequest, authorization: String? = nil, sessionID: String = "session") -> BackendCommand {
        .init(type: "structure." + type, requestId: UUID().uuidString, sessionId: sessionID, queryId: UUID().uuidString, authorization: authorization, structure: request)
    }
    @Test(arguments: [false, true], [false, true])
    func explicitVersionFiveIncludingLegacyOnlyRequiresHelloAndOwnerCapability(hello: Bool, session: Bool) async throws {
        let client = client(hello: hello, session: session); try await connect(client)
        let drafts = [StructureDraft(columns: [], allowDestructive: true, authoringVersion: 5, reconstruct: true),
            StructureDraft(columns: [.init(name: "legacy", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))], authoringVersion: 5)]
        for draft in drafts {
            let preview = command("preview", .init(baselineId: "baseline", draft: draft))
            if hello && session { #expect(try await client.request(preview).structure?.plan?.id == "plan") }
            else { await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(preview) } }
        }
        #expect(!(await client.hasExited()))
        _ = await client.shutdown(); _ = await client.waitForExit()
    }
    @Test func previewAndOwnerChurnCannotForgetOldPlanAdmissionOrReviveRetiredStatus() async throws {
        let client = client(hello: true, session: true, churnLimit: 129)
        try await connect(client)
        let advanced = StructureDraft(columns: [], allowDestructive: true, authoringVersion: 5, reconstruct: true)
        let legacy = StructureDraft(columns: [.init(name: "ordinary", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))])
        for index in 1...129 {
            let reply = try await client.request(command("preview", .init(baselineId: "baseline", draft: index == 1 ? advanced : legacy)))
            #expect(reply.structure?.plan?.id == "plan-\(index)")
        }
        #expect(try await client.request(command("status", .init())).structure?.outcome?.state == "applied")
        // The first E4 plan stays gated after many later legacy previews; an unknown
        // plan ID cannot bypass the same physical owner's retired active admission.
        for planID in ["plan-1", "plan-129", "unknown-plan"] {
            let invocation = StructureApply(planId: planID, digest: String(repeating: "b", count: 64), executionId: "execution")
            await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(command("apply", .init(apply: invocation), authorization: "grant")) }
            await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(command("validate", .init(validation: invocation), authorization: "grant")) }
            await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(.assess(sessionId: "session", operations: [.init(type: "structure.apply", structure: invocation)])) }
        }
        _ = try await client.request(.disconnect(sessionId: "session"))
        await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(command("status", .init())) }
        let retired = StructureApply(planId: "plan-1", digest: String(repeating: "b", count: 64), executionId: "execution")
        await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(command("apply", .init(apply: retired), authorization: "grant")) }
        await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(.assess(sessionId: "session", operations: [.init(type: "structure.apply", structure: retired)])) }
        for _ in 1...32 {
            let reply = try await client.request(.connect(.init(host: "synthetic.invalid", port: 5432, database: "synthetic", user: "fixture", password: "", sslMode: "disable")))
            let owner = try #require(reply.sessionId)
            #expect(try await client.request(command("status", .init(), sessionID: owner)).structure?.outcome?.state == "applied")
            _ = try await client.request(.disconnect(sessionId: owner))
            await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(command("status", .init(), sessionID: owner)) }
        }
        #expect(!(await client.hasExited()))
        _ = await client.shutdown(); _ = await client.waitForExit()
    }

    @Test func physicalLossRetainsOnlyStatusAdmissionAndNeverAdmitsNewValidationOrApply() async throws {
        let client = client(hello: true, session: true, disconnected: true); try await connect(client)
        _ = try await client.request(command("preview", .init(baselineId: "baseline", draft: .init(columns: [], allowDestructive: true, authoringVersion: 5, reconstruct: true))))
        #expect(try await client.request(command("status", .init())).structure?.outcome?.state == "applied")
        let invocation = StructureApply(planId: "plan", digest: String(repeating: "b", count: 64), executionId: "execution")
        for request in [command("preview", .init(baselineId: "baseline", draft: .init(columns: [], allowDestructive: true, authoringVersion: 5, reconstruct: true))), command("validate", .init(validation: invocation), authorization: "grant"), command("apply", .init(apply: invocation), authorization: "grant")] {
            await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(request) }
        }
        await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(.assess(sessionId: "session", operations: [.init(type: "structure.validate", structure: invocation)])) }
        await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(.assess(sessionId: "session", operations: [.init(type: "structure.apply", structure: invocation)])) }
        _ = try await client.request(.disconnect(sessionId: "session"))
        await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(command("status", .init())) }
        _ = await client.shutdown(); _ = await client.waitForExit()
    }
}
