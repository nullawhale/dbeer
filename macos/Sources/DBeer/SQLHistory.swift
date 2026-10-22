import Foundation

enum SQLHistoryOutcome: String, Codable, Sendable {
    case succeeded, failed, cancelled, timedOut, unknown

    var label: String {
        switch self {
        case .succeeded: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .timedOut: "Timed out"
        case .unknown: "Unknown outcome"
        }
    }
}

/// A launch-time description, independent of subsequent profile edits/deletion.
/// Deliberately excludes credentials, SSH settings, and local certificate paths.
struct SQLHistoryProfile: Codable, Equatable, Sendable {
    var name: String
    var engine: DatabaseEngine
    var host: String
    var port: Int
    var database: String
    var user: String
    var policy: ExecutionPolicy
    var sslMode: String?
    var contactPoints: [String]?
    var localDatacenter: String?
    var consistency: String?

    init(_ profile: SavedConnection, currentKeyspace: String? = nil) {
        name = profile.name
        engine = profile.engine
        host = profile.host
        port = profile.port
        database = profile.engine == .cassandra ? (currentKeyspace ?? profile.database) : profile.database
        user = profile.user
        policy = profile.policy
        sslMode = profile.sslMode
        if profile.engine == .cassandra {
            contactPoints = profile.contactPoints
            localDatacenter = profile.localDatacenter
            consistency = profile.consistency
        }
    }

    var summary: String {
        let hosts = contactPoints?.joined(separator: ", ") ?? host
        var parts = [name, engine.displayName, "\(user)@\(hosts):\(port)/\(database)", policy.label]
        if let sslMode { parts.append("TLS: \(sslMode)") }
        if let localDatacenter { parts.append("Datacenter: \(localDatacenter)") }
        if let consistency { parts.append("Consistency: \(consistency)") }
        return parts.joined(separator: " · ")
    }
}

/// Only terminal metadata is persisted. No result values or raw driver errors.
struct SQLHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var date: Date
    var documentID: UUID?
    var profileID: UUID?
    var sql: String
    var outcome: SQLHistoryOutcome
    var legacyOutcome: String?
    var profile: SQLHistoryProfile?
    var startedAt: Date?
    var finishedAt: Date?
    var durationMs: Double?
    var loadedRowCount: Int64?
    var affectedRowCount: Int64?
    var exportedRowCount: Int64?
    var truncated: Bool?
    var countsArePartial: Bool?
    var sqlState: String?
    var errorMessage: String?
    var sqlCompleted: Bool?
    var isFavorite: Bool = false

    // Kept for legacy fixtures and migration: a display string proves no typed outcome.
    init(id: UUID = UUID(), date: Date = .now, documentID: UUID? = nil, profileID: UUID? = nil,
         sql: String, outcome: String) {
        self.id = id
        self.date = date
        self.documentID = documentID
        self.profileID = profileID
        self.sql = sql
        self.outcome = .unknown
        legacyOutcome = outcome
    }

    @MainActor
    init?(documentID: UUID, profileID: UUID, profile: SQLHistoryProfile, sql: String,
          completion: WorkspaceModel.QueryCompletion) {
        guard completion.failure?.sqlNotExecuted != true else { return nil }
        id = UUID()
        date = completion.finishedAt
        self.documentID = documentID
        self.profileID = profileID
        self.profile = profile
        self.sql = sql
        startedAt = completion.startedAt
        finishedAt = completion.finishedAt
        durationMs = completion.durationMs
        let reply = completion.reply
        let failure = completion.failure
        if failure?.outcomeUnknown == true || reply?.outcomeUnknown == true { outcome = .unknown }
        else if failure?.category == "cancelled" { outcome = .cancelled }
        else if failure?.category == "timeout" { outcome = .timedOut }
        else if failure != nil { outcome = .failed }
        else { outcome = .succeeded }
        sqlCompleted = reply?.sqlCompleted == true || (reply?.type == "query.result" && reply?.outcomeUnknown != true)
        sqlState = failure?.sqlState.flatMap { state in
            state.utf8.count == 5 && state.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) } ? state : nil
        }
        // Server diagnostics can echo literals, row values, paths, or object
        // names. Persist a fixed explanation instead of the transient message.
        errorMessage = failure.map { Self.safeErrorMessage(category: $0.category, sqlState: sqlState) }
        exportedRowCount = reply?.exportRowCount
        if let reply {
            // These fixed helper notices explicitly describe omitted result
            // summaries, not merely a row display limit within a retained set.
            let omittedResults = [reply.displayNotice].compactMap { $0 }.contains { notice in
                notice.contains("Additional result sets exceeded") || notice.contains("Later result metadata was omitted")
            }
            let sets: [QueryResultSet]
            if let results = reply.resultSets, !results.isEmpty { sets = results }
            else if reply.type == "query.result", let count = reply.displayedRowCount {
                sets = [QueryResultSet(columns: reply.columns ?? [], commandTag: reply.commandTag ?? "",
                    rowCount: reply.rowCount ?? 0, displayedRowCount: count, truncated: reply.truncated == true,
                    affectedRowCountKnown: reply.affectedRowCountKnown)]
            } else { sets = [] }
            if !sets.isEmpty {
                loadedRowCount = Self.sum(sets.map { Int64($0.displayedRowCount) })
                let affected = sets.filter { set in
                    let verb = set.commandTag.split(separator: " ").first.map(String.init) ?? ""
                    return ["INSERT", "UPDATE", "DELETE", "MERGE", "OK"].contains(verb)
                }
                if !omittedResults, !affected.isEmpty, affected.allSatisfy({ $0.affectedRowCountKnown != false }) {
                    affectedRowCount = Self.sum(affected.map(\.rowCount))
                }
                truncated = reply.truncated == true || omittedResults || sets.contains(where: \.truncated)
                countsArePartial = failure != nil || omittedResults
            }
            if omittedResults { truncated = true; countsArePartial = true }
        }
    }

    private static func sum(_ counts: [Int64]) -> Int64? {
        var total: Int64 = 0
        for count in counts {
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    private static func safeErrorMessage(category: String, sqlState: String?) -> String {
        switch category {
        case "cancelled": return "Execution was cancelled."
        case "timeout": return "Execution exceeded its time limit."
        case "connection", "transport", "ssh": return "The database or helper connection was lost."
        case "export": return "The result could not be saved to the export file."
        case "policy": return "The execution policy rejected this command."
        default: break
        }
        switch sqlState?.prefix(2) {
        case "22": return "The database rejected a value or expression."
        case "23": return "The command violated a database constraint."
        case "40": return "The transaction could not complete because of a conflict."
        case "42": return "The database rejected the command's syntax, object reference, or permissions."
        default: return "The database could not complete the command."
        }
    }

    var outcomeLabel: String { legacyOutcome.map { "Legacy: \($0) (details unavailable)" } ?? outcome.label }

    var executionSummary: String {
        var parts = [durationMs.map { "\($0.formatted(.number.precision(.fractionLength(1)))) ms" } ?? "Duration unavailable"]
        parts.append(loadedRowCount.map { "\($0) loaded rows" } ?? "Loaded rows unavailable")
        parts.append(affectedRowCount.map { "\($0) affected rows" } ?? "Affected rows not reported")
        if let exportedRowCount { parts.append("\(exportedRowCount) exported rows") }
        return parts.joined(separator: " · ")
    }

    var isValid: Bool {
        date.timeIntervalSince1970.isFinite &&
            [startedAt, finishedAt].allSatisfy { $0?.timeIntervalSince1970.isFinite != false } &&
            (durationMs.map { $0.isFinite && $0 >= 0 } ?? true) &&
            [loadedRowCount, affectedRowCount, exportedRowCount].allSatisfy { $0.map { $0 >= 0 } ?? true }
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, documentID, profileID, sql, outcome, legacyOutcome, profile, startedAt, finishedAt, durationMs
        case loadedRowCount, affectedRowCount, exportedRowCount, truncated, countsArePartial, sqlState, errorMessage, sqlCompleted
        case isFavorite
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        date = try values.decode(Date.self, forKey: .date)
        documentID = try values.decodeIfPresent(UUID.self, forKey: .documentID)
        profileID = try values.decodeIfPresent(UUID.self, forKey: .profileID)
        sql = try values.decode(String.self, forKey: .sql)
        profile = try values.decodeIfPresent(SQLHistoryProfile.self, forKey: .profile)
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try values.decodeIfPresent(Date.self, forKey: .finishedAt)
        durationMs = try values.decodeIfPresent(Double.self, forKey: .durationMs)
        loadedRowCount = try values.decodeIfPresent(Int64.self, forKey: .loadedRowCount)
        affectedRowCount = try values.decodeIfPresent(Int64.self, forKey: .affectedRowCount)
        exportedRowCount = try values.decodeIfPresent(Int64.self, forKey: .exportedRowCount)
        truncated = try values.decodeIfPresent(Bool.self, forKey: .truncated)
        countsArePartial = try values.decodeIfPresent(Bool.self, forKey: .countsArePartial)
        sqlState = try values.decodeIfPresent(String.self, forKey: .sqlState)
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
        sqlCompleted = try values.decodeIfPresent(Bool.self, forKey: .sqlCompleted)
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        let stored = try values.decode(String.self, forKey: .outcome)
        legacyOutcome = try values.decodeIfPresent(String.self, forKey: .legacyOutcome)
        if let typed = SQLHistoryOutcome(rawValue: stored) { outcome = typed }
        else { outcome = .unknown; legacyOutcome = stored }
    }
}
