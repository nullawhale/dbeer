import Foundation

enum ExplainMode: String, Codable, Sendable { case plan, analyze
    var title: String { self == .analyze ? "Explain Analyze" : "Explain" }
}
struct ExplainRequest: Codable, Sendable, Equatable {
    var sql: String
    var mode: ExplainMode
    var valid: Bool { !sql.isEmpty && sql.utf8.count <= 1_048_576 && !sql.contains("\0") }
}
struct ExplainSupport: Codable, Sendable, Equatable {
    var engine: DatabaseEngine
    var serverVersion: String
    var format: String
    var modes: [ExplainMode]
    var unavailableReason: String?
    var valid: Bool {
        [.postgresql, .mysql, .sqlite].contains(engine) && serverVersion.utf8.count <= 256 &&
        format == (engine == .postgresql ? "json" : engine == .sqlite ? "queryPlan" : "tree") && modes.count <= 2 &&
        Set(modes.map(\.rawValue)).count == modes.count &&
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
