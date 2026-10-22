import Foundation
import Testing
@testable import DBeer

// Real helper/database coverage using model objects only. Confirmations are
// injected; no application activation, windows, file panels, or desktop input.
@Suite(.serialized)
@MainActor
struct SQLHistoryIntegrationTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private var executable: URL { repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core") }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresTerminalHistoryPersistsCompleteMetadataWithoutResultValues() async throws {
        try await exercise(.postgresql)
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlTerminalHistoryPersistsCompleteMetadataWithoutResultValues() async throws {
        try await exercise(.mysql)
    }

    private func settings(_ engine: DatabaseEngine) throws -> ConnectionSettings {
        let env = ProcessInfo.processInfo.environment
        if engine == .mysql {
            return ConnectionSettings(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
                port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")),
                database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: env["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
                password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: env["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable",
                sslRootCert: env["DBEER_TEST_MYSQL_CA_FILE"], engine: .mysql,
                policy: ExecutionPolicy(environment: .production))
        }
        let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
        let options = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        return ConnectionSettings(host: try #require(url.host), port: url.port ?? 5432,
            database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "",
            sslMode: options["sslmode"] ?? "disable", sslRootCert: options["sslrootcert"],
            policy: ExecutionPolicy(environment: .production))
    }

    private func numbers(_ engine: DatabaseEngine) -> String {
        if engine == .postgresql { return "SELECT generate_series(1,1107) AS n" }
        let digits = "(SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)"
        return "SELECT 1+a.d+10*b.d+100*c.d+1000*d.d AS n FROM \(digits) AS a CROSS JOIN \(digits) AS b CROSS JOIN \(digits) AS c CROSS JOIN \(digits) AS d ORDER BY n LIMIT 1107"
    }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let directory = repository.appendingPathComponent("build/history-integration/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionStore = MemoryConnectionLibraryStore()
        let credentialStore = MemoryConnectionCredentialStore()
        let fileURL = directory.appendingPathComponent("workspace.json")
        let store = FileSQLDocumentStore(fileURL: fileURL)
        func workspace() -> ApplicationWorkspace {
            ApplicationWorkspace(connectionStore: connectionStore, credentialStore: credentialStore, documentStore: store,
                closeDecision: { _ in .rollback }, executionDecision: { _ in true },
                helperFactory: { BackendClient(executableURL: executable) })
        }
        let original = workspace()
        var restored: ApplicationWorkspace?
        do {
            let settings = try settings(engine)
            await original.start()
            try #require(await original.library.saveConnection(name: "Original history fixture", settings: settings))
            let profileID = try #require(original.library.selectedConnectionId)
            let document = original.newDocument(profileID: profileID)
            // Temporary tables belong exclusively to this document session and
            // disappear on shutdown, including when an assertion throws.
            let table = "dbeer_history_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let sentinel = "history-result-and-error-sentinel"
            original.historyEnabled = false
            await original.run(document, sql: "CREATE TEMPORARY TABLE \(table) (id integer PRIMARY KEY, label varchar(80) UNIQUE)")
            try #require(document.runtime?.queryFailure == nil && document.runtime?.result != nil)
            await original.run(document, sql: "INSERT INTO \(table) VALUES (1,'\(sentinel)')")
            try #require(document.runtime?.queryFailure == nil)
            if engine == .mysql {
                // MySQL cannot reopen a temporary table as both INSERT target
                // and SELECT source. A session variable retains the fixture
                // value without copying it into the statement being recorded.
                await original.run(document, sql: "SET @dbeer_history_value = (SELECT label FROM \(table) WHERE id=1)")
                try #require(document.runtime?.queryFailure == nil)
            }
            #expect(original.history.isEmpty)
            original.historyEnabled = true

            let startedBefore = Date.now
            await original.run(document, sql: numbers(engine))
            let selected = try #require(original.history.last)
            #expect(selected.outcome == .succeeded && selected.sqlCompleted == true)
            #expect(selected.loadedRowCount == 1_000 && selected.affectedRowCount == nil)
            #expect(selected.truncated == true && selected.countsArePartial == false)
            #expect(try #require(selected.startedAt) >= startedBefore)
            #expect(try #require(selected.finishedAt) >= selected.startedAt!)
            #expect(try #require(selected.durationMs) >= 0)

            await original.run(document, sql: "INSERT INTO \(table) VALUES (2,'second'),(3,'third')")
            #expect(original.history.last?.affectedRowCount == 2 && original.history.last?.loadedRowCount == 0)
            await original.run(document, sql: "UPDATE \(table) SET id=id+10 WHERE id>=2")
            #expect(original.history.last?.affectedRowCount == 2 && original.history.last?.loadedRowCount == 0)

            let failingSQL = engine == .postgresql ? "SELECT CAST(label AS integer) FROM \(table) WHERE id=1"
                : "INSERT INTO \(table) VALUES (100,@dbeer_history_value)"
            document.text = "SELECT label FROM \(table) WHERE id=1; \(failingSQL); SELECT 99;"
            await original.runScript(document)
            try #require(original.history.count == 5)
            #expect(original.history.map(\.outcome) == [.succeeded, .succeeded, .succeeded, .succeeded, .failed])
            #expect(document.executions.map(\.status) == ["Completed", "Query failed", "Skipped"])
            #expect(original.history[3].loadedRowCount == 1 && original.history[3].affectedRowCount == nil)
            let failed = try #require(original.history.last)
            #expect(failed.sqlState == (engine == .postgresql ? "22P02" : "23000"))
            #expect(failed.errorMessage?.isEmpty == false && failed.errorMessage?.contains(sentinel) == false)
            // The server's conversion/duplicate-key message echoes a row's value,
            // while the failing SQL itself contains no copy of that value.
            #expect(document.runtime?.queryFailure?.message.contains(sentinel) == true)
            #expect(!failed.sql.contains(sentinel))
            #expect(!String(decoding: try JSONEncoder().encode(original.history), as: UTF8.self).contains(sentinel))

            // Supply an exact destination directly to the runtime, bypassing
            // the application's NSSavePanel while retaining the real SQL path.
            let runtime = try #require(document.runtime)
            let sessionID = try #require(runtime.sessionId)
            let client = try await original.ensureHelper()
            let export = ExportRequest(path: directory.appendingPathComponent("full.json").path, format: "json")
            let exportSQL = numbers(engine)
            let assessment = try #require(try await client.request(.assess(sessionId: sessionID,
                operations: [OperationRequest(type: "execute", sql: exportSQL, export: export)])).assessment)
            try #require(assessment.decision != "deny")
            let completion = try #require(await runtime.run(sql: exportSQL, export: export,
                authorization: try #require(assessment.authorization)))
            let profile = try #require(original.library.savedConnections.first { $0.id == profileID })
            let exported = try #require(SQLHistoryEntry(documentID: document.id, profileID: profileID,
                profile: SQLHistoryProfile(profile), sql: exportSQL, completion: completion))
            #expect(exported.outcome == .succeeded && exported.sqlCompleted == true)
            #expect(exported.exportedRowCount == 1_107)
            #expect(exported.loadedRowCount == 1_000 && exported.truncated == true)
            #expect(exported.affectedRowCount == nil)
            #expect(FileManager.default.fileExists(atPath: export.path))
            #expect(original.history.count == 5) // Direct runtime calls do not record duplicate workspace history.

            try #require(await original.library.saveConnection(name: "Renamed after execution", settings: settings, id: profileID))
            #expect(original.history.allSatisfy { $0.profile?.name == "Original history fixture" })
            await original.flushDocuments()
            let saved = try await store.load()
            #expect(saved.history.map(\.id) == original.history.map(\.id))
            #expect(saved.history.map(\.outcome) == original.history.map(\.outcome))
            #expect(saved.history.map(\.loadedRowCount) == original.history.map(\.loadedRowCount))
            #expect(saved.history.map(\.affectedRowCount) == original.history.map(\.affectedRowCount))
            #expect(saved.history.map(\.profile) == original.history.map(\.profile))
            #expect(!String(decoding: try Data(contentsOf: fileURL), as: UTF8.self).contains(sentinel))
            await original.shutdown()

            let reopened = workspace()
            restored = reopened
            await reopened.start()
            #expect(reopened.history == saved.history)
            #expect(reopened.documents.allSatisfy { $0.runtime == nil })
            #expect(reopened.services.isEmpty)
            #expect(reopened.library.savedConnections.first?.name == "Renamed after execution")
            await reopened.shutdown()
        } catch {
            await original.shutdown()
            await restored?.shutdown()
            throw error
        }
    }
}
