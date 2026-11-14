import Foundation

let structurePhysicalCapability = "tableStructurePhysicalV1"

private struct PhysicalCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func physicalKeys<K: CodingKey>(_ decoder: any Decoder, _ type: K.Type, allowed: Set<String>) throws -> KeyedDecodingContainer<K> {
    let all = try decoder.container(keyedBy: PhysicalCodingKey.self)
    guard Set(all.allKeys.map(\.stringValue)).isSubset(of: allowed) else { throw BackendTransportError(.invalidMessage) }
    for key in all.allKeys { if try all.decodeNil(forKey: key) { throw BackendTransportError(.invalidMessage) } }
    return try decoder.container(keyedBy: type)
}
private func physicalText(_ value: String, limit: Int = 4096) -> Bool { value.utf8.count <= limit && !value.contains("\0") }
private func physicalNames(_ values: [String], limit: Int = 128) -> Bool { !values.isEmpty && values.count <= limit && values.allSatisfy(StructureTarget.identifier) && Set(values.map { Data($0.utf8) }).count == values.count }

struct StructurePhysicalValue: Codable, Equatable, Sendable {
    var `kind`: String
    var `value`: String? = nil
}
extension StructurePhysicalValue {
    private enum CodingKeys: String, CodingKey { case `kind`, `value` }
    init(from decoder: any Decoder) throws {
        let c = try physicalKeys(decoder, CodingKeys.self, allowed: ["kind", "value"])
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        self.`value` = try c.decodeIfPresent(String.self, forKey: .`value`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructurePhysicalBound: Codable, Equatable, Sendable {
    var `kind`: String
    var `from`: [StructurePhysicalValue]? = nil
    var `to`: [StructurePhysicalValue]? = nil
    var `values`: [[StructurePhysicalValue]]? = nil
    var `modulus`: Int? = nil
    var `remainder`: Int? = nil
}
extension StructurePhysicalBound {
    private enum CodingKeys: String, CodingKey { case `kind`, `from`, `to`, `values`, `modulus`, `remainder` }
    init(from decoder: any Decoder) throws {
        let c = try physicalKeys(decoder, CodingKeys.self, allowed: ["kind", "from", "to", "values", "modulus", "remainder"])
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        self.`from` = try c.decodeIfPresent([StructurePhysicalValue].self, forKey: .`from`)
        self.`to` = try c.decodeIfPresent([StructurePhysicalValue].self, forKey: .`to`)
        self.`values` = try c.decodeIfPresent([[StructurePhysicalValue]].self, forKey: .`values`)
        self.`modulus` = try c.decodeIfPresent(Int.self, forKey: .`modulus`)
        self.`remainder` = try c.decodeIfPresent(Int.self, forKey: .`remainder`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructurePhysicalPartitionDefinition: Codable, Equatable, Sendable {
    var `name`: String
    var `bound`: StructurePhysicalBound
}
extension StructurePhysicalPartitionDefinition {
    private enum CodingKeys: String, CodingKey { case `name`, `bound` }
    init(from decoder: any Decoder) throws {
        let c = try physicalKeys(decoder, CodingKeys.self, allowed: ["name", "bound"])
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`bound` = try c.decode(StructurePhysicalBound.self, forKey: .`bound`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructurePhysicalIntent: Codable, Equatable, Sendable {
    var `kind`: String
    var `child`: StructureTarget? = nil
    var `bound`: StructurePhysicalBound? = nil
    var `concurrent`: Bool? = nil
    var `index`: StructureIndexEdit? = nil
    var `engine`: String? = nil
    var `algorithm`: String? = nil
    var `lock`: String? = nil
    var `partitions`: [String]? = nil
    var `definitions`: [StructurePhysicalPartitionDefinition]? = nil
    var `count`: Int? = nil
    var `columnOrder`: [String]? = nil
    var `method`: String? = nil
    var `columns`: [String]? = nil
}
extension StructurePhysicalIntent {
    private enum CodingKeys: String, CodingKey { case `kind`, `child`, `bound`, `concurrent`, `index`, `engine`, `algorithm`, `lock`, `partitions`, `definitions`, `count`, `columnOrder`, `method`, `columns` }
    init(from decoder: any Decoder) throws {
        let c = try physicalKeys(decoder, CodingKeys.self, allowed: ["kind", "child", "bound", "concurrent", "index", "engine", "algorithm", "lock", "partitions", "definitions", "count", "columnOrder", "method", "columns"])
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        self.`child` = try c.decodeIfPresent(StructureTarget.self, forKey: .`child`)
        self.`bound` = try c.decodeIfPresent(StructurePhysicalBound.self, forKey: .`bound`)
        self.`concurrent` = try c.decodeIfPresent(Bool.self, forKey: .`concurrent`)
        self.`index` = try c.decodeIfPresent(StructureIndexEdit.self, forKey: .`index`)
        self.`engine` = try c.decodeIfPresent(String.self, forKey: .`engine`)
        self.`algorithm` = try c.decodeIfPresent(String.self, forKey: .`algorithm`)
        self.`lock` = try c.decodeIfPresent(String.self, forKey: .`lock`)
        self.`partitions` = try c.decodeIfPresent([String].self, forKey: .`partitions`)
        self.`definitions` = try c.decodeIfPresent([StructurePhysicalPartitionDefinition].self, forKey: .`definitions`)
        self.`count` = try c.decodeIfPresent(Int.self, forKey: .`count`)
        self.`columnOrder` = try c.decodeIfPresent([String].self, forKey: .`columnOrder`)
        self.`method` = try c.decodeIfPresent(String.self, forKey: .`method`)
        self.`columns` = try c.decodeIfPresent([String].self, forKey: .`columns`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructurePhysicalDraft: Codable, Equatable, Sendable {
    var `version`: Int
    var `target`: StructureTarget
    var `intent`: StructurePhysicalIntent
}
extension StructurePhysicalDraft {
    private enum CodingKeys: String, CodingKey { case `version`, `target`, `intent` }
    init(from decoder: any Decoder) throws {
        let c = try physicalKeys(decoder, CodingKeys.self, allowed: ["version", "target", "intent"])
        self.`version` = try c.decode(Int.self, forKey: .`version`)
        self.`target` = try c.decode(StructureTarget.self, forKey: .`target`)
        self.`intent` = try c.decode(StructurePhysicalIntent.self, forKey: .`intent`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructurePhysicalRequest: Codable, Equatable, Sendable {
    var target: StructureTarget? = nil
    var `draft`: StructurePhysicalDraft? = nil
    var `apply`: StructureApply? = nil
}
extension StructurePhysicalRequest {
    private enum CodingKeys: String, CodingKey { case `target`, `draft`, `apply` }
    init(from decoder: any Decoder) throws {
        let c = try physicalKeys(decoder, CodingKeys.self, allowed: ["target", "draft", "apply"])
        self.target = try c.decodeIfPresent(StructureTarget.self, forKey: .target)
        self.`draft` = try c.decodeIfPresent(StructurePhysicalDraft.self, forKey: .`draft`)
        self.`apply` = try c.decodeIfPresent(StructureApply.self, forKey: .`apply`)
    }
}

struct StructurePhysicalPartition: Codable, Equatable, Sendable {
    var `name`: String
    var `target`: StructureTarget? = nil
    var `method`: String
    var `description`: String
    var `detachPending`: Bool? = nil
}
extension StructurePhysicalPartition {
    private enum CodingKeys: String, CodingKey { case `name`, `target`, `method`, `description`, `detachPending` }
    init(from decoder: any Decoder) throws {
        let c = try physicalKeys(decoder, CodingKeys.self, allowed: ["name", "target", "method", "description", "detachPending"])
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`target` = try c.decodeIfPresent(StructureTarget.self, forKey: .`target`)
        self.`method` = try c.decode(String.self, forKey: .`method`)
        self.`description` = try c.decode(String.self, forKey: .`description`)
        self.`detachPending` = try c.decodeIfPresent(Bool.self, forKey: .`detachPending`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructurePhysicalIndexState: Codable, Equatable, Sendable {
    var `name`: String
    var `valid`: Bool
    var `ready`: Bool
    var `live`: Bool
}
extension StructurePhysicalIndexState {
    private enum CodingKeys: String, CodingKey { case `name`, `valid`, `ready`, `live` }
    init(from decoder: any Decoder) throws {
        let c = try physicalKeys(decoder, CodingKeys.self, allowed: ["name", "valid", "ready", "live"])
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`valid` = try c.decode(Bool.self, forKey: .`valid`)
        self.`ready` = try c.decode(Bool.self, forKey: .`ready`)
        self.`live` = try c.decode(Bool.self, forKey: .`live`)
    }
}

struct StructurePhysicalObject: Codable, Equatable, Sendable {
    var columns: [StructureObservedColumn]
    var partitionMethod: String? = nil
    var partitionColumns: [String]? = nil
    var partitionKeyCount: Int? = nil
    var `target`: StructureTarget
    var `identity`: String
    var `kind`: String
    var `storageEngine`: String? = nil
    var `fingerprint`: String
    var `definition`: String? = nil
    var `partitions`: [StructurePhysicalPartition]
    var `indexes`: [StructurePhysicalIndexState]
    var `limitations`: [String]
}
extension StructurePhysicalObject {
    private enum CodingKeys: String, CodingKey { case columns, partitionMethod, partitionColumns, partitionKeyCount, `target`, `identity`, `kind`, `storageEngine`, `fingerprint`, `definition`, `partitions`, `indexes`, `limitations` }
    init(from decoder: any Decoder) throws {
        let c = try physicalKeys(decoder, CodingKeys.self, allowed: ["columns", "partitionMethod", "partitionColumns", "partitionKeyCount", "target", "identity", "kind", "storageEngine", "fingerprint", "definition", "partitions", "indexes", "limitations"])
        self.`target` = try c.decode(StructureTarget.self, forKey: .`target`)
        self.columns = try c.decode([StructureObservedColumn].self, forKey: .columns)
        self.partitionMethod = try c.decodeIfPresent(String.self, forKey: .partitionMethod)
        self.partitionColumns = try c.decodeIfPresent([String].self, forKey: .partitionColumns)
        self.partitionKeyCount = try c.decodeIfPresent(Int.self, forKey: .partitionKeyCount)
        self.`identity` = try c.decode(String.self, forKey: .`identity`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        self.`storageEngine` = try c.decodeIfPresent(String.self, forKey: .`storageEngine`)
        self.`fingerprint` = try c.decode(String.self, forKey: .`fingerprint`)
        self.`definition` = try c.decodeIfPresent(String.self, forKey: .`definition`)
        self.`partitions` = try c.decode([StructurePhysicalPartition].self, forKey: .`partitions`)
        self.`indexes` = try c.decode([StructurePhysicalIndexState].self, forKey: .`indexes`)
        self.`limitations` = try c.decode([String].self, forKey: .`limitations`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructurePhysicalPlan: Codable, Equatable, Sendable {
    var `id`: String
    var `digest`: String
    var `draft`: StructurePhysicalDraft
    var `engine`: String
    var `serverVersion`: Int
    var `sql`: [String]
    var `objects`: [StructurePhysicalObject]
    var `prerequisites`: [String]
    var `risks`: [String]
    var `consequences`: [StructureConsequence]
    var `transactionMode`: String
    var `locking`: String
    var `destructive`: Bool
}
extension StructurePhysicalPlan {
    private enum CodingKeys: String, CodingKey { case `id`, `digest`, `draft`, `engine`, `serverVersion`, `sql`, `objects`, `prerequisites`, `risks`, `consequences`, `transactionMode`, `locking`, `destructive` }
    init(from decoder: any Decoder) throws {
        let c = try physicalKeys(decoder, CodingKeys.self, allowed: ["id", "digest", "draft", "engine", "serverVersion", "sql", "objects", "prerequisites", "risks", "consequences", "transactionMode", "locking", "destructive"])
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`digest` = try c.decode(String.self, forKey: .`digest`)
        self.`draft` = try c.decode(StructurePhysicalDraft.self, forKey: .`draft`)
        self.`engine` = try c.decode(String.self, forKey: .`engine`)
        self.`serverVersion` = try c.decode(Int.self, forKey: .`serverVersion`)
        self.`sql` = try c.decode([String].self, forKey: .`sql`)
        self.`objects` = try c.decode([StructurePhysicalObject].self, forKey: .`objects`)
        self.`prerequisites` = try c.decode([String].self, forKey: .`prerequisites`)
        self.`risks` = try c.decode([String].self, forKey: .`risks`)
        self.`consequences` = try c.decode([StructureConsequence].self, forKey: .`consequences`)
        self.`transactionMode` = try c.decode(String.self, forKey: .`transactionMode`)
        self.`locking` = try c.decode(String.self, forKey: .`locking`)
        self.`destructive` = try c.decode(Bool.self, forKey: .`destructive`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructurePhysicalOutcome: Codable, Equatable, Sendable {
    var consequences: [StructureConsequence]? = nil
    var `executionId`: String
    var `planId`: String
    var `state`: String
    var `phase`: String
    var `steps`: [StructureStepOutcome]
    var `observed`: [StructurePhysicalObject]? = nil
    var `refreshError`: String? = nil
    var `reconciled`: Bool
}
extension StructurePhysicalOutcome {
    private enum CodingKeys: String, CodingKey { case consequences, `executionId`, `planId`, `state`, `phase`, `steps`, `observed`, `refreshError`, `reconciled` }
    init(from decoder: any Decoder) throws {
        let c = try physicalKeys(decoder, CodingKeys.self, allowed: ["consequences", "executionId", "planId", "state", "phase", "steps", "observed", "refreshError", "reconciled"])
        self.consequences = try c.decodeIfPresent([StructureConsequence].self, forKey: .consequences)
        self.`executionId` = try c.decode(String.self, forKey: .`executionId`)
        self.`planId` = try c.decode(String.self, forKey: .`planId`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        self.`phase` = try c.decode(String.self, forKey: .`phase`)
        self.`steps` = try c.decode([StructureStepOutcome].self, forKey: .`steps`)
        self.`observed` = try c.decodeIfPresent([StructurePhysicalObject].self, forKey: .`observed`)
        self.`refreshError` = try c.decodeIfPresent(String.self, forKey: .`refreshError`)
        self.`reconciled` = try c.decode(Bool.self, forKey: .`reconciled`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

final class StructurePhysicalReply: Codable, Equatable, Sendable {
    let inspection: StructurePhysicalInspection?
    let draft: StructurePhysicalDraft?
    let plan: StructurePhysicalPlan?
    let outcome: StructurePhysicalOutcome?
    let elapsedMilliseconds: Int64?
    init(inspection: StructurePhysicalInspection? = nil, draft: StructurePhysicalDraft? = nil, plan: StructurePhysicalPlan? = nil, outcome: StructurePhysicalOutcome? = nil, elapsedMilliseconds: Int64? = nil) { self.inspection = inspection; self.draft = draft; self.plan = plan; self.outcome = outcome; self.elapsedMilliseconds = elapsedMilliseconds }
    static func == (a: StructurePhysicalReply, b: StructurePhysicalReply) -> Bool { a.inspection == b.inspection && a.draft == b.draft && a.plan == b.plan && a.outcome == b.outcome && a.elapsedMilliseconds == b.elapsedMilliseconds }
    private enum CodingKeys: String, CodingKey { case inspection, `draft`, `plan`, `outcome`, `elapsedMilliseconds` }
    init(from decoder: any Decoder) throws {
        let c = try physicalKeys(decoder, CodingKeys.self, allowed: ["inspection", "draft", "plan", "outcome", "elapsedMilliseconds"])
        self.`draft` = try c.decodeIfPresent(StructurePhysicalDraft.self, forKey: .`draft`)
        self.`plan` = try c.decodeIfPresent(StructurePhysicalPlan.self, forKey: .`plan`)
        self.`outcome` = try c.decodeIfPresent(StructurePhysicalOutcome.self, forKey: .`outcome`)
        self.inspection = try c.decodeIfPresent(StructurePhysicalInspection.self, forKey: .inspection)
        self.`elapsedMilliseconds` = try c.decodeIfPresent(Int64.self, forKey: .`elapsedMilliseconds`)
    }
}

extension StructurePhysicalValue {
    var valid: Bool {
        switch kind {
        case "null", "min", "max": return value == nil
        case "text": return value.map { physicalText($0) } == true
        case "integer":
            guard let value, !value.isEmpty, value.utf8.count <= 80 else { return false }
            let digits = value.hasPrefix("-") ? value.dropFirst() : value[...]
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
            return digits == "0" ? value == "0" : digits.first != "0"
        default: return false
        }
    }
}
extension StructurePhysicalBound {
    var valid: Bool {
        func tuple(_ v: [StructurePhysicalValue]?) -> Bool { v.map { !$0.isEmpty && $0.count <= 16 && $0.allSatisfy(\.valid) } == true }
        switch kind {
        case "default": return from == nil && to == nil && values == nil && modulus == nil && remainder == nil
        case "range": return tuple(to) && (from == nil || tuple(from) && from?.count == to?.count) && values == nil && modulus == nil && remainder == nil
        case "list": return from == nil && to == nil && modulus == nil && remainder == nil && values.map { !$0.isEmpty && $0.count <= 128 && $0.allSatisfy { tuple($0) } } == true
        case "hash": return from == nil && to == nil && values == nil && (1...8192).contains(modulus ?? 0) && remainder.map { $0 >= 0 && $0 < (modulus ?? 0) } == true
        default: return false
        }
    }
}
extension StructurePhysicalPartitionDefinition { var valid: Bool { StructureTarget.identifier(name) && bound.valid } }
extension StructurePhysicalIntent {
    var valid: Bool {
        guard child.map({ $0.valid && !$0.create && $0.reconcile != true }) ?? true, bound?.valid ?? true,
              partitions.map({ physicalNames($0) }) ?? true, definitions.map({ !$0.isEmpty && $0.count <= 128 && $0.allSatisfy(\.valid) && Set($0.map { Data($0.name.utf8) }).count == $0.count }) ?? true else { return false }
        let allowed: Set<String>
        let required: Set<String>
        switch kind {
        case "concurrentIndex": allowed = ["index"]; required = allowed
        case "onlineIndex": allowed = ["index", "algorithm", "lock"]; required = allowed
        case "storageEngine": allowed = ["engine", "algorithm", "lock"]; required = allowed
        case "reorderColumns": allowed = ["columnOrder", "algorithm", "lock"]; required = allowed
        case "createPartition", "attachPartition": allowed = ["child", "bound"]; required = allowed
        case "detachPartition": allowed = ["child", "concurrent"]; required = ["child"]
        case "finalizePartition": allowed = ["child"]; required = allowed
        case "dropPartition", "truncatePartition":
            allowed = child == nil ? ["partitions", "algorithm", "lock"] : ["child"]; required = allowed
        case "addPartition": allowed = ["definitions", "algorithm", "lock"]; required = allowed
        case "reorganizePartition": allowed = ["partitions", "definitions", "algorithm", "lock"]; required = allowed
        case "addHashPartitions", "coalescePartitions": allowed = ["count", "algorithm", "lock"]; required = allowed
        case "exchangePartition": allowed = ["child", "partitions", "algorithm", "lock"]; required = allowed
        case "removePartitioning": allowed = ["algorithm", "lock"]; required = allowed
        case "partitionTable":
            allowed = ["method", "columns", "definitions", "count", "algorithm", "lock"]
            required = ["method", "columns", "algorithm", "lock"]
        default: return false
        }
        var present = Set<String>()
        if child != nil { present.insert("child") }; if bound != nil { present.insert("bound") }; if concurrent != nil { present.insert("concurrent") }
        if index != nil { present.insert("index") }; if engine != nil { present.insert("engine") }; if algorithm != nil { present.insert("algorithm") }; if lock != nil { present.insert("lock") }
        if partitions != nil { present.insert("partitions") }; if definitions != nil { present.insert("definitions") }; if count != nil { present.insert("count") }; if columnOrder != nil { present.insert("columnOrder") }; if method != nil { present.insert("method") }; if columns != nil { present.insert("columns") }
        guard present.isSubset(of: allowed), required.isSubset(of: present) else { return false }
        if let index, !index.valid || !["add", "drop"].contains(index.action) { return false }
        if let algorithm, !["INPLACE", "COPY", "INSTANT"].contains(algorithm) { return false }
        if let lock, !["NONE", "SHARED", "EXCLUSIVE"].contains(lock) { return false }
        if let engine, !["InnoDB", "MyISAM"].contains(engine) { return false }
        if let count, !(1...8192).contains(count) { return false }
        if let columnOrder, !physicalNames(columnOrder, limit: 128) { return false }
        if kind == "exchangePartition", partitions?.count != 1 { return false }
        if kind == "partitionTable" {
            guard let columns, physicalNames(columns, limit: 32) else { return false }
            if ["hash", "key"].contains(method ?? "") { return count != nil && definitions == nil }
            return ["range", "list", "rangeColumns", "listColumns"].contains(method ?? "") && definitions != nil && count == nil
        }
        return true
    }
}
extension StructurePhysicalDraft { var valid: Bool { version == 1 && target.valid && !target.create && target.reconcile != true && intent.valid } }
extension StructurePhysicalRequest {
    func valid(for type: String) -> Bool {
        if type == "structure.physical.inspect" { return target.map { $0.valid && !$0.create && $0.reconcile != true } == true && draft == nil && apply == nil }; guard target == nil else { return false }
        switch type {
        case "structure.physical.preview": return draft?.valid == true && apply == nil
        case "structure.physical.apply": return draft == nil && apply?.valid == true
        case "structure.physical.status", "structure.physical.reconcile", "structure.physical.close": return draft == nil && apply == nil
        default: return false
        }
    }
}
extension StructurePhysicalPartition { var valid: Bool { StructureTarget.identifier(name) && (target?.valid ?? true) && physicalText(method, limit: 64) && physicalText(description, limit: 65_536) } }
extension StructurePhysicalObject {
    var valid: Bool {
        columns.count <= 128 && columns.allSatisfy { StructureTarget.identifier($0.name) && physicalText($0.nativeType) } && target.valid && physicalText(identity, limit: 128) && ["r", "p", "table", "absent"].contains(kind) && StructureBaseline.digest(fingerprint) && (definition.map { physicalText($0, limit: 1_048_576) } ?? true) && partitions.count <= 128 && partitions.allSatisfy(\.valid) && indexes.count <= 128 && indexes.allSatisfy { StructureTarget.identifier($0.name) } && limitations.count <= 64 && limitations.allSatisfy { physicalText($0) }
    }
}
extension StructurePhysicalPlan {
    var valid: Bool {
        BackendMessage.validID(id) && StructureBaseline.digest(digest) && draft.valid && ["postgresql", "mysql"].contains(engine) && serverVersion > 0 && !sql.isEmpty && sql.count <= 64 && sql.reduce(0, { $0 + $1.utf8.count }) <= 1_048_576 && sql.allSatisfy { !$0.isEmpty && physicalText($0, limit: 1_048_576) } && !objects.isEmpty && objects.count <= 130 && objects.allSatisfy(\.valid) && prerequisites.count <= 64 && prerequisites.allSatisfy { physicalText($0) } && risks.count <= 64 && risks.allSatisfy { physicalText($0) } && consequences.count <= 512 && consequences.allSatisfy(\.valid) && ["transaction", "outsideTransaction", "implicitCommit"].contains(transactionMode) && physicalText(locking) && destructive
    }
}
extension StructurePhysicalOutcome {
    var valid: Bool {
        guard (consequences.map { $0.count <= 512 && $0.allSatisfy(\.valid) } ?? true), BackendMessage.validID(executionId), BackendMessage.validID(planId), ["applied", "failed", "partiallyApplied", "cancelled", "outcomeUnknown", "applying"].contains(state), ["metadataRecheck", "running", "acknowledged", "finished"].contains(phase), !steps.isEmpty, steps.count <= 64,
              steps.allSatisfy({ ["notStarted", "applied", "failed", "rolledBack", "unknown"].contains($0.state) && ($0.message.map { physicalText($0) } ?? true) }), observed.map({ $0.count <= 130 && $0.allSatisfy(\.valid) }) ?? true, refreshError.map({ physicalText($0) }) ?? true else { return false }
        let applied = steps.filter { $0.state == "applied" }.count
        let unknown = steps.contains { $0.state == "unknown" }
        switch state {
        case "applied": return applied == steps.count
        case "outcomeUnknown": return unknown
        case "partiallyApplied": return applied > 0 && applied < steps.count && !unknown
        case "applying": return !unknown && steps.allSatisfy { ["notStarted", "applied"].contains($0.state) }
        default: return applied == 0 && !unknown
        }
    }
}
extension StructurePhysicalReply {
    func valid(for type: String) -> Bool {
        if type == "structure.physical.inspect.result" { return inspection?.valid == true && draft == nil && plan == nil && outcome == nil && elapsedMilliseconds == nil }; guard inspection == nil else { return false }
        guard draft?.valid ?? true, plan?.valid ?? true, outcome?.valid ?? true, (elapsedMilliseconds ?? 0) >= 0 else { return false }
        if let plan { guard draft == plan.draft, outcome == nil else { return false } }
        switch type {
        case "structure.physical.preview.result": return draft != nil && plan != nil && outcome == nil
        case "structure.physical.apply.result", "structure.physical.reconcile.result": return draft != nil && plan == nil && outcome != nil
        case "structure.physical.status.result": return true
        case "structure.physical.close.result": return draft == nil && plan == nil && outcome == nil && elapsedMilliseconds == nil
        default: return false
        }
    }
}
extension StructurePhysicalDraft { static func == (a: Self, b: Self) -> Bool { StructureTarget.intentBytes(a) == StructureTarget.intentBytes(b) } }
extension StructurePhysicalIntent { static func == (a: Self, b: Self) -> Bool { StructureTarget.intentBytes(a) == StructureTarget.intentBytes(b) } }
extension StructurePhysicalValue { static func == (a: Self, b: Self) -> Bool { StructureTarget.intentBytes(a) == StructureTarget.intentBytes(b) } }

struct StructurePhysicalInspection: Codable, Equatable, Sendable {
    var version: Int
    var engine: String
    var serverVersion: Int
    var objects: [StructurePhysicalObject]
    var operations: [String]
    var valid: Bool { version == 1 && ["postgresql", "mysql"].contains(engine) && serverVersion > 0 && !objects.isEmpty && objects.count <= 130 && objects.allSatisfy(\.valid) && operations.count <= 32 && Set(operations).count == operations.count && operations.allSatisfy { StructurePhysicalIntent.kinds.contains($0) } }
    private enum CodingKeys: String, CodingKey { case version, engine, serverVersion, objects, operations }
    init(from decoder: any Decoder) throws {
        let c = try physicalKeys(decoder, CodingKeys.self, allowed: ["version", "engine", "serverVersion", "objects", "operations"])
        version = try c.decode(Int.self, forKey: .version); engine = try c.decode(String.self, forKey: .engine); serverVersion = try c.decode(Int.self, forKey: .serverVersion)
        objects = try c.decode([StructurePhysicalObject].self, forKey: .objects); operations = try c.decode([String].self, forKey: .operations)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}
extension StructurePhysicalIntent { static let kinds = ["concurrentIndex", "onlineIndex", "storageEngine", "reorderColumns", "createPartition", "attachPartition", "detachPartition", "finalizePartition", "dropPartition", "truncatePartition", "addPartition", "reorganizePartition", "addHashPartitions", "coalescePartitions", "exchangePartition", "partitionTable", "removePartitioning"] }
