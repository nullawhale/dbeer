import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct AppearanceThemeSettingsTests {
    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func accessibilityObjects(_ root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var visited: Set<ObjectIdentifier> = []
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                children.forEach(visit)
            }
            (object as? NSView)?.subviews.forEach(visit)
        }
        visit(root)
        return result
    }

    private func identifier(_ object: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func accessibilityBoolean(_ object: NSObject, method: String) -> Bool? {
        let selector = NSSelectorFromString(method)
        guard object.responds(to: selector) else { return nil }
        typealias Invoke = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Invoke.self)(object, selector)
    }

    private func expectColor(_ actual: NSColor?, _ expected: NSColor?) throws {
        let first = try #require(actual?.usingColorSpace(.deviceRGB))
        let second = try #require(expected?.usingColorSpace(.deviceRGB))
        #expect(abs(first.redComponent - second.redComponent) < 0.015)
        #expect(abs(first.greenComponent - second.greenComponent) < 0.015)
        #expect(abs(first.blueComponent - second.blueComponent) < 0.015)
        #expect(abs(first.alphaComponent - second.alphaComponent) < 0.015)
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    @Test func settingsExposeIndependentLiveSchemesAndNativePreviewInAllAppearanceCombinations() async throws {
        let domain = "dev.dbeer.theme-settings-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = NSApplication.shared
        let originalAppearance = app.appearance
        let originalIcon = app.applicationIconImage
        defer {
            app.appearance = originalAppearance
            app.applicationIconImage = originalIcon
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let store = EditorThemeStore(defaults: defaults, directory: directory)
        let appearance = AppAppearance(defaults: defaults, editorThemes: store)
        let host = NSHostingView(rootView: AppearanceSettingsView(appearance: appearance, editorThemes: store))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 650, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { window.close() }
        appearance.start()
        for appTheme in [AppTheme.light, .dark] {
            appearance.theme = appTheme
            for (editorName, id) in [("light", "jetbrains-light"), ("dark", "jetbrains-darcula")] {
                store.selectedThemeID = id
                try await Task.sleep(for: .milliseconds(180))
                host.layoutSubtreeIfNeeded()
                let selected = try #require(store.selectedTheme)
                #expect(selected.id == id)
                #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appTheme.appearance?.name)
                let objects = accessibilityObjects(host)
                for id in ["appearanceTheme", "editorColorScheme", "importEditorTheme", "removeEditorTheme", "editorThemePreview"] {
                    #expect(objects.contains { identifier($0) == id }, "Missing Settings accessibility element \(id)")
                }
                let editor = try #require(descendants(host, of: SQLTextView.self).first)
                #expect(!editor.isEditable && editor.isSelectable)
                #expect(editor.editorTheme?.id == id)
                #expect(editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (editorName == "dark" ? .darkAqua : .aqua))
                try expectColor(editor.backgroundColor, selected.colors["editor.background"]?.nsColor)
                try expectColor(editor.textColor, selected.colors["editor.foreground"]?.nsColor)
                let range = (editor.string as NSString).range(of: "SELECT")
                let color = editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor
                try expectColor(color, selected.style(for: ["source.sql", "keyword.other.sql"]).foreground?.nsColor)
                #expect(AppAppearance(defaults: defaults).theme == appTheme)
                #expect(EditorThemeStore(defaults: defaults, directory: directory).selectedThemeID == id)
                let remove = try #require(objects.first { identifier($0) == "removeEditorTheme" })
                #expect(accessibilityBoolean(remove, method: "isAccessibilityEnabled") == false)
                try capture(host, name: "themes-settings-app-\(appTheme.rawValue)-editor-\(editorName)")
            }
        }
        // Automatic follows the application; an explicit selection above never
        // changes the saved application appearance.
        store.selectedThemeID = EditorThemeStore.automaticID
        for appTheme in [AppTheme.light, .dark] {
            appearance.theme = appTheme
            try await Task.sleep(for: .milliseconds(150))
            let editor = try #require(descendants(host, of: SQLTextView.self).first)
            #expect(editor.editorTheme?.id == (appTheme == .dark ? "native-dark" : "native-light"))
        }
    }

    @Test func nativeSchemePickerAndRemoveActionUpdateThePersistedLibrary() async throws {
        let domain = "dev.dbeer.theme-settings-actions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("Review.icls")
        try Data("<scheme name=\"Review scheme\" parent_scheme=\"Darcula\" />".utf8).write(to: source)
        let store = EditorThemeStore(defaults: defaults, directory: directory.appendingPathComponent("library"))
        let imported = try store.importTheme(from: source)
        let appearance = AppAppearance(defaults: defaults, editorThemes: store)
        let host = NSHostingView(rootView: AppearanceSettingsView(appearance: appearance, editorThemes: store))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 650, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        let popup = try #require(NativeThemeMenuActions.buttons(in: host)
            .first { $0.title == imported.name })
        let selected = try #require(store.themes.first { $0.id == "jetbrains-light" })
        try await NativeThemeMenuActions.select(selected.name, in: popup)
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.selectedThemeID == selected.id)
        #expect(defaults.string(forKey: EditorThemeStore.preferenceKey) == selected.id)
        try await NativeThemeMenuActions.select(imported.name, in: popup)
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.selectedThemeID == imported.id)
        let remove = try #require(accessibilityObjects(host).first { identifier($0) == "removeEditorTheme" })
        #expect(accessibilityBoolean(remove, method: "isAccessibilityEnabled") == true)
        #expect(accessibilityBoolean(remove, method: "accessibilityPerformPress") == true)
        try await Task.sleep(for: .milliseconds(120))
        #expect(!store.themes.contains { $0.id == imported.id })
        #expect(store.selectedThemeID == EditorThemeStore.automaticID)
        let restored = EditorThemeStore(defaults: defaults, directory: directory.appendingPathComponent("library"))
        #expect(restored.selectedThemeID == EditorThemeStore.automaticID)
        #expect(!restored.themes.contains { $0.id == imported.id })
        #expect(appearance.theme == .system)
    }
}
