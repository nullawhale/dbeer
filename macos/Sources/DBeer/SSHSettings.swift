import Foundation

/// Only this nonsecret description may be persisted. Runtime credentials and
/// profile ownership are attached immediately before an explicit connection.
struct SSHConfiguration: Codable, Equatable, Sendable {
    enum Authentication: String, Codable, CaseIterable, Identifiable, Sendable {
        case agent, privateKey, password
        var id: String { rawValue }
        var label: String { switch self { case .agent: "SSH Agent"; case .privateKey: "Private Key"; case .password: "Password" } }
    }
    var host: String
    var port: Int = 22
    var user: String
    var authMethod: Authentication = .agent
    var identityFile: String?

    var isValid: Bool {
        !host.isEmpty && host.utf8.count <= 253 && !user.isEmpty && user.utf8.count <= 255 &&
            (1...65535).contains(port) &&
            [host, user].allSatisfy { !$0.hasPrefix("-") && !$0.contains(where: { $0.isWhitespace || $0.isNewline || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) } &&
            (CassandraSettings.isNumericAddress(host) || host.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }) &&
            !user.contains(where: { "@/\\".contains($0) }) &&
            (authMethod != .privateKey || identityFile.map { $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 } == true) &&
            (authMethod == .privateKey || identityFile == nil)
    }

    func runtime(profileId: UUID, password: String? = nil, passphrase: String? = nil) -> SSHSettings {
        SSHSettings(profileId: profileId.uuidString, host: host, port: port, user: user,
            authMethod: authMethod, identityFile: identityFile, password: password, passphrase: passphrase)
    }
}

struct SSHSettings: Codable, Equatable, Sendable {
    var profileId: String
    var host: String
    var port: Int
    var user: String
    var authMethod: SSHConfiguration.Authentication
    var identityFile: String?
    var password: String?
    var passphrase: String?
    var configuration: SSHConfiguration {
        SSHConfiguration(host: host, port: port, user: user, authMethod: authMethod, identityFile: identityFile)
    }
    var isValid: Bool {
        UUID(uuidString: profileId) != nil && configuration.isValid &&
            [password, passphrase].allSatisfy { $0.map { !$0.contains("\0") && $0.utf8.count <= 16384 } ?? true } &&
            (authMethod == .password || password == nil) && (authMethod == .privateKey || passphrase == nil)
    }
}

struct SSHTrust: Codable, Equatable, Sendable { var token: String; var replace: Bool? }
struct SSHHostKey: Codable, Equatable, Sendable {
    var status: String
    var challengeToken: String?
    var host: String
    var port: Int
    var algorithm: String
    var fingerprint: String
    var isValid: Bool {
        ["trusted", "unknown", "changed"].contains(status) && !host.isEmpty && host.utf8.count <= 1024 &&
            (1...65535).contains(port) && !algorithm.isEmpty && algorithm.utf8.count <= 128 &&
            fingerprint.hasPrefix("SHA256:") && fingerprint.utf8.count <= 128 &&
            (status == "trusted" || challengeToken.map { BackendMessage.validID($0) } == true)
    }
}

enum ConnectionCredentialPurpose: String, CaseIterable, Sendable {
    case databasePassword, sshPassword, sshPassphrase
}
