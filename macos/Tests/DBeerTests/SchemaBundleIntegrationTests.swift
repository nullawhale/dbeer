import Foundation
import Testing
@testable import DBeer

/// Real helper pipes and disposable databases only. No native windows or UI.
@Suite(.serialized)
@MainActor
struct SchemaBundleIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresCaptureKeepsDefinitionsAndEveryByteStable() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlCaptureKeepsDefinitionsAndEveryByteStable() async throws { try await exercise(.mysql) }
    @Test func sqliteCaptureKeepsDefinitionsAndEveryByteStable() async throws { try await exercise(.sqlite) }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let env = ProcessInfo.processInfo.environment
        let executable = env["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let directory = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let settings: ConnectionSettings
        if engine == .sqlite {
            let path = directory.appendingPathComponent("source.sqlite").path
            _ = FileManager.default.createFile(atPath: path, contents: Data())
            settings = .init(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite, sqlite: .init(path: path))
        } else if engine == .mysql {
            settings = .init(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost", port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")),
                database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: env["DBEER_TEST_MYSQL_USER"] ?? "dbeer", password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "",
                sslMode: "disable", engine: .mysql)
        } else {
            let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
            settings = .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()),
                user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        let seed = BackendClient(executableURL: executable)
        try await seed.start()
        let session = try #require(try await seed.request(.connect(settings)).sessionId)
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let schema = engine == .postgresql ? "bundle_" + suffix : engine == .sqlite ? "main" : settings.database
        let name = "bundle_é_" + suffix
        func quote(_ value: String) -> String { engine == .mysql ? "`" + value.replacingOccurrences(of: "`", with: "``") + "`" : "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let qualified = quote(schema) + "." + quote(name)
        let cleanup = engine == .postgresql ? "DROP SCHEMA " + quote(schema) + " CASCADE" : "DROP TABLE IF EXISTS " + qualified
        do {
            if engine == .postgresql { try await execute("CREATE SCHEMA " + quote(schema), session: session, client: seed) }
            let numeric = engine == .sqlite ? "INTEGER" : "DECIMAL(30,9)"
            let value = engine == .sqlite ? "9007199254740993" : "9007199254740993.123456789"
            let primary = engine == .sqlite ? "INTEGER PRIMARY KEY" : "BIGINT PRIMARY KEY"
            try await execute("CREATE TABLE " + qualified + " (id " + primary + ", amount " + numeric + " NOT NULL DEFAULT " + value + ", note VARCHAR(80) DEFAULT 'exact')", session: session, client: seed)
            let profile = SavedConnection(name: "Bundle fixture", settings: settings)
            var snapshots: [[String: Data]] = []
            for index in 0..<2 {
                let model = SchemaBundleModel(profile: profile, resolve: { _, _ in settings }, factory: { owner in SchemaBundleHelperBackend(owner: owner, client: BackendClient(executableURL: executable)) })
                model.schemas = [schema]
                await model.start()
                let deadline = ContinuousClock.now.advanced(by: .seconds(15))
                while model.summary == nil, model.error == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                let captureReady = model.phase == .completed && model.summary != nil
                try #require(captureReady, Comment(rawValue: model.error ?? "Real schema bundle capture failed."))
                let destination = directory.appendingPathComponent("export-\(index)")
                await model.export(to: destination)
                let exportSucceeded = model.exported
                try #require(exportSucceeded, Comment(rawValue: model.error ?? "Real schema bundle export failed."))
                let manifestData = try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
                let manifest = try SchemaBundleManifest.parse(manifestData, summary: try #require(model.summary))
                let object = try #require(manifest.objects.first { $0.ref.kind == "table" && $0.ref.name.utf8.elementsEqual(name.utf8) })
                #expect(object.state == "included")
                let ddl = try String(contentsOf: destination.appendingPathComponent(object.file.path), encoding: .utf8)
                let hasExpectedDefinition = ddl.contains("CREATE TABLE") && ddl.contains(value) && ddl.contains(name)
                #expect(hasExpectedDefinition)
                let files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
                snapshots.append(try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) }))
                await model.close()
            }
            #expect(snapshots.count == 2 && snapshots[0] == snapshots[1])
            try await execute(cleanup, session: session, client: seed)
            _ = await seed.shutdown()
        } catch {
            try? await execute(cleanup, session: session, client: seed)
            _ = await seed.shutdown()
            throw error
        }
    }
    private func execute(_ sql: String, session: String, client: BackendClient) async throws {
        var command = BackendCommand.execute(sessionId: session, sql: sql)
        let operation = OperationRequest(type: command.type, sql: sql)
        let assessment = try #require(try await client.request(.assess(sessionId: session, operations: [operation])).assessment)
        try #require(assessment.decision != "deny")
        command.authorization = try #require(assessment.authorization)
        let reply = try await client.request(command)
        try #require(reply.type != "error", "Disposable fixture setup failed.")
    }
}
