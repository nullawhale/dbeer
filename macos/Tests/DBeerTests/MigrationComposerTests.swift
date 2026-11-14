import Foundation
import Testing
@testable import DBeer

private func migrationFixtureDraft() -> StructureMigrationDraft {
    .init(version: 1, objects: [.init(id: "first", target: .init(schema: "public", table: "first", create: false),
        draft: .init(columns: [.init(name: "added", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))]), after: []),
        .init(id: "second", target: .init(schema: "public", table: "second", create: false),
        draft: .init(columns: [.init(name: "later", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))]), after: ["first"])], repairs: [])
}
private func migrationFixturePlan(_ draft: StructureMigrationDraft) -> StructureMigrationPlan {
    let fingerprint = String(repeating: "a", count: 64)
    let identity = String(repeating: "b", count: 64)
    var prior: [String] = []
    let steps = draft.objects.map { object in
        let id = "step-" + object.id
        let before = draft.objects.map { StructureMigrationExpectation(target: $0.target, initialFingerprint: fingerprint, identityDigest: identity, afterSteps: prior) }
        prior.append(id)
        let after = draft.objects.map { StructureMigrationExpectation(target: $0.target, initialFingerprint: fingerprint, identityDigest: identity, afterSteps: prior) }
        return StructureMigrationStep(id: id, objectId: object.id, phase: "object", target: object.target, draft: object.draft,
            sql: ["synthetic reviewed SQL " + object.id], digest: fingerprint, before: before, after: after, risks: ["Synthetic lock warning"], atomic: false)
    }
    return .init(id: "plan", digest: fingerprint, engine: "postgresql", draft: draft,
        baselines: draft.objects.map { .init(id: "baseline-" + $0.id, target: $0.target, engine: "postgresql", fingerprint: fingerprint, columns: [], limitations: []) },
        steps: steps, risks: ["Synthetic migration is non-atomic"], destructive: false)
}

@MainActor
private final class MigrationModelBackend {
    var current = true
    var permit = true
    var connects = 0
    var commands: [BackendCommand] = []
    var authorizations: [(StructureApply, StructureMigrationPlan, String)] = []
    var changes: [MigrationExecutionDocument] = []
    var outcome: StructureMigrationOutcome?
    var plan: StructureMigrationPlan?
    var loseApply = false
    var physicalUnavailable = false
    var heldAuthorization: CheckedContinuation<Void, Never>?
    var holdAuthorization = false
    var malformedStatus = false
    var holdMetadata = false
    var heldMetadata: CheckedContinuation<Void, Never>?
    var lastInvocation: StructureApply?
    func model() -> MigrationComposerModel {
        .init(profile: .init(name: "Synthetic migration", settings: .init(host: "synthetic.invalid", port: 5432, database: "synthetic", user: "synthetic", password: "", sslMode: "disable")),
            initialTarget: .init(schema: "public", table: "", create: false), connect: { self.connects += 1; return "owner" }, send: request,
            authorize: { apply, plan, owner in
                self.authorizations.append((apply, plan, owner))
                if self.holdAuthorization { await withCheckedContinuation { self.heldAuthorization = $0 } }
                return self.permit ? "one-use-exact-plan-grant" : nil
            }, bindingIsCurrent: { self.current }, helperIsClosed: { false }, changed: { self.changes.append($0) })
    }
    func request(_ command: BackendCommand) async throws -> BackendMessage {
        commands.append(command)
        var response = BackendMessage(type: command.type + ".result", requestId: command.requestId, sessionId: command.sessionId,
            queryId: command.queryId, transactionStatus: .idle, connected: true)
        let draft = plan?.draft ?? migrationFixtureDraft()
        let payload: StructureMigrationReply
        switch command.type {
        case "structure.load":
            // The normal helper retires migration authority on ordinary loads.
            plan = nil
            if holdMetadata { await withCheckedContinuation { heldMetadata = $0 } }
            response.structure = .init(baseline: .init(id: "metadata", target: command.structure!.target!, engine: "postgresql",
                fingerprint: String(repeating: "a", count: 64), columns: [], limitations: []))
            return response
        case "structure.migration.preview":
            let captured = migrationFixturePlan(command.structure!.migration!.draft!); plan = captured
            payload = .init(plan: captured, draft: captured.draft)
        case "structure.migration.apply":
            let apply = command.structure!.migration!.apply!; lastInvocation = apply
            if loseApply { physicalUnavailable = true; throw BackendTransportError(.unexpectedEOF, outcomeUnknown: true) }
            let retained = StructureMigrationOutcome(planId: apply.planId, executionId: apply.executionId, state: "partiallyApplied", steps: [
                .init(id: "step-first", state: "applied", statements: [.init(state: "applied")]),
                .init(id: "step-second", state: "failed", statements: [.init(state: "failed", message: "Synthetic failure")])], reconciliationRequired: true)
            outcome = retained; payload = .init(draft: draft, outcome: retained)
        case "structure.migration.status":
            if malformedStatus { payload = .init(draft: draft, outcome: .init(planId: "wrong-plan", executionId: "wrong-execution", state: "failed", steps: [.init(id: "wrong-step", state: "failed", statements: [.init(state: "failed")])], reconciliationRequired: true)) }
            else { payload = .init(draft: draft, outcome: outcome) }
            if physicalUnavailable { response.connected = false; response.transactionStatus = nil }
        case "structure.migration.reconcile":
            var observedOutcome = outcome; observedOutcome?.reconciliationRequired = false; outcome = observedOutcome
            payload = .init(draft: draft, outcome: observedOutcome, observed: plan?.baselines)
        case "disconnect": return .init(type: "disconnect.ack", requestId: command.requestId, sessionId: command.sessionId)
        default: payload = .init()
        }
        response.structure = .init(migration: payload)
        return response
    }
}

/// Pure injected model, private file and transport-envelope checks. No AppKit,
/// views, windows, application activation, default decisions or database access.
@MainActor
struct MigrationComposerTests {
    @Test func exactReviewAndPartialEvidenceRequireExplicitReconcileAndRetainedIntentReview() async throws {
        let backend = MigrationModelBackend(), model = backend.model()
        model.draft = migrationFixtureDraft()
        await model.preparePreview()
        let reviewed = try #require(model.preview)
        #expect(reviewed.valid && backend.connects == 1 && model.canApply)
        backend.permit = false; await model.apply()
        #expect(model.preview == reviewed && model.report == nil && !backend.commands.contains { $0.type == "structure.migration.apply" })
        backend.permit = true; await model.apply()
        let report = try #require(model.report)
        #expect(report.valid && report.outcome.state == "partiallyApplied" && report.plan == reviewed)
        #expect(report.outcome.steps.map(\.state) == ["applied", "failed"] && model.draft == reviewed.draft)
        #expect(!model.canApply && !model.canPreview && model.reconciliationRequired && backend.authorizations.last?.2 == "owner")
        await model.preparePreview(); await model.apply()
        #expect(backend.commands.filter { $0.type == "structure.migration.apply" }.count == 1)
        await model.checkStatus()
        #expect(model.report?.id == report.id && backend.connects == 1)
        await model.reconcile()
        #expect(!model.reconciliationRequired && model.retainedIntentNeedsReview && !model.canPreview && model.report?.plan == reviewed)
        model.reviewRetainedIntent()
        #expect(model.history.last?.id == report.id && model.report == nil && model.preview == nil && model.canPreview)
        model.removeObject("first")
        #expect(model.draft.objects.map(\.id) == ["second"] && model.draft.objects[0].after.isEmpty)
        #expect(await model.close())
    }
    @Test func objectMetadataLoadThenCancelRequiresFreshPreviewWithoutChangingIntent() async throws {
        let backend = MigrationModelBackend(), model = backend.model()
        let frozen = migrationFixtureDraft()
        model.draft = frozen; await model.preparePreview()
        try #require(model.canApply && model.preview != nil)
        await model.editObject(frozen.objects[0], target: frozen.objects[0].target)
        try #require(model.objectEditor != nil)
        #expect(backend.plan == nil && model.preview == nil && !model.canApply)
        model.cancelObjectEditor()
        #expect(model.objectEditor == nil && model.draft == frozen && model.report == nil && model.history.isEmpty)
        await model.apply()
        #expect(backend.authorizations.isEmpty && !backend.commands.contains { $0.type == "structure.migration.apply" })
        await model.preparePreview()
        #expect(model.canApply && backend.commands.filter { $0.type == "structure.migration.preview" }.count == 2 && backend.connects == 1)
        #expect(await model.close())
    }
    @Test func repairOwnerMetadataLoadWithoutSelectingRepairRequiresFreshPreview() async throws {
        let backend = MigrationModelBackend(), model = backend.model()
        let frozen = migrationFixtureDraft()
        model.draft = frozen; await model.preparePreview()
        try #require(model.canApply && model.preview != nil)
        await model.loadRepairTarget(frozen.objects[0].target)
        #expect(model.repairBaseline?.target == frozen.objects[0].target && backend.plan == nil)
        #expect(model.preview == nil && !model.canApply && model.draft == frozen && model.draft.repairs.isEmpty)
        await model.apply()
        #expect(backend.authorizations.isEmpty && !backend.commands.contains { $0.type == "structure.migration.apply" })
        await model.preparePreview()
        #expect(model.canApply && backend.commands.filter { $0.type == "structure.migration.preview" }.count == 2 && backend.connects == 1)
        #expect(await model.close())
    }
    @Test(arguments: [false, true])
    func stoppedOrReboundMetadataLoadCannotRepublishEditorOrPreview(_ bindingChanges: Bool) async throws {
        let backend = MigrationModelBackend(), model = backend.model()
        let frozen = migrationFixtureDraft()
        model.draft = frozen; await model.preparePreview(); backend.holdMetadata = true
        let edit = Task { await model.editObject(frozen.objects[0], target: frozen.objects[0].target) }
        while backend.heldMetadata == nil { await Task.yield() }
        #expect(model.preview == nil && !model.canApply)
        if bindingChanges { backend.current = false } else { await model.stop() }
        backend.heldMetadata?.resume(); await edit.value
        #expect(model.objectEditor == nil && model.preview == nil && !model.canApply && model.draft == frozen)
        #expect(model.report == nil && model.history.isEmpty && backend.connects == 1)
        #expect(await model.close())
    }
    @Test func unknownCompletionNeverReconnectsAndBadStatusCannotEraseReport() async throws {
        let backend = MigrationModelBackend(), model = backend.model()
        model.draft = migrationFixtureDraft(); await model.preparePreview()
        backend.loseApply = true; await model.apply()
        let lost = try #require(model.report)
        #expect(lost.valid && lost.outcome.state == "outcomeUnknown" && lost.outcome.steps.allSatisfy { $0.statements.allSatisfy { $0.state == "unknown" } })
        #expect(backend.connects == 1 && !model.canApply && !model.canPreview && !model.canReconcile)
        backend.malformedStatus = true; await model.checkStatus()
        #expect(model.report == lost && backend.connects == 1 && model.error != nil)
        await model.reconcile(); await model.preparePreview()
        #expect(!backend.commands.contains { $0.type == "structure.migration.reconcile" } && backend.connects == 1)
        #expect(await model.close())
    }
    @Test func editingOrBindingChangesDuringApprovalRejectTheGrant() async throws {
        let backend = MigrationModelBackend(), model = backend.model()
        model.draft = migrationFixtureDraft(); await model.preparePreview(); backend.holdAuthorization = true
        let task = Task { await model.apply() }
        while backend.heldAuthorization == nil { await Task.yield() }
        model.draft.objects[0].draft.columns[0].name = "changed"
        backend.heldAuthorization?.resume(); await task.value
        #expect(model.report == nil && !backend.commands.contains { $0.type == "structure.migration.apply" })
        backend.current = false; await model.preparePreview()
        #expect(model.preview == nil && backend.connects == 1)
        #expect(await model.close())
    }
    @Test func portableIntentIsBoundedSecretFreeDisconnectedAndRequiresRenewedConsent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("migration-documents-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var draft = migrationFixtureDraft()
        draft.objects[0].draft = .init(columns: [], changes: [.init(name: "gone", drop: true)], allowDestructive: true, authoringVersion: 4)
        let portable = MigrationDraftDocument(draft: draft), text = try portable.encoded()
        let value = try MigrationDraftDocument.decode(text)
        #expect(value == portable && value.draft.objects[0].draft.allowDestructive == nil && !value.draft.valid)
        for forbidden in ["password", "sessionId", "profileID", "authorization", "baselines", "allowDestructive"] { #expect(!text.contains(forbidden)) }
        let backend = MigrationModelBackend(), model = backend.model(), file = folder.appendingPathComponent("intent.dbeermigration")
        _ = try SQLFileBinding.write(text, to: file, expectedVersion: nil)
        await model.openDraft(from: file, expected: model.portableDraft)
        #expect(model.draft == value.draft && model.preview == nil && backend.connects == 0 && backend.commands.isEmpty && !model.canPreview)
        model.draft.objects[0].draft.allowDestructive = true
        #expect(model.canPreview)
        let expected = model.portableDraft, changed = folder.appendingPathComponent("changed.dbeermigration")
        _ = try SQLFileBinding.write("old", to: changed, expectedVersion: nil)
        let version = try SQLFileBinding.read(changed).version
        _ = try SQLFileBinding.write("external", to: changed, expectedVersion: version)
        await model.saveDraft(to: changed, expected: expected, version: version)
        #expect(try SQLFileBinding.read(changed).text == "external" && model.error != nil)
        var injectedDocument = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        injectedDocument["authorization"] = "untrusted"
        let injected = String(decoding: try JSONSerialization.data(withJSONObject: injectedDocument), as: UTF8.self)
        #expect(injectedDocument["authorization"] as? String == "untrusted" && injected != text)
        #expect(throws: (any Error).self) { try MigrationDraftDocument.decode(injected) }
        var nestedDocument = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        var nestedDraft = try #require(nestedDocument["draft"] as? [String: Any])
        var objects = try #require(nestedDraft["objects"] as? [[String: Any]])
        var objectDraft = try #require(objects[0]["draft"] as? [String: Any])
        objectDraft["allowDestructive"] = true
        objects[0]["draft"] = objectDraft; nestedDraft["objects"] = objects; nestedDocument["draft"] = nestedDraft
        let consent = String(decoding: try JSONSerialization.data(withJSONObject: nestedDocument), as: UTF8.self)
        #expect(objectDraft["allowDestructive"] as? Bool == true && consent != text)
        #expect(throws: (any Error).self) { try MigrationDraftDocument.decode(consent) }
        #expect(throws: (any Error).self) { try MigrationDraftDocument.decode(String(repeating: " ", count: MigrationDraftDocument.maximumBytes + 1)) }
    }
    @Test func savedReportAndExactSQLAreIndependentOfEditableIntent() throws {
        let plan = migrationFixturePlan(migrationFixtureDraft())
        let outcome = StructureMigrationOutcome(planId: plan.id, executionId: "execution", state: "outcomeUnknown", steps: plan.steps.map {
            .init(id: $0.id, state: "outcomeUnknown", statements: $0.sql.map { _ in .init(state: "unknown") })
        }, reconciliationRequired: true)
        let report = MigrationExecutionDocument(plan: plan, outcome: outcome)
        #expect(try MigrationExecutionDocument.decode(report.encoded()) == report)
        let exported = MigrationReviewText.sql(plan)
        #expect(exported.hasPrefix("-- DBeer reviewed migration: MANUAL execution.") && exported.contains(plan.digest))
        #expect(plan.steps.flatMap(\.sql).allSatisfy(exported.contains))
        #expect(MigrationReviewText.confirmation(plan).contains(plan.steps[1].before[0].afterSteps[0]))
        var wrong = outcome; wrong.steps.reverse()
        #expect(!MigrationTransportAdmission.matches(wrong, plan: plan))
        var downgraded = outcome; downgraded.steps[0].state = "applied"; downgraded.steps[0].statements = [.init(state: "applied")]
        #expect(!MigrationTransportAdmission.preserves(outcome, previous: downgraded))
    }
    @Test func envelopesRejectMixedFamiliesAndRegisterEveryTerminal() throws {
        let migration = StructureMigrationRequest(draft: migrationFixtureDraft())
        #expect(StructureRequest(migration: migration).valid(for: "structure.migration.preview"))
        #expect(!StructureRequest(target: .init(schema: "public", table: "t", create: false), migration: migration).valid(for: "structure.migration.preview"))
        #expect(!StructureRequest(migration: .init()).valid(for: "structure.status"))
        for operation in ["preview", "apply", "status", "reconcile", "export", "close"] {
            let type = "structure.migration." + operation
            #expect(BackendCommand(type: type, requestId: "r").terminalType == type + ".result")
        }
    }
}
