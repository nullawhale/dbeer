import Foundation
import Testing
@testable import DBeer

@MainActor
private final class AuthoringModelBackend {
    var commands: [BackendCommand] = []
    var capability = true
    var unknown = false
    var connections = 0
    let original = StructureTarget(schema: "public", table: "before", create: false)
    let result = StructureTarget(schema: "public", table: "after", create: false)
    func baseline(_ target: StructureTarget) -> StructureBaseline {
        .init(id: "baseline", target: target, engine: "postgresql", fingerprint: String(repeating: "a", count: 64), columns: [], limitations: [])
    }
    var plan: StructurePlan {
        .init(id: "plan", baselineId: "baseline", digest: String(repeating: "b", count: 64), target: original,
              sql: ["synthetic rename step"], risks: ["synthetic risk"], resultTarget: result)
    }
    func model() -> TableStructureEditorModel {
        .init(profile: .init(name: "Synthetic", settings: .init(host: "synthetic.invalid", port: 5432, database: "synthetic", user: "synthetic", password: "", sslMode: "disable")),
              schema: original.schema, table: original.table, create: false,
              connect: { self.connections += 1; return "session-\(self.connections)" }, send: request,
              authorize: { _, _, _ in "grant" }, bindingIsCurrent: { true }, authoringSupported: { self.capability }, changed: { _ in })
    }
    func request(_ command: BackendCommand) async throws -> BackendMessage {
        commands.append(command)
        if command.type == "disconnect" { return .init(type: "disconnect.ack", requestId: command.requestId, sessionId: command.sessionId) }
        var response = BackendMessage(type: command.type + ".result", requestId: command.requestId, sessionId: command.sessionId,
                                      queryId: command.queryId, transactionStatus: .idle, connected: true)
        switch command.type {
        case "structure.load": response.structure = .init(baseline: baseline(command.structure?.target ?? original))
        case "structure.preview": response.structure = .init(plan: plan)
        case "structure.apply":
            if unknown { throw BackendTransportError(.unexpectedEOF, outcomeUnknown: true) }
            let apply = try #require(command.structure?.apply)
            response.structure = .init(outcome: .init(executionId: apply.executionId, planId: apply.planId, state: "applied",
                                                     steps: [.init(state: "applied")], observed: baseline(result)))
        default: break
        }
        return response
    }
}

@MainActor
struct TableStructureAuthoringModelTests {
    @Test func capabilityGatesPreviewWhilePortableIntentRemainsSaveable() async {
        let backend = AuthoringModelBackend(); backend.capability = false
        let model = backend.model()
        await model.load()
        model.draft.renameTable = "after"
        #expect(model.draft.authoringVersion == 2 && !model.canPreview && model.canSaveDraft)
        backend.capability = true
        #expect(model.canPreview)
        await model.preparePreview()
        #expect(model.preview?.target == backend.original && model.preview?.resultTarget == backend.result)
        backend.capability = false
        #expect(!model.canApply)
    }
    @Test(arguments: [false, true]) func renameReconciliationPreservesOriginalHistory(unknown: Bool) async throws {
        let backend = AuthoringModelBackend(); backend.unknown = unknown
        let model = backend.model()
        await model.load()
        model.draft.renameTable = "after"
        await model.preparePreview()
        await model.apply()
        let review = try #require(model.outcomeReview)
        #expect(model.table == "before" && review.plan.target == backend.original && review.plan.resultTarget == backend.result)
        #expect(model.canReconcileRenamedTarget == unknown)
        let record = TableStructureOutcomeRecord(profileID: model.profile.id, schema: backend.original.schema, table: backend.original.table, review: review)
        #expect(record.matchesTable(schema: backend.result.schema, table: backend.result.table))
        #expect(record.review.plan.target == backend.original && record.outcome.state == review.outcome.state)
        if unknown { await model.load(useResultTarget: true) } else { await model.load() }
        #expect(model.table == "after" && model.target == backend.result && model.outcome == nil)
        #expect(model.historyReviews.last?.plan.target == backend.original)
        #expect(model.historyReviews.last?.outcome.state == (unknown ? "outcomeUnknown" : "applied"))
        #expect(backend.commands.filter { $0.type == "structure.apply" }.count == 1)
        #expect(backend.commands.last(where: { $0.type == "structure.load" })?.structure?.target == backend.result)
    }
    @Test func atomicBatchTerminalEvidenceRetainsKnownRollbackAndUnknownCommit() throws {
        for state in ["failed", "cancelled", "outcomeUnknown"] {
            let step = state == "outcomeUnknown" ? "unknown" : "rolledBack"
            let outcome = StructureOutcome(executionId: "atomic", planId: "plan", state: state, steps: [.init(state: step), .init(state: step)])
            #expect(outcome.valid)
            let reply = BackendMessage(type: "structure.apply.result", requestId: "request", sessionId: "session", queryId: "query", transactionStatus: .idle, connected: true, structure: .init(outcome: outcome))
            try reply.validate()
        }
        #expect(!StructureOutcome(executionId: "atomic", planId: "plan", state: "failed", steps: [.init(state: "rolledBack"), .init(state: "applied")]).valid)
    }
    @Test func unfinishedAuthoringFieldsRoundTripWithoutExecutionAdmission() async throws {
        let backend = AuthoringModelBackend()
        let model = backend.model()
        await model.load()
        let partials: [StructureColumn] = [
            .init(name: "generated", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"), generated: .init(storage: "stored", expression: "")),
            .init(name: "typed", type: .init(kind: "reference", reference: .init(schema: "é", name: "")), nullable: true, default: .init(kind: "none")),
            .init(name: "identity", type: .init(kind: "integer"), nullable: false, default: .init(kind: "none"), identity: .init(kind: "byDefault", start: "-"))
        ]
        for partial in partials {
            model.draft = .init(columns: [partial])
            #expect(model.canSaveDraft && !model.canPreview && !model.canApply)
            let document = model.portableDraft
            let decoded = try JSONDecoder().decode(StructureDraftDocument.self, from: Data(StructureDraftStore.text(document).utf8))
            #expect(decoded.valid && decoded.draft == document.draft && !decoded.draft.valid)
            #expect(decoded.draft.columns[0] == partial)
        }
        #expect(backend.commands.allSatisfy { $0.type == "structure.load" })
    }
    @Test func writerFourReadsLegacyAndRetainsExactAuthoredIntent() throws {
        let target = StructureTarget(schema: "public", table: "before", create: false)
        let draft = StructureDraft(columns: [], changes: [.init(name: "id", identity: .init(kind: "byDefault", start: "9007199254740993"))], renameTable: "é")
        let document = StructureDraftDocument(engine: .postgresql, target: target, draft: draft)
        let text = try StructureDraftStore.text(document)
        let decoded = try JSONDecoder().decode(StructureDraftDocument.self, from: Data(text.utf8))
        #expect(decoded.formatVersion == StructureDraftDocument.currentFormatVersion && decoded.draft.authoringVersion == 2)
        #expect(decoded.draft.renameTable?.utf8.elementsEqual("é".utf8) == true)
        #expect(decoded.draft.changes?.first?.identity?.start == "9007199254740993")
        #expect(!text.contains("authorization") && !text.contains("baselineId"))
        let legacy = "{\"formatVersion\":1,\"engine\":\"postgresql\",\"target\":{\"schema\":\"public\",\"table\":\"before\",\"create\":false},\"draft\":{\"columns\":[]}}"
        let old = try JSONDecoder().decode(StructureDraftDocument.self, from: Data(legacy.utf8))
        #expect(old.formatVersion == StructureDraftDocument.currentFormatVersion && old.draft.authoringVersion == nil)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(StructureDraftDocument.self, from: Data(text.replacingOccurrences(of: "\"formatVersion\" : 5", with: "\"formatVersion\" : 1").utf8))
        }
    }
}
