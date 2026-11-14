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
    var reference: StructureTypeReference? = nil
}
extension StructureDataType {
    private enum CodingKeys: String, CodingKey { case kind, length, precision, scale, reference }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["kind", "length", "precision", "scale", "reference"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        if c.contains(.length), try c.decodeNil(forKey: .length) { throw BackendTransportError(.invalidMessage) }
        length = try c.decodeIfPresent(Int.self, forKey: .length)
        if c.contains(.precision), try c.decodeNil(forKey: .precision) { throw BackendTransportError(.invalidMessage) }
        precision = try c.decodeIfPresent(Int.self, forKey: .precision)
        if c.contains(.scale), try c.decodeNil(forKey: .scale) { throw BackendTransportError(.invalidMessage) }
        scale = try c.decodeIfPresent(Int.self, forKey: .scale)
        if c.contains(.reference), try c.decodeNil(forKey: .reference) { throw BackendTransportError(.invalidMessage) }
        reference = try c.decodeIfPresent(StructureTypeReference.self, forKey: .reference)
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
    var generated: StructureGeneration? = nil
    var identity: StructureIdentity? = nil
}
extension StructureColumn {
    private enum CodingKeys: String, CodingKey { case name, type, nullable, `default`, generated, identity }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["name", "type", "nullable", "default", "generated", "identity"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(StructureDataType.self, forKey: .type)
        nullable = try c.decode(Bool.self, forKey: .nullable)
        self.`default` = try c.decode(StructureDefault.self, forKey: .`default`)
        if c.contains(.generated), try c.decodeNil(forKey: .generated) { throw BackendTransportError(.invalidMessage) }
        generated = try c.decodeIfPresent(StructureGeneration.self, forKey: .generated)
        if c.contains(.identity), try c.decodeNil(forKey: .identity) { throw BackendTransportError(.invalidMessage) }
        identity = try c.decodeIfPresent(StructureIdentity.self, forKey: .identity)
    }
}

struct StructureBackfill: Codable, Equatable, Sendable {
    var column: String
    var expression: String
    private enum CodingKeys: String, CodingKey { case column, expression }
    init(column: String, expression: String) { self.column = column; self.expression = expression }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == ["column", "expression"] else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        column = try c.decode(String.self, forKey: .column)
        expression = try c.decode(String.self, forKey: .expression)
    }
}

struct StructureDraft: Codable, Equatable, Sendable {
    var columns: [StructureColumn]
    var changes: [StructureColumnChange]?
    var indexes: [StructureIndexEdit]?
    var keys: [StructureKeyEdit]?
    var allowDestructive: Bool?
    var renameTable: String? = nil
    var authoringVersion: Int? = nil
    var dropTable: Bool = false
    var backfills: [StructureBackfill]? = nil
    var columnOrder: [String]? = nil
    var reconstruct: Bool? = nil
}
extension StructureDraft {
    private enum CodingKeys: String, CodingKey { case columns, changes, indexes, keys, allowDestructive, renameTable, authoringVersion, dropTable, backfills, columnOrder, reconstruct }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["columns", "changes", "indexes", "keys", "allowDestructive", "renameTable", "authoringVersion", "dropTable", "backfills", "columnOrder", "reconstruct"]) else { throw BackendTransportError(.invalidMessage) }
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
        if c.contains(.renameTable), try c.decodeNil(forKey: .renameTable) { throw BackendTransportError(.invalidMessage) }
        renameTable = try c.decodeIfPresent(String.self, forKey: .renameTable)
        if c.contains(.authoringVersion), try c.decodeNil(forKey: .authoringVersion) { throw BackendTransportError(.invalidMessage) }
        authoringVersion = try c.decodeIfPresent(Int.self, forKey: .authoringVersion)
        if c.contains(.dropTable), try c.decodeNil(forKey: .dropTable) { throw BackendTransportError(.invalidMessage) }
        dropTable = try c.decodeIfPresent(Bool.self, forKey: .dropTable) ?? false
        for key in [CodingKeys.backfills, .columnOrder, .reconstruct] {
            if c.contains(key), try c.decodeNil(forKey: key) { throw BackendTransportError(.invalidMessage) }
            if c.contains(key), authoringVersion != 5 { throw BackendTransportError(.invalidMessage) }
        }
        backfills = try c.decodeIfPresent([StructureBackfill].self, forKey: .backfills)
        columnOrder = try c.decodeIfPresent([String].self, forKey: .columnOrder)
        reconstruct = try c.decodeIfPresent(Bool.self, forKey: .reconstruct)
        if authoringVersion != 4 && authoringVersion != 5 {
            guard !c.contains(.dropTable) else { throw BackendTransportError(.invalidMessage) }
            if c.contains(.changes) {
                var entries = try c.nestedUnkeyedContainer(forKey: .changes)
                while !entries.isAtEnd {
                    let change = try entries.nestedContainer(keyedBy: StructureCodingKey.self)
                    guard !change.allKeys.contains(where: { ["drop", "usingExpression", "unsigned", "charset", "collation"].contains($0.stringValue) }) else { throw BackendTransportError(.invalidMessage) }
                }
            }
        }
    }
}

struct StructureObservedColumn: Codable, Equatable, Sendable {
    var name: String
    var nativeType: String
    var nullable: Bool
    var defaultExpression: String?
    var editableType: StructureDataType?
    var canModify: Bool?
    var unsigned: Bool? = nil
    var charset: String? = nil
    var collation: StructureTypeReference? = nil
}
extension StructureObservedColumn {
    private enum CodingKeys: String, CodingKey { case name, nativeType, nullable, defaultExpression, editableType, canModify, unsigned, charset, collation }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["name", "nativeType", "nullable", "defaultExpression", "editableType", "canModify", "unsigned", "charset", "collation"]) else { throw BackendTransportError(.invalidMessage) }
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
        if c.contains(.unsigned), try c.decodeNil(forKey: .unsigned) { throw BackendTransportError(.invalidMessage) }
        unsigned = try c.decodeIfPresent(Bool.self, forKey: .unsigned) ?? nil
        if c.contains(.charset), try c.decodeNil(forKey: .charset) { throw BackendTransportError(.invalidMessage) }
        charset = try c.decodeIfPresent(String.self, forKey: .charset) ?? nil
        if c.contains(.collation), try c.decodeNil(forKey: .collation) { throw BackendTransportError(.invalidMessage) }
        collation = try c.decodeIfPresent(StructureTypeReference.self, forKey: .collation) ?? nil
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
    var advanced: StructureAdvancedKindSupport? = nil
}
extension StructureBaseline {
    private enum CodingKeys: String, CodingKey { case id, target, engine, fingerprint, columns, limitations, keys, indexes, dependencyProof, advanced }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["id", "target", "engine", "fingerprint", "columns", "limitations", "keys", "indexes", "dependencyProof", "advanced"]) else { throw BackendTransportError(.invalidMessage) }
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
        if c.contains(.advanced), try c.decodeNil(forKey: .advanced) { throw BackendTransportError(.invalidMessage) }
        advanced = try c.decodeIfPresent(StructureAdvancedKindSupport.self, forKey: .advanced)
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
    var resultTarget: StructureTarget? = nil
    var droppedTarget: Bool = false
    var consequences: [StructureConsequence] = []
    var validationChecks: [StructureValidationCheck] = []
}
extension StructurePlan {
    private enum CodingKeys: String, CodingKey { case id, baselineId, digest, target, sql, risks, destructive, resultTarget, droppedTarget, consequences, validationChecks }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["id", "baselineId", "digest", "target", "sql", "risks", "destructive", "resultTarget", "droppedTarget", "consequences", "validationChecks"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        baselineId = try c.decode(String.self, forKey: .baselineId)
        digest = try c.decode(String.self, forKey: .digest)
        target = try c.decode(StructureTarget.self, forKey: .target)
        sql = try c.decode([String].self, forKey: .sql)
        risks = try c.decode([String].self, forKey: .risks)
        if c.contains(.destructive), try c.decodeNil(forKey: .destructive) { throw BackendTransportError(.invalidMessage) }
        destructive = try c.decodeIfPresent(Bool.self, forKey: .destructive)
        if c.contains(.resultTarget), try c.decodeNil(forKey: .resultTarget) { throw BackendTransportError(.invalidMessage) }
        resultTarget = try c.decodeIfPresent(StructureTarget.self, forKey: .resultTarget)
        if c.contains(.droppedTarget), try c.decodeNil(forKey: .droppedTarget) { throw BackendTransportError(.invalidMessage) }
        droppedTarget = try c.decodeIfPresent(Bool.self, forKey: .droppedTarget) ?? false
        if c.contains(.consequences), try c.decodeNil(forKey: .consequences) { throw BackendTransportError(.invalidMessage) }
        consequences = try c.decodeIfPresent([StructureConsequence].self, forKey: .consequences) ?? []
        if c.contains(.validationChecks), try c.decodeNil(forKey: .validationChecks) { throw BackendTransportError(.invalidMessage) }
        validationChecks = try c.decodeIfPresent([StructureValidationCheck].self, forKey: .validationChecks) ?? []
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
    var validation: StructureApply? = nil
    var migration: StructureMigrationRequest? = nil
    var physical: StructurePhysicalRequest? = nil
}
extension StructureRequest {
    private enum CodingKeys: String, CodingKey { case target, baselineId, draft, apply, validation, migration, physical }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["target", "baselineId", "draft", "apply", "validation", "migration", "physical"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.target), try c.decodeNil(forKey: .target) { throw BackendTransportError(.invalidMessage) }
        target = try c.decodeIfPresent(StructureTarget.self, forKey: .target)
        if c.contains(.baselineId), try c.decodeNil(forKey: .baselineId) { throw BackendTransportError(.invalidMessage) }
        baselineId = try c.decodeIfPresent(String.self, forKey: .baselineId)
        if c.contains(.draft), try c.decodeNil(forKey: .draft) { throw BackendTransportError(.invalidMessage) }
        draft = try c.decodeIfPresent(StructureDraft.self, forKey: .draft)
        if c.contains(.apply), try c.decodeNil(forKey: .apply) { throw BackendTransportError(.invalidMessage) }
        apply = try c.decodeIfPresent(StructureApply.self, forKey: .apply)
        if c.contains(.validation), try c.decodeNil(forKey: .validation) { throw BackendTransportError(.invalidMessage) }
        validation = try c.decodeIfPresent(StructureApply.self, forKey: .validation) ?? nil
        if c.contains(.migration), try c.decodeNil(forKey: .migration) { throw BackendTransportError(.invalidMessage) }
        migration = try c.decodeIfPresent(StructureMigrationRequest.self, forKey: .migration)
        if c.contains(.physical), try c.decodeNil(forKey: .physical) { throw BackendTransportError(.invalidMessage) }
        physical = try c.decodeIfPresent(StructurePhysicalRequest.self, forKey: .physical)
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
    var droppedTarget: Bool = false
}
extension StructureOutcome {
    private enum CodingKeys: String, CodingKey { case executionId, planId, state, steps, observed, refreshError, droppedTarget }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["executionId", "planId", "state", "steps", "observed", "refreshError", "droppedTarget"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        executionId = try c.decode(String.self, forKey: .executionId)
        planId = try c.decode(String.self, forKey: .planId)
        state = try c.decode(String.self, forKey: .state)
        steps = try c.decode([StructureStepOutcome].self, forKey: .steps)
        if c.contains(.observed), try c.decodeNil(forKey: .observed) { throw BackendTransportError(.invalidMessage) }
        observed = try c.decodeIfPresent(StructureBaseline.self, forKey: .observed)
        if c.contains(.refreshError), try c.decodeNil(forKey: .refreshError) { throw BackendTransportError(.invalidMessage) }
        refreshError = try c.decodeIfPresent(String.self, forKey: .refreshError)
        if c.contains(.droppedTarget), try c.decodeNil(forKey: .droppedTarget) { throw BackendTransportError(.invalidMessage) }
        droppedTarget = try c.decodeIfPresent(Bool.self, forKey: .droppedTarget) ?? false
    }
}

// Keep additive terminal payloads out of the common message's inline storage.
// This immutable box also avoids large debug-stack frames in unrelated decoders.
final class StructureReply: Codable, Equatable, Sendable {
    let baseline: StructureBaseline?
    let plan: StructurePlan?
    let outcome: StructureOutcome?
    let validation: StructureValidationOutcome?
    let migration: StructureMigrationReply?
    let physical: StructurePhysicalReply?

    init(baseline: StructureBaseline? = nil, plan: StructurePlan? = nil, outcome: StructureOutcome? = nil, validation: StructureValidationOutcome? = nil, migration: StructureMigrationReply? = nil, physical: StructurePhysicalReply? = nil) {
        self.baseline = baseline; self.plan = plan; self.outcome = outcome; self.validation = validation; self.migration = migration; self.physical = physical
    }
    private enum CodingKeys: String, CodingKey { case baseline, plan, outcome, validation, migration, physical }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["baseline", "plan", "outcome", "validation", "migration", "physical"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.baseline), try c.decodeNil(forKey: .baseline) { throw BackendTransportError(.invalidMessage) }
        if c.contains(.plan), try c.decodeNil(forKey: .plan) { throw BackendTransportError(.invalidMessage) }
        if c.contains(.outcome), try c.decodeNil(forKey: .outcome) { throw BackendTransportError(.invalidMessage) }
        baseline = try c.decodeIfPresent(StructureBaseline.self, forKey: .baseline)
        plan = try c.decodeIfPresent(StructurePlan.self, forKey: .plan)
        outcome = try c.decodeIfPresent(StructureOutcome.self, forKey: .outcome)
        if c.contains(.validation), try c.decodeNil(forKey: .validation) { throw BackendTransportError(.invalidMessage) }
        validation = try c.decodeIfPresent(StructureValidationOutcome.self, forKey: .validation)
        if c.contains(.migration), try c.decodeNil(forKey: .migration) { throw BackendTransportError(.invalidMessage) }
        migration = try c.decodeIfPresent(StructureMigrationReply.self, forKey: .migration)
        if c.contains(.physical), try c.decodeNil(forKey: .physical) { throw BackendTransportError(.invalidMessage) }
        physical = try c.decodeIfPresent(StructurePhysicalReply.self, forKey: .physical)
    }
    static func == (a: StructureReply, b: StructureReply) -> Bool { a.baseline == b.baseline && a.plan == b.plan && a.outcome == b.outcome && a.validation == b.validation && a.migration == b.migration && a.physical == b.physical }
}

struct StructureColumnChange: Codable, Equatable, Sendable {
    var name: String
    var nullable: Bool?
    var `default`: StructureDefault?
    var type: StructureDataType?
    var renameTo: String? = nil
    var generated: StructureGeneration? = nil
    var identity: StructureIdentity? = nil
    var drop: Bool = false
    var usingExpression: String? = nil
    var unsigned: Bool? = nil
    var charset: String? = nil
    var collation: StructureTypeReference? = nil
}
extension StructureColumnChange {
    private enum CodingKeys: String, CodingKey { case name, nullable, `default`, type, renameTo, generated, identity, drop, usingExpression, unsigned, charset, collation }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["name", "nullable", "default", "type", "renameTo", "generated", "identity", "drop", "usingExpression", "unsigned", "charset", "collation"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        if c.contains(.nullable), try c.decodeNil(forKey: .nullable) { throw BackendTransportError(.invalidMessage) }
        nullable = try c.decodeIfPresent(Bool.self, forKey: .nullable)
        if c.contains(.`default`), try c.decodeNil(forKey: .`default`) { throw BackendTransportError(.invalidMessage) }
        self.`default` = try c.decodeIfPresent(StructureDefault.self, forKey: .`default`)
        if c.contains(.type), try c.decodeNil(forKey: .type) { throw BackendTransportError(.invalidMessage) }
        type = try c.decodeIfPresent(StructureDataType.self, forKey: .type)
        if c.contains(.renameTo), try c.decodeNil(forKey: .renameTo) { throw BackendTransportError(.invalidMessage) }
        renameTo = try c.decodeIfPresent(String.self, forKey: .renameTo)
        if c.contains(.generated), try c.decodeNil(forKey: .generated) { throw BackendTransportError(.invalidMessage) }
        generated = try c.decodeIfPresent(StructureGeneration.self, forKey: .generated)
        if c.contains(.identity), try c.decodeNil(forKey: .identity) { throw BackendTransportError(.invalidMessage) }
        identity = try c.decodeIfPresent(StructureIdentity.self, forKey: .identity)
        if c.contains(.drop), try c.decodeNil(forKey: .drop) { throw BackendTransportError(.invalidMessage) }
        drop = try c.decodeIfPresent(Bool.self, forKey: .drop) ?? false
        if c.contains(.usingExpression), try c.decodeNil(forKey: .usingExpression) { throw BackendTransportError(.invalidMessage) }
        usingExpression = try c.decodeIfPresent(String.self, forKey: .usingExpression) ?? nil
        if c.contains(.unsigned), try c.decodeNil(forKey: .unsigned) { throw BackendTransportError(.invalidMessage) }
        unsigned = try c.decodeIfPresent(Bool.self, forKey: .unsigned) ?? nil
        if c.contains(.charset), try c.decodeNil(forKey: .charset) { throw BackendTransportError(.invalidMessage) }
        charset = try c.decodeIfPresent(String.self, forKey: .charset) ?? nil
        if c.contains(.collation), try c.decodeNil(forKey: .collation) { throw BackendTransportError(.invalidMessage) }
        collation = try c.decodeIfPresent(StructureTypeReference.self, forKey: .collation) ?? nil
    }
}

struct StructureIndex: Codable, Equatable, Sendable {
    var name: String
    var columns: [String]
    var unique: Bool
    var supported: Bool
    var owner: String?
    var definition: StructureIndexDefinition? = nil
}
extension StructureIndex {
    private enum CodingKeys: String, CodingKey { case name, columns, unique, supported, owner, definition }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["name", "columns", "unique", "supported", "owner", "definition"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        columns = try c.decode([String].self, forKey: .columns)
        unique = try c.decode(Bool.self, forKey: .unique)
        supported = try c.decode(Bool.self, forKey: .supported)
        if c.contains(.owner), try c.decodeNil(forKey: .owner) { throw BackendTransportError(.invalidMessage) }
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        if c.contains(.definition), try c.decodeNil(forKey: .definition) { throw BackendTransportError(.invalidMessage) }
        definition = try c.decodeIfPresent(StructureIndexDefinition.self, forKey: .definition)
    }
}

struct StructureIndexEdit: Codable, Equatable, Sendable {
    var action: String
    var name: String
    var columns: [String]?
    var unique: Bool?
    var definition: StructureIndexDefinition? = nil
}
extension StructureIndexEdit {
    private enum CodingKeys: String, CodingKey { case action, name, columns, unique, definition }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["action", "name", "columns", "unique", "definition"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        name = try c.decode(String.self, forKey: .name)
        if c.contains(.columns), try c.decodeNil(forKey: .columns) { throw BackendTransportError(.invalidMessage) }
        columns = try c.decodeIfPresent([String].self, forKey: .columns)
        if c.contains(.unique), try c.decodeNil(forKey: .unique) { throw BackendTransportError(.invalidMessage) }
        unique = try c.decodeIfPresent(Bool.self, forKey: .unique)
        if c.contains(.definition), try c.decodeNil(forKey: .definition) { throw BackendTransportError(.invalidMessage) }
        definition = try c.decodeIfPresent(StructureIndexDefinition.self, forKey: .definition)
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
        if kind == "reference" { return reference?.valid == true && (length ?? 0) == 0 && (precision ?? 0) == 0 && (scale ?? 0) == 0 }
        guard reference == nil else { return false }
        return switch kind {
        case "integer", "bigint", "boolean", "text", "real", "blob", "any", "sqliteNumeric": (length ?? 0) == 0 && (precision ?? 0) == 0 && (scale ?? 0) == 0
        case "varchar": (1...16_383).contains(length ?? 0) && (precision ?? 0) == 0 && (scale ?? 0) == 0
        case "numeric": (length ?? 0) == 0 && (1...65).contains(precision ?? 0) && (0...38).contains(scale ?? 0) && (scale ?? 0) <= (precision ?? 0)
        default: false
        }
    }
}
extension StructureDefault {
    var valid: Bool {
        if ["none", "null"].contains(kind) { return value == nil }
        return ["text", "numeric", "boolean", "expression"].contains(kind) && value.map { $0.utf8.count <= 4096 && !$0.contains("\0") } == true
    }
}
extension StructureColumnChange {
    var valid: Bool { destructiveIntentValid && StructureTarget.identifier(name) && (nullable != nil || self.default != nil || type != nil || renameTo != nil || generated != nil || identity != nil || drop || unsigned != nil || charset != nil || collation != nil) && (self.default?.valid ?? true) && (type?.valid ?? true) && !(nullable == false && self.default?.kind == "null") && (renameTo.map { StructureTarget.identifier($0) && !StructureTarget.sameIdentifier($0, name) } ?? true) && (generated?.valid ?? true) && (identity?.valid ?? true) && !(generated?.storage != nil && generated?.storage != "none" && (self.default != nil || identity?.kind != nil && identity?.kind != "none")) }
}
extension StructureIndexEdit {
    var valid: Bool {
        guard ["add", "drop", "replace"].contains(action), StructureTarget.identifier(name) else { return false }
        if action == "drop" { return (columns?.isEmpty ?? true) && unique != true && definition == nil }
        if let definition { return columns == nil && definition.valid }
        return StructureTarget.columns(columns ?? [])
    }
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
    var destructive: Bool { hasReconstructionIntent || requiresDestructiveAuthoring || (indexes ?? []).contains { $0.action != "add" } || (keys ?? []).contains { $0.action != "add" } }
    var valid: Bool {
        let changes = changes ?? []; let indexes = indexes ?? []; let keys = keys ?? []
        guard (authoringVersion == nil || authoringVersion == 2 || authoringVersion == 3 || authoringVersion == 4 || authoringVersion == 5), !requiresAuthoringV2 || (authoringVersion ?? 0) >= 2, !requiresIndexAuthoring || (authoringVersion ?? 0) >= 3, !requiresDestructiveAuthoring || (authoringVersion ?? 0) >= 4, reconstructionIntentValid, !dropTable || columns.isEmpty && changes.isEmpty && indexes.isEmpty && keys.isEmpty && renameTable == nil, columns.count <= 128, changes.count + indexes.count + keys.count <= 64,
              columns.count + changes.count + indexes.count + keys.count > 0 || renameTable != nil || dropTable || hasReconstructionIntent,
              renameTable.map(StructureTarget.identifier) ?? true,
              Set((columns.map(\.name) + changes.map(\.name)).map { Data($0.utf8) }).count == columns.count + changes.count,
              Set(indexes.map { Data($0.name.utf8) }).count == indexes.count, Set(keys.map { Data($0.name.utf8) }).count == keys.count,
              !destructive || allowDestructive == true else { return false }
        return columns.allSatisfy(\.valid) && changes.allSatisfy(\.valid) && indexes.allSatisfy(\.valid) && keys.allSatisfy(\.valid)
    }
}
extension StructureApply {
    var valid: Bool { BackendMessage.validID(planId) && BackendMessage.validID(executionId) && StructureBaseline.digest(digest) }
}
extension StructureRequest {
    func valid(for type: String) -> Bool {
        if type.hasPrefix("structure.physical.") { return target == nil && baselineId == nil && draft == nil && apply == nil && validation == nil && migration == nil && physical?.valid(for: type) == true }; guard physical == nil else { return false }
        if type.hasPrefix("structure.migration.") {
            return target == nil && baselineId == nil && draft == nil && apply == nil && validation == nil && migration?.valid(for: type) == true
        }
        guard migration == nil else { return false }
        if type == "structure.validate" { return target == nil && baselineId == nil && draft == nil && apply == nil && validation?.valid == true }
        guard validation == nil else { return false }
        return switch type {
        case "structure.load": target?.valid == true && (target?.reconcile != true || target?.create == true) && baselineId == nil && draft == nil && apply == nil
        case "structure.preview": target == nil && baselineId.map(BackendMessage.validID) == true && draft?.valid == true && apply == nil
        case "structure.apply": target == nil && baselineId == nil && draft == nil && apply?.valid == true
        case "structure.status", "structure.close": target == nil && baselineId == nil && draft == nil && apply == nil
        default: false
        }
    }
}
extension StructureBaseline {
    var requiresIndexAuthoring: Bool { (indexes ?? []).contains { $0.definition != nil } }
    static func digest(_ s: String) -> Bool { s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    var valid: Bool {
        (advanced?.valid(engine: engine) ?? true) && BackendMessage.validID(id) && target.valid && target.reconcile != true && ["postgresql", "mysql", "mariadb", "sqlite"].contains(engine) && (engine != "sqlite" || !requiresIndexAuthoring) && Self.digest(fingerprint) && columns.count <= 128 && limitations.count <= 64 && limitations.allSatisfy { $0.utf8.count <= 4096 } && columns.allSatisfy {
            StructureTarget.identifier($0.name) && $0.nativeType.utf8.count <= 4096 && ($0.defaultExpression?.utf8.count ?? 0) <= 65_536 && ($0.editableType?.valid ?? true) && ($0.editableType?.scale ?? 0) <= (engine == "mariadb" ? 38 : 30) && ($0.charset.map(StructureTarget.identifier) ?? true) && ($0.collation.map { StructureTarget.identifier($0.name) && ($0.schema.isEmpty || StructureTarget.identifier($0.schema)) } ?? true)
        } && (keys?.count ?? 0) <= 256 && (indexes?.count ?? 0) <= 256 && (keys ?? []).allSatisfy {
            StructureTarget.identifier($0.name) && ["primary", "unique", "foreign", "unsupported"].contains($0.kind) && $0.columns.count <= 32 && $0.columns.allSatisfy(StructureTarget.identifier) && ($0.reference?.valid ?? true) && ($0.referenceColumns?.count ?? 0) <= 32
        } && (indexes ?? []).allSatisfy { StructureTarget.identifier($0.name) && $0.columns.count <= 32 && $0.columns.allSatisfy(StructureTarget.identifier) && ($0.owner.map(StructureTarget.identifier) ?? true) && ($0.definition?.valid ?? true) }
    }
}
extension StructurePlan {
    var valid: Bool {
        consequences.count <= 512 && consequences.allSatisfy(\.valid) && validationChecks.count <= 64 && validationChecks.allSatisfy(\.valid) && Set(validationChecks.map(\.id)).count == validationChecks.count && (!droppedTarget || !target.create && resultTarget == nil && destructive == true) && BackendMessage.validID(id) && BackendMessage.validID(baselineId) && StructureBaseline.digest(digest) && target.valid && target.reconcile != true && (resultTarget.map { $0.valid && !$0.create && $0.reconcile != true && StructureTarget.sameIdentifier($0.schema, target.schema) } ?? true) && !sql.isEmpty && sql.count <= 64 && sql.reduce(0) { $0 + $1.utf8.count } <= 1_048_576 && sql.allSatisfy { !$0.isEmpty && !$0.contains("\0") } && risks.count <= 64 && risks.allSatisfy { $0.utf8.count <= 4096 }
    }
}
extension StructureOutcome {
    var valid: Bool {
        guard !droppedTarget || state == "applied" && (observed == nil || observed?.target.create == true), BackendMessage.validID(executionId), BackendMessage.validID(planId), !steps.isEmpty, steps.count <= 64,
              ["applied", "failed", "partiallyApplied", "cancelled", "outcomeUnknown", "applying"].contains(state),
              steps.allSatisfy({ ["notStarted", "applied", "failed", "rolledBack", "unknown"].contains($0.state) && ($0.message?.utf8.count ?? 0) <= 4096 }),
              (refreshError?.utf8.count ?? 0) <= 4096, observed?.valid ?? true else { return false }
        let atomicRollback = steps.first?.state == "rolledBack" && steps.drop(while: { $0.state == "rolledBack" }).allSatisfy { $0.state == "notStarted" }
        let atomicTerminal = atomicRollback || steps.allSatisfy { $0.state == "unknown" }
        var stopped = false
        for step in steps { if !atomicTerminal && stopped && step.state != "notStarted" { return false }; if step.state != "applied" { stopped = true } }
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
        if type.hasPrefix("structure.physical.") { return baseline == nil && plan == nil && outcome == nil && validation == nil && migration == nil && physical?.valid(for: type) == true }; guard physical == nil else { return false }
        if type.hasPrefix("structure.migration.") {
            return baseline == nil && plan == nil && outcome == nil && validation == nil && migration?.valid(for: type) == true
        }
        guard migration == nil else { return false }
        return switch type {
        case "structure.load.result": baseline?.valid == true && plan == nil && outcome == nil && validation == nil
        case "structure.preview.result": baseline == nil && plan?.valid == true && outcome == nil && validation == nil
        case "structure.apply.result": baseline == nil && plan == nil && outcome?.valid == true && validation == nil
        case "structure.validate.result": baseline == nil && plan == nil && outcome == nil && validation?.valid == true
        case "structure.status.result": baseline == nil && plan == nil && (outcome?.valid ?? true) && (validation?.valid ?? true)
        case "structure.close.result": baseline == nil && plan == nil && outcome == nil && validation == nil
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


struct StructureTypeReference: Codable, Equatable, Sendable {
    var schema: String
    var name: String
    var valid: Bool { StructureTarget.identifier(schema) && StructureTarget.identifier(name) }
    private enum CodingKeys: String, CodingKey { case schema, name }
    init(schema: String, name: String) { self.schema = schema; self.name = name }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == ["schema", "name"] else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(String.self, forKey: .schema); name = try c.decode(String.self, forKey: .name)
    }
}
struct StructureGeneration: Codable, Equatable, Sendable {
    var storage: String
    var expression: String?
    var valid: Bool { storage == "none" ? expression == nil || expression == "" : ["stored", "virtual"].contains(storage) && expression.map { !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\0") } == true }
    private enum CodingKeys: String, CodingKey { case storage, expression }
    init(storage: String, expression: String? = nil) { self.storage = storage; self.expression = expression }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["storage", "expression"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        storage = try c.decode(String.self, forKey: .storage)
        if c.contains(.expression), try c.decodeNil(forKey: .expression) { throw BackendTransportError(.invalidMessage) }
        expression = try c.decodeIfPresent(String.self, forKey: .expression)
    }
}
struct StructureIdentity: Codable, Equatable, Sendable {
    var kind: String
    var start: String? = nil
    var increment: String? = nil
    var minimum: String? = nil
    var maximum: String? = nil
    var cache: String? = nil
    var cycle: Bool? = nil
    var valid: Bool {
        guard ["none", "always", "byDefault", "autoIncrement"].contains(kind) else { return false }
        let options = [start, increment, minimum, maximum, cache]
        guard options.allSatisfy({ value in
            guard let value else { return true }; guard let number = Int64(value) else { return false }; return String(number) == value
        }) else { return false }
        if kind == "none" || kind == "autoIncrement" { return options.allSatisfy { $0 == nil } && cycle == nil }
        if increment == "0" || cache.map({ (Int64($0) ?? 0) < 1 }) == true { return false }
        if let minimum, let maximum, let a = Int64(minimum), let b = Int64(maximum), a >= b { return false }
        return true
    }
    private enum CodingKeys: String, CodingKey { case kind, start, increment, minimum, maximum, cache, cycle }
    init(kind: String, start: String? = nil, increment: String? = nil, minimum: String? = nil, maximum: String? = nil, cache: String? = nil, cycle: Bool? = nil) {
        self.kind = kind; self.start = start; self.increment = increment; self.minimum = minimum; self.maximum = maximum; self.cache = cache; self.cycle = cycle
    }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["kind", "start", "increment", "minimum", "maximum", "cache", "cycle"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        if c.contains(.start), try c.decodeNil(forKey: .start) { throw BackendTransportError(.invalidMessage) }
        start = try c.decodeIfPresent(String.self, forKey: .start)
        if c.contains(.increment), try c.decodeNil(forKey: .increment) { throw BackendTransportError(.invalidMessage) }
        increment = try c.decodeIfPresent(String.self, forKey: .increment)
        if c.contains(.minimum), try c.decodeNil(forKey: .minimum) { throw BackendTransportError(.invalidMessage) }
        minimum = try c.decodeIfPresent(String.self, forKey: .minimum)
        if c.contains(.maximum), try c.decodeNil(forKey: .maximum) { throw BackendTransportError(.invalidMessage) }
        maximum = try c.decodeIfPresent(String.self, forKey: .maximum)
        if c.contains(.cache), try c.decodeNil(forKey: .cache) { throw BackendTransportError(.invalidMessage) }
        cache = try c.decodeIfPresent(String.self, forKey: .cache)
        if c.contains(.cycle), try c.decodeNil(forKey: .cycle) { throw BackendTransportError(.invalidMessage) }
        cycle = try c.decodeIfPresent(Bool.self, forKey: .cycle)
    }
}
extension StructureColumn {
    var valid: Bool {
        guard StructureTarget.identifier(name), type.valid, self.default.valid, nullable || self.default.kind != "null", generated?.valid ?? true, identity?.valid ?? true else { return false }
        if let generated, generated.storage != "none", self.default.kind != "none" || identity?.kind != nil && identity?.kind != "none" { return false }
        if let identity, identity.kind != "none", self.default.kind != "none" || nullable || !["integer", "bigint"].contains(type.kind) { return false }
        return true
    }
}

extension StructureDraft {
    var minimumAuthoringVersion: Int? { hasReconstructionIntent ? 5 : hasDestructiveIntent ? 4 : requiresIndexAuthoring ? 3 : requiresAuthoringV2 ? 2 : nil }
    var requiresIndexAuthoring: Bool { (indexes ?? []).contains { $0.definition != nil } }
    var requiresAuthoringV2: Bool {
        !(backfills ?? []).isEmpty || renameTable != nil || columns.contains { $0.type.reference != nil || $0.generated != nil || $0.identity != nil || $0.default.kind == "expression" } ||
        (changes ?? []).contains { $0.renameTo != nil || $0.generated != nil || $0.identity != nil || $0.type?.reference != nil || $0.default?.kind == "expression" }
    }
}

struct StructureIndexOption: Codable, Equatable, Sendable {
    var name: String
    var value: String
}
extension StructureIndexOption {
    private enum CodingKeys: String, CodingKey { case name, value }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["name", "value"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        value = try c.decode(String.self, forKey: .value)
    }
}

struct StructureIndexTerm: Codable, Equatable, Sendable {
    var column: String? = nil
    var expression: String? = nil
    var descending: Bool? = nil
    var nullsFirst: Bool? = nil
    var prefixLength: Int64? = nil
    var collation: StructureTypeReference? = nil
    var opclass: StructureTypeReference? = nil
    var options: [StructureIndexOption]? = nil
}
extension StructureIndexTerm {
    private enum CodingKeys: String, CodingKey { case column, expression, descending, nullsFirst, prefixLength, collation, opclass, options }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["column", "expression", "descending", "nullsFirst", "prefixLength", "collation", "opclass", "options"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.column), try c.decodeNil(forKey: .column) { throw BackendTransportError(.invalidMessage) }
        column = try c.decodeIfPresent(String.self, forKey: .column)
        if c.contains(.expression), try c.decodeNil(forKey: .expression) { throw BackendTransportError(.invalidMessage) }
        expression = try c.decodeIfPresent(String.self, forKey: .expression)
        if c.contains(.descending), try c.decodeNil(forKey: .descending) { throw BackendTransportError(.invalidMessage) }
        descending = try c.decodeIfPresent(Bool.self, forKey: .descending)
        if c.contains(.nullsFirst), try c.decodeNil(forKey: .nullsFirst) { throw BackendTransportError(.invalidMessage) }
        nullsFirst = try c.decodeIfPresent(Bool.self, forKey: .nullsFirst)
        if c.contains(.prefixLength), try c.decodeNil(forKey: .prefixLength) { throw BackendTransportError(.invalidMessage) }
        prefixLength = try c.decodeIfPresent(Int64.self, forKey: .prefixLength)
        if c.contains(.collation), try c.decodeNil(forKey: .collation) { throw BackendTransportError(.invalidMessage) }
        collation = try c.decodeIfPresent(StructureTypeReference.self, forKey: .collation)
        if c.contains(.opclass), try c.decodeNil(forKey: .opclass) { throw BackendTransportError(.invalidMessage) }
        opclass = try c.decodeIfPresent(StructureTypeReference.self, forKey: .opclass)
        if c.contains(.options), try c.decodeNil(forKey: .options) { throw BackendTransportError(.invalidMessage) }
        options = try c.decodeIfPresent([StructureIndexOption].self, forKey: .options)
    }
}

struct StructureIndexDefinition: Codable, Equatable, Sendable {
    var method: String
    var terms: [StructureIndexTerm]
    var includes: [String]? = nil
    var predicate: String? = nil
    var nullsDistinct: Bool? = nil
    var visible: Bool? = nil
    var options: [StructureIndexOption]? = nil
}
extension StructureIndexDefinition {
    private enum CodingKeys: String, CodingKey { case method, terms, includes, predicate, nullsDistinct, visible, options }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["method", "terms", "includes", "predicate", "nullsDistinct", "visible", "options"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decode(String.self, forKey: .method)
        terms = try c.decode([StructureIndexTerm].self, forKey: .terms)
        if c.contains(.includes), try c.decodeNil(forKey: .includes) { throw BackendTransportError(.invalidMessage) }
        includes = try c.decodeIfPresent([String].self, forKey: .includes)
        if c.contains(.predicate), try c.decodeNil(forKey: .predicate) { throw BackendTransportError(.invalidMessage) }
        predicate = try c.decodeIfPresent(String.self, forKey: .predicate)
        if c.contains(.nullsDistinct), try c.decodeNil(forKey: .nullsDistinct) { throw BackendTransportError(.invalidMessage) }
        nullsDistinct = try c.decodeIfPresent(Bool.self, forKey: .nullsDistinct)
        if c.contains(.visible), try c.decodeNil(forKey: .visible) { throw BackendTransportError(.invalidMessage) }
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible)
        if c.contains(.options), try c.decodeNil(forKey: .options) { throw BackendTransportError(.invalidMessage) }
        options = try c.decodeIfPresent([StructureIndexOption].self, forKey: .options)
    }
}

extension StructureIndexOption {
    var valid: Bool { StructureTarget.identifier(name) && value.utf8.count <= 1024 && !value.contains("\0") }
    static func valid(_ options: [Self]?) -> Bool {
        guard let options else { return true }
        return options.count <= 32 && options.allSatisfy(\.valid) && Set(options.map { Data($0.name.utf8) }).count == options.count
    }
}
extension StructureIndexTerm {
    var valid: Bool {
        (column != nil) != (expression != nil) && (column.map(StructureTarget.identifier) ?? true) &&
            (expression.map { !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\0") } ?? true) &&
            (prefixLength.map { $0 > 0 && $0 <= 65_535 } ?? true) &&
            (collation?.valid ?? true) && (opclass?.valid ?? true) && StructureIndexOption.valid(options)
    }
}
extension StructureIndexDefinition {
    var valid: Bool {
        StructureTarget.identifier(method) && !terms.isEmpty && terms.count <= 32 && terms.allSatisfy(\.valid) &&
            (includes.map { $0.isEmpty || StructureTarget.columns($0) } ?? true) &&
            (predicate.map { !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\0") } ?? true) && StructureIndexOption.valid(options)
    }
}
extension StructureIndexDefinition { static func == (a: Self, b: Self) -> Bool { StructureTarget.intentBytes(a) == StructureTarget.intentBytes(b) } }
extension StructureIndexTerm { static func == (a: Self, b: Self) -> Bool { StructureTarget.intentBytes(a) == StructureTarget.intentBytes(b) } }
extension StructureIndexOption { static func == (a: Self, b: Self) -> Bool { StructureTarget.intentBytes(a) == StructureTarget.intentBytes(b) } }

extension StructureIndex {
    func editIntent(action: String, engine: DatabaseEngine, advancedAllowed: Bool) -> StructureIndexEdit? {
        guard ["drop", "replace"].contains(action), supported, owner == nil,
              definition == nil || advancedAllowed && engine != .sqlite else { return nil }
        return .init(action: action, name: name, columns: action == "drop" || definition != nil ? nil : columns,
                     unique: action == "replace" && engine == .postgresql && unique ? true : nil,
                     definition: action == "replace" ? definition : nil)
    }
}

extension StructureDraft {
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(columns, forKey: .columns)
        try c.encodeIfPresent(changes, forKey: .changes)
        try c.encodeIfPresent(indexes, forKey: .indexes)
        try c.encodeIfPresent(keys, forKey: .keys)
        try c.encodeIfPresent(allowDestructive, forKey: .allowDestructive)
        try c.encodeIfPresent(renameTable, forKey: .renameTable)
        try c.encodeIfPresent(authoringVersion, forKey: .authoringVersion)
        if dropTable { try c.encode(true, forKey: .dropTable) }
        try c.encodeIfPresent(backfills, forKey: .backfills)
        try c.encodeIfPresent(columnOrder, forKey: .columnOrder)
        try c.encodeIfPresent(reconstruct, forKey: .reconstruct)
    }
}

extension StructureColumnChange {
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(nullable, forKey: .nullable)
        try c.encodeIfPresent(self.`default`, forKey: .`default`)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(renameTo, forKey: .renameTo)
        try c.encodeIfPresent(generated, forKey: .generated)
        try c.encodeIfPresent(identity, forKey: .identity)
        if drop { try c.encode(true, forKey: .drop) }
        try c.encodeIfPresent(usingExpression, forKey: .usingExpression)
        try c.encodeIfPresent(unsigned, forKey: .unsigned)
        try c.encodeIfPresent(charset, forKey: .charset)
        try c.encodeIfPresent(collation, forKey: .collation)
    }
}

extension StructurePlan {
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(baselineId, forKey: .baselineId)
        try c.encode(digest, forKey: .digest)
        try c.encode(target, forKey: .target)
        try c.encode(sql, forKey: .sql)
        try c.encode(risks, forKey: .risks)
        try c.encodeIfPresent(destructive, forKey: .destructive)
        try c.encodeIfPresent(resultTarget, forKey: .resultTarget)
        if droppedTarget { try c.encode(true, forKey: .droppedTarget) }
        if !consequences.isEmpty { try c.encode(consequences, forKey: .consequences) }
        if !validationChecks.isEmpty { try c.encode(validationChecks, forKey: .validationChecks) }
    }
}

extension StructureOutcome {
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(executionId, forKey: .executionId)
        try c.encode(planId, forKey: .planId)
        try c.encode(state, forKey: .state)
        try c.encode(steps, forKey: .steps)
        try c.encodeIfPresent(observed, forKey: .observed)
        try c.encodeIfPresent(refreshError, forKey: .refreshError)
        if droppedTarget { try c.encode(true, forKey: .droppedTarget) }
    }
}

struct StructureConsequence: Codable, Equatable, Sendable {
    var kind: String
    var object: String
    var message: String
    var valid: Bool { [kind, object, message].allSatisfy { !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\0") } }
    private enum CodingKeys: String, CodingKey { case kind, object, message }
    init(kind: String, object: String, message: String) { self.kind = kind; self.object = object; self.message = message }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == ["kind", "object", "message"] else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        object = try c.decode(String.self, forKey: .object)
        message = try c.decode(String.self, forKey: .message)
    }
}
struct StructureValidationCheck: Codable, Equatable, Sendable {
    var id: String
    var summary: String
    var sql: String? = nil
    var risks: [String]
    var unavailableReason: String? = nil
    var valid: Bool {
        BackendMessage.validID(id) && !summary.isEmpty && summary.utf8.count <= 4096 && (sql == nil) != (unavailableReason == nil) &&
        (sql.map { !$0.isEmpty && $0.utf8.count <= 1_048_576 && !$0.contains("\0") } ?? true) &&
        (unavailableReason.map { !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\0") } ?? true) && risks.count <= 16 && risks.allSatisfy { !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\0") }
    }
    private enum CodingKeys: String, CodingKey { case id, summary, sql, risks, unavailableReason }
    init(id: String, summary: String, sql: String? = nil, risks: [String], unavailableReason: String? = nil) {
        self.id = id; self.summary = summary; self.sql = sql; self.risks = risks; self.unavailableReason = unavailableReason
    }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["id", "summary", "sql", "risks", "unavailableReason"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        summary = try c.decode(String.self, forKey: .summary)
        risks = try c.decode([String].self, forKey: .risks)
        if c.contains(.sql), try c.decodeNil(forKey: .sql) { throw BackendTransportError(.invalidMessage) }
        sql = try c.decodeIfPresent(String.self, forKey: .sql)
        if c.contains(.unavailableReason), try c.decodeNil(forKey: .unavailableReason) { throw BackendTransportError(.invalidMessage) }
        unavailableReason = try c.decodeIfPresent(String.self, forKey: .unavailableReason)
    }
}
struct StructureValidationCheckOutcome: Codable, Equatable, Sendable {
    var id: String
    var state: String
    var invalidRows: String? = nil
    var message: String? = nil
    var valid: Bool {
        guard BackendMessage.validID(id), ["passed", "failed", "unavailable", "cancelled", "notStarted"].contains(state), (message?.utf8.count ?? 0) <= 4096 else { return false }
        if let invalidRows {
            guard let n = UInt64(invalidRows), String(n) == invalidRows else { return false }
            return state == "passed" && n == 0 || state == "failed" && n > 0
        }
        return state != "passed" && (state != "failed" || message?.isEmpty == false)
    }
    private enum CodingKeys: String, CodingKey { case id, state, invalidRows, message }
    init(id: String, state: String, invalidRows: String? = nil, message: String? = nil) { self.id = id; self.state = state; self.invalidRows = invalidRows; self.message = message }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["id", "state", "invalidRows", "message"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        state = try c.decode(String.self, forKey: .state)
        if c.contains(.invalidRows), try c.decodeNil(forKey: .invalidRows) { throw BackendTransportError(.invalidMessage) }
        invalidRows = try c.decodeIfPresent(String.self, forKey: .invalidRows)
        if c.contains(.message), try c.decodeNil(forKey: .message) { throw BackendTransportError(.invalidMessage) }
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}
struct StructureValidationOutcome: Codable, Equatable, Sendable {
    var executionId: String
    var planId: String
    var digest: String
    var state: String
    var checks: [StructureValidationCheckOutcome]
    var valid: Bool {
        BackendMessage.validID(executionId) && BackendMessage.validID(planId) && StructureBaseline.digest(digest) && ["completed", "cancelled", "failed"].contains(state) && !checks.isEmpty && checks.count <= 64 && Set(checks.map(\.id)).count == checks.count && checks.allSatisfy(\.valid) && (state != "completed" || checks.allSatisfy { ["passed", "failed", "unavailable"].contains($0.state) && ($0.state != "failed" || $0.invalidRows != nil) })
    }
    private enum CodingKeys: String, CodingKey { case executionId, planId, digest, state, checks }
    init(executionId: String, planId: String, digest: String, state: String, checks: [StructureValidationCheckOutcome]) { self.executionId = executionId; self.planId = planId; self.digest = digest; self.state = state; self.checks = checks }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: StructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == ["executionId", "planId", "digest", "state", "checks"] else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        executionId = try c.decode(String.self, forKey: .executionId)
        planId = try c.decode(String.self, forKey: .planId)
        digest = try c.decode(String.self, forKey: .digest)
        state = try c.decode(String.self, forKey: .state)
        checks = try c.decode([StructureValidationCheckOutcome].self, forKey: .checks)
    }
}
extension StructureColumnChange {
    var requiresDestructiveAuthoring: Bool { drop || usingExpression != nil || unsigned != nil || charset != nil || collation != nil }
    var destructiveIntentValid: Bool {
        if drop { return nullable == nil && self.default == nil && type == nil && renameTo == nil && generated == nil && identity == nil && usingExpression == nil && unsigned == nil && charset == nil && collation == nil }
        if usingExpression != nil && (type == nil || usingExpression?.isEmpty != false || (usingExpression?.utf8.count ?? 0) > 4096 || usingExpression?.contains("\0") == true) { return false }
        if let charset, !StructureTarget.identifier(charset) { return false }
        if let collation, !StructureTarget.identifier(collation.name) || !collation.schema.isEmpty && !StructureTarget.identifier(collation.schema) { return false }
        if (usingExpression != nil || unsigned != nil || charset != nil || collation != nil) && (generated != nil || identity != nil || renameTo != nil) { return false }
        return true
    }
}
extension StructureDraft {
    var hasDestructiveIntent: Bool { dropTable || (changes ?? []).contains { $0.requiresDestructiveAuthoring || (authoringVersion ?? 0) >= 4 && $0.type != nil } }
    var requiresDestructiveAuthoring: Bool { authoringVersion == 4 || hasDestructiveIntent }
}
extension StructureBaseline {
    var requiresDestructiveAuthoring: Bool { columns.contains { $0.unsigned != nil || $0.charset != nil || $0.collation != nil } }
}
extension StructurePlan {
    var requiresDestructiveAuthoring: Bool { droppedTarget || !consequences.isEmpty || !validationChecks.isEmpty }
}
extension StructureOutcome {
    var requiresDestructiveAuthoring: Bool { droppedTarget || observed?.requiresDestructiveAuthoring == true }
}

extension StructureBackfill {
    var valid: Bool { StructureTarget.identifier(column) && !expression.isEmpty && expression.utf8.count <= 4096 && !expression.contains("\0") }
}
extension StructureDraft {
    var hasReconstructionIntent: Bool { !(backfills ?? []).isEmpty || !(columnOrder ?? []).isEmpty || reconstruct == true }
    var requiresReconstructionAuthoring: Bool { authoringVersion == 5 || backfills != nil || columnOrder != nil || reconstruct != nil }
    private var reconstructionIntentValid: Bool {
        guard !requiresReconstructionAuthoring || authoringVersion == 5 else { return false }
        guard hasReconstructionIntent else { return true }
        let fills = backfills ?? []; let order = columnOrder ?? []
        guard !dropTable, renameTable == nil, (changes ?? []).isEmpty, (keys ?? []).isEmpty, (indexes ?? []).isEmpty,
              fills.count <= 128, order.count <= 128, fills.allSatisfy(\.valid),
              order.allSatisfy(StructureTarget.identifier),
              Set(fills.map { Data($0.column.utf8) }).count == fills.count,
              Set(order.map { Data($0.utf8) }).count == order.count else { return false }
        guard fills.count == columns.count else { return false }
        return columns.allSatisfy { column in
            !column.nullable && column.default.kind == "none" && column.type.reference == nil && column.generated == nil && column.identity == nil &&
            fills.contains { StructureTarget.sameIdentifier($0.column, column.name) }
        }
    }
}

// Generic intent syntax admits MariaDB's native precision; the owning engine
// retains its narrower bound before a typed preview can be requested.
extension StructureDraft {
    func valid(for engine: DatabaseEngine?) -> Bool {
        valid && numericScalePermitted(for: engine)
    }
    func numericScalePermitted(for engine: DatabaseEngine?) -> Bool {
        let maximum = engine == .mariadb ? 38 : 30
        return columns.allSatisfy { ($0.type.scale ?? 0) <= maximum } &&
            (changes ?? []).allSatisfy { ($0.type?.scale ?? 0) <= maximum }
    }
}
