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
        ["idle", "transaction", "failedTransaction", "unsupported"].contains(transactionStatus)
    }
}
struct ExplainRequest: Codable, Sendable, Equatable {
    var sql: String
    var mode: ExplainMode
    var parameters: [QueryParameterBinding]? = nil
    var planKind: ExplainPlanKind? = nil
    var context: ExplainContext? = nil
    var options: ExplainOptions? = nil
    var writeIntent: ExplainWriteIntent? = nil
    private enum CodingKeys: String, CodingKey { case sql, mode, parameters, planKind, context, options, writeIntent }
    var valid: Bool {
        !sql.isEmpty && sql.utf8.count <= 1_048_576 && !sql.contains("\0") &&
        (writeIntent.map { $0.valid && mode == .analyze && context != nil && context?.transactionStatus == $0.expectedTransactionStatus } ?? true) &&
        (options?.valid ?? true) && (parameters.map { (try? QueryParameterBinding.validate($0)) != nil } ?? true) &&
        (planKind != .generic || mode == .plan) && (context.map { $0.valid && $0.rangeLength == sql.utf16.count } ?? true)
    }
    var portable: Self { var copy = self; copy.context = nil; copy.writeIntent = nil; return copy }
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
        try requireExplainKeys(decoder, required: ["sql", "mode"], optional: ["parameters", "planKind", "context", "options", "writeIntent"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sql = try values.decode(String.self, forKey: .sql)
        mode = try values.decode(ExplainMode.self, forKey: .mode)
        parameters = values.contains(.parameters) ? try values.decode([QueryParameterBinding].self, forKey: .parameters) : nil
        planKind = values.contains(.planKind) ? try values.decode(ExplainPlanKind.self, forKey: .planKind) : nil
        context = values.contains(.context) ? try values.decode(ExplainContext.self, forKey: .context) : nil
        options = values.contains(.options) ? try values.decode(ExplainOptions.self, forKey: .options) : nil
        writeIntent = values.contains(.writeIntent) ? try values.decode(ExplainWriteIntent.self, forKey: .writeIntent) : nil
        guard valid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid Explain request.")) }
    }
}
private struct ExplainCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
func requireExplainKeys(_ decoder: Decoder, required: Set<String>, optional: Set<String> = []) throws {
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
    var diagnosticModel: String? = nil
    var options: ExplainOptionSupport? = nil
    var analyzeUnavailableReason: String? = nil
    var notices: [String]? = nil
    var dml: ExplainDMLSupport? = nil
    private enum CodingKeys: String, CodingKey { case engine, serverVersion, format, modes, unavailableReason, planKinds, diagnosticModel, options, analyzeUnavailableReason, notices, dml }
    var valid: Bool {
        (dml.map { $0.valid(engine: engine) && !modes.isEmpty && ($0.analyze.isEmpty || modes.contains(.analyze)) } ?? true) &&
        [.postgresql, .mysql, .sqlite, .mongodb, .cassandra].contains(engine) && serverVersion.utf8.count <= 256 &&
        (engine == .mysql ? ["tree", "json"].contains(format) : format == (engine == .postgresql ? "json" : engine == .sqlite ? "queryPlan" : engine == .mysql ? "tree" : engine == .mongodb ? "mongodbExplain" : "cassandraTrace")) &&
        (engine == .mongodb ? diagnosticModel == "mongodbExplain" : engine == .cassandra ? diagnosticModel == "cassandraTrace" && modes == [.analyze] : diagnosticModel == nil) && modes.count <= 2 &&
        Set(modes.map(\.rawValue)).count == modes.count &&
        (notices == nil || [.postgresql, .mysql].contains(engine) && notices!.count <= 8 && notices!.allSatisfy { !$0.isEmpty && $0.utf8.count <= 4096 }) &&
        (options?.valid(engine: engine) ?? true) &&
        (analyzeUnavailableReason == nil || engine == .mysql && !modes.contains(.analyze) && analyzeUnavailableReason!.utf8.count <= 4096 && !analyzeUnavailableReason!.isEmpty) &&
        (planKinds == nil || engine == .postgresql && planKinds!.count <= 2 && Set(planKinds!.map(\.rawValue)).count == planKinds!.count) &&
        (modes.isEmpty ? unavailableReason?.isEmpty == false : unavailableReason == nil)
    }
}
struct ExplainPreview: Codable, Sendable, Equatable {
    var sql: String
    var mode: ExplainMode
    var support: ExplainSupport
    var options: ExplainOptions? = nil
    var format: String? = nil
    var dml: ExplainDMLTarget? = nil
    private enum CodingKeys: String, CodingKey { case sql, mode, support, options, format, dml }
    var valid: Bool { (dml.map { $0.valid(engine: support.engine) && support.dml != nil && (mode != .analyze || support.dml!.analyze.contains($0.analyzeForm)) } ?? true) && support.valid && validExplainSelection(support: support, options: options, mode: mode, format: format) && support.modes.contains(mode) && !sql.isEmpty && sql.utf8.count <= 1_049_600 && !sql.contains("\0") }
}
struct ExplainMetric: Codable, Sendable, Equatable {
    var value: String?
    var unit: String
    var basis: String
    var unavailableReason: String?
    private enum CodingKeys: String, CodingKey { case value, unit, basis, unavailableReason }
    static func validDecimal(_ value: String) -> Bool {
        value.utf8.count <= 128 && value.range(of: #"^(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) == value.startIndex..<value.endIndex
    }
    var valid: Bool {
        ["cost", "rows", "ms", "count", "blocks", "bytes"].contains(unit) &&
        ["inclusive", "perInvocation", "total", "inclusiveTotal", "exclusivePerInvocation"].contains(basis) &&
        (value.map { Self.validDecimal($0) && unavailableReason == nil } ??
            ["notCollected", "notReported", "unsupported", "notExecuted", "disabled", "inclusiveOnly", "parallel", "unknownScope", "partialInput"].contains(unavailableReason))
    }
    var unavailableLabel: String {
        switch unavailableReason {
        case "notCollected": "Unavailable — run Explain Analyze to collect this metric"
        case "disabled": "Unavailable — timing was disabled for this collection"
        case "notExecuted": "Unavailable — not executed"
        case "unsupported": "Unavailable — unsupported by this format"
        case "inclusiveOnly": "Unavailable — inclusive time cannot be safely partitioned"
        case "parallel": "Unavailable — parallel measurements can overlap"
        case "unknownScope": "Unavailable — serial execution could not be proved"
        case "partialInput": "Unavailable — input may have been consumed only partly"
        default: "Unavailable — server did not report this metric"
        }
    }
    var basisLabel: String {
        switch basis {
        case "perInvocation": "per invocation"
        case "inclusiveTotal": "inclusive total across loops"
        case "exclusivePerInvocation": "exclusive per invocation"
        default: basis
        }
    }
    var label: String { value.map { "\($0) \(unit) · \(basisLabel)" } ?? unavailableLabel }
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
    var advancedMetrics: ExplainNodeMetrics? = nil
    private enum CodingKeys: String, CodingKey { case id, children, operation, details, execution, metrics, advancedMetrics }
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
    var advancedMetrics: ExplainPlanMetrics? = nil
    var engineDiagnostic: EngineDiagnostic? = nil
    var options: ExplainOptions? = nil
    var format: String? = nil
    var dml: ExplainDMLResult? = nil
    private enum CodingKeys: String, CodingKey { case support, mode, status, raw, complete, diagnostic, roots, nodes, metrics, advancedMetrics, engineDiagnostic, options, format, dml }
    var valid: Bool {
        guard dml.map({ $0.valid(engine: support.engine, mode: mode) && support.dml != nil && (mode != .analyze || $0.execution == "completed" && support.dml!.analyze.contains($0.target.analyzeForm)) }) ?? true,
              support.valid, support.modes.contains(mode),
              advancedMetrics == nil || status == "tree" && advancedMetrics?.valid(engine: support.engine) == true,
              validExplainSelection(support: support, options: options, mode: mode, format: format, status: status), raw.utf8.count <= Self.maximumRawBytes,
              nodes.count <= 10_000, metrics.count <= 16, metrics.values.allSatisfy(\.valid),
              (diagnostic?.utf8.count ?? 0) <= 4_096 else { return false }
        if support.engine == .cassandra && complete { return false }
        if support.engine == .mongodb || support.engine == .cassandra {
            return engineDiagnostic?.valid(engine: support.engine, mode: mode) == true && status == "diagnostic" &&
                nodes.isEmpty && roots.isEmpty && metrics.isEmpty && diagnostic?.isEmpty == false
        }
        guard engineDiagnostic == nil, ["tree", "rawOnly", "limited"].contains(status) else { return false }
        if status == "tree" {
            guard complete, !nodes.isEmpty, !roots.isEmpty, diagnostic == nil else { return false }
        } else {
            guard nodes.isEmpty, roots.isEmpty, diagnostic?.isEmpty == false,
                  status != "limited" || !complete else { return false }
        }
        var indexed: [String: ExplainNode] = [:]
        for node in nodes {
            guard node.advancedMetrics == nil || advancedMetrics != nil && node.advancedMetrics?.valid(engine: support.engine, node: node, mode: mode) == true,
                  node.advancedMetrics?.jit == nil || roots.contains(node.id), BackendMessage.validID(node.id), indexed[node.id] == nil, !node.operation.isEmpty,
                  node.operation.utf8.count <= 65_536, node.details.count <= 128,
                  node.details.allSatisfy({ $0.key.utf8.count <= 1_024 && $0.value.utf8.count <= 65_536 }),
                  node.children.count <= 10_000, node.metrics.count <= 32, node.metrics.values.allSatisfy(\.valid),
                  ["estimated", "executed", "notExecuted", "unknown"].contains(node.execution) else { return false }
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

extension ExplainNode {
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["id", "children", "operation", "details", "execution", "metrics"], optional: ["advancedMetrics"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        children = try fields.decode([String].self, forKey: .children)
        operation = try fields.decode(String.self, forKey: .operation)
        details = try fields.decode([String: String].self, forKey: .details)
        execution = try fields.decode(String.self, forKey: .execution)
        metrics = try fields.decode([String: ExplainMetric].self, forKey: .metrics)
        advancedMetrics = fields.contains(.advancedMetrics) ? try fields.decode(ExplainNodeMetrics.self, forKey: .advancedMetrics) : nil
    }
}
extension ExplainResult {
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["support", "mode", "status", "raw", "complete", "roots", "nodes", "metrics"], optional: ["diagnostic", "engineDiagnostic", "options", "format", "advancedMetrics", "dml"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        support = try fields.decode(ExplainSupport.self, forKey: .support)
        mode = try fields.decode(ExplainMode.self, forKey: .mode)
        status = try fields.decode(String.self, forKey: .status)
        raw = try fields.decode(String.self, forKey: .raw)
        complete = try fields.decode(Bool.self, forKey: .complete)
        diagnostic = try fields.decodeIfPresent(String.self, forKey: .diagnostic)
        roots = try fields.decode([String].self, forKey: .roots)
        nodes = try fields.decode([ExplainNode].self, forKey: .nodes)
        metrics = try fields.decode([String: ExplainMetric].self, forKey: .metrics)
        engineDiagnostic = try fields.decodeIfPresent(EngineDiagnostic.self, forKey: .engineDiagnostic)
        options = try fields.decodeIfPresent(ExplainOptions.self, forKey: .options)
        format = try fields.decodeIfPresent(String.self, forKey: .format)
        advancedMetrics = fields.contains(.advancedMetrics) ? try fields.decode(ExplainPlanMetrics.self, forKey: .advancedMetrics) : nil
        dml = fields.contains(.dml) ? try fields.decode(ExplainDMLResult.self, forKey: .dml) : nil
    }
}

extension ExplainMetric {
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["unit", "basis"], optional: ["value", "unavailableReason"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        value = try fields.decodeIfPresent(String.self, forKey: .value)
        unit = try fields.decode(String.self, forKey: .unit)
        basis = try fields.decode(String.self, forKey: .basis)
        unavailableReason = try fields.decodeIfPresent(String.self, forKey: .unavailableReason)
    }
}

extension ExplainSupport {
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["engine", "serverVersion", "format", "modes"], optional: ["unavailableReason", "planKinds", "diagnosticModel", "options", "analyzeUnavailableReason", "notices", "dml"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        engine = try fields.decode(DatabaseEngine.self, forKey: .engine)
        serverVersion = try fields.decode(String.self, forKey: .serverVersion)
        format = try fields.decode(String.self, forKey: .format)
        modes = try fields.decode([ExplainMode].self, forKey: .modes)
        unavailableReason = try fields.decodeIfPresent(String.self, forKey: .unavailableReason)
        planKinds = try fields.decodeIfPresent([ExplainPlanKind].self, forKey: .planKinds)
        diagnosticModel = try fields.decodeIfPresent(String.self, forKey: .diagnosticModel)
        options = try fields.decodeIfPresent(ExplainOptionSupport.self, forKey: .options)
        analyzeUnavailableReason = try fields.decodeIfPresent(String.self, forKey: .analyzeUnavailableReason)
        notices = try fields.decodeIfPresent([String].self, forKey: .notices)
        dml = fields.contains(.dml) ? try fields.decode(ExplainDMLSupport.self, forKey: .dml) : nil
    }
}
extension ExplainPreview {
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["sql", "mode", "support"], optional: ["options", "format", "dml"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        sql = try fields.decode(String.self, forKey: .sql)
        mode = try fields.decode(ExplainMode.self, forKey: .mode)
        support = try fields.decode(ExplainSupport.self, forKey: .support)
        options = try fields.decodeIfPresent(ExplainOptions.self, forKey: .options)
        format = try fields.decodeIfPresent(String.self, forKey: .format)
        dml = fields.contains(.dml) ? try fields.decode(ExplainDMLTarget.self, forKey: .dml) : nil
    }
}
