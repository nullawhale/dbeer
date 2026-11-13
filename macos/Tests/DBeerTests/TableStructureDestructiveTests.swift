import Foundation
import Testing
@testable import DBeer

/// In-memory protocol owners and injected decisions only; no AppKit, windows or credentials.
@MainActor
private final class DestructiveStructureBackend {
    var available = true
    var current = true
    var approve = true
    var authorizeValidation = true
    var loseApply = false
    var missingDropAcknowledgement = false
    var validationState = "completed"
    var returnedCheckID: String?
    var commands: [BackendCommand] = []
    var confirmed: [StructurePlan] = []
    var appliedAuthorizations = 0
    var validationAuthorizations = 0
    var connections = 0
    var beforeConfirmation: (() -> Void)?
    var beforeApplyAuthorization: (() -> Void)?
    var beforeValidationAuthorization: (() -> Void)?
    var duringValidation: (() async -> Void)?
    var published: [TableStructureExecutionReview] = []
    var retained: StructureOutcome?
    var lastDraft = StructureDraft(columns: [])
    var generation = 0
    let target = StructureTarget(schema: "public", table: "synthetic", create: false)
    let digest = String(repeating: "b", count: 64)
    let checkID = "narrow-é"
    var checks: [StructureValidationCheck] {
        [.init(id: checkID, summary: "Check integer range", sql: "SELECT synthetic_range_check", risks: ["This read may scan every row."]),
         .init(id: "unavailable", summary: "Arbitrary expression effects", risks: [], unavailableReason: "User routines cannot be safely evaluated by automatic validation.")]
    }
    var conversion: StructureDraft { .init(columns: [], changes: [.init(name: "amount", type: .init(kind: "integer"))], allowDestructive: true, authoringVersion: 4) }
    var plan: StructurePlan {
        .init(id: "plan-\(generation)", baselineId: "baseline", digest: digest, target: target,
            sql: ["synthetic reviewed DDL"], risks: ["Values may be lost."], destructive: true,
            droppedTarget: lastDraft.dropTable,
            consequences: [.init(kind: "dependency", object: "synthetic.amount", message: "Affected column and stored values.")],
            validationChecks: lastDraft.dropTable ? [] : checks)
    }
    func baseline(_ target: StructureTarget, engine: DatabaseEngine) -> StructureBaseline {
        .init(id: "baseline", target: .init(schema: target.schema, table: target.table, create: target.create), engine: engine.rawValue,
            fingerprint: String(repeating: "a", count: 64),
            columns: target.create ? [] : [.init(name: "amount", nativeType: "BIGINT", nullable: true, editableType: .init(kind: "bigint"), canModify: true)],
            limitations: [], dependencyProof: true)
    }
    func model(engine: DatabaseEngine = .postgresql) -> TableStructureEditorModel {
        .init(profile: .init(name: "Synthetic", settings: .init(host: "synthetic.invalid", port: 5432, database: "synthetic", user: "synthetic", password: "", sslMode: "disable", engine: engine)),
            schema: target.schema, table: target.table, create: false,
            connect: { self.connections += 1; return "session-\(self.connections)" }, send: { try await self.request($0, engine: engine) },
            authorize: { _, _, _ in self.appliedAuthorizations += 1; self.beforeApplyAuthorization?(); return "apply-grant" },
            bindingIsCurrent: { self.current }, destructiveSupported: { self.available },
            confirmPlan: { plan, _ in self.confirmed.append(plan); self.beforeConfirmation?(); return self.approve },
            authorizeValidation: { _, _, _ in self.validationAuthorizations += 1; self.beforeValidationAuthorization?(); return self.authorizeValidation ? "validation-grant" : nil },
            changed: { self.published.append($0) })
    }
    func request(_ command: BackendCommand, engine: DatabaseEngine) async throws -> BackendMessage {
        commands.append(command)
        if command.type == "disconnect" { return .init(type: "disconnect.ack", requestId: command.requestId, sessionId: command.sessionId) }
        if command.type == "cancel" { return .init(type: "cancel.ack", requestId: command.requestId, sessionId: command.sessionId, queryId: command.queryId) }
        var result = BackendMessage(type: command.type + ".result", requestId: command.requestId, sessionId: command.sessionId, queryId: command.queryId, transactionStatus: .idle, connected: true)
        switch command.type {
        case "structure.load": result.structure = .init(baseline: baseline(command.structure?.target ?? target, engine: engine))
        case "structure.preview":
            lastDraft = try #require(command.structure?.draft); generation += 1
            result.structure = .init(plan: plan)
        case "structure.validate":
            await duringValidation?()
            let invocation = try #require(command.structure?.validation)
            let first = StructureValidationCheckOutcome(id: returnedCheckID ?? checkID, state: validationState == "cancelled" ? "cancelled" : "passed", invalidRows: validationState == "cancelled" ? nil : "0")
            result.structure = .init(validation: .init(executionId: invocation.executionId, planId: invocation.planId, digest: invocation.digest,
                state: validationState, checks: [first, .init(id: "unavailable", state: "unavailable", message: "Not evaluated.")]))
        case "structure.apply":
            let apply = try #require(command.structure?.apply)
            let observed = lastDraft.dropTable ? StructureTarget(schema: target.schema, table: target.table, create: true) : target
            retained = .init(executionId: apply.executionId, planId: apply.planId, state: "applied", steps: [.init(state: "applied")], observed: baseline(observed, engine: engine), droppedTarget: lastDraft.dropTable && !missingDropAcknowledgement)
            if loseApply { throw BackendTransportError(.unexpectedEOF, outcomeUnknown: true) }
            result.structure = .init(outcome: retained)
        case "structure.status": result.structure = .init(outcome: retained)
        default: throw BackendTransportError(.invalidMessage)
        }
        return result
    }
}

@MainActor
struct TableStructureDestructiveModelTests {
    @Test(arguments: [DatabaseEngine.postgresql, .mysql, .sqlite])
    func capabilityGatesDropWithoutLosingPortableIntent(engine: DatabaseEngine) async {
        let backend = DestructiveStructureBackend(); backend.available = false
        let model = backend.model(engine: engine)
        await model.load()
        model.draft = .init(columns: [], changes: [.init(name: "amount", drop: true)], allowDestructive: true)
        #expect(model.draft.authoringVersion == 4 && model.canSaveDraft && !model.canPreview)
        #expect(!model.conversionAvailable)
        backend.available = true
        #expect(model.canPreview && model.destructiveAvailable && model.conversionAvailable == (engine != .sqlite))
        await model.preparePreview()
        #expect(model.preview != nil && model.validation == nil)
        backend.available = false
        #expect(!model.canApply && !model.canValidateData)
    }

    @Test func authoringVersionRecalculatesAfterRemovingEveryAdvancedIntent() async {
        let backend = DestructiveStructureBackend(); let model = backend.model()
        await model.load()
        model.draft = backend.conversion
        #expect(model.draft.authoringVersion == 4 && model.canPreview)
        model.draft.changes = nil
        model.draft.indexes = [.init(action: "add", name: "rich", definition: .init(method: "btree", terms: [.init(column: "amount")]))]
        #expect(model.draft.authoringVersion == 3)
        model.draft.indexes = nil
        model.draft.renameTable = "renamed"
        #expect(model.draft.authoringVersion == 2)
        model.draft.renameTable = nil
        #expect(model.draft.authoringVersion == nil)
    }

    @Test func previewNeverValidatesAndCancelledExactConfirmationNeverAuthorizesDDL() async {
        let backend = DestructiveStructureBackend(); let model = backend.model()
        await model.load(); model.draft = backend.conversion
        await model.preparePreview()
        let reviewed = model.preview
        #expect(model.canValidateData && model.validation == nil && backend.validationAuthorizations == 0)
        #expect(backend.commands.allSatisfy { $0.type != "structure.validate" && $0.type != "structure.apply" })
        backend.approve = false
        await model.apply()
        #expect(backend.confirmed == [reviewed].compactMap { $0 } && backend.appliedAuthorizations == 0)
        #expect(model.preview == reviewed && model.outcome == nil && model.draft == backend.conversion)
        #expect(backend.commands.allSatisfy { $0.type != "structure.apply" })
    }

    @Test func validationRequiresItsOwnGrantAndRetainsOrderedPerCheckEvidence() async throws {
        let backend = DestructiveStructureBackend(); let model = backend.model()
        await model.load(); model.draft = backend.conversion; await model.preparePreview()
        let plan = try #require(model.preview)
        backend.authorizeValidation = false
        await model.validateData()
        #expect(model.validation == nil && backend.commands.allSatisfy { $0.type != "structure.validate" })
        backend.authorizeValidation = true
        await model.validateData()
        let validation = try #require(model.validation)
        #expect(validation.planId == plan.id && validation.digest == plan.digest && validation.checks.map(\.state) == ["passed", "unavailable"])
        #expect(model.preview == plan && backend.appliedAuthorizations == 0 && backend.confirmed.isEmpty)
        await model.apply()
        #expect(model.outcomeReview?.validation == validation && backend.published.last?.validation == validation)
        #expect(backend.confirmed == [plan] && backend.appliedAuthorizations == 1)
    }

    @Test func editingAndRepreviewInvalidateValidationWithoutChangingDirtyIntent() async throws {
        let backend = DestructiveStructureBackend(); let model = backend.model()
        await model.load(); model.draft = backend.conversion; await model.preparePreview(); await model.validateData()
        try #require(model.validation != nil)
        let intent = model.draft
        await model.preparePreview()
        #expect(model.validation == nil && model.draft == intent && model.preview?.id == "plan-2")
        await model.validateData()
        model.draft.changes?[0].usingExpression = "amount + 0"
        #expect(model.validation == nil && model.preview == nil && model.draft.changes?.first?.usingExpression == "amount + 0")
    }

    @Test(arguments: ["confirm", "authorize", "validate"])
    func changedDraftDuringDecisionCannotSubmitStaleWork(stage: String) async {
        let backend = DestructiveStructureBackend(); let model = backend.model()
        await model.load(); model.draft = backend.conversion; await model.preparePreview()
        let change: () -> Void = { model.draft.changes?[0].usingExpression = "amount + 0" }
        switch stage {
        case "confirm": backend.beforeConfirmation = change
        case "authorize": backend.beforeApplyAuthorization = change
        default: backend.beforeValidationAuthorization = change
        }
        if stage == "validate" { await model.validateData() } else { await model.apply() }
        #expect(backend.commands.allSatisfy { $0.type != "structure.apply" && $0.type != "structure.validate" })
        #expect(model.outcome == nil && model.preview == nil && model.validation == nil)
        #expect(model.draft.changes?.first?.usingExpression == "amount + 0")
    }

    @Test func capabilityLossDuringConfirmationCannotAuthorizeOrApply() async {
        let backend = DestructiveStructureBackend(); let model = backend.model()
        await model.load(); model.draft = backend.conversion; await model.preparePreview()
        backend.beforeConfirmation = { backend.available = false }
        await model.apply()
        #expect(backend.appliedAuthorizations == 0 && backend.commands.allSatisfy { $0.type != "structure.apply" })
    }

    @Test func changedBindingDuringConfirmationRetainsDirtyDraftAndSendsNoDDL() async {
        let backend = DestructiveStructureBackend(); let model = backend.model()
        await model.load(); model.draft = backend.conversion; await model.preparePreview()
        let dirty = model.draft
        backend.beforeConfirmation = { backend.current = false }
        await model.apply()
        #expect(model.invalidated && model.draft == dirty && model.preview == nil && model.validation == nil)
        #expect(backend.appliedAuthorizations == 0 && backend.commands.allSatisfy { $0.type != "structure.apply" })
    }

    @Test func missingDropAcknowledgementCannotBecomeKnownSuccess() async throws {
        let backend = DestructiveStructureBackend(); backend.missingDropAcknowledgement = true
        let model = backend.model()
        await model.load(); model.draft = .init(columns: [], allowDestructive: true, dropTable: true)
        await model.preparePreview(); await model.apply()
        #expect(model.outcome?.state == "outcomeUnknown" && !model.targetWasDropped)
        #expect(model.outcomeReview?.plan.droppedTarget == true && model.outcomeReview?.draft.dropTable == true)
        #expect(backend.commands.filter { $0.type == "structure.apply" }.count == 1)
    }

    @Test func cancelledValidationKeepsAuthoritativeCancellationAndNeverApplies() async throws {
        let backend = DestructiveStructureBackend(); let model = backend.model()
        await model.load(); model.draft = backend.conversion; await model.preparePreview()
        backend.validationState = "cancelled"; backend.duringValidation = { await model.stop() }
        await model.validateData()
        #expect(model.validation?.state == "cancelled" && model.validation?.checks.first?.state == "cancelled")
        #expect(model.preview != nil && model.outcome == nil && backend.commands.contains { $0.type == "cancel" })
        #expect(backend.commands.allSatisfy { $0.type != "structure.apply" })
    }

    @Test func validationRejectsCanonicalEquivalentCheckIdentityAndLateDraftReplacement() async {
        let backend = DestructiveStructureBackend(); let model = backend.model()
        await model.load(); model.draft = backend.conversion; await model.preparePreview()
        backend.returnedCheckID = "narrow-é"
        await model.validateData()
        #expect(model.validation == nil && model.error != nil)
        backend.returnedCheckID = nil
        backend.duringValidation = { model.draft.changes?[0].usingExpression = "amount + 0" }
        await model.validateData()
        #expect(model.validation == nil && model.preview == nil && model.draft.changes?.first?.usingExpression == "amount + 0")
    }

    @Test(arguments: [false, true])
    func dropAcknowledgementAndUnknownReconciliationRetainOriginalEvidence(unknown: Bool) async throws {
        let backend = DestructiveStructureBackend(); backend.loseApply = unknown
        let model = backend.model(engine: .sqlite)
        await model.load(); model.draft = .init(columns: [], allowDestructive: true, dropTable: true)
        await model.preparePreview(); await model.apply()
        let review = try #require(model.outcomeReview)
        #expect(review.plan.droppedTarget && review.draft.dropTable && review.plan.target == backend.target)
        #expect(model.outcome?.state == (unknown ? "outcomeUnknown" : "applied"))
        if unknown {
            await model.load()
            #expect(model.historyReviews.last?.outcome.state == "outcomeUnknown" && model.historyReviews.last?.draft == review.draft)
            #expect(model.create && model.outcome == nil && model.preview == nil)
            let load = backend.commands.last { $0.type == "structure.load" }
            #expect(load?.structure?.target?.create == true && load?.structure?.target?.reconcile == true)
        } else {
            let loadCount = backend.commands.filter { $0.type == "structure.load" }.count
            await model.load()
            #expect(model.targetWasDropped && model.outcomeReview?.id == review.id)
            #expect(backend.commands.filter { $0.type == "structure.load" }.count == loadCount)
            await model.checkExecutionStatus()
            #expect(model.outcome?.droppedTarget == true && model.outcomeReview?.plan == review.plan)
        }
        #expect(backend.commands.filter { $0.type == "structure.apply" }.count == 1)
    }
}

struct TableStructureDestructivePersistenceTests {
    private var target: StructureTarget { .init(schema: "public", table: "synthetic", create: false) }
    private func folder() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("build/destructive-drafts/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }
    @Test func writerFourPreservesIncompleteExactIntentAndSeparatesDestructiveOptIn() throws {
        let changes: [StructureColumnChange] = [
            .init(name: "é", type: .init(kind: "numeric", precision: 38, scale: 8), usingExpression: ""),
            .init(name: "signed", unsigned: false, charset: "", collation: .init(schema: "", name: "é")),
            .init(name: "drop", drop: true)
        ]
        let document = StructureDraftDocument(engine: .mysql, target: target,
            draft: .init(columns: [], changes: changes, allowDestructive: true))
        #expect(document.valid && document.draft.authoringVersion == 4 && document.draft.allowDestructive == nil && !document.draft.valid)
        let text = try StructureDraftStore.text(document)
        let restored = try JSONDecoder().decode(StructureDraftDocument.self, from: Data(text.utf8))
        #expect(restored == document && restored.formatVersion == 4 && restored.draft.changes?.first?.name.utf8.elementsEqual("é".utf8) == true)
        #expect(restored.draft.changes?[1].unsigned == false && restored.draft.changes?[1].charset == "" && restored.draft.changes?[0].usingExpression == "")
        #expect(!text.contains("authorization") && !text.contains("validation") && !text.contains("baselineId"))
        for version in [1, 2, 3] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(StructureDraftDocument.self, from: Data(text.replacingOccurrences(of: "\"formatVersion\" : 4", with: "\"formatVersion\" : \(version)").utf8))
            }
        }
    }
    @Test func allLegacyWritersReadAndExplicitNewFieldsCannotHideInAnOldEnvelope() throws {
        for version in [1, 2, 3] {
            let text = "{\"formatVersion\":\(version),\"engine\":\"postgresql\",\"target\":{\"schema\":\"public\",\"table\":\"synthetic\",\"create\":false},\"draft\":{\"columns\":[]}}"
            let value = try JSONDecoder().decode(StructureDraftDocument.self, from: Data(text.utf8))
            #expect(value.formatVersion == 4 && value.draft.authoringVersion == nil)
            for fragment in [",\"authoringVersion\":4", ",\"dropTable\":false", ",\"changes\":[{\"name\":\"x\",\"drop\":false}]"] {
                let newFields = text.replacingOccurrences(of: "\"columns\":[]", with: "\"columns\":[]" + fragment)
                #expect(throws: (any Error).self) { try JSONDecoder().decode(StructureDraftDocument.self, from: Data(newFields.utf8)) }
            }
        }
    }
    @MainActor @Test func reopeningDestructiveDraftStaysDisconnectedUntilExplicitLoad() async throws {
        let backend = DestructiveStructureBackend(); let model = backend.model()
        model.discard()
        let document = StructureDraftDocument(engine: .postgresql, target: target,
            draft: .init(columns: [], changes: [.init(name: "é", type: .init(kind: "integer"), usingExpression: "\"é\"::integer")]))
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("synthetic.dbeerstructure")
        _ = try StructureDraftStore.write(document, to: url, expectedVersion: nil)
        await model.openDraft(from: url, expectedDocument: model.portableDraft, replaceReviewed: false)
        #expect(model.draft == document.draft && model.draftFileLabel == "synthetic.dbeerstructure · Saved")
        #expect(backend.connections == 0 && backend.commands.isEmpty && !model.canPreview && !model.canApply)
        await model.load()
        #expect(model.draft == document.draft && model.preview == nil && model.validation == nil && !model.canPreview)
        #expect(model.draft.changes?.first?.usingExpression?.utf8.elementsEqual("\"é\"::integer".utf8) == true)
        model.draft.allowDestructive = true
        #expect(model.canPreview)
    }

    @Test func versionThreeSavedEvidenceRetainsValidationAndReadsOldArtifactsOffline() throws {
        let check = StructureValidationCheck(id: "range", summary: "Observed range", sql: "SELECT synthetic_check", risks: ["Full table scan."])
        let plan = StructurePlan(id: "plan", baselineId: "must-not-survive", digest: String(repeating: "b", count: 64), target: target,
            sql: ["synthetic DDL"], risks: ["Conversion changes values."], destructive: true,
            consequences: [.init(kind: "conversion", object: "synthetic.é", message: "Narrowing may lose values.")], validationChecks: [check])
        let draft = StructureDraft(columns: [], changes: [.init(name: "é", type: .init(kind: "integer"), usingExpression: "\"é\"::integer")], allowDestructive: true, authoringVersion: 4)
        let outcome = StructureOutcome(executionId: "execution", planId: plan.id, state: "applied", steps: [.init(state: "applied")])
        let validation = StructureValidationOutcome(executionId: "validation", planId: plan.id, digest: plan.digest, state: "completed", checks: [.init(id: "range", state: "failed", invalidRows: "18446744073709551615")])
        let review = TableStructureExecutionReview(outcome: outcome, plan: plan, draft: draft, validation: validation)
        let artifact = SavedEvidenceArtifact(id: UUID(), kind: .structure, title: "Conversion", savedAt: Date(timeIntervalSince1970: 1), engine: .postgresql,
            environment: .unspecified, sourceWasStale: false, structure: try SavedStructureEvidence(review))
        let text = try artifact.encoded()
        let restored = try SavedEvidenceArtifact.decode(text)
        #expect(restored.version == 3 && restored.structure?.validation == validation && restored.structure?.consequences == plan.consequences)
        #expect(restored.structure?.displayReview.validation == validation && restored.structure?.displayReview.plan.validationChecks == plan.validationChecks)
        #expect(!text.contains("must-not-survive") && !text.contains("sessionId") && !text.contains("authorization"))
        for version in [1, 2] {
            #expect(throws: (any Error).self) { try SavedEvidenceArtifact.decode(text.replacingOccurrences(of: "\"version\" : 3", with: "\"version\" : \(version)")) }
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/saved-evidence-v1.json"))) as? [String: Any])
        for record in try #require(fixture["artifacts"] as? [[String: Any]]) {
            let original = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
            #expect(try SavedEvidenceArtifact.decode(original).version == 3)
            #expect(try SavedEvidenceArtifact.decode(original.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")).version == 3)
            if record["kind"] as? String == "structure" {
                var wireOnly = try SavedEvidenceArtifact.decode(original)
                wireOnly.structure?.draft.authoringVersion = 4
                wireOnly.structure?.draft.allowDestructive = true
                let current = try wireOnly.encoded()
                for version in [1, 2] {
                    #expect(throws: (any Error).self) { try SavedEvidenceArtifact.decode(current.replacingOccurrences(of: "\"version\" : 3", with: "\"version\" : \(version)")) }
                }
            }
        }
    }

    @Test func savedAbsentObservationIsBoundToAnAcknowledgedDrop() throws {
        let plan = StructurePlan(id: "plan", baselineId: "baseline", digest: String(repeating: "c", count: 64), target: target,
            sql: ["synthetic DROP"], risks: [], destructive: true, droppedTarget: true)
        let absent = StructureBaseline(id: "absent", target: .init(schema: target.schema, table: target.table, create: true), engine: "sqlite", fingerprint: String(repeating: "d", count: 64), columns: [], limitations: [])
        let outcome = StructureOutcome(executionId: "execution", planId: plan.id, state: "applied", steps: [.init(state: "applied")], observed: absent, droppedTarget: true)
        let draft = StructureDraft(columns: [], allowDestructive: true, authoringVersion: 4, dropTable: true)
        let saved = try SavedStructureEvidence(.init(outcome: outcome, plan: plan, draft: draft))
        #expect(saved.valid && saved.displayReview.outcome.droppedTarget && saved.observed?.target.create == true)
        var forged = saved; forged.droppedTarget = nil
        #expect(!forged.valid)
        forged = saved; forged.state = "failed"; forged.steps = [.init(state: "failed")]
        #expect(!forged.valid)
    }
}

struct TableStructureDestructiveContractTests {
    @Test func sharedFixtureClosesCommandsAndResponseBoundaries() throws {
        struct Fixture: Decodable { var valid: [BackendCommand]; var invalid: [String]; var responses: [BackendMessage]; var invalidResponses: [String] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/table-structure-destructive-v1.json")))
        for command in fixture.valid {
            if command.type != "operation.assess" { #expect(command.structure?.valid(for: command.type) == true) }
            #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command)) == command)
        }
        for (index, raw) in fixture.invalid.enumerated() {
            var accepted = false
            do {
                let frame = Data(raw.utf8)
                _ = try GPUIProductBuildIdentity.optionalFromFrame(frame, maximumFrameBytes: BackendProtocol.maxFrameBytes)
                let command = try JSONDecoder().decode(BackendCommand.self, from: frame)
                if command.type == "operation.assess" {
                    accepted = command.operations?.count == 1 && command.operations?.allSatisfy { $0.type == "structure.validate" && $0.structure?.valid == true && $0.sql == nil && $0.export == nil && $0.changes == nil && $0.explain == nil && $0.parameters == nil && $0.tableImport == nil && $0.nativeCommand == nil && $0.queryId == nil } == true
                } else { accepted = command.structure?.valid(for: command.type) == true }
            } catch {}
            #expect(!accepted, "Invalid structure command case \(index)")
        }
        for reply in fixture.responses { try reply.validate() }
        for raw in fixture.invalidResponses {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(BackendMessage.self, from: Data(raw.utf8)).validate() }
        }
    }
}

/// Controlled framed Python subprocesses only; no app or database is launched.
@MainActor
struct TableStructureDestructiveTransportTests {
    private func client(hello: Bool, session: Bool, rich: Bool = false, observed: Bool = false, disconnected: Bool = false, wrongValidation: Bool = false) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys
        def read(): return json.loads(sys.stdin.readline())
        def send(v): print(json.dumps(v),flush=True)
        cap='tableStructureDestructiveV1'
        index='tableStructureIndexAuthoringV1'
        hc=([cap] if \(hello ? "True" : "False") else [])+([index] if \(rich ? "True" : "False") else [])
        sc=([cap] if \(session ? "True" : "False") else [])+([index] if \(rich ? "True" : "False") else [])
        c=read();send(dict(type='hello.ack',requestId=c['requestId'],protocolVersion=6,capabilities=hc))
        target=dict(schema='public',table='synthetic',create=False)
        baseline=dict(id='baseline',target=target,engine='mysql',fingerprint='a'*64,columns=[],limitations=[])
        if \(observed ? "True" : "False"):
            baseline['columns']=[dict(name='amount',nativeType='int unsigned',nullable=True,unsigned=True,charset='utf8mb4',collation=dict(schema='',name='utf8mb4_bin'))]
        while True:
            c=read()
            if c['type']=='shutdown':
                send(dict(type='shutdown.ack',requestId=c['requestId']));break
            if c['type']=='connect':
                send(dict(type='connect.result',requestId=c['requestId'],sessionId='session',engine='mysql',transactionStatus='idle',connected=True,capabilities=sc));continue
            if c['type']=='disconnect':
                send(dict(type='disconnect.ack',requestId=c['requestId'],sessionId=c['sessionId']));continue
            send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
            if c['type']=='structure.load': payload=dict(baseline=baseline)
            elif c['type']=='structure.status':
                payload=dict(outcome=dict(executionId='execution',planId='plan',state='outcomeUnknown',steps=[dict(state='unknown')],observed=baseline))
            elif c['type']=='structure.validate':
                v=c['structure']['validation']
                payload=dict(validation=dict(executionId=v['executionId'],planId='other' if \(wrongValidation ? "True" : "False") else v['planId'],digest=v['digest'],state='completed',checks=[dict(id='range',state='passed',invalidRows='0')]))
            else:
                payload=dict(plan=dict(id='plan',baselineId='baseline',digest='b'*64,target=target,sql=['synthetic DDL'],risks=[],consequences=[dict(kind='conversion',object='amount',message='Conversion may lose data.')]))
            send(dict(type=c['type']+'.result',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'],transactionStatus='idle',connected=\(disconnected ? "False" : "True"),structure=payload))
        """])
    }
    private func connect(_ client: BackendClient) async throws {
        try await client.start()
        _ = try await client.request(.connect(.init(host: "synthetic.invalid", port: 3306, database: "synthetic", user: "synthetic", password: "", sslMode: "disable", engine: .mysql)))
    }
    private func command(_ operation: String, _ request: StructureRequest, authorization: String? = nil) -> BackendCommand {
        .init(type: "structure." + operation, requestId: UUID().uuidString, sessionId: "session", queryId: UUID().uuidString, authorization: authorization, structure: request)
    }
    @Test(arguments: [false, true], [false, true])
    func versionFourAndValidationRequireBothCapabilities(hello: Bool, session: Bool) async throws {
        let client = client(hello: hello, session: session)
        try await connect(client)
        let preview = command("preview", .init(baselineId: "baseline", draft: .init(columns: [], indexes: [.init(action: "add", name: "ordinary", columns: ["amount"])], allowDestructive: true, authoringVersion: 4)))
        let validation = command("validate", .init(validation: .init(planId: "plan", digest: String(repeating: "b", count: 64), executionId: "validation")), authorization: "grant")
        if hello && session {
            #expect(try await client.request(preview).structure?.plan?.consequences.count == 1)
            #expect(try await client.request(validation).structure?.validation?.checks.first?.invalidRows == "0")
        } else {
            await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(preview) }
            await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(validation) }
            #expect(!(await client.hasExited()))
        }
        _ = await client.shutdown(); _ = await client.waitForExit()
    }
    @Test(arguments: [false, true], [false, true])
    func incomingNativeFactsRequireBothCapabilities(hello: Bool, session: Bool) async throws {
        let client = client(hello: hello, session: session, observed: true)
        try await connect(client)
        let load = command("load", .init(target: .init(schema: "public", table: "synthetic", create: false)))
        if hello && session { #expect(try await client.request(load).structure?.baseline?.columns.first?.collation?.name == "utf8mb4_bin") }
        else { await #expect(throws: BackendTransportError.self) { try await client.request(load) } }
        _ = await client.shutdown(); _ = await client.waitForExit()
    }
    @Test func richVersionFourStillRequiresIndependentIndexCapability() async throws {
        let client = client(hello: true, session: true)
        try await connect(client)
        let draft = StructureDraft(columns: [], changes: [.init(name: "amount", unsigned: false)], indexes: [.init(action: "add", name: "rich", definition: .init(method: "btree", terms: [.init(column: "amount")]))], allowDestructive: true, authoringVersion: 4)
        await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(command("preview", .init(baselineId: "baseline", draft: draft))) }
        #expect(!(await client.hasExited()))
        _ = await client.shutdown(); _ = await client.waitForExit()
    }
    @Test func validationAssessmentRequiresItsOwnNegotiatedCapability() async throws {
        let client = client(hello: false, session: false)
        try await connect(client)
        let operation = OperationRequest(type: "structure.validate", structure: .init(planId: "plan", digest: String(repeating: "b", count: 64), executionId: "validation"))
        await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(.assess(sessionId: "session", operations: [operation])) }
        #expect(!(await client.hasExited()))
        _ = await client.shutdown(); _ = await client.waitForExit()
    }
    @Test func validationReplyCannotSubstituteAnotherPlan() async throws {
        let client = client(hello: true, session: true, wrongValidation: true)
        try await connect(client)
        await #expect(throws: BackendTransportError.self) {
            try await client.request(command("validate", .init(validation: .init(planId: "plan", digest: String(repeating: "b", count: 64), executionId: "validation")), authorization: "grant"))
        }
        _ = await client.shutdown(); _ = await client.waitForExit()
    }
    @Test func logicalDisconnectClearsRetainedStatusAdmission() async throws {
        let client = client(hello: true, session: true, observed: true, disconnected: true)
        try await connect(client)
        _ = try await client.request(command("load", .init(target: .init(schema: "public", table: "synthetic", create: false))))
        _ = try await client.request(.disconnect(sessionId: "session"))
        await #expect(throws: BackendTransportError.self) { try await client.request(command("status", .init())) }
        _ = await client.shutdown(); _ = await client.waitForExit()
    }
    @Test func replacementHelperCannotInheritRetainedStatusCapabilities() async throws {
        let previous = client(hello: true, session: true, observed: true, disconnected: true)
        try await connect(previous)
        _ = try await previous.request(command("load", .init(target: .init(schema: "public", table: "synthetic", create: false))))
        _ = await previous.shutdown(); _ = await previous.waitForExit()
        let replacement = client(hello: true, session: false, observed: true)
        try await connect(replacement)
        await #expect(throws: BackendTransportError.self) { try await replacement.request(command("status", .init())) }
        _ = await replacement.shutdown(); _ = await replacement.waitForExit()
    }
    @Test func terminalDisconnectRetainsOriginalCapabilityAdmission() async throws {
        let client = client(hello: true, session: true, observed: true, disconnected: true)
        try await connect(client)
        let reply = try await client.request(command("load", .init(target: .init(schema: "public", table: "synthetic", create: false))))
        #expect(reply.connected == false && reply.structure?.baseline?.columns.first?.unsigned == true)
        let status = try await client.request(command("status", .init()))
        #expect(status.structure?.outcome?.state == "outcomeUnknown" && status.structure?.outcome?.observed?.columns.first?.unsigned == true)
        await #expect(throws: BackendRequestError.invalidCommand) {
            try await client.request(command("validate", .init(validation: .init(planId: "plan", digest: String(repeating: "b", count: 64), executionId: "validation")), authorization: "grant"))
        }
        _ = await client.shutdown(); _ = await client.waitForExit()
    }
}
