import Foundation
import Darwin

/// The persisted connection description. Passwords belong exclusively to the credential store.
struct SavedConnection: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var engine: DatabaseEngine
    var host: String
    var port: Int
    var database: String
    var user: String
    var sslMode: String
    var sslRootCert: String?
    var policy: ExecutionPolicy
    var contactPoints: [String]?
    var localDatacenter: String?
    var consistency: String?
    var ssh: SSHConfiguration?
    var passwordCommand: PasswordCommand?

    init(id: UUID = UUID(), name: String, settings: ConnectionSettings) {
        ssh = settings.ssh?.configuration
        passwordCommand = settings.passwordCommand
        self.id = id
        self.name = name
        engine = settings.engine
        host = settings.host
        port = settings.port
        database = settings.database
        user = settings.user
        sslMode = settings.sslMode
        sslRootCert = settings.sslRootCert
        policy = settings.policy
        contactPoints = settings.contactPoints
        localDatacenter = settings.localDatacenter
        consistency = settings.consistency
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case id, name, engine, host, port, database, user, sslMode, sslRootCert, policy, contactPoints, localDatacenter, consistency, ssh, passwordCommand
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ssh = try values.decodeIfPresent(SSHConfiguration.self, forKey: .ssh)
        passwordCommand = try values.decodeIfPresent(PasswordCommand.self, forKey: .passwordCommand)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        engine = try values.decodeIfPresent(DatabaseEngine.self, forKey: .engine) ?? .postgresql
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        database = try values.decode(String.self, forKey: .database)
        user = try values.decode(String.self, forKey: .user)
        sslMode = try values.decode(String.self, forKey: .sslMode)
        sslRootCert = try values.decodeIfPresent(String.self, forKey: .sslRootCert)
        policy = try values.decodeIfPresent(ExecutionPolicy.self, forKey: .policy) ?? ExecutionPolicy()
        contactPoints = try values.decodeIfPresent([String].self, forKey: .contactPoints)
        localDatacenter = try values.decodeIfPresent(String.self, forKey: .localDatacenter)
        consistency = try values.decodeIfPresent(String.self, forKey: .consistency) ?? (engine == .cassandra ? "LOCAL_QUORUM" : nil)
    }

    func settings(password: String) -> ConnectionSettings {
        ConnectionSettings(host: host, port: port, database: database, user: user,
            password: password, sslMode: sslMode, sslRootCert: sslRootCert, engine: engine, policy: policy, contactPoints: contactPoints,
            localDatacenter: localDatacenter, consistency: consistency, ssh: ssh?.runtime(profileId: id), passwordCommand: passwordCommand)
    }

    func matches(_ settings: ConnectionSettings) -> Bool {
        passwordCommand == settings.passwordCommand && ssh == settings.ssh?.configuration && engine == settings.engine && host == settings.host && port == settings.port && database == settings.database &&
            user == settings.user && sslMode == settings.sslMode && sslRootCert == settings.sslRootCert && policy == settings.policy &&
            contactPoints == settings.contactPoints && localDatacenter == settings.localDatacenter && consistency == settings.consistency
    }
}

struct SavedConnectionLibrary: Codable, Equatable, Sendable {
    static let currentVersion = 5
    private(set) var version: Int
    var connections: [SavedConnection]
    var selectedConnectionId: UUID?

    init(connections: [SavedConnection] = [], selectedConnectionId: UUID? = nil) {
        version = Self.currentVersion
        self.connections = connections
        self.selectedConnectionId = selectedConnectionId
    }

    private enum CodingKeys: String, CodingKey { case version, connections, selectedConnectionId }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...Self.currentVersion).contains(version) else {
            throw ConnectionLibraryError.load
        }
        var records = try values.nestedUnkeyedContainer(forKey: .connections)
        connections = []
        while !records.isAtEnd {
            let record = try records.superDecoder()
            if version >= 2 {
                // Missing engine is a migration rule only for old profiles;
                // malformed v2 records must not silently change their adapter.
                let header = try record.container(keyedBy: SavedConnection.CodingKeys.self)
                _ = try header.decode(DatabaseEngine.self, forKey: .engine)
                if version >= 3 { _ = try header.decode(ExecutionPolicy.self, forKey: .policy) }
            }
            connections.append(try SavedConnection(from: record))
        }
        selectedConnectionId = try values.decodeIfPresent(UUID.self, forKey: .selectedConnectionId)
    }
}

protocol ConnectionLibraryStore: Sendable {
    func load() async throws -> SavedConnectionLibrary
    func save(_ library: SavedConnectionLibrary) async throws
}

protocol ConnectionCredentialStore: Sendable {
    func password(for id: UUID) async throws -> String?
    func savePassword(_ password: String, for id: UUID) async throws
    func deletePassword(for id: UUID) async throws
    func secret(for id: UUID, purpose: ConnectionCredentialPurpose) async throws -> String?
    func saveSecret(_ value: String, for id: UUID, purpose: ConnectionCredentialPurpose) async throws
    func deleteSecret(for id: UUID, purpose: ConnectionCredentialPurpose) async throws
}

extension ConnectionCredentialStore {
    func secret(for id: UUID, purpose: ConnectionCredentialPurpose) async throws -> String? {
        purpose == .databasePassword ? try await password(for: id) : nil
    }
    func saveSecret(_ value: String, for id: UUID, purpose: ConnectionCredentialPurpose) async throws {
        guard purpose == .databasePassword else { throw ConnectionLibraryError.credentialWrite }
        try await savePassword(value, for: id)
    }
    func deleteSecret(for id: UUID, purpose: ConnectionCredentialPurpose) async throws {
        if purpose == .databasePassword { try await deletePassword(for: id) }
    }
}

enum ConnectionLibraryError: LocalizedError {
    case load, save, credentialRead, credentialWrite, credentialDelete

    var errorDescription: String? {
        switch self {
        case .load: "Saved connections could not be read. The existing file has been left unchanged."
        case .save: "Saved connections could not be saved."
        case .credentialRead: "The connection password could not be read from macOS Keychain."
        case .credentialWrite: "The connection password could not be saved in macOS Keychain."
        case .credentialDelete: "The connection password could not be removed from macOS Keychain."
        }
    }
}

actor MemoryConnectionLibraryStore: ConnectionLibraryStore {
    private var library: SavedConnectionLibrary

    init(library: SavedConnectionLibrary = SavedConnectionLibrary()) { self.library = library }
    func load() -> SavedConnectionLibrary { library }
    func save(_ library: SavedConnectionLibrary) { self.library = library }
}

actor MemoryConnectionCredentialStore: ConnectionCredentialStore {
    private var passwords: [UUID: String] = [:]
    private var sshSecrets: [String: String] = [:]

    func password(for id: UUID) -> String? { passwords[id] }
    func savePassword(_ password: String, for id: UUID) { passwords[id] = password }
    func deletePassword(for id: UUID) { passwords[id] = nil }
    func secret(for id: UUID, purpose: ConnectionCredentialPurpose) async -> String? {
        purpose == .databasePassword ? passwords[id] : sshSecrets[id.uuidString + purpose.rawValue]
    }
    func saveSecret(_ value: String, for id: UUID, purpose: ConnectionCredentialPurpose) async {
        if purpose == .databasePassword { passwords[id] = value }
        else { sshSecrets[id.uuidString + purpose.rawValue] = value }
    }
    func deleteSecret(for id: UUID, purpose: ConnectionCredentialPurpose) async {
        if purpose == .databasePassword { passwords[id] = nil }
        else { sshSecrets[id.uuidString + purpose.rawValue] = nil }
    }
}

/// File and Keychain actors keep blocking system calls away from the UI actor.
actor FileConnectionLibraryStore: ConnectionLibraryStore {
    let fileURL: URL

    init(fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("DBeer/connections.json")) {
        self.fileURL = fileURL
    }

    func load() throws -> SavedConnectionLibrary {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return SavedConnectionLibrary()
        } catch { throw ConnectionLibraryError.load }
        do {
            let library = try decode(data)
            if library.version < SavedConnectionLibrary.currentVersion {
                try backupLegacyFile(version: library.version)
                let migrated = SavedConnectionLibrary(connections: library.connections,
                    selectedConnectionId: library.selectedConnectionId)
                try write(migrated)
                return migrated
            }
            return library
        } catch { throw ConnectionLibraryError.load }
    }

    func save(_ library: SavedConnectionLibrary) throws {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let existing = try decode(Data(contentsOf: fileURL))
                if existing.version < SavedConnectionLibrary.currentVersion { try backupLegacyFile(version: existing.version) }
            }
            try validate(library)
            try write(SavedConnectionLibrary(connections: library.connections,
                selectedConnectionId: library.selectedConnectionId))
        } catch { throw ConnectionLibraryError.save }
    }

    private func decode(_ data: Data) throws -> SavedConnectionLibrary {
        let library = try JSONDecoder().decode(SavedConnectionLibrary.self, from: data)
        try validate(library)
        return library
    }

    private func validate(_ library: SavedConnectionLibrary) throws {
        guard Set(library.connections.map(\.id)).count == library.connections.count,
              library.connections.allSatisfy({
                  !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 128 &&
                      $0.settings(password: "").hasValidNativeFields
              }) else { throw ConnectionLibraryError.load }
    }

    /// Preserve the exact old bytes before the first atomic v2 replacement.
    /// An existing backup is never overwritten by another migration attempt.
    private func backupLegacyFile(version: Int) throws {
        var backup = fileURL.appendingPathExtension("v\(version).backup")
        if FileManager.default.fileExists(atPath: backup.path) {
            backup = fileURL.appendingPathExtension("v\(version)-\(UUID().uuidString).backup")
        }
        try FileManager.default.copyItem(at: fileURL, to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }

    private func write(_ library: SavedConnectionLibrary) throws {
        let folder = fileURL.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".connections-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(library)
            guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                attributes: [.posixPermissions: 0o600]),
                rename(temporary.path, fileURL.path) == 0 else { throw ConnectionLibraryError.save }
        } catch { throw ConnectionLibraryError.save }
    }
}
