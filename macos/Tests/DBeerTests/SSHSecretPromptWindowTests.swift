import AppKit
import Foundation
import Testing
@testable import DBeer

/// Exercise the production secure prompt through AppKit's actual field editor.
/// Synthetic text never enters Keychain, a helper, a database or a log. These
/// owned-window tests distinguish field-editor commit from external event delivery.
@Suite(.serialized)
@MainActor
struct SSHSecretPromptWindowTests {
    @MainActor private final class Outcome {
        var result: Result<String, Error>?
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func wait(_ reason: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), Comment(rawValue: reason))
    }

    private func host() async throws -> NSWindow {
        let application = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 90, y: 90, width: 600, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "DBeer secure prompt verification"
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        do {
            try await wait("The owned parent window did not become key.") { application.keyWindow === window }
        } catch {
            window.close()
            throw error
        }
        return window
    }

    private func begin(profileID: String, outcome: Outcome) -> Task<Void, Never> {
        let configuration = SSHConfiguration(host: "fixture.invalid", user: "reader", authMethod: .privateKey,
            identityFile: "/synthetic/fixture-encrypted-key")
        return Task { @MainActor in
            do {
                outcome.result = .success(try await SSHConnectionReview.requestSecret(
                    passphrase: true, profileId: profileID, configuration: configuration))
            } catch {
                outcome.result = .failure(error)
            }
        }
    }

    private func prompt(in parent: NSWindow) async throws -> (sheet: NSWindow, field: NSSecureTextField) {
        try await wait("The production SSH secure prompt did not attach to the owned window.") {
            guard let content = parent.attachedSheet?.contentView else { return false }
            return descendants(content, of: NSSecureTextField.self).count == 1
        }
        let sheet = try #require(parent.attachedSheet)
        let content = try #require(sheet.contentView)
        try #require(descendants(content, of: NSTextField.self).contains {
            !($0 is NSSecureTextField) && $0.stringValue == "SSH Private Key Passphrase"
        }, "The owned sheet is not the SSH private-key prompt.")
        return (sheet, try #require(descendants(content, of: NSSecureTextField.self).first))
    }

    private func insert(_ sentinel: String, field: NSSecureTextField, sheet: NSWindow) throws {
        try #require(sheet.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView, "The secure field has no real field editor.")
        try #require(sheet.firstResponder === editor)
        editor.insertText(sentinel, replacementRange: editor.selectedRange())
        // Observe only the editor; reading/setting the control value before
        // Connect could hide a missing production commit of the field editor.
        let insertedExactBytes = editor.string.utf8.elementsEqual(sentinel.utf8)
        try #require(insertedExactBytes, "The native field editor did not accept the synthetic input.")
    }

    private func press(_ title: String, in sheet: NSWindow) throws {
        let content = try #require(sheet.contentView)
        let button = try #require(descendants(content, of: NSButton.self).first { $0.title == title })
        try #require(button.isEnabled)
        button.performClick(nil)
    }

    @Test
    func connectReturnsExactBytesInsertedThroughTheUncommittedSecureFieldEditor() async throws {
        let window = try await host()
        defer { window.close() }
        let profileID = UUID().uuidString
        let outcome = Outcome()
        let pending = begin(profileID: profileID, outcome: outcome)
        defer { SSHConnectionReview.cancel(profileId: profileID); pending.cancel() }
        let owned = try await prompt(in: window)
        let sentinel = "  synthetic key passphrase 🐋  "
        try insert(sentinel, field: owned.field, sheet: owned.sheet)
        try press("Connect", in: owned.sheet)
        try await wait("Connect did not complete the production secure prompt.") { outcome.result != nil }
        let returned = try #require(outcome.result).get()
        let returnedExactBytes = returned.utf8.elementsEqual(sentinel.utf8)
        #expect(returnedExactBytes, "Connect must preserve the current field-editor bytes, including whitespace and Unicode.")
        await pending.value
        try await wait("The completed Connect sheet did not detach.") { window.attachedSheet == nil }
    }

    @Test
    func cancelRejectsTheEnteredSecureFieldEditorValue() async throws {
        let window = try await host()
        defer { window.close() }
        let profileID = UUID().uuidString
        let outcome = Outcome()
        let pending = begin(profileID: profileID, outcome: outcome)
        defer { SSHConnectionReview.cancel(profileId: profileID); pending.cancel() }
        let owned = try await prompt(in: window)
        try insert("synthetic cancellation sentinel", field: owned.field, sheet: owned.sheet)
        try press("Cancel", in: owned.sheet)
        try await wait("Cancel did not complete the production secure prompt.") { outcome.result != nil }
        switch try #require(outcome.result) {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("Cancel returned a secure value instead of cancellation.")
        }
        await pending.value
        try await wait("The cancelled sheet did not detach.") { window.attachedSheet == nil }
    }
}
