import Foundation

/// This allowlisted protocol deliberately has no credentials, file paths,
/// backend commands, export destinations or authorization tokens.
struct AgentRequest: Codable, Sendable {
    var id: String
    var method: String
    var clientName: String?
    var profileId: String?
    var sql: String?
    var queryId: String?
    var kind: String?
    var schema: String?
    var object: String?
    var maxRows: Int?
    var timeoutSeconds: Int?
}

struct AgentConnection: Codable, Sendable {
    var id: String
    var name: String
    var engine: String
    var readOnly: Bool
    var queryLanguage: String? = nil
    var readOnlyEnforcement: String? = nil
}

struct AgentColumn: Codable, Sendable {
    var name: String
    var type: String
    var encoding: String?
}

struct AgentResult: Codable, Sendable {
    var columns: [AgentColumn]
    var rows: [[String?]]
    var commandTag: String
    var rowCount: Int64
    var truncated: Bool
    var displayNotice: String? = nil
    var affectedRowCountKnown: Bool? = nil
}

struct AgentResponse: Codable, Sendable {
    var id: String
    var ok: Bool
    var error: String?
    var connections: [AgentConnection]?
    var results: [AgentResult]?
    var queryId: String?
}
