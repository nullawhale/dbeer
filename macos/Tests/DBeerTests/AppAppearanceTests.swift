import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct AppAppearanceTests {
    private func defaults() -> (UserDefaults, String) {
        let name = "dev.dbeer.appearance-tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private var appBundle: Bundle {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: repository.appendingPathComponent("build/DBeer.app"))!
    }

    @Test func themeIsPersistedAndUnknownValuesFollowSystem() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("unknown", forKey: AppAppearance.preferenceKey)
        let appearance = AppAppearance(defaults: defaults)
        #expect(appearance.theme == .system)
        appearance.theme = .dark
        #expect(AppAppearance(defaults: defaults).theme == .dark)
        appearance.theme = .light
        #expect(AppAppearance(defaults: defaults).theme == .light)
        appearance.theme = .system
        #expect(AppAppearance(defaults: defaults).theme == .system)
    }

    @Test func iconFollowsResolvedTheme() {
        let light = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!
        #expect(AppTheme.system.iconName(for: light) == "AppIcon")
        #expect(AppTheme.system.iconName(for: dark) == "AppIconDark")
        #expect(AppTheme.light.iconName(for: dark) == "AppIcon")
        #expect(AppTheme.dark.iconName(for: light) == "AppIconDark")
    }

    @Test func nativeAccentIsBundledAndMatchesTheAppPaletteInBothThemes() throws {
        let name = try #require(appBundle.object(forInfoDictionaryKey: "NSAccentColorName") as? String)
        let accent = try #require(NSColor(named: name, bundle: appBundle))
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            var resolvedAccent: NSColor?
            var resolvedPalette: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolvedAccent = accent.usingColorSpace(.deviceRGB)
                resolvedPalette = NSColor(AppPalette.accent).usingColorSpace(.deviceRGB)
            }
            let actual = try #require(resolvedAccent)
            let expected = try #require(resolvedPalette)
            #expect(abs(actual.redComponent - expected.redComponent) < 0.02)
            #expect(abs(actual.greenComponent - expected.greenComponent) < 0.02)
            #expect(abs(actual.blueComponent - expected.blueComponent) < 0.02)
            #expect(actual.alphaComponent == 1)
            #expect(actual.redComponent > actual.greenComponent)
            #expect(actual.greenComponent > actual.blueComponent)
        }
    }

    private func iconColor(_ image: NSImage, x: Int = 16, y: Int = 22) -> NSColor {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let destination = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try data.write(to: destination.appendingPathComponent(name + ".png"))
    }

    @Test func changingThemeUpdatesNativeAppearanceAndDockIcon() async throws {
        let (defaults, name) = defaults()
        let app = NSApplication.shared
        let originalAppearance = app.appearance
        let originalIcon = app.applicationIconImage
        defer {
            app.appearance = originalAppearance
            app.applicationIconImage = originalIcon
            defaults.removePersistentDomain(forName: name)
        }
        let appearance = AppAppearance(defaults: defaults, bundle: appBundle)
        appearance.start()
        let workspace = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        workspace.isReleasedWhenClosed = false
        workspace.contentView = NSHostingView(rootView: WorkspaceView(model: WorkspaceModel()))
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        settings.contentView = NSHostingView(rootView: AppearanceSettingsView(appearance: appearance))
        workspace.orderFront(nil)
        settings.orderFront(nil)
        defer { settings.close(); workspace.close() }
        for theme in [AppTheme.dark, .light] {
            appearance.theme = theme
            try await Task.sleep(for: .milliseconds(150))
            #expect(app.appearance?.name == theme.appearance?.name)
            #expect(workspace.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == theme.appearance?.name)
            #expect(settings.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == theme.appearance?.name)
            let url = try #require(appBundle.url(forResource: theme.iconName(for: app.effectiveAppearance), withExtension: "icns"))
            let expected = try #require(NSImage(contentsOf: url))
            let actual = try #require(app.applicationIconImage)
            // AppKit can resample the assigned icon; compare the mark color with
            // tolerance rather than requiring identical encoded pixels.
            let actualColor = iconColor(actual)
            let expectedColor = iconColor(expected)
            #expect(actualColor.alphaComponent > 0.99)
            #expect(expectedColor.alphaComponent > 0.99)
            #expect(abs(actualColor.redComponent - expectedColor.redComponent) < 0.06)
            #expect(abs(actualColor.greenComponent - expectedColor.greenComponent) < 0.06)
            #expect(abs(actualColor.blueComponent - expectedColor.blueComponent) < 0.06)
            #expect(iconColor(actual, x: 5, y: 16).alphaComponent < 0.01)
            #expect(iconColor(expected, x: 5, y: 16).alphaComponent < 0.01)
            try capture(try #require(workspace.contentView), name: "appearance-workspace-\(theme.rawValue)")
            try capture(try #require(settings.contentView), name: "appearance-settings-\(theme.rawValue)")
        }
        appearance.theme = .system
        #expect(app.appearance == nil)
        // Simulate a new resolved system appearance without changing the user's
        // macOS settings or selecting another theme in the controller.
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            app.appearance = NSAppearance(named: name)
            try await Task.sleep(for: .milliseconds(150))
            let iconName = AppTheme.system.iconName(for: app.effectiveAppearance)
            let url = try #require(appBundle.url(forResource: iconName, withExtension: "icns"))
            let expected = try #require(NSImage(contentsOf: url))
            let actual = try #require(app.applicationIconImage)
            #expect(abs(iconColor(actual).redComponent - iconColor(expected).redComponent) < 0.06)
        }
    }
}
