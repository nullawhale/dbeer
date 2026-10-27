import Foundation
import Testing
@testable import DBeer

/// Real helper/database coverage without AppKit windows, approval UI or saved profiles.
/// The standard database runners provide disposable servers and temporary credentials.
@Suite(.serialized)
@MainActor
struct AgentAccessDatabaseTests {
    private enum FixtureError: Error { case configuration, backend, database, waitExpired }

    @MainActor private final class Fixture {
        let engine: DatabaseEngine
        let connection: ConnectionSettings
        let profile: SavedConnection
        let table = "dbeer_agent_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let admin: BackendClient
        var session: String?
        var coordinator: AgentAccessCoordinator!
        var allowWrites = false
        var confirmResult = true
        var confirmationCalls = 0
        var backendStarts = 0

        var schema: String { engine == .postgresql ? "public" : connection.database }
        var identitySQL: String { engine == .postgresql ? "SELECT pg_backend_pid()" : "SELECT CONNECTION_ID()" }

        private static var executable: URL {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        }

        init(_ engine: DatabaseEngine) throws {
            self.engine = engine
            connection = try Self.settings(engine)
            var agentSettings = connection
            agentSettings.policy = ExecutionPolicy(environment: .production, readOnly: false)
            profile = SavedConnection(name: "Agent database fixture", settings: agentSettings)
            admin = BackendClient(executableURL: Self.executable)
            coordinator = AgentAccessCoordinator(profiles: { [unowned self] in [profile] },
                settings: { [unowned self] snapshot in snapshot.settings(password: connection.password) },
                backendFactory: { [unowned self] in
                    backendStarts += 1
                    let backend = BackendClient(executableURL: Self.executable)
                    try await backend.start()
                    return backend
                }, approve: { [unowned self] _, _ in [profile.id: allowWrites] },
                confirm: { [unowned self] _ in confirmationCalls += 1; return confirmResult })
        }

        private static func settings(_ engine: DatabaseEngine) throws -> ConnectionSettings {
            let environment = ProcessInfo.processInfo.environment
            if engine == .mysql {
                guard let port = Int(environment["DBEER_TEST_MYSQL_PORT"] ?? "") else { throw FixtureError.configuration }
                return ConnectionSettings(host: environment["DBEER_TEST_MYSQL_HOST"] ?? "localhost", port: port,
                    database: environment["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: environment["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
                    password: environment["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: environment["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable",
                    sslRootCert: environment["DBEER_TEST_MYSQL_CA_FILE"], engine: .mysql)
            }
            guard let url = URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""),
                  let host = url.host, let user = url.user else { throw FixtureError.configuration }
            let options = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
            return ConnectionSettings(host: host, port: url.port ?? 5432, database: String(url.path.dropFirst()),
                user: user, password: url.password ?? "", sslMode: options["sslmode"] ?? "verify-full", sslRootCert: options["sslrootcert"])
        }

        func start() async throws {
            try await admin.start()
            session = try await admin.request(.connect(connection)).sessionId
            guard session != nil else { throw FixtureError.backend }
            _ = try await execute("CREATE TABLE \(table) (id INTEGER PRIMARY KEY, note VARCHAR(128) NOT NULL)")
            _ = try await execute("INSERT INTO \(table) (id,note) VALUES (1,'seed')")
        }

        /// Every fixture command explicitly approves the helper's exact operation assessment.
        func execute(_ sql: String) async throws -> BackendMessage {
            guard let session else { throw FixtureError.backend }
            let assessed = try await admin.request(.assess(sessionId: session,
                operations: [OperationRequest(type: "execute", sql: sql)]))
            guard let assessment = assessed.assessment, assessment.decision != "deny",
                  let authorization = assessment.authorization else { throw FixtureError.database }
            var command = BackendCommand.execute(sessionId: session, sql: sql)
            command.authorization = authorization
            let reply = try await admin.request(command)
            guard reply.type == "query.result" else { throw FixtureError.database }
            return reply
        }

        func close() async {
            await coordinator.shutdown()
            if session != nil {
                _ = try? await execute("ROLLBACK")
                _ = try? await execute("DROP TABLE IF EXISTS \(table)")
            }
            _ = await admin.shutdown()
            session = nil
        }

        func hello(_ clientID: UUID) async -> AgentResponse {
            await coordinator.handle(clientID: clientID,
                request: AgentRequest(id: UUID().uuidString, method: "hello", clientName: "Database integration client"))
        }

        func query(_ clientID: UUID, _ sql: String, id: String = UUID().uuidString,
                   maxRows: Int? = nil, timeout: Int = 10) async -> AgentResponse {
            await coordinator.handle(clientID: clientID,
                request: AgentRequest(id: UUID().uuidString, method: "query", profileId: profile.id.uuidString,
                    sql: sql, queryId: id, maxRows: maxRows, timeoutSeconds: timeout))
        }

        func catalog(_ clientID: UUID, kind: String, schema: String? = nil, object: String? = nil) async -> AgentResponse {
            await coordinator.handle(clientID: clientID,
                request: AgentRequest(id: UUID().uuidString, method: "catalog", profileId: profile.id.uuidString,
                    queryId: UUID().uuidString, kind: kind, schema: schema, object: object, timeoutSeconds: 10))
        }

        func cancel(_ clientID: UUID, id: String) async -> AgentResponse {
            await coordinator.handle(clientID: clientID,
                request: AgentRequest(id: UUID().uuidString, method: "cancel", queryId: id))
        }

        func slowSQL(marker: String) -> String {
            engine == .postgresql ? "/*\(marker)*/ SELECT pg_sleep(20)" : "/*\(marker)*/ SELECT SLEEP(20)"
        }

        /// Observe actual server execution rather than inferring it from a frontend task starting.
        func waitForSleep(marker: String, running: Bool = true) async throws {
            let sql = engine == .postgresql
                ? "SELECT COUNT(*) FROM pg_catalog.pg_stat_activity WHERE pid <> pg_backend_pid() AND wait_event='PgSleep' AND query LIKE '%\(marker)%'"
                : "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() AND COMMAND='Query' AND INFO LIKE '%\(marker)%'"
            for _ in 0..<200 {
                // The owner deliberately stays in a transaction; refresh PostgreSQL's
                // statistics snapshot so successive polls observe server cancellation.
                if engine == .postgresql { _ = try await execute("SELECT pg_stat_clear_snapshot()") }
                let reply = try await execute(sql)
                guard let value = reply.rows?.first?.first ?? nil, let count = Int(value) else { throw FixtureError.database }
                if (count > 0) == running { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw FixtureError.waitExpired
        }
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresReadonlyExactValuesAndCatalog() async throws { try await readonly(.postgresql) }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlReadonlyExactValuesAndCatalog() async throws { try await readonly(.mysql) }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresWritesIsolationCancellationAndRevocation() async throws { try await writesAndLifecycle(.postgresql) }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlWritesIsolationCancellationAndRevocation() async throws { try await writesAndLifecycle(.mysql) }

    private func readonly(_ engine: DatabaseEngine) async throws {
        let fixture = try Fixture(engine)
        do {
            try await fixture.start()
            let id = UUID()
            let hello = await fixture.hello(id)
            let approvedReadonly = hello.ok && hello.connections?.count == 1 && hello.connections?.first?.readOnly == true
            try #require(approvedReadonly, "The real-database agent grant did not default to readonly.")

            let launches = fixture.backendStarts
            let unavailable = await fixture.coordinator.handle(clientID: id,
                request: AgentRequest(id: UUID().uuidString, method: "query", profileId: UUID().uuidString,
                    sql: "SELECT 1", queryId: UUID().uuidString))
            #expect(!unavailable.ok && fixture.backendStarts == launches)

            let mutationCTE = engine == .postgresql
                ? "WITH modified AS (DELETE FROM \(fixture.table) RETURNING id) SELECT id FROM modified"
                : "WITH modified AS (SELECT 1 AS id) UPDATE \(fixture.table) SET note='blocked' WHERE id IN (SELECT id FROM modified)"
            let resetReadonly = engine == .postgresql ? "SET default_transaction_read_only=off" : "SET SESSION TRANSACTION READ WRITE"
            for sql in ["INSERT INTO \(fixture.table) (id,note) VALUES (2,'blocked')", mutationCTE, resetReadonly] {
                let response = await fixture.query(id, sql)
                #expect(!response.ok)
                let noCredentialLeak = fixture.connection.password.isEmpty || !(response.error ?? "").contains(fixture.connection.password)
                #expect(noCredentialLeak)
            }
            #expect(fixture.confirmationCalls == 0)
            let unchanged = try await fixture.execute("SELECT id,note FROM \(fixture.table) ORDER BY id")
            let originalPreserved = unchanged.rows == [["1", "seed"]]
            #expect(originalPreserved)

            let exactSQL = engine == .postgresql
                ? "SELECT NULL::text AS absent, ''::text AS empty, 'NULL'::text AS literal_null, 9007199254740993.123456789::numeric AS exact_value, decode('00ff','hex') AS payload"
                : "SELECT NULL AS absent, '' AS `empty`, 'NULL' AS literal_null, CAST('9007199254740993.123456789' AS DECIMAL(30,9)) AS exact_value, _binary X'00FF' AS payload"
            let exact = await fixture.query(id, exactSQL)
            let exactValues = exact.ok && exact.results?.first?.rows == [[nil, "", "NULL", "9007199254740993.123456789", "AP8="]]
                && exact.results?.first?.columns.last?.encoding == "base64"
            #expect(exactValues, "Real database cells lost exact values or binary metadata through the agent DTO.")
            let bounded = await fixture.query(id, "SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3 ORDER BY n", maxRows: 2)
            let boundedRows = bounded.ok && bounded.results?.first?.rows.count == 2 && bounded.results?.first?.truncated == true
            #expect(boundedRows)

            let schemas = await fixture.catalog(id, kind: "schemas")
            let hasSchema = schemas.ok && schemas.results?.first?.rows.contains(where: { $0.first == fixture.schema }) == true
            #expect(hasSchema)
            let tables = await fixture.catalog(id, kind: "tables", schema: fixture.schema)
            let hasTable = tables.ok && tables.results?.first?.rows.contains(where: { $0.first == fixture.table }) == true
            #expect(hasTable)
            let columns = await fixture.catalog(id, kind: "columns", schema: fixture.schema, object: fixture.table)
            let hasColumns = columns.ok && columns.results?.first?.rows.compactMap { $0.first ?? nil } == ["id", "note"]
            #expect(hasColumns)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private func writesAndLifecycle(_ engine: DatabaseEngine) async throws {
        let fixture = try Fixture(engine)
        do {
            try await fixture.start()
            fixture.allowWrites = true
            let id = UUID(), other = UUID()
            let firstHello = await fixture.hello(id), secondHello = await fixture.hello(other)
            let writeGranted = firstHello.ok && secondHello.ok && firstHello.connections?.first?.readOnly == false
            try #require(writeGranted)

            // This owner session stands in for an unrelated GUI tab transaction.
            _ = try await fixture.execute("BEGIN")
            let ownerIdentity = try await fixture.execute(fixture.identitySQL)
            let agentIdentity = await fixture.query(id, fixture.identitySQL)
            let ownerPID = ownerIdentity.rows?.first?.first ?? nil
            let agentPID = agentIdentity.results?.first?.rows.first?.first ?? nil
            let isolatedSession = agentIdentity.ok && ownerPID != nil && agentPID != nil && ownerPID != agentPID
            #expect(isolatedSession)

            let inserted = await fixture.query(id, "INSERT INTO \(fixture.table) (id,note) VALUES (2,'agent-insert')")
            #expect(inserted.ok && fixture.confirmationCalls == 1)
            let updated = await fixture.query(id, "UPDATE \(fixture.table) SET note='agent-updated' WHERE id=2")
            #expect(updated.ok && fixture.confirmationCalls == 2)
            fixture.confirmResult = false
            let denied = await fixture.query(id, "DELETE FROM \(fixture.table) WHERE id=2")
            #expect(!denied.ok && fixture.confirmationCalls == 3)
            let retained = await fixture.query(other, "SELECT note FROM \(fixture.table) WHERE id=2")
            let retainedWrite = retained.ok && retained.results?.first?.rows == [["agent-updated"]]
            #expect(retainedWrite)
            fixture.confirmResult = true
            let deleted = await fixture.query(id, "DELETE FROM \(fixture.table) WHERE id=2")
            #expect(deleted.ok && fixture.confirmationCalls == 4)

            let marker = "agent_cancel_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let queryID = UUID().uuidString
            let query = Task { await fixture.query(id, fixture.slowSQL(marker: marker), id: queryID) }
            do { try await fixture.waitForSleep(marker: marker) }
            catch { _ = await fixture.cancel(id, id: queryID); _ = await query.value; throw error }
            let crossClient = await fixture.cancel(other, id: queryID)
            #expect(crossClient.ok)
            // Cancellation is idempotent within the caller's namespace, so the
            // same identifier on another client cannot stop the owner's query.
            try await fixture.waitForSleep(marker: marker)
            let cancelled = await fixture.cancel(id, id: queryID)
            let cancelledQuery = await query.value
            #expect(cancelled.ok && !cancelledQuery.ok)
            try await fixture.waitForSleep(marker: marker, running: false)

            let revokeMarker = "agent_revoke_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let revokedID = UUID().uuidString
            let revoking = Task { await fixture.query(id, fixture.slowSQL(marker: revokeMarker), id: revokedID) }
            do { try await fixture.waitForSleep(marker: revokeMarker) }
            catch { _ = await fixture.cancel(id, id: revokedID); _ = await revoking.value; throw error }
            await fixture.coordinator.revoke(clientID: id)
            let revokedQuery = await revoking.value
            #expect(!revokedQuery.ok)
            try await fixture.waitForSleep(marker: revokeMarker, running: false)
            let rejectedAfterRevoke = await fixture.query(id, "SELECT 1")
            let survivingClient = await fixture.query(other, "SELECT 1")
            #expect(!rejectedAfterRevoke.ok && survivingClient.ok)

            let timedOut = await fixture.query(other, fixture.slowSQL(marker: "agent_deadline"), timeout: 1)
            #expect(!timedOut.ok)
            let ownerStillActive = try await fixture.execute("SELECT 1")
            #expect(ownerStillActive.transactionStatus == .transaction)
            _ = try await fixture.execute("ROLLBACK")
            let finalRows = try await fixture.execute("SELECT id,note FROM \(fixture.table) ORDER BY id")
            let finalState = finalRows.rows == [["1", "seed"]]
            #expect(finalState)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}
