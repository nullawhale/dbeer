import Foundation

/// Local configuration only. Tokens are resolved by the helper and never
/// returned to the app, written to Keychain or included in profile transfer.
struct PasswordCommand: Codable, Equatable, Sendable {
    var executable: String
    var arguments: [String]

    var isValid: Bool {
        executable.hasPrefix("/") && executable.utf8.count <= 4_096 && !executable.contains("\0") &&
        arguments.count <= 128 && arguments.allSatisfy { !$0.contains("\0") } &&
        executable.utf8.count + arguments.reduce(0) { $0 + $1.utf8.count } <= 65_536
    }
}
