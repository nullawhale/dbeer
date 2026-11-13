import Foundation

enum ExplainMode: String, Codable, Sendable { case plan, analyze
    var title: String { self == .analyze ? "Explain Analyze" : "Explain" }
}
enum ExplainPlanKind: String, Codable, CaseIterable, Sendable { case custom, generic
    var title: String { self == .generic ? "Generic (PostgreSQL 16+, estimated only)" : "Custom (bound values)" }
}

/// Process-local ownership copied into the single-use execution grant.
struct ExplainContext: Codable, Sendable, Equatable {
    var documentId: String
    var targetDocumentId: String
    var rangeLocation: Int
    var rangeLength: Int
    var profileId: String
    var sessionId: String
    var transactionStatus: String
    private enum CodingKeys: String, CodingKey { case documentId, targetDocumentId, rangeLocation, rangeLength, profileId, sessionId, transactionStatus }
    var valid: Bool {
        [documentId, targetDocumentId, profileId, sessionId].allSatisfy(BackendMessage.validID) &&
        (0...16_777_216).contains(rangeLocation) && (1...1_048_576).contains(rangeLength) &&
        ["idle", "transaction", "failedTransaction"].contains(transactionStatus)
    }
}
struct ExplainRequest: Codable, Sendable, Equatable {
    var sql: String
    var mode: ExplainMode
    var parameters: [QueryParameterBinding]? = nil
    var planKind: ExplainPlanKind? = nil
    var context: ExplainContext? = nil
    private enum CodingKeys: String, CodingKey { case sql, mode, parameters, planKind, context }
    var valid: Bool {
        !sql.isEmpty && sql.utf8.count <= 1_048_576 && !sql.contains("\0") &&
        (parameters.map { (try? QueryParameterBinding.validate($0)) != nil } ?? true) &&
        (planKind != .generic || mode == .plan) && (context.map { $0.valid && $0.rangeLength == sql.utf16.count } ?? true)
    }
    var portable: Self { var copy = self; copy.context = nil; return copy }
}
extension ExplainContext {
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["documentId", "targetDocumentId", "rangeLocation", "rangeLength", "profileId", "sessionId", "transactionStatus"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        documentId = try values.decode(String.self, forKey: .documentId)
        targetDocumentId = try values.decode(String.self, forKey: .targetDocumentId)
        rangeLocation = try values.decode(Int.self, forKey: .rangeLocation)
        rangeLength = try values.decode(Int.self, forKey: .rangeLength)
        profileId = try values.decode(String.self, forKey: .profileId)
        sessionId = try values.decode(String.self, forKey: .sessionId)
        transactionStatus = try values.decode(String.self, forKey: .transactionStatus)
        guard valid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid Explain ownership context.")) }
    }
}
extension ExplainRequest {
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["sql", "mode"], optional: ["parameters", "planKind", "context"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sql = try values.decode(String.self, forKey: .sql)
        mode = try values.decode(ExplainMode.self, forKey: .mode)
        parameters = values.contains(.parameters) ? try values.decode([QueryParameterBinding].self, forKey: .parameters) : nil
        planKind = values.contains(.planKind) ? try values.decode(ExplainPlanKind.self, forKey: .planKind) : nil
        context = values.contains(.context) ? try values.decode(ExplainContext.self, forKey: .context) : nil
        guard valid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid Explain request.")) }
    }
}
private struct ExplainCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func requireExplainKeys(_ decoder: Decoder, required: Set<String>, optional: Set<String> = []) throws {
    let values = try decoder.container(keyedBy: ExplainCodingKey.self)
    let keys = Set(values.allKeys.map(\.stringValue))
    guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid Explain fields."))
    }
}
struct ExplainSupport: Codable, Sendable, Equatable {
    var engine: DatabaseEngine
    var serverVersion: String
    var format: String
    var modes: [ExplainMode]
    var unavailableReason: String?
    var planKinds: [ExplainPlanKind]? = nil
    var valid: Bool {
        [.postgresql, .mysql, .sqlite].contains(engine) && serverVersion.utf8.count <= 256 &&
        format == (engine == .postgresql ? "json" : engine == .sqlite ? "queryPlan" : "tree") && modes.count <= 2 &&
        Set(modes.map(\.rawValue)).count == modes.count &&
        (planKinds == nil || engine == .postgresql && planKinds!.count <= 2 && Set(planKinds!.map(\.rawValue)).count == planKinds!.count) &&
        (modes.isEmpty ? unavailableReason?.isEmpty == false : unavailableReason == nil)
    }
}
struct ExplainPreview: Codable, Sendable, Equatable {
    var sql: String
    var mode: ExplainMode
    var support: ExplainSupport
    var valid: Bool { support.valid && support.modes.contains(mode) && !sql.isEmpty && sql.utf8.count <= 1_049_600 && !sql.contains("\0") }
}
struct ExplainMetric: Codable, Sendable, Equatable {
    var value: String?
    var unit: String
    var basis: String
    var unavailableReason: String?
    static func validDecimal(_ value: String) -> Bool {
        value.utf8.count <= 128 && value.range(of: #"^(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) == value.startIndex..<value.endIndex
    }
    var valid: Bool {
        ["cost", "rows", "ms", "count"].contains(unit) &&
        ["inclusive", "perInvocation", "total"].contains(basis) &&
        (value.map { Self.validDecimal($0) && unavailableReason == nil } ??
            ["notCollected", "notReported", "unsupported", "notExecuted"].contains(unavailableReason))
    }
    var unavailableLabel: String {
        switch unavailableReason {
        case "notCollected": "Unavailable — run Explain Analyze to collect this metric"
        case "notExecuted": "Unavailable — not executed"
        case "unsupported": "Unavailable — unsupported by this format"
        default: "Unavailable — server did not report this metric"
        }
    }
    var label: String { value.map { "\($0) \(unit) · \(basis == "perInvocation" ? "per invocation" : basis)" } ?? unavailableLabel }
    var decimal: Decimal? {
        guard let value, valid else { return nil }
        let mantissa = value.split(whereSeparator: { $0 == "e" || $0 == "E" }).first ?? ""
        let digits = mantissa.filter(\.isNumber).drop(while: { $0 == "0" })
        guard digits.count <= 38, let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN else { return nil }
        return number
    }
}
struct ExplainNode: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var children: [String]
    var operation: String
    var details: [String: String]
    var execution: String
    var metrics: [String: ExplainMetric]
}
struct ExplainResult: Codable, Sendable, Equatable {
    static let maximumRawBytes = 4 * 1_024 * 1_024
    var support: ExplainSupport
    var mode: ExplainMode
    var status: String
    var raw: String
    var complete: Bool
    var diagnostic: String?
    var roots: [String]
    var nodes: [ExplainNode]
    var metrics: [String: ExplainMetric]
    var valid: Bool {
        guard support.valid, support.modes.contains(mode), raw.utf8.count <= Self.maximumRawBytes,
              nodes.count <= 10_000, metrics.count <= 16, metrics.values.allSatisfy(\.valid),
              (diagnostic?.utf8.count ?? 0) <= 4_096, ["tree", "rawOnly", "limited"].contains(status) else { return false }
        if status == "tree" {
            guard complete, !nodes.isEmpty, !roots.isEmpty, diagnostic == nil else { return false }
        } else {
            guard nodes.isEmpty, roots.isEmpty, diagnostic?.isEmpty == false,
                  status != "limited" || !complete else { return false }
        }
        var indexed: [String: ExplainNode] = [:]
        for node in nodes {
            guard BackendMessage.validID(node.id), indexed[node.id] == nil, !node.operation.isEmpty,
                  node.operation.utf8.count <= 65_536, node.details.count <= 128,
                  node.details.allSatisfy({ $0.key.utf8.count <= 1_024 && $0.value.utf8.count <= 65_536 }),
                  node.children.count <= 10_000, node.metrics.count <= 32, node.metrics.values.allSatisfy(\.valid),
                  ["estimated", "executed", "notExecuted"].contains(node.execution) else { return false }
            indexed[node.id] = node
        }
        var seen = Set<String>()
        var pending = roots.map { ($0, 1) }
        while let (id, depth) = pending.popLast() {
            guard depth <= 128, let node = indexed[id], seen.insert(id).inserted else { return false }
            pending.append(contentsOf: node.children.map { ($0, depth + 1) })
        }
        return seen.count == nodes.count
    }
}
