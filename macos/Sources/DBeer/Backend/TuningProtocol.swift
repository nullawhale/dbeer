import Foundation

// Tuning evidence carries no grant; execution requests require fresh current-owner review.
struct TuningInspectRequest: Codable, Sendable, Equatable {
    static let capability = "tuningV1"
    var version: Int
    var source: ExplainRequest
    var capture: ExplainResult
    var target: StructureTarget
    var valid: Bool { version == 1 && source.tuningSourceValid && source.context?.transactionStatus == "idle" && capture.valid && capture.mode == source.mode && capture.options == source.options && target.tuningTargetValid }
}
extension TuningInspectRequest {
    private enum CodingKeys: String, CodingKey { case version, source, capture, target }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["version", "source", "capture", "target"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        version = try fields.decode(Int.self, forKey: .version)
        source = try fields.decode(ExplainRequest.self, forKey: .source)
        capture = try fields.decode(ExplainResult.self, forKey: .capture)
        target = try fields.decode(StructureTarget.self, forKey: .target)
        guard valid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tuning contract.")) }
    }
}
struct TuningValidationRequest: Codable, Sendable, Equatable {
    var version: Int
    var original: ExplainRequest
    var variant: ExplainRequest
    var target: StructureTarget
    var metadataFingerprint: String
    var maxRows: Int
    var maxBytes: Int
    var timeoutMs: Int
    var comparison: String
    var valid: Bool { version == 1 && original.tuningSourceValid && variant.tuningSourceValid && original.context?.transactionStatus == "idle" && variant.context?.transactionStatus == "idle" && original.mode == .plan && variant.mode == .plan && original.sql != variant.sql && original.planKind != .generic && variant.planKind != .generic && target.tuningTargetValid && tuningDigest(metadataFingerprint) && (1...10_000).contains(maxRows) && (1_024...4_194_304).contains(maxBytes) && (100...30_000).contains(timeoutMs) && comparison == "multiset" && (original.parameters ?? []) == (variant.parameters ?? []) && original.options == variant.options && original.planKind == variant.planKind && tuningSameContext(original.context, variant.context) }
}
extension TuningValidationRequest {
    private enum CodingKeys: String, CodingKey { case version, original, variant, target, metadataFingerprint, maxRows, maxBytes, timeoutMs, comparison }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["version", "original", "variant", "target", "metadataFingerprint", "maxRows", "maxBytes", "timeoutMs", "comparison"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        version = try fields.decode(Int.self, forKey: .version)
        original = try fields.decode(ExplainRequest.self, forKey: .original)
        variant = try fields.decode(ExplainRequest.self, forKey: .variant)
        target = try fields.decode(StructureTarget.self, forKey: .target)
        metadataFingerprint = try fields.decode(String.self, forKey: .metadataFingerprint)
        maxRows = try fields.decode(Int.self, forKey: .maxRows)
        maxBytes = try fields.decode(Int.self, forKey: .maxBytes)
        timeoutMs = try fields.decode(Int.self, forKey: .timeoutMs)
        comparison = try fields.decode(String.self, forKey: .comparison)
        guard valid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tuning contract.")) }
    }
}
struct TuningSettingRequest: Codable, Sendable, Equatable {
    var version: Int
    var context: ExplainContext
    var name: String
    var expectedValueKiB: Int
    var valueKiB: Int
    var valid: Bool { version == 1 && context.valid && context.transactionStatus == "transaction" && name == "work_mem" && (64...1_048_576).contains(expectedValueKiB) && (64...1_048_576).contains(valueKiB) && expectedValueKiB != valueKiB }
}
extension TuningSettingRequest {
    private enum CodingKeys: String, CodingKey { case version, context, name, expectedValueKiB, valueKiB }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["version", "context", "name", "expectedValueKiB", "valueKiB"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        version = try fields.decode(Int.self, forKey: .version)
        context = try fields.decode(ExplainContext.self, forKey: .context)
        name = try fields.decode(String.self, forKey: .name)
        expectedValueKiB = try fields.decode(Int.self, forKey: .expectedValueKiB)
        valueKiB = try fields.decode(Int.self, forKey: .valueKiB)
        guard valid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tuning contract.")) }
    }
}
struct TuningIndexAdvice: Codable, Sendable, Equatable {
    var id: String
    var nodeId: String
    var explanation: String
    var evidence: [String]
    var limitations: [String]
    var edit: StructureIndexEdit
    var valid: Bool { BackendMessage.validID(id) && BackendMessage.validID(nodeId) && tuningText(explanation) && tuningTexts(evidence) && tuningTexts(limitations) && edit.action == "add" && edit.definition?.method == "btree" && edit.definition?.terms.count == 1 && edit.definition?.terms.first?.column != nil && edit.definition?.terms.first?.expression == nil && edit.unique != true && edit.columns == nil }
}
extension TuningIndexAdvice {
    private enum CodingKeys: String, CodingKey { case id, nodeId, explanation, evidence, limitations, edit }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["id", "nodeId", "explanation", "evidence", "limitations", "edit"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        nodeId = try fields.decode(String.self, forKey: .nodeId)
        explanation = try fields.decode(String.self, forKey: .explanation)
        evidence = try fields.decode([String].self, forKey: .evidence)
        limitations = try fields.decode([String].self, forKey: .limitations)
        edit = try fields.decode(StructureIndexEdit.self, forKey: .edit)
        guard valid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tuning contract.")) }
    }
}
struct TuningVariant: Codable, Sendable, Equatable {
    var id: String
    var kind: String
    var explanation: String
    var validation: String
    var request: ExplainRequest
    var valid: Bool { BackendMessage.validID(id) && kind == "sameColumnOrToIn" && tuningText(explanation) && validation == "unvalidated" && request.tuningSourceValid && request.mode == .plan }
}
extension TuningVariant {
    private enum CodingKeys: String, CodingKey { case id, kind, explanation, validation, request }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["id", "kind", "explanation", "validation", "request"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        kind = try fields.decode(String.self, forKey: .kind)
        explanation = try fields.decode(String.self, forKey: .explanation)
        validation = try fields.decode(String.self, forKey: .validation)
        request = try fields.decode(ExplainRequest.self, forKey: .request)
        guard valid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tuning contract.")) }
    }
}
struct TuningInspection: Codable, Sendable, Equatable {
    var version: Int
    var engine: String
    var serverVersion: String
    var evidenceOrigin: String
    var metadataFingerprint: String
    var target: StructureTarget
    var indexes: [TuningIndexAdvice]
    var variants: [TuningVariant]
    var limitations: [String]
    var workMemKiB: Int? = nil
    var valid: Bool { version == 1 && ["postgresql", "mysql"].contains(engine) && serverVersion.utf8.count <= 256 && evidenceOrigin == "suppliedCapture" && tuningDigest(metadataFingerprint) && target.tuningTargetValid && indexes.count <= 1 && variants.count <= 1 && indexes.allSatisfy(\.valid) && variants.allSatisfy(\.valid) && tuningTexts(limitations) && (workMemKiB.map { engine == "postgresql" && (64...1_048_576).contains($0) } ?? true) }
}
extension TuningInspection {
    private enum CodingKeys: String, CodingKey { case version, engine, serverVersion, evidenceOrigin, metadataFingerprint, target, indexes, variants, limitations, workMemKiB }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["version", "engine", "serverVersion", "evidenceOrigin", "metadataFingerprint", "target", "indexes", "variants", "limitations"], optional: ["workMemKiB"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        version = try fields.decode(Int.self, forKey: .version)
        engine = try fields.decode(String.self, forKey: .engine)
        serverVersion = try fields.decode(String.self, forKey: .serverVersion)
        evidenceOrigin = try fields.decode(String.self, forKey: .evidenceOrigin)
        metadataFingerprint = try fields.decode(String.self, forKey: .metadataFingerprint)
        target = try fields.decode(StructureTarget.self, forKey: .target)
        indexes = try fields.decode([TuningIndexAdvice].self, forKey: .indexes)
        variants = try fields.decode([TuningVariant].self, forKey: .variants)
        limitations = try fields.decode([String].self, forKey: .limitations)
        workMemKiB = fields.contains(.workMemKiB) ? try fields.decode(Int.self, forKey: .workMemKiB) : nil
        guard valid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tuning contract.")) }
    }
}
struct TuningValidation: Codable, Sendable, Equatable {
    var version: Int
    var state: String
    var comparison: String
    var originalRows: Int
    var variantRows: Int
    var comparedBytes: Int
    var complete: Bool
    var scope: String
    var limitations: [String]
    var valid: Bool { version == 1 && ["inconclusive", "observedEqual", "observedDifferent"].contains(state) && comparison == "multiset" && (0...10_000).contains(originalRows) && (0...10_000).contains(variantRows) && (0...4_194_304).contains(comparedBytes) && complete == (state != "inconclusive") && scope == "sequentialCurrentSession" && tuningTexts(limitations) }
}
extension TuningValidation {
    private enum CodingKeys: String, CodingKey { case version, state, comparison, originalRows, variantRows, comparedBytes, complete, scope, limitations }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["version", "state", "comparison", "originalRows", "variantRows", "comparedBytes", "complete", "scope", "limitations"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        version = try fields.decode(Int.self, forKey: .version)
        state = try fields.decode(String.self, forKey: .state)
        comparison = try fields.decode(String.self, forKey: .comparison)
        originalRows = try fields.decode(Int.self, forKey: .originalRows)
        variantRows = try fields.decode(Int.self, forKey: .variantRows)
        comparedBytes = try fields.decode(Int.self, forKey: .comparedBytes)
        complete = try fields.decode(Bool.self, forKey: .complete)
        scope = try fields.decode(String.self, forKey: .scope)
        limitations = try fields.decode([String].self, forKey: .limitations)
        guard valid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tuning contract.")) }
    }
}
struct TuningSettingPreview: Codable, Sendable, Equatable {
    var sql: String
    var restoreSQL: String
    var scope: String
    var risks: [String]
    var valid: Bool { tuningText(sql) && tuningText(restoreSQL) && scope == "currentTransaction" && tuningTexts(risks) }
}
extension TuningSettingPreview {
    private enum CodingKeys: String, CodingKey { case sql, restoreSQL, scope, risks }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["sql", "restoreSQL", "scope", "risks"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        sql = try fields.decode(String.self, forKey: .sql)
        restoreSQL = try fields.decode(String.self, forKey: .restoreSQL)
        scope = try fields.decode(String.self, forKey: .scope)
        risks = try fields.decode([String].self, forKey: .risks)
        guard valid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tuning contract.")) }
    }
}
struct TuningSettingResult: Codable, Sendable, Equatable {
    var version: Int
    var state: String
    var beforeKiB: Int
    var requestedKiB: Int
    var restore: TuningSettingRequest
    var limitations: [String]
    var valid: Bool { version == 1 && state == "applied" && (64...1_048_576).contains(beforeKiB) && (64...1_048_576).contains(requestedKiB) && restore.valid && restore.valueKiB == beforeKiB && restore.expectedValueKiB == requestedKiB && tuningTexts(limitations) }
}
extension TuningSettingResult {
    private enum CodingKeys: String, CodingKey { case version, state, beforeKiB, requestedKiB, restore, limitations }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["version", "state", "beforeKiB", "requestedKiB", "restore", "limitations"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        version = try fields.decode(Int.self, forKey: .version)
        state = try fields.decode(String.self, forKey: .state)
        beforeKiB = try fields.decode(Int.self, forKey: .beforeKiB)
        requestedKiB = try fields.decode(Int.self, forKey: .requestedKiB)
        restore = try fields.decode(TuningSettingRequest.self, forKey: .restore)
        limitations = try fields.decode([String].self, forKey: .limitations)
        guard valid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tuning contract.")) }
    }
}

private extension ExplainRequest {
    var tuningSourceValid: Bool { valid && context != nil && writeIntent == nil && ["idle", "transaction"].contains(context?.transactionStatus ?? "") }
}
private extension StructureTarget {
    var tuningTargetValid: Bool { !create && reconcile == nil && [schema, table].allSatisfy { !$0.isEmpty && $0.utf8.count <= 63 && !$0.contains("\0") } }
}
private func tuningSameContext(_ a: ExplainContext?, _ b: ExplainContext?) -> Bool {
    guard var a, var b else { return false }; a.rangeLength = 0; b.rangeLength = 0; return a == b
}
private func tuningDigest(_ s: String) -> Bool { s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
private func tuningText(_ s: String) -> Bool { !s.isEmpty && s.utf8.count <= 4_096 && !s.contains("\0") }
private func tuningTexts(_ a: [String]) -> Bool { !a.isEmpty && a.count <= 16 && a.allSatisfy(tuningText) }

struct TuningSettingObservationRequest: Codable, Sendable, Equatable {
 var version: Int
 var context: ExplainContext
 var name: String
 var valid: Bool { version == 1 && context.valid && context.transactionStatus == "transaction" && name == "work_mem" }
}
extension TuningSettingObservationRequest {
 private enum CodingKeys: String, CodingKey { case version, context, name }
 init(from decoder: Decoder) throws {
  try requireExplainKeys(decoder, required: ["version", "context", "name"])
  let fields = try decoder.container(keyedBy: CodingKeys.self)
  version = try fields.decode(Int.self, forKey: .version)
  context = try fields.decode(ExplainContext.self, forKey: .context)
  name = try fields.decode(String.self, forKey: .name)
  guard valid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tuning setting observation request.")) }
 }
}
struct TuningSettingObservation: Codable, Sendable, Equatable {
 var version: Int
 var name: String
 var workMemKiB: Int
 var scope: String
 var valid: Bool { version == 1 && name == "work_mem" && (64...1_048_576).contains(workMemKiB) && scope == "currentTransaction" }
}
extension TuningSettingObservation {
 private enum CodingKeys: String, CodingKey { case version, name, workMemKiB, scope }
 init(from decoder: Decoder) throws {
  try requireExplainKeys(decoder, required: ["version", "name", "workMemKiB", "scope"])
  let fields = try decoder.container(keyedBy: CodingKeys.self)
  version = try fields.decode(Int.self, forKey: .version)
  name = try fields.decode(String.self, forKey: .name)
  workMemKiB = try fields.decode(Int.self, forKey: .workMemKiB)
  scope = try fields.decode(String.self, forKey: .scope)
  guard valid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tuning setting observation.")) }
 }
}
