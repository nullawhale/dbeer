import AppKit
import Foundation

/// Shares first-trust reviews between service and tab connections. The helper
/// binds every review token to an immutable profile and verifies the real key.
@MainActor
enum SSHConnectionReview {
    private struct Review {
        let id: UUID
        let configuration: SSHConfiguration
        let task: Task<Void, Error>
    }
    private struct SecretReview {
        let id: UUID
        let configuration: SSHConfiguration
        let task: Task<String, Error>
    }
    private static var secrets: [String: SecretReview] = [:]
    private static var pending: [String: Review] = [:]
    private static var alerts: [String: NSAlert] = [:]

    static func cancel(profileId: String) {
        pending[profileId]?.task.cancel()
        secrets[profileId]?.task.cancel()
        if let alert = alerts.removeValue(forKey: profileId) {
            if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .cancel) }
            else { NSApp.abortModal(); alert.window.orderOut(nil) }
        }
    }

    static func prepare(_ settings: ConnectionSettings, client: BackendClient) async throws {
        guard let ssh = settings.ssh else { return }
        if let review = pending[ssh.profileId], review.configuration == ssh.configuration {
            return try await review.task.value
        }
        if pending[ssh.profileId] != nil { cancel(profileId: ssh.profileId) }
        let reviewId = UUID()
        let task = Task { @MainActor in
            let reply = try await client.request(.sshProbe(settings))
            guard let key = reply.ssh, key.host == ssh.host, key.port == ssh.port else {
                throw BackendTransportError(.invalidMessage)
            }
            try Task.checkCancellation()
            if key.status == "unknown" || key.status == "changed" {
                guard let token = key.challengeToken else { throw BackendTransportError(.invalidMessage) }
                let alert = NSAlert()
                alert.messageText = key.status == "changed" ? "Replace the trusted SSH server key?" : "Trust this SSH server?"
                alert.informativeText = (key.status == "changed" ? "WARNING: The server key changed. This can indicate interception. Replace it only after independently verifying the change.\n\n" : "") + "\(key.host):\(key.port)\n\(key.algorithm)\n\(key.fingerprint)\n\nVerify this fingerprint with your server administrator before trusting it."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: key.status == "changed" ? "Replace Key and Connect" : "Trust and Connect")
                alerts[ssh.profileId] = alert
                defer { if alerts[ssh.profileId] === alert { alerts[ssh.profileId] = nil } }
                guard await present(alert) == .alertSecondButtonReturn else { throw CancellationError() }
                try Task.checkCancellation()
                let trusted = try await client.request(.sshTrust(settings, token: token, replace: key.status == "changed"))
                guard trusted.ssh?.status == "trusted" else { throw BackendTransportError(.invalidMessage) }
            }
        }
        pending[ssh.profileId] = Review(id: reviewId, configuration: ssh.configuration, task: task)
        defer { if pending[ssh.profileId]?.id == reviewId { pending[ssh.profileId] = nil } }
        try await task.value
    }

    static func requestSecret(passphrase: Bool, profileId: String, configuration: SSHConfiguration) async throws -> String {
        if let existing = secrets[profileId], existing.configuration == configuration {
            return try await existing.task.value
        }
        if secrets[profileId] != nil { cancel(profileId: profileId) }
        let id = UUID()
        let task = Task { @MainActor in try await promptSecret(passphrase: passphrase, profileId: profileId) }
        secrets[profileId] = SecretReview(id: id, configuration: configuration, task: task)
        defer { if secrets[profileId]?.id == id { secrets[profileId] = nil } }
        return try await task.value
    }

    private static func promptSecret(passphrase: Bool, profileId: String) async throws -> String {
        try Task.checkCancellation()
        let alert = NSAlert()
        alert.messageText = passphrase ? "SSH Private Key Passphrase" : "SSH Password"
        alert.informativeText = passphrase ? "Enter the key passphrase. Leave it empty for an unencrypted key." : "Enter the SSH user's password."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = passphrase ? "Passphrase" : "Password"
        alert.accessoryView = field
        alerts[profileId] = alert
        defer { if alerts[profileId] === alert { alerts[profileId] = nil } }
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        defer { field.stringValue = "" }
        guard await present(alert) == .alertFirstButtonReturn else { throw CancellationError() }
        try Task.checkCancellation()
        return field.stringValue
    }

    private static func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        }
        // A standalone editor may have no document window. AppKit's modal loop
        // continues servicing the helper reader and unrelated connections.
        return alert.runModal()
    }
}

enum SSHReviewError: LocalizedError {
    case changedKey
    var errorDescription: String? {
        "The SSH server key has changed. Connection was blocked. Verify the replacement key independently before updating DBeer's SSH trust record."
    }
}
