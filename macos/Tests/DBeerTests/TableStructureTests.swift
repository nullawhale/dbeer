import Foundation
import Testing
@testable import DBeer

struct TableStructureProtocolTests {
    @Test func sharedContractRejectsMissingDuplicateAndUnknownFields() throws {
        struct Fixture: Decodable { var valid: [BackendCommand]; var invalid: [String]; var responses: [BackendMessage] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/table-structure-editor-v1.json")))
        for command in fixture.valid {
            #expect(command.structure?.valid(for: command.type) == true)
            #expect(command.terminalType == command.type + ".result")
            #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command)) == command)
        }
        for response in fixture.responses { try response.validate() }
        for raw in fixture.invalid {
            let data = Data(raw.utf8)
            var accepted = false
            do {
                _ = try GPUIProductBuildIdentity.optionalFromFrame(data, maximumFrameBytes: BackendProtocol.maxFrameBytes)
                let command = try JSONDecoder().decode(BackendCommand.self, from: data)
                accepted = command.structure?.valid(for: command.type) == true
            } catch {}
            #expect(!accepted)
        }
    }
    @Test func outcomeValidationPreservesAcknowledgementAndRejectsFalseSuccess() {
        var result = StructureOutcome(executionId: "execution", planId: "plan", state: "outcomeUnknown", steps: [.init(state: "unknown")])
        #expect(result.valid)
        result.state = "applied"
        #expect(!result.valid)
        result.steps[0].state = "applied"; result.refreshError = "Observation failed"
        #expect(result.valid)
    }
}
struct TableStructureDraftTests {
    @Test func defaultsPreserveNullEmptyTextAndExactNumeric() throws {
        let defaults: [StructureDefault] = [.init(kind: "none"), .init(kind: "null"), .init(kind: "text", value: ""), .init(kind: "text", value: "NULL"), .init(kind: "text", value: "DEFAULT"), .init(kind: "numeric", value: "12345678901234567890.1234567890")]
        for value in defaults {
            #expect(value.valid)
            #expect(try JSONDecoder().decode(StructureDefault.self, from: JSONEncoder().encode(value)) == value)
        }
        #expect(!StructureDefault(kind: "expression", value: "now()").valid)
        #expect(!StructureDefault(kind: "null", value: "").valid)
    }
}
@MainActor
private final class StructureModelBackend {
    var calls: [String] = []
    var current = true
    var loseApply = false
    var confirm = true
    var failBeforeSend = false
    var sentApplyCount = 0
    var holdDisconnect = false
    var disconnectGate: CheckedContinuation<Void, Never>?
    var tableExists = false
    var deadHelper = false
    var failDisconnect = false
    let target = StructureTarget(schema: "public", table: "samples", create: true)
    var baseline: StructureBaseline { .init(id: "baseline", target: .init(schema: target.schema, table: target.table, create: !tableExists), engine: "postgresql", fingerprint: String(repeating: "a", count: 64), columns: [], limitations: []) }
    var plan: StructurePlan { .init(id: "plan", baselineId: "baseline", digest: String(repeating: "b", count: 64), target: target, sql: ["synthetic reviewed SQL"], risks: ["synthetic risk"]) }
    func request(_ command: BackendCommand) async throws -> BackendMessage {
        calls.append(command.type)
        var reply = BackendMessage(type: command.type + ".result", requestId: command.requestId,
            sessionId: command.sessionId, queryId: command.queryId, transactionStatus: .idle)
        switch command.type {
        case "structure.load": reply.structure = .init(baseline: baseline)
        case "disconnect":
            if failDisconnect { throw BackendTransportError(.notReady) }
            if holdDisconnect { await withCheckedContinuation { disconnectGate = $0 } }
            reply = BackendMessage(type: "disconnect.ack", requestId: command.requestId, sessionId: command.sessionId)
        case "structure.preview": reply.structure = .init(plan: plan)
        case "structure.apply":
            if failBeforeSend { throw BackendTransportError(.notReady) }
            sentApplyCount += 1
            if loseApply { throw BackendTransportError(.unexpectedEOF, outcomeUnknown: true) }
            let apply = command.structure!.apply!
            reply.structure = .init(outcome: .init(executionId: apply.executionId, planId: apply.planId, state: "applied", steps: [.init(state: "applied")]))
        default: break
        }
        return reply
    }
    func model() -> TableStructureEditorModel {
        .init(profile: SavedConnection(name: "Fixture", settings: .init(host: "fixture.invalid", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable")),
            schema: "public", table: "samples", create: true,
            connect: { self.calls.append("connect"); return "session" }, send: request,
            authorize: { _, _, _ in self.confirm ? "grant" : nil },
            bindingIsCurrent: { self.current }, sessionIsKnownClosed: { self.deadHelper }, changed: { _ in })
    }
}
@MainActor
struct TableStructureEditorModelTests {
    @Test func draftNeverConnectsAndEveryEditInvalidatesPreview() async {
        let backend = StructureModelBackend(); let model = backend.model()
        #expect(backend.calls.isEmpty)
        await model.load()
        model.draft.columns[0].name = "label"
        await model.preparePreview()
        #expect(model.canApply && !backend.calls.contains("structure.apply"))
        model.draft.columns[0].name = "changed"
        #expect(model.preview == nil && !model.canApply)
        model.discard()
        #expect(model.draft.columns[0].name.isEmpty && !backend.calls.contains("structure.apply"))
    }
    @Test func changedBindingAndCancelledConfirmationNeverDispatchDDL() async {
        let backend = StructureModelBackend(); let model = backend.model()
        await model.load(); model.draft.columns[0].name = "label"; await model.preparePreview()
        backend.confirm = false; await model.apply()
        #expect(!backend.calls.contains("structure.apply"))
        backend.current = false; backend.confirm = true; await model.apply()
        #expect(model.invalidated && !backend.calls.contains("structure.apply"))
    }
    @Test func lostAcknowledgementRequiresReconciliationAndCannotReplay() async {
        let backend = StructureModelBackend(); let model = backend.model()
        await model.load(); model.draft.columns[0].name = "label"; await model.preparePreview()
        backend.loseApply = true; await model.apply()
        #expect(model.outcome?.state == "outcomeUnknown" && !model.canApply && model.preview == nil)
        await model.apply()
        #expect(backend.calls.filter { $0 == "structure.apply" }.count == 1)
    }
}

@MainActor
struct TableStructureClosingTests {
    @Test func suspendedDisconnectBlocksNewApplyUntilPositiveAcknowledgement() async throws {
        let backend = StructureModelBackend(); let model = backend.model()
        await model.load(); model.draft.columns[0].name = "value"; await model.preparePreview()
        backend.holdDisconnect = true
        #expect(model.beginClosing())
        let closing = Task { await model.close() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while backend.disconnectGate == nil && ContinuousClock.now < deadline { await Task.yield() }
        #expect(!model.canApply && model.closing)
        await model.apply()
        #expect(backend.sentApplyCount == 0)
        backend.disconnectGate?.resume(); backend.disconnectGate = nil
        #expect(await closing.value)
    }
    @Test func failureBeforeDispatchStaysNotStartedAndCreateAbsenceReconciles() async {
        let backend = StructureModelBackend(); let model = backend.model()
        await model.load(); model.draft.columns[0].name = "value"; await model.preparePreview()
        backend.failBeforeSend = true; await model.apply()
        #expect(model.outcome?.state == "failed" && model.outcome?.steps.first?.state == "notStarted")
        #expect(backend.sentApplyCount == 0 && model.create)
        await model.load()
        #expect(model.baseline?.target.create == true && model.create && model.outcome == nil)
        #expect(model.history.first?.state == "failed")
    }
    @Test func unknownCreateReconcilesPresenceWithoutRewritingHistoricalOutcome() async {
        let backend = StructureModelBackend(); let model = backend.model()
        await model.load(); model.draft.columns[0].name = "value"; await model.preparePreview()
        backend.loseApply = true; await model.apply(); backend.tableExists = true
        await model.load()
        #expect(!model.create && model.baseline?.target.create == false)
        #expect(model.history.first?.state == "outcomeUnknown")
    }
}
struct TableStructureExactIdentifierTests {
    @Test func canonicallyEquivalentIdentifiersRetainDistinctBytes() throws {
        let a = "é"; let b = "é"
        #expect(a == b)
        let first = StructureTarget(schema: a, table: a, create: true)
        let second = StructureTarget(schema: b, table: b, create: true)
        #expect(first != second)
        let column = StructureColumn(name: a, type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))
        var other = column; other.name = b
        let draft = StructureDraft(columns: [column, other])
        #expect(draft.valid)
        #expect(StructureDraft(columns: [column]) != StructureDraft(columns: [other]))
    }
}

@MainActor
struct TableStructureRetentionTests {
    @Test func reviewedIntentAndSQLSurviveUnknownOutcomeAndReconciliation() async throws {
        let backend = StructureModelBackend(); let model = backend.model()
        await model.load(); model.draft.columns[0].name = "retained_value"; await model.preparePreview()
        let reviewed = try #require(model.preview)
        backend.loseApply = true; await model.apply()
        let report = try #require(model.outcomeReview)
        #expect(report.plan == reviewed && report.draft.columns[0].name == "retained_value")
        await model.load()
        #expect(model.outcomeReview == nil && model.historyReviews.count == 1)
        #expect(model.historyReviews[0].plan.sql == reviewed.sql && model.historyReviews[0].outcome.state == "outcomeUnknown")
        #expect(backend.sentApplyCount == 1)
    }
    @Test func dirtyUnnamedColumnRetainsNonNameChanges() {
        let model = StructureModelBackend().model()
        #expect(!model.hasDraft)
        model.draft.columns[0].nullable = false
        #expect(model.hasDraft)
        model.discard()
        model.draft.columns[0].type = .init(kind: "bigint")
        #expect(model.hasDraft)
    }
    @Test func knownDeadHelperAllowsCleanupWithoutRewritingUnknownEvidence() async {
        let backend = StructureModelBackend(); let model = backend.model()
        await model.load(); model.draft.columns[0].name = "value"; await model.preparePreview()
        backend.loseApply = true; await model.apply()
        backend.failDisconnect = true
        #expect(!(await model.close()))
        backend.deadHelper = true
        #expect(await model.close())
        #expect(model.outcomeReview?.outcome.state == "outcomeUnknown" && backend.sentApplyCount == 1)
    }
}
