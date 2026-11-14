import Foundation
import Testing
@testable import DBeer

// Pure models and injected metadata providers; no windows or application activation.
@MainActor
struct ERDiagramSourceTests {
    private func profile(_ name: String, engine: DatabaseEngine = .postgresql) -> SavedConnection {
        .init(name: name, settings: .init(host: "synthetic.invalid", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable", engine: engine))
    }
    private func fixture() -> (ERDiagramModel, SavedConnection, SavedConnection, ERTableID, ERTableID) {
        let a = profile("A"), b = profile("B", engine: .mysql)
        let left = ERTableID(profileID: a.id, schema: "same", name: "é")
        let right = ERTableID(profileID: b.id, schema: "same", name: "é")
        return (.init(stored: .init(profileID: a.id, engine: a.engine, database: a.database,
            sources: [.init(a), .init(b)], tables: [left, right])), a, b, left, right)
    }
    private func context(_ profile: SavedConnection) -> ERDiagramLoadContext {
        .init(profileID: profile.id, sessionID: profile.id.uuidString, serviceGeneration: UUID(),
              settingsRevision: ERDiagramSource(profile).revision!, engine: profile.engine, database: profile.database)
    }
    private func facts(_ table: ERTableID) -> ERTableMetadata {
        .init(table: table, columns: [.init(name: "id", nativeType: "integer", nullable: false, primaryKeyPosition: 1)], columnState: .available, relationshipState: .available)
    }
    @Test func persistedBindingsKeepOwnersAndRestoreOnlyPresentation() throws {
        let (model, a, _, left, right) = fixture()
        model.setMetadata(facts(left)); model.sourceStates[a.id, default: .init()].context = context(a)
        let document = StoredSQLDocument(title: "Two profiles", text: "", kind: .erDiagram, erDiagram: model.stored)
        let data = try JSONEncoder().encode(SQLWorkspaceSnapshot(documents: [document]))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("synthetic.invalid") && !text.contains("sessionID") && !text.contains("nativeType"))
        let decoded = try JSONDecoder().decode(SQLWorkspaceSnapshot.self, from: data)
        let restored = ERDiagramModel(stored: try #require(decoded.documents.first?.erDiagram))
        #expect(restored.stored.isValid && Set(restored.stored.tables) == Set([left, right]))
        #expect(restored.metadata.isEmpty && restored.sourceStates.isEmpty && restored.context == nil)
        var oldShape = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        oldShape["version"] = 14
        let disguised = try JSONSerialization.data(withJSONObject: oldShape)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SQLWorkspaceSnapshot.self, from: disguised) }
    }
    @Test func sourceInvalidationDoesNotEraseAnotherOwnersFactsOrAttempt() {
        let (model, a, b, left, right) = fixture()
        model.beginLoad(profileID: a.id); model.sourceStates[a.id, default: .init()].context = context(a)
        model.setMetadata(facts(left))
        let generation = model.sourceState(a.id).generation
        model.beginLoad(profileID: b.id); model.setMetadata(facts(right))
        model.invalidateSource(b.id, reason: "Synthetic B failure")
        #expect(model.sourceState(a.id).generation == generation && model.sourceState(a.id).loading)
        #expect(model.metadata[left]?.columnState.isAvailable == true)
        #expect(model.metadata[right]?.columnState == .stale("Synthetic B failure"))
        model.finishLoad(a.id, generation: generation)
        #expect(!model.isLoading)
    }
    @Test func explicitRebindPreservesGeometryClearsFactsAndRejectsMerging() throws {
        let (model, a, _, left, right) = fixture()
        model.move(right, to: .init(x: 37, y: -91)); model.select(right); model.setMetadata(facts(right))
        #expect(throws: ERDiagramFailure.self) { try model.rebind(right, to: left, profile: a) }
        let replacement = ERTableID(profileID: a.id, schema: "same", name: "e\u{301}")
        try model.rebind(right, to: replacement, profile: a)
        #expect(model.stored.isValid && model.stored.tables.contains(left) && model.stored.tables.contains(replacement))
        #expect(model.stored.placements.first { $0.table == replacement }?.point == .init(x: 37, y: -91))
        #expect(model.metadata[right] == nil && model.metadata[replacement] == nil && model.stored.selected == replacement)
    }
    @Test func labelsDoNotChangeBindingButChangedEndpointsRequireExplicitRebind() {
        let original = profile("Original")
        let binding = ERDiagramSource(original)
        var renamed = original; renamed.name = "Renamed"
        #expect(binding.matches(renamed) && binding.revision == ERDiagramSource(renamed).revision)
        renamed.host = "different.synthetic.invalid"
        #expect(!binding.matches(renamed))
        let model = ERDiagramModel(stored: .init(profileID: original.id, engine: original.engine, database: original.database, sources: [binding]))
        #expect(!model.bindSource(renamed) && model.source(original.id)?.fingerprint == binding.fingerprint)
    }
    @Test func pausedSourceCannotPublishAfterInvalidationWhileOtherSourceCompletes() async {
        let (model, a, b, left, right) = fixture()
        let gate = SourceGate()
        let task = Task { await ERDiagramLoader.load(model, context: context(a), isCurrent: { true }) { request in
            if request.kind == "columns" { await gate.wait() }
            return response(request.kind)
        } }
        while !gate.waiting { await Task.yield() }
        await ERDiagramLoader.load(model, context: context(b), isCurrent: { true }) { response($0.kind) }
        model.invalidateSource(a.id, reason: "Synthetic source retired")
        gate.resume(); await task.value
        #expect(model.metadata[left]?.columnState == .stale("Synthetic source retired"))
        #expect(model.metadata[right]?.columnState.isAvailable == true && model.sourceState(b.id).context?.profileID == b.id)
        #expect(!model.isLoading)
    }
    @Test(arguments: [false, true])
    func oneLegacyRebindCannotConfirmAnotherLegacyObject(changeEngine: Bool) throws {
        let original = profile("Legacy")
        let first = ERTableID(profileID: original.id, schema: "public", name: "first")
        let second = ERTableID(profileID: original.id, schema: "public", name: "second")
        let model = ERDiagramModel(stored: .init(profileID: original.id, engine: original.engine,
            database: original.database, tables: [first, second]))
        let before = model.stored
        var current = original
        current.host = "changed.synthetic.invalid"
        if changeEngine { current.engine = .mysql }
        #expect(throws: ERDiagramFailure.self) { try model.rebind(first, to: first, profile: current) }
        #expect(model.stored == before && model.source(original.id) == nil)
        let destination = profile("Explicit destination", engine: .mysql)
        let replacement = ERTableID(profileID: destination.id, schema: "target", name: "first")
        try model.rebind(first, to: replacement, profile: destination)
        #expect(model.stored.isValid && model.stored.tables.contains(second))
        #expect(model.source(original.id) == nil && model.source(destination.id)?.matches(destination) == true)
    }

    @Test func wholeLegacySourceReviewCanConfirmItsRemainingObjects() throws {
        let original = profile("Legacy")
        let tables = ["first", "second"].map { ERTableID(profileID: original.id, schema: "public", name: $0) }
        let model = ERDiagramModel(stored: .init(profileID: original.id, engine: original.engine,
            database: original.database, tables: tables))
        var current = original; current.host = "reviewed.synthetic.invalid"
        #expect(model.bindSource(current))
        try model.rebind(tables[0], to: tables[0], profile: current)
        #expect(model.source(original.id)?.matches(current) == true && model.stored.tables == tables)
    }

    @Test func sourceLimitCountsLegacyOwnersAndExcludesUnusedAnchors() throws {
        let anchor = profile("Legacy anchor")
        let table = ERTableID(profileID: anchor.id, schema: "public", name: "table")
        let legacy = StoredERDiagram(profileID: anchor.id, engine: anchor.engine, database: anchor.database, tables: [table])
        let model = ERDiagramModel(stored: legacy)
        let added = (0..<15).map { profile("Source \($0)") }
        for source in added { #expect(model.bindSource(source)) }
        #expect(model.stored.isValid && model.stored.sourceProfileIDs.count == 16)
        let overflow = profile("Overflow")
        #expect(!model.bindSource(overflow))
        var forged = model.stored; forged.sources.append(.init(overflow))
        #expect(!forged.isValid)
        #expect(model.bindSource(anchor) && model.stored.sources.count == 16)
        model.removeSource(anchor.id)
        #expect(model.bindSource(overflow) && model.stored.isValid && model.stored.sourceProfileIDs.count == 16)
        #expect(!model.stored.sourceProfileIDs.contains(anchor.id))

        let rebound = ERDiagramModel(stored: legacy)
        for source in added { #expect(rebound.bindSource(source)) }
        let replacement = ERTableID(profileID: overflow.id, schema: "public", name: "table")
        try rebound.rebind(table, to: replacement, profile: overflow)
        #expect(rebound.stored.isValid && rebound.stored.sourceProfileIDs.count == 16)
        #expect(!rebound.stored.sourceProfileIDs.contains(anchor.id))
    }

    private func response(_ kind: String) -> BackendMessage {
        let names = kind == "columns" ? ["name", "nativeType", "nullable", "primaryKey"] : ["name", "targetSchema", "targetTable", "sourceColumn", "targetColumn", "position"]
        return .init(type: "query.result", requestId: "synthetic", columns: names.enumerated().map { .init(index: $0.offset, name: $0.element) },
            rows: kind == "columns" ? [["id", "integer", "false", "1"]] : [], rowCount: kind == "columns" ? 1 : 0)
    }
}

@MainActor
private final class SourceGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; waiting = true } }
    func resume() { continuation?.resume(); continuation = nil }
}
