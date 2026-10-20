import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Check rendered native chrome, whose vibrant foregrounds cannot be verified
/// by comparing the application's palette values with each other.
@Suite(.serialized)
@MainActor
struct NativeThemeContrastTests {
    private func context() throws -> (UserDefaults, String, URL) {
        let domain = "dev.dbeer.native-contrast-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(domain, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (defaults, domain, directory)
    }

    private func host(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: content.bounds, styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return window
    }

    private static func bitmap(_ window: NSWindow) throws -> NSBitmapImageRep {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // Capture only this process's test-owned native windows. WindowServer
        // preserves toolbar/menu vibrancy that NSView.cacheDisplay loses.
        // This public macOS 14 API remains available on newer systems after
        // newer SDKs removed its Swift declaration.
        typealias WindowCapture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let library = try #require(dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW))
        defer { dlclose(library) }
        let capture = unsafeBitCast(try #require(dlsym(library, "CGWindowListCreateImage")), to: WindowCapture.self)
        let image = try #require(capture(.null, CGWindowListOption.optionIncludingWindow.rawValue,
            UInt32(window.windowNumber), CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
        return NSBitmapImageRep(cgImage: image)
    }

    private static func crop(_ image: NSBitmapImageRep, screenRect: NSRect, window: NSWindow) throws -> NSBitmapImageRep {
        let frame = window.frame
        let scaleX = CGFloat(image.pixelsWide) / frame.width
        let scaleY = CGFloat(image.pixelsHigh) / frame.height
        let rect = CGRect(x: (screenRect.minX - frame.minX) * scaleX,
            y: (frame.maxY - screenRect.maxY) * scaleY,
            width: screenRect.width * scaleX, height: screenRect.height * scaleY).integral
        let cropped = try #require(image.cgImage?.cropping(to: rect))
        return NSBitmapImageRep(cgImage: cropped)
    }

    private static func capture(_ image: NSBitmapImageRep, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    /// Compare visible ink with the dominant native background. Insets exclude
    /// the window shadow/border, and contrast excludes subtle material noise.
    private static func foregroundPixels(_ image: NSBitmapImageRep, inset: Int = 0,
                                         minimumContrast: Double = 3) -> Int {
        func luminance(_ color: NSColor) -> Double {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return linear(color.redComponent) * 0.2126 + linear(color.greenComponent) * 0.7152 +
                linear(color.blueComponent) * 0.0722
        }
        var colors: [NSColor] = []
        var bins: [Int: (count: Int, color: NSColor)] = [:]
        guard image.pixelsWide > inset * 2, image.pixelsHigh > inset * 2 else { return 0 }
        for y in inset..<(image.pixelsHigh - inset) {
            for x in inset..<(image.pixelsWide - inset) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.95 else { continue }
                colors.append(color)
                let key = Int(color.redComponent * 15) * 256 + Int(color.greenComponent * 15) * 16 +
                    Int(color.blueComponent * 15)
                bins[key] = ((bins[key]?.count ?? 0) + 1, color)
            }
        }
        guard let background = bins.values.max(by: { $0.count < $1.count })?.color else { return 0 }
        let backgroundLuminance = luminance(background)
        return colors.filter { color in
            let value = luminance(color)
            return (max(value, backgroundLuminance) + 0.05) / (min(value, backgroundLuminance) + 0.05) >= minimumContrast
        }.count
    }

    @Test func globalControlPolicyPreservesRenderedLightNativeMenu() async throws {
        let (defaults, domain, directory) = try context()
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        let originalIcon = application.applicationIconImage
        let appearance = AppAppearance(defaults: defaults,
            editorThemes: EditorThemeStore(defaults: defaults, directory: directory))
        appearance.chooseSelection("vscode-light-plus")
        appearance.start()
        defer {
            appearance.chooseSelection("system")
            application.appearance = originalAppearance
            application.applicationIconImage = originalIcon
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        let window = host(content)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(120))
        let menu = NSMenu(title: "DBeer")
        menu.autoenablesItems = false
        for title in ["About DBeer", "Settings…", "Hide DBeer", "Quit DBeer"] {
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        let state = MenuCapture(existingWindows: Set(application.windows.map(ObjectIdentifier.init)))
        let timer = Timer(timeInterval: 0.06, target: state, selector: #selector(MenuCapture.tick(_:)),
            userInfo: nil, repeats: true)
        state.menu = menu
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate(); menu.cancelTracking() }
        menu.popUp(positioning: menu.item(at: 1), at: NSPoint(x: 30, y: 140), in: content)
        if let error = state.error { throw error }
        let before = try #require(state.before, "The native menu did not expose a rendered tracking window")
        let after = try #require(state.after, "The global policy did not complete during menu tracking")
        try Self.capture(before, name: "native-light-menu-before-policy")
        try Self.capture(after, name: "native-light-menu-after-policy")
        let referenceInk = Self.foregroundPixels(before, inset: 12)
        #expect(referenceInk >= 40, "The reference menu must contain visible native text")
        #expect(Self.foregroundPixels(after, inset: 12) >= referenceInk * 8 / 10,
            "Applying application control styling erased native menu text")
    }

    @MainActor
    private final class MenuCapture: NSObject {
        let existingWindows: Set<ObjectIdentifier>
        let deadline = Date().addingTimeInterval(3)
        let policy = NativeButtonFocusPolicy()
        var menu: NSMenu?
        var before: NSBitmapImageRep?
        var after: NSBitmapImageRep?
        var error: Error?

        init(existingWindows: Set<ObjectIdentifier>) { self.existingWindows = existingWindows }

        @objc func tick(_ timer: Timer) {
            guard Date() < deadline else { menu?.cancelTracking(); timer.invalidate(); return }
            guard let window = NSApplication.shared.windows.first(where: {
                !existingWindows.contains(ObjectIdentifier($0)) && $0.isVisible &&
                    $0.level.rawValue >= NSWindow.Level.mainMenu.rawValue
            }) else { return }
            do {
                if before == nil {
                    before = try NativeThemeContrastTests.bitmap(window)
                    policy.start()
                    // Explicit application makes the regression independent of
                    // the timing of AppKit's global window-update notification.
                    policy.apply(to: window)
                } else {
                    after = try NativeThemeContrastTests.bitmap(window)
                    menu?.cancelTracking()
                    timer.invalidate()
                }
            } catch {
                self.error = error
                menu?.cancelTracking()
                timer.invalidate()
            }
        }
    }

    @Test func nativeLightSelectionMaterialPreservesHighlightedTextAndTemplateSymbol() async throws {
        let (defaults, domain, directory) = try context()
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        let originalIcon = application.applicationIconImage
        let appearance = AppAppearance(defaults: defaults,
            editorThemes: EditorThemeStore(defaults: defaults, directory: directory))
        appearance.chooseSelection("light")
        appearance.start()
        defer {
            appearance.chooseSelection("system")
            application.appearance = originalAppearance
            application.applicationIconImage = originalIcon
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        let selection = NSVisualEffectView(frame: NSRect(x: 20, y: 25, width: 360, height: 100))
        selection.material = .selection
        selection.blendingMode = .withinWindow
        selection.state = .active
        selection.isEmphasized = true
        let label = NSTextField(labelWithString: "Selected color scheme")
        label.frame = NSRect(x: 72, y: 38, width: 270, height: 24)
        label.font = .systemFont(ofSize: 17)
        label.textColor = .alternateSelectedControlTextColor
        let symbol = NSImageView(frame: NSRect(x: 20, y: 34, width: 32, height: 32))
        symbol.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Appearance")
        symbol.contentTintColor = .alternateSelectedControlTextColor
        selection.addSubview(label)
        selection.addSubview(symbol)
        content.addSubview(selection)
        let window = host(content)
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()
        var referenceInk = 0
        var nativeChildren: [ObjectIdentifier] = []
        for theme in ["light", "vscode-light-plus", "solarized-light", "jetbrains-light"] {
            if theme != "light" {
                appearance.chooseSelection("dark")
                try await Task.sleep(for: .milliseconds(60))
            }
            appearance.chooseSelection(theme)
            try await Task.sleep(for: .milliseconds(180))
            if theme == "light" { nativeChildren = selection.subviews.map(ObjectIdentifier.init) }
            policy.apply(to: window)
            let image = try Self.bitmap(window)
            try Self.capture(image, name: "native-selected-material-\(theme)")
            let screen = window.convertToScreen(selection.convert(selection.bounds.insetBy(dx: 8, dy: 8), to: nil))
            let selectedRow = try Self.crop(image, screenRect: screen, window: window)
            // Compare against AppKit's own selected material, whose native
            // accent can be lighter than a standard text contrast target.
            let ink = Self.foregroundPixels(selectedRow, minimumContrast: 2)
            if theme == "light" {
                referenceInk = ink
                #expect(ink >= 40, "The native selected material must render visible text and a symbol")
            } else {
                #expect(ink >= referenceInk * 8 / 10,
                    "Application styling obscured the native selected material behind its light foreground")
            }
            // A visual-effect view owns compositing of its material and its
            // emphasized foreground; application backgrounds belong outside it.
            #expect(selection.subviews.map(ObjectIdentifier.init) == nativeChildren)
        }
    }

    @Test func nativeSettingsToolbarRendersAcrossDarkToLightTransitions() async throws {
        let (defaults, domain, directory) = try context()
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        let originalIcon = application.applicationIconImage
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let appearance = AppAppearance(defaults: defaults,
            editorThemes: EditorThemeStore(defaults: defaults, directory: directory))
        appearance.chooseSelection("light")
        appearance.start()
        defer {
            appearance.chooseSelection("system")
            application.appearance = originalAppearance
            application.applicationIconImage = originalIcon
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        // Settings scenes translate their top-level SwiftUI TabView into a
        // native toolbar. A TabView in an ordinary NSHostingView instead uses
        // compact tabs and does not exercise the symbol rendering at issue.
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for (title, symbol) in [("Appearance", "paintpalette"), ("Shortcuts", "keyboard")] {
            let controller = NSHostingController(rootView: Color.clear
                .frame(width: 650, height: 300).applicationTheme(appearance: appearance))
            controller.title = title
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 650, height: 300))
        window.makeKeyAndOrderFront(nil)
        window.toolbar?.displayMode = .iconAndLabel
        application.activate(ignoringOtherApps: true)
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()
        for theme in ["light", "vscode-light-plus", "solarized-light", "jetbrains-light"] {
            if theme != "light" {
                appearance.chooseSelection("dark")
                try await Task.sleep(for: .milliseconds(60))
            }
            appearance.chooseSelection(theme)
            try await Task.sleep(for: .milliseconds(180))
            window.contentView?.layoutSubtreeIfNeeded()
            policy.apply(to: window)
            let image = try Self.bitmap(window)
            try Self.capture(image, name: "settings-native-toolbar-\(theme)")
            #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
            #expect(window.toolbar?.visibleItems?.isEmpty == false)
            #expect(image.pixelsWide > 0 && image.pixelsHigh > 0)
        }
    }
}
