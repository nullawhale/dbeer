import Foundation

/// Portable topology and authentication metadata. Secrets use the credential store.
struct MongoDBSettings: Codable, Equatable, Sendable {
    var authSource: String = "admin"
    var authMechanism: String = ""
    var replicaSet: String = ""
    var directConnection: Bool = false

    init(authSource: String = "admin", authMechanism: String = "", replicaSet: String = "", directConnection: Bool = false) {
        self.authSource = authSource
        self.authMechanism = authMechanism
        self.replicaSet = replicaSet
        self.directConnection = directConnection
    }

    private enum CodingKeys: String, CodingKey { case authSource, authMechanism, replicaSet, directConnection }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        authSource = try values.decodeIfPresent(String.self, forKey: .authSource) ?? "admin"
        authMechanism = try values.decodeIfPresent(String.self, forKey: .authMechanism) ?? ""
        replicaSet = try values.decodeIfPresent(String.self, forKey: .replicaSet) ?? ""
        directConnection = try values.decodeIfPresent(Bool.self, forKey: .directConnection) ?? false
    }

    var isValid: Bool {
        [authSource, replicaSet].allSatisfy { $0.utf8.count <= 1_024 && !$0.contains(where: { "\0\r\n".contains($0) }) } &&
            ["", "SCRAM-SHA-256", "SCRAM-SHA-1"].contains(authMechanism)
    }
}

enum MongoDBScript {
    static let initialText = """
    {
      "collection": "collection",
      "find": {}
    }
    """

    static func parse(_ text: String) -> SQLParseResult {
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        let statement = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [SQLStatement(sql: text, range: range)]
        let expression = try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|\b(?:true|false|null)\b"#)
        let tokens: [SQLToken] = expression?.matches(in: text, range: range).map { match in
            let value = source.substring(with: match.range)
            let kind: SQLToken.Kind = value.hasPrefix("\"") ? .string : ["true", "false", "null"].contains(value) ? .keyword : .number
            return SQLToken(range: match.range, kind: kind)
        } ?? []
        return SQLParseResult(statements: statement, statementEditorRanges: statement.map(\.range), tokens: tokens, diagnostics: [])
    }
}
