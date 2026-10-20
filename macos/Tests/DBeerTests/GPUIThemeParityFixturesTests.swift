import Foundation
import Testing
@testable import DBeer

/// Additive parser equivalence cases shared with Rust; prepared, not executed acceptance.
struct GPUIThemeParityFixturesTests {
    private struct Fixtures: Decodable { let version: Int; let cases: [Case] }
    private struct Case: Decodable {
        let file: String
        let name: String
        let appearance: EditorThemeAppearance
        let colors: [String: String]
        let rules: [Rule]
        let styles: [Resolved]
    }
    private struct Style: Decodable {
        let foreground: String?
        let background: String?
        let fontStyle: String?
        var normalized: EditorThemeTokenStyle {
            EditorThemeTokenStyle(foreground: foreground.flatMap(EditorThemeColor.init(hex:)),
                background: background.flatMap(EditorThemeColor.init(hex:)), fontStyle: fontStyle)
        }
    }
    private struct Rule: Decodable { let scopes: [String]; let style: Style }
    private struct Resolved: Decodable {
        let scopes: [String]
        let foreground: String?
        let background: String?
        let fontStyle: String?
        var normalized: EditorThemeTokenStyle {
            EditorThemeTokenStyle(foreground: foreground.flatMap(EditorThemeColor.init(hex:)),
                background: background.flatMap(EditorThemeColor.init(hex:)), fontStyle: fontStyle)
        }
    }
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/gpui-theme-parity")
    }
    @Test func sharedSourcesNormalizeEveryColorRuleAndResolvedStyle() throws {
        let fixture = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: root.appendingPathComponent("cases.json")))
        #expect(fixture.version == 1)
        for entry in fixture.cases {
            let theme = try EditorThemeParser.load(from: root.appendingPathComponent(entry.file),
                id: "imported-00000000-0000-4000-8000-000000000027")
            #expect(theme.name == entry.name)
            #expect(theme.appearance == entry.appearance)
            #expect(theme.isImported)
            #expect(theme.colors == entry.colors.compactMapValues(EditorThemeColor.init(hex:)))
            #expect(theme.tokenRules == entry.rules.map { EditorThemeTokenRule(scopes: $0.scopes, style: $0.style.normalized) })
            for resolved in entry.styles { #expect(theme.style(for: resolved.scopes) == resolved.normalized) }
        }
    }
    @Test func supportedJetBrainsParentUsesBundledDefaultsAndExplicitFontReset() throws {
        let theme = try EditorThemeParser.load(from: root.appendingPathComponent("jetbrains-parent.icls"))
        #expect(theme.appearance == .dark)
        let keyword = theme.style(for: ["source.sql", "keyword.control.sql"])
        #expect(keyword.foreground == EditorThemeColor(hex: "#123456"))
        #expect(keyword.fontStyle == "")
        #expect(theme.colors["editor.background"] != nil)
    }
}
