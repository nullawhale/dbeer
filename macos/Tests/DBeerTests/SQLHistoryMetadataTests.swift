import Foundation
import Testing
@testable import DBeer

// Pure metadata and serialization coverage; no application, windows, or desktop input.
@MainActor
struct SQLHistoryMetadataTests {
    private func profile(engine: DatabaseEngine = .postgresql) -> SavedConnection {
        SavedConnection(name: "Production analytics", settings: ConnectionSettings(
            host: "db.example.test", port: engine.defaultPort, database: "original_database", user: "analyst",
            password: "database-password-sentinel", sslMode: "verify-full", engine: engine,
            policy: ExecutionPolicy(environment: .production)))
    }

    private func entry(_ reply: BackendMessage?, failure: WorkspaceModel.QueryFailure? = nil,
                       profile saved: SavedConnection? = nil, currentKeyspace: String? = nil) throws -> SQLHistoryEntry {
        let saved = saved ?? profile()
        return try #require(SQLHistoryEntry(documentID: UUID(), profileID: saved.id,
            profile: SQLHistoryProfile(saved, currentKeyspace: currentKeyspace), sql: "SELECT fixture_value FROM fixture",
            completion: WorkspaceModel.QueryCompletion(startedAt: Date(timeIntervalSince1970: 1_000),
                finishedAt: Date(timeIntervalSince1970: 1_002), durationMs: 125.5, reply: reply, failure: failure)))
    }

    @Test func mirroredPrimaryResultIsCountedOnceAcrossMultipleResults() throws {
        let reply = BackendMessage(type: "query.result", requestId: "fixture",
            commandTag: "UPDATE 4", rowCount: 4, displayedRowCount: 2, truncated: false,
            resultSets: [
                QueryResultSet(commandTag: "UPDATE 4", rowCount: 4, displayedRowCount: 2),
                QueryResultSet(commandTag: "SELECT 1000", rowCount: 1_000, displayedRowCount: 3, truncated: true),
                QueryResultSet(commandTag: "DELETE 6", rowCount: 6)
            ])
        let result = try entry(reply)
        #expect(result.loadedRowCount == 5)
        #expect(result.affectedRowCount == 10)
        #expect(result.truncated == true)
        #expect(result.countsArePartial == false)
    }

    @Test func selectCommandCountDoesNotBecomeAnAffectedOrLoadedTotal() throws {
        let reply = BackendMessage(type: "query.result", requestId: "fixture", commandTag: "SELECT 1000000",
            rowCount: 1_000_000, displayedRowCount: 2, truncated: true)
        let result = try entry(reply)
        #expect(result.loadedRowCount == 2)
        #expect(result.affectedRowCount == nil)
        #expect(result.truncated == true)
        #expect(!result.executionSummary.contains("1000000"))
    }

    @Test func returningPreservesLoadedAndAffectedCountsIndependently() throws {
        let reply = BackendMessage(type: "query.result", requestId: "fixture", commandTag: "UPDATE 25",
            rowCount: 25, displayedRowCount: 3, truncated: true, affectedRowCountKnown: true)
        let result = try entry(reply)
        #expect(result.loadedRowCount == 3)
        #expect(result.affectedRowCount == 25)
        #expect(result.sqlCompleted == true)
    }

    @Test func cassandraUnknownAffectedCountRetainsSelectedKeyspace() throws {
        let saved = profile(engine: .cassandra)
        let reply = BackendMessage(type: "query.result", requestId: "fixture", commandTag: "UPDATE",
            rowCount: 0, displayedRowCount: 0, truncated: false, affectedRowCountKnown: false)
        let result = try entry(reply, profile: saved, currentKeyspace: "selected_keyspace")
        #expect(result.profile?.engine == .cassandra)
        #expect(result.profile?.database == "selected_keyspace")
        #expect(saved.database == "original_database")
        #expect(result.loadedRowCount == 0)
        #expect(result.affectedRowCount == nil)
        #expect(result.truncated == false)
    }

    @Test(arguments: [DatabaseEngine.postgresql, .mysql])
    func relationalProfilesRetainTheirDatabaseWhenAKeyspaceIsSupplied(engine: DatabaseEngine) throws {
        let saved = profile(engine: engine)
        let snapshot = SQLHistoryProfile(saved, currentKeyspace: "unrelated_keyspace")
        #expect(snapshot.database == "original_database")
        #expect(snapshot.engine == engine)
    }

    @Test func omittedMySQLResultSetsMakeAggregateCountsPartialAndAffectedTotalUnknown() throws {
        let reply = BackendMessage(type: "query.result", requestId: "fixture", commandTag: "OK",
            rowCount: 5, displayedRowCount: 1, truncated: false,
            displayNotice: "Additional result sets exceeded the display limit and were drained without retaining data.",
            affectedRowCountKnown: true, resultSets: [
                QueryResultSet(commandTag: "OK", rowCount: 5, displayedRowCount: 1, affectedRowCountKnown: true)
            ])
        let result = try entry(reply, profile: profile(engine: .mysql))
        #expect(result.outcome == .succeeded)
        #expect(result.loadedRowCount == 1)
        #expect(result.affectedRowCount == nil)
        #expect(result.countsArePartial == true)
        #expect(result.truncated == true)
    }

    @Test func exportedRowsAreSeparateFromRowsLoadedIntoTheGrid() throws {
        let reply = BackendMessage(type: "query.result", requestId: "fixture", commandTag: "SELECT 50000",
            rowCount: 50_000, displayedRowCount: 200, truncated: true,
            exportPath: "/synthetic/export-destination.csv", exportFormat: "csv", exportRowCount: 50_000)
        let result = try entry(reply)
        #expect(result.loadedRowCount == 200)
        #expect(result.exportedRowCount == 50_000)
        #expect(result.affectedRowCount == nil)
        #expect(result.executionSummary.contains("200 loaded rows"))
        #expect(result.executionSummary.contains("50000 exported rows"))
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!json.contains("export-destination"))
    }

    @Test func partialFailureKeepsKnownRowsAndSafeTerminalDiagnostics() throws {
        let reply = BackendMessage(type: "error", requestId: "fixture", resultSets: [
            QueryResultSet(commandTag: "UPDATE 2", rowCount: 2),
            QueryResultSet(commandTag: "SELECT 100", rowCount: 100, displayedRowCount: 4, truncated: true)
        ])
        let failure = WorkspaceModel.QueryFailure(category: "sql", message: "The statement could not be completed.",
            sqlState: "23505", outcomeUnknown: false)
        let result = try entry(reply, failure: failure)
        #expect(result.outcome == .failed)
        #expect(result.sqlCompleted == false)
        #expect(result.loadedRowCount == 4)
        #expect(result.affectedRowCount == 2)
        #expect(result.countsArePartial == true)
        #expect(result.sqlState == "23505")
        #expect(result.errorMessage?.isEmpty == false)
        #expect(result.startedAt == Date(timeIntervalSince1970: 1_000))
        #expect(result.finishedAt == Date(timeIntervalSince1970: 1_002))
        #expect(result.durationMs == 125.5)
    }

    @Test func missingMetricsStayUnknownWhileReportedZeroStaysZero() throws {
        let failure = WorkspaceModel.QueryFailure(category: "transport", message: "Connection lost.",
            sqlState: nil, outcomeUnknown: true)
        let unknown = try entry(nil, failure: failure)
        #expect(unknown.outcome == .unknown)
        #expect(unknown.loadedRowCount == nil)
        #expect(unknown.affectedRowCount == nil)
        #expect(unknown.exportedRowCount == nil)
        #expect(unknown.truncated == nil)
        #expect(unknown.countsArePartial == nil)

        let zero = try entry(BackendMessage(type: "query.result", requestId: "fixture", commandTag: "UPDATE 0",
            rowCount: 0, displayedRowCount: 0, truncated: false, affectedRowCountKnown: true))
        #expect(zero.outcome == .succeeded)
        #expect(zero.loadedRowCount == 0)
        #expect(zero.affectedRowCount == 0)
        #expect(zero.truncated == false)
        #expect(zero.countsArePartial == false)
    }

    @Test func overflowingTotalsBecomeUnknownWithoutWrappingOrLosingOtherMetrics() throws {
        let overflowingAffected = BackendMessage(type: "query.result", requestId: "fixture", resultSets: [
            QueryResultSet(commandTag: "UPDATE", rowCount: .max, displayedRowCount: 1),
            QueryResultSet(commandTag: "DELETE 1", rowCount: 1, displayedRowCount: 2)
        ])
        let affected = try entry(overflowingAffected)
        #expect(affected.affectedRowCount == nil)
        #expect(affected.loadedRowCount == 3)
        #expect(affected.isValid)

        let overflowingLoaded = BackendMessage(type: "query.result", requestId: "fixture", resultSets: [
            QueryResultSet(commandTag: "UPDATE 2", rowCount: 2, displayedRowCount: .max),
            QueryResultSet(commandTag: "DELETE 3", rowCount: 3, displayedRowCount: 1)
        ])
        let loaded = try entry(overflowingLoaded)
        #expect(loaded.loadedRowCount == nil)
        #expect(loaded.affectedRowCount == 5)
        #expect(loaded.isValid)
    }

    @Test func serializationIncludesExecutionSnapshotWithoutCredentialsTransportOrResultValues() throws {
        var saved = profile()
        saved.sslRootCert = "/synthetic/tls/certificate-path-sentinel.pem"
        // Newer profile schemas may recognize additional transport settings;
        // the history snapshot must remain an explicit nonsecret allowlist.
        var profileJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        profileJSON["ssh"] = ["host": "ssh-host-sentinel.example.test", "port": 22, "user": "ssh-user-sentinel",
            "authMethod": "privateKey", "identityFile": "/synthetic/ssh/private-key-sentinel"]
        saved = try JSONDecoder().decode(SavedConnection.self, from: JSONSerialization.data(withJSONObject: profileJSON))
        let reply = BackendMessage(type: "query.result", requestId: "fixture",
            columns: [ResultColumn(index: 0, name: "result-column-sentinel", typeOid: 25)],
            rows: [["result-value-sentinel"]], commandTag: "SELECT 1", rowCount: 1, displayedRowCount: 1, truncated: false)
        let result = try entry(reply, profile: saved)
        let data = try JSONEncoder().encode(result)
        let json = String(decoding: data, as: UTF8.self)
        for sentinel in ["database-password-sentinel", "certificate-path-sentinel", "ssh-host-sentinel",
                         "ssh-user-sentinel", "private-key-sentinel", "result-column-sentinel", "result-value-sentinel"] {
            #expect(!json.contains(sentinel))
        }
        let decoded = try JSONDecoder().decode(SQLHistoryEntry.self, from: data)
        #expect(decoded == result)
        #expect(decoded.profile?.name == saved.name)
        #expect(decoded.profile?.host == saved.host)
        #expect(decoded.profile?.port == saved.port)
        #expect(decoded.profile?.user == saved.user)
        #expect(decoded.profile?.policy == saved.policy)
    }

    @Test(arguments: ["sql", "export", "transport", "connection", "timeout", "cancelled", "policy", "unrecognized"])
    func terminalDescriptionsExcludeRawRemoteDiagnostics(category: String) throws {
        let rawMessage = "Driver diagnostic contains 'sql-literal-sentinel' and 'credential-sentinel'."
        let failure = WorkspaceModel.QueryFailure(category: category, message: rawMessage,
            sqlState: category == "sql" ? "23505" : nil, outcomeUnknown: category == "transport")
        let result = try entry(BackendMessage(type: "error", requestId: "fixture"), failure: failure)
        #expect(result.errorMessage?.isEmpty == false)
        #expect(result.errorMessage != rawMessage)
        #expect(result.sqlState == failure.sqlState)
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!json.contains("sql-literal-sentinel"))
        #expect(!json.contains("credential-sentinel"))
    }

    @Test(arguments: ["Completed", "Cancelled", "Timed out", "future-outcome", "Ошибка 😀"])
    func untypedLegacyOutcomeSurvivesRoundTripWithoutInventedMetadata(outcome: String) throws {
        let legacy = SQLHistoryEntry(id: UUID(), date: Date(timeIntervalSince1970: 1_000),
            documentID: UUID(), profileID: UUID(), sql: "SELECT '😀'", outcome: outcome)
        var stored = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        stored["outcome"] = outcome
        stored.removeValue(forKey: "legacyOutcome")
        let decoded = try JSONDecoder().decode(SQLHistoryEntry.self, from: JSONSerialization.data(withJSONObject: stored))
        #expect(decoded == legacy)
        #expect(try JSONDecoder().decode(SQLHistoryEntry.self, from: JSONEncoder().encode(decoded)) == legacy)
        #expect(decoded.outcome == .unknown)
        #expect(decoded.legacyOutcome == outcome)
        #expect(decoded.outcomeLabel.contains(outcome))
        #expect(decoded.profile == nil)
        #expect(decoded.startedAt == nil && decoded.finishedAt == nil && decoded.durationMs == nil)
        #expect(decoded.loadedRowCount == nil && decoded.affectedRowCount == nil && decoded.exportedRowCount == nil)
        #expect(decoded.truncated == nil && decoded.countsArePartial == nil && decoded.sqlCompleted == nil)
        #expect(decoded.sqlState == nil && decoded.errorMessage == nil)
    }
}
