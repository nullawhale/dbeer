import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Exercise the real Settings menu and workspace rather than a palette-only
/// fixture: choosing an application scheme must also reach native controls.
@Suite(.serialized)
@MainActor
struct ApplicationThemeIntegrationTests {
    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, of: type) }
    }

    private func accessibilityObjects(_ root: NSObject) -> [NSObject] {
        var visited: Set<ObjectIdentifier> = []
        var result: [NSObject] = []
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let children = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: children),
               let values = object.perform(children)?.takeUnretainedValue() as? [NSObject] { values.forEach(visit) }
            (object as? NSView)?.subviews.forEach(visit)
        }
        visit(root)
        return result
    }

    private func accessibilityValue(_ object: NSObject, selector name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func accessibilityIdentifiers(_ root: NSObject) -> Set<String> {
        Set(accessibilityObjects(root).compactMap { accessibilityValue($0, selector: "accessibilityIdentifier") as? String })
    }

    private func context() throws -> (UserDefaults, String, URL) {
        let domain = "dev.dbeer.application-scheme-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(domain, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (defaults, domain, directory)
    }

    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> (NSWindow, NSHostingView<V>) {
        let content = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 60, y: 80, width: width, height: height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DBeer"
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return (window, content)
    }

    private func settle(_ content: NSView) async throws {
        try await Task.sleep(for: .milliseconds(180))
        content.layoutSubtreeIfNeeded()
        if let window = content.window { NativeButtonFocusPolicy().apply(to: window) }
        content.displayIfNeeded()
    }

    private func expectColor(_ actual: NSColor?, _ expected: NSColor?, appearance: NSAppearance) throws {
        var actualRGB: NSColor?
        var expectedRGB: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            actualRGB = actual?.usingColorSpace(.deviceRGB)
            expectedRGB = expected?.usingColorSpace(.deviceRGB)
        }
        let first = try #require(actualRGB)
        let second = try #require(expectedRGB)
        #expect(abs(first.redComponent - second.redComponent) < 0.015)
        #expect(abs(first.greenComponent - second.greenComponent) < 0.015)
        #expect(abs(first.blueComponent - second.blueComponent) < 0.015)
        #expect(abs(first.alphaComponent - second.alphaComponent) < 0.015)
    }

    private func capture(_ window: NSWindow, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        let view = try #require(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    @Test func actualSettingsMenuOffersAllSharedSchemesAndKeepsEditorSelectionIndependent() async throws {
        let (defaults, domain, directory) = try context()
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        let originalIcon = application.applicationIconImage
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let store = EditorThemeStore(defaults: defaults, directory: directory)
        let appearance = AppAppearance(defaults: defaults, editorThemes: store)
        defer {
            appearance.chooseSelection("system")
            application.appearance = originalAppearance
            application.applicationIconImage = originalIcon
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        store.selectedThemeID = "vscode-dark-plus"
        appearance.start()
        let (window, content) = host(AppearanceSettingsView(appearance: appearance, editorThemes: store),
            width: 650, height: 560)
        defer { window.close() }
        try await settle(content)
        let identifiers = accessibilityIdentifiers(content)
        for id in ["applicationTheme", "appearanceTheme", "editorColorScheme", "editorThemePreview"] {
            #expect(identifiers.contains(id), "Missing Settings accessibility element \(id)")
        }
        let appPicker = try #require(NativeThemeMenuActions.buttons(in: content)
            .first { $0.title == AppTheme.system.title })
        let editorPicker = try #require(NativeThemeMenuActions.buttons(in: content)
            .first { $0 !== appPicker && $0.title == store.selectedTheme?.name })
        let preview = try #require(descendants(content, of: SQLTextView.self).first)
        #expect(!preview.isEditable)
        for scheme in store.themes {
            try await NativeThemeMenuActions.select(scheme.name, in: appPicker)
            try await settle(content)
            #expect(appearance.selectionID == scheme.id)
            #expect(appearance.selectedColorTheme?.id == scheme.id)
            #expect(defaults.string(forKey: AppAppearance.colorThemePreferenceKey) == scheme.id)
            #expect(store.selectedThemeID == "vscode-dark-plus")
            #expect(editorPicker.title == store.selectedTheme?.name)
            #expect(descendants(content, of: SQLTextView.self).first === preview)
            #expect(preview.editorTheme?.id == "vscode-dark-plus")
            #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ==
                (scheme.appearance == .dark ? .darkAqua : .aqua))
        }
        try await NativeThemeMenuActions.select(try #require(store.themes.first { $0.id == "solarized-light" }).name, in: appPicker)
        try await NativeThemeMenuActions.select(try #require(store.themes.first { $0.id == "jetbrains-darcula" }).name, in: editorPicker)
        try await settle(content)
        #expect(appearance.selectionID == "solarized-light")
        #expect(store.selectedThemeID == "jetbrains-darcula")
        #expect(preview.editorTheme?.id == "jetbrains-darcula")
        try capture(window, name: "application-scheme-settings-solarized-light-editor-darcula")
        let restoredStore = EditorThemeStore(defaults: defaults, directory: directory)
        let restored = AppAppearance(defaults: defaults, editorThemes: restoredStore)
        #expect(restored.selectionID == "solarized-light")
        #expect(restoredStore.selectedThemeID == "jetbrains-darcula")
        try await NativeThemeMenuActions.select(AppTheme.dark.title, in: appPicker)
        try await settle(content)
        #expect(appearance.selectionID == "dark")
        #expect(appearance.selectedColorTheme == nil)
        #expect(store.selectedThemeID == "jetbrains-darcula")
    }

    @Test func removingImportedApplicationSchemeRestoresNativeThemeWithoutChangingEditor() async throws {
        let (defaults, domain, directory) = try context()
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        let originalIcon = application.applicationIconImage
        let store = EditorThemeStore(defaults: defaults, directory: directory.appendingPathComponent("library"))
        let appearance = AppAppearance(defaults: defaults, editorThemes: store)
        defer {
            appearance.chooseSelection("system")
            application.appearance = originalAppearance
            application.applicationIconImage = originalIcon
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let source = directory.appendingPathComponent("Imported.json")
        try Data(##"{"name":"Imported application scheme","type":"dark","colors":{"editor.background":"#142536","editor.foreground":"#e0e7ef","sideBar.background":"#0d1b29"}}"##.utf8).write(to: source)
        let imported = try store.importTheme(from: source)
        store.selectedThemeID = "vscode-light-plus"
        appearance.chooseSelection("light")
        appearance.chooseSelection(imported.id)
        appearance.start()
        try FileManager.default.removeItem(at: source)
        let restoredStore = EditorThemeStore(defaults: defaults, directory: directory.appendingPathComponent("library"))
        let restored = AppAppearance(defaults: defaults, editorThemes: restoredStore)
        #expect(restored.selectionID == imported.id)
        #expect(restoredStore.selectedThemeID == "vscode-light-plus")
        let (window, content) = host(AppearanceSettingsView(appearance: appearance, editorThemes: store),
            width: 650, height: 560)
        defer { window.close() }
        try await settle(content)
        let picker = try #require(NativeThemeMenuActions.buttons(in: content)
            .first { $0.title == imported.name })
        #expect(picker.title == imported.name)
        try await NativeThemeMenuActions.select(AppTheme.light.title, in: picker)
        try await settle(content)
        try await NativeThemeMenuActions.select(imported.name, in: picker)
        try await settle(content)
        #expect(appearance.selectionID == imported.id)
        try store.removeTheme(id: imported.id)
        try await settle(content)
        #expect(appearance.selectionID == "light")
        #expect(appearance.selectedColorTheme == nil)
        #expect(picker.title == AppTheme.light.title)
        #expect(store.selectedThemeID == "vscode-light-plus")
        #expect(defaults.string(forKey: AppAppearance.colorThemePreferenceKey) == "native")
        #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        let afterRemoval = AppAppearance(defaults: defaults,
            editorThemes: EditorThemeStore(defaults: defaults, directory: directory.appendingPathComponent("library")))
        #expect(afterRemoval.selectionID == "light")
    }

    @Test func schemesReachRealWorkspaceAndNativeGridWhileEditorRetainsFocusSelectionAndUndo() async throws {
        let (defaults, domain, directory) = try context()
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        let originalIcon = application.applicationIconImage
        let store = EditorThemeStore(defaults: defaults, directory: directory)
        let appearance = AppAppearance(defaults: defaults, editorThemes: store)
        defer {
            appearance.chooseSelection("system")
            application.appearance = originalAppearance
            application.applicationIconImage = originalIcon
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), editorThemes: store, appearance: appearance)
        let originalText = """
        -- Beer inventory
        SELECT name, style, abv
        FROM public.beers
        ORDER BY name;
        """
        let document = workspace.newDocument(text: originalText)
        var result = BackendMessage(type: "query.result", requestId: "theme-fixture")
        result.columns = [ResultColumn(index: 0, name: "name", typeOid: 25),
            ResultColumn(index: 1, name: "style", typeOid: 25), ResultColumn(index: 2, name: "abv", typeOid: 1700)]
        result.rows = [["Northern Lights", "IPA", "6.5"], ["Velvet Stout", "Stout", "5.8"], [nil, "", "0"]]
        result.commandTag = "SELECT 3"
        result.rowCount = 3
        result.displayedRowCount = 3
        result.durationMs = 1.2
        document.executions = [SQLExecution(sql: originalText, range: NSRange(location: 0, length: originalText.utf16.count),
            status: "Completed", result: result)]
        store.selectedThemeID = "vscode-dark-plus"
        appearance.start()
        let (window, content) = host(ApplicationWorkspaceView(workspace: workspace), width: 1180, height: 760)
        defer { window.close() }
        try await settle(content)
        let editor = try #require(descendants(content, of: SQLTextView.self).first)
        let table = try #require(descendants(content, of: ResultGridTableView.self).first)
        #expect(table.numberOfRows == 3 && table.numberOfColumns == 3)
        #expect(table.copyCoordinator?.supportsEditing == false)
        table.setRowsExternally(IndexSet(integer: 1))
        let gridSelection = try #require(table.cellSelection)
        try #require(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText("\n-- keep this draft", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        editor.setSelectedRange(NSRange(location: 24, length: 5))
        let selection = editor.selectedRange()
        let editedText = editor.string
        let undoManager = try #require(editor.undoManager)
        #expect(undoManager.canUndo)
        let caret = editor.insertionPointColor
        for appScheme in ["solarized-light", "solarized-dark", "jetbrains-darcula"] {
            appearance.chooseSelection(appScheme)
            try await settle(content)
            #expect(appearance.selectedColorTheme?.id == appScheme)
            #expect(descendants(content, of: SQLTextView.self).first === editor)
            #expect(descendants(content, of: ResultGridTableView.self).first === table)
            #expect(table.cellSelection?.rowRange == gridSelection.rowRange)
            #expect(table.cellSelection?.columnRange == gridSelection.columnRange)
            #expect(window.firstResponder === editor)
            #expect(editor.string == editedText && document.text == editedText)
            #expect(editor.selectedRange() == selection)
            #expect(editor.undoManager === undoManager && undoManager.canUndo)
            #expect(editor.editorTheme?.id == "vscode-dark-plus")
            try expectColor(editor.insertionPointColor, caret, appearance: editor.effectiveAppearance)
            let explicitEditor = try #require(store.selectedTheme)
            try expectColor(editor.backgroundColor, explicitEditor.colors["editor.background"]?.nsColor,
                appearance: editor.effectiveAppearance)
            try expectColor(window.backgroundColor, AppPalette.nsColor(.window), appearance: window.effectiveAppearance)
            try expectColor(table.backgroundColor, AppPalette.nsColor(.panel), appearance: window.effectiveAppearance)
            let firstCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
            try expectColor(firstCell.textField?.textColor, AppPalette.nsColor(.text), appearance: window.effectiveAppearance)
            #expect(firstCell.textField?.isEditable == false)
            #expect(document.runtime == nil)
            #expect(workspace.services.isEmpty && workspace.library.sessionId == nil)
            try capture(window, name: "application-scheme-\(appScheme)-editor-vscode-dark")
        }
        undoManager.undo()
        #expect(document.text == originalText)
        #expect(editor.string == originalText)
        store.selectedThemeID = "vscode-light-plus"
        appearance.chooseSelection("solarized-dark")
        try await settle(content)
        #expect(editor.editorTheme?.id == "vscode-light-plus")
        #expect(editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        try capture(window, name: "application-scheme-solarized-dark-editor-vscode-light")
        store.selectedThemeID = EditorThemeStore.automaticID
        try await settle(content)
        #expect(editor.editorTheme?.id == "solarized-dark")
        appearance.chooseSelection("light")
        store.selectedThemeID = "solarized-dark"
        try await settle(content)
        #expect(appearance.selectedColorTheme == nil)
        #expect(editor.editorTheme?.id == "solarized-dark")
        #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        #expect(document.runtime == nil && workspace.services.isEmpty)
        try capture(window, name: "application-scheme-native-light-editor-solarized-dark")
        await workspace.shutdown()
    }
}
