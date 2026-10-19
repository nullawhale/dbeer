import Foundation
import Testing
@testable import DBeer

struct EditorThemeTests {
    private func parse(_ json: String) throws -> EditorTheme {
        try EditorThemeParser.parse(data: Data(json.utf8))
    }

    @Test func hexadecimalColorsFollowVSCodeAlphaOrdering() throws {
        let short = try #require(EditorThemeColor(hex: "#1aF8"))
        #expect(short.red == 1.0 / 15)
        #expect(short.green == 10.0 / 15)
        #expect(short.blue == 1)
        #expect(short.alpha == 8.0 / 15)
        let long = try #require(EditorThemeColor(hex: "#12345680"))
        #expect(long.red == 18.0 / 255)
        #expect(long.green == 52.0 / 255)
        #expect(long.blue == 86.0 / 255)
        #expect(long.alpha == 128.0 / 255)
        #expect(EditorThemeColor(hex: "#abc")?.alpha == 1)
        #expect(EditorThemeColor(hex: "#abcdef")?.alpha == 1)
        for invalid in ["123456", "#12", "#12345", "#gggggg", "#-00000", "rgb(1,2,3)"] {
            #expect(EditorThemeColor(hex: invalid) == nil)
        }
    }

    @Test func jsoncPreservesCommentDelimitersAndTrailingCommasInStrings() throws {
        let theme = try parse(#"""
        {
          // Comment before a URL-like name.
          "name": "https://theme.example/a/*literal*/,}",
          "type": "light",
          "colors": { "editor.background": "#fff", /* inline */ },
          "tokenColors": [
            { "scope": ["keyword",], "settings": {"foreground": "#123456",}, },
          ],
        }
        """#)
        #expect(theme.name == "https://theme.example/a/*literal*/,}")
        #expect(theme.appearance == .light)
        #expect(theme.style(for: ["source.sql", "keyword.other.sql"]).foreground == EditorThemeColor(hex: "#123456"))
        #expect(throws: EditorThemeImportError.self) { try parse(##"{"colors":{"editor.background":"#fff"},/* unclosed"##) }
        #expect(throws: EditorThemeImportError.self) { try parse(##"{"name":"unterminated}"##) }
    }

    @Test func scopePrecedenceCascadesIndividualPropertiesAndHonorsSQLParents() throws {
        let theme = try parse(#"""
        { "colors": {"editor.background":"#fff"}, "tokenColors": [
          {"scope":"keyword", "settings":{"foreground":"#111111", "fontStyle":"bold"}},
          {"scope":"source.sql keyword.other.sql", "settings":{"foreground":"#222222"}},
          {"scope":["string, keyword.other.sql"], "settings":{"fontStyle":"italic"}},
          {"scope":"keyword - source.sql", "settings":{"foreground":"#ff0000"}},
          {"scope":"source.js keyword.other.sql", "settings":{"foreground":"#00ff00"}},
          {"scope":"(keyword | string)", "settings":{"foreground":"#0000ff"}}
        ] }
        """#)
        let style = theme.style(for: ["source.sql", "keyword.other.sql"])
        #expect(style.foreground == EditorThemeColor(hex: "#222222"))
        #expect(style.fontStyle == "italic")
        #expect(theme.style(for: ["source.sql", "string.quoted.single.sql"]).fontStyle == "italic")
        #expect(theme.style(for: ["source.sql", "constant.numeric.sql"]).foreground == nil)
    }

    @Test func malformedAndUnrelatedFilesAreRejected() throws {
        for text in ["", "null", "[]", "{}", ##"{"name":"A plugin", "ui":[1,2]}"##,
                     ##"{"colors":{"editor.background":"red"}}"##,
                     ##"{"tokenColors":[{"settings":{"foreground":42}}]}"##,
                     ##"{"tokenColors":false}"##] {
            #expect(throws: EditorThemeImportError.self) { try parse(text) }
        }
        #expect(throws: EditorThemeImportError.self) {
            try EditorThemeParser.parse(data: Data(repeating: 32, count: EditorThemeParser.maximumFileSize + 1))
        }
    }

    @Test func parserLimitsMatchPersistedLibraryValidation() throws {
        let rules = Array(repeating: ["scope": "keyword", "settings": ["foreground": "#123456"]] as [String: Any], count: 10_001)
        let data = try JSONSerialization.data(withJSONObject: ["tokenColors": rules])
        #expect(data.count < EditorThemeParser.maximumFileSize)
        #expect(throws: EditorThemeImportError.self) { try EditorThemeParser.parse(data: data) }
        let valid = Data(##"{"colors":{"editor.background":"#fff"}}"##.utf8)
        let theme = try EditorThemeParser.parse(data: valid, name: String(repeating: "A", count: 200))
        #expect(theme.name.count == 120)
    }

    @Test func textMatePlistMapsGlobalEditorColorsAndTokenStyles() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "name": "Plist Theme",
            "settings": [
                ["settings": ["background": "#001122", "foreground": "#aabbcc", "caret": "#ffffff",
                              "selection": "#33445580", "lineHighlight": "#223344"]],
                ["scope": "comment, string", "settings": ["foreground": "#123456", "fontStyle": "italic"]],
            ],
        ], format: .xml, options: 0)
        let theme = try EditorThemeParser.parse(data: data)
        #expect(theme.name == "Plist Theme")
        #expect(theme.appearance == .dark)
        #expect(theme.colors["editorCursor.foreground"] == EditorThemeColor(hex: "#ffffff"))
        #expect(theme.colors["editor.selectionBackground"] == EditorThemeColor(hex: "#33445580"))
        #expect(theme.style(for: ["source.sql", "comment.line.sql"]).fontStyle == "italic")
        for declaration in [
            ##"<!DOCTYPE plist [<!ENTITY value "expanded">]>"##,
            ##"<!DOCTYPE plist SYSTEM "https://example.com/theme.dtd">"##,
        ] {
            let xml = declaration + "<plist><dict><key>name</key><string>Unsafe</string></dict></plist>"
            #expect(throws: EditorThemeImportError.self) { try EditorThemeParser.parse(data: Data(xml.utf8)) }
        }
    }

    @Test func localIncludesAndReferencedTextMateFilesAreResolvedBeforeImport() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = directory.appendingPathComponent("base.json")
        try Data(##"{"name":"Base","colors":{"editor.background":"#ffffff"},"tokenColors":[{"scope":"keyword","settings":{"foreground":"#111111"}}]}"##.utf8).write(to: base)
        let tokens = try PropertyListSerialization.data(fromPropertyList: ["settings": [
            ["scope": "string", "settings": ["foreground": "#222222"]],
        ]], format: .xml, options: 0)
        try tokens.write(to: directory.appendingPathComponent("tokens.tmTheme"))
        let file = directory.appendingPathComponent("theme.json")
        try Data(##"{"name":"Child","include":"./base.json","tokenColors":"./tokens.tmTheme","colors":{"editor.foreground":"#333333"}}"##.utf8).write(to: file)
        let theme = try EditorThemeParser.load(from: file)
        #expect(theme.name == "Child")
        #expect(theme.appearance == .light)
        #expect(theme.colors["editor.foreground"] == EditorThemeColor(hex: "#333333"))
        #expect(theme.style(for: ["source.sql", "keyword.other.sql"]).foreground == EditorThemeColor(hex: "#111111"))
        #expect(theme.style(for: ["source.sql", "string.quoted.sql"]).foreground == EditorThemeColor(hex: "#222222"))
    }

    @Test func includeCyclesEscapesSymlinksRemotePathsAndOversizedFilesAreRejected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("theme", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("theme.json")
        let outside = directory.appendingPathComponent("outside.json")
        try Data(##"{"colors":{"editor.background":"#fff"}}"##.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.json"), withDestinationURL: outside)
        for path in ["./theme.json", "../outside.json", "./link.json", outside.path, "https://example.com/theme.json"] {
            let data = try JSONSerialization.data(withJSONObject: ["include": path])
            try data.write(to: file)
            #expect(throws: EditorThemeImportError.self) { try EditorThemeParser.load(from: file) }
        }
        try Data(repeating: 32, count: EditorThemeParser.maximumFileSize + 1).write(to: file)
        #expect(throws: EditorThemeImportError.self) { try EditorThemeParser.load(from: file) }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-editor-themes-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
struct EditorThemeStoreTests {
    private func context() throws -> (UserDefaults, String, URL) {
        let suite = "DBeer.EditorThemeTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (defaults, suite, directory)
    }

    @Test func bundledStandardThemesLoadAndAutomaticFollowsAppearance() throws {
        let (defaults, suite, directory) = try context()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = EditorThemeStore(defaults: defaults, directory: directory)
        #expect(store.themes.count == 8)
        #expect(Set(store.themes.map(\.id)).count == 8)
        #expect(store.themes.allSatisfy { !$0.isImported })
        #expect(store.effectiveTheme(isDark: false).id == "native-light")
        #expect(store.effectiveTheme(isDark: true).id == "native-dark")
        let dark = try #require(store.themes.first { $0.id == "vscode-dark-plus" })
        #expect(dark.appearance == .dark)
        #expect(dark.style(for: ["source.sql", "keyword.other.sql"]).foreground == EditorThemeColor(hex: "#569cd6"))
        let light = try #require(store.themes.first { $0.id == "vscode-light-plus" })
        #expect(light.appearance == .light)
        #expect(light.style(for: ["source.sql", "string.quoted.single.sql"]).foreground == EditorThemeColor(hex: "#a31515"))
        store.selectedThemeID = dark.id
        #expect(store.effectiveTheme(isDark: false).id == dark.id)
        #expect(EditorThemeStore(defaults: defaults, directory: directory).selectedThemeID == dark.id)
    }

    @Test func importedThemeSurvivesOriginalDeletionAndRemovalPersists() throws {
        let (defaults, suite, directory) = try context()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = EditorThemeStore(defaults: defaults, directory: directory.appendingPathComponent("library"))
        let source = directory.appendingPathComponent("theme.json")
        try Data(##"{"name":"My Theme","type":"light","colors":{"editor.background":"#fcfcfc"},"ignoredPrivateData":"do not copy"}"##.utf8).write(to: source)
        let imported = try store.importTheme(from: source)
        try FileManager.default.removeItem(at: source)
        let restored = EditorThemeStore(defaults: defaults, directory: directory.appendingPathComponent("library"))
        #expect(restored.selectedThemeID == imported.id)
        #expect(restored.selectedTheme == imported)
        let persisted = try String(contentsOf: directory.appendingPathComponent("library/themes.json"), encoding: .utf8)
        #expect(!persisted.contains("ignoredPrivateData"))
        #expect(!persisted.contains("do not copy"))
        try restored.removeTheme(id: imported.id)
        #expect(restored.selectedThemeID == EditorThemeStore.automaticID)
        #expect(EditorThemeStore(defaults: defaults, directory: directory.appendingPathComponent("library")).themes.count == 8)
    }

    @Test func failedImportsAndFailedWritesPreserveActiveSelection() throws {
        let (defaults, suite, directory) = try context()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("bad.json")
        try Data("{}".utf8).write(to: source)
        let store = EditorThemeStore(defaults: defaults, directory: directory.appendingPathComponent("library"))
        store.selectedThemeID = "vscode-dark-plus"
        #expect(throws: EditorThemeImportError.self) { try store.importTheme(from: source) }
        #expect(store.selectedThemeID == "vscode-dark-plus")
        #expect(store.themes.count == 8)
        let blocked = directory.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocked)
        let blockedStore = EditorThemeStore(defaults: defaults, directory: blocked)
        try Data(##"{"colors":{"editor.background":"#fff"}}"##.utf8).write(to: source)
        #expect(throws: (any Error).self) { try blockedStore.importTheme(from: source) }
        #expect(blockedStore.selectedThemeID == "vscode-dark-plus")
        #expect(blockedStore.themes.count == 8)
    }

    @Test func missingSelectionsAndCorruptLibrariesFallBackWithoutDestroyingRecoveryData() throws {
        let (defaults, suite, directory) = try context()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        defaults.set("missing-id", forKey: EditorThemeStore.preferenceKey)
        let corrupt = Data("broken theme library".utf8)
        try corrupt.write(to: directory.appendingPathComponent("themes.json"))
        let store = EditorThemeStore(defaults: defaults, directory: directory)
        #expect(store.selectedThemeID == EditorThemeStore.automaticID)
        #expect(store.loadError != nil)
        #expect(try Data(contentsOf: directory.appendingPathComponent("themes.json")) == corrupt)
        let source = directory.appendingPathComponent("valid.json")
        try Data(##"{"colors":{"editor.background":"#fff"}}"##.utf8).write(to: source)
        try store.importTheme(from: source)
        let recovery = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("themes-recovery-") })
        #expect(try Data(contentsOf: recovery) == corrupt)
        #expect(store.loadError == nil)
    }
}
