import Foundation
import Testing
@testable import DBeer

// Pure DTO and injected-model checks: no windows, app activation, panels,
// credentials, database sessions, subprocesses or network access.
@Suite @MainActor struct StructureAdvancedKindsTests {
    private struct Fixture: Decodable { var valid: [StructureBaseline]; var invalid: [String] }
    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/table-structure-advanced-kinds-v1.json")))
    }
    @Test func strictClosedObservationContract() throws {
        let f = try fixture()
        for baseline in f.valid { #expect(baseline.valid && baseline.advanced?.valid(engine: baseline.engine) == true) }
        for raw in f.invalid {
            if let baseline = try? JSONDecoder().decode(StructureBaseline.self, from: Data(raw.utf8)) { #expect(!baseline.valid) }
        }
        let plain = StructureBaseline(id: "ordinary", target: .init(schema: "app", table: "ordinary", create: false), engine: "postgresql", fingerprint: String(repeating: "a", count: 64), columns: [], limitations: [])
        #expect(plain.valid && plain.advanced == nil)
        let encoded = try JSONEncoder().encode(f.valid[0])
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["advancedEvidence"] == nil && object["authorization"] == nil && object["planId"] == nil)
    }
    @Test func unsupportedImportedIntentCannotPreviewAndLoadDoesNotGrantApply() async throws {
        let baseline = try #require(fixture().valid.first)
        var sent = 0
        let profile = SavedConnection(name: "Synthetic", settings: .init(host: "synthetic.invalid", port: 5432, database: "synthetic", user: "synthetic", password: "", sslMode: "disable"))
        let model = TableStructureEditorModel(profile: profile, schema: "app", table: "secured", create: false,
            connect: { "injected-structure-session" }, send: { command in
                sent += 1
                var response = BackendMessage(type: command.type + ".result", requestId: command.requestId, sessionId: command.sessionId, queryId: command.queryId, transactionStatus: .idle, connected: true)
                response.structure = command.type == "structure.load" ? StructureReply(baseline: baseline) : StructureReply()
                return response
            }, authorize: { _, _, _ in nil }, bindingIsCurrent: { true }, authoringSupported: { true }, reconstructionSupported: { true }, changed: { _ in })
        #expect(sent == 0 && !model.canApply && model.baseline == nil)
        await model.load()
        #expect(sent == 1 && model.baseline?.advanced != nil && !model.canApply)
        model.draft = .init(columns: [], changes: [.init(name: "id", default: .init(kind: "numeric", value: "7"))], authoringVersion: 2)
        #expect(model.canPreview && model.advancedDraftPermitted)
        model.draft = .init(columns: [], columnOrder: ["id"], reconstruct: true)
        #expect(!model.canPreview && !model.advancedDraftPermitted && !model.reconstructionAvailable)
        await model.preparePreview()
        #expect(sent == 1 && !model.canApply)
        model.draft = .init(columns: [], changes: [.init(name: "id", default: .init(kind: "expression", value: "synthetic_function()"))], authoringVersion: 2)
        #expect(!model.canPreview)
        _ = await model.close()
    }
    @Test func requiredAdvancedAppendNeedsMatchingReviewedBackfill() throws {
        let observed = try #require(fixture().valid.first?.advanced)
        let support = StructureAdvancedKindSupport(kinds: observed.kinds, scope: observed.scope, familyCount: observed.familyCount, nontransactional: observed.nontransactional,
            operations: observed.operations.map { .init(kind: $0.kind, available: true, reason: "Synthetic supported operation") }, relations: observed.relations)
        var draft = StructureDraft(columns: [.init(name: "required", type: .init(kind: "integer"), nullable: false, default: .init(kind: "none"))], allowDestructive: true, backfills: [.init(column: "required", expression: "id + 100")])
        #expect(support.permits(draft))
        draft.backfills = nil
        #expect(!support.permits(draft))
        draft.backfills = [.init(column: "other", expression: "id + 100")]
        #expect(!support.permits(draft))
        draft.backfills = [.init(column: "required", expression: "id + 100")]
        draft.columns[0].default = .init(kind: "text", value: "NULL")
        #expect(!support.permits(draft))
    }

}
