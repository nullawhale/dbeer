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
    var nativeCommand: NativeCommand? = nil
}

extension AgentRequest {
    static func decode(_ frame: Data) throws -> Self {
        try ExactJSONKeys.validate(frame, maximumBytes: AgentSocketBroker.maximumRequestBytes, maximumDepth: 40)
        guard let fields = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let method = fields["method"] as? String else { throw ExactJSONKeys.Failure.invalid }
        let allowed: Set<String>
        switch method {
        case "hello": allowed = ["id", "method", "clientName"]
        case "connections": allowed = ["id", "method"]
        case "query": allowed = ["id", "method", "profileId", "sql", "queryId", "maxRows", "timeoutSeconds"]
        case "command": allowed = ["id", "method", "profileId", "nativeCommand", "queryId", "maxRows", "timeoutSeconds"]
        case "catalog": allowed = ["id", "method", "profileId", "queryId", "kind", "schema", "object"]
        case "cancel": allowed = ["id", "method", "queryId"]
        default: throw ExactJSONKeys.Failure.invalid
        }
        guard Set(fields.keys).isSubset(of: allowed), !fields.values.contains(where: { $0 is NSNull }) else { throw ExactJSONKeys.Failure.invalid }
        let request = try JSONDecoder().decode(Self.self, from: frame)
        guard method != "command" || request.nativeCommand?.valid == true else { throw ExactJSONKeys.Failure.invalid }
        return request
    }
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
    var sqliteValues: [[SQLiteValue]]? = nil
    var nativeValues: [[NativeValue]]? = nil
}

struct AgentResponse: Codable, Sendable {
    var id: String
    var ok: Bool
    var error: String?
    var connections: [AgentConnection]?
    var results: [AgentResult]?
    var queryId: String?
}
