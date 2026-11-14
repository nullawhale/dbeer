import Foundation
import Testing
@testable import DBeer

private func physicalModelProfile() -> SavedConnection {
    .init(name: "Synthetic physical operation", settings: .init(host: "synthetic.invalid", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable"))
}
private let physicalModelTarget = StructureTarget(schema: "app", table: "parent", create: false)
private func physicalModelObject() -> StructurePhysicalObject {
    .init(columns: [.init(name: "id", nativeType: "pg_catalog.int4", nullable: false)], target: physicalModelTarget,
        identity: "42", kind: "r", fingerprint: String(repeating: "b", count: 64), partitions: [],
        indexes: [.init(name: "interrupted_index", valid: false, ready: true, live: true)], limitations: [])
}
private func physicalModelIntent() -> StructurePhysicalIntent {
    .init(kind: "concurrentIndex", index: .init(action: "add", name: "exact_index", columns: ["id"]))
}
private func physicalModelPlan(_ draft: StructurePhysicalDraft) -> StructurePhysicalPlan {
    .init(id: "physical-plan", digest: String(repeating: "a", count: 64), draft: draft, engine: "postgresql", serverVersion: 170000,
        sql: ["synthetic exact SQL first", "synthetic exact SQL second"], objects: [physicalModelObject()],
        prerequisites: ["Original idle session required"], risks: ["Interrupted index may remain INVALID"], consequences: [],
        transactionMode: "outsideTransaction", locking: "Synthetic disclosed locking", destructive: true)
}

@MainActor
private final class PhysicalModelBackend {
    var current = true
    var allowed = true
    var grant = true
    var connects = 0
    var commands: [BackendCommand] = []
    var authorizations: [(StructureApply, StructurePhysicalPlan, String)] = []
    var changes: [PhysicalStructureReport] = []
    var plan: StructurePhysicalPlan?
    var invocation: StructureApply?
    var status: StructurePhysicalOutcome?
    var loseApply = false
    var holdApply = false
    var heldApply: CheckedContinuation<Void, Never>?
    var holdApproval = false
    var heldApproval: CheckedContinuation<Void, Never>?
    var holdStatus = false
    var heldStatus: CheckedContinuation<Void, Never>?
    var holdInspect = false
    var heldInspect: CheckedContinuation<Void, Never>?
    var statusWrongOwner = false
    var finalState = "applied"
    func model() -> PhysicalStructureModel {
        .init(profile: physicalModelProfile(), target: physicalModelTarget, connect: { self.connects += 1; return "physical-owner" }, send: send,
            authorize: { invocation, plan, owner in
                self.authorizations.append((invocation, plan, owner))
                if self.holdApproval { await withCheckedContinuation { self.heldApproval = $0 } }
                return self.grant ? "one-use-exact-grant" : nil
            }, bindingIsCurrent: { self.current }, operationsAllowed: { self.allowed }, helperIsClosed: { false }, changed: { self.changes.append($0) })
    }
    func send(_ command: BackendCommand) async throws -> BackendMessage {
        commands.append(command)
        if command.type == "disconnect" { return .init(type: "disconnect.ack", requestId: command.requestId, sessionId: command.sessionId) }
        if command.type == "cancel" { return .init(type: "cancel.ack", requestId: command.requestId, sessionId: command.sessionId, queryId: command.queryId, status: "accepted") }
        var message = BackendMessage(type: command.type + ".result", requestId: command.requestId, sessionId: command.sessionId,
            queryId: command.queryId, transactionStatus: .idle, connected: true)
        let value: StructurePhysicalReply
        switch command.type {
        case "structure.physical.inspect":
            if holdInspect { await withCheckedContinuation { heldInspect = $0 } }
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(physicalModelObject()))
            let inspection = try JSONSerialization.data(withJSONObject: ["version": 1, "engine": "postgresql", "serverVersion": 170000, "objects": [object], "operations": ["concurrentIndex"]])
            value = .init(inspection: try JSONDecoder().decode(StructurePhysicalInspection.self, from: inspection))
        case "structure.physical.preview":
            let captured = physicalModelPlan(command.structure!.physical!.draft!); plan = captured
            value = .init(draft: captured.draft, plan: captured)
        case "structure.physical.apply":
            let apply = command.structure!.physical!.apply!; invocation = apply
            if holdApply { await withCheckedContinuation { heldApply = $0 } }
            if loseApply { throw BackendTransportError(.unexpectedEOF, outcomeUnknown: true) }
            let steps: [StructureStepOutcome] = finalState == "applied" ? [.init(state: "applied"), .init(state: "applied")] : [.init(state: "failed"), .init(state: "notStarted")]
            let outcome = StructurePhysicalOutcome(executionId: apply.executionId, planId: apply.planId, state: finalState, phase: "finished", steps: steps, observed: [physicalModelObject()], reconciled: true)
            status = outcome; value = .init(draft: plan!.draft, outcome: outcome)
        case "structure.physical.status":
            let captured = status
            if holdStatus { await withCheckedContinuation { heldStatus = $0 } }
            var result = captured
            if statusWrongOwner { result?.executionId = "other-execution" }
            value = .init(draft: plan?.draft, outcome: result, elapsedMilliseconds: 123)
        case "structure.physical.reconcile":
            var result = status; result?.observed = [physicalModelObject()]; result?.reconciled = true
            status = result; value = .init(draft: plan?.draft, outcome: result)
        default: throw BackendRequestError.invalidCommand
        }
        message.structure = .init(physical: value)
        return message
    }
}

/// Injected model, private files and value-only fixtures. No AppKit, view/window,
/// application activation, default decisions, credentials or database access.
@MainActor
struct PhysicalStructureModelTests {
    @Test func inspectPreviewMandatoryReviewAndOneAttemptRetainExactEvidence() async throws {
        let backend = PhysicalModelBackend(), model = backend.model()
        #expect(model.preview == nil && backend.connects == 0)
        await model.inspect()
        #expect(model.inspection?.operations == ["concurrentIndex"] && model.columnNames == ["id"])
        #expect(model.objects.first?.indexes.first?.valid == false && backend.authorizations.isEmpty)
        model.intent = physicalModelIntent(); await model.preparePreview()
        let plan = try #require(model.preview)
        #expect(plan.valid && backend.connects == 1 && model.canApply)
        backend.grant = false; await model.apply()
        #expect(model.preview == plan && model.report == nil && !backend.commands.contains { $0.type == "structure.physical.apply" })
        backend.grant = true; await model.apply()
        let report = try #require(model.report)
        #expect(report.valid && report.serverEvidence && report.plan == plan && report.outcome.state == "applied")
        #expect(!model.canPreview && !model.canApply && backend.authorizations.last?.2 == "physical-owner")
        let confirmation = PhysicalReviewText.confirmation(plan)
        #expect(confirmation.contains(plan.digest) && confirmation.contains(plan.objects[0].fingerprint) && plan.sql.allSatisfy(confirmation.contains))
        await model.apply(); await model.preparePreview()
        #expect(backend.commands.filter { $0.type == "structure.physical.apply" }.count == 1)
        await model.checkStatus(); await model.reconcile()
        #expect(model.report?.id == report.id && model.report?.outcome.reconciled == true && model.preview == nil && backend.connects == 1)
        #expect(await model.close())
    }
    @Test(arguments: [false, true])
    func changedIntentOrOriginDuringReviewCannotConsumeGrant(_ changeBinding: Bool) async throws {
        let backend = PhysicalModelBackend(), model = backend.model()
        model.intent = physicalModelIntent(); await model.preparePreview(); backend.holdApproval = true
        let apply = Task { await model.apply() }
        while backend.heldApproval == nil { await Task.yield() }
        if changeBinding { backend.current = false } else { model.intent.index?.name = "changed_after_review" }
        backend.heldApproval?.resume(); await apply.value
        #expect(model.report == nil && !backend.commands.contains { $0.type == "structure.physical.apply" })
        #expect(await model.close())
    }
    @Test func observedAcknowledgementSurvivesLostCompletionWithoutReconnectOrCleanup() async throws {
        let backend = PhysicalModelBackend(), model = backend.model()
        model.intent = physicalModelIntent(); await model.preparePreview(); backend.holdApply = true; backend.loseApply = true
        let apply = Task { await model.apply() }
        while backend.heldApply == nil { await Task.yield() }
        let invocation = try #require(backend.invocation)
        backend.status = .init(executionId: invocation.executionId, planId: invocation.planId, state: "applying", phase: "acknowledged", steps: [.init(state: "applied"), .init(state: "notStarted")], reconciled: false)
        await model.checkStatus()
        #expect(model.isApplying && model.report?.outcome.steps.map(\.state) == ["applied", "notStarted"] && model.elapsedMilliseconds == 123)
        backend.heldApply?.resume(); await apply.value
        let lost = try #require(model.report)
        #expect(lost.valid && !lost.serverEvidence && lost.outcome.state == "outcomeUnknown" && lost.outcome.steps.map(\.state) == ["applied", "unknown"])
        #expect(!model.canReconcile && !model.canApply && !model.canPreview && backend.connects == 1)
        backend.statusWrongOwner = true; await model.checkStatus()
        #expect(model.report == lost && model.error != nil)
        await model.inspect(); await model.reconcile(); await model.preparePreview(); await model.apply()
        #expect(backend.connects == 1 && backend.commands.filter { $0.type == "structure.physical.apply" }.count == 1)
        #expect(!backend.commands.contains { $0.type == "structure.physical.reconcile" || $0.type == "execute" })
        #expect(await model.close())
    }
    @Test func lateApplyingStatusCannotReplaceACompleteTerminalAcknowledgement() async throws {
        let backend = PhysicalModelBackend(), model = backend.model()
        model.intent = physicalModelIntent(); await model.preparePreview(); backend.holdApply = true; backend.holdStatus = true
        let apply = Task { await model.apply() }
        while backend.heldApply == nil { await Task.yield() }
        let invocation = try #require(backend.invocation)
        backend.status = .init(executionId: invocation.executionId, planId: invocation.planId, state: "applying", phase: "metadataRecheck", steps: [.init(state: "notStarted"), .init(state: "notStarted")], reconciled: false)
        let status = Task { await model.checkStatus() }
        while backend.heldStatus == nil { await Task.yield() }
        backend.heldApply?.resume(); await apply.value
        let finished = try #require(model.report)
        backend.heldStatus?.resume(); await status.value
        #expect(model.report == finished && model.report?.outcome.state == "applied")
        #expect(await model.close())
    }
    @Test func stopDuringMetadataReadCannotRepublishInspectorOrReusePreview() async throws {
        let backend = PhysicalModelBackend(), model = backend.model()
        model.intent = physicalModelIntent(); await model.preparePreview(); backend.holdInspect = true
        let inspect = Task { await model.inspect() }
        while backend.heldInspect == nil { await Task.yield() }
        await model.stop(); backend.heldInspect?.resume(); await inspect.value
        #expect(model.inspection == nil && model.preview == nil && model.report == nil)
        #expect(backend.commands.contains { $0.type == "cancel" } && backend.connects == 1)
        #expect(await model.close())
    }
    @Test func portableIntentAndHistoricalReportStayDisconnectedAndGuardExternalWrites() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("physical-documents-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = PhysicalModelBackend(), model = backend.model()
        let draft = StructurePhysicalDraft(version: 1, target: physicalModelTarget, intent: physicalModelIntent())
        let portable = PhysicalStructureIntentDocument(engine: .postgresql, draft: draft)
        let text = try portable.encoded(), file = folder.appendingPathComponent("intent.dbeerphysical")
        _ = try SQLFileBinding.write(text, to: file, expectedVersion: nil)
        await model.openIntent(from: file, expected: model.portableIntent)
        #expect(model.draft == draft && model.preview == nil && backend.connects == 0 && backend.commands.isEmpty)
        for key in ["password", "profileID", "sessionId", "authorization", "fingerprint", "digest", "planId"] { #expect(!text.contains(key)) }
        var injection = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        injection["authorization"] = "untrusted"
        let injectedText = String(decoding: try JSONSerialization.data(withJSONObject: injection), as: UTF8.self)
        #expect(throws: (any Error).self) { try PhysicalStructureIntentDocument.decode(injectedText) }
        let version = try SQLFileBinding.read(file).version
        _ = try SQLFileBinding.write("external", to: file, expectedVersion: version)
        await model.saveIntent(to: file, expected: model.portableIntent, version: version)
        #expect(try SQLFileBinding.read(file).text == "external" && model.error != nil)
        let plan = physicalModelPlan(draft)
        let outcome = StructurePhysicalOutcome(executionId: "historical", planId: plan.id, state: "outcomeUnknown", phase: "finished", steps: [.init(state: "unknown"), .init(state: "unknown")], reconciled: false)
        let report = PhysicalStructureReport(plan: plan, outcome: outcome, serverEvidence: false)
        let reportFile = folder.appendingPathComponent("report.dbeerphysicalreport")
        _ = try SQLFileBinding.write(report.encoded(), to: reportFile, expectedVersion: nil)
        await model.openReport(from: reportFile)
        #expect(model.openedReport == report && model.report == nil && model.preview == nil && !model.canCheckStatus && !model.canApply && backend.commands.isEmpty)
        #expect(try PhysicalStructureReport.decode(report.encoded()) == report)
    }
    @Test func unknownAcknowledgementCannotBecomeAppliedThroughCatalogReconciliation() {
        let plan = physicalModelPlan(.init(version: 1, target: physicalModelTarget, intent: physicalModelIntent()))
        let unknown = StructurePhysicalOutcome(executionId: "execution", planId: plan.id, state: "outcomeUnknown", phase: "finished", steps: [.init(state: "unknown"), .init(state: "notStarted")], reconciled: false)
        var invented = unknown; invented.state = "partiallyApplied"; invented.steps[0].state = "applied"; invented.reconciled = true
        #expect(!PhysicalTransportAdmission.preserves(invented, previous: unknown))
        var observed = unknown; observed.reconciled = true; observed.observed = [physicalModelObject()]
        #expect(PhysicalTransportAdmission.preserves(observed, previous: unknown))
    }
}
