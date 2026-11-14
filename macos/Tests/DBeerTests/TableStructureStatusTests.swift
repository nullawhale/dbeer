import Foundation
import Testing
@testable import DBeer

@MainActor
private final class StructureStatusBackend {
    var commands: [BackendCommand] = []
    var current = true
    var helperClosed = false
    var disconnectFails = false
    var failConnect = false
    var failLoad = false
    var holdDisconnect = false
    var disconnectGate: CheckedContinuation<Void, Never>?
    var activeSessions: Set<String> = []
    var unusableSessions: Set<String> = []
    var holdStatus = false
    var statusGate: CheckedContinuation<Void, Never>?
    var statusOutcome: StructureOutcome?
    var applyOutcome: StructureOutcome?
    var appliedRequest: StructureApply?
    var changed: [TableStructureExecutionReview] = []
    var connectCount = 0
    var statusPhysicalClosed = false
    let target = StructureTarget(schema: "public", table: "samples", create: false)
    var baseline: StructureBaseline {
        .init(id: "baseline", target: target, engine: "postgresql", fingerprint: String(repeating: "a", count: 64), columns: [], limitations: [])
    }
    var plan: StructurePlan {
        .init(id: "plan", baselineId: "baseline", digest: String(repeating: "b", count: 64), target: target,
              sql: ["synthetic step one", "synthetic step two", "synthetic step three"], risks: ["synthetic warning"])
    }
    func model() -> TableStructureEditorModel {
        .init(profile: .init(name: "Synthetic", settings: .init(host: "synthetic.invalid", port: 5432, database: "synthetic", user: "synthetic", password: "", sslMode: "disable")),
              schema: target.schema, table: target.table, create: false,
              connect: {
                  self.connectCount += 1
                  if self.failConnect { throw BackendTransportError(.notReady) }
                  let id = self.connectCount == 1 ? "original-session" : "reconciled-session-\(self.connectCount)"
                  self.activeSessions.insert(id)
                  self.helperClosed = false
                  return id
              }, send: request,
              authorize: { _, _, _ in "original-grant" }, bindingIsCurrent: { self.current },
              sessionIsKnownClosed: { self.helperClosed }, changed: { self.changed.append($0) })
    }
    func request(_ command: BackendCommand) async throws -> BackendMessage {
        commands.append(command)
        var response = BackendMessage(type: command.type + ".result", requestId: command.requestId,
                                      sessionId: command.sessionId, queryId: command.queryId,
                                      transactionStatus: .idle, connected: true)
        switch command.type {
        case "structure.load":
            // Mirror the helper's idle-session requirement rather than accepting
            // reads on the original connection after connected:false.
            guard let session = command.sessionId, activeSessions.contains(session), !unusableSessions.contains(session), !failLoad else {
                var rejected = BackendMessage(type: "error", requestId: command.requestId,
                                              sessionId: command.sessionId, queryId: command.queryId)
                rejected.connected = command.sessionId.map { activeSessions.contains($0) && !unusableSessions.contains($0) } == true
                rejected.sqlNotExecuted = true
                rejected.message = "A fresh idle structure session is required."
                throw BackendRemoteError(reply: rejected)
            }
            response.structure = .init(baseline: baseline)
        case "structure.preview": response.structure = .init(plan: plan)
        case "structure.apply":
            appliedRequest = command.structure?.apply
            if let applyOutcome { response.structure = .init(outcome: applyOutcome) }
            else { throw BackendTransportError(.unexpectedEOF, outcomeUnknown: true) }
        case "structure.status":
            if holdStatus { await withCheckedContinuation { statusGate = $0 } }
            response.structure = .init(outcome: statusOutcome)
            if statusPhysicalClosed {
                if let session = command.sessionId { unusableSessions.insert(session) }
                response.connected = false
                response.transactionStatus = nil
            }
        case "cancel":
            return BackendMessage(type: "cancel.ack", requestId: command.requestId, sessionId: command.sessionId, queryId: command.queryId)
        case "disconnect":
            if disconnectFails { throw BackendTransportError(.notReady) }
            if holdDisconnect { await withCheckedContinuation { disconnectGate = $0 } }
            if let session = command.sessionId { activeSessions.remove(session) }
            return BackendMessage(type: "disconnect.ack", requestId: command.requestId, sessionId: command.sessionId)
        default: break
        }
        return response
    }
    func outcome(_ state: String, _ steps: [String], observed: Bool = false) throws -> StructureOutcome {
        let apply = try #require(appliedRequest)
        return .init(executionId: apply.executionId, planId: apply.planId, state: state,
                     steps: steps.map { .init(state: $0) }, observed: observed ? baseline : nil)
    }
    func prepareUnknown() async throws -> TableStructureEditorModel {
        let model = model()
        await model.load()
        model.draft.columns = [.init(name: "retained_value", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))]
        await model.preparePreview()
        #expect(model.canApply)
        await model.apply()
        #expect(model.outcome?.state == "outcomeUnknown" && model.canCheckExecutionStatus)
        return model
    }
    func waitForStatus() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while statusGate == nil && ContinuousClock.now < deadline { await Task.yield() }
        _ = try #require(statusGate)
    }
    func releaseStatus() { statusGate?.resume(); statusGate = nil }
}

@MainActor
struct TableStructureStatusTests {
    @Test func recoveredAcknowledgementRequiresFreshLoadAndRetainsReviewedIntent() async throws {
        let backend = StructureStatusBackend()
        let model = try await backend.prepareUnknown()
        let original = try #require(model.outcomeReview)
        backend.statusOutcome = try backend.outcome("applied", ["applied", "applied", "applied"], observed: true)
        backend.statusPhysicalClosed = true
        await model.checkExecutionStatus()
        #expect(model.outcome?.state == "applied" && model.outcome?.observed == backend.baseline)
        #expect(model.outcomeReview?.plan == original.plan && model.outcomeReview?.draft == original.draft)
        #expect(model.baseline == nil && model.preview == nil && !model.canApply && !model.canPreview)
        #expect(backend.connectCount == 1 && backend.commands.filter { $0.type == "structure.status" }.allSatisfy { $0.sessionId == "original-session" })
        await model.apply()
        #expect(backend.commands.filter { $0.type == "structure.apply" }.count == 1)
        await model.load()
        #expect(model.baseline != nil && model.outcome == nil && model.preview == nil)
        #expect(backend.connectCount == 2 && backend.commands.filter { $0.type == "structure.load" }.last?.sessionId == "reconciled-session-2")
        #expect(backend.commands.contains { $0.type == "disconnect" && $0.sessionId == "original-session" })
        #expect(!model.canCheckExecutionStatus)
        #expect(model.historyReviews.last?.draft == original.draft && model.historyReviews.last?.outcome.state == "applied")
        #expect(model.statusNotice?.contains("Execution History") == true)
    }

    @Test func partialAndUnknownReportsKeepSeparateIntentAndObservedEvidence() async throws {
        let backend = StructureStatusBackend()
        let model = try await backend.prepareUnknown()
        let original = model.portableDraft
        backend.statusOutcome = try backend.outcome("partiallyApplied", ["applied", "failed", "notStarted"], observed: true)
        await model.checkExecutionStatus()
        #expect(model.outcome?.state == "partiallyApplied" && model.outcome?.steps.last?.state == "notStarted")
        #expect(model.portableDraft == original && model.canSaveDraft && !model.canApply && model.baseline == nil)
        // The helper may retain an unresolved step even after it has read matching metadata.
        let anotherBackend = StructureStatusBackend()
        let another = try await anotherBackend.prepareUnknown()
        anotherBackend.statusOutcome = try anotherBackend.outcome("outcomeUnknown", ["applied", "unknown", "notStarted"], observed: true)
        await another.checkExecutionStatus()
        #expect(another.outcome?.state == "outcomeUnknown" && !another.canApply && another.outcome?.observed != nil)
    }

    @Test func missingAndUnavailableEvidencePreservesUnknownWithoutReconnect() async throws {
        let backend = StructureStatusBackend()
        let model = try await backend.prepareUnknown()
        let original = model.outcome
        await model.checkExecutionStatus()
        #expect(model.outcome == original && model.statusNotice != nil && backend.connectCount == 1)
        let before = backend.commands.count
        backend.helperClosed = true
        await model.checkExecutionStatus()
        #expect(backend.commands.count == before && model.outcome == original && backend.connectCount == 1)
        #expect(!model.canApply && model.baseline == nil)
    }

    @Test(arguments: ["execution", "plan", "steps", "state", "target", "engine"])
    func rejectsEvidenceForAnotherExecutionOrMalformedSteps(change: String) async throws {
        let backend = StructureStatusBackend()
        let model = try await backend.prepareUnknown()
        let original = model.outcome
        var report = try backend.outcome("applied", ["applied", "applied", "applied"], observed: true)
        switch change {
        case "execution": report.executionId = "another-execution"
        case "plan": report.planId = "another-plan"
        case "steps": report.steps.removeLast()
        case "state": report.steps[0].state = "unknown"
        case "target": report.observed?.target.table = "another-table"
        case "engine": report.observed?.engine = "mysql"
        default: break
        }
        backend.statusOutcome = report
        await model.checkExecutionStatus()
        #expect(model.outcome == original && model.error != nil && model.baseline == nil && !model.canApply)
        #expect(backend.changed.count == 1 && backend.connectCount == 1)
    }

    @Test func confirmedAppliedPrefixCannotBeReplacedByWeakerEvidence() async throws {
        let backend = StructureStatusBackend()
        let model = try await backend.prepareUnknown()
        backend.statusOutcome = try backend.outcome("partiallyApplied", ["applied", "failed", "notStarted"])
        await model.checkExecutionStatus()
        let retained = model.outcome
        backend.statusOutcome = try backend.outcome("failed", ["failed", "notStarted", "notStarted"])
        await model.checkExecutionStatus()
        #expect(model.outcome == retained && model.error != nil && backend.changed.count == 2)
    }

    @Test func rereadingIdenticalEvidenceDoesNotInvalidateOtherDocumentsAgain() async throws {
        let backend = StructureStatusBackend()
        let model = try await backend.prepareUnknown()
        backend.statusOutcome = try backend.outcome("partiallyApplied", ["applied", "failed", "notStarted"])
        await model.checkExecutionStatus()
        #expect(backend.changed.count == 2)
        await model.checkExecutionStatus()
        #expect(backend.changed.count == 2 && model.outcome?.state == "partiallyApplied")
    }

    @Test func stopKeepsBusyUntilTerminalAndDoesNotReplaceUnknownOutcome() async throws {
        let backend = StructureStatusBackend()
        let model = try await backend.prepareUnknown()
        let original = model.outcome
        backend.statusOutcome = try backend.outcome("applied", ["applied", "applied", "applied"])
        backend.holdStatus = true
        let request = Task { await model.checkExecutionStatus() }
        try await backend.waitForStatus()
        await model.stop()
        #expect(model.isBusy && !model.canApply && model.outcome == original)
        backend.releaseStatus()
        await request.value
        #expect(!model.isBusy && model.outcome == original && model.error != nil)
        backend.holdStatus = false
        await model.checkExecutionStatus()
        #expect(model.outcome?.state == "applied" && backend.connectCount == 1)
    }

    @Test(arguments: ["binding", "target", "draft", "closing"])
    func lateStatusCannotReplaceChangedContext(change: String) async throws {
        let backend = StructureStatusBackend()
        let model = try await backend.prepareUnknown()
        let original = model.outcome
        backend.statusOutcome = try backend.outcome("applied", ["applied", "applied", "applied"])
        backend.holdStatus = true
        let request = Task { await model.checkExecutionStatus() }
        try await backend.waitForStatus()
        switch change {
        case "binding": backend.current = false
        case "target": model.table = "another-table"
        case "draft": model.draft.columns[0].name = "changed"
        case "closing": #expect(model.beginClosing())
        default: break
        }
        backend.releaseStatus()
        await request.value
        #expect(model.outcome == original && model.error != nil && backend.changed.count == 1)
        #expect(backend.connectCount == 1 && !model.canApply)
    }

    @Test func failedRetirementKeepsTheReportAndNeverOpensAnotherSession() async throws {
        let backend = StructureStatusBackend()
        let model = try await backend.prepareUnknown()
        backend.statusOutcome = try backend.outcome("outcomeUnknown", ["applied", "unknown", "notStarted"])
        backend.statusPhysicalClosed = true
        await model.checkExecutionStatus()
        let retained = model.outcomeReview
        backend.disconnectFails = true
        await model.load()
        #expect(model.outcomeReview?.outcome == retained?.outcome && model.outcomeReview?.draft == retained?.draft)
        #expect(model.error != nil && model.baseline == nil && backend.connectCount == 1 && model.canCheckExecutionStatus)
        #expect(backend.commands.filter { $0.type == "structure.load" }.count == 1)
        await model.apply()
        #expect(backend.commands.filter { $0.type == "structure.apply" }.count == 1)
    }

    @Test func freshLoadFailureKeepsIntentAndRetiresOriginalStatusLocation() async throws {
        let backend = StructureStatusBackend()
        let model = try await backend.prepareUnknown()
        backend.statusOutcome = try backend.outcome("partiallyApplied", ["applied", "failed", "notStarted"])
        backend.statusPhysicalClosed = true
        await model.checkExecutionStatus()
        let retained = model.outcomeReview
        backend.failLoad = true
        await model.load()
        #expect(backend.connectCount == 2 && model.outcomeReview?.outcome == retained?.outcome && model.portableDraft.draft == retained?.draft)
        #expect(model.error != nil && model.baseline == nil && !model.canCheckExecutionStatus && !model.canPreview && !model.canApply)
        let count = backend.commands.count
        await model.checkExecutionStatus()
        #expect(backend.commands.count == count)
        backend.failLoad = false
        await model.load()
        #expect(backend.connectCount == 2 && model.baseline != nil && model.historyReviews.last?.outcome.state == "partiallyApplied")
    }

    @Test func explicitLoadAfterKnownHelperExitOpensFreshSessionAndRetainsUnknownHistory() async throws {
        let backend = StructureStatusBackend()
        let model = try await backend.prepareUnknown()
        let retained = model.portableDraft
        backend.helperClosed = true
        await model.checkExecutionStatus()
        #expect(backend.connectCount == 1)
        await model.load()
        #expect(backend.connectCount == 2 && !backend.commands.contains { $0.type == "disconnect" })
        #expect(model.baseline != nil && model.historyReviews.last?.outcome.state == "outcomeUnknown")
        #expect(model.historyReviews.last?.draft == retained.draft && !model.canCheckExecutionStatus)
    }

    @Test(arguments: ["cancel", "binding"])
    func retirementWaitsForAcknowledgementBeforeOpeningNewSession(change: String) async throws {
        let backend = StructureStatusBackend()
        let model = try await backend.prepareUnknown()
        backend.statusOutcome = try backend.outcome("applied", ["applied", "applied", "applied"])
        backend.statusPhysicalClosed = true
        await model.checkExecutionStatus()
        let retained = model.outcome
        backend.holdDisconnect = true
        let load = Task { await model.load() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while backend.disconnectGate == nil && ContinuousClock.now < deadline { await Task.yield() }
        let gate = try #require(backend.disconnectGate)
        #expect(model.isBusy && backend.connectCount == 1 && model.outcome == retained)
        if change == "cancel" { await model.stop() }
        else { backend.current = false }
        gate.resume()
        backend.disconnectGate = nil
        await load.value
        #expect(!model.isBusy && backend.connectCount == 1 && model.outcome == retained && model.baseline == nil)
        #expect(!model.canCheckExecutionStatus && model.error != nil)
    }

    @Test func applyAlsoRejectsMismatchedAcknowledgementAndRetainsOriginalExecutionIdentity() async throws {
        let backend = StructureStatusBackend()
        let model = backend.model()
        await model.load()
        model.draft.columns = [.init(name: "retained_value", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))]
        await model.preparePreview()
        backend.applyOutcome = .init(executionId: "foreign-execution", planId: "plan", state: "applied", steps: [.init(state: "applied"), .init(state: "applied"), .init(state: "applied")])
        await model.apply()
        #expect(model.outcome?.state == "outcomeUnknown" && model.outcome?.executionId == backend.appliedRequest?.executionId)
        #expect(model.outcomeReview?.draft.columns[0].name == "retained_value" && !model.canApply)
    }
}
