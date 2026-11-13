import Foundation
import Testing
@testable import DBeer

/// Disposable databases and memory-backed profile/credential/document stores only.
/// No native windows, modal decisions or application activation.
@Suite(.serialized)
@MainActor
struct ForeignKeyPickerIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresPickerStagesCompositeTypedKeyThroughNormalApply() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlPickerStagesCompositeTypedKeyThroughNormalApply() async throws { try await exercise(.mysql) }
    @Test func sqlitePickerStagesStorageValuesThroughNormalApply() async throws { try await exercise(.sqlite) }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let env = ProcessInfo.processInfo.environment
        let executable = env["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ??
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings: ConnectionSettings
        if engine == .sqlite {
            settings = .init(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite,
                sqlite: .init(path: directory.appendingPathComponent("fixture.sqlite").path))
            _ = FileManager.default.createFile(atPath: settings.sqlite!.path, contents: Data())
        } else if engine == .mysql {
            settings = .init(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost", port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")),
                database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: env["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
                password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: "disable", engine: .mysql)
        } else {
            let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
            settings = .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()),
                user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(), automaticallyWatchFiles: false,
            closeDecision: { _ in .discard }, executionDecision: { _ in true }, helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        do {
            try #require(await workspace.library.saveConnection(name: "Picker fixture", settings: settings))
            let profile = try #require(workspace.library.selectedConnectionId)
            let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let parent = "dbeer_picker_parent_" + suffix, child = "dbeer_picker_child_" + suffix
            let schema = engine == .postgresql ? "public" : engine == .sqlite ? "main" : settings.database
            let sql = workspace.newDocument(profileID: profile)
            let numeric = engine == .sqlite ? "INTEGER" : "DECIMAL(30,10)"
            let binary = engine == .postgresql ? "bytea" : engine == .mysql ? "VARBINARY(8)" : "BLOB"
            let chosenTenant = engine == .sqlite ? "9223372036854775807" : "12345678901234567890.1234567890"
            let firstBytes = engine == .postgresql ? "decode('01','hex')" : "X'01'"
            let chosenBytes = engine == .postgresql ? "decode('00ff','hex')" : "X'00ff'"
            await workspace.run(sql, sql: "CREATE TABLE \(parent) (tenant \(numeric), code \(binary), label VARCHAR(80), PRIMARY KEY (tenant,code))")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            let reference = engine == .sqlite ? parent : parent + "(tenant,code)"
            await workspace.run(sql, sql: "CREATE TABLE \(child) (id INTEGER PRIMARY KEY, tenant \(numeric), customer_code \(binary), FOREIGN KEY (tenant,customer_code) REFERENCES \(reference))")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            await workspace.run(sql, sql: "INSERT INTO \(parent) VALUES (1,\(firstBytes),'Initial'),(\(chosenTenant),\(chosenBytes),'Chosen Customer')")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            await workspace.run(sql, sql: "INSERT INTO \(child) VALUES (1,1,\(firstBytes))")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            let node = CatalogNode(profileID: profile, name: child, kind: .object, schema: schema, object: child, objectKind: "table")
            _ = await workspace.openData(node)
            let document = try #require(workspace.selectedDocument)
            var grid = try #require(document.grid)
            var key = try #require(document.tableForeignKeys.first), row = try #require(grid.rows.first)
            if engine != .sqlite {
                let projection = "SELECT customer_code AS tenant, id AS customer_code, tenant AS id FROM \(child)"
                await workspace.run(sql, sql: projection)
                let resultGrid = try #require(sql.grid)
                try #require(resultGrid.canEdit && resultGrid.querySource?.isEditable == true)
                let sourceRow = try #require(resultGrid.rows.first)
                let keys = try await workspace.loadForeignKeyPickerKeys(sql, grid: resultGrid, rowID: sourceRow.id)
                let picker = try workspace.makeForeignKeyPicker(sql, grid: resultGrid, rowID: sourceRow.id, key: try #require(keys.first))
                await picker.load()
                picker.search = "Chosen"
                await picker.searchRows()
                try #require(picker.error == nil && picker.rows.count == 1)
                #expect(picker.choose(try #require(picker.rows.first)))
                #expect(resultGrid.rows[0].values[0] == .init(kind: "binary", value: "AP8="))
                #expect(resultGrid.rows[0].values[1].value == "1")
                #expect(resultGrid.rows[0].values[2].value == chosenTenant)
                await workspace.previewGrid(sql)
                try #require(resultGrid.preview != nil)
                #expect(await workspace.applyGrid(sql))
                #expect(resultGrid.resultIsStale)
                await workspace.run(sql, sql: "UPDATE \(child) SET tenant=1,customer_code=\(firstBytes) WHERE id=1")
                try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
                await workspace.run(sql, sql: projection)
                let freshQueryGrid = try #require(sql.grid), freshQueryRow = try #require(freshQueryGrid.rows.first)
                let freshKeys = try await workspace.loadForeignKeyPickerKeys(sql, grid: freshQueryGrid, rowID: freshQueryRow.id)
                let staleQueryPicker = try workspace.makeForeignKeyPicker(sql, grid: freshQueryGrid,
                    rowID: freshQueryRow.id, key: try #require(freshKeys.first))
                await staleQueryPicker.load()
                let staleChoice = try #require(staleQueryPicker.rows.first)
                await workspace.run(sql, sql: "SELECT 1")
                #expect(!staleQueryPicker.choose(staleChoice))
                await workspace.run(sql, sql: "BEGIN")
                await workspace.run(sql, sql: projection)
                if let transactionGrid = sql.grid, let transactionRow = transactionGrid.rows.first {
                    do {
                        _ = try await workspace.loadForeignKeyPickerKeys(sql, grid: transactionGrid, rowID: transactionRow.id)
                        Issue.record("An active SQL transaction opened an editable source picker")
                    } catch { #expect(transactionGrid.foreignKeyPickerMetadata == nil) }
                }
                await workspace.run(sql, sql: "ROLLBACK")
                if engine == .postgresql {
                    // The independent table snapshot predates both the query Apply and reset.
                    // Restoring visible values must not bypass PostgreSQL row-version checks.
                    let originalToken = try #require(row.originalStorageToken)
                    let staleTablePicker = try workspace.makeForeignKeyPicker(document, grid: grid, rowID: row.id, key: key)
                    await staleTablePicker.load()
                    staleTablePicker.search = "Chosen"
                    await staleTablePicker.searchRows()
                    try #require(staleTablePicker.error == nil && staleTablePicker.rows.count == 1)
                    let staleTableChoice = try #require(staleTablePicker.rows.first)
                    try #require(staleTablePicker.choose(staleTableChoice))
                    let stagedValues = grid.rows[0].values
                    await workspace.previewGrid(document)
                    try #require(grid.preview != nil)
                    #expect(!(await workspace.applyGrid(document)))
                    #expect(document.grid === grid && grid.pendingCount == 1 && !grid.outcomeUnknown)
                    #expect(grid.error?.contains("changed or deleted by another client") == true)
                    #expect(grid.rows[0].values == stagedValues && grid.rows[0].original == row.original)
                    #expect(grid.rows[0].originalStorageToken == originalToken)
                    await workspace.discardGrid(document)
                    let reloaded = try #require(document.grid)
                    #expect(reloaded !== grid && reloaded.pendingCount == 0)
                    #expect(reloaded.rows.first?.originalStorageToken != originalToken)
                } else {
                    await workspace.run(document)
                }
                grid = try #require(document.grid)
                key = try #require(document.tableForeignKeys.first)
                row = try #require(grid.rows.first)
            }
            let model = try workspace.makeForeignKeyPicker(document, grid: grid, rowID: row.id, key: key)
            await model.load()
            try #require(model.error == nil)
            model.search = "Chosen"
            await model.searchRows()
            try #require(model.error == nil && model.rows.count == 1)
            #expect(model.choose(try #require(model.rows.first)))
            #expect(grid.pendingCount == 1 && grid.rows[0].original == row.original)
            await workspace.run(sql, sql: "SELECT label FROM \(parent) p JOIN \(child) c ON p.tenant=c.tenant AND p.code=c.customer_code")
            #expect(sql.runtime?.result?.rows == [["Initial"]])
            await workspace.previewGrid(document)
            try #require(grid.preview != nil)
            #expect(await workspace.applyGrid(document))
            await workspace.run(sql, sql: "SELECT label FROM \(parent) p JOIN \(child) c ON p.tenant=c.tenant AND p.code=c.customer_code")
            #expect(sql.runtime?.result?.rows == [["Chosen Customer"]])
            // A picker belongs to its exact original grid/row snapshot.
            let refreshed = try #require(document.grid), refreshedRow = try #require(refreshed.rows.first)
            let stale = try workspace.makeForeignKeyPicker(document, grid: refreshed, rowID: refreshedRow.id, key: try #require(document.tableForeignKeys.first))
            await stale.load()
            refreshed.set(.null, row: 0, column: 1)
            #expect(!stale.choose(try #require(stale.rows.first)))
            await workspace.discardGrid(document)
            if engine == .sqlite {
                let anyParent = "dbeer_picker_any_parent_" + suffix, anyChild = "dbeer_picker_any_child_" + suffix
                await workspace.run(sql, sql: "CREATE TABLE \(anyParent) (k ANY PRIMARY KEY)")
                try #require(sql.runtime?.queryFailure == nil)
                await workspace.run(sql, sql: "CREATE TABLE \(anyChild) (id INTEGER PRIMARY KEY,k ANY REFERENCES \(anyParent))")
                try #require(sql.runtime?.queryFailure == nil)
                await workspace.run(sql, sql: "INSERT INTO \(anyParent) VALUES (X'00ff'),('AP8=')")
                await workspace.run(sql, sql: "INSERT INTO \(anyChild) VALUES (1,'AP8=')")
                _ = await workspace.openData(.init(profileID: profile, name: anyChild, kind: .object,
                    schema: "main", object: anyChild, objectKind: "table"))
                let anyDocument = try #require(workspace.selectedDocument), anyGrid = try #require(anyDocument.grid)
                let anyKey = try #require(anyDocument.tableForeignKeys.first)
                let anyPicker = try workspace.makeForeignKeyPicker(anyDocument, grid: anyGrid,
                    rowID: try #require(anyGrid.rows.first).id, key: anyKey)
                await anyPicker.load()
                anyPicker.search = "AP8="
                anyPicker.sqliteSearchType = "blob"
                await anyPicker.searchRows()
                try #require(anyPicker.error == nil && anyPicker.rows.count == 1)
                #expect(anyPicker.rows[0].values[0].sqliteValue?.type == "blob")
                anyPicker.sqliteSearchType = "text"
                await anyPicker.searchRows()
                try #require(anyPicker.error == nil && anyPicker.rows.count == 1)
                #expect(anyPicker.rows[0].values[0].sqliteValue?.type == "text")
                anyPicker.sqliteSearchType = "blob"
                await anyPicker.searchRows()
                #expect(anyPicker.choose(try #require(anyPicker.rows.first)))
                #expect(anyGrid.pendingCount == 1)
                await workspace.previewGrid(anyDocument)
                try #require(anyGrid.preview != nil)
                #expect(await workspace.applyGrid(anyDocument))
                await workspace.run(sql, sql: "SELECT typeof(k) FROM \(anyChild)")
                #expect(sql.runtime?.result?.rows == [["blob"]])
                await workspace.run(sql, sql: "DROP TABLE \(anyChild)")
                await workspace.run(sql, sql: "DROP TABLE \(anyParent)")
            }
            await workspace.run(sql, sql: "DROP TABLE \(child)")
            await workspace.run(sql, sql: "DROP TABLE \(parent)")
            await workspace.shutdown()
        } catch {
            await workspace.shutdown()
            throw error
        }
    }
}
