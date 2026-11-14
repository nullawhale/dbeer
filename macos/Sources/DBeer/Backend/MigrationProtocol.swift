import Foundation

// Migration intent reuses typed table drafts; captured plans and authority are never portable.
let structureMigrationsCapability = "tableStructureMigrationsV1"

private struct MigrationCodingKey: CodingKey { var stringValue: String; var intValue: Int? { nil }; init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil } }

private func migrationKeys<K: CodingKey>(_ decoder: any Decoder, _ type: K.Type, allowed: Set<String>) throws -> KeyedDecodingContainer<K> {
    let all = try decoder.container(keyedBy: MigrationCodingKey.self)
    guard Set(all.allKeys.map(\.stringValue)).isSubset(of: allowed) else { throw BackendTransportError(.invalidMessage) }
    for key in all.allKeys { if try all.decodeNil(forKey: key) { throw BackendTransportError(.invalidMessage) } }
    return try decoder.container(keyedBy: type)
}
private func migrationID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
}
private func migrationText(_ value: String, limit: Int = 4096) -> Bool { !value.isEmpty && value.utf8.count <= limit && !value.contains("\0") }
private func migrationTargetKey(_ target: StructureTarget) -> Data { Data(target.schema.utf8) + Data([0]) + Data(target.table.utf8) }

struct StructureMigrationObject: Codable, Equatable, Sendable {
    var `id`: String
    var `target`: StructureTarget
    var `draft`: StructureDraft
    var `after`: [String]
}
extension StructureMigrationObject {
    private enum CodingKeys: String, CodingKey { case `id`, `target`, `draft`, `after` }
    init(from decoder: any Decoder) throws {
        let c = try migrationKeys(decoder, CodingKeys.self, allowed: ["id", "target", "draft", "after"])
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`target` = try c.decode(StructureTarget.self, forKey: .`target`)
        self.`draft` = try c.decode(StructureDraft.self, forKey: .`draft`)
        self.`after` = try c.decode([String].self, forKey: .`after`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructureMigrationRepair: Codable, Equatable, Sendable {
    var `id`: String
    var `target`: StructureTarget
    var `key`: String
    var `action`: String
    var `replacement`: StructureKeyEdit? = nil
}
extension StructureMigrationRepair {
    private enum CodingKeys: String, CodingKey { case `id`, `target`, `key`, `action`, `replacement` }
    init(from decoder: any Decoder) throws {
        let c = try migrationKeys(decoder, CodingKeys.self, allowed: ["id", "target", "key", "action", "replacement"])
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`target` = try c.decode(StructureTarget.self, forKey: .`target`)
        self.`key` = try c.decode(String.self, forKey: .`key`)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        self.`replacement` = try c.decodeIfPresent(StructureKeyEdit.self, forKey: .`replacement`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructureMigrationDraft: Codable, Equatable, Sendable {
    var `version`: Int
    var `objects`: [StructureMigrationObject]
    var `repairs`: [StructureMigrationRepair]
}
extension StructureMigrationDraft {
    private enum CodingKeys: String, CodingKey { case `version`, `objects`, `repairs` }
    init(from decoder: any Decoder) throws {
        let c = try migrationKeys(decoder, CodingKeys.self, allowed: ["version", "objects", "repairs"])
        self.`version` = try c.decode(Int.self, forKey: .`version`)
        self.`objects` = try c.decode([StructureMigrationObject].self, forKey: .`objects`)
        self.`repairs` = try c.decode([StructureMigrationRepair].self, forKey: .`repairs`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructureMigrationRequest: Codable, Equatable, Sendable {
    var `draft`: StructureMigrationDraft? = nil
    var `apply`: StructureApply? = nil
}
extension StructureMigrationRequest {
    private enum CodingKeys: String, CodingKey { case `draft`, `apply` }
    init(from decoder: any Decoder) throws {
        let c = try migrationKeys(decoder, CodingKeys.self, allowed: ["draft", "apply"])
        self.`draft` = try c.decodeIfPresent(StructureMigrationDraft.self, forKey: .`draft`)
        self.`apply` = try c.decodeIfPresent(StructureApply.self, forKey: .`apply`)
    }
}


struct StructureMigrationExpectation: Codable, Equatable, Sendable {
    var `target`: StructureTarget
    var `initialFingerprint`: String
    var `identityDigest`: String
    var `afterSteps`: [String]
}
extension StructureMigrationExpectation {
    private enum CodingKeys: String, CodingKey { case `target`, `initialFingerprint`, `identityDigest`, `afterSteps` }
    init(from decoder: any Decoder) throws {
        let c = try migrationKeys(decoder, CodingKeys.self, allowed: ["target", "initialFingerprint", "identityDigest", "afterSteps"])
        self.`target` = try c.decode(StructureTarget.self, forKey: .`target`)
        self.`initialFingerprint` = try c.decode(String.self, forKey: .`initialFingerprint`)
        self.`identityDigest` = try c.decode(String.self, forKey: .`identityDigest`)
        self.`afterSteps` = try c.decode([String].self, forKey: .`afterSteps`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructureMigrationStep: Codable, Equatable, Sendable {
    var `id`: String
    var `objectId`: String
    var `phase`: String
    var `target`: StructureTarget
    var `draft`: StructureDraft
    var `sql`: [String]
    var `digest`: String
    var `before`: [StructureMigrationExpectation]
    var `after`: [StructureMigrationExpectation]
    var `risks`: [String]
    var `consequences`: [StructureConsequence]? = nil
    var `atomic`: Bool
}
extension StructureMigrationStep {
    private enum CodingKeys: String, CodingKey { case `id`, `objectId`, `phase`, `target`, `draft`, `sql`, `digest`, `before`, `after`, `risks`, `consequences`, `atomic` }
    init(from decoder: any Decoder) throws {
        let c = try migrationKeys(decoder, CodingKeys.self, allowed: ["id", "objectId", "phase", "target", "draft", "sql", "digest", "before", "after", "risks", "consequences", "atomic"])
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`objectId` = try c.decode(String.self, forKey: .`objectId`)
        self.`phase` = try c.decode(String.self, forKey: .`phase`)
        self.`target` = try c.decode(StructureTarget.self, forKey: .`target`)
        self.`draft` = try c.decode(StructureDraft.self, forKey: .`draft`)
        self.`sql` = try c.decode([String].self, forKey: .`sql`)
        self.`digest` = try c.decode(String.self, forKey: .`digest`)
        self.`before` = try c.decode([StructureMigrationExpectation].self, forKey: .`before`)
        self.`after` = try c.decode([StructureMigrationExpectation].self, forKey: .`after`)
        self.`risks` = try c.decode([String].self, forKey: .`risks`)
        self.`consequences` = try c.decodeIfPresent([StructureConsequence].self, forKey: .`consequences`)
        self.`atomic` = try c.decode(Bool.self, forKey: .`atomic`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructureMigrationPlan: Codable, Equatable, Sendable {
    var `id`: String
    var `digest`: String
    var `engine`: String
    var `draft`: StructureMigrationDraft
    var `baselines`: [StructureBaseline]
    var `steps`: [StructureMigrationStep]
    var `risks`: [String]
    var `destructive`: Bool
}
extension StructureMigrationPlan {
    private enum CodingKeys: String, CodingKey { case `id`, `digest`, `engine`, `draft`, `baselines`, `steps`, `risks`, `destructive` }
    init(from decoder: any Decoder) throws {
        let c = try migrationKeys(decoder, CodingKeys.self, allowed: ["id", "digest", "engine", "draft", "baselines", "steps", "risks", "destructive"])
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`digest` = try c.decode(String.self, forKey: .`digest`)
        self.`engine` = try c.decode(String.self, forKey: .`engine`)
        self.`draft` = try c.decode(StructureMigrationDraft.self, forKey: .`draft`)
        self.`baselines` = try c.decode([StructureBaseline].self, forKey: .`baselines`)
        self.`steps` = try c.decode([StructureMigrationStep].self, forKey: .`steps`)
        self.`risks` = try c.decode([String].self, forKey: .`risks`)
        self.`destructive` = try c.decode(Bool.self, forKey: .`destructive`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructureMigrationObservation: Codable, Equatable, Sendable {
    var target: StructureTarget
    var fingerprint: String
    var identityDigest: String
}
extension StructureMigrationObservation {
    private enum CodingKeys: String, CodingKey { case target, fingerprint, identityDigest }
    init(from decoder: any Decoder) throws {
        let c = try migrationKeys(decoder, CodingKeys.self, allowed: ["target", "fingerprint", "identityDigest"])
        target = try c.decode(StructureTarget.self, forKey: .target)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        identityDigest = try c.decode(String.self, forKey: .identityDigest)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
    var valid: Bool { target.valid && target.reconcile == nil && StructureBaseline.digest(fingerprint) && StructureBaseline.digest(identityDigest) }
}

struct StructureMigrationStepOutcome: Codable, Equatable, Sendable {
    var `id`: String
    var `state`: String
    var `statements`: [StructureStepOutcome]
    var `message`: String? = nil
    var `observed`: [StructureMigrationObservation]? = nil
}
extension StructureMigrationStepOutcome {
    private enum CodingKeys: String, CodingKey { case `id`, `state`, `statements`, `message`, `observed` }
    init(from decoder: any Decoder) throws {
        let c = try migrationKeys(decoder, CodingKeys.self, allowed: ["id", "state", "statements", "message", "observed"])
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        self.`statements` = try c.decode([StructureStepOutcome].self, forKey: .`statements`)
        self.`message` = try c.decodeIfPresent(String.self, forKey: .`message`)
        self.`observed` = try c.decodeIfPresent([StructureMigrationObservation].self, forKey: .`observed`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructureMigrationOutcome: Codable, Equatable, Sendable {
    var `planId`: String
    var `executionId`: String
    var `state`: String
    var `steps`: [StructureMigrationStepOutcome]
    var `reconciliationRequired`: Bool
}
extension StructureMigrationOutcome {
    private enum CodingKeys: String, CodingKey { case `planId`, `executionId`, `state`, `steps`, `reconciliationRequired` }
    init(from decoder: any Decoder) throws {
        let c = try migrationKeys(decoder, CodingKeys.self, allowed: ["planId", "executionId", "state", "steps", "reconciliationRequired"])
        self.`planId` = try c.decode(String.self, forKey: .`planId`)
        self.`executionId` = try c.decode(String.self, forKey: .`executionId`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        self.`steps` = try c.decode([StructureMigrationStepOutcome].self, forKey: .`steps`)
        self.`reconciliationRequired` = try c.decode(Bool.self, forKey: .`reconciliationRequired`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructureMigrationExport: Codable, Equatable, Sendable {
    var `version`: Int
    var `draft`: StructureMigrationDraft
    var `sql`: String
}
extension StructureMigrationExport {
    private enum CodingKeys: String, CodingKey { case `version`, `draft`, `sql` }
    init(from decoder: any Decoder) throws {
        let c = try migrationKeys(decoder, CodingKeys.self, allowed: ["version", "draft", "sql"])
        self.`version` = try c.decode(Int.self, forKey: .`version`)
        self.`draft` = try c.decode(StructureMigrationDraft.self, forKey: .`draft`)
        self.`sql` = try c.decode(String.self, forKey: .`sql`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct StructureMigrationReply: Codable, Equatable, Sendable {
    var `plan`: StructureMigrationPlan? = nil
    var `draft`: StructureMigrationDraft? = nil
    var `outcome`: StructureMigrationOutcome? = nil
    var `observed`: [StructureBaseline]? = nil
    var `export`: StructureMigrationExport? = nil
}
extension StructureMigrationReply {
    private enum CodingKeys: String, CodingKey { case `plan`, `draft`, `outcome`, `observed`, `export` }
    init(from decoder: any Decoder) throws {
        let c = try migrationKeys(decoder, CodingKeys.self, allowed: ["plan", "draft", "outcome", "observed", "export"])
        self.`plan` = try c.decodeIfPresent(StructureMigrationPlan.self, forKey: .`plan`)
        self.`draft` = try c.decodeIfPresent(StructureMigrationDraft.self, forKey: .`draft`)
        self.`outcome` = try c.decodeIfPresent(StructureMigrationOutcome.self, forKey: .`outcome`)
        self.`observed` = try c.decodeIfPresent([StructureBaseline].self, forKey: .`observed`)
        self.`export` = try c.decodeIfPresent(StructureMigrationExport.self, forKey: .`export`)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}


extension StructureMigrationObject {
    var valid: Bool { migrationID(id) && target.valid && target.reconcile == nil && draft.valid && after.count <= 16 && after.allSatisfy(migrationID) && Set(after).count == after.count && !after.contains(id) }
}
extension StructureMigrationRepair {
    var valid: Bool {
        guard migrationID(id), target.valid, !target.create, target.reconcile == nil, StructureTarget.identifier(key) else { return false }
        if action == "drop" { return replacement == nil }
        return action == "replace" && replacement.map { $0.valid && $0.action == "add" && $0.kind == "foreign" && StructureTarget.sameIdentifier($0.name, key) } == true
    }
}
extension StructureMigrationDraft {
    var valid: Bool {
        guard version == 1, !objects.isEmpty, objects.count <= 16, repairs.count <= 16, objects.allSatisfy(\.valid), repairs.allSatisfy(\.valid) else { return false }
        let ids = objects.map(\.id) + repairs.map(\.id)
        guard Set(ids).count == ids.count, Set(objects.map { migrationTargetKey($0.target) }).count == objects.count else { return false }
        let objectIDs = Set(objects.map(\.id))
        guard objects.allSatisfy({ Set($0.after).isSubset(of: objectIDs) }) else { return false }
        let repairIDs = repairs.map { migrationTargetKey($0.target) + Data([0]) + Data($0.key.utf8) }
        return Set(repairIDs).count == repairIDs.count && (StructureTarget.intentBytes(self)?.count ?? Int.max) <= 1_048_576
    }
}
extension StructureMigrationRequest {
    func valid(for type: String) -> Bool {
        switch type {
        case "structure.migration.preview": return draft?.valid == true && apply == nil
        case "structure.migration.apply", "structure.migration.export": return draft == nil && apply?.valid == true
        case "structure.migration.status", "structure.migration.reconcile", "structure.migration.close": return draft == nil && apply == nil
        default: return false
        }
    }
}
extension StructureMigrationExpectation {
    var valid: Bool { target.valid && target.reconcile == nil && StructureBaseline.digest(initialFingerprint) && StructureBaseline.digest(identityDigest) && afterSteps.count <= 96 && afterSteps.allSatisfy(migrationID) && Set(afterSteps).count == afterSteps.count }
}
extension StructureMigrationStep {
    var valid: Bool {
        migrationID(id) && migrationID(objectId) && ["repairDrop", "object", "repairAdd"].contains(phase) && target.valid && target.reconcile == nil && draft.valid && !sql.isEmpty && sql.count <= 64 && sql.allSatisfy { migrationText($0, limit: 1_048_576) } && sql.reduce(0, { $0 + $1.utf8.count }) <= 1_048_576 && StructureBaseline.digest(digest) && !before.isEmpty && before.count <= 32 && before.allSatisfy(\.valid) && after.count == before.count && after.allSatisfy(\.valid) && risks.count <= 64 && risks.allSatisfy { migrationText($0) } && (consequences?.count ?? 0) <= 512 && (consequences?.allSatisfy(\.valid) ?? true)
    }
}
extension StructureMigrationPlan {
    var valid: Bool {
        guard migrationID(id), StructureBaseline.digest(digest), ["postgresql", "mysql", "mariadb", "sqlite"].contains(engine), draft.valid, !baselines.isEmpty, baselines.count <= 32, baselines.allSatisfy(\.valid), baselines.allSatisfy({ $0.engine == engine }), !steps.isEmpty, steps.count <= 96, steps.allSatisfy(\.valid), Set(steps.map(\.id)).count == steps.count, risks.count <= 64, risks.allSatisfy({ migrationText($0) }) else { return false }
        guard (StructureTarget.intentBytes(self)?.count ?? Int.max) <= 6 * 1_048_576 else { return false }
        let ids = Set(draft.objects.map(\.id) + draft.repairs.map(\.id))
        let targets = baselines.map { migrationTargetKey($0.target) }
        guard Set(targets).count == targets.count, steps.allSatisfy({ ids.contains($0.objectId) }), steps.flatMap(\.sql).reduce(0, { $0 + $1.utf8.count }) <= 1_048_576 else { return false }
        let baselineMap = Dictionary(uniqueKeysWithValues: baselines.map { (migrationTargetKey($0.target), $0.fingerprint) })
        var identities: [Data: String] = [:]
        var prior: [String] = []
        for step in steps {
            guard step.before.count == baselines.count, step.after.count == baselines.count else { return false }
            for expectations in [step.before, step.after] {
                guard Set(expectations.map { migrationTargetKey($0.target) }) == Set(targets) else { return false }
                for value in expectations {
                    let key = migrationTargetKey(value.target)
                    guard baselineMap[key] == value.initialFingerprint else { return false }
                    if let retained = identities[key], retained != value.identityDigest { return false }
                    identities[key] = value.identityDigest
                }
            }
            guard step.before.allSatisfy({ $0.afterSteps == prior }), step.after.allSatisfy({ $0.afterSteps == prior + [step.id] }) else { return false }
            prior.append(step.id)
        }
        return true
    }
}
extension StructureMigrationStepOutcome {
    var valid: Bool {
        guard migrationID(id), ["notStarted", "applied", "failed", "partiallyApplied", "outcomeUnknown"].contains(state), !statements.isEmpty, statements.count <= 64, statements.allSatisfy({ ["notStarted", "applied", "failed", "rolledBack", "unknown"].contains($0.state) && ($0.message?.utf8.count ?? 0) <= 4096 }), message.map({ migrationText($0) }) ?? true, (observed?.count ?? 0) <= 32, observed?.allSatisfy(\.valid) ?? true else { return false }
        let unknown = statements.contains { $0.state == "unknown" }
        switch state {
        case "notStarted": return statements.allSatisfy { $0.state == "notStarted" }
        case "applied": return statements.allSatisfy { $0.state == "applied" }
        case "outcomeUnknown": return unknown
        case "partiallyApplied": return !unknown && statements.contains { $0.state == "applied" }
        default: return !unknown && statements.contains { $0.state != "applied" }
        }
    }
}
extension StructureMigrationOutcome {
    var valid: Bool {
        guard migrationID(planId), migrationID(executionId), ["applying", "applied", "failed", "partiallyApplied", "outcomeUnknown", "cancelled"].contains(state), !steps.isEmpty, steps.count <= 96, steps.allSatisfy(\.valid), Set(steps.map(\.id)).count == steps.count else { return false }
        let lostAggregate = state == "outcomeUnknown" && steps.allSatisfy { $0.state == "outcomeUnknown" && $0.statements.allSatisfy { $0.state == "unknown" } }
        var stopped = false
        for step in steps {
            if !lostAggregate && stopped && step.state != "notStarted" { return false }
            if step.state != "applied" { stopped = true }
        }
        let unknown = steps.contains { $0.state == "outcomeUnknown" }
        let applied = steps.flatMap(\.statements).contains { $0.state == "applied" }
        switch state {
        case "applied": return steps.allSatisfy { $0.state == "applied" }
        case "outcomeUnknown": return unknown
        case "partiallyApplied": return applied && !unknown
        case "failed", "cancelled": return !applied && !unknown
        default: return !unknown
        }
    }
}
extension StructureMigrationExport {
    var valid: Bool { version == 1 && draft.valid && migrationText(sql, limit: 1_114_112) && sql.hasPrefix("-- DBeer reviewed migration: MANUAL execution.") }
}
extension StructureMigrationReply {
    var valid: Bool { (plan?.valid ?? true) && (draft?.valid ?? true) && (outcome?.valid ?? true) && (observed?.count ?? 0) <= 32 && (observed?.allSatisfy(\.valid) ?? true) && (self.export?.valid ?? true) }
}

extension StructureMigrationDraft { static func == (a: Self, b: Self) -> Bool { StructureTarget.intentBytes(a) == StructureTarget.intentBytes(b) } }
