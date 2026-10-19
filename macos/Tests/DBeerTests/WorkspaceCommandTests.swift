import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct WorkspaceCommandTests {
    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func store(descriptors: [AppCommandDescriptor] = AppCommandDescriptor.builtins) throws -> (AppShortcutStore, UserDefaults, String) {
        let name = "dev.dbeer.tests.commands.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (AppShortcutStore(defaults: defaults, descriptors: descriptors), defaults, name)
    }

    private func setup(shortcuts: AppShortcutStore? = nil) async throws -> (ApplicationWorkspace, SQLDocument) {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), commandShortcuts: shortcuts)
        try #require(await workspace.library.saveConnection(name: "Fixture", settings: ConnectionSettings(
            host: "localhost", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable")))
        let document = workspace.newDocument(text: "SELECT 'first';\nSELECT '😀 second';\nSELECT 'third';")
        document.selection = (document.text as NSString).range(of: "SELECT '😀 second'")
        return (workspace, document)
    }

    private func context(_ document: SQLDocument, focus: AppCommandFocus = .sqlEditor) -> AppCommandContext {
        AppCommandContext(documentID: document.id, focus: focus, isWorkspaceWindow: true, hasModal: false)
    }

    private func key(_ window: NSWindow, keyCode: UInt16 = 36, characters: String = "\r",
                     modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private func dispatch(_ event: NSEvent, in window: NSWindow) {
        // A standalone NSHostingView has no Scene command menu. Exercise the
        // native window's keyDown route; editor key equivalents are tested
        // separately above, and the menu uses the same registry entry point.
        window.sendEvent(event)
    }

    private func press(_ identifier: String, in root: NSObject) throws {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
            if object.responds(to: identifierSelector),
               object.perform(identifierSelector)?.takeUnretainedValue() as? String == identifier { return object }
            let childrenSelector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: childrenSelector),
               let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [NSObject] {
                for child in children { if let found = find(child) { return found } }
            }
            if let view = object as? NSView {
                for child in view.subviews { if let found = find(child) { return found } }
            }
            return nil
        }
        let element = try #require(find(root))
        if let button = (element as? NSButton) ?? ((element as? NSCell)?.controlView as? NSButton) {
            try #require(button.isEnabled)
            button.performClick(nil)
        } else {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            try #require(element.responds(to: selector))
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            try #require(unsafeBitCast(element.method(for: selector), to: Action.self)(element, selector))
        }
    }

    private func host<Content: View>(_ root: Content, width: CGFloat = 1120, height: CGFloat = 760,
                                    appearance: NSAppearance.Name? = nil) async throws -> (NSWindow, NSHostingView<Content>) {
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let appearance {
            window.appearance = NSAppearance(named: appearance)
            host.appearance = NSAppearance(named: appearance)
        }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        for _ in 0..<20 where !window.isKeyWindow {
            try await Task.sleep(for: .milliseconds(20))
            window.makeKeyAndOrderFront(nil)
        }
        try #require(window.isKeyWindow)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }

    @Test func fragmentResolverUsesTheExactUTF16SelectionAndWholeScriptRanges() {
        let text = "-- header\nSELECT '😀';\n  SELECT 2;\nSELECT 3;"
        let selected = (text as NSString).range(of: "  SELECT 2;")
        let fragment = SQLExecutionFragment.resolve(text: text, selection: selected, engine: .postgresql)
        #expect(fragment?.kind == .selection)
        #expect(fragment?.sourceSQL == "SELECT 2;")
        #expect(fragment?.statements.map(\.sql) == ["SELECT 2"])
        #expect(fragment?.firstLine == 3 && fragment?.lastLine == 3)
        #expect(fragment?.statements.first?.range == (text as NSString).range(of: "SELECT 2"))
        let current = SQLExecutionFragment.resolve(text: text, selection: NSRange(location: selected.location + 4, length: 0), engine: .postgresql)
        #expect(current?.kind == .statement && current?.sourceSQL == "SELECT 2")
        let script = SQLExecutionFragment.resolve(text: text, selection: selected, engine: .postgresql, script: true)
        #expect(script?.kind == .script && script?.sourceSQL == text)
        #expect(script?.statements.count == 3 && script?.range.length == text.utf16.count)
        #expect(script?.firstLine == 1 && script?.lastLine == 4)
    }

    @Test func dispatcherCapturesTheDocumentAndSelectionBeforeItsTaskStarts() async throws {
        let (shortcuts, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let (workspace, first) = try await setup(shortcuts: shortcuts)
        var invoked: [AppCommandInvocation] = []
        let registry = AppCommandRegistry(workspace: workspace, shortcuts: shortcuts) { invoked.append($0) }
        let firstTask = try #require(registry.perform(.runCurrent, context: context(first)))
        first.selection = NSRange(location: 0, length: 0)
        let second = workspace.newDocument(text: "SELECT 'other tab'")
        await firstTask.value
        #expect(invoked.count == 1)
        #expect(invoked[0].documentID == first.id)
        #expect(invoked[0].fragment?.sourceSQL == "SELECT '😀 second'")
        #expect(workspace.selectedDocumentID == second.id)
        workspace.selectedDocumentID = first.id
        let script = try #require(registry.perform(.runScript, context: context(first)))
        await script.value
        #expect(invoked.last?.fragment?.sourceSQL == first.text)
        #expect(invoked.last?.fragment?.kind == .script)
        first.isRunning = true
        #expect(!registry.canPerform(.runCurrent, context: context(first)))
        #expect(registry.canPerform(.stop, context: context(first)))
        #expect(registry.canPerform(.stop, context: context(first, focus: .textInput)))
        first.isRunning = false
        first.table = TableReference(schema: "public", name: "demo", kind: "table")
        #expect(registry.canPerform(.runCurrent, context: context(first, focus: .grid)))
        #expect(!registry.canPerform(.runScript, context: context(first, focus: .grid)))
        #expect(!registry.canPerform(.runToJSON, context: context(first, focus: .grid)))
    }

    @Test func nativeRemappingUsesSelectedDocumentAndLeavesTextEditingIntact() async throws {
        let (shortcuts, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let (workspace, document) = try await setup(shortcuts: shortcuts)
        var invoked: [AppCommandInvocation] = []
        let registry = AppCommandRegistry(workspace: workspace, shortcuts: shortcuts) { invoked.append($0) }
        let text = Binding(get: { document.text }, set: { document.text = $0 })
        let coordinator = SQLEditorView.Coordinator(text: text)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: text, isEditable: true, in: scroll, documentID: document.id,
            selectionChanged: { document.selection = $0 },
            onCommandEvent: { registry.handleKeyEvent($0, documentID: document.id, selection: $1) })
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 700, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        workspace.presentationWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }
        let editor = try #require(scroll.documentView as? NSTextView)
        try #require(window.makeFirstResponder(editor))
        for _ in 0..<20 where !window.isKeyWindow { try await Task.sleep(for: .milliseconds(20)); window.makeKey() }
        try #require(window.isKeyWindow)
        let selection = (document.text as NSString).range(of: "SELECT '😀 second'")
        let sourceBeforeShortcuts = document.text
        editor.setSelectedRange(selection)
        #expect(editor.performKeyEquivalent(with: try key(window)))
        #expect(editor.performKeyEquivalent(with: try key(window, modifiers: [.command, .shift])))
        try await Task.sleep(for: .milliseconds(20))
        #expect(invoked.map(\.command) == [.runCurrent, .runScript])
        #expect(invoked.first?.fragment?.sourceSQL == "SELECT '😀 second'")
        #expect(invoked.last?.fragment?.sourceSQL == sourceBeforeShortcuts)
        let other = workspace.newDocument(text: "SELECT 'new selected tab'")
        other.selection = NSRange(location: 3, length: 0)
        #expect(workspace.selectedDocumentID == other.id)
        #expect(registry.context().documentID == document.id)
        #expect(!registry.canPerform(.runCurrent))
        #expect(registry.perform(.runCurrent) == nil)
        #expect(!editor.performKeyEquivalent(with: try key(window)))
        #expect(other.selection == NSRange(location: 3, length: 0))
        workspace.selectedDocumentID = document.id
        #expect(shortcuts.update(AppShortcut(key: "r", modifiers: [.command, .option]), for: .runCurrent) == nil)
        #expect(!editor.performKeyEquivalent(with: try key(window)))
        dispatch(try key(window, keyCode: 15, characters: "r", modifiers: [.command, .option]), in: window)
        try await Task.sleep(for: .milliseconds(20))
        #expect(invoked.count == 3)
        // System selection, insertion, newline and per-document undo
        // still go through NSTextView rather than the app command registry.
        let before = invoked.count
        editor.selectAll(nil)
        #expect(editor.selectedRange().length == document.text.utf16.count)
        #expect(!registry.handleKeyEvent(try key(window, keyCode: 8, characters: "c"), documentID: document.id))
        editor.insertText("SELECT 9", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        #expect(document.text == "SELECT 9\n")
        editor.undoManager?.undo()
        #expect(!document.text.hasSuffix("\n"))
        editor.setSelectedRange(NSRange(location: document.text.utf16.count, length: 0))
        let beforeNativeNewlines = document.text.utf16.count
        editor.keyDown(with: try key(window, modifiers: .option))
        editor.keyDown(with: try key(window, modifiers: .control))
        #expect(document.text.utf16.count == beforeNativeNewlines + 2)
        #expect(invoked.count == before)
    }

    @Test func actualFocusForeignWindowsSheetsAndFutureGridCommandsAreScoped() async throws {
        let gridID = AppCommandID(rawValue: "copyJSONFixture")
        let gridCommand = AppCommandDescriptor(id: gridID, title: "Copy JSON fixture", scope: .grid,
            defaultShortcut: AppShortcut(key: "j", modifiers: [.command, .option]))
        let (shortcuts, defaults, name) = try store(descriptors: AppCommandDescriptor.builtins + [gridCommand])
        defer { defaults.removePersistentDomain(forName: name) }
        let (workspace, document) = try await setup(shortcuts: shortcuts)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 480))
        let binding = Binding(get: { document.text }, set: { document.text = $0 })
        let coordinator = SQLEditorView.Coordinator(text: binding)
        let editorScroll = coordinator.makeScrollView()
        coordinator.update(text: binding, isEditable: true, in: editorScroll, documentID: document.id)
        editorScroll.frame = NSRect(x: 0, y: 180, width: 700, height: 300)
        content.addSubview(editorScroll)
        let gridCoordinator = ResultTableView.Coordinator()
        let gridScroll = gridCoordinator.makeScrollView()
        gridCoordinator.update(columns: [ResultColumn(index: 0, name: "value", typeOid: 23)], rows: [["1"]], in: gridScroll)
        gridScroll.frame = NSRect(x: 0, y: 30, width: 500, height: 130)
        content.addSubview(gridScroll)
        let grid = try #require(gridScroll.documentView as? ResultGridTableView)
        grid.appCommandDocumentID = document.id
        let window = NSWindow(contentRect: content.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        workspace.presentationWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        for _ in 0..<20 where !window.isKeyWindow { try await Task.sleep(for: .milliseconds(20)); window.makeKey() }
        try #require(window.isKeyWindow)
        defer { window.close() }
        let editor = try #require(editorScroll.documentView as? NSTextView)
        try #require(window.makeFirstResponder(editor))
        #expect(workspace.commands.context().focus == .sqlEditor)
        #expect(workspace.commands.canPerform(.runCurrent))
        var gridCalls = 0
        workspace.commands.registerGridCommand(gridID) { _ in gridCalls += 1 }
        #expect(!workspace.commands.canPerform(gridID))
        #expect(!workspace.commands.handleKeyEvent(try key(window, keyCode: 38, characters: "j", modifiers: [.command, .option]), documentID: document.id))
        try #require(window.makeFirstResponder(grid))
        #expect(workspace.commands.context().focus == .grid)
        let other = workspace.newDocument(text: "SELECT 'other grid tab'")
        #expect(workspace.commands.context().documentID == document.id)
        #expect(!workspace.commands.canPerform(.runCurrent))
        #expect(!workspace.commands.canPerform(gridID))
        #expect(workspace.commands.perform(.runCurrent) == nil)
        #expect(workspace.commands.perform(gridID) == nil)
        #expect(workspace.selectedDocumentID == other.id)
        workspace.selectedDocumentID = document.id
        let gridTask = try #require(workspace.commands.perform(gridID))
        await gridTask.value
        #expect(gridCalls == 1)
        let field = NSTextField(frame: NSRect(x: 0, y: 60, width: 150, height: 24))
        content.addSubview(field)
        try #require(window.makeFirstResponder(field))
        #expect(workspace.commands.context().focus == .textInput)
        #expect(!workspace.commands.canPerform(gridID) && !workspace.commands.canPerform(.runCurrent))
        let foreign = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        foreign.isReleasedWhenClosed = false
        foreign.makeKeyAndOrderFront(nil)
        defer { foreign.close() }
        #expect(!workspace.commands.canPerform(.runCurrent))
        window.makeKeyAndOrderFront(nil)
        try #require(window.makeFirstResponder(editor))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet, completionHandler: nil)
        #expect(workspace.commands.context().hasModal)
        #expect(workspace.commands.perform(.runCurrent) == nil)
        #expect(!workspace.commands.handleKeyEvent(try key(sheet), documentID: document.id))
        window.endSheet(sheet)
        sheet.orderOut(nil)
    }

    @Test func actualWorkspaceAndShortcutSettingsRenderInBothAppearances() async throws {
        let (shortcuts, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let (workspace, document) = try await setup(shortcuts: shortcuts)
        document.text = "select * from orders;\n\nselect * from people;"
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            let (window, content) = try await host(ApplicationWorkspaceView(workspace: workspace).preferredColorScheme(scheme), appearance: appearance)
            let policy = NativeButtonFocusPolicy()
            policy.apply(to: window)
            try await Task.sleep(for: .milliseconds(80))
            let editor = try #require(descendants(content, of: NSTextView.self).first { $0.accessibilityIdentifier() == "sqlEditor" })
            try #require(window.makeFirstResponder(editor))
            editor.setSelectedRange(NSRange(location: (document.text as NSString).range(of: ";").location + 1, length: 0))
            #expect(workspace.executionFragment(document)?.sourceSQL == "select * from orders")
            #expect(editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil)
            #expect(editor.layoutManager?.temporaryAttribute(.backgroundColor,
                atCharacterIndex: (document.text as NSString).range(of: "select * from people").location, effectiveRange: nil) == nil)
            try capture(content, name: "r24-workspace-\(name)")
            window.close()
            let (settings, settingsContent) = try await host(ShortcutSettingsView(store: shortcuts).preferredColorScheme(scheme), width: 660, height: 460, appearance: appearance)
            policy.apply(to: settings)
            try await Task.sleep(for: .milliseconds(80))
            let buttons = descendants(settingsContent, of: NSButton.self).filter { !$0.isHiddenOrHasHiddenAncestor }
            #expect(!buttons.isEmpty)
            for button in buttons { #expect(button.focusRingType == .none) }
            try capture(settingsContent, name: "r24-shortcuts-\(name)")
            settings.close()
        }
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func nativeButtonMenuDispatcherAndRemappedKeyboardExecuteTheSameFragmentOnPostgres() async throws {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let url = try #require(URLComponents(string: ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? ""))
        let (shortcuts, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), commandShortcuts: shortcuts,
            closeDecision: { _ in .rollback }, executionDecision: { _ in true }, helperFactory: {
                BackendClient(executableURL: repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core"))
            })
        await workspace.start()
        try #require(await workspace.library.saveConnection(name: "Command fixture", settings: ConnectionSettings(
            host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()),
            user: try #require(url.user), password: url.password ?? "", sslMode: "disable")))
        let document = workspace.newDocument(text: "SELECT 10 AS value;\nSELECT 20 AS value;\nSELECT 30 AS value;")
        let (window, content) = try await host(ApplicationWorkspaceView(workspace: workspace))
        defer { window.close() }
        let editor = try #require(descendants(content, of: NSTextView.self).first { $0.accessibilityIdentifier() == "sqlEditor" })
        try #require(window.makeFirstResponder(editor))
        editor.setSelectedRange((document.text as NSString).range(of: "SELECT 20 AS value"))
        try await Task.sleep(for: .milliseconds(40))
        // This is the exact entry point used by the Query menu.
        let menu = try #require(workspace.commands.perform(.runCurrent))
        await menu.value
        #expect(document.executions.map(\.sql) == ["SELECT 20 AS value"])
        #expect(document.runtime?.result?.rows == [["20"]])
        #expect(document.successfulExecutionRanges == [(document.text as NSString).range(of: "SELECT 20 AS value")])
        try await Task.sleep(for: .milliseconds(40))
        let ruler = try #require((editor.enclosingScrollView?.verticalRulerView as? SQLLineNumberRuler))
        #expect(ruler.successfulLines == [1])
        try await Task.sleep(for: .milliseconds(40))
        let beforeButton = workspace.history.count
        try press("runQuery", in: content)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while workspace.history.count == beforeButton || document.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(workspace.history.count == beforeButton + 1)
        try #require(!document.isRunning)
        #expect(document.executions.map(\.sql) == ["SELECT 20 AS value"])
        #expect(document.runtime?.result?.rows == [["20"]])
        #expect(shortcuts.update(AppShortcut(key: "r", modifiers: [.command, .option]), for: .runCurrent) == nil)
        window.makeKeyAndOrderFront(nil)
        try #require(window.makeFirstResponder(editor))
        try #require(window.isKeyWindow)
        try #require(workspace.commands.canPerform(.runCurrent))
        let beforeKey = workspace.history.count
        dispatch(try key(window, keyCode: 15, characters: "r", modifiers: [.command, .option]), in: window)
        while workspace.history.count == beforeKey || document.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(workspace.history.count == beforeKey + 1)
        try #require(!document.isRunning)
        #expect(document.executions.map(\.sql) == ["SELECT 20 AS value"])
        #expect(document.runtime?.result?.rows == [["20"]])
        window.makeKeyAndOrderFront(nil)
        try #require(window.makeFirstResponder(editor))
        try #require(workspace.commands.canPerform(.runScript))
        let beforeScript = workspace.history.count
        dispatch(try key(window, modifiers: [.command, .shift]), in: window)
        while workspace.history.count < beforeScript + 3 || document.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(workspace.history.count == beforeScript + 3)
        #expect(document.executions.map(\.sql) == ["SELECT 10 AS value", "SELECT 20 AS value", "SELECT 30 AS value"])
        #expect(document.runtime?.result?.rows == [["30"]])
        #expect(document.successfulExecutionRanges == document.executions.map(\.range))
        await workspace.shutdown()
    }
}
