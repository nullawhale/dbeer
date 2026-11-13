import Foundation
import Testing
@testable import DBeer

/// Explicit normal workspace/profile/editor flows against disposable databases.
/// No windows, activation, UI automation or private connection stores are used.
@Suite(.serialized)
@MainActor
struct ERDiagramMultiProfileIntegrationTests {
    @Test func twoSQLiteFilesRetainIndependentObjectsAndRestoreDisconnected() async throws {
        try await exercise(firstEngine: .sqlite, secondEngine: .sqlite)
    }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty && !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func postgresAndMySQLRetainTheirOwnMetadataAndSourceSessions() async throws {
        try await exercise(firstEngine: .postgresql, secondEngine: .mysql)
    }

    private func exercise(firstEngine: DatabaseEngine, secondEngine: DatabaseEngine) async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-multi-er-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = environment["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        func settings(_ engine: DatabaseEngine, suffix: String) throws -> ConnectionSettings {
            if engine == .sqlite {
                let path = root.appendingPathComponent(suffix + ".sqlite")
                _ = FileManager.default.createFile(atPath: path.path, contents: Data())
                return .init(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite, sqlite: .init(path: path.path))
            }
            if engine == .mysql {
                return .init(host: environment["DBEER_TEST_MYSQL_HOST"] ?? "localhost", port: try #require(Int(environment["DBEER_TEST_MYSQL_PORT"] ?? "")),
                    database: environment["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: environment["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
                    password: environment["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: "disable", engine: .mysql)
            }
            let url = try #require(URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""))
            return .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        func schema(_ engine: DatabaseEngine) -> String {
            engine == .sqlite ? "main" : engine == .postgresql ? "public" : (environment["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer")
        }
        let connections = MemoryConnectionLibraryStore(), credentials = MemoryConnectionCredentialStore(), documents = MemorySQLDocumentStore()
        let links = root.appendingPathComponent("links/library.json")
        let workspace = ApplicationWorkspace(connectionStore: connections, credentialStore: credentials, documentStore: documents,
            logicalRelationships: LogicalRelationshipStore(fileURL: links), automaticallyWatchFiles: false,
            closeDecision: { _ in .discard }, executionDecision: { _ in true }, helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let parentName = "er_parent_" + suffix, childName = "er_child_" + suffix, keyName = "fk_er_" + suffix
        var setup: [SQLDocument] = []
        var restoredWorkspace: ApplicationWorkspace?
        do {
            try #require(await workspace.library.saveConnection(name: "ER first owner", settings: try settings(firstEngine, suffix: "first")))
            let first = try #require(workspace.library.savedConnections.last)
            try #require(await workspace.library.saveConnection(name: "ER second owner", settings: try settings(secondEngine, suffix: "second")))
            let second = try #require(workspace.library.savedConnections.last)
            for (profile, marker) in [(first, "first_only"), (second, "second_only")] {
                let sql = workspace.newDocument(profileID: profile.id); setup.append(sql)
                for statement in ["CREATE TABLE \(parentName)(id integer primary key, \(marker) text)",
                    "CREATE TABLE \(childName)(id integer primary key, parent_id integer, CONSTRAINT \(keyName) FOREIGN KEY(parent_id) REFERENCES \(parentName)(id))"] {
                    await workspace.run(sql, sql: statement)
                    try #require(sql.localError == nil && sql.runtime?.queryFailure == nil)
                }
            }
            let left = ERTableID(profileID: first.id, schema: schema(first.engine), name: parentName)
            let right = ERTableID(profileID: second.id, schema: schema(second.engine), name: parentName)
            let leftChild = ERTableID(profileID: first.id, schema: schema(first.engine), name: childName)
            let rightChild = ERTableID(profileID: second.id, schema: schema(second.engine), name: childName)
            let document = try #require(workspace.openERDiagram(.init(profileID: first.id, name: parentName, kind: .object, schema: left.schema, object: parentName, objectKind: "table")))
            let graph = try #require(document.erDiagramModel)
            workspace.confirmERDiagramSource(document, profileID: second.id)
            graph.add(right); graph.add(leftChild); graph.add(rightChild)
            graph.move(left, to: .init(x: 70, y: -60)); graph.move(right, to: .init(x: 510, y: 110))
            await workspace.buildERDiagram(document, profileID: first.id, connect: true)
            await workspace.buildERDiagram(document, profileID: second.id, connect: true)
            try #require(graph.metadata.count == 4 && graph.metadata.values.allSatisfy { $0.columnState.isAvailable && $0.relationshipState.isAvailable })
            #expect(graph.metadata[left]?.columns.contains { $0.name == "first_only" } == true)
            #expect(graph.metadata[right]?.columns.contains { $0.name == "second_only" } == true)
            #expect(graph.sourceState(first.id).context?.engine == first.engine && graph.sourceState(second.id).context?.engine == second.engine)
            #expect(workspace.services[first.id]?.sessionId != workspace.services[second.id]?.sessionId)
            let declared = graph.relationships.filter { $0.kind == .declared }
            #expect(declared.count == 2 && declared.allSatisfy { $0.source.profileID == $0.target.profileID })
            workspace.editLogicalRelationship(sourceProfileID: first.id, reference: left.reference)
            let editor = try #require(workspace.logicalRelationshipEditor)
            editor.name = "Cross-profile diagram link"; editor.targetProfileID = second.id
            editor.targetSchema = right.schema; editor.targetName = right.name; editor.columns = [.init(source: "id", target: "id")]
            await editor.validate()
            let validationError = editor.error, canConfirm = editor.canConfirm
            #expect(validationError == nil)
            try #require(canConfirm)
            await editor.confirm(in: workspace.logicalRelationships); try #require(editor.saved)
            workspace.closeLogicalRelationshipEditor()
            let local = try #require(graph.relationships.first { $0.kind == .logical })
            #expect(local.source == left && local.target == right && local.validationNotice == nil)
            graph.select(right)
            await workspace.openERTable(document, table: right, newTab: true)
            let opened = try #require(workspace.documents.last { $0.table?.name == parentName && $0.profileID == second.id })
            #expect(opened.grid?.columns.contains { $0.name == "second_only" } == true)
            await workspace.closeDocument(opened)
            let originalPoint = try #require(graph.stored.placements.first { $0.table == right }?.point)
            let replacement = ERTableID(profileID: first.id, schema: leftChild.schema, name: childName)
            #expect(throws: ERDiagramFailure.self) { try graph.rebind(right, to: replacement, profile: first) }
            let stale = ERTableID(profileID: second.id, schema: right.schema, name: parentName + "_missing")
            workspace.rebindERDiagramTable(document, original: right, replacement: stale)
            #expect(graph.metadata[right] == nil && graph.metadata[stale] == nil && graph.stored.placements.first { $0.table == stale }?.point == originalPoint)
            #expect(workspace.logicalRelationships.relationship(id: local.logicalID!)?.target.tableID == right)
            workspace.rebindERDiagramTable(document, original: stale, replacement: right)
            await workspace.buildERDiagram(document, profileID: second.id)
            try #require(graph.metadata[right]?.columnState.isAvailable == true)
            let firstFacts = graph.metadata[left]
            try #require(await workspace.disconnectProfile(second.id))
            #expect(graph.metadata[left]?.columnState == firstFacts?.columnState && graph.sourceState(first.id).context != nil)
            #expect(graph.metadata[right]?.columnState.isAvailable == false)
            try #require(graph.relationships.first { $0.kind == .logical }?.validationNotice != nil)
            workspace.removeERDiagramSource(document, profileID: first.id, expectedFingerprint: LogicalRelationshipEndpoint.fingerprint(first))
            #expect(!graph.ownsSource(first.id) && graph.source(first.id) == nil && graph.stored.tables.count == 2)
            await workspace.buildERDiagram(document, profileID: second.id, connect: true)
            try #require(graph.metadata[right]?.columnState.isAvailable == true && graph.sourceState(second.id).context != nil)
            graph.select(rightChild)
            for sql in workspace.documents.filter({ !$0.isERDiagram }).reversed() {
                await workspace.closeDocument(sql)
            }
            setup = []
            let diagramOnly = workspace.documents.allSatisfy(\.isERDiagram)
            try #require(diagramOnly)
            await workspace.flushDocuments(); await workspace.shutdown()
            var helperStarts = 0
            let restored = ApplicationWorkspace(connectionStore: connections, credentialStore: credentials, documentStore: documents,
                logicalRelationships: LogicalRelationshipStore(fileURL: links), automaticallyWatchFiles: false,
                closeDecision: { _ in .discard }, executionDecision: { _ in true },
                helperFactory: { helperStarts += 1; return BackendClient(executableURL: executable) })
            restoredWorkspace = restored
            await restored.start()
            let reopened = try #require(restored.documents.first { $0.id == document.id }?.erDiagramModel)
            #expect(reopened.stored.sources.count == 1 && reopened.stored.tables.count == 2 && reopened.activeSourceID == second.id && !reopened.ownsSource(first.id) && reopened.metadata.isEmpty && reopened.sourceStates.isEmpty)
            let restoredServiceCount = restored.services.count
            let restoredRuntimeCount = restored.documents.filter { $0.runtime != nil }.count
            #expect(helperStarts == 0)
            #expect(restoredServiceCount == 0)
            #expect(restoredRuntimeCount == 0)
            #expect(reopened.stored.placements.first { $0.table == right }?.point == originalPoint)
            await restored.buildERDiagram(try #require(restored.documents.first { $0.id == document.id }), profileID: second.id, connect: true)
            #expect(restored.services[first.id] == nil && helperStarts == 1 && reopened.sourceState(second.id).context != nil && reopened.metadata[right]?.columnState.isAvailable == true)
            for profile in [first, second] {
                let cleanup = restored.newDocument(profileID: profile.id)
                await restored.run(cleanup, sql: "DROP TABLE IF EXISTS \(childName)")
                await restored.run(cleanup, sql: "DROP TABLE IF EXISTS \(parentName)")
                await restored.closeDocument(cleanup)
            }
            await restored.shutdown()
        } catch {
            for sql in setup.reversed() {
                await workspace.run(sql, sql: "DROP TABLE IF EXISTS \(childName)")
                await workspace.run(sql, sql: "DROP TABLE IF EXISTS \(parentName)")
            }
            await restoredWorkspace?.shutdown(); await workspace.shutdown(); throw error
        }
    }
}
