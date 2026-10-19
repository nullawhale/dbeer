import Foundation
import Testing
@testable import DBeer

struct JetBrainsEditorThemeTests {
    private func parse(_ xml: String) throws -> EditorTheme {
        try JetBrainsEditorThemeParser.parse(data: Data(xml.utf8), id: "fixture")
    }

    @Test func officialDefaultAndDarculaParentsProvideActualEditorColors() throws {
        let light = try parse("<scheme name=\"Light copy\" parent_scheme=\"Default\" version=\"142\" />")
        let dark = try parse("<scheme name=\"Dark copy\" parent_scheme=\"Darcula\" version=\"142\" />")
        #expect(light.name == "Light copy")
        #expect(light.appearance == .light)
        #expect(light.colors["editor.background"] == EditorThemeColor(hex: "#FFFFFF"))
        #expect(light.colors["editor.foreground"] == EditorThemeColor(hex: "#000000"))
        #expect(dark.appearance == .dark)
        #expect(dark.colors["editor.background"] == EditorThemeColor(hex: "#2B2B2B"))
        #expect(dark.colors["editor.foreground"] == EditorThemeColor(hex: "#A9B7C6"))
        #expect(dark.style(for: ["source.sql", "keyword.control.sql"]).foreground == EditorThemeColor(hex: "#CC7832"))
        #expect(dark.style(for: ["source.sql", "string.quoted.single.sql"]).foreground == EditorThemeColor(hex: "#6A8759"))
        #expect(dark.style(for: ["source.sql", "constant.numeric.sql"]).foreground == EditorThemeColor(hex: "#6897BB"))
        #expect(dark.style(for: ["source.sql", "comment.block.sql"]).foreground == EditorThemeColor(hex: "#808080"))
    }

    @Test func exportedSQLAttributesOverrideLanguageDefaultsAndKeepRGBAndFontSemantics() throws {
        let theme = try parse("""
        <?xml version="1.0" encoding="UTF-8"?>
        <scheme name="DataGrip export" parent_scheme="Darcula" version="142">
          <colors>
            <option name="CARET_COLOR" value="ff" />
            <option name="SELECTION_BACKGROUND" value="12345678" />
            <option name="LINE_NUMBERS_COLOR" value="456789" />
          </colors>
          <attributes>
            <option name="DEFAULT_KEYWORD"><value><option name="FOREGROUND" value="112233" /><option name="FONT_TYPE" value="1" /></value></option>
            <option name="SQL_KEYWORD"><value><option name="FOREGROUND" value="abcdef" /><option name="FONT_TYPE" value="2" /></value></option>
            <option name="SQL_STRING" baseAttributes="DEFAULT_KEYWORD" />
            <option name="SQL_COMMENT"><value><option name="FOREGROUND" value="0" /><option name="FONT_TYPE" value="3" /></value></option>
            <option name="SQL_NUMBER"><value /></option>
          </attributes>
        </scheme>
        """)
        let keyword = theme.style(for: ["source.sql", "keyword.control.sql"])
        #expect(keyword.foreground == EditorThemeColor(hex: "#ABCDEF"))
        #expect(keyword.fontStyle == "italic")
        let string = theme.style(for: ["source.sql", "string.quoted.single.sql"])
        #expect(string.foreground == EditorThemeColor(hex: "#112233"))
        #expect(string.fontStyle == "bold")
        for scope in ["comment.line.sql", "comment.line.double-dash.sql", "comment.block.sql"] {
            let comment = theme.style(for: ["source.sql", scope])
            #expect(comment.foreground == EditorThemeColor(hex: "#000000"))
            #expect(comment.fontStyle == "bold italic")
        }
        let number = theme.style(for: ["source.sql", "constant.numeric.sql"])
        #expect(number.foreground == theme.colors["editor.foreground"])
        #expect(number.fontStyle == "")
        #expect(theme.colors["editorCursor.foreground"] == EditorThemeColor(hex: "#0000FF"))
        #expect(theme.colors["editor.selectionBackground"] == EditorThemeColor(hex: "#12345678"))
        #expect(theme.colors["editorLineNumber.foreground"] == EditorThemeColor(hex: "#456789"))
    }

    @Test func selfContainedSchemesAndClearedInheritedFontStylesImportWithoutAnIDE() throws {
        let theme = try parse("""
        <scheme name="Standalone" version="142">
          <attributes>
            <option name="TEXT"><value><option name="FOREGROUND" value="f0f0f0" /><option name="BACKGROUND" value="101010" /></value></option>
            <option name="DEFAULT_KEYWORD"><value><option name="FOREGROUND" value="00ff00" /><option name="FONT_TYPE" value="3" /></value></option>
            <option name="SQL_KEYWORD"><value><option name="FOREGROUND" value="ff0000" /><option name="FONT_TYPE" value="0" /></value></option>
          </attributes>
        </scheme>
        """)
        #expect(theme.appearance == .dark)
        #expect(theme.colors["editor.background"] == EditorThemeColor(hex: "#101010"))
        #expect(theme.style(for: ["source.sql", "keyword.control.sql"]).fontStyle == "")
        #expect(theme.style(for: ["source.sql", "keyword.control.sql"]).foreground == EditorThemeColor(hex: "#FF0000"))
    }

    @Test func unknownParentsMalformedColorsAndAttributeCyclesAreRejected() {
        #expect(throws: JetBrainsThemeImportError.self) {
            try parse("<scheme name=\"Unavailable\" parent_scheme=\"Custom plugin parent\" />")
        }
        #expect(throws: EditorThemeImportError.self) {
            try parse("<scheme><attributes><option name=\"DEFAULT_KEYWORD\"><value><option name=\"FOREGROUND\" value=\"oops\" /></value></option></attributes></scheme>")
        }
        #expect(throws: EditorThemeImportError.self) {
            try parse("<scheme><attributes><option name=\"DEFAULT_KEYWORD\" baseAttributes=\"SQL_KEYWORD\" /><option name=\"SQL_KEYWORD\" baseAttributes=\"DEFAULT_KEYWORD\" /></attributes></scheme>")
        }
        #expect(throws: EditorThemeImportError.self) { try parse("<theme />") }
        #expect(throws: EditorThemeImportError.self) { try parse("<scheme><attributes></scheme>") }
    }

    @Test func xmlDoesNotResolveLocalExternalOrExpandingEntities() {
        for xml in [
            "<!DOCTYPE scheme SYSTEM 'https://example.com/theme.dtd'><scheme name='External' />",
            "<!DOCTYPE scheme [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><scheme name='&secret;' />",
            "<!DOCTYPE scheme [<!ENTITY a 'expanded'>]><scheme name='&a;' />",
        ] {
            #expect(throws: EditorThemeImportError.self) { try parse(xml) }
        }
    }

    @Test @MainActor func jetBrainsSchemesAreBundledSelectableAndCustomImportsSurviveSourceRemoval() throws {
        let domain = "dev.dbeer.jetbrains-theme-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = EditorThemeStore(defaults: defaults, directory: directory.appendingPathComponent("library"))
        #expect(store.themes.first { $0.id == "jetbrains-light" }?.appearance == .light)
        #expect(store.themes.first { $0.id == "jetbrains-darcula" }?.appearance == .dark)
        let source = directory.appendingPathComponent("DataGrip.icls")
        try Data("<scheme name=\"Exported\" parent_scheme=\"Darcula\" />".utf8).write(to: source)
        let imported = try store.importTheme(from: source)
        #expect(store.selectedThemeID == imported.id)
        #expect(imported.colors["editor.background"] == EditorThemeColor(hex: "#2B2B2B"))
        try FileManager.default.removeItem(at: source)
        let restored = EditorThemeStore(defaults: defaults, directory: directory.appendingPathComponent("library"))
        #expect(restored.selectedThemeID == imported.id)
        #expect(restored.selectedTheme == imported)
        try restored.removeTheme(id: imported.id)
        #expect(restored.selectedThemeID == EditorThemeStore.automaticID)
    }
}
