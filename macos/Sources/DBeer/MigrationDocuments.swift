import Foundation

/// Portable intent contains no connection, captured authority, execution plan or report.
struct MigrationDraftDocument: Encodable, Equatable, Sendable {
    static let maximumBytes = 1_048_576
    let version: Int
    var draft: StructureMigrationDraft

    init(draft: StructureMigrationDraft) {
        version = 1
        self.draft = draft
        for index in self.draft.objects.indices { self.draft.objects[index].draft.allowDestructive = nil }
    }
    var valid: Bool {
        guard version == 1, draft.version == 1, !draft.objects.isEmpty, draft.objects.count <= 16, draft.repairs.count <= 16,
              draft.repairs.allSatisfy(\.valid) else { return false }
        let ids = draft.objects.map(\.id) + draft.repairs.map(\.id)
        let objectIDs = Set(draft.objects.map(\.id))
        let targets = draft.objects.map { Data($0.target.schema.utf8) + Data([0]) + Data($0.target.table.utf8) }
        let repairs = draft.repairs.map { Data($0.target.schema.utf8) + Data([0]) + Data($0.target.table.utf8) + Data([0]) + Data($0.key.utf8) }
        return Set(targets).count == targets.count && Set(repairs).count == repairs.count && ids.allSatisfy(Self.identifier) && Set(ids).count == ids.count && draft.objects.allSatisfy { object in
            object.target.valid && object.target.reconcile == nil && object.after.count <= 16 &&
                Set(object.after).count == object.after.count && !object.after.contains(object.id) &&
                Set(object.after).isSubset(of: objectIDs) && object.draft.allowDestructive == nil &&
                StructureDraftDocument(engine: .postgresql, target: object.target, draft: object.draft).valid
        }
    }
    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    static func decode(_ text: String) throws -> Self {
        let data = Data(text.utf8)
        try ExactJSONKeys.validate(data, maximumBytes: maximumBytes)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["version", "draft"],
              let rawDraft = object["draft"] as? [String: Any], Set(rawDraft.keys) == ["version", "objects", "repairs"] else { throw StructureDraftFileError.invalidDocument }
        // The wire draft validator requires destructive consent. Decode portable
        // intent using the established bounded draft-file boundary instead.
        guard let rawObjects = rawDraft["objects"] as? [[String: Any]], rawObjects.count <= 16 else { throw StructureDraftFileError.invalidDocument }
        var objects: [StructureMigrationObject] = []
        for raw in rawObjects {
            guard Set(raw.keys) == ["id", "target", "draft", "after"], let id = raw["id"] as? String,
                  let after = raw["after"] as? [String], let intent = raw["draft"] as? [String: Any], intent["allowDestructive"] == nil,
                  let targetObject = raw["target"] as? [String: Any] else { throw StructureDraftFileError.invalidDocument }
            let wrapped: [String: Any] = ["formatVersion": 5, "engine": "postgresql", "target": targetObject, "draft": intent]
            let value = try JSONDecoder().decode(StructureDraftDocument.self, from: JSONSerialization.data(withJSONObject: wrapped))
            objects.append(.init(id: id, target: value.target, draft: value.draft, after: after))
        }
        guard let repairs = rawDraft["repairs"] as? [[String: Any]] else { throw StructureDraftFileError.invalidDocument }
        struct Header: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).version
        let draftVersion = try JSONDecoder().decode(Header.self, from: JSONSerialization.data(withJSONObject: rawDraft)).version
        let decodedRepairs = try JSONDecoder().decode([StructureMigrationRepair].self, from: JSONSerialization.data(withJSONObject: repairs))
        let value = Self(version: version, draft: .init(version: draftVersion, objects: objects, repairs: decodedRepairs))
        guard value.valid else { throw StructureDraftFileError.invalidDocument }
        return value
    }
    private init(version: Int, draft: StructureMigrationDraft) { self.version = version; self.draft = draft }
    func encoded() throws -> String {
        guard valid else { throw StructureDraftFileError.invalidDocument }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count < Self.maximumBytes else { throw StructureDraftFileError.invalidDocument }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// Evidence is independent of editable portable intent and never grants replay.
struct MigrationExecutionDocument: Codable, Equatable, Sendable, Identifiable {
    static let maximumBytes = 8 * 1_024 * 1_024
    let version: Int
    let plan: StructureMigrationPlan
    var outcome: StructureMigrationOutcome
    var id: String { outcome.executionId }
    init(plan: StructureMigrationPlan, outcome: StructureMigrationOutcome) { version = 1; self.plan = plan; self.outcome = outcome }
    var valid: Bool { version == 1 && plan.valid && MigrationTransportAdmission.matches(outcome, plan: plan) }
    func encoded() throws -> String {
        guard valid else { throw StructureDraftFileError.invalidDocument }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count < Self.maximumBytes else { throw StructureDraftFileError.invalidDocument }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
    static func decode(_ text: String) throws -> Self {
        let data = Data(text.utf8)
        try ExactJSONKeys.validate(data, maximumBytes: maximumBytes)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["version", "plan", "outcome"] else { throw StructureDraftFileError.invalidDocument }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.valid else { throw StructureDraftFileError.invalidDocument }
        return value
    }
}

enum MigrationTransportAdmission {
    static func validate(_ value: StructureMigrationReply?, command: BackendCommand) throws {
        guard let value, value.valid(for: command.type + ".result") else { throw BackendTransportError(.invalidMessage) }
        if let draft = command.structure?.migration?.draft, value.plan?.draft != draft { throw BackendTransportError(.invalidMessage) }
        if let apply = command.structure?.migration?.apply {
            if command.type == "structure.migration.apply" {
                guard value.outcome?.planId == apply.planId, value.outcome?.executionId == apply.executionId else { throw BackendTransportError(.invalidMessage) }
            }
        }
    }
    static func matches(_ outcome: StructureMigrationOutcome, plan: StructureMigrationPlan) -> Bool {
        outcome.valid && outcome.planId == plan.id && outcome.steps.map(\.id) == plan.steps.map(\.id) &&
            zip(outcome.steps, plan.steps).allSatisfy { $0.statements.count == $1.sql.count } &&
            (outcome.state != "applied" || outcome.steps.allSatisfy { $0.state == "applied" && $0.statements.allSatisfy { $0.state == "applied" } })
    }
    static func preserves(_ next: StructureMigrationOutcome, previous: StructureMigrationOutcome) -> Bool {
        guard next.steps.map(\.id) == previous.steps.map(\.id) else { return false }
        return zip(next.steps, previous.steps).allSatisfy { nextStep, oldStep in
            (oldStep.state != "applied" || nextStep.state == "applied") && nextStep.statements.count == oldStep.statements.count &&
                zip(nextStep.statements, oldStep.statements).allSatisfy { $1.state != "applied" || $0.state == "applied" }
        }
    }
}

extension StructureMigrationReply {
    func valid(for type: String) -> Bool {
        guard valid else { return false }
        switch type {
        case "structure.migration.preview.result": return plan != nil && draft != nil && observed == nil && self.export == nil
        case "structure.migration.apply.result": return plan == nil && draft != nil && outcome != nil && observed == nil && self.export == nil
        case "structure.migration.export.result": return plan == nil && draft == nil && outcome == nil && observed == nil && self.export != nil
        case "structure.migration.status.result": return plan == nil && observed == nil && self.export == nil
        case "structure.migration.reconcile.result": return plan == nil && draft != nil && observed != nil && self.export == nil
        case "structure.migration.close.result": return plan == nil && observed == nil && self.export == nil
        default: return false
        }
    }
}
