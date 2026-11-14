import Foundation
import Testing
@testable import DBeer

/// Isolated database fixtures with the normal workspace-owned readonly sampler.
/// No windows, native sheets, application activation or production profiles.
@Suite(.serialized)
@MainActor
struct GridProfileIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresFreshSamplePreservesDecimalAndIndependentTransaction() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlFreshSamplePreservesDecimalAndIndependentTransaction() async throws { try await exercise(.mysql) }
    @Test func sqliteFreshSamplePreservesStorageAndIndependentTransaction() async throws { try await exercise(.sqlite) }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let env = ProcessInfo.processInfo.environment
        let executable = env["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ??
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/profiling-fixtures/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings: ConnectionSettings
        if engine == .sqlite {
            let path = directory.appendingPathComponent("fixture.sqlite").path
            _ = FileManager.default.createFile(atPath: path, contents: Data())
            settings = .init(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite, sqlite: .init(path: path))
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
            try #require(await workspace.library.saveConnection(name: "Profile fixture", settings: settings))
            let profileID = try #require(workspace.library.selectedConnectionId)
            let sql = workspace.newDocument(profileID: profileID)
            let name = "dbeer_profile_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let numeric = engine == .sqlite ? "INTEGER" : "DECIMAL(65,30)"
            let number = engine == .sqlite ? "9223372036854775807" : "9007199254740993.000000000000000001"
            await workspace.run(sql, sql: "CREATE TABLE \(name) (id INTEGER PRIMARY KEY,n \(numeric),label TEXT)")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            await workspace.run(sql, sql: "INSERT INTO \(name) VALUES (1,\(number),NULL),(2,1,'NULL'),(3,NULL,'')")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            let schema = engine == .postgresql ? "public" : engine == .sqlite ? "main" : settings.database
            _ = await workspace.openData(.init(profileID: profileID, name: name, kind: .object, schema: schema, object: name, objectKind: "table"))
            let document = try #require(workspace.selectedDocument), grid = try #require(document.grid)
            let column = try #require(grid.columns.first { $0.name == "n" })
            let model = try workspace.makeGridProfileServer(document: document, grid: grid, column: column)
            #expect(model.report == nil && !model.isBusy)
            await workspace.run(sql, sql: "BEGIN")
            try #require(sql.runtime?.transactionStatus == .transaction)
            let originalSession = try #require(sql.runtime?.sessionId)
            await workspace.run(sql, sql: "UPDATE \(name) SET n=7 WHERE id=1")
            try #require(sql.runtime?.queryFailure == nil)
            await model.capture()
            let report = try #require(model.report)
            #expect(model.notice == nil && report.rowCount == 3 && report.columns[0].nullCount == 1 && !report.scope.partial)
            #expect(report.columns[0].sum == (engine == .sqlite ? "9223372036854775808" : "9007199254740994.000000000000000001"))
            #expect(report.scope.notice.contains("independently from SQL-tab transactions"))
            #expect(sql.runtime?.sessionId == originalSession && sql.runtime?.transactionStatus == .transaction)
            model.rowLimit = 2
            await model.capture()
            #expect(model.report?.rowCount == 2 && model.report?.scope.partial == true && model.report?.scope.title.contains("First 2 rows") == true)
            await model.close()
            await workspace.run(sql, sql: "ROLLBACK")
            let textColumn = try #require(grid.columns.first { $0.name == "label" })
            let textProfile = try workspace.makeGridProfileServer(document: document, grid: grid, column: textColumn)
            await textProfile.capture()
            let observed = try #require(textProfile.report?.columns.first)
            #expect(observed.distinctCount == 3 && observed.nullCount == 1 && observed.sum == nil)
            #expect(observed.frequencies.contains { $0.label == "SQL NULL" })
            #expect(observed.frequencies.contains { $0.label == "Empty string" })
            await textProfile.close()
            // A staged draft cannot mix original typed values with edited display strings.
            if !grid.rows.isEmpty, let ordinal = grid.columns.firstIndex(where: { $0.name == "n" }) {
                grid.set(.init(kind: engine == .sqlite ? "sqliteInteger" : "text", value: "5"), row: 0, column: ordinal)
                #expect(throws: (any Error).self) { try workspace.makeGridProfileServer(document: document, grid: grid, column: column) }
            }
            await workspace.run(sql, sql: "DROP TABLE \(name)")
            try #require(sql.runtime?.queryFailure == nil)
            await workspace.shutdown()
        } catch { await workspace.shutdown(); throw error }
    }
}
