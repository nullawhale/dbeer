import Foundation

// Catalog observation only; portable drafts never carry these capabilities or proof.
final class StructureAdvancedKindSupport: Codable, Equatable, Sendable {
    let kinds: [String]
    let scope: String
    let familyCount: Int
    let nontransactional: Bool
    let operations: [StructureAdvancedKindOperation]
    let relations: [StructureAdvancedRelationFact]?
    static let operationKinds = ["renameTable", "renameColumn", "addColumn", "dropColumn", "default", "nullable", "type", "index", "key", "foreignKey", "generation", "reconstruction", "hierarchy"]
    init(kinds: [String], scope: String, familyCount: Int, nontransactional: Bool, operations: [StructureAdvancedKindOperation], relations: [StructureAdvancedRelationFact]? = nil) {
        self.kinds = kinds; self.scope = scope; self.familyCount = familyCount
        self.nontransactional = nontransactional; self.operations = operations; self.relations = relations
    }
    private enum CodingKeys: String, CodingKey { case kinds, scope, familyCount, nontransactional, operations, relations }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: AdvancedStructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["kinds", "scope", "familyCount", "nontransactional", "operations", "relations"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kinds = try c.decode([String].self, forKey: .kinds)
        scope = try c.decode(String.self, forKey: .scope)
        familyCount = try c.decode(Int.self, forKey: .familyCount)
        nontransactional = try c.decode(Bool.self, forKey: .nontransactional)
        operations = try c.decode([StructureAdvancedKindOperation].self, forKey: .operations)
        if c.contains(.relations), try c.decodeNil(forKey: .relations) { throw BackendTransportError(.invalidMessage) }
        relations = try c.decodeIfPresent([StructureAdvancedRelationFact].self, forKey: .relations)
    }
    static func == (lhs: StructureAdvancedKindSupport, rhs: StructureAdvancedKindSupport) -> Bool {
        lhs.kinds == rhs.kinds && lhs.scope == rhs.scope && lhs.familyCount == rhs.familyCount && lhs.nontransactional == rhs.nontransactional && lhs.operations == rhs.operations && lhs.relations == rhs.relations
    }
    func valid(engine: String) -> Bool {
        let allowed: Set<String> = ["inheritanceParent", "inheritanceChild", "partitionParent", "partitionMember", "rowSecurity", "typed", "unlogged", "mySQLPartitions", "myISAM"]
        guard engine != "postgresql" || !nontransactional, engine != "mysql" || kinds.contains("myISAM") == nontransactional else { return false }
        return validRelations(engine: engine) && ["postgresql", "mysql"].contains(engine) && ["only", "table", "operation"].contains(scope) && (1...64).contains(familyCount) && (1...6).contains(kinds.count) && Set(kinds).count == kinds.count && kinds.allSatisfy { allowed.contains($0) && $0.hasPrefix("my") == (engine == "mysql") } && operations.map(\.kind) == Self.operationKinds && operations.allSatisfy { !$0.reason.isEmpty && $0.reason.utf8.count <= 4096 && !$0.reason.contains("\0") }
    }
    private func validRelations(engine: String) -> Bool {
        guard let relations else { return true }
        guard relations.count == familyCount && relations.allSatisfy({ $0.valid(engine: engine) }) else { return false }
        for i in relations.indices {
            for j in relations.indices where j < i {
                if StructureTarget.sameIdentifier(relations[i].target.schema, relations[j].target.schema) && StructureTarget.sameIdentifier(relations[i].target.table, relations[j].target.table) { return false }
            }
        }
        return true
    }
    func permits(_ kind: String) -> Bool { operations.first { $0.kind == kind }?.available == true }
    func permits(_ draft: StructureDraft) -> Bool {
        if draft.dropTable { return false }
        if draft.renameTable != nil && !permits("renameTable") || !draft.columns.isEmpty && !permits("addColumn") || !(draft.indexes ?? []).isEmpty && !permits("index") || !(draft.keys ?? []).isEmpty && !permits("key") || draft.requiresReconstructionAuthoring && !permits("reconstruction") { return false }
        if draft.columns.contains(where: { column in
            let reviewedBackfill = (draft.backfills ?? []).contains { StructureTarget.sameIdentifier($0.column, column.name) }
            return !column.nullable && !reviewedBackfill || column.default.kind != "none" || column.type.reference != nil || column.generated != nil || column.identity != nil
        }) { return false }
        if (draft.keys ?? []).contains(where: { $0.kind == "foreign" }) && !permits("foreignKey") { return false }
        for c in draft.changes ?? [] {
            if c.renameTo != nil && !permits("renameColumn") || c.drop && !permits("dropColumn") || c.default != nil && !permits("default") || c.nullable != nil && !permits("nullable") || (c.type != nil || c.unsigned != nil || c.charset != nil || c.collation != nil) && !permits("type") || (c.generated != nil || c.identity != nil) && !permits("generation") { return false }
            if c.default?.kind == "expression" { return false }
        }
        return true
    }
}
struct StructureAdvancedKindOperation: Codable, Equatable, Sendable {
    let kind: String
    let available: Bool
    let reason: String
    private enum CodingKeys: String, CodingKey { case kind, available, reason }
    init(kind: String, available: Bool, reason: String) { self.kind = kind; self.available = available; self.reason = reason }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: AdvancedStructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == ["kind", "available", "reason"] else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        available = try c.decode(Bool.self, forKey: .available)
        reason = try c.decode(String.self, forKey: .reason)
    }
}

struct StructureAdvancedRelationFact: Codable, Equatable, Sendable {
    let target: StructureTarget
    let kind: String
    let persistence: String
    let partitionMember: Bool
    let storageEngine: String?
    let parents: [StructureTarget]
    let rowSecurity: Bool
    let forceRowSecurity: Bool
    let typeBinding: StructureTypeReference?
    let policies: [StructureAdvancedPolicyFact]
    private enum CodingKeys: String, CodingKey { case target, kind, persistence, partitionMember, storageEngine, parents, rowSecurity, forceRowSecurity, typeBinding, policies }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: AdvancedStructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["target", "kind", "persistence", "partitionMember", "storageEngine", "parents", "rowSecurity", "forceRowSecurity", "typeBinding", "policies"]) else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(StructureTarget.self, forKey: .target)
        kind = try c.decode(String.self, forKey: .kind)
        persistence = try c.decode(String.self, forKey: .persistence)
        partitionMember = try c.decode(Bool.self, forKey: .partitionMember)
        parents = try c.decode([StructureTarget].self, forKey: .parents)
        rowSecurity = try c.decode(Bool.self, forKey: .rowSecurity)
        forceRowSecurity = try c.decode(Bool.self, forKey: .forceRowSecurity)
        policies = try c.decode([StructureAdvancedPolicyFact].self, forKey: .policies)
        for key in [CodingKeys.storageEngine, .typeBinding] {
            if c.contains(key), try c.decodeNil(forKey: key) { throw BackendTransportError(.invalidMessage) }
        }
        storageEngine = try c.decodeIfPresent(String.self, forKey: .storageEngine)
        typeBinding = try c.decodeIfPresent(StructureTypeReference.self, forKey: .typeBinding)
    }
    func valid(engine: String) -> Bool {
        guard target.valid, !target.create, target.reconcile != true, ["table", "partitionedTable"].contains(kind), ["permanent", "unlogged"].contains(persistence), parents.count <= 64, parents.allSatisfy({ $0.valid && !$0.create && $0.reconcile != true }), typeBinding?.valid ?? true, policies.count <= 128, policies.allSatisfy(\.valid) else { return false }
        if engine == "mysql" { return ["InnoDB", "MyISAM"].contains(storageEngine ?? "") && !rowSecurity && !forceRowSecurity && typeBinding == nil && policies.isEmpty && persistence == "permanent" }
        return storageEngine == nil
    }
}
struct StructureAdvancedPolicyFact: Codable, Equatable, Sendable {
    let name: String
    let command: String
    let permissive: Bool
    let roles: [String]
    private enum CodingKeys: String, CodingKey { case name, command, permissive, roles }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: AdvancedStructureCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == ["name", "command", "permissive", "roles"] else { throw BackendTransportError(.invalidMessage) }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
        permissive = try c.decode(Bool.self, forKey: .permissive)
        roles = try c.decode([String].self, forKey: .roles)
    }
    var valid: Bool { StructureTarget.identifier(name) && ["all", "select", "insert", "update", "delete"].contains(command) && roles.count <= 2048 && roles.allSatisfy(StructureTarget.identifier) }
}

private struct AdvancedStructureCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
