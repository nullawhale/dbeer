import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct ApplicationThemeSurfaceTests {
    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func settle(_ content: NSView, window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(160))
        content.layoutSubtreeIfNeeded()
        NativeButtonFocusPolicy().apply(to: window)
        content.displayIfNeeded()
    }

    private func expectColor(_ actual: NSColor?, _ expected: NSColor?, in appearance: NSAppearance) throws {
        guard actual != nil || expected != nil else { return }
        var actualRGB: NSColor?
        var expectedRGB: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            actualRGB = actual?.usingColorSpace(.deviceRGB)
            expectedRGB = expected?.usingColorSpace(.deviceRGB)
        }
        let first = try #require(actualRGB)
        let second = try #require(expectedRGB)
        #expect(abs(first.redComponent - second.redComponent) < 0.01)
        #expect(abs(first.greenComponent - second.greenComponent) < 0.01)
        #expect(abs(first.blueComponent - second.blueComponent) < 0.01)
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent(name + ".png"))
    }

    @Test func connectionSheetUpdatesBetweenDarkSchemesAndRestoresNativeControlsWithoutLosingEdits() async throws {
        let domain = "dev.dbeer.application-surface-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(domain, isDirectory: true)
        let app = NSApplication.shared
        let originalAppearance = app.appearance
        let originalIcon = app.applicationIconImage
        let store = EditorThemeStore(defaults: defaults, directory: directory)
        let appearance = AppAppearance(defaults: defaults, editorThemes: store)
        appearance.chooseSelection("dark")
        appearance.start()
        defer {
            appearance.chooseSelection("system")
            app.appearance = originalAppearance
            app.applicationIconImage = originalIcon
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = WorkspaceModel(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let parent = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 760, height: 850),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.contentView = NSHostingView(rootView: Text("DBeer").applicationTheme(appearance: appearance))
        let content = NSHostingView(rootView: ConnectionEditorView(model: model, connection: nil) {}
            .applicationTheme(appearance: appearance))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 780),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentView = content
        parent.makeKeyAndOrderFront(nil)
        parent.beginSheet(sheet, completionHandler: nil)
        app.activate(ignoringOtherApps: true)
        defer {
            parent.endSheet(sheet)
            sheet.close()
            parent.close()
        }
        try await settle(content, window: sheet)
        #expect(sheet.sheetParent === parent)
        let host = try #require(descendants(content, of: NSTextField.self)
            .first { $0.isEditable && !($0 is NSSecureTextField) && $0.stringValue == "localhost" })
        let tls = try #require(NativeThemeMenuActions.buttons(in: content).first { $0.title == "verify-full" })
        let readonly = try #require(descendants(content, of: NSSwitch.self).first)
        let nativeText = host.textColor
        let nativeBackground = host.backgroundColor
        let nativeWindow = sheet.backgroundColor
        let nativePopupBezel = tls.bezelStyle
        let nativeToggleSize = readonly.controlSize
        let nativeBorder = host.isBordered
        let nativeBezel = host.isBezeled
        try await NativeThemeMenuActions.select("require", in: tls)
        readonly.performClick(nil)
        try await settle(content, window: sheet)
        #expect(tls.title == "require")
        #expect(readonly.state == .on)
        #expect(sheet.makeFirstResponder(host))
        let editor = try #require(host.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 1, length: 4))
        let selection = editor.selectedRange()
        let undo = editor.undoManager
        for id in ["solarized-dark", "jetbrains-darcula"] {
            let theme = try #require(store.themes.first { $0.id == id })
            #expect(theme.appearance == .dark)
            appearance.chooseSelection(id)
            try await settle(content, window: sheet)
            #expect(descendants(content, of: NSTextField.self).contains { $0 === host })
            #expect(host.stringValue == "localhost")
            #expect(host.currentEditor() === editor)
            #expect(editor.selectedRange() == selection)
            #expect(editor.undoManager === undo)
            #expect(tls.title == "require")
            #expect(readonly.state == .on)
            #expect(tls.bezelStyle == nativePopupBezel)
            #expect(readonly.controlSize == nativeToggleSize)
            #expect(host.isBordered == nativeBorder)
            #expect(host.isBezeled == nativeBezel)
            #expect(sheet.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            try expectColor(host.textColor, AppPalette.nsColor(.text), in: sheet.effectiveAppearance)
            try expectColor(sheet.backgroundColor, AppPalette.nsColor(.window), in: sheet.effectiveAppearance)
            if host.drawsBackground {
                try expectColor(host.backgroundColor, AppPalette.nsColor(.control), in: sheet.effectiveAppearance)
            }
            try capture(content, name: "application-scheme-connection-sheet-" + id)
        }
        appearance.chooseSelection("dark")
        try await settle(content, window: sheet)
        #expect(!AppPalette.isCustom)
        #expect(host.currentEditor() === editor)
        #expect(editor.selectedRange() == selection)
        #expect(tls.title == "require")
        #expect(readonly.state == .on)
        try expectColor(host.textColor, nativeText, in: sheet.effectiveAppearance)
        try expectColor(host.backgroundColor, nativeBackground, in: sheet.effectiveAppearance)
        try expectColor(sheet.backgroundColor, nativeWindow, in: sheet.effectiveAppearance)
    }


}
