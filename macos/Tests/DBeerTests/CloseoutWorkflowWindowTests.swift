import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Real production controls in owned windows. All persistence, credentials and
/// clipboard state are isolated. These tests require explicit UI authorization.
@Suite(.serialized)
@MainActor
struct CloseoutWorkflowWindowTests {
    private struct Element {
        let object: NSObject
        func value<T>(_ name: String) -> T? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? T : nil
        }
        func flag(_ name: String) -> Bool {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return false }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        var id: String? { value("accessibilityIdentifier") }
        var label: String? { value("accessibilityLabel") }
        var button: NSButton? { (object as? NSButton) ?? ((object as? NSCell)?.controlView as? NSButton) }
        var field: NSTextField? { (object as? NSTextField) ?? ((object as? NSCell)?.controlView as? NSTextField) }
        func isEnabled() throws -> Bool {
            if let control = object as? NSControl { return control.isEnabled }
            let selector = NSSelectorFromString("isAccessibilityEnabled")
            try #require(object.responds(to: selector), "The control does not expose an enabled state.")
            return flag("isAccessibilityEnabled")
        }
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func elements(_ window: NSWindow) -> [Element] {
        var seen = Set<ObjectIdentifier>()
        var result: [Element] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            let element = Element(object: object)
            result.append(element)
            let children: [NSObject] = element.value("accessibilityChildren") ?? []
            children.forEach(visit)
            (object as? NSView)?.subviews.forEach(visit)
        }
        visit(window)
        if let content = window.contentView { visit(content) }
        if let sheet = window.attachedSheet { result += elements(sheet) }
        return result
    }

    private func element(_ id: String, _ window: NSWindow) throws -> Element {
        try #require(elements(window).first { $0.id == id }, "Missing closeout control: \(id)")
    }

    private func wait(_ reason: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), Comment(rawValue: reason))
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(120)) }

    private func press(_ element: Element) async throws {
        if let button = element.button {
            try #require(button.isEnabled)
            button.performClick(nil)
        } else if let toggle = element.object as? NSSwitch {
            try #require(toggle.isEnabled)
            toggle.state = toggle.state == .on ? .off : .on
            toggle.sendAction(toggle.action, to: toggle.target)
        } else {
            try #require(element.flag("accessibilityPerformPress"), "The native control did not accept Press.")
        }
        try await settle()
    }

    private func press(_ id: String, _ window: NSWindow) async throws { try await press(element(id, window)) }

    private func enter(_ text: String, _ id: String, _ window: NSWindow) async throws {
        let field = try #require(element(id, window).field, "Expected a native field: \(id)")
        try #require(window.makeFirstResponder(field))
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await settle()
    }

    private func choose(_ title: String, _ id: String, _ window: NSWindow) async throws {
        try await NativeThemeMenuActions.select(title, in: #require(element(id, window).button))
        try await settle()
    }

    private func host<V: View>(_ view: V, theme: String, width: Double = 900, height: Double = 760) async throws -> NSWindow {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: width, height: height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DBeer closeout verification"
        window.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view.preferredColorScheme(theme == "dark" ? .dark : .light))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        try await settle()
        NativeButtonFocusPolicy().apply(to: window)
        return window
    }

    private func capture(_ window: NSWindow, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        // Production AppDelegate applies this policy before window updates.
        // Standalone fixtures must use the same native focus ownership.
        NativeButtonFocusPolicy().apply(to: window)
        try await settle()
        let directory = URL(fileURLWithPath: path).appendingPathComponent("closeout")
        try await NativeOwnedWindowCapture.write(window, to: directory.appendingPathComponent(name + ".png"))
    }

    private func workspace(snapshot: SQLWorkspaceSnapshot = SQLWorkspaceSnapshot(),
                           profiles: [SavedConnection] = [], helperFactory: @escaping () -> BackendClient) throws -> ApplicationWorkspace {
        let artifactRoot = repository.appendingPathComponent("build/closeout/artifacts-" + UUID().uuidString)
        let artifacts = ResultSnapshotStore(rootURL: artifactRoot)
        let defaults = try #require(UserDefaults(suiteName: "dev.dbeer.tests.closeout-workspace." + UUID().uuidString))
        let themes = EditorThemeStore(defaults: defaults, directory: artifactRoot.appendingPathComponent("themes"))
        return ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library: SavedConnectionLibrary(connections: profiles)),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(snapshot: snapshot),
            commandShortcuts: AppShortcutStore(defaults: defaults), copySettings: ResultCopySettings(defaults: defaults),
            editorThemes: themes, appearance: AppAppearance(defaults: defaults, editorThemes: themes),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false),
            resultSnapshots: ResultSnapshotsModel(store: artifacts),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: artifacts, autosaveDelay: nil),
            automaticallyWatchFiles: false,
            closeDecision: { _ in .discard }, helperFactory: helperFactory)
    }

    @Test(arguments: ["light", "dark"])
    func historySearchFavoritesSettingsDeletionAndDisconnectedOpening(_ theme: String) async throws {
        let profile = SavedConnection(name: "Closeout staging", settings: ConnectionSettings(host: "fixture.invalid",
            port: 5432, database: "fixture", user: "reader", password: "", sslMode: "disable"))
        var first = SQLHistoryEntry(date: .now, profileID: profile.id, sql: "SELECT 'Café 🐋 target';", outcome: "Completed")
        first.outcome = .succeeded
        first.legacyOutcome = nil
        var second = SQLHistoryEntry(date: .now, profileID: profile.id, sql: "SELECT 'unrelated';", outcome: "Failed")
        second.outcome = .failed
        second.legacyOutcome = nil
        var starts = 0
        let workspace = try workspace(snapshot: SQLWorkspaceSnapshot(history: [second, first]), profiles: [profile]) {
            starts += 1
            return BackendClient(executableURL: URL(fileURLWithPath: "/unused-closeout-helper"))
        }
        await workspace.restoreSavedWorkspace()
        await workspace.library.loadConnections()
        defer { Task { await workspace.shutdown() } }
        let window = try await host(SQLHistoryView(workspace: workspace), theme: theme)
        defer { window.attachedSheet?.orderOut(nil); window.close() }
        let openID = "openHistory-" + first.id.uuidString
        try await wait("History did not show both stored executions.") {
            elements(window).contains { $0.id == openID } && elements(window).contains { $0.id == "openHistory-" + second.id.uuidString }
        }
        try await press("historyRecording", window)
        #expect(!workspace.historyEnabled)
        try await press("historyRecording", window)
        try await enter("CAFE 🐋", "historySQLSearch", window)
        try await wait("Unicode SQL search did not narrow the history.") {
            elements(window).contains { $0.id == openID } && !elements(window).contains { $0.id == "openHistory-" + second.id.uuidString }
        }
        try await choose("Failed", "historyOutcomeFilter", window)
        try await wait("Combined history filters were not applied.") { !elements(window).contains { $0.id == openID } }
        try await press("resetHistoryFilters", window)
        try await wait("Reset did not restore the history row.") { elements(window).contains { $0.id == openID } }
        try await press("historyFavorite-" + first.id.uuidString, window)
        try await wait("The star did not persist the favorite.") { workspace.history.first { $0.id == first.id }?.isFavorite == true }
        try await press("historyFavoritesFilter", window)
        try await wait("Favorites-only filter did not hide the ordinary entry.") {
            elements(window).contains { $0.id == openID } && !elements(window).contains { $0.id == "openHistory-" + second.id.uuidString }
        }
        try await capture(window, name: "history-" + theme)
        try await press(openID, window)
        let document = try #require(workspace.selectedDocument)
        #expect(document.text == first.sql && document.profileID == profile.id)
        #expect(document.runtime == nil && workspace.services.isEmpty && starts == 0)

        let settingsWindow = try await host(SQLHistorySettingsView(workspace: workspace), theme: theme, width: 560, height: 420)
        defer { settingsWindow.close() }
        try await enter("0", "historyMaxEntries", settingsWindow)
        #expect(try !element("applyHistorySettings", settingsWindow).isEnabled())
        try await enter("1", "historyMaxEntries", settingsWindow)
        try await enter("7", "historyRetentionDays", settingsWindow)
        try await press("applyHistorySettings", settingsWindow)
        try await wait("History settings were not applied from the native fields.") {
            workspace.historySettings == SQLHistoryRetentionSettings(maxEntries: 1, retentionDays: 7)
        }
        #expect(workspace.history.first { $0.id == first.id }?.isFavorite == true)
        settingsWindow.close()

        try await press("resetHistoryFilters", window)
        try await press("clearAllHistory", window)
        try await wait("Clear confirmation did not appear.") { elements(window).contains { $0.label == "Clear Ordinary" } }
        try await press(#require(elements(window).first { $0.label == "Clear Ordinary" }))
        try await wait("Clearing ordinary history did not preserve only the favorite.") { workspace.history.map(\.id) == [first.id] }
        #expect(starts == 0)
    }

    @Test(arguments: ["light", "dark"])
    func libraryAndFolderSearchOpenTheOriginalFileWithoutConnecting(_ theme: String) async throws {
        let root = repository.appendingPathComponent("build/closeout/files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("orders.sql")
        let sql = "-- café 🐋\nSELECT 'closeout_file_marker';\n"
        try Data(sql.utf8).write(to: file)
        let libraryEntry = SQLLibraryEntry(fileURL: file, folder: "Reports", tags: ["closeout"])
        let snapshot = SQLWorkspaceSnapshot(sqlFolders: [SQLFolderAttachment(url: root)],
            sqlLibrary: SQLLibrarySnapshot(entries: [libraryEntry]))
        var starts = 0
        let workspace = try workspace(snapshot: snapshot) {
            starts += 1
            return BackendClient(executableURL: URL(fileURLWithPath: "/unused-closeout-helper"))
        }
        await workspace.restoreSavedWorkspace()
        defer { Task { await workspace.shutdown() } }
        let window = try await host(SQLLibrarySidebarView(workspace: workspace), theme: theme, width: 410, height: 600)
        defer { window.close() }
        try await enter("closeout", "sqlLibrarySearch", window)
        try await press("openSQLLibrary-" + libraryEntry.id.uuidString, window)
        try await wait("Library file did not open.") { workspace.selectedDocument?.fileURL == file }
        #expect(workspace.selectedDocument?.text == sql && workspace.selectedDocument?.runtime == nil)
        try await capture(window, name: "library-" + theme)

        let editor = try await host(SQLLibraryEntryEditor(workspace: workspace, fileURL: file), theme: theme, width: 600, height: 480)
        defer { editor.close() }
        try await enter("Reports/Weekly", "sqlLibraryEntryFolder", editor)
        try await press("saveSQLLibraryEntry", editor)
        try await wait("Library details were not saved.") { workspace.sqlLibrary.entry(at: file)?.folder == "Reports/Weekly" }
        #expect(try String(contentsOf: file, encoding: .utf8) == sql)
        editor.close()

        let files = try await host(SQLFilesSidebarView(workspace: workspace), theme: theme, width: 410, height: 600)
        defer { files.close() }
        try await enter("closeout_file_marker", "sqlFolderSearch", files)
        try await wait("Native content search did not find the SQL file.") {
            workspace.sqlFolders.searchResults.contains { $0.url == file }
        }
        let match = try #require(workspace.sqlFolders.searchResults.first { $0.url == file })
        let rowID = "openSQLFolderMatch-\(match.attachmentID.uuidString)-\(match.relativePath)-\(match.lineNumber ?? 0)"
        try await wait("The SQL search result was not rendered.") { elements(files).contains { $0.id == rowID } }
        try await press(rowID, files)
        #expect(workspace.selectedDocument?.fileURL == file && workspace.selectedDocument?.text == sql)
        #expect(workspace.documents.count == 1 && workspace.services.isEmpty && starts == 0)
        try await capture(files, name: "files-" + theme)
    }

    @Test(arguments: ["light", "dark"])
    func copyPreferencesAndInspectorControlsPreserveExactOriginals(_ theme: String) async throws {
        let name = "dev.dbeer.tests.closeout-copy." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ResultCopySettings(defaults: defaults)
        let window = try await host(ResultCopySettingsView(settings: settings), theme: theme, width: 680, height: 400)
        defer { window.close() }
        try await choose("CSV", "resultCopyFormat", window)
        try await press("resultCopyHeaders", window)
        #expect(settings.options.format == .csv && settings.options.includesHeaders)
        #expect(ResultCopySettings(defaults: defaults).options == settings.options)
        try await capture(window, name: "copy-settings-" + theme)
        try await press("restoreCopyDefaults", window)
        #expect(settings.options == .default)
        window.close()

        let source = #"{"amount":9007199254740993.123456789,"name":"café 🐋","other":"CAFÉ"}"#
        let inspector = ValueInspectorModel()
        await inspector.select(InspectedValue(row: 0, column: 0, name: "payload", nativeType: "jsonb",
            value: ChangeValue(kind: "text", value: source)))?.value
        let preview = try await host(ValueInspectorView(model: inspector), theme: theme, width: 500, height: 600)
        defer { preview.close() }
        try await press("valueInspectorFormatJSON", preview)
        #expect(inspector.formatted && inspector.text.contains("9007199254740993.123456789"))
        try await enter("café", "valueInspectorSearch", preview)
        try await wait("Inspector search did not match both Unicode values.") { inspector.matches.count == 2 }
        try await press("valueInspectorWrap", preview)
        #expect(inspector.selection?.text == source)
        try await capture(preview, name: "inspector-" + theme)
    }

    @Test(arguments: ["light", "dark"])
    func externalFileComparisonRejectsStaleReviewAndReplacesOnlyReviewedBytes(_ theme: String) async throws {
        let root = repository.appendingPathComponent("build/closeout/conflict-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("review.sql")
        try Data("SELECT 'original';\n".utf8).write(to: url)
        var starts = 0
        let workspace = try workspace {
            starts += 1
            return BackendClient(executableURL: URL(fileURLWithPath: "/unused-closeout-helper"))
        }
        await workspace.restoreSavedWorkspace()
        await workspace.openSQLFile(at: url)
        defer { Task { await workspace.shutdown() } }
        let document = try #require(workspace.selectedDocument)
        let file = try #require(document.fileDocument)
        document.text = "SELECT 'local draft';\n"
        let external = "SELECT 'external draft';\n"
        try Data(external.utf8).write(to: url)
        let window = try await host(SQLFileStatusView(document: document, workspace: workspace, file: file),
            theme: theme, width: 960, height: 220)
        defer { window.attachedSheet?.orderOut(nil); window.close() }
        try await press("checkSQLFile", window)
        try await wait("External changes were not detected by the native action.") { file.conflict != nil }
        try await press("compareSQLFileVersions", window)
        try await wait("The file comparison did not open.") {
            elements(window).contains { $0.id == "replaceExternalSQLFileVersion" }
        }
        let newest = "SELECT 'newer local draft';\n"
        document.text = newest
        try await settle()
        #expect(try !element("replaceExternalSQLFileVersion", window).isEnabled())
        #expect(try String(contentsOf: url, encoding: .utf8) == external)
        let done = try #require(elements(window).first { $0.label == "Done" })
        try await press(done)
        try await press("compareSQLFileVersions", window)
        try await wait("The refreshed file comparison did not open.") {
            elements(window).contains { $0.id == "replaceExternalSQLFileVersion" }
        }
        try await capture(window.attachedSheet ?? window, name: "file-review-" + theme)
        try await press("replaceExternalSQLFileVersion", window)
        try await wait("Reviewed replacement did not complete.") { file.conflict == nil && !file.isSaving }
        #expect(try String(contentsOf: url, encoding: .utf8) == newest)
        #expect(file.acceptedSHA256 == SQLFileBinding.digestText(newest) && !file.isDirty)
        #expect(document.text == newest && workspace.services.isEmpty && starts == 0)
    }

    @Test(arguments: ["light", "dark"])
    func connectionEditorSavesOpenSSHAndLiteralPasswordCommandWithoutRunningEither(_ theme: String) async throws {
        let root = repository.appendingPathComponent("build/closeout/connection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("must-not-run")
        let config = root.appendingPathComponent("ssh_config")
        try Data("Host closeout-alias\n  HostName localhost\n  ProxyJump jump-one,jump-two\n".utf8).write(to: config)
        let model = WorkspaceModel(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore())
        let original = ConnectionSettings(host: "db.internal", port: 5432, database: "fixture", user: "reader",
            password: "", sslMode: "disable")
        try #require(await model.saveConnection(name: "Closeout connection", settings: original))
        let profile = try #require(model.savedConnections.first)
        var closed = false
        let window = try await host(ConnectionEditorView(model: model, connection: profile, onClose: { closed = true }),
            theme: theme, width: 980, height: 860)
        defer { window.close(); Task { await model.shutdown() } }
        try await choose("CLI command", "passwordSource", window)
        try await enter("/usr/bin/touch", "passwordExecutable", window)
        try await enter(String(decoding: JSONEncoder().encode([marker.path, "literal $(command)"]), as: UTF8.self),
            "passwordArguments", window)
        try await NativeConnectionEditorTabs.select("SSH", in: #require(window.contentView))
        try await press("sshEnabled", window)
        try await choose("OpenSSH Configuration", "sshAuthentication", window)
        try await enter("closeout-alias", "sshHost", window)
        try await enter(config.path, "sshConfigFile", window)
        try await capture(window, name: "openssh-editor-" + theme)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try await press("saveConnection", window)
        try await wait("Saving the connection editor did not finish.") { closed }
        let saved = try #require(model.savedConnections.first)
        #expect(saved.id == profile.id && saved.ssh?.authMethod == .openSSH)
        #expect(saved.ssh?.host == "closeout-alias" && saved.ssh?.configFile == config.path)
        #expect(saved.passwordCommand?.arguments == [marker.path, "literal $(command)"])
        #expect(!FileManager.default.fileExists(atPath: marker.path) && model.sessionId == nil)
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty),
          arguments: ["light", "dark"])
    func saveAndConnectUsesTheNativeCLIFieldsAndRealPostgres(_ theme: String) async throws {
        let address = try #require(URLComponents(string: ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? ""))
        let root = repository.appendingPathComponent("build/closeout/live-password-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let token = root.appendingPathComponent("token")
        try Data((address.password ?? "").utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        let trace = root.appendingPathComponent("calls")
        let provider = root.appendingPathComponent("provider.sh")
        try Data("#!/bin/sh\n/usr/bin/printf 'called\\n' >> \"$1\"\n/bin/cat \"$2\"\n".utf8).write(to: provider)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: provider.path)
        let workspace = try workspace {
            BackendClient(executableURL: repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core"))
        }
        await workspace.restoreSavedWorkspace()
        let connection = ConnectionSettings(host: try #require(address.host), port: address.port ?? 5432,
            database: String(address.path.dropFirst()), user: try #require(address.user), password: "", sslMode: "disable")
        try #require(await workspace.library.saveConnection(name: "Native dynamic password", settings: connection))
        let profile = try #require(workspace.library.savedConnections.first)
        var finished = false
        let window = try await host(ConnectionEditorView(model: workspace.library, connection: profile,
            onConnect: { id, ssh in
                await workspace.connectProfile(id, sshSnapshot: ssh)
                finished = true
            }, onClose: {}), theme: theme, width: 980, height: 860)
        defer { window.close() }
        do {
            try await choose("CLI command", "passwordSource", window)
            try await enter(provider.path, "passwordExecutable", window)
            try await enter(String(decoding: JSONEncoder().encode([trace.path, token.path]), as: UTF8.self),
                "passwordArguments", window)
            #expect(!FileManager.default.fileExists(atPath: trace.path) && workspace.services.isEmpty)
            try await press("saveAndConnect", window)
            try await wait("The native Save and Connect action did not complete.") { finished }
            try #require(workspace.services[profile.id]?.connectionState == .connected)
            #expect(FileManager.default.fileExists(atPath: trace.path))
            let saved = try #require(workspace.library.savedConnections.first)
            #expect(saved.passwordCommand?.executable == provider.path && saved.id == profile.id)
            try await capture(window, name: "dynamic-password-live-" + theme)
            await workspace.shutdown()
        } catch {
            await workspace.shutdown()
            throw error
        }
    }
}
