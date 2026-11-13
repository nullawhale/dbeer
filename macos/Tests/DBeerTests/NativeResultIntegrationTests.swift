import Foundation
import Testing
@testable import DBeer

/// Normal bundled helper, owned disposable tables/files, memory credentials and
/// injected approvals only. No windows, panels, application activation or file watches.
@Suite(.serialized)
@MainActor
struct NativeResultIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresNormalHelperCarriesNativeEvidenceThroughConsumers() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlNormalHelperCarriesNativeEvidenceThroughConsumers() async throws { try await exercise(.mysql) }
    @Test func sqliteNormalHelperCarriesNativeEvidenceThroughConsumers() async throws { try await exercise(.sqlite) }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = env["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let folder = root.appendingPathComponent("build/native-result-integration/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings: ConnectionSettings
        switch engine {
        case .sqlite:
            settings = .init(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite,
                sqlite: .init(path: folder.appendingPathComponent("native.sqlite").path))
            _ = FileManager.default.createFile(atPath: settings.sqlite!.path, contents: Data())
        case .mysql:
            settings = .init(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost", port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")),
                database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: env["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
                password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: "disable", engine: .mysql)
        default:
            let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
            settings = .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()),
                user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        let snapshots = ResultSnapshotsModel(store: ResultSnapshotStore(rootURL: folder.appendingPathComponent("snapshots")))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(), resultSnapshots: snapshots,
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in true },
            helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        let name = "a4_native_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let schema = engine == .postgresql ? "public" : engine == .sqlite ? "main" : settings.database
        var sql: SQLDocument?
        var created = false
        var agent: AgentAccessCoordinator?
        do {
            try #require(await workspace.library.saveConnection(name: "Native result fixture", settings: settings))
            let profileID = try #require(workspace.library.selectedConnectionId)
            let query = workspace.newDocument(profileID: profileID); sql = query
            let amount = engine == .sqlite ? "INTEGER" : "DECIMAL(30,10)"
            let binaryType = engine == .postgresql ? "BYTEA" : "BLOB"
            let temporalColumns = engine == .mysql ? ", native_date DATE, native_time TIME(6), native_datetime DATETIME(6), native_json JSON" : ""
            await workspace.run(query, sql: "CREATE TABLE \(name) (id BIGINT NOT NULL PRIMARY KEY, amount \(amount), note VARCHAR(100), empty_value VARCHAR(100), null_text VARCHAR(100), payload \(binaryType)\(temporalColumns))")
            try #require(query.runtime?.queryFailure == nil && query.localError == nil); created = true
            let numeric = engine == .sqlite ? "9223372036854775807" : "12345678901234567890.1234567890"
            let binary = engine == .postgresql ? "decode('00ff','hex')" : "X'00FF'"
            let temporalValues = engine == .mysql ? ",'2026-11-13','-25:04:05.123456','2026-11-13 10:11:12.123456','{\"integer\":9007199254740993}'" : ""
            await workspace.run(query, sql: "INSERT INTO \(name) VALUES (9007199254740993,\(numeric),NULL,'','NULL',\(binary)\(temporalValues))")
            try #require(query.runtime?.queryFailure == nil && query.localError == nil)
            let select = "SELECT * FROM \(name)"
            await workspace.run(query, sql: select)
            let reply = try #require(query.runtime?.result)
            let native = try #require(reply.nativeValues)
            let columns = try #require(reply.columns)
            #expect(native.count == 1 && native[0].count == (engine == .mysql ? 10 : 6))
            if engine == .mysql {
                #expect(native[0][6].kind == "native" && native[0][6].value == "2026-11-13")
                #expect(native[0][7].value == "-25:04:05.123456" && native[0][8].value == "2026-11-13 10:11:12.123456")
                #expect(native[0][9].kind == "native" && native[0][9].value?.contains("9007199254740993") == true)
            }
            #expect(native[0][0].kind == "integer" && native[0][0].value == "9007199254740993")
            #expect(native[0][1].value == numeric && native[0][2].kind == "null")
            #expect(native[0][3].value == "" && native[0][4].value == "NULL" && native[0][5].kind == "binary" && native[0][5].value == "AP8=")
            #expect(reply.rows?[0][2] == nil && reply.rows?[0][3] == "" && reply.rows?[0][4] == "NULL")
            let payload = try ResultCopy.selection(columns: columns, rows: reply.rows ?? [], sqliteValues: reply.sqliteValues,
                nativeValues: native, rowIndices: [0], columnIndices: Array(columns.indices))
            #expect(payload.version == 2 && payload.nativeValues == native)
            let exported = try ResultExport.json([ExportResultSet(reply)])
            #expect(try ResultExport.decodeJSON(exported)[0].nativeValues == native)
            let capture = try #require(workspace.snapshotCapture(for: query))
            let saved = try await snapshots.store.save(capture)
            let restored = try await snapshots.store.load(id: saved.id)
            #expect(restored.nativeValues == native && restored.sqliteValues == reply.sqliteValues && restored.manifest.version == 3)
            let importedFile = folder.appendingPathComponent("export.json"); try exported.write(to: importedFile)
            #expect(await snapshots.importResultJSON(importedFile).count == 1)

            let node = CatalogNode(profileID: profileID, name: name, kind: .object, schema: schema, object: name, objectKind: "table")
            let table = try #require(await workspace.openData(node, inNewTab: true))
            let grid = try #require(table.grid)
            try #require(grid.canEditRow(0) && grid.nativeValues?[0][0].value == "9007199254740993")
            #expect(grid.rows[0].original?[0].value == "9007199254740993")
            grid.set(.init(kind: "text", value: "edited"), row: 0, column: 2)
            await workspace.previewGrid(table)
            try #require(grid.error == nil)
            let preview = try #require(grid.preview)
            #expect(preview.commandTag == (engine == .postgresql ? "PREVIEW 1" : "PREVIEW"))
            if engine == .sqlite {
                #expect(preview.sql == "UPDATE main.\"\(name)\" SET \"note\"=CAST(X'656469746564' AS TEXT) WHERE \"id\" IS 9007199254740993;")
            } else {
                #expect(!preview.catalogRecords.isEmpty)
            }
            #expect(grid.request().changes[0].original?[0].value == "9007199254740993")
            try #require(await workspace.applyGrid(table))
            let refreshed = try #require(table.grid)
            #expect(refreshed.nativeValues?[0][2].value == "edited")


            let profile = try #require(workspace.library.savedConnections.first { $0.id == profileID })
            let coordinator = AgentAccessCoordinator(profiles: { [profile] }, settings: { _ in settings }, backendFactory: {
                let client = BackendClient(executableURL: executable); try await client.start(); return client
            }, approve: { _, _ in [profileID: false] }, confirm: { _ in false })
            agent = coordinator
            let clientID = UUID()
            #expect(await coordinator.handle(clientID: clientID, request: .init(id: "hello", method: "hello", clientName: "Native fixture")).ok)
            let response = await coordinator.handle(clientID: clientID, request: .init(id: "read", method: "query", profileId: profileID.uuidString, sql: select, queryId: UUID().uuidString))
            try #require(response.ok)
            let agentNative = try #require(response.results?.first?.nativeValues)
            #expect(agentNative[0][0].value == "9007199254740993" && agentNative[0][2].value == "edited" && agentNative[0][5].value == "AP8=")
            await coordinator.shutdown(); agent = nil
            await workspace.run(query, sql: "DROP TABLE \(name)"); created = false
            try #require(query.runtime?.queryFailure == nil && query.localError == nil)
        } catch {
            await agent?.shutdown()
            if created, let sql { await workspace.run(sql, sql: "DROP TABLE \(name)") }
            await workspace.shutdown()
            throw error
        }
        await workspace.shutdown()
    }
}
