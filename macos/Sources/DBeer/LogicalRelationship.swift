import CryptoKit
import Foundation

enum LogicalRelationshipLimits {
    static let relationships = 512
    static let columns = 32
    static let libraryBytes = 4 * 1_024 * 1_024
    static let metadataBytes = 8 * 1_024 * 1_024
}

enum LogicalRelationshipError: LocalizedError, Equatable {
    case invalid, read, write, changed, busy, notFound
    case metadata(String)
    var errorDescription: String? {
        switch self {
        case .invalid: "The local relationship has invalid identifiers or incomplete, duplicate column mappings."
        case .read: "Local relationships could not be read. The existing library has been left unchanged."
        case .write: "Local relationships could not be saved. The local draft has been kept."
        case .changed: "Local relationships changed in another window or process. Reload the library before saving."
        case .busy: "The local relationship library is still loading or saving."
        case .notFound: "This local relationship is no longer available."
        case .metadata(let reason): reason
        }
    }
}

/// A profile fingerprint binds a confirmed link to its original connection
/// settings without copying connection details, credentials or private keys.
struct LogicalRelationshipEndpoint: Codable, Hashable, Sendable {
    let profileID: UUID
    let engine: DatabaseEngine
    let profileFingerprint: String
    let schema: String
    let name: String
    let kind: String

    init(profile: SavedConnection, reference: TableReference) {
        profileID = profile.id; engine = profile.engine
        profileFingerprint = Self.fingerprint(profile)
        schema = reference.schema; name = reference.name; kind = reference.kind
    }
    init(profileID: UUID, engine: DatabaseEngine, profileFingerprint: String, schema: String, name: String, kind: String = "table") {
        self.profileID = profileID; self.engine = engine; self.profileFingerprint = profileFingerprint
        self.schema = schema; self.name = name; self.kind = kind
    }
    var reference: TableReference { .init(schema: schema, name: name, kind: kind) }
    var tableID: ERTableID { .init(profileID: profileID, schema: schema, name: name) }
    var label: String { schema + "." + name }
    var isValid: Bool {
        [.postgresql, .mysql, .mariadb, .sqlite].contains(engine) && ["table", "view"].contains(kind) &&
            ERTableID.validName(schema) && ERTableID.validName(name) &&
            profileFingerprint.utf8.count == 64 && profileFingerprint.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func matches(_ profile: SavedConnection) -> Bool {
        profile.id == profileID && profile.engine == engine && profileFingerprint == Self.fingerprint(profile)
    }
    func matches(profileID: UUID, reference: TableReference) -> Bool {
        self.profileID == profileID && kind == reference.kind &&
            Data(schema.utf8) == Data(reference.schema.utf8) && Data(name.utf8) == Data(reference.name.utf8)
    }
    static func fingerprint(_ profile: SavedConnection) -> String {
        struct SSHRoute: Encodable { let host: String; let port: Int; let user: String; let authMethod: String; let configFile: String? }
        struct Identity: Encodable {
            let id: UUID; let engine: DatabaseEngine; let host: String; let port: Int; let database: String; let user: String
            let sslMode: String; let sslRootCert: String?; let policy: ExecutionPolicy; let sqlite: SQLiteSettings?; let ssh: SSHRoute?
        }
        // Credential providers, their arguments, key files, human labels and
        // all resolved secrets are deliberately outside the identity DTO.
        let identity = Identity(id: profile.id, engine: profile.engine, host: profile.host, port: profile.port,
            database: profile.database, user: profile.user, sslMode: profile.sslMode, sslRootCert: profile.sslRootCert,
            policy: profile.policy, sqlite: profile.sqlite,
            ssh: profile.ssh.map { .init(host: $0.host, port: $0.port, user: $0.user, authMethod: $0.authMethod.rawValue, configFile: $0.configFile) })
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(identity) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profileID == rhs.profileID && lhs.engine == rhs.engine && lhs.profileFingerprint == rhs.profileFingerprint &&
            Data(lhs.schema.utf8) == Data(rhs.schema.utf8) && Data(lhs.name.utf8) == Data(rhs.name.utf8) && lhs.kind == rhs.kind
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(profileID); hasher.combine(engine); hasher.combine(profileFingerprint)
        hasher.combine(Data(schema.utf8)); hasher.combine(Data(name.utf8)); hasher.combine(kind)
    }
    private enum CodingKeys: String, CodingKey { case profileID, engine, profileFingerprint, schema, name, kind }
    init(from decoder: any Decoder) throws {
        try logicalRelationshipKeys(decoder, allowed: ["profileID", "engine", "profileFingerprint", "schema", "name", "kind"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try values.decode(UUID.self, forKey: .profileID)
        engine = try values.decode(DatabaseEngine.self, forKey: .engine)
        profileFingerprint = try values.decode(String.self, forKey: .profileFingerprint)
        schema = try values.decode(String.self, forKey: .schema)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(String.self, forKey: .kind)
        guard isValid else { throw LogicalRelationshipError.invalid }
    }
}

struct LogicalRelationshipColumn: Codable, Equatable, Sendable {
    var source: String
    var target: String
    var sourceType: String
    var targetType: String
    /// Cross-engine navigation to SQLite requires a deliberate bound storage
    /// class. Native SQLite sources retain their authoritative storage bytes.
    var sqliteStorage: String
    var isValid: Bool {
        ERTableID.validName(source) && ERTableID.validName(target) &&
            [sourceType, targetType].allSatisfy { !$0.isEmpty && $0.utf8.count <= 16_384 && !$0.contains("\0") } &&
            ["preserve", "text", "integer", "real", "blob"].contains(sqliteStorage)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        Data(lhs.source.utf8) == Data(rhs.source.utf8) && Data(lhs.target.utf8) == Data(rhs.target.utf8) &&
            Data(lhs.sourceType.utf8) == Data(rhs.sourceType.utf8) && Data(lhs.targetType.utf8) == Data(rhs.targetType.utf8) && lhs.sqliteStorage == rhs.sqliteStorage
    }
    private enum CodingKeys: String, CodingKey { case source, target, sourceType, targetType, sqliteStorage }
    init(source: String, target: String, sourceType: String = "", targetType: String = "", sqliteStorage: String = "preserve") {
        self.source = source; self.target = target; self.sourceType = sourceType; self.targetType = targetType; self.sqliteStorage = sqliteStorage
    }
    init(from decoder: any Decoder) throws {
        try logicalRelationshipKeys(decoder, allowed: ["source", "target", "sourceType", "targetType", "sqliteStorage"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        source = try fields.decode(String.self, forKey: .source); target = try fields.decode(String.self, forKey: .target)
        sourceType = try fields.decode(String.self, forKey: .sourceType); targetType = try fields.decode(String.self, forKey: .targetType)
        sqliteStorage = try fields.decode(String.self, forKey: .sqliteStorage)
        guard isValid else { throw LogicalRelationshipError.invalid }
    }
}

enum LogicalRelationshipOrigin: String, Codable, Sendable { case manual, nameTypeSuggestion }

/// Only an explicitly confirmed mapping enters the library. Suggestions stay
/// in the editor and cannot become server constraints or JOIN evidence.
struct LogicalRelationship: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var source: LogicalRelationshipEndpoint
    var target: LogicalRelationshipEndpoint
    var columns: [LogicalRelationshipColumn]
    var origin: LogicalRelationshipOrigin

    init(id: UUID = UUID(), name: String, source: LogicalRelationshipEndpoint, target: LogicalRelationshipEndpoint,
         columns: [LogicalRelationshipColumn], origin: LogicalRelationshipOrigin = .manual) {
        self.id = id; self.name = name; self.source = source; self.target = target; self.columns = columns; self.origin = origin
    }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 1_024 && !name.contains("\0") &&
            source.isValid && target.isValid && (1...LogicalRelationshipLimits.columns).contains(columns.count) &&
            columns.allSatisfy(\.isValid) && Set(columns.map { Data($0.source.utf8) }).count == columns.count &&
            Set(columns.map { Data($0.target.utf8) }).count == columns.count &&
            (source.engine == target.engine || source.engine != .sqlite && target.engine != .sqlite || columns.allSatisfy { $0.sqliteStorage != "preserve" })
    }
    var isCrossProfile: Bool { source.profileID != target.profileID }
    var key: TableForeignKey {
        .init(name: name, target: target.reference, columns: columns.enumerated().map {
            .init(source: $0.element.source, target: $0.element.target, position: $0.offset + 1)
        })
    }
    var reversed: Self {
        .init(id: id, name: name, source: target, target: source, columns: columns.map {
            .init(source: $0.target, target: $0.source, sourceType: $0.targetType, targetType: $0.sourceType,
                  sqliteStorage: $0.sqliteStorage)
        }, origin: origin)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && Data(lhs.name.utf8) == Data(rhs.name.utf8) && lhs.source == rhs.source &&
            lhs.target == rhs.target && lhs.columns == rhs.columns && lhs.origin == rhs.origin
    }
    private enum CodingKeys: String, CodingKey { case id, name, source, target, columns, origin }
    init(from decoder: any Decoder) throws {
        try logicalRelationshipKeys(decoder, allowed: ["id", "name", "source", "target", "columns", "origin"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id); name = try fields.decode(String.self, forKey: .name)
        source = try fields.decode(LogicalRelationshipEndpoint.self, forKey: .source)
        target = try fields.decode(LogicalRelationshipEndpoint.self, forKey: .target)
        columns = try fields.decode([LogicalRelationshipColumn].self, forKey: .columns)
        origin = try fields.decode(LogicalRelationshipOrigin.self, forKey: .origin)
        guard isValid else { throw LogicalRelationshipError.invalid }
    }
}

struct LogicalRelationshipSuggestion: Identifiable, Equatable, Sendable {
    let relationship: LogicalRelationship
    let reason: String
    var id: UUID { relationship.id }
}

func logicalRelationshipKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    struct Key: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    let fields = try decoder.container(keyedBy: Key.self)
    guard Set(fields.allKeys.map(\.stringValue)) == allowed,
          fields.allKeys.allSatisfy({ (try? fields.decodeNil(forKey: $0)) == false }) else { throw LogicalRelationshipError.invalid }
}
