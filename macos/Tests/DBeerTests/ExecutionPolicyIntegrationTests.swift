import Foundation
import Testing
@testable import DBeer

/// Exercise the installed helper's complete Swift/framed-protocol/database path.
/// Policy failures must be returned before either SQL execution or export I/O.
@Suite(.serialized)
@MainActor
struct ExecutionPolicyIntegrationTests {
    private final class Decision {
        var allow = false
        var confirmations: [OperationConfirmation] = []
    }
    private var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresNativeAndHelperEnforcePolicyAndExactGrants() async throws { try await exercise(.postgresql) }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlNativeAndHelperEnforcePolicyAndExactGrants() async throws { try await exercise(.mysql) }

    private func settings(_ engine: DatabaseEngine) throws -> ConnectionSettings {
        let env = ProcessInfo.processInfo.environment
        if engine == .mysql {
            return ConnectionSettings(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
                port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")),
                database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: env["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
                password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: env["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable",
                sslRootCert: env["DBEER_TEST_MYSQL_CA_FILE"], engine: .mysql, policy: ExecutionPolicy(environment: .production))
        }
        let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
        return ConnectionSettings(host: try #require(url.host), port: url.port ?? 5432,
            database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "",
            sslMode: "disable", policy: ExecutionPolicy(environment: .production))
    }

    private func command(_ operation: OperationRequest, session: String, authorization: String? = nil) -> BackendCommand {
        var result = BackendCommand(type: operation.type, requestId: UUID().uuidString, sessionId: session,
            queryId: UUID().uuidString, sql: operation.sql, export: operation.export, changes: operation.changes)
        result.authorization = authorization
        return result
    }

    private func grant(_ operation: OperationRequest, session: String, client: BackendClient, decision: String = "confirm") async throws -> String {
        let reply = try await client.request(.assess(sessionId: session, operations: [operation]))
        let assessment = try #require(reply.assessment)
        #expect(assessment.decision == decision)
        return try #require(assessment.authorization)
    }

    private func approved(_ operation: OperationRequest, session: String, client: BackendClient) async throws -> BackendMessage {
        let authorization = try await grant(operation, session: session, client: client)
        return try await client.request(command(operation, session: session, authorization: authorization))
    }

    private func denied(_ command: BackendCommand, client: BackendClient) async throws {
        do {
            _ = try await client.request(command)
            Issue.record("A policy-rejected operation reached execution")
        } catch let error as BackendRemoteError {
            #expect(error.reply.category == "policy")
            #expect(error.reply.connected == true && error.reply.outcomeUnknown == false)
            #expect(error.reply.transactionStatus == .idle)
        }
    }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let client = BackendClient(executableURL: executable)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-policy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try settings(engine)
        let table = "dbeer_policy_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let schema = engine == .postgresql ? "public" : settings.database
        var connected: String?
        let decision = Decision()
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            closeDecision: { _ in .rollback }, executionDecision: { decision.confirmations.append($0); return decision.allow },
            helperFactory: { BackendClient(executableURL: executable) })
        do {
            try await client.start()
            let session = try #require(try await client.request(.connect(settings)).sessionId)
            connected = session
            let other = try #require(try await client.request(.connect(settings)).sessionId)
            let create = OperationRequest(type: "execute", sql: "CREATE TABLE \(table) (id integer PRIMARY KEY, label varchar(80))")
            try await denied(command(create, session: session), client: client)
            _ = try await approved(create, session: session, client: client)
            _ = try await approved(OperationRequest(type: "execute", sql: "INSERT INTO \(table) VALUES (1,'original')"), session: session, client: client)

            var readonly = settings
            readonly.policy.readOnly = true
            let readonlySession = try #require(try await client.request(.connect(readonly)).sessionId)
            let mode = try await client.request(.execute(sessionId: readonlySession,
                sql: engine == .postgresql ? "SHOW default_transaction_read_only" : "SELECT @@session.transaction_read_only"))
            #expect(mode.rows == [[engine == .postgresql ? "on" : "1"]])
            #expect(try await client.request(.execute(sessionId: readonlySession, sql: "SELECT 1")).rows == [["1"]])

            let data = try await client.request(.execute(sessionId: session, sql: "SELECT id,label FROM \(table)"))
            let metadata = try await client.request(.catalog(sessionId: session,
                request: CatalogRequest(kind: "columns", schema: schema, object: table, objectKind: "table")))
            let snapshotGrid = GridDraft(reference: TableReference(schema: schema, name: table, kind: "table"),
                result: data, metadata: metadata.catalogRecords)
            try #require(snapshotGrid.canEdit)
            snapshotGrid.set(ChangeValue(kind: "text", value: "applied"), row: 0, column: 1)
            let changes = snapshotGrid.request()
            let export = directory.appendingPathComponent("protected.json")
            let sentinel = Data("existing file must survive policy denial".utf8)
            try sentinel.write(to: export)
            let blocked = [
                OperationRequest(type: "execute", sql: "UPDATE \(table) SET label='denied'"),
                OperationRequest(type: "execute", sql: "DELETE FROM \(table)"),
                OperationRequest(type: "execute", sql: "SELECT dbeer_policy_unknown_function()"),
                OperationRequest(type: "execute", sql: "DELETE FROM \(table)", export: ExportRequest(path: export.path, format: "json")),
                OperationRequest(type: "changes.apply", changes: changes),
            ]
            for operation in blocked {
                let assessment = try await client.request(.assess(sessionId: readonlySession, operations: [operation]))
                #expect(assessment.assessment?.decision == "deny" && assessment.assessment?.authorization == nil)
                try await denied(command(operation, session: readonlySession), client: client)
            }
            #expect(try Data(contentsOf: export) == sentinel)
            #expect(try await client.request(.execute(sessionId: session, sql: "SELECT label FROM \(table)")).rows == [["original"]])
            let readonlyExport = directory.appendingPathComponent("readonly-read.json")
            let readonlyResult = try await client.request(.runToFile(sessionId: readonlySession, sql: "SELECT id,label FROM \(table)",
                export: ExportRequest(path: readonlyExport.path, format: "json")))
            #expect(readonlyResult.exportRowCount == 1 && FileManager.default.fileExists(atPath: readonlyExport.path))

            // Changed SQL invalidates the original grant; another session cannot
            // use it either, and even a successful exact operation is single-use.
            let update = OperationRequest(type: "execute", sql: "UPDATE \(table) SET label='confirmed' WHERE id=1")
            var token = try await grant(update, session: session, client: client)
            try await denied(command(update, session: other, authorization: token), client: client)
            var modified = update
            modified.sql = "UPDATE \(table) SET label='changed' WHERE id=1"
            try await denied(command(modified, session: session, authorization: token), client: client)
            try await denied(command(update, session: session, authorization: token), client: client)
            token = try await grant(update, session: session, client: client)
            _ = try await client.request(command(update, session: session, authorization: token))
            try await denied(command(update, session: session, authorization: token), client: client)

            let exportOperation = OperationRequest(type: "execute", sql: "SELECT id,label FROM \(table)", export: ExportRequest(path: export.path, format: "json"))
            token = try await grant(exportOperation, session: session, client: client, decision: "allow")
            var changedExport = exportOperation
            changedExport.export?.path = directory.appendingPathComponent("changed.json").path
            try await denied(command(changedExport, session: session, authorization: token), client: client)
            #expect(!FileManager.default.fileExists(atPath: try #require(changedExport.export?.path)))
            #expect(try Data(contentsOf: export) == sentinel)
            token = try await grant(exportOperation, session: session, client: client, decision: "allow")
            let exported = try await client.request(command(exportOperation, session: session, authorization: token))
            #expect(exported.exportPath == export.path && exported.exportRowCount == 1)
            try await denied(command(exportOperation, session: session, authorization: token), client: client)

            var apply = OperationRequest(type: "changes.apply", changes: changes)
            apply.changes?.changes[0].original?[1] = ChangeValue(kind: "text", value: "confirmed")
            try await denied(command(apply, session: session), client: client)
            token = try await grant(apply, session: session, client: client)
            var changedApply = apply
            changedApply.changes?.changes[0].values?[0].value.value = "changed snapshot"
            try await denied(command(changedApply, session: session, authorization: token), client: client)
            token = try await grant(apply, session: session, client: client)
            _ = try await client.request(command(apply, session: session, authorization: token))
            try await denied(command(apply, session: session, authorization: token), client: client)
            #expect(try await client.request(.execute(sessionId: session, sql: "SELECT label FROM \(table)")).rows == [["applied"]])

            // Native cancellation uses the same real helper and leaves the DB
            // unchanged. Approval then permits exactly the displayed operation.
            await workspace.start()
            try #require(await workspace.library.saveConnection(name: "Production \(engine.displayName)", settings: settings))
            let document = workspace.newDocument(profileID: workspace.library.selectedConnectionId, text: "UPDATE \(table) SET label='native' WHERE id=1")
            await workspace.run(document)
            #expect(decision.confirmations.count == 1)
            #expect(decision.confirmations.first?.operations.first?.sql == document.text)
            #expect(document.executions.last?.status == "Not executed")
            #expect(try await client.request(.execute(sessionId: session, sql: "SELECT label FROM \(table)")).rows == [["applied"]])
            decision.allow = true
            await workspace.run(document)
            #expect(decision.confirmations.count == 2)
            #expect(document.runtime?.queryFailure == nil)
            #expect(try await client.request(.execute(sessionId: session, sql: "SELECT label FROM \(table)")).rows == [["native"]])

            try #require(await workspace.library.saveConnection(name: "Readonly \(engine.displayName)", settings: readonly))
            let readonlyProfile = try #require(workspace.library.selectedConnectionId)
            await workspace.openData(CatalogNode(profileID: readonlyProfile, name: table, kind: .object,
                schema: schema, object: table, objectKind: "table"))
            let grid = try #require(workspace.selectedDocument?.grid)
            #expect(!grid.canEdit && grid.policyReadOnly)
            grid.set(ChangeValue(kind: "text", value: "blocked native grid"), row: 0, column: 1)
            grid.insert()
            grid.selectedRows = [0]
            grid.deleteSelected()
            #expect(grid.pendingCount == 0)
            #expect(decision.confirmations.count == 2)
            await workspace.shutdown()
            _ = try await approved(OperationRequest(type: "execute", sql: "DROP TABLE \(table)"), session: session, client: client)
            connected = nil
            #expect(await client.shutdown().acknowledged)
        } catch {
            await workspace.shutdown()
            if let session = connected {
                _ = try? await approved(OperationRequest(type: "execute", sql: "DROP TABLE IF EXISTS \(table)"), session: session, client: client)
            }
            _ = await client.shutdown()
            throw error
        }
    }
}
