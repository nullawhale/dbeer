import Foundation

enum SQLiteSessionCompletionPolicy {
    /// These statements cannot change the session's catalog. In particular,
    /// BEGIN must not be followed by an implicit catalog read that starts the
    /// user's deferred read snapshot before their first query.
    static func preservesCatalog(_ statements: [SQLStatement]) -> Bool {
        !statements.isEmpty && statements.allSatisfy { statement in
            let parsed = SQLScriptParser.parse(statement.sql, engine: .sqlite)
            guard parsed.diagnostics.isEmpty,
                  let first = parsed.tokens.first(where: { $0.kind != .comment }), first.kind == .keyword else { return false }
            let keyword = (statement.sql as NSString).substring(with: first.range).uppercased()
            return ["SELECT", "VALUES", "WITH", "INSERT", "UPDATE", "DELETE", "REPLACE", "BEGIN", "SAVEPOINT", "RELEASE", "COMMIT", "END", "EXPLAIN"].contains(keyword)
        }
    }
}

/// Ephemeral metadata belongs to one physical SQL session, never the profile.
struct SQLiteSessionCompletion: Sendable {
    let profile: SavedConnection
    let sessionID: String
    let context: SQLCompletionContext
    let notice: String?

    func matches(profile current: SavedConnection?, sessionID: String?) -> Bool {
        self.sessionID == sessionID && ExplainProfileBinding(profile)?.matches(current) == true
    }
}

enum SQLiteSessionCompletionLoader {
    static let maximumPages = 50
    static let pageSize = 200
    static let maximumBytes = 16 * 1_024 * 1_024

    /// The caller supplies an existing session. This loader cannot connect or
    /// replace a query result, and never retains metadata from a previous load.
    @MainActor static func load(profile: SavedConnection, sessionID: String,
                               request: (Int) async throws -> BackendMessage,
                               isCurrent: () -> Bool) async throws -> SQLiteSessionCompletion {
        var records: [[String: String]] = []
        var notice: String?
        var bytes = 0
        for page in 0..<maximumPages {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let reply = try await request(page)
            guard isCurrent() else { throw CancellationError() }
            guard reply.type == "query.result", reply.sessionId == sessionID else { throw BackendTransportError(.invalidMessage) }
            let batch = reply.catalogRecords
            let batchBytes = try JSONEncoder().encode(batch).count
            if batchBytes > maximumBytes - bytes {
                notice = "Some SQLite suggestions are unavailable because metadata was limited."
                break
            }
            bytes += batchBytes
            guard batch.count <= pageSize else { throw BackendTransportError(.invalidMessage) }
            records += batch
            if reply.truncated == true {
                notice = "Some SQLite suggestions are unavailable because metadata was limited."
                break
            }
            if batch.count < pageSize { break }
            if page == maximumPages - 1 {
                notice = "SQLite suggestions include the first 10,000 objects in this session."
            }
        }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        var catalog = SQLCompletionCatalog()
        catalog.record(records, request: CatalogRequest(kind: "completion"), profileID: profile.id)
        var context = catalog.context(profileID: profile.id)
        try orderSessionRelations(&context, records: records)
        return SQLiteSessionCompletion(profile: profile, sessionID: sessionID,
            context: context, notice: notice)
    }

    private struct RelationIdentity: Hashable {
        let schema: Data
        let name: Data
        let kind: Data
        init(schema: String, name: String, kind: String) {
            self.schema = Data(schema.utf8); self.name = Data(name.utf8); self.kind = Data(kind.utf8)
        }
    }

    /// SQLite resolves unqualified names in TEMP, main, then attachment order.
    /// Keep that order through the generic cache, which sorts schemas by name.
    /// Byte keys avoid merging canonically equivalent but distinct identifiers.
    private static func orderSessionRelations(_ context: inout SQLCompletionContext, records: [[String: String]]) throws {
        var schemaFirst: [Data: Int] = [:]
        var schemaRanks: [Data: Int] = [:]
        var relationFirst: [RelationIdentity: Int] = [:]
        for (index, record) in records.enumerated() {
            guard let schema = record["schema"], let name = record["name"], let kind = record["kind"] else { continue }
            let key = Data(schema.utf8)
            if schemaFirst[key] == nil { schemaFirst[key] = schemaFirst.count }
            if let raw = record["schemaOrder"] {
                guard let rank = Int(raw), (0...1_024).contains(rank), String(rank) == raw,
                      schemaRanks[key] == nil || schemaRanks[key] == rank else { throw BackendTransportError(.invalidMessage) }
                schemaRanks[key] = rank
            }
            let relation = RelationIdentity(schema: schema, name: name, kind: kind)
            if relationFirst[relation] == nil { relationFirst[relation] = index }
        }
        func rank(_ schema: String) -> Int {
            let key = Data(schema.utf8)
            if let rank = schemaRanks[key] { return rank }
            let folded = String(decoding: schema.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
            if folded == "temp" { return 0 }
            if folded == "main" { return 1 }
            return 2 + (schemaFirst[key] ?? records.count)
        }
        context.catalog.sort {
            let left = (rank($0.schema), schemaFirst[Data($0.schema.utf8)] ?? records.count,
                relationFirst[RelationIdentity(schema: $0.schema, name: $0.name, kind: $0.kind)] ?? records.count)
            let right = (rank($1.schema), schemaFirst[Data($1.schema.utf8)] ?? records.count,
                relationFirst[RelationIdentity(schema: $1.schema, name: $1.name, kind: $1.kind)] ?? records.count)
            return left < right
        }
    }
}
