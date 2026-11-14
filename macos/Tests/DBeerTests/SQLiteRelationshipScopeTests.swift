import Foundation
import Testing
@testable import DBeer

@MainActor
struct SQLiteRelationshipScopeTests {
    @Test func rebindingRetainsScopeAndUnloadedRemovalDoesNotConnectOrRead() async throws {
        let scope = SQLiteRelationshipScope(child: .init(schema: "main", name: "child"), parent: .init(schema: "main", name: "parent"), name: "fk_0",
            columns: [.init(source: "p", target: "id", position: 1, value: .init(type: "integer", value: "1"))])
        let filter = CatalogFilter(column: "label", operator: "eq", value: "keep")
        let stored = StoredSQLDocument(title: "Child", text: "Table data", profileID: UUID(), kind: .table,
            table: StoredTableDocument(reference: .init(schema: "main", name: "child", kind: "table"), filterExpression: .conjunction([filter]), relationshipScope: scope))
        let document = SQLDocument(restoring: stored)
        var helperCreations = 0
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
            automaticallyWatchFiles: false, helperFactory: { helperCreations += 1; return BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/false")) })
        await workspace.library.loadConnections()
        try #require(await workspace.library.saveConnection(name: "Other engine", settings: .init(host: "localhost", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable")))
        document.profileID = try #require(workspace.library.selectedConnectionId)
        workspace.addDocument(document)
        #expect(document.tableRelationshipScope == scope && document.tableFilters == [filter] && document.grid == nil)
        await workspace.run(document)
        #expect(document.localError?.contains("requires SQLite") == true && helperCreations == 0 && document.runtime == nil)
        #expect(document.removeUnloadedRelationshipScope())
        #expect(document.tableRelationshipScope == nil && document.tableFilters == [filter] && document.runtime == nil && document.grid == nil && helperCreations == 0)
        #expect(document.storedState.table?.relationshipScope == nil && document.tableNeedsExplicitLoad)
        #expect(!document.removeUnloadedRelationshipScope())
        await workspace.shutdown()
    }

    @Test func strictSharedScopesAndVersionedRestorationPreserveTheRestriction() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let raw = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/sqlite-relationship-scope-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        for item in try #require(fixture["valid"] as? [[String: Any]]) {
            let command = try JSONDecoder().decode(BackendCommand.self, from: JSONSerialization.data(withJSONObject: item))
            #expect(command.catalog?.relationshipScope?.isValid == true)
            let again = try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command))
            #expect(again == command)
        }
        for item in try #require(fixture["invalid"] as? [String]) {
            var rejected = false
            do { _ = try JSONDecoder().decode(BackendCommand.self, from: Data(item.utf8)) } catch { rejected = true }
            #expect(rejected)
        }
        let first = try #require((fixture["valid"] as? [[String: Any]])?.first)
        let command = try JSONDecoder().decode(BackendCommand.self, from: JSONSerialization.data(withJSONObject: first))
        let scope = try #require(command.catalog?.relationshipScope)
        let profile = UUID()
        let table = TableReference(schema: scope.child.schema, name: scope.child.name, kind: "table")
        let stored = StoredSQLDocument(id: UUID(), title: table.name, text: "Table data", profileID: profile, kind: .table,
            table: StoredTableDocument(reference: table, filterExpression: nil, relationshipScope: scope))
        let bytes = try JSONEncoder().encode(SQLWorkspaceSnapshot(documents: [stored]))
        let snapshot = try JSONDecoder().decode(SQLWorkspaceSnapshot.self, from: bytes)
        let document = SQLDocument(restoring: try #require(snapshot.documents.first))
        #expect(snapshot.version == SQLWorkspaceSnapshot.currentVersion && document.tableRelationshipScope == scope && document.runtime == nil && document.grid == nil)
        var old = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        old["version"] = 12
        let oldBytes = try JSONSerialization.data(withJSONObject: old)
        #expect(throws: SQLDocumentStoreError.self) { try JSONDecoder().decode(SQLWorkspaceSnapshot.self, from: oldBytes) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-relation-presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("views.json")
        let presets = TableBrowsePresetStore(fileURL: file)
        await presets.load()
        _ = try await presets.saveNew(name: "Related", profileID: profile, table: table, configuration: .init(relationshipScope: scope))
        var saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(saved["version"] as? Int == TableBrowsePresetFormat.currentVersion)
        let reopened = TableBrowsePresetStore(fileURL: file)
        await reopened.load()
        #expect(reopened.presets.first?.configuration.relationshipScope == scope)
        saved["version"] = 1
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        let oldPresets = TableBrowsePresetStore(fileURL: file)
        await oldPresets.load()
        #expect(oldPresets.error != nil && oldPresets.presets.isEmpty)
    }
}

/// Runs normal incoming discovery, navigation, history and Apply View without windows.
@Suite(.serialized)
@MainActor
struct SQLiteIncomingComparisonIntegrationTests {
    @Test func parentComparisonSemanticsSurviveNativeNavigationHistoryPersistenceAndRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-relationship-semantics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.sqlite")
        _ = FileManager.default.createFile(atPath: file.path, contents: Data())
        let executable = ProcessInfo.processInfo.environment["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ??
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(), automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in true }, helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        do {
            let settings = ConnectionSettings(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite, sqlite: .init(path: file.path))
            try #require(await workspace.library.saveConnection(name: "Relationship semantics", settings: settings))
            let profile = try #require(workspace.library.selectedConnectionId)
            let sql = workspace.newDocument(profileID: profile)
            for statement in [
                "CREATE TABLE integer_parent(k INTEGER PRIMARY KEY)",
                "CREATE TABLE text_child(id INTEGER PRIMARY KEY,v TEXT REFERENCES integer_parent(k))",
                "INSERT INTO integer_parent VALUES(1)", "INSERT INTO text_child VALUES(1,'001'),(2,NULL)",
                "CREATE TABLE nocase_parent(k TEXT COLLATE NOCASE PRIMARY KEY NOT NULL)",
                "CREATE TABLE binary_child(id INTEGER PRIMARY KEY,v TEXT REFERENCES nocase_parent(k))",
                "INSERT INTO nocase_parent VALUES('ABC')", "INSERT INTO binary_child VALUES(1,'abc'),(2,NULL)",
                "CREATE TABLE text_parent(k TEXT PRIMARY KEY NOT NULL)",
                "CREATE TABLE integer_child(id INTEGER PRIMARY KEY,v INTEGER REFERENCES text_parent(k))",
                "INSERT INTO text_parent VALUES('01')", "PRAGMA foreign_keys=OFF", "INSERT INTO integer_child VALUES(1,1)", "PRAGMA foreign_keys=ON"
            ] {
                await workspace.run(sql, sql: statement)
                try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            }
            var savedRestricted: StoredSQLDocument?
            for (parent, child, count) in [("integer_parent", "text_child", 1), ("nocase_parent", "binary_child", 1), ("text_parent", "integer_child", 0)] {
                let document = try #require(await workspace.openData(.init(profileID: profile, name: parent, kind: .object, schema: "main", object: parent, objectKind: "table"), inNewTab: true))
                await workspace.discoverIncomingRows(document)
                let relation = try #require(document.incomingRelationships?.relationships.first)
                let row = try #require(document.grid?.rows.first)
                await workspace.followIncomingRelationship(relation, rowID: row.id, in: document, inNewTab: false)
                #expect(document.table?.name == child && document.grid?.rows.count == count && document.tableFilters.isEmpty)
                let scope = try #require(document.tableRelationshipScope)
                if parent == "integer_parent" { savedRestricted = document.storedState }
                let restored = SQLDocument(restoring: document.storedState)
                #expect(restored.tableRelationshipScope == scope && restored.runtime == nil)
                await workspace.navigateTableBack(document)
                #expect(document.table?.name == parent && document.tableRelationshipScope == nil)
                await workspace.navigateTableForward(document)
                #expect(document.tableRelationshipScope == scope && document.grid?.rows.count == count)
                var configuration = document.browseDraftConfiguration
                configuration.relationshipScope = nil
                document.browseDraftConfiguration = configuration
                let applying = try #require(TableBrowseNavigation.apply(document: document, workspace: workspace))
                await applying.value
                #expect(document.tableRelationshipScope == nil && document.grid?.rows.count == (child == "integer_child" ? 1 : 2))
            }
            await workspace.run(sql, sql: "DROP TABLE text_child")
            await workspace.run(sql, sql: "CREATE TABLE text_child(id INTEGER PRIMARY KEY,v TEXT)")
            let failed = SQLDocument(restoring: try #require(savedRestricted))
            workspace.addDocument(failed)
            await workspace.run(failed)
            try #require(failed.grid == nil && failed.tableRelationshipScope != nil)
            let runtime = try #require(failed.runtime), previousRead = runtime.queryStartedAt, previousSession = runtime.sessionId
            #expect(failed.removeUnloadedRelationshipScope())
            #expect(failed.runtime === runtime && runtime.queryStartedAt == previousRead && runtime.sessionId == previousSession && failed.grid == nil)
            await workspace.run(failed)
            #expect(failed.tableRelationshipScope == nil && failed.grid != nil && failed.runtime?.queryFailure == nil)
            await workspace.shutdown()
        } catch { await workspace.shutdown(); throw error }
    }
}
