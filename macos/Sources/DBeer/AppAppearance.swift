import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    func iconName(for appearance: NSAppearance) -> String {
        let isDark = self == .dark || (self == .system &&
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        return isDark ? "AppIconDark" : "AppIcon"
    }
}

@MainActor
final class AppAppearance: ObservableObject {
    static let preferenceKey = "appearanceTheme"

    @Published var theme: AppTheme {
        didSet {
            guard theme != oldValue else { return }
            defaults.set(theme.rawValue, forKey: Self.preferenceKey)
            if isStarted { apply() }
        }
    }

    private let defaults: UserDefaults
    private let bundle: Bundle
    private var observation: NSKeyValueObservation?
    private var isStarted = false

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
        theme = AppTheme(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .system
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        observation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateIcon() }
        }
        apply()
    }

    private func apply() {
        NSApplication.shared.appearance = theme.appearance
        updateIcon()
    }

    private func updateIcon() {
        let name = theme.iconName(for: NSApplication.shared.effectiveAppearance)
        guard let url = bundle.url(forResource: name, withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}

enum AppPalette {
    static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.105, green: 0.11, blue: 0.12, alpha: 1)
            : NSColor(red: 0.97, green: 0.965, blue: 0.95, alpha: 1)
    })

    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.91, green: 0.66, blue: 0.28, alpha: 1)
            : NSColor(red: 0.61, green: 0.36, blue: 0.08, alpha: 1)
    })
}
