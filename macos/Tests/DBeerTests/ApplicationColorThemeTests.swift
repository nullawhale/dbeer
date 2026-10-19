import AppKit
import Foundation
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct ApplicationColorThemeTests {
    private func withLibrary(_ body: (UserDefaults, EditorThemeStore, URL) throws -> Void) throws {
        let domain = "dev.dbeer.application-color-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(domain, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(defaults, EditorThemeStore(defaults: defaults, directory: directory), directory)
    }

    @Test func applicationSelectionPersistsIndependentlyFromEditorAndNativeAppearance() throws {
        try withLibrary { defaults, store, _ in
            let appearance = AppAppearance(defaults: defaults, editorThemes: store)
            appearance.theme = .light
            store.selectedThemeID = "jetbrains-darcula"
            appearance.selectionID = "solarized-dark"
            #expect(appearance.theme == .light)
            #expect(appearance.selectionID == "solarized-dark")
            #expect(appearance.selectedColorTheme?.appearance == .dark)
            #expect(store.selectedThemeID == "jetbrains-darcula")
            #expect(defaults.string(forKey: AppAppearance.preferenceKey) == "light")
            #expect(defaults.string(forKey: AppAppearance.colorThemePreferenceKey) == "solarized-dark")
            let restored = AppAppearance(defaults: defaults, editorThemes: store)
            #expect(restored.selectionID == "solarized-dark")
            #expect(restored.selectedColorTheme?.id == "solarized-dark")
            // Re-selecting the same native base still exits the named scheme.
            appearance.theme = .light
            #expect(appearance.selectionID == "light")
            #expect(appearance.selectedColorTheme == nil)
            #expect(store.selectedThemeID == "jetbrains-darcula")
            appearance.selectionID = "vscode-dark-plus"
            appearance.selectionID = "system"
            #expect(appearance.selectionID == "system")
            #expect(appearance.colorThemeID == AppAppearance.nativeColorThemeID)
        }
    }

    @Test func missingSavedSchemeFallsBackWithoutRewritingMetadataOrGlobalAppearance() throws {
        try withLibrary { defaults, store, _ in
            let originalAppearance = NSApplication.shared.appearance
            let wasCustom = AppPalette.isCustom
            defaults.set("imported-missing", forKey: AppAppearance.colorThemePreferenceKey)
            defaults.set("dark", forKey: AppAppearance.preferenceKey)
            let appearance = AppAppearance(defaults: defaults, editorThemes: store)
            #expect(appearance.selectionID == "dark")
            #expect(appearance.selectedColorTheme == nil)
            #expect(defaults.string(forKey: AppAppearance.colorThemePreferenceKey) == "imported-missing")
            appearance.selectionID = "dark"
            #expect(defaults.string(forKey: AppAppearance.colorThemePreferenceKey) == AppAppearance.nativeColorThemeID)
            appearance.selectionID = "solarized-light"
            #expect(NSApplication.shared.appearance === originalAppearance)
            #expect(AppPalette.isCustom == wasCustom)
            #expect(appearance.paletteRevision == 0)
        }
    }

    @Test func removingApplicationSchemePreservesDifferentExplicitEditorChoice() throws {
        try withLibrary { defaults, store, directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = directory.appendingPathComponent("custom.json")
            try Data("""
                {"name":"Custom","type":"dark","colors":{"editor.background":"#112233","editor.foreground":"#EEF2F7"}}
                """.utf8).write(to: source)
            let imported = try store.importTheme(from: source)
            let appearance = AppAppearance(defaults: defaults, editorThemes: store)
            appearance.selectionID = imported.id
            store.selectedThemeID = "solarized-light"
            try store.removeTheme(id: imported.id)
            #expect(appearance.selectionID == "system")
            #expect(appearance.selectedColorTheme == nil)
            #expect(defaults.string(forKey: AppAppearance.colorThemePreferenceKey) == AppAppearance.nativeColorThemeID)
            #expect(store.selectedThemeID == "solarized-light")
        }
    }

    @Test func workbenchColorsAreMappedAndTransparentSurfacesAreComposited() throws {
        let theme = try EditorThemeParser.parse(data: Data("""
            {"name":"Workbench","type":"dark","colors":{
                "editor.background":"#102030","editor.foreground":"#FFFFFF",
                "sideBar.background":"#203040","panel.background":"#304050",
                "titleBar.activeBackground":"#182838","input.background":"#FFFFFF20",
                "focusBorder":"#66AAFF","list.activeSelectionBackground":"#005599",
                "list.activeSelectionForeground":"#FFFFFF","panel.border":"#456789"}}
            """.utf8))
        let palette = AppColorScheme(theme: theme)
        #expect(palette[.background] == EditorThemeColor(hex: "#102030"))
        #expect(palette[.sidebar] == EditorThemeColor(hex: "#203040"))
        #expect(palette[.panel] == EditorThemeColor(hex: "#304050"))
        #expect(palette[.window] == EditorThemeColor(hex: "#182838"))
        #expect(palette[.border] == EditorThemeColor(hex: "#456789"))
        #expect(palette[.selection] == EditorThemeColor(hex: "#005599"))
        #expect(palette[.selectionText] == EditorThemeColor(hex: "#FFFFFF"))
        let opacity = 32.0 / 255
        #expect(abs(palette[.control].red - (opacity + 16.0 / 255 * (1 - opacity))) < 0.00001)
        #expect(AppColorRole.allCases.allSatisfy { palette[$0].alpha == 1 })
    }

    @Test func sparseTransparentThemesProduceReadableOpaqueFallbackColors() throws {
        for type in ["light", "dark"] {
            let theme = try EditorThemeParser.parse(data: Data("""
                {"name":"Sparse","type":"\(type)","colors":{
                    "editor.background":"#12340000","editor.foreground":"#FFFFFF00",
                    "editor.selectionBackground":"#00000000","editorLineNumber.foreground":"#88888801"}}
                """.utf8))
            let palette = AppColorScheme(theme: theme)
            for role in AppColorRole.allCases {
                let color = palette[role]
                #expect(color.alpha == 1)
                #expect([color.red, color.green, color.blue].allSatisfy { $0.isFinite && (0...1).contains($0) })
            }
            for surface in [AppColorRole.background, .window, .sidebar, .panel, .control] {
                #expect(contrast(palette[.text], palette[surface]) >= 4.49)
                #expect(contrast(palette[.secondaryText], palette[surface]) >= 4.49)
            }
            #expect(contrast(palette[.selectionText], palette[.selection]) >= 4.49)
        }
    }

    @Test func everyBundledSchemeSuppliesApplicationSurfacesWithoutModifyingItsEditorColors() {
        let themes = EditorThemeStore.builtinThemes()
        #expect(themes.count == 8)
        for theme in themes {
            let original = theme.colors
            let palette = AppColorScheme(theme: theme)
            #expect(palette.themeID == theme.id)
            #expect(palette.appearance == theme.appearance)
            #expect(AppColorRole.allCases.allSatisfy { palette[$0].alpha == 1 })
            #expect(contrast(palette[.text], palette[.background]) >= 4.49)
            #expect(contrast(palette[.selectionText], palette[.selection]) >= 4.49)
            #expect(theme.colors == original)
        }
    }

    private func contrast(_ first: EditorThemeColor, _ second: EditorThemeColor) -> Double {
        func luminance(_ color: EditorThemeColor) -> Double {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return linear(color.red) * 0.2126 + linear(color.green) * 0.7152 + linear(color.blue) * 0.0722
        }
        let firstValue = luminance(first)
        let secondValue = luminance(second)
        return (max(firstValue, secondValue) + 0.05) / (min(firstValue, secondValue) + 0.05)
    }
}
