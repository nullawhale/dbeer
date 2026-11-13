import Foundation
import Testing
@testable import DBeer

/// Real helper and disposable stores; no windows, application activation or modal prompts.
@Suite(.serialized)
@MainActor
struct RelationshipDiscoveryIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresIncomingRowsAndERDiscoveryUseNormalNativeWorkflow() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlIncomingRowsAndERDiscoveryUseNormalNativeWorkflow() async throws { try await exercise(.mysql) }
    @Test func sqliteIncomingRowsAndERDiscoveryUseNormalNativeWorkflow() async throws { try await exercise(.sqlite) }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let env = ProcessInfo.processInfo.environment
        let executable = env["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ??
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-relations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings: ConnectionSettings
        if engine == .sqlite {
            let file = directory.appendingPathComponent("fixture.sqlite")
            _ = FileManager.default.createFile(atPath: file.path, contents: Data())
            settings = .init(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite, sqlite: .init(path: file.path))
        } else if engine == .mysql {
            settings = .init(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost", port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")),
                database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: env["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
                password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: "disable", engine: .mysql)
        } else {
            let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
            settings = .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(), automaticallyWatchFiles: false, closeDecision: { _ in .discard },
            executionDecision: { _ in true }, helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        do {
            try #require(await workspace.library.saveConnection(name: "Relationship fixture", settings: settings))
            let profile = try #require(workspace.library.selectedConnectionId)
            let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let parent = "dbeer_relation_parent_" + suffix, child = "dbeer_relation_child_" + suffix
            let schema = engine == .postgresql ? "public" : engine == .sqlite ? "main" : settings.database
            let sql = workspace.newDocument(profileID: profile)
            let numeric = engine == .sqlite ? "INTEGER" : "DECIMAL(30,10)"
            let binary = engine == .postgresql ? "bytea" : engine == .mysql ? "VARBINARY(8)" : "BLOB"
            let exact = engine == .sqlite ? "9223372036854775807" : "12345678901234567890.1234567890"
            let bytes = engine == .postgresql ? "decode('00ff','hex')" : "X'00ff'"
            let sourceTenant = engine == .sqlite ? "Tenant" : "tenant", sourceCode = engine == .sqlite ? "Code" : "code"
            await workspace.run(sql, sql: "CREATE TABLE \(parent) (\(sourceTenant) \(numeric) NOT NULL, \(sourceCode) \(binary) NOT NULL, label VARCHAR(80), PRIMARY KEY (\(sourceTenant),\(sourceCode)))")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            await workspace.run(sql, sql: "CREATE TABLE \(child) (id INTEGER PRIMARY KEY, tenant_key \(numeric), child_code \(binary), FOREIGN KEY (tenant_key,child_code) REFERENCES \(parent)(tenant,code))")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            await workspace.run(sql, sql: "INSERT INTO \(parent) VALUES (\(exact),\(bytes),'Parent')")
            await workspace.run(sql, sql: "INSERT INTO \(child) VALUES (1,\(exact),\(bytes)),(2,NULL,NULL)")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            let node = CatalogNode(profileID: profile, name: parent, kind: .object, schema: schema, object: parent, objectKind: "table")
            let document = try #require(await workspace.openData(node))
            let grid = try #require(document.grid), row = try #require(grid.rows.first)
            #expect(document.incomingRelationships == nil)
            await workspace.discoverIncomingRows(document)
            let incoming = try #require(document.incomingRelationships)
            try #require(incoming.complete && incoming.relationships.count == 1)
            let relation = try #require(incoming.relationships.first)
            #expect(relation.key.columns.map(\.target) == [sourceTenant, sourceCode])
            let count = workspace.documents.count
            await workspace.followIncomingRelationship(relation, rowID: row.id, in: document)
            let childDocument = try #require(workspace.selectedDocument)
            #expect(workspace.documents.count == count + 1 && childDocument !== document && childDocument.runtime !== document.runtime)
            #expect(childDocument.table?.name == child && childDocument.grid?.rows.count == 1)
            if engine == .sqlite {
                let restriction = try #require(childDocument.tableRelationshipScope)
                #expect(childDocument.tableFilters.isEmpty && restriction.columns.map(\.source) == ["tenant_key", "child_code"])
                #expect(restriction.columns.map(\.value) == [SQLiteValue(type: "integer", value: exact), SQLiteValue(type: "blob", value: "AP8=")])
            } else {
                #expect(childDocument.tableFilters.map(\.column) == ["tenant_key", "child_code"])
                #expect(childDocument.tableFilters.map(\.value) == [exact, "AP8="])
            }
            await workspace.followIncomingRelationship(relation, rowID: row.id, in: document, inNewTab: false)
            #expect(document.table?.name == child && document.tableBackHistory.count == 1 && document.grid?.rows.count == 1)
            await workspace.navigateTableBack(document)
            #expect(document.table?.name == parent && document.tableForwardHistory.count == 1)
            await workspace.navigateTableForward(document)
            #expect(document.table?.name == child)
            await workspace.navigateTableBack(document)
            await workspace.discoverIncomingRows(document)
            let refreshed = try #require(document.incomingRelationships), freshGrid = try #require(document.grid)
            let freshRow = try #require(freshGrid.rows.first), freshRelation = try #require(refreshed.relationships.first)
            freshGrid.set(engine == .sqlite ? SQLiteValue(type: "integer", value: "7").changeValue : .init(kind: "text", value: "7"), row: 0, column: 0)
            let beforeRejected = workspace.documents.count
            await workspace.followIncomingRelationship(freshRelation, rowID: freshRow.id, in: document)
            #expect(workspace.documents.count == beforeRejected && document.tableNavigationError?.contains("changed parent-key") == true)
            await workspace.discardGrid(document)
            var useManualAlias = engine == .sqlite
            if engine == .mysql {
                await workspace.run(sql, sql: "SELECT @@lower_case_table_names")
                useManualAlias = sql.runtime?.result?.rows == [["1"]]
            }
            let diagramNode = useManualAlias ? CatalogNode(profileID: profile, name: parent.uppercased(), kind: .object,
                schema: schema, object: parent.uppercased(), objectKind: "table") : node
            let erDocument = try #require(workspace.openERDiagram(diagramNode)), diagram = try #require(erDocument.erDiagramModel)
            let draftParent = try #require(diagram.stored.tables.first)
            diagram.move(draftParent, to: .init(x: 41, y: 73))
            #expect(diagram.visibleTableDiscovery == nil && diagram.neighbourDiscovery == nil && diagram.metadata.isEmpty)
            await workspace.discoverERVisibleTables(erDocument, schema: schema)
            let visible = try #require(diagram.visibleTableDiscovery)
            #expect(visible.tables.contains { $0.name == parent } && visible.tables.contains { $0.name == child })
            #expect(diagram.stored.tables.count == 1 && diagram.metadata.isEmpty)
            await workspace.discoverERNeighbours(erDocument)
            let neighbours = try #require(diagram.neighbourDiscovery)
            try #require(neighbours.complete && neighbours.relationships.contains { $0.source.name == child })
            #expect(neighbours.resolvedTarget?.name == parent && diagram.stored.selected?.name == parent)
            #expect(diagram.stored.placements.first { $0.table.name == parent }?.point == .init(x: 41, y: 73))
            diagram.add(try #require(neighbours.relationships.first { $0.source.name == child }).source)
            #expect(diagram.stored.tables.count == 2 && diagram.metadata.isEmpty)
            await workspace.buildERDiagram(erDocument)
            #expect(diagram.metadata.count == 2 && diagram.relationships.count == 1)
            if engine == .postgresql { try await unicodeParentEditIsRetainedAndBlocksNewTab(workspace, sql: sql, profile: profile, suffix: suffix) }
            await workspace.run(sql, sql: "DROP TABLE \(child)")
            let afterDrop = workspace.documents.count
            let storedRow = try #require(document.grid?.rows.first)
            await workspace.followIncomingRelationship(freshRelation, rowID: storedRow.id, in: document)
            #expect(workspace.documents.count == afterDrop && document.tableNavigationError != nil)
            await workspace.run(sql, sql: "DROP TABLE \(parent)")
            await workspace.shutdown()
        } catch { await workspace.shutdown(); throw error }
    }
    private func unicodeParentEditIsRetainedAndBlocksNewTab(_ workspace: ApplicationWorkspace, sql: SQLDocument, profile: UUID, suffix: String) async throws {
        let parent = "dbeer_unicode_parent_" + suffix, child = "dbeer_unicode_child_" + suffix
        let nfc = "é", nfd = "e\u{301}"
        await workspace.run(sql, sql: "CREATE TABLE \(parent)(k TEXT COLLATE \"C\" PRIMARY KEY)")
        await workspace.run(sql, sql: "CREATE TABLE \(child)(id INTEGER PRIMARY KEY,p TEXT REFERENCES \(parent)(k))")
        await workspace.run(sql, sql: "INSERT INTO \(parent) VALUES ('é')")
        await workspace.run(sql, sql: "INSERT INTO \(child) VALUES (1,'é')")
        try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
        let document = try #require(await workspace.openData(.init(profileID: profile, name: parent, kind: .object, schema: "public", object: parent, objectKind: "table"), inNewTab: true))
        await workspace.discoverIncomingRows(document)
        let relation = try #require(document.incomingRelationships?.relationships.first)
        let grid = try #require(document.grid), row = try #require(grid.rows.first)
        try #require(grid.canEdit)
        grid.set(.init(kind: "text", value: nfd), row: 0, column: 0)
        #expect(grid.pendingCount == 1 && grid.request().changes.count == 1)
        let assignment = try #require(grid.request().changes.first?.values?.first)
        #expect(Data((assignment.value.value ?? "").utf8) == Data(nfd.utf8))
        #expect(Data((row.original?.first?.value ?? "").utf8) == Data(nfc.utf8))
        let documentsBefore = workspace.documents.count
        await workspace.followIncomingRelationship(relation, rowID: row.id, in: document)
        #expect(workspace.documents.count == documentsBefore && document.tableNavigationError?.contains("changed parent-key") == true)
        #expect(grid.pendingCount == 1 && Data((grid.rows[0].values[0].value ?? "").utf8) == Data(nfd.utf8))
        await workspace.discardGrid(document)
        await workspace.run(sql, sql: "DROP TABLE \(child)")
        await workspace.run(sql, sql: "DROP TABLE \(parent)")
    }

}
