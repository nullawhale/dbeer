import Foundation

/// A default is still an explicit choice; cancellation is the outer optional.
enum ExplainOptionsDecision: Equatable, Sendable {
    case use(ExplainOptions?)
    var options: ExplainOptions? { switch self { case let .use(options): options } }
}

struct ExplainOptionsAdmission {
    static let capability = "explainOptionsV1"

    static func validOwner(support: ExplainSupport?, engine: DatabaseEngine?, capabilities: Set<String>, helperSupports: Bool) -> Bool {
        guard helperSupports, capabilities.contains(capability), let support, support.valid,
              support.engine == engine, [.postgresql, .mysql].contains(support.engine),
              support.options?.valid(engine: support.engine) == true else { return false }
        return true
    }

    static func accepts(_ options: ExplainOptions, support: ExplainSupport, mode: ExplainMode) -> Bool {
        guard support.valid, support.modes.contains(mode), let advertised = support.options,
              advertised.valid(engine: support.engine), options.valid(engine: support.engine) else { return false }
        return advertised.accepts(options: options, mode: mode, engine: support.engine)
    }
}

/// Built only after connection from the physical target, never from the source
/// editor's profile or a restored document's historical evidence.
struct ExplainOptionsConfiguration {
    let support: ExplainSupport
    let mode: ExplainMode
    let profile: SavedConnection
    let sessionID: String
    let targetDocumentID: UUID
    let transactionStatus: TransactionStatus?
    let sql: String
    let range: NSRange

    var available: [String] {
        if let pg = support.options?.postgresql { return mode == .plan ? pg.plan : pg.analyze }
        if let mysql = support.options?.mysql { return mode == .plan ? mysql.plan : mysql.analyze }
        return []
    }
    var requiresJSONVersion2: Bool { mode == .analyze && support.options?.mysql?.jsonAnalyzeRequiresVersion2 == true }
    func accepts(_ options: ExplainOptions?) -> Bool {
        support.engine == profile.engine && support.modes.contains(mode) &&
            (options.map { ExplainOptionsAdmission.accepts($0, support: support, mode: mode) } ?? true)
    }
}

@MainActor
final class ExplainOptionsPrompt: Identifiable {
    let id = UUID()
    let documentID: UUID
    let configuration: ExplainOptionsConfiguration
    let continuation: CheckedContinuation<ExplainOptionsDecision?, Never>
    var result: ExplainOptionsDecision?

    init(documentID: UUID, configuration: ExplainOptionsConfiguration, continuation: CheckedContinuation<ExplainOptionsDecision?, Never>) {
        self.documentID = documentID
        self.configuration = configuration
        self.continuation = continuation
    }
}

extension ExplainOptions {
    var summary: String {
        if let pg = postgresql {
            let flags: [(String, Bool?)] = [("BUFFERS", pg.buffers), ("WAL", pg.wal), ("SETTINGS", pg.settings), ("MEMORY", pg.memory), ("TIMING", pg.timing)]
            var labels = flags.compactMap { name, value in value.map { name + ($0 ? " ON" : " OFF") } }
            if let serialize = pg.serialize { labels.append("SERIALIZE " + serialize.rawValue.uppercased()) }
            return labels.isEmpty ? "PostgreSQL defaults" : labels.joined(separator: " · ")
        }
        return "MySQL format: " + (mysql?.format.rawValue.uppercased() ?? "unavailable")
    }
}
