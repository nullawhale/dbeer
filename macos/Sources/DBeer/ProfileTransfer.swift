import Darwin
import Foundation

struct ImportedProfile: Identifiable, Equatable, Sendable {
    var profile: SavedConnection
    var isSelected = true
    var id: UUID { profile.id }

    /// Recomputed before importing too, so a CA removed after preview does not
    /// silently switch the connection to the system trust store.
    var requiresCASelection: Bool {
        guard let path = profile.sslRootCert else { return false }
        return !ProfileTransfer.isLocalReadableCA(path)
    }
}

enum ProfileTransferError: LocalizedError {
    case invalid, unsupportedVersion, write

    var errorDescription: String? {
        switch self {
        case .invalid: "The profile file is invalid or contains unsupported fields. No connections were imported."
        case .unsupportedVersion: "This profile file uses an unsupported version. No connections were imported."
        case .write: "The connection profiles could not be exported."
        }
    }
}

/// Portable metadata only. UUIDs and password/private-key fields have no place
/// in this format; decoding a preview never reads or writes Keychain.
enum ProfileTransfer {
    static let currentVersion = 2
    static let maxFileBytes = 2 * 1_024 * 1_024
    static let maxProfiles = 1_000

    private struct Envelope: Codable {
        let version: Int
        let profiles: [Profile]
    }

    private struct Profile: Codable {
        let name: String
        let engine: DatabaseEngine
        let host: String
        let port: Int
        let database: String
        let user: String
        let sslMode: String
        let sslRootCert: String?
        var policy: ExecutionPolicy?
        var contactPoints: [String]?
        var localDatacenter: String?
        var consistency: String?

        init(_ saved: SavedConnection) {
            name = saved.name
            engine = saved.engine
            host = saved.host
            port = saved.port
            database = saved.database
            user = saved.user
            sslMode = saved.sslMode
            sslRootCert = saved.sslRootCert
            policy = saved.policy
            contactPoints = saved.contactPoints
            localDatacenter = saved.localDatacenter
            consistency = saved.consistency
        }

        func imported() -> ImportedProfile {
            ImportedProfile(profile: SavedConnection(id: UUID(), name: name, settings: ConnectionSettings(
                host: host, port: port, database: database, user: user, password: "", sslMode: sslMode,
                sslRootCert: sslRootCert, engine: engine, policy: policy ?? ExecutionPolicy(), contactPoints: contactPoints,
                localDatacenter: localDatacenter, consistency: consistency)))
        }
    }

    static func encode(_ profiles: [SavedConnection]) throws -> Data {
        let descriptions = profiles.map(Profile.init)
        try validate(descriptions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: currentVersion, profiles: descriptions))
        guard data.count <= maxFileBytes else { throw ProfileTransferError.invalid }
        return data
    }

    static func preview(_ data: Data) throws -> [ImportedProfile] {
        do {
            guard !data.isEmpty, data.count <= maxFileBytes, String(data: data, encoding: .utf8) != nil,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["version", "profiles"], let raw = object["profiles"] as? [[String: Any]] else {
                throw ProfileTransferError.invalid
            }
            var uniqueKeys = UniqueJSONKeys(data)
            try uniqueKeys.validate()
            let permitted: Set<String> = ["name", "engine", "host", "port", "database", "user", "sslMode", "sslRootCert", "policy", "contactPoints", "localDatacenter", "consistency"]
            let required = permitted.subtracting(["sslRootCert", "policy", "contactPoints", "localDatacenter", "consistency"])
            guard raw.allSatisfy({ Set($0.keys).isSubset(of: permitted) && required.isSubset(of: Set($0.keys)) }) else {
                throw ProfileTransferError.invalid
            }
            guard raw.allSatisfy({ record in
                // Legacy v1 treats null like omission. Version 2 still requires
                // a decoded policy below, and present objects remain strict.
                guard let policy = record["policy"], !(policy is NSNull) else { return true }
                guard let fields = policy as? [String: Any] else { return false }
                return Set(fields.keys) == ["environment", "readOnly"]
            }) else { throw ProfileTransferError.invalid }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1 || envelope.version == currentVersion else { throw ProfileTransferError.unsupportedVersion }
            if envelope.version == currentVersion, envelope.profiles.contains(where: { $0.policy == nil }) { throw ProfileTransferError.invalid }
            try validate(envelope.profiles)
            return envelope.profiles.map { $0.imported() }
        } catch let error as ProfileTransferError { throw error }
        catch { throw ProfileTransferError.invalid }
    }

    static func write(_ profiles: [SavedConnection], to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".dbeer-profiles-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let data = try encode(profiles)
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
                  rename(temporary.path, destination.path) == 0 else { throw ProfileTransferError.write }
        } catch { throw ProfileTransferError.write }
    }

    private static func validate(_ profiles: [Profile]) throws {
        guard !profiles.isEmpty, profiles.count <= maxProfiles,
              profiles.allSatisfy({ profile in
                  let fields = [profile.name, profile.host] + (profile.engine == .cassandra ? [] : [profile.database, profile.user])
                  return fields.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      !$0.contains("\0") && $0.utf8.count <= 1_024 } && profile.name.count <= 128 &&
                      profile.imported().profile.settings(password: "").hasValidNativeFields &&
                      (profile.sslRootCert.map { validCAHint($0) } ?? true)
              }) else { throw ProfileTransferError.invalid }
    }

    /// Portable absolute hints carry no authority on another OS. Only a POSIX
    /// path can be local on this Mac; Windows drive/UNC hints require the user
    /// to choose a local CA before import. Never probe foreign/network hints.
    static func validCAHint(_ path: String) -> Bool {
        guard !path.isEmpty, !path.contains("\0"), path.utf8.count <= 4_096 else { return false }
        if path.hasPrefix("/") { return true }
        let bytes = Array(path.utf8)
        if bytes.count >= 3, ((65...90).contains(bytes[0]) || (97...122).contains(bytes[0])),
           bytes[1] == 58, bytes[2] == 92 || bytes[2] == 47 { return true }
        if path.hasPrefix("\\\\") {
            let parts = path.dropFirst(2).split(separator: "\\", omittingEmptySubsequences: false)
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty,
                  !["?", "."].contains(String(parts[0])),
                  !parts[0].contains(where: { $0 == "/" || $0 == ":" }),
                  !parts[1].contains(where: { $0 == "/" || $0 == ":" }) else { return false }
            return true
        }
        return false
    }

    static func isLocalReadableCA(_ path: String) -> Bool {
        guard validCAHint(path), path.hasPrefix("/") else { return false }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) &&
            !directory.boolValue && FileManager.default.isReadableFile(atPath: path)
    }

    /// JSONDecoder accepts repeated keys. Reject them, including escaped
    /// spellings of the same key, before choosing a database target.
    private struct UniqueJSONKeys {
        let bytes: [UInt8]
        var index = 0
        init(_ data: Data) { bytes = Array(data) }

        mutating func validate() throws {
            try value(depth: 0)
            whitespace()
            guard index == bytes.count else { throw ProfileTransferError.invalid }
        }

        private mutating func whitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }

        private mutating func string() throws -> String {
            guard index < bytes.count, bytes[index] == 34 else { throw ProfileTransferError.invalid }
            let start = index
            index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2 }
                else if bytes[index] == 34 {
                    index += 1
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                } else { index += 1 }
            }
            throw ProfileTransferError.invalid
        }

        private mutating func value(depth: Int) throws {
            guard depth < 16 else { throw ProfileTransferError.invalid }
            whitespace()
            guard index < bytes.count else { throw ProfileTransferError.invalid }
            switch bytes[index] {
            case 123:
                index += 1
                whitespace()
                var keys: Set<String> = []
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                while index < bytes.count {
                    whitespace()
                    let key = try string()
                    guard keys.insert(key).inserted else { throw ProfileTransferError.invalid }
                    whitespace()
                    guard index < bytes.count, bytes[index] == 58 else { throw ProfileTransferError.invalid }
                    index += 1
                    try value(depth: depth + 1)
                    whitespace()
                    guard index < bytes.count else { throw ProfileTransferError.invalid }
                    if bytes[index] == 125 { index += 1; return }
                    guard bytes[index] == 44 else { throw ProfileTransferError.invalid }
                    index += 1
                }
                throw ProfileTransferError.invalid
            case 91:
                index += 1
                whitespace()
                if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while index < bytes.count {
                    try value(depth: depth + 1)
                    whitespace()
                    guard index < bytes.count else { throw ProfileTransferError.invalid }
                    if bytes[index] == 93 { index += 1; return }
                    guard bytes[index] == 44 else { throw ProfileTransferError.invalid }
                    index += 1
                }
                throw ProfileTransferError.invalid
            case 34: _ = try string()
            default:
                let start = index
                while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                guard index > start else { throw ProfileTransferError.invalid }
            }
        }
    }
}
