import AppKit
import SwiftUI
import Testing
@testable import DBeer

/// Mount the actual application screens: a synthetic button/field fixture alone
/// cannot catch native controls introduced by Forms, Lists or sheets.
@Suite(.serialized)
@MainActor
struct ApplicationFocusAuditTests {
    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: folder.appendingPathComponent("focus-audit-\(name).png"))
    }

    private func focus(_ control: NSControl, in window: NSWindow) async throws {
        let application = NSApplication.shared
        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(control))
        // SwiftUI screen updates can change the key window after the initial
        // presentation. Verify active-window feedback with this window active.
        for _ in 0..<20 where !window.isKeyWindow {
            try await Task.sleep(for: .milliseconds(25))
            application.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        try #require(window.isKeyWindow)
    }

    @Test func actualScreensReplaceNativeRingsAndRetainVisibleKeyboardFocusInBothThemes() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "fixture",
            user: "fixture", password: "", sslMode: "disable")
        try #require(await workspace.library.saveConnection(name: "Local", settings: settings))
        let document = workspace.newDocument(profileID: workspace.library.selectedConnectionId)
        let importing = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        importing.importPreview = try ProfileTransfer.preview(ProfileTransfer.encode(workspace.library.savedConnections))
        let defaultsName = "dev.dbeer.tests.focus-audit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let appearance = AppAppearance(defaults: defaults)
        let screens: [(String, AnyView)] = [
            ("workspace", AnyView(ApplicationWorkspaceView(workspace: workspace))),
            ("legacy-workspace", AnyView(WorkspaceView(model: workspace.library))),
            ("connection", AnyView(ConnectionEditorView(model: workspace.library, connection: nil) {})),
            ("filters", AnyView(TableBrowseControls(document: document, workspace: workspace))),
            ("import", AnyView(ProfileImportView(workspace: importing))),
            ("history", AnyView(SQLHistoryView(workspace: workspace))),
            ("inspection", AnyView(CatalogInspectionView(inspection:
                CatalogInspection(title: "customers", definition: "CREATE TABLE customers (id integer);", isLoading: false)) {})),
            ("settings", AnyView(AppearanceSettingsView(appearance: appearance))),
        ]
        let policy = NativeButtonFocusPolicy()
        for (theme, scheme, nativeAppearance) in [
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
            ("light", .light, .aqua),
        ] {
            for (name, screen) in screens {
                let host = NSHostingView(rootView: screen.preferredColorScheme(scheme))
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1120, height: 760),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: nativeAppearance)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                application.activate(ignoringOtherApps: true)
                defer { window.close() }
                for _ in 0..<20 where !window.isKeyWindow {
                    try await Task.sleep(for: .milliseconds(25))
                    window.makeKey()
                }
                try #require(window.isKeyWindow)
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                policy.apply(to: window)
                if ["workspace", "connection", "filters"].contains(name) {
                    // Grouped Forms materialize their native fields lazily.
                    for _ in 0..<80 {
                        let ready = descendants(host, of: NSTextField.self).contains {
                            $0.isEditable && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
                        }
                        if ready { break }
                        try await Task.sleep(for: .milliseconds(25))
                        host.layoutSubtreeIfNeeded()
                        policy.apply(to: window)
                    }
                }
                let fields = descendants(host, of: NSTextField.self).filter {
                    $0.isEditable && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
                }
                if ["workspace", "connection", "filters"].contains(name) {
                    #expect(!fields.isEmpty, "Missing real fields in \(name)/\(theme)")
                }
                for field in fields {
                    try await focus(field, in: window)
                    policy.apply(to: window)
                    #expect(field.focusRingType == .none)
                    #expect(field.cell?.focusRingType == NSFocusRingType.none)
                    #expect(field.currentEditor() === window.firstResponder)
                    let outline = try #require(field.subviews.compactMap { $0 as? NativeFieldFocusView }.first)
                    let textRect = try #require(field.cell).drawingRect(forBounds: field.bounds)
                    let border = outline.frame.insetBy(dx: ControlHoverAppearance.inset, dy: ControlHoverAppearance.inset)
                    // Verify the real native text area, including Form, secure,
                    // search and rounded filter fields in both appearances.
                    let gaps = [textRect.minX - border.minX, border.maxX - textRect.maxX,
                        textRect.minY - border.minY, border.maxY - textRect.maxY]
                    #expect(gaps.allSatisfy { $0 >= 3 }, "Tight text border in \(name)/\(theme): \(gaps)")
                    #expect(field.subviews.compactMap { $0 as? NativeFieldFocusView }.first?.isFocused == true,
                        "\(name)/\(theme) field \(field.accessibilityIdentifier() ?? field.placeholderString ?? field.stringValue), key=\(window.isKeyWindow), responder=\(String(describing: window.firstResponder))")
                }
                if !fields.isEmpty { try capture(host, name: "\(name)-\(theme)-field") }
                let buttons = descendants(host, of: NSButton.self).filter {
                    $0.isEnabled && $0.acceptsFirstResponder && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
                }
                for button in buttons {
                    try await focus(button, in: window)
                    policy.apply(to: window)
                    #expect(button.focusRingType == .none)
                    #expect(button.cell?.focusRingType == NSFocusRingType.none)
                    let rowIndicator = CatalogRowHoverAnchor.feedback(containing: button)
                    let indicators = descendants(host, of: ControlFeedbackView.self).filter {
                        $0.nativeControl === button || $0 === rowIndicator
                    }
                    #expect(indicators.count == 1, "A focused button in \(name) needs one amber indicator")
                    #expect(indicators.first?.isNativeKeyboardFocused == true,
                        "\(name)/\(theme) button \(button.accessibilityIdentifier() ?? button.title) \(type(of: button)), key=\(window.isKeyWindow), responder=\(String(describing: window.firstResponder))")
                    #expect(descendants(host, of: NativeFieldFocusView.self).allSatisfy { !$0.isFocused })
                }
                for container in descendants(host, of: NSView.self)
                    where container is NSScrollView || container is NSTextView || container is NSTableView {
                    #expect(container.focusRingType == .none)
                }
                try capture(host, name: "\(name)-\(theme)-button")
                window.close()
            }
        }
        await importing.shutdown()
        await workspace.shutdown()
    }
}
