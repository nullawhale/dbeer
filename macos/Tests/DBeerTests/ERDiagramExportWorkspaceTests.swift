import Foundation
import Testing
@testable import DBeer

private actor ERExportWorkspacePublicationGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func pause() async {
        guard !entered else { return }; entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

/// Production workspace factories, ownership and private file exports only.
/// No helper is started, no native window is created or activated.
@Suite(.serialized)
@MainActor
struct ERDiagramExportWorkspaceTests {
    @MainActor private final class DecisionGate {
        var hold = false
        var pending: CheckedContinuation<WorkspaceCloseDecision, Never>?
        func decide() async -> WorkspaceCloseDecision {
            guard hold else { return .discard }
            return await withCheckedContinuation { pending = $0 }
        }
        func resolve(_ decision: WorkspaceCloseDecision) { pending?.resume(returning: decision); pending = nil }
    }
    @MainActor private final class Counter { var starts = 0 }
    private struct Fixture {
        let workspace: ApplicationWorkspace
        let document: SQLDocument
        let graph: ERDiagramModel
        let profile: SavedConnection
        let other: SavedConnection
        let counter: Counter
    }
    private func fixture(_ suppliedDecision: DecisionGate? = nil) async throws -> Fixture {
        let decision = suppliedDecision ?? DecisionGate()
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "synthetic", user: "fixture", password: "", sslMode: "disable")
        let profile = SavedConnection(name: "Offline export", settings: settings), other = SavedConnection(name: "Other profile", settings: settings)
        let tables = ["first", "second"].map { ERTableID(profileID: profile.id, schema: "synthetic", name: $0) }
        let stored = StoredSQLDocument(title: "Offline diagram", text: "", kind: .erDiagram,
            erDiagram: .init(profileID: profile.id, engine: .postgresql, database: "synthetic", tables: tables,
                             placements: [.init(table: tables[0], point: .init(x: -120, y: -30), manual: true), .init(table: tables[1], point: .init(x: 440, y: 90), manual: true)],
                             selected: tables[0]))
        let counter = Counter()
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library: .init(connections: [profile, other], selectedConnectionId: profile.id)),
            credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(snapshot: .init(documents: [stored], selectedDocumentID: stored.id)),
            automaticallyWatchFiles: false, closeDecision: { _ in await decision.decide() },
            helperFactory: { counter.starts += 1; return BackendClient(executableURL: URL(fileURLWithPath: "/er-export-fixture/unused-helper")) })
        await workspace.start()
        let document = try #require(workspace.documents.first(where: { $0.id == stored.id })), graph = try #require(document.erDiagramModel)
        return Fixture(workspace: workspace, document: document, graph: graph, profile: profile, other: other, counter: counter)
    }
    private func dirtyTable(_ workspace: ApplicationWorkspace, profile: UUID) -> SQLDocument {
        let document = workspace.newDocument(profileID: profile)
        document.table = .init(schema: "synthetic", name: "dirty", kind: "table")
        let grid = GridDraft(reference: document.table!, result: .init(type: "query.result", requestId: "fixture",
            columns: [.init(index: 0, name: "id", typeOid: 23, nativeType: "int4")], rows: [["1"]]),
            metadata: [["name": "id", "nativeType": "integer", "primaryKey": "1", "editable": "true"]])
        document.attachGrid(grid); grid.set(.init(kind: "text", value: "2"), row: 0, column: 0)
        return document
    }

    @Test func disconnectedRestorationExportsCapturedSelectionAndGeometryWithoutHelperOrCredentials() async throws {
        let fixture = try await fixture(), workspace = fixture.workspace
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let invocation = try workspace.prepareERDiagramExport(fixture.document, scope: .selectedTable)
        let original = try #require(invocation.snapshot.placements.first), selected = try #require(invocation.snapshot.tables.first)
        fixture.graph.select(fixture.graph.stored.tables[1]); fixture.graph.move(selected, to: .init(x: 900, y: 900))
        let destination = root.appendingPathComponent("selected.svg")
        await workspace.exportERDiagram(fixture.document, invocation: invocation, format: .svg, options: .init(scope: .selectedTable), to: destination)
        let model = try #require(workspace.erDiagramExports[fixture.document.id]?.model)
        #expect(model.phase == .completed && fixture.counter.starts == 0 && workspace.services.isEmpty && fixture.document.runtime == nil)
        let text = String(decoding: try Data(contentsOf: destination), as: UTF8.self)
        let base64 = try #require(text.components(separatedBy: "data-format=\"base64-json-v1\">").last?.components(separatedBy: "</metadata>").first)
        let bytes = try #require(Data(base64Encoded: base64)), metadata = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let tables = try #require(metadata["tables"] as? [[String: Any]])
        #expect(tables.count == 1 && tables[0]["name"] as? String == selected.name)
        let placements = try #require(metadata["placements"] as? [[String: Any]])
        let point = try #require(placements.first?["point"] as? [String: Double])
        #expect(point["x"] == original.point.x && point["y"] == original.point.y)
        #expect(text.contains("Not loaded") || text.contains("not loaded"))
        await workspace.closeDocument(fixture.document)
        #expect(workspace.erDiagramExports.isEmpty && fixture.counter.starts == 0)
        await workspace.shutdown()
    }

    @Test(arguments: ["sourceProfile", "unrelatedTab"])
    func pendingCancelPreservesProductionExportThroughNavigationAndDecision(scope: String) async throws {
        let decision = DecisionGate(), fixture = try await fixture(decision), workspace = fixture.workspace
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let dirty = dirtyTable(workspace, profile: scope == "sourceProfile" ? fixture.profile.id : fixture.other.id)
        let gate = ERExportWorkspacePublicationGate(), destination = root.appendingPathComponent("diagram.svg")
        let exporting = Task { await workspace.exportERDiagram(fixture.document, scope: .diagram, format: .svg, options: .init(), to: destination,
            publicationHook: { item in if item.phase == .beforePublish { await gate.pause() } }) }
        try await ERExportFixtures.waitFor { await gate.entered }
        let model = try #require(workspace.erDiagramExports[fixture.document.id]?.model)
        workspace.selectDocument(dirty.id, in: workspace.activePaneID)
        decision.hold = true
        let closing = Task { () -> Bool in
            if scope == "sourceProfile" { return await workspace.disconnectProfile(fixture.profile.id) }
            await workspace.closeDocument(dirty); return !workspace.documents.contains { $0 === dirty }
        }
        try await ERExportFixtures.waitFor { decision.pending != nil }
        #expect(model.isWorking)
        await gate.release(); await exporting.value
        #expect(model.phase == .completed && FileManager.default.fileExists(atPath: destination.path) && fixture.counter.starts == 0)
        decision.resolve(.cancel)
        let closed = await closing.value
        #expect(!closed && workspace.documents.contains { $0 === dirty } && workspace.erDiagramExports[fixture.document.id]?.model === model)
        #expect(model.canStart)
        dirty.grid?.discard(); decision.hold = false
        await workspace.shutdown()
        #expect(workspace.erDiagramExports.isEmpty)
    }

    @Test(arguments: ["document", "profile", "shutdown"])
    func acceptedSourceTeardownWaitsForCleanupAndRejectsNewOwners(action: String) async throws {
        let fixture = try await fixture(), workspace = fixture.workspace
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = ERExportWorkspacePublicationGate(), destination = root.appendingPathComponent("diagram.svg")
        let exporting = Task { await workspace.exportERDiagram(fixture.document, scope: .diagram, format: .svg, options: .init(), to: destination,
            publicationHook: { item in if item.phase == .beforePublish { await gate.pause() } }) }
        try await ERExportFixtures.waitFor { await gate.entered }
        let model = try #require(workspace.erDiagramExports[fixture.document.id]?.model)
        let other = workspace.newDocument(profileID: fixture.other.id)
        await workspace.closeDocument(other)
        let irrelevantDisconnect = await workspace.disconnectProfile(fixture.other.id)
        #expect(irrelevantDisconnect && model.isWorking)
        let closing = Task {
            switch action {
            case "document": await workspace.closeDocument(fixture.document)
            case "profile": _ = await workspace.disconnectProfile(fixture.profile.id)
            default: await workspace.shutdown()
            }
        }
        try await ERExportFixtures.waitFor { model.phase == .stopping }
        #expect(!model.canStart)
        await gate.release(); await exporting.value; await closing.value
        #expect(model.phase == .closed && workspace.erDiagramExports.isEmpty && fixture.counter.starts == 0)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        if action == "shutdown" { #expect(workspace.makeERDiagramExport(fixture.document) == nil) }
        await workspace.shutdown()
    }

    @Test(arguments: ["generation", "profile"])
    func permanentSourceChangesRejectAWaitingFile(action: String) async throws {
        let fixture = try await fixture(), workspace = fixture.workspace
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = ERExportWorkspacePublicationGate(), destination = root.appendingPathComponent("diagram.svg")
        let exporting = Task { await workspace.exportERDiagram(fixture.document, scope: .diagram, format: .svg, options: .init(), to: destination,
            publicationHook: { item in if item.phase == .beforePublish { await gate.pause() } }) }
        try await ERExportFixtures.waitFor { await gate.entered }
        let model = try #require(workspace.erDiagramExports[fixture.document.id]?.model)
        if action == "generation" { fixture.graph.invalidate("Synthetic source changed") }
        else { fixture.document.profileID = fixture.other.id }
        await gate.release(); await exporting.value
        #expect(model.phase == .cancelled && !FileManager.default.fileExists(atPath: destination.path) && fixture.counter.starts == 0)
        await workspace.shutdown()
    }
}
