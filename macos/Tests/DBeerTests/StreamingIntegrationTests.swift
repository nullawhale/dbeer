import Foundation
import Testing
@testable import DBeer

/// These use the packaged helper, including its real pipe framing and credit
/// acknowledgements, rather than an adapter or a scripted helper substitute.
@Suite(.serialized)
struct StreamingIntegrationTests {
    private var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
    }

    @Test func loadedExportMatchesTheFullExportWireFixture() throws {
        let fixture = executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/export.json")
        let sets = [ExportResultSet(columns: [
            ResultColumn(index: 0, name: "x", nativeType: "numeric"),
            ResultColumn(index: 1, name: "x", nativeType: "bytea", encoding: "base64")
        ], rows: [["9007199254740993.123456789", "AP8="], [nil, ""]], commandTag: "SELECT 2"),
            ExportResultSet(columns: [], rows: [], commandTag: "CALL")]
        let expected = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? NSDictionary)
        let actual = try #require(JSONSerialization.jsonObject(with: ResultExport.json(sets)) as? NSDictionary)
        #expect(actual == expected)
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresHydratesBoundedResultsExportsOnceAndCancelsAtomically() async throws {
        try await exercise(.postgresql)
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlHydratesBoundedResultsExportsOnceAndCancelsAtomically() async throws {
        try await exercise(.mysql)
    }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let client = BackendClient(executableURL: executable)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-stream-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await client.start()
            let session = try #require(try await client.request(.connect(settings(engine))).sessionId)
            let bounded = try await client.request(.execute(sessionId: session, sql: numbers(engine, count: 1_107)))
            #expect(bounded.rows?.count == 1_000)
            #expect(bounded.displayedRowCount == 1_000 && bounded.rowCount == 1_107 && bounded.truncated == true)
            #expect(bounded.streamed == nil)
            #expect(bounded.resultSets?.first?.rows == bounded.rows)

            let exactSQL = engine == .postgresql
                ? "SELECT 9007199254740993.123456789::numeric AS duplicate, decode('00ff','hex') AS duplicate, NULL::text AS absent, ''::text AS empty"
                : "SELECT CAST('9007199254740993.123456789' AS DECIMAL(30,9)) AS duplicate, _binary X'00FF' AS duplicate, NULL AS absent, '' AS `empty`"
            let exact = try await client.request(.execute(sessionId: session, sql: exactSQL))
            #expect(exact.rows == [["9007199254740993.123456789", "AP8=", nil, ""]])
            #expect(exact.columns?.map(\.name) == ["duplicate", "duplicate", "absent", "empty"])
            #expect(exact.columns?[1].encoding == "base64")

            let exportSQL: String
            if engine == .postgresql {
                _ = try await client.request(.execute(sessionId: session, sql: "CREATE TEMPORARY TABLE dbeer_export_once (value integer)"))
                exportSQL = "INSERT INTO dbeer_export_once SELECT generate_series(1,1503) RETURNING value"
            } else {
                _ = try await client.request(.execute(sessionId: session, sql: "SET @dbeer_export_once = 0"))
                exportSQL = "SELECT @dbeer_export_once := @dbeer_export_once + 1 AS value FROM (\(numbers(engine, count: 1_503))) AS source_rows"
            }
            let path = directory.appendingPathComponent("all.json")
            let exported = try await client.request(.runToFile(sessionId: session, sql: exportSQL,
                export: ExportRequest(path: path.path, format: "json")))
            #expect(exported.exportPath == path.path && exported.exportRowCount == 1_503)
            let document = try JSONDecoder().decode(ExportDocument.self, from: Data(contentsOf: path))
            #expect(document.version == 1 && document.resultSets.count == 1)
            #expect(document.resultSets.first?.rows.count == 1_503)
            #expect(document.resultSets.first?.metadata.rowCount == 1_503)
            #expect(document.resultSets.first?.metadata.truncated == false)
            let counter = try await client.request(.execute(sessionId: session,
                sql: engine == .postgresql ? "SELECT count(*) FROM dbeer_export_once" : "SELECT @dbeer_export_once"))
            #expect(counter.rows == [["1503"]])

            let original = Data("existing destination".utf8)
            let preserved = directory.appendingPathComponent("preserved.json")
            try original.write(to: preserved)
            let query = UUID().uuidString
            let started = AsyncStream<Void>.makeStream()
            let slow = engine == .postgresql
                ? "SELECT n,pg_sleep(0.01) FROM generate_series(1,1503) AS n"
                : "SELECT n FROM (\(numbers(engine, count: 1_503))) AS source_rows WHERE SLEEP(0.01 + n * 0)=0"
            let execution = Task {
                try await client.request(.runToFile(sessionId: session, queryId: query, sql: slow,
                    export: ExportRequest(path: preserved.path, format: "json")), onEvent: {
                        if $0.type == "query.started" { started.continuation.yield(()) }
                    })
            }
            var events = started.stream.makeAsyncIterator()
            _ = await events.next()
            try await Task.sleep(for: .milliseconds(100))
            let stopped = try await client.request(.cancel(sessionId: session, queryId: query))
            #expect(stopped.status == "accepted")
            do {
                _ = try await execution.value
                Issue.record("Cancelled export unexpectedly succeeded")
            } catch let error as BackendRemoteError {
                #expect(error.reply.category == "cancelled")
                #expect(error.reply.outcomeUnknown == false)
            }
            started.continuation.finish()
            #expect(try Data(contentsOf: preserved) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .allSatisfy { !$0.hasPrefix(".dbeer-export-") })
            #expect(await client.shutdown().acknowledged)
        } catch {
            _ = await client.shutdown()
            throw error
        }
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlCallHydratesEveryOrderedResultSet() async throws {
        let client = BackendClient(executableURL: executable)
        let name = "dbeer_stream_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var session: String?
        do {
            try await client.start()
            let id = try #require(try await client.request(.connect(settings(.mysql))).sessionId)
            session = id
            _ = try await client.request(.execute(sessionId: id, sql: "CREATE PROCEDURE \(name)() BEGIN SELECT CAST('9007199254740993.123456789' AS DECIMAL(30,9)) AS duplicate, _binary X'00FF' AS duplicate; SELECT NULL AS absent, '' AS `empty`; END"))
            let reply = try await client.request(.execute(sessionId: id, sql: "CALL \(name)()"))
            let sets = try #require(reply.resultSets)
            let tables = sets.filter { !$0.columns.isEmpty }
            try #require(tables.count == 2)
            #expect(tables[0].rows == [["9007199254740993.123456789", "AP8="]])
            #expect(tables[0].columns.map(\.name) == ["duplicate", "duplicate"])
            #expect(tables[0].columns[1].encoding == "base64")
            #expect(tables[1].rows == [[nil, ""]])
            #expect(reply.rows == tables[0].rows && reply.columns == tables[0].columns)
            #expect(sets.last?.columns.isEmpty == true)
            _ = try await client.request(.execute(sessionId: id, sql: "DROP PROCEDURE \(name)"))
            #expect(await client.shutdown().acknowledged)
        } catch {
            if let session { _ = try? await client.request(.execute(sessionId: session, sql: "DROP PROCEDURE IF EXISTS \(name)")) }
            _ = await client.shutdown()
            throw error
        }
    }

    private func numbers(_ engine: DatabaseEngine, count: Int) -> String {
        if engine == .postgresql { return "SELECT generate_series(1,\(count)) AS n" }
        let digits = "(SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)"
        return "SELECT 1+a.d+10*b.d+100*c.d+1000*d.d AS n FROM \(digits) AS a CROSS JOIN \(digits) AS b CROSS JOIN \(digits) AS c CROSS JOIN \(digits) AS d ORDER BY n LIMIT \(count)"
    }

    private func settings(_ engine: DatabaseEngine) throws -> ConnectionSettings {
        let env = ProcessInfo.processInfo.environment
        if engine == .mysql {
            return ConnectionSettings(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
                port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")),
                database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: env["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
                password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: env["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable",
                sslRootCert: env["DBEER_TEST_MYSQL_CA_FILE"], engine: .mysql)
        }
        let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
        let options = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        return ConnectionSettings(host: try #require(url.host), port: url.port ?? 5432,
            database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "",
            sslMode: options["sslmode"] ?? "verify-full", sslRootCert: options["sslrootcert"])
    }

    private struct ExportDocument: Decodable {
        let version: Int
        let resultSets: [ExportSet]
        struct ExportSet: Decodable {
            let metadata: Metadata
            let rows: [[String?]]
        }
        struct Metadata: Decodable {
            let columns: [ResultColumn]
            let rowCount: Int64
            let truncated: Bool
        }
    }
}
