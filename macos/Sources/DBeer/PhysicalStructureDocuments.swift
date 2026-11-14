import Foundation

/// Portable physical intent contains no connection, plan, grant or execution state.
struct PhysicalStructureIntentDocument: Codable, Equatable, Sendable {
    static let maximumBytes = 1_048_576
    let version: Int
    let engine: DatabaseEngine
    let draft: StructurePhysicalDraft
    init(engine: DatabaseEngine, draft: StructurePhysicalDraft) { version = 1; self.engine = engine; self.draft = draft }
    var valid: Bool { version == 1 && [.postgresql, .mysql, .mariadb].contains(engine) && draft.valid(for: engine) }
    func encoded() throws -> String {
        guard valid else { throw StructureDraftFileError.invalidDocument }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count < Self.maximumBytes else { throw StructureDraftFileError.invalidDocument }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
    static func decode(_ text: String) throws -> Self {
        let data = Data(text.utf8)
        try ExactJSONKeys.validate(data, maximumBytes: maximumBytes)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["version", "engine", "draft"] else { throw StructureDraftFileError.invalidDocument }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.valid else { throw StructureDraftFileError.invalidDocument }
        return value
    }
}

/// Historical plan IDs and fingerprints are evidence; importing never registers a live owner.
extension PhysicalStructureReport {
    static let maximumBytes = 8 * 1_048_576
    var valid: Bool { version == 1 && plan.valid && PhysicalTransportAdmission.matches(outcome, plan: plan) }
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
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["version", "plan", "outcome", "serverEvidence"] else { throw StructureDraftFileError.invalidDocument }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.valid else { throw StructureDraftFileError.invalidDocument }
        return value
    }
}
