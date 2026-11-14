import Foundation
import Testing
@testable import DBeer

/// Basic normal-helper wire only. All persistence and decision dependencies are
/// private; no windows, presenters, appearance startup, watchers or SSH.
@Suite(.serialized) @MainActor struct MariaDBBasicIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MARIADB_PORT"] ?? "").isEmpty || ProcessInfo.processInfo.environment["DBEER_REQUIRE_MARIADB"] == "1"))
    func nativeProfileQueriesCatalogBrowseAndIndependentTransactions() async throws {
        let env = ProcessInfo.processInfo.environment
        let port = try #require(Int(env["DBEER_TEST_MARIADB_PORT"] ?? ""))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = env["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let folder = root.appendingPathComponent("build/mariadb-basic/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let suite = "DBeer.MariaDBBasic." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let settings = ConnectionSettings(host: env["DBEER_TEST_MARIADB_HOST"] ?? "localhost", port: port,
            database: env["DBEER_TEST_MARIADB_DATABASE"] ?? "dbeer", user: env["DBEER_TEST_MARIADB_USER"] ?? "dbeer",
            password: env["DBEER_TEST_MARIADB_PASSWORD"] ?? "", sslMode: env["DBEER_TEST_MARIADB_SSLMODE"] ?? "disable",
            sslRootCert: env["DBEER_TEST_MARIADB_CA_FILE"], engine: .mariadb, policy: .init(environment: .production))
        let snapshots = ResultSnapshotStore(rootURL: folder.appendingPathComponent("snapshots"))
        let plans = PlanArtifactStore(rootURL: folder.appendingPathComponent("plans"))
        let themes = EditorThemeStore(defaults: defaults, directory: folder.appendingPathComponent("themes"))
        let client = BackendClient(executableURL: executable)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
            commandShortcuts: AppShortcutStore(defaults: defaults), copySettings: ResultCopySettings(defaults: defaults), editorThemes: themes,
            appearance: AppAppearance(defaults: defaults, editorThemes: themes), sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: SQLLibrary(),
            tableBrowsePresets: TableBrowsePresetStore(fileURL: folder.appendingPathComponent("presets.json")), logicalRelationships: LogicalRelationshipStore(fileURL: folder.appendingPathComponent("relationships.json")),
            resultSnapshots: ResultSnapshotsModel(store: snapshots), planArtifacts: PlanArtifactsModel(store: plans),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in true },
            queryParameterDecision: { _, _ in nil }, explainOptionsDecision: { _ in .use(nil) }, helperFactory: { client },
            explainCollectorFactory: { id in ExplainCollector(store: PlanArtifactStore(rootURL: folder.appendingPathComponent("collector-" + id.uuidString))) })
        await workspace.start()
        let table = "g1_basic_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var owned: SQLDocument?
        do {
            try #require(await workspace.library.saveConnection(name: "MariaDB basic fixture", settings: settings))
            let profile = try #require(workspace.library.selectedConnectionId)
            let first = workspace.newDocument(profileID: profile)
            let second = workspace.newDocument(profileID: profile)
            owned = first
            await workspace.run(first, sql: "CREATE TABLE \(table)(id BIGINT PRIMARY KEY,payload VARCHAR(40),n DECIMAL(65,38),b LONGBLOB,j JSON) ENGINE=InnoDB")
            try #require(first.runtime?.queryFailure == nil && first.localError == nil)
            let exactJSON = "{ \"a\":1, \"a\":2 }"
            let decimal = "123456789012345678901234567.12345678901234567890123456789012345678"
            await workspace.run(first, sql: "INSERT INTO \(table) VALUES(1,'',\(decimal),X'00FF','\(exactJSON)'),(11,'NULL',NULL,NULL,NULL),(12,NULL,NULL,X'',NULL)")
            try #require(first.runtime?.queryFailure == nil && first.localError == nil)
            await workspace.run(first, sql: "SELECT id,payload,n,HEX(b),j FROM \(table) ORDER BY id")
            #expect(first.runtime?.result?.rows == [["1", "", decimal, "00FF", exactJSON], ["11", "NULL", nil, nil, nil], ["12", nil, nil, "", nil]])
            #expect(first.runtime?.engine == .mariadb && first.runtime?.result?.columns?.allSatisfy { $0.engine == .mariadb } == true)
            let firstSession = try #require(first.runtime?.sessionId)
            let objects = try await client.request(.catalog(sessionId: firstSession, request: .init(kind: "objects", schema: settings.database, objectKind: "table")))
            try #require(objects.type == "query.result")
            #expect(objects.rows?.contains { $0.contains { $0 == table } } == true)
            let browsed = try await client.request(.catalog(sessionId: firstSession, request: .init(kind: "browse", schema: settings.database,
                object: table, objectKind: "table", page: 0, sort: [.init(column: "id", direction: "desc")])))
            try #require(browsed.type == "query.result")
            #expect(browsed.rows?.compactMap { $0.first ?? nil } == ["12", "11", "1"])
            let native = try #require(browsed.nativeValues)
            #expect(native.count == 3 && native.allSatisfy { $0.count == 5 && $0.allSatisfy { $0.engine == "mariadb" && $0.valid } })
            #expect(native[2][2].value == decimal && native[2][4].value == exactJSON && native[0][3].kind == "binary" && native[0][3].value == "")
            await workspace.run(first, sql: "START TRANSACTION")
            await workspace.run(first, sql: "INSERT INTO \(table)(id) VALUES(2)")
            try #require(first.runtime?.queryFailure == nil && first.runtime?.transactionStatus == .transaction)
            await workspace.run(second, sql: "SELECT COUNT(*) FROM \(table) WHERE id=2")
            #expect(second.runtime?.result?.rows == [["0"]] && second.runtime?.sessionId != firstSession && second.runtime?.transactionStatus == .idle)
            await workspace.run(first, sql: "ROLLBACK")
            await workspace.run(first, sql: "SELECT COUNT(*) FROM \(table) WHERE id=2")
            #expect(first.runtime?.result?.rows == [["0"]] && first.runtime?.sessionId == firstSession)
            await workspace.run(first, sql: "DROP TABLE \(table)")
            try #require(first.runtime?.queryFailure == nil && first.localError == nil)
        } catch {
            if let owned { await workspace.run(owned, sql: "ROLLBACK"); await workspace.run(owned, sql: "DROP TABLE IF EXISTS \(table)") }
            await workspace.shutdown()
            throw error
        }
        await workspace.shutdown()
    }
}
