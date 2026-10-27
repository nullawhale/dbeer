import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Synthetic native dialogs complement the real database/stdio acceptance.
/// Every visible window belongs to this test host; no saved profiles are read.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DBEER_R04_UI_QA"] == "1"))
@MainActor
struct AgentAccessWindowTests {
    private func profiles(longNames: Bool = false) -> [SavedConnection] {
        (0..<(longNames ? 6 : 2)).map { index in
            let engine: DatabaseEngine = index.isMultiple(of: 2) ? .postgresql : .mysql
            let name = longNames ? "Duplicate profile " + String(repeating: "long connection name ", count: 5) : "UI fixture"
            return SavedConnection(name: name, settings: ConnectionSettings(host: "server-\(index).example.invalid",
                port: engine.defaultPort, database: longNames ? String(repeating: "database_", count: 9) : "fixture",
                user: "fixture_user_\(index)", password: "", sslMode: "disable", engine: engine,
                policy: ExecutionPolicy(environment: index.isMultiple(of: 2) ? .production : .staging, readOnly: index == 1)))
        }
    }

    private func coordinator(_ profiles: [SavedConnection]) -> AgentAccessCoordinator {
        AgentAccessCoordinator(profiles: { profiles }, settings: { $0.settings(password: "") },
            backendFactory: { throw CocoaError(.featureUnsupported) },
            approve: { name, profiles in await AgentAccessApproval.present(clientName: name, profiles: profiles) })
    }

    private func host(_ coordinator: AgentAccessCoordinator, dark: Bool) async throws -> NSWindow {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 85, y: 85, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DBeer agent access window verification"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: AgentAccessSettingsView(coordinator: coordinator, brokerError: nil,
            revoke: { id in await coordinator.revoke(clientID: id) }).preferredColorScheme(dark ? .dark : .light))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        try await settle(window)
        return window
    }

    private func views(_ window: NSWindow) -> [NSView] {
        var result: [NSView] = []
        func visit(_ view: NSView) { result.append(view); view.subviews.forEach(visit) }
        if let content = window.contentView { visit(content) }
        return result
    }

    private func control<T: NSView>(_ identifier: String, in window: NSWindow, as type: T.Type) throws -> T {
        try #require(views(window).first { $0.accessibilityIdentifier() == identifier } as? T,
            "Missing native agent control: \(identifier)")
    }

    private func waitFor(_ message: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<240 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition(), Comment(rawValue: message))
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(160))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }

    private func sheet(_ window: NSWindow) async throws -> NSWindow {
        try await waitFor("The owned agent sheet did not appear.") { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        try await settle(sheet)
        return sheet
    }

    private func close(_ window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        window.close()
    }

    private func press(_ identifier: String, in window: NSWindow) async throws {
        let button = try control(identifier, in: window, as: NSButton.self)
        try #require(button.isEnabled)
        button.scrollToVisible(button.bounds)
        button.performClick(nil)
        try await settle(window)
    }

    private func key(_ characters: String, code: UInt16, in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        window.makeKey()
        NSApp.postEvent(event, atStart: false)
    }

    private func capture(_ window: NSWindow, name: String) async throws {
        try await settle(window)
        guard let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"],
              let content = window.contentView else { return }
        let view = content.superview ?? content
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("agent-window-" + name + ".png"))
    }

    private func confirmation(_ profile: SavedConnection) -> OperationConfirmation {
        let sql = "DELETE FROM agent_ui_fixture"
        let operations = [OperationRequest(type: "execute", sql: sql)]
        let assessment = OperationAssessment(decision: "confirm", policy: profile.policy,
            operations: [AssessedOperation(kind: "destructive", statements: [StatementAssessment(start: 0, end: sql.utf8.count,
                kind: "destructive", reason: "Synthetic native UI fixture")])], authorization: UUID().uuidString)
        return OperationConfirmation(profile: profile, operations: operations, assessment: assessment, isScript: false)
    }

    @Test func longDuplicateProfilesRemainDistinctAndReadonlyDefaultsInBothAppearances() async throws {
        for dark in [false, true] {
            let profiles = profiles(longNames: true)
            let window = try await host(coordinator(profiles), dark: dark)
            defer { close(window) }
            var finished = false
            var selected: [UUID: Bool]?
            let task = Task { @MainActor in
                selected = await AgentAccessApproval.present(clientName: "Window verification client", profiles: profiles)
                finished = true
            }
            defer { task.cancel() }
            let sheet = try await sheet(window)
            let scroll = try #require(views(sheet).compactMap { $0 as? NSScrollView }.first)
            let document = try #require(scroll.documentView)
            let first = try control("agentProfile-\(profiles[0].id)", in: sheet, as: NSButton.self)
            let firstRectangle = first.convert(first.bounds, to: document)
            #expect(firstRectangle.intersects(scroll.contentView.bounds), "The first profile must be visible when a long grant list opens.")
            #expect(firstRectangle.minX >= 11, "Profile controls need inset space beside the native scroll viewport.")
            for profile in profiles {
                let select = try control("agentProfile-\(profile.id)", in: sheet, as: NSButton.self)
                let write = try control("agentWrite-\(profile.id)", in: sheet, as: NSButton.self)
                let details = try control("agentProfileDetails-\(profile.id)", in: sheet, as: NSTextField.self)
                #expect(select.state == .off && write.state == .off)
                #expect(write.isEnabled == !profile.policy.readOnly)
                #expect(details.stringValue.contains(profile.host) && details.stringValue.contains(profile.user) && details.stringValue.contains(profile.id.uuidString))
                let selectRectangle = select.convert(select.bounds, to: document)
                let writeRectangle = write.convert(write.bounds, to: document)
                #expect(selectRectangle.maxX <= document.bounds.width + 1 && writeRectangle.maxX <= document.bounds.width + 1,
                    "Long profile checkboxes must fit inside the grant viewport.")
            }
            try await capture(sheet, name: "long-grant-\(dark ? "dark" : "light")")
            try await press("agentProfile-\(profiles[0].id)", in: sheet)
            try await press("agentApprove", in: sheet)
            try await waitFor("Explicit native grant did not complete.") { finished && window.attachedSheet == nil }
            await task.value
            #expect(selected?.count == 1 && selected?[profiles[0].id] == false)
        }
    }

    @Test func selectAllUpdatesProfileSelectionWithoutChangingWritePermissionInBothAppearances() async throws {
        for dark in [false, true] {
            let profiles = profiles(longNames: true)
            let window = try await host(coordinator(profiles), dark: dark)
            defer { close(window) }
            var finished = false
            var selected: [UUID: Bool]?
            let task = Task { @MainActor in
                selected = await AgentAccessApproval.present(clientName: "Bulk selection verification client", profiles: profiles)
                finished = true
            }
            defer { task.cancel() }
            let sheet = try await sheet(window)
            let all = try control("agentSelectAll", in: sheet, as: NSButton.self)
            let selections = try profiles.map { try control("agentProfile-\($0.id)", in: sheet, as: NSButton.self) }
            let writes = try profiles.map { try control("agentWrite-\($0.id)", in: sheet, as: NSButton.self) }
            #expect(all.state == .off && selections.allSatisfy { $0.state == .off })
            #expect(writes.allSatisfy { $0.state == .off })
            #expect(!writes[1].isEnabled)

            try await press("agentSelectAll", in: sheet)
            #expect(all.state == .on && selections.allSatisfy { $0.state == .on })
            #expect(writes.allSatisfy { $0.state == .off }, "Bulk profile approval must not grant write permission.")

            try await press("agentProfile-\(profiles[0].id)", in: sheet)
            #expect(all.state == .mixed && selections[0].state == .off)
            try await press("agentSelectAll", in: sheet)
            #expect(all.state == .on && selections.allSatisfy { $0.state == .on })
            #expect(writes.allSatisfy { $0.state == .off })

            // Existing explicit write choices belong to their individual controls.
            // Selecting/deselecting profiles must neither add nor remove them.
            try await press("agentWrite-\(profiles[0].id)", in: sheet)
            #expect(writes[0].state == .on)
            try await press("agentSelectAll", in: sheet)
            #expect(all.state == .off && selections.allSatisfy { $0.state == .off })
            #expect(writes[0].state == .on && writes.dropFirst().allSatisfy { $0.state == .off })
            try await press("agentSelectAll", in: sheet)
            #expect(all.state == .on && selections.allSatisfy { $0.state == .on })
            #expect(writes[0].state == .on && writes.dropFirst().allSatisfy { $0.state == .off })
            #expect(!writes[1].isEnabled)
            try await press("agentWrite-\(profiles[0].id)", in: sheet)
            #expect(writes.allSatisfy { $0.state == .off })
            try await capture(sheet, name: "select-all-\(dark ? "dark" : "light")")

            try await press("agentApprove", in: sheet)
            try await waitFor("Bulk profile grant did not complete.") { finished && window.attachedSheet == nil }
            await task.value
            #expect(selected?.count == profiles.count && selected?.values.allSatisfy { !$0 } == true)
        }
    }

    @Test func returnAndEscapeDenySelectedProfilesAndDangerousOperations() async throws {
        for dark in [false, true] {
            let profiles = profiles()
            let window = try await host(coordinator(profiles), dark: dark)
            defer { close(window) }
            for (characters, code) in [("\r", UInt16(36)), ("\u{1b}", UInt16(53))] {
                var grantFinished = false
                var grant: [UUID: Bool]?
                let grantTask = Task { @MainActor in
                    grant = await AgentAccessApproval.present(clientName: "Keyboard verification client", profiles: profiles)
                    grantFinished = true
                }
                defer { grantTask.cancel() }
                let grantSheet = try await sheet(window)
                try await press("agentProfile-\(profiles[0].id)", in: grantSheet)
                try key(characters, code: code, in: grantSheet)
                try await waitFor("Return/Escape did not deny agent access.") { grantFinished && window.attachedSheet == nil }
                await grantTask.value
                #expect(grant == nil)

                var confirmationFinished = false
                var accepted = true
                let confirmation = confirmation(profiles[0])
                let confirmTask = Task { @MainActor in accepted = await AgentAccessApproval.confirm(confirmation); confirmationFinished = true }
                defer { confirmTask.cancel() }
                let confirmSheet = try await sheet(window)
                if code == 36 { try await capture(confirmSheet, name: "dangerous-preview-\(dark ? "dark" : "light")") }
                try key(characters, code: code, in: confirmSheet)
                try await waitFor("Return/Escape did not cancel the dangerous operation.") { confirmationFinished && window.attachedSheet == nil }
                await confirmTask.value
                #expect(!accepted)
            }
        }
    }

    @Test func existingSheetsRejectConcurrentRequestsAndTaskCancellationDismissesOwnedDialogs() async throws {
        let profiles = profiles()
        let window = try await host(coordinator(profiles), dark: false)
        defer { close(window) }
        var grantFinished = false
        var grant: [UUID: Bool]?
        let grantTask = Task { @MainActor in
            grant = await AgentAccessApproval.present(clientName: "First window client", profiles: profiles)
            grantFinished = true
        }
        defer { grantTask.cancel() }
        let grantSheet = try await sheet(window)
        let secondGrant = await AgentAccessApproval.present(clientName: "Second window client", profiles: profiles)
        let secondConfirmation = await AgentAccessApproval.confirm(confirmation(profiles[0]))
        #expect(secondGrant == nil && !secondConfirmation)
        #expect(window.attachedSheet === grantSheet && grantSheet.attachedSheet == nil)
        grantTask.cancel()
        try await waitFor("Cancelled approval did not dismiss its sheet.") { grantFinished && window.attachedSheet == nil }
        await grantTask.value
        #expect(grant == nil)

        var confirmFinished = false
        var accepted = true
        let fixture = confirmation(profiles[0])
        let confirmTask = Task { @MainActor in accepted = await AgentAccessApproval.confirm(fixture); confirmFinished = true }
        defer { confirmTask.cancel() }
        let confirmSheet = try await sheet(window)
        let nestedGrant = await AgentAccessApproval.present(clientName: "Blocked window client", profiles: profiles)
        let nestedConfirmation = await AgentAccessApproval.confirm(fixture)
        #expect(nestedGrant == nil && !nestedConfirmation)
        #expect(window.attachedSheet === confirmSheet && confirmSheet.attachedSheet == nil)
        confirmTask.cancel()
        try await waitFor("Cancelled dangerous operation did not dismiss its sheet.") { confirmFinished && window.attachedSheet == nil }
        await confirmTask.value
        #expect(!accepted)
    }
}
