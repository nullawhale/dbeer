import AppKit
import Foundation
import SwiftUI

enum AppColorRole: CaseIterable, Hashable, Sendable {
    case background, window, sidebar, panel, control
    case text, secondaryText, border, selection, accent, selectionText
}

/// A value snapshot of a library theme. Dynamic NSColor providers can read it
/// from AppKit drawing threads without reaching into a main-actor store.
struct AppColorScheme: Equatable, Sendable {
    let themeID: String
    let appearance: EditorThemeAppearance
    private let colors: [AppColorRole: EditorThemeColor]

    init(theme: EditorTheme) {
        themeID = theme.id
        appearance = theme.appearance
        let dark = theme.appearance == .dark
        let base = EditorThemeColor(hex: dark ? "#1E1E1E" : "#FFFFFF")!
        let background = (theme.colors["editor.background"] ?? base).composited(over: base)
        let foreground = (theme.colors["foreground"] ?? theme.colors["editor.foreground"] ??
            EditorThemeColor(hex: dark ? "#FFFFFF" : "#000000")!).composited(over: background)

        func surface(_ keys: [String], fallback: EditorThemeColor) -> EditorThemeColor {
            (keys.lazy.compactMap { theme.colors[$0] }.first ?? fallback).composited(over: background)
        }
        let sidebar = surface(["sideBar.background", "editorGutter.background"],
            fallback: background.mixed(with: foreground, fraction: 0.035))
        let panel = surface(["panel.background"], fallback: background)
        let window = surface(["titleBar.activeBackground"], fallback: background)
        let control = surface(["input.background", "dropdown.background", "editorWidget.background"],
            fallback: background.mixed(with: foreground, fraction: 0.07))
        let surfaces = [background, sidebar, panel, window, control]
        let text = foreground.readable(on: surfaces, minimumContrast: 4.5)
        let secondary = surface(["descriptionForeground", "editorLineNumber.foreground"],
            fallback: text.mixed(with: background, fraction: 0.28)).readable(on: surfaces, minimumContrast: 4.5)
        let accentSource = theme.colors["focusBorder"] ?? theme.colors["button.background"] ??
            theme.style(for: ["source.sql", "keyword.control.sql"]).foreground ??
            EditorThemeColor(hex: dark ? "#73B7FF" : "#0066CC")!
        let accent = accentSource.composited(over: background).readable(on: [background, control], minimumContrast: 3)
        let selection = surface(["list.activeSelectionBackground", "editor.selectionBackground"],
            fallback: accent.mixed(with: background, fraction: 0.6))
        let selectionText = surface(["list.activeSelectionForeground", "editor.selectionForeground"],
            fallback: text).readable(on: [selection], minimumContrast: 4.5)
        let border = surface(["panel.border", "sideBar.border", "input.border", "contrastBorder"],
            fallback: text.mixed(with: background, fraction: 0.77))
        colors = [.background: background, .window: window, .sidebar: sidebar, .panel: panel, .control: control,
                  .text: text, .secondaryText: secondary, .border: border, .selection: selection,
                  .accent: accent, .selectionText: selectionText]
    }

    subscript(_ role: AppColorRole) -> EditorThemeColor { colors[role]! }
}

extension Notification.Name {
    static let applicationPaletteDidChange = Notification.Name("DBeerApplicationPaletteDidChange")
}

enum AppPalette {
    private static let storage = PaletteStorage()
    static var isCustom: Bool { storage.snapshot != nil }

    private static let dynamicColors = Dictionary(uniqueKeysWithValues: AppColorRole.allCases.map { ($0, dynamic($0)) })

    static var backgroundNS: NSColor { nsColor(.background) }
    static var windowNS: NSColor { nsColor(.window) }
    static var sidebarNS: NSColor { nsColor(.sidebar) }
    static var panelNS: NSColor { nsColor(.panel) }
    static var controlNS: NSColor { nsColor(.control) }
    static var textNS: NSColor { nsColor(.text) }
    static var secondaryTextNS: NSColor { nsColor(.secondaryText) }
    static var borderNS: NSColor { nsColor(.border) }
    static var selectionNS: NSColor { nsColor(.selection) }
    static var accentNS: NSColor { nsColor(.accent) }
    static var selectionTextNS: NSColor { nsColor(.selectionText) }

    // Concrete custom values let SwiftUI distinguish schemes with the same
    // Aqua appearance; their identity must not depend only on a dynamic color.
    static var background: Color { Color(nsColor: backgroundNS) }
    static var window: Color { Color(nsColor: windowNS) }
    static var sidebar: Color { Color(nsColor: sidebarNS) }
    static var panel: Color { Color(nsColor: panelNS) }
    static var control: Color { Color(nsColor: controlNS) }
    static var text: Color { Color(nsColor: textNS) }
    static var secondaryText: Color { Color(nsColor: secondaryTextNS) }
    static var border: Color { Color(nsColor: borderNS) }
    static var selection: Color { Color(nsColor: selectionNS) }
    static var accent: Color { Color(nsColor: accentNS) }
    static var selectionText: Color { Color(nsColor: selectionTextNS) }

    static func nsColor(_ role: AppColorRole) -> NSColor {
        if let scheme = storage.snapshot { return scheme[role].nsColor }
        return dynamicColors[role]!
    }

    @MainActor
    static func apply(_ scheme: AppColorScheme?) { storage.snapshot = scheme }

    private static func dynamic(_ role: AppColorRole) -> NSColor {
        NSColor(name: nil) { appearance in
            if let scheme = storage.snapshot { return scheme[role].nsColor }
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            switch role {
            case .background:
                return dark ? NSColor(red: 0.105, green: 0.11, blue: 0.12, alpha: 1)
                    : NSColor(red: 0.97, green: 0.965, blue: 0.95, alpha: 1)
            case .accent:
                return dark ? NSColor(red: 0.91, green: 0.66, blue: 0.28, alpha: 1)
                    : NSColor(red: 0.61, green: 0.36, blue: 0.08, alpha: 1)
            case .window: return NSColor.windowBackgroundColor
            case .sidebar: return NSColor.controlBackgroundColor
            case .panel: return NSColor.textBackgroundColor
            case .control: return NSColor.controlBackgroundColor
            case .text: return NSColor.labelColor
            case .secondaryText: return NSColor.secondaryLabelColor
            case .border: return NSColor.separatorColor
            case .selection: return NSColor.selectedContentBackgroundColor
            case .selectionText: return NSColor.selectedTextColor
            }
        }
    }
}

private final class PaletteStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppColorScheme?

    var snapshot: AppColorScheme? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

private extension EditorThemeColor {
    func composited(over background: EditorThemeColor) -> EditorThemeColor {
        EditorThemeColor(red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha))
    }

    func mixed(with other: EditorThemeColor, fraction: Double) -> EditorThemeColor {
        EditorThemeColor(red: red + (other.red - red) * fraction,
            green: green + (other.green - green) * fraction,
            blue: blue + (other.blue - blue) * fraction)
    }

    var luminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return channel(red) * 0.2126 + channel(green) * 0.7152 + channel(blue) * 0.0722
    }

    func contrast(with other: EditorThemeColor) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }

    /// Sparse editor-only themes have no workbench text contract. Preserve their
    /// hues where possible, then move toward the more readable neutral endpoint.
    func readable(on surfaces: [EditorThemeColor], minimumContrast: Double) -> EditorThemeColor {
        func score(_ color: EditorThemeColor) -> Double { surfaces.map { color.contrast(with: $0) }.min() ?? 21 }
        guard score(self) < minimumContrast else { return self }
        let black = EditorThemeColor(red: 0, green: 0, blue: 0)
        let white = EditorThemeColor(red: 1, green: 1, blue: 1)
        let endpoint = score(black) > score(white) ? black : white
        guard score(endpoint) >= minimumContrast else { return endpoint }
        var low = 0.0
        var high = 1.0
        for _ in 0..<20 {
            let fraction = (low + high) / 2
            if score(mixed(with: endpoint, fraction: fraction)) < minimumContrast { low = fraction }
            else { high = fraction }
        }
        return mixed(with: endpoint, fraction: high)
    }
}
