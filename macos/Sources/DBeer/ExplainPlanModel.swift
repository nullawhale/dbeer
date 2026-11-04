import Foundation


/// Freeze the exact credential-free profile representation. Swift String and
/// synthesized profile equality intentionally accept canonical equivalents;
/// database names, user names and file paths need byte-exact binding instead.
struct ExplainProfileBinding: Sendable {
    let profile: SavedConnection
    private let encodedProfile: Data

    init?(_ profile: SavedConnection) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(profile) else { return nil }
        self.profile = profile
        encodedProfile = encoded
    }

    func matches(_ current: SavedConnection?) -> Bool {
        guard let current, let candidate = Self(current) else { return false }
        return encodedProfile == candidate.encodedProfile
    }

    @MainActor func matchesRuntime(_ runtime: WorkspaceModel) -> Bool {
        guard let port = Int(runtime.port) else { return false }
        let settings = ConnectionSettings(host: runtime.host, port: port, database: runtime.database,
            user: runtime.user, password: "", sslMode: runtime.sslMode,
            sslRootCert: runtime.sslRootCert.isEmpty && profile.sslRootCert == nil ? nil : runtime.sslRootCert,
            engine: runtime.engine, policy: runtime.policy, contactPoints: runtime.contactPoints,
            localDatacenter: runtime.localDatacenter, consistency: runtime.consistency,
            ssh: runtime.ssh, passwordCommand: runtime.passwordCommand, mongodb: runtime.mongodb, sqlite: runtime.sqlite)
        return matches(SavedConnection(id: profile.id, name: profile.name, settings: settings))
    }
}

/// Transient source-bound evidence. Never included in document persistence,
/// SQL history, result snapshots or diagnostics.
struct ExplainPlanModel {
    let id = UUID()
    var request: ExplainRequest
    var sourceText: String
    var sourceRange: NSRange
    var profileID: UUID
    var profile: SavedConnection?
    var profileBinding: ExplainProfileBinding?
    var sessionID: String?
    var result: ExplainResult?
    var status = "Starting"
    var clientDurationMs: Double?
    var failure: WorkspaceModel.QueryFailure?

    func isStale(text: String, profileID: UUID?, profile: SavedConnection? = nil) -> Bool {
        let changedProfile: Bool
        if let profileBinding { changedProfile = !profileBinding.matches(profile) }
        else if let captured = self.profile { changedProfile = ExplainProfileBinding(captured)?.matches(profile) != true }
        else { changedProfile = false }
        return !sourceText.utf8.elementsEqual(text.utf8) || self.profileID != profileID || changedProfile
    }
    static func request(fragment: SQLExecutionFragment, mode: ExplainMode, engine: DatabaseEngine = .postgresql) throws -> ExplainRequest {
        if let diagnostic = fragment.diagnostic { throw ExecutionPolicyError(message: diagnostic.message) }
        guard fragment.kind != .script, fragment.statements.count == 1 else {
            throw ExecutionPolicyError(message: "Explain requires exactly one selected or current statement.")
        }
        let request = ExplainRequest(sql: fragment.statements[0].sql, mode: mode)
        let parsed = SQLScriptParser.parse(request.sql, engine: engine)
        let tokens = parsed.tokens.filter { $0.kind != .comment }
        guard let first = tokens.first, first.kind == .keyword,
              ["SELECT", "WITH"].contains((request.sql as NSString).substring(with: first.range).uppercased()) else {
            throw ExecutionPolicyError(message: "Explain requires an unwrapped SELECT or WITH … SELECT statement.")
        }
        var prefix = (request.sql as NSString).substring(to: first.range.location)
        for comment in parsed.tokens.filter({ $0.kind == .comment && NSMaxRange($0.range) <= first.range.location }).reversed() {
            prefix = (prefix as NSString).replacingCharacters(in: comment.range, with: "")
        }
        guard prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExecutionPolicyError(message: "Explain does not accept an already wrapped or parenthesized statement.")
        }
        guard request.valid else { throw ExecutionPolicyError(message: "The selected statement exceeds the Explain input limit.") }
        return request
    }
}

struct ExplainRanking {
    struct Entry: Identifiable { let id: String; let operation: String; let score: Decimal }
    let entries: [Entry]
    let basis: String
    init(_ result: ExplainResult) {
        let roots = Set(result.roots)
        let candidates = result.nodes.filter { !roots.contains($0.id) }
        func scores(measured: Bool) -> [Entry] {
            candidates.compactMap { node in
                let score: Decimal?
                if measured {
                    if let time = node.metrics["totalTime"]?.decimal, let loops = node.metrics["loops"]?.decimal {
                        var left = time, right = loops, product = Decimal()
                        score = NSDecimalMultiply(&product, &left, &right, .plain) == .noError && !product.isNaN ? product : nil
                    } else { score = nil }
                } else { score = node.metrics["totalCost"]?.decimal }
                return score.map { Entry(id: node.id, operation: node.operation, score: $0) }
            }.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        }
        let measured = result.mode == .analyze ? scores(measured: true) : []
        let ranked = measured.isEmpty ? scores(measured: false) : measured
        entries = Array(ranked.prefix(3))
        basis = ranked.isEmpty ? "Ranking unavailable: no comparable reported metrics" :
            measured.isEmpty ? "Inclusive estimated cost (planner units)" : "Inclusive time × loops (ms of work, not wall time)"
    }
}
