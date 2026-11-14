import Foundation
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct RelationshipDiscoveryLifecycleTests {
    @MainActor
    private final class DecisionGate {
        var pending: CheckedContinuation<WorkspaceCloseDecision, Never>?
        func choose() async -> WorkspaceCloseDecision { await withCheckedContinuation { pending = $0 } }
        func resolve(_ value: WorkspaceCloseDecision) { pending?.resume(returning: value); pending = nil }
    }
    @Test(arguments: [false, true])
    func canceledCloseIntentPreservesProductionDiscoveryBindings(sourceProfile: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-relationship-close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.sqlite")
        _ = FileManager.default.createFile(atPath: file.path, contents: Data())
        let gate = DecisionGate()
        let executable = ProcessInfo.processInfo.environment["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ??
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(), automaticallyWatchFiles: false, closeDecision: { _ in await gate.choose() }, executionDecision: { _ in true }, helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        do {
            let settings = ConnectionSettings(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite, sqlite: .init(path: file.path))
            try #require(await workspace.library.saveConnection(name: "Relationship lifecycle", settings: settings))
            let profile = try #require(workspace.library.selectedConnectionId)
            let sql = workspace.newDocument(profileID: profile)
            await workspace.run(sql, sql: "CREATE TABLE parent(id INTEGER PRIMARY KEY)")
            await workspace.run(sql, sql: "CREATE TABLE child(id INTEGER PRIMARY KEY,p INTEGER REFERENCES parent(id))")
            await workspace.run(sql, sql: "INSERT INTO parent VALUES(1)")
            let node = CatalogNode(profileID: profile, name: "parent", kind: .object, schema: "main", object: "parent", objectKind: "table")
            let table = try #require(await workspace.openData(node))
            await workspace.discoverIncomingRows(table)
            let incoming = try #require(table.incomingRelationships)
            let er = try #require(workspace.openERDiagram(node))
            await workspace.discoverERVisibleTables(er, schema: "main")
            let visible = try #require(er.erDiagramModel?.visibleTableDiscovery)
            try #require(incoming.complete && visible.complete)
            await workspace.run(sql, sql: "BEGIN")
            let closing = Task { @MainActor in
                if sourceProfile { return await workspace.disconnectProfile(profile) }
                await workspace.closeDocument(sql)
                return false
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while gate.pending == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(gate.pending != nil)
            #expect(!workspace.canStartOperation(table))
            #expect(incoming.reader.contextIsCurrent && visible.reader.contextIsCurrent)
            await incoming.discover()
            await visible.discover(schema: "main")
            #expect(incoming.complete && incoming.relationships.count == 1 && visible.complete)
            gate.resolve(.cancel)
            let closed = await closing.value
            #expect(!closed && incoming.reader.contextIsCurrent && visible.reader.contextIsCurrent)
            #expect(table.incomingRelationships === incoming && er.erDiagramModel?.visibleTableDiscovery === visible)
            await workspace.run(sql, sql: "ROLLBACK")
            if sourceProfile {
                let accepted = await workspace.disconnectProfile(profile)
                #expect(accepted && !incoming.reader.contextIsCurrent && !visible.reader.contextIsCurrent)
            }
            await workspace.shutdown()
        } catch { gate.resolve(.cancel); await workspace.shutdown(); throw error }
    }
}
