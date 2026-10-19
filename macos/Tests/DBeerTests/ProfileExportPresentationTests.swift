import AppKit
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct ProfileExportPresentationTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test func exportAttachesToWorkspaceAndCanBeCancelledAndOpenedAgain() async throws {
        _ = NSApplication.shared
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "fixture",
            user: "fixture", password: "", sslMode: "disable")
        try #require(await workspace.library.saveConnection(name: "First", settings: settings))
        try #require(await workspace.library.saveConnection(name: "Second", settings: settings))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ApplicationWorkspaceView(workspace: workspace))
        window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
            window.close()
        }
        try await waitUntil { workspace.presentationWindow === window }

        workspace.exportProfiles()
        try await waitUntil { window.attachedSheet is NSSavePanel }
        let first = try #require(window.attachedSheet as? NSSavePanel)
        #expect(first.isVisible)
        #expect(first.nameFieldStringValue == "dbeer-connections.json")
        #expect(first.allowedContentTypes == [.json])
        workspace.exportProfiles()
        #expect(window.attachedSheet === first)
        first.cancel(nil)
        try await waitUntil { window.attachedSheet == nil }

        workspace.exportProfiles([workspace.library.savedConnections[0]])
        try await waitUntil { window.attachedSheet is NSSavePanel }
        let second = try #require(window.attachedSheet as? NSSavePanel)
        #expect(second !== first)
        #expect(second.isVisible)
        #expect(second.nameFieldStringValue == "dbeer-connection.json")
        second.cancel(nil)
        try await waitUntil { window.attachedSheet == nil }
        #expect(workspace.error == nil)
    }
}
