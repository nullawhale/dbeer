import Foundation
import Testing
@testable import DBeer

/// These tests inject every approval and never present a window or activate the app.
@Suite(.serialized)
@MainActor
struct AgentAccessTests {
    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-agent-" + UUID().uuidString)
        var profiles: [SavedConnection]
        var approval: [UUID: Bool]?
        var approvalCalls = 0
        var confirmationCalls = 0
        var confirmResult = true
        var confirmationHook: (@MainActor () async -> Void)?
        var approvalHook: (@MainActor () async -> Void)?
        var settingsCalls = 0
        var changeDuringSettings = false
        var connectingDelay = false
        var coordinator: AgentAccessCoordinator!
        var log: URL { directory.appendingPathComponent("commands.jsonl") }
        var entered: URL { directory.appendingPathComponent("entered") }
        var release: URL { directory.appendingPathComponent("release") }

        init(readOnly: Bool = false, writes: Bool = false) throws {
            let profile = SavedConnection(name: "Allowed profile", settings: ConnectionSettings(host: "secret-host", port: 5432,
                database: "private-db", user: "private-user", password: "database-secret", sslMode: "disable",
                policy: ExecutionPolicy(environment: .production, readOnly: readOnly)))
            profiles = [profile]; approval = [profile.id: writes]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            coordinator = AgentAccessCoordinator(profiles: { [unowned self] in profiles }, settings: { [unowned self] profile in
                settingsCalls += 1
                if changeDuringSettings { profiles[0].host = "changed-host" }
                return profile.settings(password: "database-secret")
            }, backendFactory: { [unowned self] in let client = makeClient(); try await client.start(); return client },
            approve: { [unowned self] _, _ in approvalCalls += 1; await approvalHook?(); return approval },
            confirm: { [unowned self] _ in confirmationCalls += 1; await confirmationHook?(); return confirmResult })
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        var commands: [[String: Any]] {
            guard let contents = try? String(contentsOf: log, encoding: .utf8) else { return [] }
            return contents.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        func makeClient() -> BackendClient {
            BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
            import json, os, sys, time, uuid
            from pathlib import Path
            log, entered, release, delay = sys.argv[1:]
            policy = None
            sid = str(uuid.uuid4())
            def send(r): print(json.dumps(r), flush=True)
            for line in sys.stdin:
                c = json.loads(line)
                with open(log, 'a') as f: f.write(json.dumps(c) + '\\n')
                r = {'requestId':c['requestId']}
                k = c['type']
                if k == 'hello': r.update(type='hello.ack', protocolVersion=5)
                elif k == 'connect':
                    policy = c['connection']['policy']
                    if delay == 'delay':
                        Path(entered).touch()
                        until = time.monotonic() + 3
                        while not Path(release).exists() and time.monotonic() < until: time.sleep(.005)
                    r.update(type='connect.result', sessionId=sid, engine='postgresql', capabilities=['execute','catalog','cancel'], transactionStatus='idle')
                elif k == 'operation.assess':
                    sql = c['operations'][0].get('sql','')
                    write = 'DELETE' in sql
                    decision = 'deny' if write and policy['readOnly'] else 'confirm' if write else 'allow'
                    statements = [{'start':0,'end':len(sql.encode()),'kind':'destructive' if write else 'read','reason':'fixture'}]
                    if 'MULTI' in sql: statements.append(statements[0])
                    a = {'decision':decision,'policy':policy,'operations':[{'kind':'destructive' if write else 'read','statements':statements}]}
                    if decision != 'deny': a['authorization'] = 'private-authorization'
                    r.update(type='operation.assessment',sessionId=sid,queryId=c['queryId'],assessment=a)
                elif k in ['execute','catalog']:
                    send(dict(type='query.started',requestId=c['requestId'],sessionId=sid,queryId=c['queryId']))
                    sql = c.get('sql','')
                    if 'BLOCK' in sql:
                        Path(entered).touch()
                        continue
                    if 'ERROR' in sql:
                        r.update(type='error',sessionId=sid,queryId=c['queryId'],category='sql',message='SELECT secret_sql database-secret private-user',connected=True,outcomeUnknown=False)
                    else:
                        rows = [[None],[''],['NULL'],['12345678901234567890.123456789']] if 'VALUES' in sql else [['ok'],['second'],['third']]
                        if 'LARGE' in sql: rows = [['x' * 600000], ['y' * 600000], ['z' * 600000]]
                        if 'MANY' in sql: rows = [[str(i) + ':' + 'x' * 8180] for i in range(1000)]
                        r.update(type='query.result',sessionId=sid,queryId=c['queryId'],transactionStatus='idle',durationMs=1,
                            columns=[{'index':0,'name':'value','nativeType':'numeric'}],rows=rows,commandTag='SELECT',rowCount=len(rows),displayedRowCount=len(rows),truncated=False)
                elif k == 'cancel': r.update(type='cancel.ack',sessionId=sid,queryId=c['queryId'],status='accepted')
                elif k == 'disconnect': r.update(type='disconnect.ack',sessionId=sid)
                elif k == 'shutdown': r.update(type='shutdown.ack')
                else: sys.exit(42)
                send(r)
                if k == 'shutdown': break
            """, log.path, entered.path, release.path, connectingDelay ? "delay" : "immediate"])
        }
        func hello(_ id: UUID) async -> AgentResponse {
            await coordinator.handle(clientID: id, request: AgentRequest(id: "hello", method: "hello", clientName: "Test agent"))
        }
        func query(_ id: UUID, sql: String = "SELECT 1", queryID: String = UUID().uuidString, limit: Int? = nil) async -> AgentResponse {
            await coordinator.handle(clientID: id, request: AgentRequest(id: UUID().uuidString, method: "query",
                profileId: profiles[0].id.uuidString, sql: sql, queryId: queryID, maxRows: limit))
        }
        func waitForEntry() async throws {
            for _ in 0..<500 {
                if FileManager.default.fileExists(atPath: entered.path) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("The helper did not reach the expected operation phase.")
        }
    }

    @Test func approvalRestrictsProfilesAndNeverExportsConnectionSettings() async throws {
        let fixture = try Fixture(); let id = UUID()
        let denied = await fixture.query(id)
        #expect(!denied.ok && fixture.settingsCalls == 0)
        let hello = await fixture.hello(id)
        #expect(hello.ok && hello.connections?.count == 1 && hello.connections?.first?.readOnly == true)
        let encoded = String(decoding: try JSONEncoder().encode(hello), as: UTF8.self)
        for secret in ["secret-host", "private-db", "private-user", "database-secret", "password"] { #expect(!encoded.contains(secret)) }
        let other = await fixture.coordinator.handle(clientID: id, request: AgentRequest(id: "other", method: "query",
            profileId: UUID().uuidString, sql: "SELECT 1", queryId: "query"))
        #expect(!other.ok && fixture.settingsCalls == 0)
        await fixture.coordinator.shutdown()
    }

    @Test func readonlyIsPassedToHelperAndCannotBeEscalatedByAgentSQL() async throws {
        let fixture = try Fixture(); let id = UUID(); _ = await fixture.hello(id)
        #expect(!(await fixture.query(id, sql: "DELETE FROM records")).ok)
        #expect(fixture.confirmationCalls == 0)
        #expect(fixture.commands.filter { $0["type"] as? String == "execute" }.isEmpty)
        let connection = try #require(fixture.commands.first { $0["type"] as? String == "connect" }?["connection"] as? [String: Any])
        #expect((connection["policy"] as? [String: Any])?["readOnly"] as? Bool == true)
        await fixture.coordinator.shutdown()
    }

    @Test func writeGrantPreservesProfileReadonlyAndDangerousConfirmation() async throws {
        for profileReadonly in [false, true] {
            let fixture = try Fixture(readOnly: profileReadonly, writes: true); let id = UUID(); _ = await fixture.hello(id)
            fixture.confirmResult = false
            #expect(!(await fixture.query(id, sql: "DELETE FROM records")).ok)
            #expect(fixture.confirmationCalls == (profileReadonly ? 0 : 1))
            #expect(fixture.commands.filter { $0["type"] as? String == "execute" }.isEmpty)
            await fixture.coordinator.shutdown()
        }
    }

    @Test func changedProfileAndInvalidBoundsNeverConnect() async throws {
        let fixture = try Fixture(); let id = UUID(); _ = await fixture.hello(id)
        #expect(!(await fixture.query(id, limit: 1001)).ok)
        #expect(!(await fixture.query(id, sql: String(repeating: "x", count: 131073))).ok)
        fixture.changeDuringSettings = true
        #expect(!(await fixture.query(id)).ok)
        #expect(fixture.commands.isEmpty)
        await fixture.coordinator.shutdown()
    }

    @Test func exactCellsAreRetainedAndResponseBytesAreBounded() async throws {
        let fixture = try Fixture(); let id = UUID(); _ = await fixture.hello(id)
        let exact = await fixture.query(id, sql: "SELECT VALUES")
        #expect(exact.ok && exact.results?.first?.rows == [[nil], [""], ["NULL"], ["12345678901234567890.123456789"]])
        let limited = await fixture.query(id, limit: 1)
        #expect(limited.results?.first?.rows == [["ok"]] && limited.results?.first?.truncated == true)
        let large = await fixture.query(id, sql: "SELECT LARGE")
        #expect(large.ok && large.results?.first?.rows.count == 1 && large.results?.first?.truncated == true)
        #expect(try JSONEncoder().encode(large).count <= 1_048_576)
        await fixture.coordinator.shutdown()
    }

    @Test func wideThousandRowResponseKeepsLargestExactOrderedPrefix() async throws {
        let fixture = try Fixture(); let id = UUID(); _ = await fixture.hello(id)
        let response = await fixture.query(id, sql: "SELECT MANY", limit: 1000)
        #expect(response.ok)
        let result = try #require(response.results?.first)
        #expect(result.rows.count > 1 && result.rows.count < 1000 && result.truncated)
        #expect(result.rowCount == 1000)
        for (index, row) in result.rows.enumerated() { #expect(row == [String(index) + ":" + String(repeating: "x", count: 8180)]) }
        #expect(try JSONEncoder().encode(response).count <= 1_048_576)
        var extended = response
        extended.results?[0].rows.append([String(result.rows.count) + ":" + String(repeating: "x", count: 8180)])
        #expect(try JSONEncoder().encode(extended).count > 1_048_576)
        await fixture.coordinator.shutdown()
    }

    @Test func rejectsMultipleStatementsAndRedactsBackendErrorsAndAudit() async throws {
        let fixture = try Fixture(); let id = UUID(); _ = await fixture.hello(id)
        #expect(!(await fixture.query(id, sql: "SELECT MULTI")).ok)
        let failed = await fixture.query(id, sql: "SELECT ERROR")
        #expect(!failed.ok)
        let text = String(describing: failed) + String(describing: fixture.coordinator.audit)
        for secret in ["secret_sql", "database-secret", "private-user", "private-authorization", "SELECT ERROR"] { #expect(!text.contains(secret)) }
        #expect(fixture.commands.filter { $0["type"] as? String == "execute" }.count == 1)
        await fixture.coordinator.shutdown()
    }

    @Test func revokeDuringConnectClosesLateSessionAndNeverExecutesOrRegrants() async throws {
        let fixture = try Fixture(); fixture.connectingDelay = true
        let id = UUID(); _ = await fixture.hello(id)
        let task = Task { await fixture.query(id) }
        try await fixture.waitForEntry()
        await fixture.coordinator.revoke(clientID: id)
        try Data().write(to: fixture.release)
        let revokedResponse = await task.value
        #expect(!revokedResponse.ok)
        #expect(fixture.coordinator.clients.isEmpty)
        #expect(!(await fixture.hello(id)).ok && fixture.approvalCalls == 1)
        #expect(fixture.commands.filter { $0["type"] as? String == "execute" }.isEmpty)
        await fixture.coordinator.shutdown()
    }

    @Test func cancellationIsOwnedAndTerminatesBlockedQuery() async throws {
        let fixture = try Fixture(); let id = UUID(), other = UUID()
        _ = await fixture.hello(id); _ = await fixture.hello(other)
        let task = Task { await fixture.query(id, sql: "SELECT BLOCK", queryID: "blocked") }
        try await fixture.waitForEntry()
        let foreign = await fixture.coordinator.handle(clientID: other, request: AgentRequest(id: "foreign", method: "cancel", queryId: "blocked"))
        #expect(foreign.ok)
        #expect(!fixture.commands.contains { $0["type"] as? String == "cancel" })
        let cancelled = await fixture.coordinator.handle(clientID: id, request: AgentRequest(id: "cancel", method: "cancel", queryId: "blocked"))
        let cancelledResponse = await task.value
        #expect(cancelled.ok && !cancelledResponse.ok)
        #expect(fixture.coordinator.audit.last(where: { $0.method == "query" })?.outcome == "cancelled")
        #expect(!(await fixture.query(id, queryID: "blocked")).ok)
        await fixture.coordinator.shutdown()
    }

    @Test func cancellationBeforeQueryAdmissionPreventsAnyCredentialOrBackendAccess() async throws {
        let fixture = try Fixture(); let id = UUID(), other = UUID()
        _ = await fixture.hello(id); _ = await fixture.hello(other)
        let request = AgentRequest(id: "early-cancel", method: "cancel", queryId: "not-admitted-yet")
        let cancelled = await fixture.coordinator.handle(clientID: id, request: request)
        #expect(cancelled.ok)
        let late = await fixture.query(id, queryID: "not-admitted-yet")
        #expect(!late.ok && fixture.settingsCalls == 0 && fixture.commands.isEmpty)
        let repeated = await fixture.coordinator.handle(clientID: id, request: request)
        #expect(repeated.ok)
        let independent = await fixture.query(other, queryID: "not-admitted-yet")
        #expect(independent.ok)
        await fixture.coordinator.shutdown()
    }

    @Test func cancellationTombstonesRespectPerClientIdentifierLimit() async throws {
        let fixture = try Fixture(); let id = UUID(); _ = await fixture.hello(id)
        for index in 0..<4_096 {
            let response = await fixture.coordinator.handle(clientID: id,
                request: AgentRequest(id: "cancel-" + String(index), method: "cancel", queryId: "query-" + String(index)))
            #expect(response.ok)
        }
        let overflow = await fixture.coordinator.handle(clientID: id,
            request: AgentRequest(id: "overflow", method: "cancel", queryId: "one-too-many"))
        #expect(!overflow.ok && fixture.settingsCalls == 0 && fixture.commands.isEmpty)
        let repeated = await fixture.coordinator.handle(clientID: id,
            request: AgentRequest(id: "repeat", method: "cancel", queryId: "query-0"))
        #expect(repeated.ok)
        await fixture.coordinator.shutdown()
    }

    @Test func cancelledSubmittedWriteRetainsUnknownOutcomeInAudit() async throws {
        let fixture = try Fixture(writes: true); let id = UUID(); _ = await fixture.hello(id)
        let task = Task { await fixture.query(id, sql: "DELETE BLOCK", queryID: "write-blocked") }
        try await fixture.waitForEntry()
        _ = await fixture.coordinator.handle(clientID: id, request: AgentRequest(id: "cancel-write", method: "cancel", queryId: "write-blocked"))
        let response = await task.value
        #expect(!response.ok && response.error?.contains("unknown outcome") == true)
        let entry = try #require(fixture.coordinator.audit.last(where: { $0.method == "query" }))
        #expect(entry.outcome == "unknown" && entry.permission == "write")
        await fixture.coordinator.shutdown()
    }

    @Test func revokedOrChangedGrantAfterDangerousConfirmationCannotExecute() async throws {
        for revoke in [false, true] {
            let fixture = try Fixture(writes: true); let id = UUID(); _ = await fixture.hello(id)
            fixture.confirmationHook = {
                if revoke { await fixture.coordinator.revoke(clientID: id) }
                else { fixture.profiles[0].host = "changed-after-review" }
            }
            #expect(!(await fixture.query(id, sql: "DELETE FROM records")).ok)
            #expect(fixture.confirmationCalls == 1)
            #expect(fixture.commands.filter { $0["type"] as? String == "execute" }.isEmpty)
            await fixture.coordinator.shutdown()
        }
    }

    @Test func socketDisconnectWhileApprovalIsPendingCannotCreateGrant() async throws {
        let fixture = try Fixture(); let id = UUID()
        fixture.approvalHook = { await fixture.coordinator.disconnect(clientID: id) }
        #expect(!(await fixture.hello(id)).ok)
        #expect(fixture.coordinator.clients.isEmpty && fixture.commands.isEmpty)
        await fixture.coordinator.shutdown()
    }

    @Test func sharedFixturePreservesExactValuesAndBinaryEncoding() throws {
        struct WireFixture: Decodable { let version: Int; let requests: [AgentRequest]; let responses: [AgentResponse] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/agent-access-v1.json"))
        let fixture = try JSONDecoder().decode(WireFixture.self, from: data)
        #expect(fixture.version == 1)
        #expect(fixture.requests.prefix(5).map(\.method) == ["hello", "connections", "catalog", "query", "cancel"])
        #expect(Set(fixture.requests.map(\.method)) == Set(["hello", "connections", "catalog", "query", "cancel"]))
        let response = try #require(fixture.responses.first { $0.id == "request-query" })
        let result = try #require(response.results?.first)
        #expect(result.rows == [[nil, "", "NULL", "12345678901234567890.123456789", "AP8="]])
        #expect(result.columns.last?.encoding == "base64")
        #expect(try JSONDecoder().decode(AgentResponse.self, from: JSONEncoder().encode(response)).results?.first?.rows == result.rows)
        let connections = try #require(fixture.responses.first { $0.id == "request-list-engines" }?.connections)
        #expect(Set(connections.map(\.engine)) == Set(["postgresql", "mysql", "cassandra", "mongodb"]))
        #expect(connections.first { $0.engine == "cassandra" }?.queryLanguage == "cql")
        #expect(connections.first { $0.engine == "mongodb" }?.readOnlyEnforcement == "local")
        let fields = try #require(fixture.responses.first { $0.id == "request-mongodb-fields" }?.results?.first)
        #expect(fields.affectedRowCountKnown == false && fields.displayNotice?.contains("not a schema") == true)
        let decoded = try JSONDecoder().decode(AgentResult.self, from: JSONEncoder().encode(fields))
        #expect(decoded.affectedRowCountKnown == false && decoded.displayNotice == fields.displayNotice)
    }

    @Test func catalogTablesMapsToAllowlistedHelperObjectsRequest() async throws {
        let fixture = try Fixture(); let id = UUID(); _ = await fixture.hello(id)
        let result = await fixture.coordinator.handle(clientID: id, request: AgentRequest(id: "catalog", method: "catalog",
            profileId: fixture.profiles[0].id.uuidString, queryId: "catalog-tables", kind: "tables", schema: "public"))
        #expect(result.ok)
        let catalog = try #require(fixture.commands.first { $0["type"] as? String == "catalog" }?["catalog"] as? [String: Any])
        #expect(catalog["kind"] as? String == "objects" && catalog["objectKind"] as? String == "table")
        #expect(catalog["schema"] as? String == "public")
        let blocked = await fixture.coordinator.handle(clientID: id, request: AgentRequest(id: "bad", method: "catalog",
            profileId: fixture.profiles[0].id.uuidString, queryId: "catalog-bad", kind: "typeChange"))
        #expect(!blocked.ok)
        #expect(fixture.commands.filter { $0["type"] as? String == "catalog" }.count == 1)
        await fixture.coordinator.shutdown()
    }

    @Test func timeoutClosesBlockedBackendOperation() async throws {
        let fixture = try Fixture(); let id = UUID(); _ = await fixture.hello(id)
        let task = Task { await fixture.coordinator.handle(clientID: id, request: AgentRequest(id: "timeout", method: "query",
            profileId: fixture.profiles[0].id.uuidString, sql: "SELECT BLOCK", queryId: "timed", timeoutSeconds: 1)) }
        try await fixture.waitForEntry()
        let response = await task.value
        #expect(!response.ok && response.error?.contains("cancelled or timed out") == true)
        #expect(fixture.commands.contains { $0["type"] as? String == "shutdown" })
        await fixture.coordinator.shutdown()
    }

    @Test func retiredSocketLimitFailsClosedForExistingAndNewClients() async throws {
        let fixture = try Fixture(); let id = UUID(); _ = await fixture.hello(id)
        for _ in 0..<4_096 { await fixture.coordinator.disconnect(clientID: UUID()) }
        let response = await fixture.coordinator.handle(clientID: id, request: AgentRequest(id: "closed", method: "connections"))
        #expect(!response.ok)
        #expect(!(await fixture.hello(UUID())).ok && fixture.approvalCalls == 1)
        #expect(fixture.coordinator.audit.count <= 200)
        await fixture.coordinator.shutdown()
    }

    @Test func disconnectedSocketCannotApproveAndAuditHasFixedBound() async throws {
        let fixture = try Fixture(); let id = UUID()
        await fixture.coordinator.disconnect(clientID: id)
        #expect(!(await fixture.hello(id)).ok && fixture.approvalCalls == 0)
        for number in 0..<250 {
            _ = await fixture.coordinator.handle(clientID: id, request: AgentRequest(id: String(number), method: "connections"))
        }
        #expect(fixture.coordinator.audit.count == 200)
        await fixture.coordinator.shutdown()
    }
}
