import Foundation

/// A terminal execution owns its historical context and the server-loaded
/// values. Editor changes, profile changes and grid drafts cannot rewrite it.
struct ResultSnapshotSource: Sendable {
    let sql: String
    let profileID: UUID?
    let profile: SQLHistoryProfile
    let finishedAt: Date
    let outcome: SQLHistoryOutcome
    let result: BackendMessage
    let isPartial: Bool

    init?(sql: String, profileID: UUID?, profile: SQLHistoryProfile,
          completion: WorkspaceModel.QueryCompletion, isTablePage: Bool = false) {
        guard !sql.isEmpty, completion.failure?.sqlNotExecuted != true,
              let result = completion.reply,
              result.columns?.isEmpty == false || result.resultSets?.contains(where: { !$0.columns.isEmpty }) == true else { return nil }
        self.sql = sql
        self.profileID = profileID
        self.profile = profile
        finishedAt = completion.finishedAt
        if completion.failure?.outcomeUnknown == true || result.outcomeUnknown == true { outcome = .unknown }
        else if completion.failure?.category == "cancelled" { outcome = .cancelled }
        else if completion.failure?.category == "timeout" { outcome = .timedOut }
        else if completion.failure != nil { outcome = .failed }
        else { outcome = .succeeded }
        self.result = result
        isPartial = isTablePage || completion.failure != nil || outcome != .succeeded
    }

    func capture(title: String, resultSetIndex: Int) -> ResultSnapshotCapture? {
        guard let displayed = Self.project(result, resultSetIndex: resultSetIndex),
              let columns = displayed.columns, !columns.isEmpty else { return nil }
        return ResultSnapshotCapture(title: title, sql: sql, engine: profile.engine,
            columns: columns, rows: displayed.rows ?? [], capturedAt: finishedAt,
            profileID: profileID, profileName: profile.name, environment: profile.policy.environment,
            outcome: outcome, truncated: displayed.truncated == true,
            partial: isPartial || displayed.nextCursor != nil,
            sourceRowCount: displayed.rowCount, commandTag: displayed.commandTag ?? "")
    }

    /// Shared with presentation so Pin always captures the selected set rather
    /// than the aggregate result or the last set returned by a script.
    static func project(_ message: BackendMessage, resultSetIndex: Int) -> BackendMessage? {
        var projected = message
        if let sets = message.resultSets, !sets.isEmpty {
            guard sets.indices.contains(resultSetIndex) else { return nil }
            let set = sets[resultSetIndex]
            projected.columns = set.columns
            projected.rows = set.rows
            projected.commandTag = set.commandTag
            projected.rowCount = set.rowCount
            projected.displayedRowCount = set.displayedRowCount
            projected.truncated = set.truncated
            projected.displayNotice = set.displayNotice
            projected.affectedRowCountKnown = set.affectedRowCountKnown
            projected.nextCursor = set.nextCursor
            projected.storageTokens = set.storageTokens
        } else if resultSetIndex != 0 { return nil }
        return projected
    }
}
