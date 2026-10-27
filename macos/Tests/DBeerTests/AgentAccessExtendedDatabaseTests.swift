import Foundation
import Testing
@testable import DBeer

/// Real Cassandra/MongoDB MCP coverage without windows, persisted profiles or UI approval.
/// The supported disposable runners supply the only connection settings used here.
@Suite(.serialized)
@MainActor
struct AgentAccessExtendedDatabaseTests {
    private enum FixtureError: Error { case configuration, backend, database, waitExpired, fixtureCommand }

    @MainActor private final class Fixture {
        let engine: DatabaseEngine
        let connection: ConnectionSettings
        let profile: SavedConnection
        let excluded: SavedConnection
        let admin: BackendClient
        let table = "mcp_extended_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var session: String?
        var coordinator: AgentAccessCoordinator!
        var allowWrites = false
        var confirmResult = true
        var confirmationCalls = 0
        var backendStarts = 0
        var holdNextBackend = false
        var heldBackend: BackendClient?
        var releaseBackend: CheckedContinuation<Void, Never>?

        var schema: String { connection.database }
        var qualifiedTable: String { schema + "." + table }

        private static var executable: URL {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        }

        init(_ engine: DatabaseEngine) throws {
            self.engine = engine
            let environment = ProcessInfo.processInfo.environment
            let prefix = engine == .cassandra ? "DBEER_TEST_CASSANDRA_" : "DBEER_TEST_MONGODB_"
            guard let host = environment[prefix + "HOST"], ["localhost", "127.0.0.1", "::1"].contains(host),
                  let port = Int(environment[prefix + "PORT"] ?? "") else { throw FixtureError.configuration }
            let sslMode = environment[prefix + "SSLMODE"] ?? "disable"
            let database = engine == .cassandra ? environment[prefix + "DATABASE"] ?? "dbeer" :
                "dbeer_mcp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            connection = ConnectionSettings(host: host, port: port, database: database,
                user: environment[prefix + "USER"] ?? "", password: environment[prefix + "PASSWORD"] ?? "",
                sslMode: sslMode,
                sslRootCert: sslMode == "verify-full" ? environment[prefix + (engine == .cassandra ? "CA_FILE" : "CA")] : nil,
                engine: engine,
                localDatacenter: engine == .cassandra ? environment[prefix + "DATACENTER"] ?? "datacenter1" : nil,
                consistency: engine == .cassandra ? "LOCAL_ONE" : nil,
                mongodb: engine == .mongodb ? MongoDBSettings(replicaSet: environment[prefix + "REPLICA_SET"] ?? "", directConnection: true) : nil)
            var effective = connection
            effective.policy = ExecutionPolicy(environment: .production, readOnly: false)
            profile = SavedConnection(name: "Allowed extended agent fixture", settings: effective)
            excluded = SavedConnection(name: "Unapproved extended agent fixture", settings: effective)
            admin = BackendClient(executableURL: Self.executable)
            coordinator = AgentAccessCoordinator(profiles: { [unowned self] in [profile, excluded] },
                settings: { [unowned self] captured in captured.settings(password: connection.password) },
                backendFactory: { [unowned self] in
                    backendStarts += 1
                    let client = BackendClient(executableURL: Self.executable)
                    try await client.start()
                    if holdNextBackend {
                        holdNextBackend = false; heldBackend = client
                        await withCheckedContinuation { releaseBackend = $0 }
                    }
                    return client
                }, approve: { [unowned self] _, _ in [profile.id: allowWrites] },
                confirm: { [unowned self] _ in confirmationCalls += 1; return confirmResult })
        }

        func start() async throws {
            try await admin.start()
            session = try await admin.request(.connect(connection)).sessionId
            guard session != nil else { throw FixtureError.backend }
            if engine == .cassandra {
                _ = try await execute("CREATE TABLE \(qualifiedTable) (id int PRIMARY KEY, absent text, empty text, literal text, exact_value decimal, huge varint, payload blob)")
                _ = try await execute("INSERT INTO \(qualifiedTable) (id,empty,literal,exact_value,huge,payload) VALUES (1,'','NULL',9007199254740993.123456789,1234567890123456789012345678901234567890,0x00ff)")
            } else {
                _ = try await mongoScript("""
                const fixture = db.getSiblingDB("\(schema)");
                fixture.createCollection("\(table)");
                fixture.getCollection("\(table)").insertMany([
                  {_id:NumberInt(1),absent:null,empty:"",literal:"NULL",exact_value:NumberDecimal("9007199254740993.123456789"),huge:NumberLong("9007199254740993"),payload:BinData(0,"AP8=")},
                  {_id:NumberInt(2),empty:"second"},{_id:NumberInt(3),empty:"third"}
                ]);
                """)
            }
        }

        func execute(_ source: String) async throws -> BackendMessage {
            guard let session else { throw FixtureError.backend }
            let assessed = try await admin.request(.assess(sessionId: session,
                operations: [OperationRequest(type: "execute", sql: source)]))
            guard let assessment = assessed.assessment, assessment.decision != "deny",
                  let authorization = assessment.authorization else { throw FixtureError.database }
            var command = BackendCommand.execute(sessionId: session, sql: source)
            command.authorization = authorization
            let reply = try await admin.request(command)
            guard reply.type == "query.result" else { throw FixtureError.database }
            return reply
        }

        func hello(_ id: UUID) async -> AgentResponse {
            await coordinator.handle(clientID: id,
                request: AgentRequest(id: UUID().uuidString, method: "hello", clientName: "Extended database integration client"))
        }
        func query(_ id: UUID, _ source: String, queryID: String = UUID().uuidString,
                   maxRows: Int = 100, profileID: UUID? = nil) async -> AgentResponse {
            await coordinator.handle(clientID: id,
                request: AgentRequest(id: UUID().uuidString, method: "query", profileId: (profileID ?? profile.id).uuidString,
                    sql: source, queryId: queryID, maxRows: maxRows, timeoutSeconds: 15))
        }
        func catalog(_ id: UUID, kind: String, schema: String? = nil, object: String? = nil) async -> AgentResponse {
            await coordinator.handle(clientID: id,
                request: AgentRequest(id: UUID().uuidString, method: "catalog", profileId: profile.id.uuidString,
                    queryId: UUID().uuidString, kind: kind, schema: schema, object: object, timeoutSeconds: 15))
        }
        func cancel(_ id: UUID, queryID: String) async -> AgentResponse {
            await coordinator.handle(clientID: id,
                request: AgentRequest(id: UUID().uuidString, method: "cancel", queryId: queryID))
        }
        func waitForBackend() async throws {
            for _ in 0..<500 {
                if releaseBackend != nil { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw FixtureError.waitExpired
        }
        func releaseHeldBackend() {
            let continuation = releaseBackend; releaseBackend = nil; continuation?.resume()
        }
        func mongoFind(_ collection: String? = nil, filter: String = "{}") -> String {
            "{\"collection\":\"\(collection ?? table)\",\"find\":\(filter),\"sort\":{\"_id\":1}}"
        }
        func mongoOutput(_ stage: String = "$out") -> String {
            "{\"collection\":\"\(table)\",\"aggregate\":[{\"$match\":{}},{\"\(stage)\":\"\(table)_output\"}]}"
        }

        /// Credentials are expanded only inside the runner-owned container.
        /// Only explicitly printed nonsecret fixture counters are retained.
        func mongoScript(_ script: String) async throws -> String {
            let environment = ProcessInfo.processInfo.environment
            guard let container = environment["DBEER_TEST_MONGODB_CONTAINER"], !container.isEmpty else {
                throw FixtureError.configuration
            }
            let tls = environment["DBEER_TEST_MONGODB_SSLMODE"] == "verify-full"
            return try await Task.detached {
                let process = Process(), input = Pipe(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                let shell = """
                auth=()
                if [[ -n "${MONGO_INITDB_ROOT_USERNAME:-}" ]]; then
                  auth=(--username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin)
                fi
                exec mongosh --quiet --host localhost "${auth[@]}" "$@" --file /dev/stdin
                """
                process.arguments = ["docker", "exec", "-i", container, "bash", "-c", shell, "_"] +
                    (tls ? ["--tls", "--tlsCAFile", "/fixture/ca.crt"] : [])
                process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try process.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
                    if process.isRunning { process.terminate() }
                }
                try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try input.fileHandleForWriting.close()
                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0, bytes.count <= 4_096,
                      let text = String(data: bytes, encoding: .utf8) else { throw FixtureError.fixtureCommand }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }.value
        }

        func blockNextMongoAggregate() async throws -> Int {
            let result = try await mongoScript("""
            const result = db.adminCommand({configureFailPoint:"failCommand",mode:{times:1},data:{failCommands:["aggregate"],blockConnection:true,blockTimeMS:5000}});
            if (result.ok !== 1) throw new Error("fixture setup failed");
            print(Number(result.count));
            """)
            guard let count = Int(result) else { throw FixtureError.fixtureCommand }
            return count
        }
        func waitForMongoAggregate(_ count: Int) async throws {
            _ = try await mongoScript("""
            const result = db.adminCommand({waitForFailPoint:"failCommand",timesEntered:\(count + 1),maxTimeMS:4000});
            if (result.ok !== 1) throw new Error("fixture wait failed");
            """)
        }

        func close() async {
            releaseHeldBackend()
            await coordinator.shutdown()
            if session != nil {
                if engine == .cassandra { _ = try? await execute("DROP TABLE IF EXISTS \(qualifiedTable)") }
                else { _ = try? await mongoScript("db.getSiblingDB(\"\(schema)\").dropDatabase();") }
            }
            _ = await admin.shutdown()
            session = nil
        }
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_CASSANDRA_HOST"] ?? "").isEmpty))
    func cassandraReadonlyExactValuesCatalogAndExplicitWrites() async throws {
        let fixture = try Fixture(.cassandra)
        do {
            try await fixture.start()
            let reader = UUID(), grant = await fixture.hello(reader)
            let readonlyGrant = grant.ok && grant.connections?.count == 1 && grant.connections?.first?.engine == "cassandra" &&
                grant.connections?.first?.readOnly == true && grant.connections?.first?.queryLanguage == "cql" &&
                grant.connections?.first?.readOnlyEnforcement == "local"
            try #require(readonlyGrant)
            let starts = fixture.backendStarts
            let excluded = await fixture.query(reader, "SELECT * FROM system.local", profileID: fixture.excluded.id)
            #expect(!excluded.ok && fixture.backendStarts == starts)
            for source in ["INSERT INTO \(fixture.qualifiedTable) (id) VALUES (2)", "TRUNCATE \(fixture.qualifiedTable)",
                           "SELECT id FROM \(fixture.qualifiedTable); INSERT INTO \(fixture.qualifiedTable) (id) VALUES (2)"] {
                let denied = await fixture.query(reader, source)
                #expect(!denied.ok)
            }
            #expect(fixture.confirmationCalls == 0)
            let exact = await fixture.query(reader, "SELECT absent,empty,literal,exact_value,huge,payload FROM \(fixture.qualifiedTable) WHERE id=1")
            let exactCells = exact.ok && exact.results?.first?.rows == [[nil, "", "NULL", "9007199254740993.123456789", "1234567890123456789012345678901234567890", "AP8="]] &&
                exact.results?.first?.columns.last?.encoding == "base64" && exact.results?.first?.affectedRowCountKnown == false
            #expect(exactCells, "CQL values or non-SQL row-count semantics were lost through MCP.")
            for kind in ["schemas", "keyspaces"] {
                let listed = await fixture.catalog(reader, kind: kind)
                #expect(listed.ok && listed.results?.first?.rows.contains(where: { $0.first == fixture.schema }) == true)
            }
            let tables = await fixture.catalog(reader, kind: "tables", schema: fixture.schema)
            #expect(tables.ok && tables.results?.first?.rows.contains(where: { $0.first == fixture.table }) == true)
            let columns = await fixture.catalog(reader, kind: "columns", schema: fixture.schema, object: fixture.table)
            #expect(columns.ok && columns.results?.first?.rows.contains(where: { $0.first == "payload" }) == true)
            let wrongAlias = await fixture.catalog(reader, kind: "databases")
            #expect(!wrongAlias.ok)

            fixture.allowWrites = true
            let writer = UUID(), writeGrant = await fixture.hello(writer)
            #expect(writeGrant.ok && writeGrant.connections?.first?.readOnly == false)
            fixture.confirmResult = false
            let declined = await fixture.query(writer, "DELETE FROM \(fixture.qualifiedTable) WHERE id=1")
            #expect(!declined.ok && fixture.confirmationCalls == 1)
            fixture.confirmResult = true
            let inserted = await fixture.query(writer, "INSERT INTO \(fixture.qualifiedTable) (id,empty) VALUES (2,'agent')")
            #expect(inserted.ok && fixture.confirmationCalls == 2)
            let written = await fixture.query(reader, "SELECT empty FROM \(fixture.qualifiedTable) WHERE id=2")
            #expect(written.ok && written.results?.first?.rows == [["agent"]])
            let changedKeyspace = await fixture.query(reader, "USE dbeer_other")
            #expect(changedKeyspace.ok)
            let original = await fixture.query(reader, "SELECT id FROM \(fixture.table) WHERE id=1")
            #expect(original.ok && original.results?.first?.rows == [["1"]])
            let owner = try await fixture.execute("SELECT id FROM \(fixture.table) WHERE id=1")
            #expect(owner.transactionStatus == .unsupported && owner.currentKeyspace == fixture.schema)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_CASSANDRA_HOST"] ?? "").isEmpty))
    func cassandraCancellationAndRevocationCloseLateHelpersWithoutChangingOwnerSession() async throws {
        let fixture = try Fixture(.cassandra)
        do {
            try await fixture.start()
            let reader = UUID(), grant = await fixture.hello(reader)
            try #require(grant.ok)
            let queryID = UUID().uuidString
            fixture.holdNextBackend = true
            let pending = Task { await fixture.query(reader, "SELECT id FROM \(fixture.qualifiedTable) WHERE id=1", queryID: queryID) }
            try await fixture.waitForBackend()
            let held = try #require(fixture.heldBackend)
            let cancelled = await fixture.cancel(reader, queryID: queryID)
            fixture.releaseHeldBackend()
            let stopped = await pending.value
            #expect(cancelled.ok && !stopped.ok)
            let exit = await held.waitForExit()
            #expect(exit.status == 0)
            let recovered = await fixture.query(reader, "SELECT id FROM \(fixture.qualifiedTable) WHERE id=1")
            #expect(recovered.ok)
            fixture.holdNextBackend = true
            let pendingRevoke = Task { await fixture.query(reader, "SELECT id FROM \(fixture.qualifiedTable) WHERE id=1") }
            try await fixture.waitForBackend()
            let late = try #require(fixture.heldBackend)
            await fixture.coordinator.revoke(clientID: reader)
            fixture.releaseHeldBackend()
            let revoked = await pendingRevoke.value
            #expect(!revoked.ok && fixture.coordinator.clients.isEmpty)
            let lateExit = await late.waitForExit()
            #expect(lateExit.status == 0)
            let denied = await fixture.query(reader, "SELECT id FROM \(fixture.qualifiedTable) WHERE id=1")
            #expect(!denied.ok)
            let owner = try await fixture.execute("SELECT id FROM \(fixture.qualifiedTable) WHERE id=1")
            #expect(owner.rows == [["1"]] && owner.transactionStatus == .unsupported)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MONGODB_HOST"] ?? "").isEmpty))
    func mongodbReadonlyCanonicalValuesCatalogAndConfirmedOutputStages() async throws {
        let fixture = try Fixture(.mongodb)
        do {
            try await fixture.start()
            let reader = UUID(), grant = await fixture.hello(reader)
            let readonlyGrant = grant.ok && grant.connections?.count == 1 && grant.connections?.first?.engine == "mongodb" &&
                grant.connections?.first?.readOnly == true && grant.connections?.first?.queryLanguage == "mongodb-json" &&
                grant.connections?.first?.readOnlyEnforcement == "local"
            try #require(readonlyGrant)
            let starts = fixture.backendStarts
            let excluded = await fixture.query(reader, fixture.mongoFind(), profileID: fixture.excluded.id)
            #expect(!excluded.ok && fixture.backendStarts == starts)
            for source in [fixture.mongoOutput(), fixture.mongoOutput("$merge"),
                           "{\"collection\":\"\(fixture.table)\",\"find\":{\"$where\":\"return true\"}}",
                           "{\"collection\":\"\(fixture.table)\",\"insert\":[{\"_id\":4}]}"] {
                let denied = await fixture.query(reader, source)
                #expect(!denied.ok)
            }
            #expect(fixture.confirmationCalls == 0)
            let exact = await fixture.query(reader, fixture.mongoFind(filter: "{\"_id\":1}"))
            let document = exact.results?.first?.rows.first?.first ?? nil
            let fields = document.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            let binary = fields?["payload"] as? [String: Any]
            let encodedBinary = binary?["$binary"] as? [String: String]
            let exactCells = exact.ok && fields?["absent"] is NSNull && fields?["empty"] as? String == "" &&
                fields?["literal"] as? String == "NULL" &&
                (fields?["exact_value"] as? [String: String])?["$numberDecimal"] == "9007199254740993.123456789" &&
                (fields?["huge"] as? [String: String])?["$numberLong"] == "9007199254740993" &&
                encodedBinary?["base64"] == "AP8=" && exact.results?.first?.affectedRowCountKnown == false
            #expect(exactCells, "Canonical BSON or non-SQL row-count semantics were lost through MCP.")
            let bounded = await fixture.query(reader, fixture.mongoFind(), maxRows: 2)
            #expect(bounded.ok && bounded.results?.first?.rows.count == 2 && bounded.results?.first?.truncated == true)
            for kind in ["schemas", "databases"] {
                let listed = await fixture.catalog(reader, kind: kind)
                #expect(listed.ok && listed.results?.first?.rows.contains(where: { $0.first == fixture.schema }) == true)
            }
            for kind in ["tables", "collections"] {
                let listed = await fixture.catalog(reader, kind: kind, schema: fixture.schema)
                #expect(listed.ok && listed.results?.first?.rows.contains(where: { $0.first == fixture.table }) == true)
            }
            for kind in ["columns", "fields"] {
                let sampled = await fixture.catalog(reader, kind: kind, schema: fixture.schema, object: fixture.table)
                let sampledEvidence = sampled.ok && sampled.results?.first?.rows.contains(where: { $0.first == "exact_value" && $0.last == "sampled" }) == true &&
                    sampled.results?.first?.displayNotice?.contains("32") == true && sampled.results?.first?.affectedRowCountKnown == false
                #expect(sampledEvidence, "Sampled MongoDB fields were presented as a complete schema.")
            }
            let wrongAlias = await fixture.catalog(reader, kind: "keyspaces")
            #expect(!wrongAlias.ok)
            fixture.allowWrites = true
            let writer = UUID(), writeGrant = await fixture.hello(writer)
            #expect(writeGrant.ok && writeGrant.connections?.first?.readOnly == false)
            fixture.confirmResult = false
            let declined = await fixture.query(writer, fixture.mongoOutput())
            #expect(!declined.ok && fixture.confirmationCalls == 1)
            fixture.confirmResult = true
            let output = await fixture.query(writer, fixture.mongoOutput())
            #expect(output.ok && fixture.confirmationCalls == 2)
            let copied = await fixture.query(reader, fixture.mongoFind(fixture.table + "_output"))
            #expect(copied.ok && copied.results?.first?.rows.count == 3)
            let javascript = await fixture.query(writer, "db.\(fixture.table).find({})")
            #expect(!javascript.ok)
            let owner = try await fixture.execute(fixture.mongoFind())
            #expect(owner.transactionStatus == .unsupported && owner.rows?.count == 3)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MONGODB_HOST"] ?? "").isEmpty))
    func mongodbCancellationAndRevocationStopWaitingForServerWithoutRetry() async throws {
        let fixture = try Fixture(.mongodb)
        do {
            try await fixture.start()
            let reader = UUID(), grant = await fixture.hello(reader)
            try #require(grant.ok)
            let source = "{\"collection\":\"\(fixture.table)\",\"aggregate\":[{\"$match\":{}}]}"
            let count = try await fixture.blockNextMongoAggregate(), queryID = UUID().uuidString
            let active = Task { await fixture.query(reader, source, queryID: queryID) }
            try await fixture.waitForMongoAggregate(count)
            let start = ContinuousClock.now
            let cancelled = await fixture.cancel(reader, queryID: queryID)
            let stopped = await active.value
            #expect(cancelled.ok && !stopped.ok && start.duration(to: .now) < .seconds(3))
            let recovered = await fixture.query(reader, fixture.mongoFind())
            #expect(recovered.ok && recovered.results?.first?.rows.count == 3)
            let next = try await fixture.blockNextMongoAggregate()
            let revoking = Task { await fixture.query(reader, source) }
            try await fixture.waitForMongoAggregate(next)
            let revokeStart = ContinuousClock.now
            await fixture.coordinator.revoke(clientID: reader)
            let revoked = await revoking.value
            #expect(!revoked.ok && fixture.coordinator.clients.isEmpty && revokeStart.duration(to: .now) < .seconds(3))
            let denied = await fixture.query(reader, fixture.mongoFind())
            #expect(!denied.ok)
            let owner = try await fixture.execute(fixture.mongoFind())
            #expect(owner.rows?.count == 3 && owner.transactionStatus == .unsupported)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }
}
