import AppKit
import Combine
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
    static let colorThemePreferenceKey = "applicationColorTheme"
    static let nativeColorThemeID = "native"

    @Published var theme: AppTheme {
        didSet {
            // Choosing a native appearance always exits the named color scheme,
            // including when the native choice itself has not changed.
            if colorThemeID != Self.nativeColorThemeID { colorThemeID = Self.nativeColorThemeID }
            else { defaults.set(Self.nativeColorThemeID, forKey: Self.colorThemePreferenceKey) }
            defaults.set(theme.rawValue, forKey: Self.preferenceKey)
            guard theme != oldValue else { return }
            if isStarted { apply() }
        }
    }

    @Published var colorThemeID: String {
        didSet {
            guard colorThemeID != oldValue else { return }
            if colorThemeID != Self.nativeColorThemeID && !editorThemes.themes.contains(where: { $0.id == colorThemeID }) {
                colorThemeID = Self.nativeColorThemeID
            }
            defaults.set(colorThemeID, forKey: Self.colorThemePreferenceKey)
            if isStarted { apply() }
        }
    }

    /// Native appearance and editor library selection have independent storage.
    var selectionID: String {
        get { selectedColorTheme?.id ?? theme.rawValue }
        set { chooseSelection(newValue) }
    }

    var selectedColorTheme: EditorTheme? { editorThemes.themes.first { $0.id == colorThemeID } }
    @Published private(set) var paletteRevision = 0

    private let defaults: UserDefaults
    private let bundle: Bundle
    let editorThemes: EditorThemeStore
    private var observation: NSKeyValueObservation?
    private var themesObservation: AnyCancellable?
    private var isStarted = false

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main, editorThemes: EditorThemeStore? = nil) {
        self.defaults = defaults
        self.bundle = bundle
        let store = editorThemes ?? EditorThemeStore(defaults: defaults)
        self.editorThemes = store
        theme = AppTheme(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .system
        let saved = defaults.string(forKey: Self.colorThemePreferenceKey) ?? Self.nativeColorThemeID
        // Missing themes (for example a temporarily unreadable library) use the
        // native appearance without destroying the user's saved selection.
        colorThemeID = store.themes.contains(where: { $0.id == saved }) ? saved : Self.nativeColorThemeID
        themesObservation = store.$themes.dropFirst().sink { [weak self] next in
            guard let self, self.colorThemeID != Self.nativeColorThemeID,
                  !next.contains(where: { $0.id == self.colorThemeID }) else { return }
            self.colorThemeID = Self.nativeColorThemeID
        }
    }

    func chooseSelection(_ id: String) {
        if let native = AppTheme(rawValue: id) {
            theme = native
        } else if editorThemes.themes.contains(where: { $0.id == id }) {
            colorThemeID = id
        } else {
            colorThemeID = Self.nativeColorThemeID
        }
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
        let colorTheme = selectedColorTheme
        AppPalette.apply(colorTheme.map(AppColorScheme.init(theme:)))
        NSApplication.shared.appearance = colorTheme.map {
            NSAppearance(named: $0.appearance == .dark ? .darkAqua : .aqua)
        } ?? theme.appearance
        paletteRevision &+= 1
        NotificationCenter.default.post(name: .applicationPaletteDidChange, object: self)
        updateIcon()
    }

    private func updateIcon() {
        let resolvedTheme: AppTheme = selectedColorTheme.map { $0.appearance == .dark ? .dark : .light } ?? theme
        let name = resolvedTheme.iconName(for: NSApplication.shared.effectiveAppearance)
        guard let url = bundle.url(forResource: name, withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}
