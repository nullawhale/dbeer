import Foundation

/// Only the identity of an explicitly selected saved profile is persisted.
struct ERDiagramSource: Codable, Equatable, Identifiable, Sendable {
    let profileID: UUID
    let engine: DatabaseEngine
    let database: String
    let fingerprint: String
    var name: String
    var id: UUID { profileID }

    init(_ profile: SavedConnection) {
        profileID = profile.id; engine = profile.engine; database = profile.database
        fingerprint = LogicalRelationshipEndpoint.fingerprint(profile); name = profile.name
    }
    var isValid: Bool {
        [.postgresql, .mysql, .sqlite].contains(engine) && database.utf8.count <= 1_024 && !database.contains("\0") &&
            name.utf8.count <= 1_024 && fingerprint.utf8.count == 64 &&
            fingerprint.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    var revision: UUID? {
        guard fingerprint.utf8.count == 64 else { return nil }
        let h = Array(fingerprint.prefix(32))
        return UUID(uuidString: String(h[0..<8]) + "-" + String(h[8..<12]) + "-" + String(h[12..<16]) + "-" + String(h[16..<20]) + "-" + String(h[20..<32]))
    }
    func matches(_ profile: SavedConnection) -> Bool {
        profile.id == profileID && profile.engine == engine && Data(profile.database.utf8) == Data(database.utf8) &&
            LogicalRelationshipEndpoint.fingerprint(profile) == fingerprint
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case profileID, engine, database, fingerprint, name }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Key.self)
        guard Set(keys.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else { throw SQLDocumentStoreError.read }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try c.decode(UUID.self, forKey: .profileID); engine = try c.decode(DatabaseEngine.self, forKey: .engine)
        database = try c.decode(String.self, forKey: .database); fingerprint = try c.decode(String.self, forKey: .fingerprint)
        name = try c.decode(String.self, forKey: .name)
        guard isValid else { throw SQLDocumentStoreError.read }
    }
}

@MainActor
struct ERDiagramSourceState {
    var generation: UInt64 = 0
    var context: ERDiagramLoadContext?
    var request: CatalogMetadataRequest?
    var loading = false
    var progress = 0
    var notice: String? = "Not loaded. Build this source explicitly."
    var observation: ERSchemaObservation?
}
