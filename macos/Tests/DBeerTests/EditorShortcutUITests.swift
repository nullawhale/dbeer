import AppKit
import SwiftUI
import Testing
@testable import DBeer

/// Opt-in UI coverage in owned native windows with isolated shortcut preferences.
@Suite(.serialized)
@MainActor
struct EditorShortcutUITests {
    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func activate(_ window: NSWindow) async throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<40 where !window.isKeyWindow || !NSApp.isActive {
            try await Task.sleep(for: .milliseconds(25))
            window.makeKeyAndOrderFront(nil)
        }
        try #require(window.isKeyWindow && NSApp.isActive)
        try await settle(window)
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }

    private func press(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = .command,
                       in window: NSWindow) async throws {
        try #require(NSApp.keyWindow === window)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            // Go through native application/window routing, never the editor's action directly.
            NSApp.sendEvent(event)
        }
        try await settle(window)
    }

    private func window<Content: View>(_ content: Content, title: String, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 90, y: 100), size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.contentView = NSHostingView(rootView: content)
        return window
    }

    private func capture(_ window: NSWindow, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = try #require(window.contentView)
        content.displayIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
    }

    @Test func selectionRemappingAndUndoRedoThroughVisibleWorkspaceAndSettings() async throws {
        let defaultsName = "dev.dbeer.tests.editor-shortcut-ui.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let shortcuts = AppShortcutStore(defaults: defaults)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
            commandShortcuts: shortcuts, sqlFolders: SQLFolderLibrary(automaticallyRefresh: false),
            automaticallyWatchFiles: false, closeDecision: { _ in .cancel })
        await workspace.restoreSavedWorkspace()
        let source = "SELECT sum(coalesce(price, 0)) FROM sales;\nSELECT 2;"
        let document = workspace.newDocument(text: source)
        let editorWindow = window(ApplicationWorkspaceView(workspace: workspace),
            title: "DBeer editor shortcut verification", size: NSSize(width: 1120, height: 760))
        workspace.presentationWindow = editorWindow
        defer { editorWindow.close() }

        // Include native Close/Undo/Redo equivalents to catch Command-W routing conflicts.
        let previousMenu = NSApp.mainMenu
        let menu = NSMenu()
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        file.submenu = NSMenu(title: "File")
        file.submenu?.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(file)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Undo", action: #selector(SQLTextView.undo(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(SQLTextView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.submenu?.addItem(redo)
        menu.addItem(edit)
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = previousMenu }

        do {
            try await activate(editorWindow)
            let editor = try #require(workspace.editorState.editor(for: document.id))
            try #require(editorWindow.makeFirstResponder(editor))
            editor.setSelectedRange(NSRange(location: (source as NSString).range(of: "price").location + 2, length: 0))
            for (index, expected) in ["price", "price, 0", "(price, 0)", "coalesce(price, 0)",
                                      "(coalesce(price, 0))", "sum(coalesce(price, 0))"].enumerated() {
                try await press("w", code: 13, in: editorWindow)
                try #require(editorWindow.isVisible && editorWindow.firstResponder === editor)
                #expect((editor.string as NSString).substring(with: editor.selectedRange()) == expected)
                #expect(document.text == source && workspace.documents.count == 1)
                if index == 3 { try capture(editorWindow, name: "01-command-w-selection") }
            }

            editor.setSelectedRange((editor.string as NSString).range(of: "price"))
            try await press("x", code: 7, modifiers: [], in: editorWindow)
            let changed = source.replacingOccurrences(of: "price", with: "x")
            try #require(editor.string == changed && document.text == changed)
            try await press("z", code: 6, in: editorWindow)
            #expect(editor.string == source && document.text == source)
            try capture(editorWindow, name: "02-command-z-undo")
            try await press("Z", code: 6, modifiers: [.command, .shift], in: editorWindow)
            #expect(editor.string == changed && document.text == changed)
            try capture(editorWindow, name: "03-command-shift-z-redo")

            let settingsWindow = window(ShortcutSettingsView(store: shortcuts), title: "DBeer Shortcuts verification",
                size: NSSize(width: 700, height: 560))
            defer { settingsWindow.close() }
            try await activate(settingsWindow)
            let settingsContent = try #require(settingsWindow.contentView)
            let search = try #require(descendants(settingsContent, of: NSTextField.self).first { $0.isEditable })
            try #require(settingsWindow.makeFirstResponder(search))
            try await press("extend selection", code: 0, modifiers: [], in: settingsWindow)
            let recorder = try #require(descendants(settingsContent, of: ShortcutRecorderButton.self).first {
                $0.accessibilityIdentifier() == "shortcutRecorder-editor.extendSelection"
            })
            try #require(!recorder.visibleRect.isEmpty)
            #expect(recorder.title == "⌘W")
            recorder.performClick(nil)
            try #require(recorder.isRecording && settingsWindow.firstResponder === recorder)
            let custom = AppShortcut(key: "k", modifiers: [.command, .option])
            try await press("k", code: 40, modifiers: custom.modifiers, in: settingsWindow)
            #expect(!recorder.isRecording && recorder.title == custom.displayString)
            #expect(shortcuts.shortcut(for: SQLToolCommand.extendSelection.commandID) == custom)
            #expect(AppShortcutStore(defaults: defaults).shortcut(for: SQLToolCommand.extendSelection.commandID) == custom)
            try capture(settingsWindow, name: "04-shortcut-remapped")
            settingsWindow.close()

            try await activate(editorWindow)
            try #require(editorWindow.makeFirstResponder(editor))
            editor.setSelectedRange(NSRange(location: (changed as NSString).range(of: "coalesce").location + 2, length: 0))
            for expected in ["coalesce", "coalesce(x, 0)"] {
                try await press("k", code: 40, modifiers: custom.modifiers, in: editorWindow)
                #expect((editor.string as NSString).substring(with: editor.selectedRange()) == expected)
            }
            #expect(document.text == changed && editorWindow.isVisible)
            try capture(editorWindow, name: "05-remapped-shortcut-selection")
            await workspace.shutdown()
        } catch {
            try? capture(editorWindow, name: "failure-workspace")
            await workspace.shutdown()
            throw error
        }
    }
}
