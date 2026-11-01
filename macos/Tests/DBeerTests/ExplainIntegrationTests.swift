import Foundation
import Testing
@testable import DBeer

/// No windows, modal alerts, saved profiles or owner credentials. These tests
/// use only credentials exported by the disposable database runners.
@Suite(.serialized)
@MainActor
struct ExplainIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresRoundTripSameSessionAndReview() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlRoundTripSameSessionAndReview() async throws { try await exercise(.mysql) }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let env = ProcessInfo.processInfo.environment
        let executable = env["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ??
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let client = BackendClient(executableURL: executable)
        let settings: ConnectionSettings
        if engine == .mysql {
            settings = ConnectionSettings(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
                port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")), database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer",
                user: env["DBEER_TEST_MYSQL_USER"] ?? "dbeer", password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "",
                sslMode: env["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable", sslRootCert: env["DBEER_TEST_MYSQL_CA_FILE"], engine: .mysql)
        } else {
            let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
            settings = ConnectionSettings(host: try #require(url.host), port: url.port ?? 5432,
                database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        try await client.start()
        do {
            let connected = try await client.request(.connect(settings))
            let session = try #require(connected.sessionId)
            #expect(connected.capabilities?.contains("visualExplainV1") == true)
            #expect(connected.explainSupport?.modes == [.plan, .analyze])
            _ = try await client.request(.execute(sessionId: session, sql: "CREATE TEMPORARY TABLE dbeer_explain_native (id integer)"))
            _ = try await client.request(.execute(sessionId: session, sql: "INSERT INTO dbeer_explain_native VALUES (1), (2)"))
            _ = try await client.request(.execute(sessionId: session, sql: "BEGIN"))
            _ = try await client.request(.execute(sessionId: session, sql: "INSERT INTO dbeer_explain_native VALUES (3)"))
            for mode in [ExplainMode.plan, .analyze] {
                let request = ExplainRequest(sql: "SELECT * FROM dbeer_explain_native WHERE id > 0", mode: mode)
                let assessment = try await client.request(.assess(sessionId: session, operations: [OperationRequest(type: "explain.run", explain: request)]))
                let review = try #require(assessment.assessment)
                #expect(review.decision == (mode == .analyze ? "confirm" : "allow"))
                #expect(review.operations.first?.explain?.mode == mode)
                #expect(review.operations.first?.explain?.sql.hasSuffix(request.sql) == true)
                var command = BackendCommand.explain(sessionId: session, request: request)
                command.authorization = try #require(review.authorization)
                let response = try await client.request(command)
                #expect(response.transactionStatus == .transaction && response.sqlCompleted == true)
                let plan = try #require(response.explain)
                #expect(plan.valid && plan.status == "tree" && plan.complete)
                #expect(plan.mode == mode && plan.support.engine == engine)
                #expect(!plan.nodes.isEmpty && !plan.raw.isEmpty)
                #expect(response.rows == nil && response.source == nil)
                // An authorization is single use even when the first reply was success.
                command = .explain(sessionId: session, request: request)
                command.authorization = review.authorization
                do { _ = try await client.request(command); Issue.record("Reused explain grant") }
                catch let error as BackendRemoteError { #expect(error.reply.sqlNotExecuted == true && error.reply.category == "policy") }
            }
            let retained = try await client.request(.execute(sessionId: session, sql: "SELECT count(*) FROM dbeer_explain_native"))
            #expect(retained.rows?.first?.first == "3")
            _ = try await client.request(.execute(sessionId: session, sql: "ROLLBACK"))
            _ = try await client.request(.disconnect(sessionId: session))
        } catch {
            _ = await client.shutdown()
            throw error
        }
        _ = await client.shutdown()
    }
}
