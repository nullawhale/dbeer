import Foundation
import Testing
@testable import DBeer

/// Real adapters execute each parsed routine as one server statement. These
/// fixtures use temporary PostgreSQL routines or uniquely named MySQL routines.
struct SQLRoutineParserIntegrationTests {
    private var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresDollarQuotedAndAtomicFunctionsExecuteThroughTheParser() async throws {
        let components = try #require(URLComponents(string: ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? ""))
        let parameters = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last })
        let settings = ConnectionSettings(host: try #require(components.host), port: components.port ?? 5432,
            database: String(components.path.dropFirst()), user: try #require(components.user), password: components.password ?? "",
            sslMode: parameters["sslmode"] ?? "verify-full", sslRootCert: parameters["sslrootcert"])
        let sql = """
        CREATE FUNCTION pg_temp.dbeer_parser_quoted() RETURNS text LANGUAGE plpgsql AS $body$
        BEGIN
          RETURN 'one;two';
        END;
        $body$;
        SELECT pg_temp.dbeer_parser_quoted();
        CREATE FUNCTION pg_temp.dbeer_parser_atomic() RETURNS integer LANGUAGE SQL
        BEGIN ATOMIC
          SELECT CASE WHEN true THEN 1 ELSE 2 END;
          SELECT 3;
        END;
        SELECT pg_temp.dbeer_parser_atomic();
        """
        let parsed = SQLScriptParser.parse(sql, engine: .postgresql)
        try #require(parsed.diagnostics.isEmpty && parsed.statements.count == 4)
        let client = BackendClient(executableURL: executable)
        do {
            try await client.start()
            let connected = try await client.request(.connect(settings))
            let session = try #require(connected.sessionId)
            var results: [BackendMessage] = []
            for statement in parsed.statements { results.append(try await client.request(.execute(sessionId: session, sql: statement.sql))) }
            #expect(results[1].rows == [["one;two"]])
            #expect(results[3].rows == [["3"]])
            #expect(await client.shutdown().acknowledged)
        } catch {
            _ = await client.shutdown()
            throw error
        }
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlDelimiterProcedureExecutesWithoutSendingClientDirectives() async throws {
        let environment = ProcessInfo.processInfo.environment
        let settings = ConnectionSettings(host: environment["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
            port: try #require(Int(environment["DBEER_TEST_MYSQL_PORT"] ?? "")),
            database: environment["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: environment["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
            password: environment["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: environment["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable",
            sslRootCert: environment["DBEER_TEST_MYSQL_CA_FILE"], engine: .mysql)
        let name = "dbeer_parser_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sql = """
        DELIMITER $$
        CREATE PROCEDURE \(name)()
        BEGIN
          SET @dbeer_parser_value = 'one;two $$ three';
        END$$
        DELIMITER ;
        CALL \(name)();
        SELECT @dbeer_parser_value;
        DROP PROCEDURE \(name);
        """
        let parsed = SQLScriptParser.parse(sql, engine: .mysql)
        try #require(parsed.diagnostics.isEmpty && parsed.statements.count == 4)
        let client = BackendClient(executableURL: executable)
        var session: String?
        do {
            try await client.start()
            let connected = try await client.request(.connect(settings))
            let id = try #require(connected.sessionId)
            session = id
            var results: [BackendMessage] = []
            for statement in parsed.statements { results.append(try await client.request(.execute(sessionId: id, sql: statement.sql))) }
            #expect(results[2].rows == [["one;two $$ three"]])
            #expect(await client.shutdown().acknowledged)
        } catch {
            if let session { _ = try? await client.request(.execute(sessionId: session, sql: "DROP PROCEDURE IF EXISTS \(name)")) }
            _ = await client.shutdown()
            throw error
        }
    }
}
