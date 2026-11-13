import Foundation
import Testing
@testable import DBeer

/// Local stores and guarded exports only; no helper, credentials or windows.
@Suite(.serialized)
@MainActor
struct ERDiagramMultiProfileWorkspaceTests {
    private struct Fixture {
        let workspace: ApplicationWorkspace
        let document: SQLDocument
        let graph: ERDiagramModel
        let a: SavedConnection
        let b: SavedConnection
        let left: ERTableID
        let right: ERTableID
    }
    private func fixture(external: Bool, starts: C3HelperCounter, decision: C3DecisionGate? = nil) async throws -> Fixture {
        let settings = ConnectionSettings(host: "synthetic.invalid", port: 5432, database: "synthetic", user: "fixture", password: "", sslMode: "disable")
        let a = SavedConnection(name: "Owner A", settings: settings), b = SavedConnection(name: "Owner B", settings: settings)
        let left = ERTableID(profileID: a.id, schema: "same", name: "table"), right = ERTableID(profileID: b.id, schema: "same", name: "table")
        let stored = StoredERDiagram(profileID: a.id, engine: a.engine, database: a.database,
            sources: external ? [.init(a)] : [.init(a), .init(b)], tables: external ? [left] : [left, right],
            placements: [.init(table: left, point: .init(x: 0, y: 0), manual: true)] + (external ? [] : [.init(table: right, point: .init(x: 450, y: 0), manual: true)]), selected: left)
        let saved = StoredSQLDocument(title: "Multi-profile", text: "", kind: .erDiagram, erDiagram: stored)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library: .init(connections: [a, b], selectedConnectionId: a.id)),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(snapshot: .init(documents: [saved])),
            automaticallyWatchFiles: false, closeDecision: { _ in await decision?.decide() ?? .discard },
            helperFactory: { starts.count += 1; return BackendClient(executableURL: URL(fileURLWithPath: "/synthetic/unused-helper")) })
        await workspace.start()
        let document = try #require(workspace.documents.first { $0.id == saved.id }), graph = try #require(document.erDiagramModel)
        if external {
            graph.localRelationships = {
                [.init(source: left, key: .init(name: "Local external", target: right.reference, columns: [.init(source: "id", target: "id", position: 1)]),
                    logicalID: UUID(uuidString: "b4c2fe36-5b75-4187-a5c9-22e8025c785b"), targetProfileID: b.id,
                    targetProfileName: b.name, sourceProfileName: a.name, validationNotice: "Saved mapping; metadata not loaded.")]
            }
        }
        return .init(workspace: workspace, document: document, graph: graph, a: a, b: b, left: left, right: right)
    }
    @Test(arguments: [false, true])
    func acceptedTeardownRetiresOnlyCapturedOwnersIncludingExternalLinks(external: Bool) async throws {
        let starts = C3HelperCounter(), f = try await fixture(external: external, starts: starts)
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = C3PublicationGate(), destination = root.appendingPathComponent("selected.svg")
        let exporting = Task { await f.workspace.exportERDiagram(f.document, scope: .selectedTable, format: .svg,
            options: .init(scope: .selectedTable), to: destination,
            publicationHook: { event in if event.phase == .beforePublish { await gate.pause() } }) }
        try await ERExportFixtures.waitFor { await gate.entered }
        let model = try #require(f.workspace.erDiagramExports[f.document.id]?.model)
        #expect(f.workspace.erDiagramExports[f.document.id]?.sourceProfileIDs.contains(f.b.id) == external)
        let closing = Task { await f.workspace.disconnectProfile(f.b.id) }
        if external {
            try await ERExportFixtures.waitFor { model.phase == .stopping }
            #expect(!model.canStart)
            await gate.release(); await exporting.value
            #expect(await closing.value)
            #expect(model.phase == .closed && !FileManager.default.fileExists(atPath: destination.path))
        } else {
            #expect(await closing.value)
            #expect(model.isWorking)
            await gate.release(); await exporting.value
            #expect(model.phase == .completed && FileManager.default.fileExists(atPath: destination.path))
        }
        #expect(starts.count == 0 && f.workspace.services.isEmpty)
        await f.workspace.shutdown()
    }
    @Test(arguments: [false, true])
    func rejectedSecondInvocationCannotReplaceRunningExportOwners(disconnectCaptured: Bool) async throws {
        let starts = C3HelperCounter(), f = try await fixture(external: false, starts: starts)
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = C3PublicationGate(), firstFile = root.appendingPathComponent("first.svg")
        let first = try f.workspace.prepareERDiagramExport(f.document, scope: .selectedTable)
        let exporting = Task { await f.workspace.exportERDiagram(f.document, invocation: first, format: .svg,
            options: .init(scope: .selectedTable), to: firstFile,
            publicationHook: { event in if event.phase == .beforePublish { await gate.pause() } }) }
        try await ERExportFixtures.waitFor { await gate.entered }
        let model = try #require(f.workspace.erDiagramExports[f.document.id]?.model)
        f.graph.select(f.right)
        let second = try f.workspace.prepareERDiagramExport(f.document, scope: .selectedTable)
        let afterPrepare = f.workspace.erDiagramExports[f.document.id]?.sourceProfileIDs
        let afterPrepareBindings = f.workspace.erDiagramExports[f.document.id]?.sourceBindings
        #expect(afterPrepare == [f.a.id] && afterPrepareBindings == first.sourceBindings)
        let secondFile = root.appendingPathComponent("second.svg")
        await f.workspace.exportERDiagram(f.document, invocation: second, format: .svg,
            options: .init(scope: .selectedTable), to: secondFile)
        let afterRejected = f.workspace.erDiagramExports[f.document.id]?.sourceProfileIDs
        let afterRejectedBindings = f.workspace.erDiagramExports[f.document.id]?.sourceBindings
        #expect(afterRejected == [f.a.id] && afterRejectedBindings == first.sourceBindings)
        #expect(model.isWorking && !FileManager.default.fileExists(atPath: secondFile.path))
        var finished = false
        let closing = Task {
            let result = await f.workspace.disconnectProfile(disconnectCaptured ? f.a.id : f.b.id)
            finished = true
            return result
        }
        if disconnectCaptured {
            try await ERExportFixtures.waitFor { model.phase == .stopping }
            #expect(!finished)
        } else {
            #expect(await closing.value)
            #expect(model.isWorking)
        }
        await gate.release(); await exporting.value
        if disconnectCaptured { #expect(await closing.value) }
        #expect(FileManager.default.fileExists(atPath: firstFile.path) == !disconnectCaptured)
        #expect(starts.count == 0)
        await f.workspace.shutdown()
    }

    private func dirtyTable(_ workspace: ApplicationWorkspace, profileID: UUID) -> SQLDocument {
        let document = workspace.newDocument(profileID: profileID)
        document.table = .init(schema: "synthetic", name: "dirty", kind: "table")
        let grid = GridDraft(reference: document.table!, result: .init(type: "query.result", requestId: "synthetic",
            columns: [.init(index: 0, name: "id", typeOid: 23, nativeType: "int4")], rows: [["1"]]),
            metadata: [["name": "id", "nativeType": "integer", "primaryKey": "1", "editable": "true"]])
        document.attachGrid(grid); grid.set(.init(kind: "text", value: "2"), row: 0, column: 0)
        return document
    }
    @Test(arguments: [false, true])
    func pendingAndDeclinedSecondaryDecisionPreservesCapturedAndUnrelatedExports(external: Bool) async throws {
        let starts = C3HelperCounter(), decision = C3DecisionGate()
        let f = try await fixture(external: external, starts: starts, decision: decision)
        let dirty = dirtyTable(f.workspace, profileID: f.b.id)
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = C3PublicationGate(), destination = root.appendingPathComponent("pending.svg")
        let exporting = Task { await f.workspace.exportERDiagram(f.document, scope: .selectedTable, format: .svg,
            options: .init(scope: .selectedTable), to: destination,
            publicationHook: { event in if event.phase == .beforePublish { await gate.pause() } }) }
        try await ERExportFixtures.waitFor { await gate.entered }
        let model = try #require(f.workspace.erDiagramExports[f.document.id]?.model)
        decision.hold = true
        let closing = Task { await f.workspace.disconnectProfile(f.b.id) }
        try await ERExportFixtures.waitFor { decision.pending != nil }
        #expect(model.isWorking)
        await gate.release(); await exporting.value
        #expect(model.phase == .completed && FileManager.default.fileExists(atPath: destination.path))
        decision.resolve(.cancel)
        #expect(!(await closing.value) && model.canStart && dirty.grid?.pendingCount == 1)
        decision.hold = false; dirty.grid?.discard()
        #expect(starts.count == 0)
        await f.workspace.shutdown()
    }
    @Test(arguments: [false, true])
    func preparedInvocationRechecksPendingCapturedOwnerBeforeStarting(external: Bool) async throws {
        let starts = C3HelperCounter(), decision = C3DecisionGate()
        let f = try await fixture(external: external, starts: starts, decision: decision)
        let invocation = try f.workspace.prepareERDiagramExport(f.document, scope: .selectedTable)
        let dirty = dirtyTable(f.workspace, profileID: f.b.id)
        decision.hold = true
        let closing = Task { await f.workspace.disconnectProfile(f.b.id) }
        try await ERExportFixtures.waitFor { decision.pending != nil }
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("prepared-pending.svg")
        await f.workspace.exportERDiagram(f.document, invocation: invocation, format: .svg,
            options: .init(scope: .selectedTable), to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path) == !external)
        decision.resolve(.cancel)
        #expect(!(await closing.value))
        if external {
            await f.workspace.exportERDiagram(f.document, invocation: invocation, format: .svg,
                options: .init(scope: .selectedTable), to: destination)
            #expect(FileManager.default.fileExists(atPath: destination.path))
        }
        #expect(starts.count == 0 && dirty.grid?.pendingCount == 1)
        decision.hold = false; dirty.grid?.discard(); await f.workspace.shutdown()
    }

    @Test func removedPrimaryAnchorCannotGateRemainingSourceDuringADeclinedDisconnect() async throws {
        let starts = C3HelperCounter(), decision = C3DecisionGate()
        let f = try await fixture(external: false, starts: starts, decision: decision)
        f.workspace.removeERDiagramSource(f.document, profileID: f.a.id, expectedFingerprint: LogicalRelationshipEndpoint.fingerprint(f.a))
        #expect(!f.graph.ownsSource(f.a.id) && f.graph.activeSourceID == f.b.id && f.graph.stored.isValid)
        f.graph.select(f.right)
        let dirty = dirtyTable(f.workspace, profileID: f.a.id)
        decision.hold = true
        let closing = Task { await f.workspace.disconnectProfile(f.a.id) }
        try await ERExportFixtures.waitFor { decision.pending != nil }
        let remainingSourceCanStart = f.workspace.canStartOperation(f.document)
        #expect(remainingSourceCanStart)
        #expect(f.workspace.canStartERSource(f.b.id) && !f.workspace.canStartERSource(f.a.id))
        #expect(!f.workspace.canStartTableStructure(f.b.id))
        let invocation = try f.workspace.prepareERDiagramExport(f.document, scope: .selectedTable)
        #expect(Set(invocation.sourceBindings.keys) == [f.b.id] && invocation.snapshot.profileName == f.b.name)
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("remaining.svg")
        await f.workspace.exportERDiagram(f.document, invocation: invocation, format: .svg, options: .init(scope: .selectedTable), to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        decision.resolve(.cancel); #expect(!(await closing.value))
        #expect(starts.count == 0 && f.graph.source(f.a.id) == nil)
        decision.hold = false; dirty.grid?.discard(); await f.workspace.shutdown()
    }
    @Test(arguments: ["label", "host"])
    func externalOwnerChangesUseIdentityAndFenceNewExports(change: String) async throws {
        let starts = C3HelperCounter(), f = try await fixture(external: true, starts: starts)
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = C3PublicationGate(), destination = root.appendingPathComponent("changed-owner.svg")
        let exporting = Task { await f.workspace.exportERDiagram(f.document, scope: .selectedTable, format: .svg,
            options: .init(scope: .selectedTable), to: destination,
            publicationHook: { event in if event.phase == .beforePublish { await gate.pause() } }) }
        try await ERExportFixtures.waitFor { await gate.entered }
        let model = try #require(f.workspace.erDiagramExports[f.document.id]?.model)
        var settings = f.b.settings(password: "")
        if change == "host" { settings.host = "changed.synthetic.invalid" }
        try #require(await f.workspace.library.saveConnection(name: change == "label" ? "Renamed external owner" : f.b.name, settings: settings, id: f.b.id))
        if change == "host" {
            #expect(!model.canStart)
            try await ERExportFixtures.waitFor { model.phase == .stopping }
            await gate.release(); await exporting.value
            try await ERExportFixtures.waitFor { f.workspace.erDiagramExports[f.document.id] == nil }
            #expect(model.phase == .closed && !FileManager.default.fileExists(atPath: destination.path))
        } else {
            #expect(model.isWorking)
            await gate.release(); await exporting.value
            #expect(model.phase == .completed && FileManager.default.fileExists(atPath: destination.path))
        }
        #expect(starts.count == 0)
        await f.workspace.shutdown()
    }
    @Test func invocationPreparedBeforeAcceptedSecondaryTeardownCannotRestartAfterThePanel() async throws {
        let starts = C3HelperCounter(), f = try await fixture(external: false, starts: starts)
        f.graph.select(f.right)
        let invocation = try f.workspace.prepareERDiagramExport(f.document, scope: .selectedTable)
        #expect(await f.workspace.disconnectProfile(f.b.id))
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("old-choice.svg")
        await f.workspace.exportERDiagram(f.document, invocation: invocation, format: .svg, options: .init(scope: .selectedTable), to: destination)
        #expect(!FileManager.default.fileExists(atPath: destination.path) && starts.count == 0)
        await f.workspace.shutdown()
    }
    @Test func legacyBindingNeedsExplicitFreshReviewBeforeAnyConnection() async throws {
        let starts = C3HelperCounter(), f = try await fixture(external: false, starts: starts)
        f.graph.stored.sources = []; f.graph.stored.tables = [f.left]; f.graph.stored.placements = []
        await f.workspace.buildERDiagram(f.document, connect: true)
        #expect(starts.count == 0 && f.graph.source(f.a.id) == nil && f.graph.metadata.isEmpty)
        f.workspace.confirmERDiagramSource(f.document, profileID: f.a.id, expectedFingerprint: String(repeating: "0", count: 64))
        #expect(f.graph.source(f.a.id) == nil && starts.count == 0)
        f.workspace.confirmERDiagramSource(f.document, profileID: f.a.id, expectedFingerprint: LogicalRelationshipEndpoint.fingerprint(f.a))
        #expect(f.graph.source(f.a.id)?.matches(f.a) == true && starts.count == 0 && f.workspace.services.isEmpty)
        await f.workspace.shutdown()
    }
}

@MainActor
private final class C3HelperCounter { var count = 0 }
private actor C3PublicationGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func pause() async {
        guard !entered else { return }; entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor
private final class C3DecisionGate {
    var hold = false
    var pending: CheckedContinuation<WorkspaceCloseDecision, Never>?
    func decide() async -> WorkspaceCloseDecision {
        guard hold else { return .discard }
        return await withCheckedContinuation { pending = $0 }
    }
    func resolve(_ decision: WorkspaceCloseDecision) { pending?.resume(returning: decision); pending = nil }
}
