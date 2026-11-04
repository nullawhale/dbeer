import Foundation

// Exact typed table edits and immutable helper plan identities.

struct StructureTarget: Codable, Equatable, Sendable {
    var schema: String
    var table: String
    var create: Bool
    var reconcile: Bool?
}
extension StructureTarget {
    private enum CodingKeys: String, CodingKey { case schema, table, create, reconcile }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["schema", "table", "create", "reconcile"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(String.self, forKey: .schema)
        table = try c.decode(String.self, forKey: .table)
        create = try c.decode(Bool.self, forKey: .create)
        if c.contains(.reconcile), try c.decodeNil(forKey: .reconcile) { throw BackendTransportError(.invalidMessage) }
        reconcile = try c.decodeIfPresent(Bool.self, forKey: .reconcile)
    }
}

struct StructureDataType: Codable, Equatable, Sendable {
    var kind: String
    var length: Int?
    var precision: Int?
    var scale: Int?
}
extension StructureDataType {
    private enum CodingKeys: String, CodingKey { case kind, length, precision, scale }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["kind", "length", "precision", "scale"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        if c.contains(.length), try c.decodeNil(forKey: .length) { throw BackendTransportError(.invalidMessage) }
        length = try c.decodeIfPresent(Int.self, forKey: .length)
        if c.contains(.precision), try c.decodeNil(forKey: .precision) { throw BackendTransportError(.invalidMessage) }
        precision = try c.decodeIfPresent(Int.self, forKey: .precision)
        if c.contains(.scale), try c.decodeNil(forKey: .scale) { throw BackendTransportError(.invalidMessage) }
        scale = try c.decodeIfPresent(Int.self, forKey: .scale)
    }
}

struct StructureDefault: Codable, Equatable, Sendable {
    var kind: String
    var value: String?
}
extension StructureDefault {
    private enum CodingKeys: String, CodingKey { case kind, value }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["kind", "value"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        if c.contains(.value), try c.decodeNil(forKey: .value) { throw BackendTransportError(.invalidMessage) }
        value = try c.decodeIfPresent(String.self, forKey: .value)
    }
}

struct StructureColumn: Codable, Equatable, Sendable {
    var name: String
    var type: StructureDataType
    var nullable: Bool
    var `default`: StructureDefault
}
extension StructureColumn {
    private enum CodingKeys: String, CodingKey { case name, type, nullable, `default` }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["name", "type", "nullable", "default"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(StructureDataType.self, forKey: .type)
        nullable = try c.decode(Bool.self, forKey: .nullable)
        self.`default` = try c.decode(StructureDefault.self, forKey: .`default`)
    }
}

struct StructureDraft: Codable, Equatable, Sendable {
    var columns: [StructureColumn]
    var changes: [StructureColumnChange]?
    var indexes: [StructureIndexEdit]?
    var keys: [StructureKeyEdit]?
    var allowDestructive: Bool?
}
extension StructureDraft {
    private enum CodingKeys: String, CodingKey { case columns, changes, indexes, keys, allowDestructive }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["columns", "changes", "indexes", "keys", "allowDestructive"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        columns = try c.decode([StructureColumn].self, forKey: .columns)
        if c.contains(.changes), try c.decodeNil(forKey: .changes) { throw BackendTransportError(.invalidMessage) }
        changes = try c.decodeIfPresent([StructureColumnChange].self, forKey: .changes)
        if c.contains(.indexes), try c.decodeNil(forKey: .indexes) { throw BackendTransportError(.invalidMessage) }
        indexes = try c.decodeIfPresent([StructureIndexEdit].self, forKey: .indexes)
        if c.contains(.keys), try c.decodeNil(forKey: .keys) { throw BackendTransportError(.invalidMessage) }
        keys = try c.decodeIfPresent([StructureKeyEdit].self, forKey: .keys)
        if c.contains(.allowDestructive), try c.decodeNil(forKey: .allowDestructive) { throw BackendTransportError(.invalidMessage) }
        allowDestructive = try c.decodeIfPresent(Bool.self, forKey: .allowDestructive)
    }
}

struct StructureObservedColumn: Codable, Equatable, Sendable {
    var name: String
    var nativeType: String
    var nullable: Bool
    var defaultExpression: String?
    var editableType: StructureDataType?
    var canModify: Bool?
}
extension StructureObservedColumn {
    private enum CodingKeys: String, CodingKey { case name, nativeType, nullable, defaultExpression, editableType, canModify }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["name", "nativeType", "nullable", "defaultExpression", "editableType", "canModify"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        nativeType = try c.decode(String.self, forKey: .nativeType)
        nullable = try c.decode(Bool.self, forKey: .nullable)
        if c.contains(.defaultExpression), try c.decodeNil(forKey: .defaultExpression) { throw BackendTransportError(.invalidMessage) }
        defaultExpression = try c.decodeIfPresent(String.self, forKey: .defaultExpression)
        if c.contains(.editableType), try c.decodeNil(forKey: .editableType) { throw BackendTransportError(.invalidMessage) }
        editableType = try c.decodeIfPresent(StructureDataType.self, forKey: .editableType)
        if c.contains(.canModify), try c.decodeNil(forKey: .canModify) { throw BackendTransportError(.invalidMessage) }
        canModify = try c.decodeIfPresent(Bool.self, forKey: .canModify)
    }
}

struct StructureBaseline: Codable, Equatable, Sendable {
    var id: String
    var target: StructureTarget
    var engine: String
    var fingerprint: String
    var columns: [StructureObservedColumn]
    var limitations: [String]
    var keys: [StructureKey]?
    var indexes: [StructureIndex]?
    var dependencyProof: Bool?
}
extension StructureBaseline {
    private enum CodingKeys: String, CodingKey { case id, target, engine, fingerprint, columns, limitations, keys, indexes, dependencyProof }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["id", "target", "engine", "fingerprint", "columns", "limitations", "keys", "indexes", "dependencyProof"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        target = try c.decode(StructureTarget.self, forKey: .target)
        engine = try c.decode(String.self, forKey: .engine)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        columns = try c.decode([StructureObservedColumn].self, forKey: .columns)
        limitations = try c.decode([String].self, forKey: .limitations)
        if c.contains(.keys), try c.decodeNil(forKey: .keys) { throw BackendTransportError(.invalidMessage) }
        keys = try c.decodeIfPresent([StructureKey].self, forKey: .keys)
        if c.contains(.indexes), try c.decodeNil(forKey: .indexes) { throw BackendTransportError(.invalidMessage) }
        indexes = try c.decodeIfPresent([StructureIndex].self, forKey: .indexes)
        if c.contains(.dependencyProof), try c.decodeNil(forKey: .dependencyProof) { throw BackendTransportError(.invalidMessage) }
        dependencyProof = try c.decodeIfPresent(Bool.self, forKey: .dependencyProof)
    }
}

struct StructurePlan: Codable, Equatable, Sendable {
    var id: String
    var baselineId: String
    var digest: String
    var target: StructureTarget
    var sql: [String]
    var risks: [String]
    var destructive: Bool?
}
extension StructurePlan {
    private enum CodingKeys: String, CodingKey { case id, baselineId, digest, target, sql, risks, destructive }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["id", "baselineId", "digest", "target", "sql", "risks", "destructive"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        baselineId = try c.decode(String.self, forKey: .baselineId)
        digest = try c.decode(String.self, forKey: .digest)
        target = try c.decode(StructureTarget.self, forKey: .target)
        sql = try c.decode([String].self, forKey: .sql)
        risks = try c.decode([String].self, forKey: .risks)
        if c.contains(.destructive), try c.decodeNil(forKey: .destructive) { throw BackendTransportError(.invalidMessage) }
        destructive = try c.decodeIfPresent(Bool.self, forKey: .destructive)
    }
}

struct StructureApply: Codable, Equatable, Sendable {
    var planId: String
    var digest: String
    var executionId: String
}
extension StructureApply {
    private enum CodingKeys: String, CodingKey { case planId, digest, executionId }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["planId", "digest", "executionId"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planId = try c.decode(String.self, forKey: .planId)
        digest = try c.decode(String.self, forKey: .digest)
        executionId = try c.decode(String.self, forKey: .executionId)
    }
}

struct StructureRequest: Codable, Equatable, Sendable {
    var target: StructureTarget?
    var baselineId: String?
    var draft: StructureDraft?
    var apply: StructureApply?
}
extension StructureRequest {
    private enum CodingKeys: String, CodingKey { case target, baselineId, draft, apply }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["target", "baselineId", "draft", "apply"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.target), try c.decodeNil(forKey: .target) { throw BackendTransportError(.invalidMessage) }
        target = try c.decodeIfPresent(StructureTarget.self, forKey: .target)
        if c.contains(.baselineId), try c.decodeNil(forKey: .baselineId) { throw BackendTransportError(.invalidMessage) }
        baselineId = try c.decodeIfPresent(String.self, forKey: .baselineId)
        if c.contains(.draft), try c.decodeNil(forKey: .draft) { throw BackendTransportError(.invalidMessage) }
        draft = try c.decodeIfPresent(StructureDraft.self, forKey: .draft)
        if c.contains(.apply), try c.decodeNil(forKey: .apply) { throw BackendTransportError(.invalidMessage) }
        apply = try c.decodeIfPresent(StructureApply.self, forKey: .apply)
    }
}

struct StructureStepOutcome: Codable, Equatable, Sendable {
    var state: String
    var message: String?
}
extension StructureStepOutcome {
    private enum CodingKeys: String, CodingKey { case state, message }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["state", "message"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        if c.contains(.message), try c.decodeNil(forKey: .message) { throw BackendTransportError(.invalidMessage) }
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}

struct StructureOutcome: Codable, Equatable, Sendable {
    var executionId: String
    var planId: String
    var state: String
    var steps: [StructureStepOutcome]
    var observed: StructureBaseline?
    var refreshError: String?
}
extension StructureOutcome {
    private enum CodingKeys: String, CodingKey { case executionId, planId, state, steps, observed, refreshError }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["executionId", "planId", "state", "steps", "observed", "refreshError"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        executionId = try c.decode(String.self, forKey: .executionId)
        planId = try c.decode(String.self, forKey: .planId)
        state = try c.decode(String.self, forKey: .state)
        steps = try c.decode([StructureStepOutcome].self, forKey: .steps)
        if c.contains(.observed), try c.decodeNil(forKey: .observed) { throw BackendTransportError(.invalidMessage) }
        observed = try c.decodeIfPresent(StructureBaseline.self, forKey: .observed)
        if c.contains(.refreshError), try c.decodeNil(forKey: .refreshError) { throw BackendTransportError(.invalidMessage) }
        refreshError = try c.decodeIfPresent(String.self, forKey: .refreshError)
    }
}

// Keep additive terminal payloads out of the common message's inline storage.
// This immutable box also avoids large debug-stack frames in unrelated decoders.
final class StructureReply: Codable, Equatable, Sendable {
    let baseline: StructureBaseline?
    let plan: StructurePlan?
    let outcome: StructureOutcome?

    init(baseline: StructureBaseline? = nil, plan: StructurePlan? = nil, outcome: StructureOutcome? = nil) {
        self.baseline = baseline; self.plan = plan; self.outcome = outcome
    }
    private enum CodingKeys: String, CodingKey { case baseline, plan, outcome }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["baseline", "plan", "outcome"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.baseline), try c.decodeNil(forKey: .baseline) { throw BackendTransportError(.invalidMessage) }
        if c.contains(.plan), try c.decodeNil(forKey: .plan) { throw BackendTransportError(.invalidMessage) }
        if c.contains(.outcome), try c.decodeNil(forKey: .outcome) { throw BackendTransportError(.invalidMessage) }
        baseline = try c.decodeIfPresent(StructureBaseline.self, forKey: .baseline)
        plan = try c.decodeIfPresent(StructurePlan.self, forKey: .plan)
        outcome = try c.decodeIfPresent(StructureOutcome.self, forKey: .outcome)
    }
    static func == (a: StructureReply, b: StructureReply) -> Bool { a.baseline == b.baseline && a.plan == b.plan && a.outcome == b.outcome }
}

struct StructureColumnChange: Codable, Equatable, Sendable {
    var name: String
    var nullable: Bool?
    var `default`: StructureDefault?
    var type: StructureDataType?
}
extension StructureColumnChange {
    private enum CodingKeys: String, CodingKey { case name, nullable, `default`, type }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["name", "nullable", "default", "type"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        if c.contains(.nullable), try c.decodeNil(forKey: .nullable) { throw BackendTransportError(.invalidMessage) }
        nullable = try c.decodeIfPresent(Bool.self, forKey: .nullable)
        if c.contains(.`default`), try c.decodeNil(forKey: .`default`) { throw BackendTransportError(.invalidMessage) }
        self.`default` = try c.decodeIfPresent(StructureDefault.self, forKey: .`default`)
        if c.contains(.type), try c.decodeNil(forKey: .type) { throw BackendTransportError(.invalidMessage) }
        type = try c.decodeIfPresent(StructureDataType.self, forKey: .type)
    }
}

struct StructureIndex: Codable, Equatable, Sendable {
    var name: String
    var columns: [String]
    var unique: Bool
    var supported: Bool
    var owner: String?
}
extension StructureIndex {
    private enum CodingKeys: String, CodingKey { case name, columns, unique, supported, owner }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["name", "columns", "unique", "supported", "owner"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        columns = try c.decode([String].self, forKey: .columns)
        unique = try c.decode(Bool.self, forKey: .unique)
        supported = try c.decode(Bool.self, forKey: .supported)
        if c.contains(.owner), try c.decodeNil(forKey: .owner) { throw BackendTransportError(.invalidMessage) }
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
    }
}

struct StructureIndexEdit: Codable, Equatable, Sendable {
    var action: String
    var name: String
    var columns: [String]?
    var unique: Bool?
}
extension StructureIndexEdit {
    private enum CodingKeys: String, CodingKey { case action, name, columns, unique }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["action", "name", "columns", "unique"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        name = try c.decode(String.self, forKey: .name)
        if c.contains(.columns), try c.decodeNil(forKey: .columns) { throw BackendTransportError(.invalidMessage) }
        columns = try c.decodeIfPresent([String].self, forKey: .columns)
        if c.contains(.unique), try c.decodeNil(forKey: .unique) { throw BackendTransportError(.invalidMessage) }
        unique = try c.decodeIfPresent(Bool.self, forKey: .unique)
    }
}

struct StructureKey: Codable, Equatable, Sendable {
    var kind: String
    var name: String
    var columns: [String]
    var reference: StructureTarget?
    var referenceColumns: [String]?
    var onUpdate: String?
    var onDelete: String?
    var supported: Bool
}
extension StructureKey {
    private enum CodingKeys: String, CodingKey { case kind, name, columns, reference, referenceColumns, onUpdate, onDelete, supported }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["kind", "name", "columns", "reference", "referenceColumns", "onUpdate", "onDelete", "supported"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        columns = try c.decode([String].self, forKey: .columns)
        if c.contains(.reference), try c.decodeNil(forKey: .reference) { throw BackendTransportError(.invalidMessage) }
        reference = try c.decodeIfPresent(StructureTarget.self, forKey: .reference)
        if c.contains(.referenceColumns), try c.decodeNil(forKey: .referenceColumns) { throw BackendTransportError(.invalidMessage) }
        referenceColumns = try c.decodeIfPresent([String].self, forKey: .referenceColumns)
        if c.contains(.onUpdate), try c.decodeNil(forKey: .onUpdate) { throw BackendTransportError(.invalidMessage) }
        onUpdate = try c.decodeIfPresent(String.self, forKey: .onUpdate)
        if c.contains(.onDelete), try c.decodeNil(forKey: .onDelete) { throw BackendTransportError(.invalidMessage) }
        onDelete = try c.decodeIfPresent(String.self, forKey: .onDelete)
        supported = try c.decode(Bool.self, forKey: .supported)
    }
}

struct StructureKeyEdit: Codable, Equatable, Sendable {
    var action: String
    var kind: String
    var name: String
    var columns: [String]?
    var reference: StructureTarget?
    var referenceColumns: [String]?
    var onUpdate: String?
    var onDelete: String?
}
extension StructureKeyEdit {
    private enum CodingKeys: String, CodingKey { case action, kind, name, columns, reference, referenceColumns, onUpdate, onDelete }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["action", "kind", "name", "columns", "reference", "referenceColumns", "onUpdate", "onDelete"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        kind = try c.decode(String.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        if c.contains(.columns), try c.decodeNil(forKey: .columns) { throw BackendTransportError(.invalidMessage) }
        columns = try c.decodeIfPresent([String].self, forKey: .columns)
        if c.contains(.reference), try c.decodeNil(forKey: .reference) { throw BackendTransportError(.invalidMessage) }
        reference = try c.decodeIfPresent(StructureTarget.self, forKey: .reference)
        if c.contains(.referenceColumns), try c.decodeNil(forKey: .referenceColumns) { throw BackendTransportError(.invalidMessage) }
        referenceColumns = try c.decodeIfPresent([String].self, forKey: .referenceColumns)
        if c.contains(.onUpdate), try c.decodeNil(forKey: .onUpdate) { throw BackendTransportError(.invalidMessage) }
        onUpdate = try c.decodeIfPresent(String.self, forKey: .onUpdate)
        if c.contains(.onDelete), try c.decodeNil(forKey: .onDelete) { throw BackendTransportError(.invalidMessage) }
        onDelete = try c.decodeIfPresent(String.self, forKey: .onDelete)
    }
}

private struct StructureCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
extension StructureTarget {
    static func identifier(_ s: String) -> Bool { !s.isEmpty && s.utf8.count <= 63 && !s.contains("\0") }
    var valid: Bool { Self.identifier(schema) && Self.identifier(table) }
    static func columns(_ values: [String]) -> Bool { !values.isEmpty && values.count <= 32 && Set(values.map { Data($0.utf8) }).count == values.count && values.allSatisfy(identifier) }
}
extension StructureDataType {
    var valid: Bool {
        switch kind {
        case "integer", "bigint", "boolean", "text", "real", "blob", "any", "sqliteNumeric": (length ?? 0) == 0 && (precision ?? 0) == 0 && (scale ?? 0) == 0
        case "varchar": (1...16_383).contains(length ?? 0) && (precision ?? 0) == 0 && (scale ?? 0) == 0
        case "numeric": (length ?? 0) == 0 && (1...65).contains(precision ?? 0) && (0...30).contains(scale ?? 0) && (scale ?? 0) <= (precision ?? 0)
        default: false
        }
    }
}
extension StructureDefault {
    var valid: Bool {
        if ["none", "null"].contains(kind) { return value == nil }
        return ["text", "numeric", "boolean"].contains(kind) && value.map { $0.utf8.count <= 4096 && !$0.contains("\0") } == true
    }
}
extension StructureColumnChange {
    var valid: Bool { StructureTarget.identifier(name) && (nullable != nil || self.default != nil || type != nil) && (self.default?.valid ?? true) && (type?.valid ?? true) && !(nullable == false && self.default?.kind == "null") }
}
extension StructureIndexEdit {
    var valid: Bool { ["add", "drop", "replace"].contains(action) && StructureTarget.identifier(name) && (action == "drop" ? (columns?.isEmpty ?? true) && unique != true : StructureTarget.columns(columns ?? [])) }
}
extension StructureKeyEdit {
    static let actions = ["NO ACTION", "RESTRICT", "CASCADE", "SET NULL"]
    var valid: Bool {
        guard ["add", "drop", "replace"].contains(action), ["primary", "unique", "foreign"].contains(kind), StructureTarget.identifier(name) else { return false }
        if action == "drop" { return (columns?.isEmpty ?? true) && reference == nil && (referenceColumns?.isEmpty ?? true) && onUpdate == nil && onDelete == nil }
        guard StructureTarget.columns(columns ?? []) else { return false }
        if kind == "foreign" { return reference?.valid == true && reference?.create == false && reference?.reconcile != true && StructureTarget.columns(referenceColumns ?? []) && columns?.count == referenceColumns?.count && Self.actions.contains(onUpdate ?? "") && Self.actions.contains(onDelete ?? "") }
        return reference == nil && (referenceColumns?.isEmpty ?? true) && onUpdate == nil && onDelete == nil
    }
}
extension StructureDraft {
    var destructive: Bool { (indexes ?? []).contains { $0.action != "add" } || (keys ?? []).contains { $0.action != "add" } }
    var valid: Bool {
        let changes = changes ?? []; let indexes = indexes ?? []; let keys = keys ?? []
        guard columns.count <= 128, changes.count + indexes.count + keys.count <= 64,
              columns.count + changes.count + indexes.count + keys.count > 0,
              Set((columns.map(\.name) + changes.map(\.name)).map { Data($0.utf8) }).count == columns.count + changes.count,
              Set(indexes.map { Data($0.name.utf8) }).count == indexes.count, Set(keys.map { Data($0.name.utf8) }).count == keys.count,
              !destructive || allowDestructive == true else { return false }
        return columns.allSatisfy { StructureTarget.identifier($0.name) && $0.type.valid && $0.default.valid && ($0.nullable || $0.default.kind != "null") } && changes.allSatisfy(\.valid) && indexes.allSatisfy(\.valid) && keys.allSatisfy(\.valid)
    }
}
extension StructureApply {
    var valid: Bool { BackendMessage.validID(planId) && BackendMessage.validID(executionId) && StructureBaseline.digest(digest) }
}
extension StructureRequest {
    func valid(for type: String) -> Bool {
        switch type {
        case "structure.load": return target?.valid == true && (target?.reconcile != true || target?.create == true) && baselineId == nil && draft == nil && apply == nil
        case "structure.preview": return target == nil && baselineId.map(BackendMessage.validID) == true && draft?.valid == true && apply == nil
        case "structure.apply": return target == nil && baselineId == nil && draft == nil && apply?.valid == true
        case "structure.status", "structure.close": return target == nil && baselineId == nil && draft == nil && apply == nil
        default: return false
        }
    }
}
extension StructureBaseline {
    static func digest(_ s: String) -> Bool { s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    var valid: Bool {
        BackendMessage.validID(id) && target.valid && target.reconcile != true && ["postgresql", "mysql", "sqlite"].contains(engine) && Self.digest(fingerprint) && columns.count <= 128 && limitations.count <= 64 && limitations.allSatisfy { $0.utf8.count <= 4096 } && columns.allSatisfy {
            StructureTarget.identifier($0.name) && $0.nativeType.utf8.count <= 4096 && ($0.defaultExpression?.utf8.count ?? 0) <= 65_536 && ($0.editableType?.valid ?? true)
        } && (keys?.count ?? 0) <= 256 && (indexes?.count ?? 0) <= 256 && (keys ?? []).allSatisfy {
            StructureTarget.identifier($0.name) && ["primary", "unique", "foreign", "unsupported"].contains($0.kind) && $0.columns.count <= 32 && $0.columns.allSatisfy(StructureTarget.identifier) && ($0.reference?.valid ?? true) && ($0.referenceColumns?.count ?? 0) <= 32
        } && (indexes ?? []).allSatisfy { StructureTarget.identifier($0.name) && $0.columns.count <= 32 && $0.columns.allSatisfy(StructureTarget.identifier) && ($0.owner.map(StructureTarget.identifier) ?? true) }
    }
}
extension StructurePlan {
    var valid: Bool {
        BackendMessage.validID(id) && BackendMessage.validID(baselineId) && StructureBaseline.digest(digest) && target.valid && target.reconcile != true && !sql.isEmpty && sql.count <= 64 && sql.reduce(0) { $0 + $1.utf8.count } <= 1_048_576 && sql.allSatisfy { !$0.isEmpty && !$0.contains("\0") } && risks.count <= 64 && risks.allSatisfy { $0.utf8.count <= 4096 }
    }
}
extension StructureOutcome {
    var valid: Bool {
        guard BackendMessage.validID(executionId), BackendMessage.validID(planId), !steps.isEmpty, steps.count <= 64,
              ["applied", "failed", "partiallyApplied", "cancelled", "outcomeUnknown", "applying"].contains(state),
              steps.allSatisfy({ ["notStarted", "applied", "failed", "rolledBack", "unknown"].contains($0.state) && ($0.message?.utf8.count ?? 0) <= 4096 }),
              (refreshError?.utf8.count ?? 0) <= 4096, observed?.valid ?? true else { return false }
        var stopped = false
        for step in steps { if stopped && step.state != "notStarted" { return false }; if step.state != "applied" { stopped = true } }
        let applied = steps.filter { $0.state == "applied" }.count; let unknown = steps.contains { $0.state == "unknown" }
        switch state {
        case "applied": return applied == steps.count
        case "partiallyApplied": return applied > 0 && applied < steps.count && !unknown
        case "outcomeUnknown": return unknown
        case "applying": return !unknown && steps.allSatisfy { ["applied", "notStarted"].contains($0.state) }
        default: return applied == 0 && !unknown
        }
    }
}
extension StructureReply {
    func valid(for type: String) -> Bool {
        switch type {
        case "structure.load.result": baseline?.valid == true && plan == nil && outcome == nil
        case "structure.preview.result": baseline == nil && plan?.valid == true && outcome == nil
        case "structure.apply.result": baseline == nil && plan == nil && outcome?.valid == true
        case "structure.status.result": baseline == nil && plan == nil && (outcome?.valid ?? true)
        case "structure.close.result": baseline == nil && plan == nil && outcome == nil
        default: false
        }
    }
}

extension StructureTarget {
    static func sameIdentifier(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    static func == (a: Self, b: Self) -> Bool { sameIdentifier(a.schema, b.schema) && sameIdentifier(a.table, b.table) && a.create == b.create && a.reconcile == b.reconcile }
    static func intentBytes<T: Encodable>(_ value: T) -> Data? { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return try? encoder.encode(value) }
}
extension StructureDraft { static func == (a: Self, b: Self) -> Bool { StructureTarget.intentBytes(a) == StructureTarget.intentBytes(b) } }
extension StructurePlan { static func == (a: Self, b: Self) -> Bool { StructureTarget.intentBytes(a) == StructureTarget.intentBytes(b) } }
