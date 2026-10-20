import Foundation
import SwiftUI

@MainActor
final class EditorThemeStore: ObservableObject {
    static let preferenceKey = "editorColorTheme"
    static let automaticID = "automatic"

    @Published var selectedThemeID: String {
        didSet {
            guard selectedThemeID != oldValue else { return }
            if selectedThemeID != Self.automaticID && !themes.contains(where: { $0.id == selectedThemeID }) {
                selectedThemeID = Self.automaticID
            }
            defaults.set(selectedThemeID, forKey: Self.preferenceKey)
        }
    }
    @Published private(set) var themes: [EditorTheme]
    @Published private(set) var loadError: String?

    private let defaults: UserDefaults
    private let directory: URL
    private var needsLibraryBackup = false
    private var libraryURL: URL { directory.appendingPathComponent("themes.json") }

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DBeer/EditorThemes", isDirectory: true)
        let builtins = Self.builtinThemes()
        var imported: [EditorTheme] = []
        let url = self.directory.appendingPathComponent("themes.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 16_777_217) ?? Data()
                guard data.count <= 16_777_216 else { throw EditorThemeImportError.tooLarge }
                let library = try JSONDecoder().decode(Library.self, from: data)
                guard library.version == 1, library.themes.count <= 64,
                      Set(library.themes.map(\.id)).count == library.themes.count,
                      library.themes.allSatisfy({ $0.isValidImportedTheme }) else { throw EditorThemeImportError.invalidFormat }
                imported = library.themes
            } catch {
                needsLibraryBackup = true
                loadError = "Saved editor themes could not be loaded. The existing file will be preserved as a recovery copy when you import a theme."
            }
        }
        let loadedThemes = builtins + imported
        themes = loadedThemes
        let saved = defaults.string(forKey: Self.preferenceKey) ?? Self.automaticID
        selectedThemeID = loadedThemes.contains(where: { $0.id == saved }) ? saved : Self.automaticID
    }

    var selectedTheme: EditorTheme? { themes.first { $0.id == selectedThemeID } }

    func effectiveTheme(isDark: Bool) -> EditorTheme {
        selectedTheme ?? themes.first { $0.id == (isDark ? "native-dark" : "native-light") } ?? Self.fallbackTheme(isDark: isDark)
    }

    @discardableResult
    func importTheme(from url: URL) throws -> EditorTheme {
        guard themes.filter(\.isImported).count < 64 else { throw ThemeLibraryError.limitReached }
        let theme = try EditorThemeParser.load(from: url, id: "imported-" + UUID().uuidString)
        guard theme.isValidImportedTheme else { throw EditorThemeImportError.invalidFormat }
        let next = themes + [theme]
        try persist(next)
        themes = next
        selectedThemeID = theme.id
        loadError = nil
        return theme
    }

    func removeTheme(id: String) throws {
        guard themes.contains(where: { $0.id == id && $0.isImported }) else { return }
        let next = themes.filter { $0.id != id }
        try persist(next)
        themes = next
        if selectedThemeID == id { selectedThemeID = Self.automaticID }
        loadError = nil
    }

    private func persist(_ themes: [EditorTheme]) throws {
        let data = try JSONEncoder().encode(Library(version: 1, themes: themes.filter(\.isImported)))
        guard data.count <= 16_777_216 else { throw EditorThemeImportError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if needsLibraryBackup, FileManager.default.fileExists(atPath: libraryURL.path) {
            try FileManager.default.copyItem(at: libraryURL,
                to: directory.appendingPathComponent("themes-recovery-" + UUID().uuidString + ".json"))
        }
        try data.write(to: libraryURL, options: .atomic)
        needsLibraryBackup = false
    }

    private struct Library: Codable {
        let version: Int
        let themes: [EditorTheme]
    }

    private enum ThemeLibraryError: Error, LocalizedError {
        case limitReached
        var errorDescription: String? { "The editor theme library is full. Remove an imported theme before adding another." }
    }

    static func builtinThemes() -> [EditorTheme] {
        let resources = [
            ("native-light", "dbeer-light", "json"), ("native-dark", "dbeer-dark", "json"),
            ("vscode-light-plus", "light_plus", "json"), ("vscode-dark-plus", "dark_plus", "json"),
            ("solarized-light", "solarized-light-color-theme", "json"), ("solarized-dark", "solarized-dark-color-theme", "json"),
            ("jetbrains-light", "jetbrains-default", "icls"), ("jetbrains-darcula", "jetbrains-darcula", "icls"),
        ]
        return resources.compactMap { id, file, fileExtension in
            guard let url = Bundle.module.url(forResource: file, withExtension: fileExtension, subdirectory: "EditorThemes"),
                  let theme = try? EditorThemeParser.load(from: url, id: id, isImported: false) else { return nil }
            if id == "jetbrains-light" {
                return EditorTheme(id: theme.id, name: "JetBrains Light", appearance: theme.appearance,
                    colors: theme.colors, tokenRules: theme.tokenRules, isImported: false)
            }
            return theme
        }
    }

    private static func fallbackTheme(isDark: Bool) -> EditorTheme {
        EditorTheme(id: isDark ? "native-dark" : "native-light", name: isDark ? "DBeer Dark" : "DBeer Light",
            appearance: isDark ? .dark : .light,
            colors: ["editor.background": EditorThemeColor(hex: isDark ? "#1E1E1E" : "#FFFFFF")!,
                     "editor.foreground": EditorThemeColor(hex: isDark ? "#FFFFFF" : "#000000")!],
            tokenRules: [], isImported: false)
    }
}

private extension EditorTheme {
    var isValidImportedTheme: Bool {
        guard isImported, id.hasPrefix("imported-"), UUID(uuidString: String(id.dropFirst(9))) != nil,
              !name.isEmpty, name.count <= 120, tokenRules.count <= 10_000,
              colors.count <= 10_000 else { return false }
        let allColors = Array(colors.values) + tokenRules.flatMap { [$0.style.foreground, $0.style.background].compactMap { $0 } }
        return allColors.allSatisfy { color in
            [color.red, color.green, color.blue, color.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
        }
    }
}
