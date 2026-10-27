import Foundation
import Testing
@testable import DBeer

struct EditorSearchTests {
    @Test func wholeWordTreatsUnicodeAndUnderscoresAsIdentifiers() throws {
        let source = "orders orders_old ORDERS заказы заказы_old 😀orders"
        let matches = try EditorSearch.matches(text: source, query: "orders", options: .init(wholeWord: true))
        #expect(matches.count == 3)
        let unicode = try EditorSearch.matches(text: source, query: "заказы", options: .init(wholeWord: true))
        #expect(unicode.count == 1)
        #expect((source as NSString).substring(with: try #require(unicode.first).range) == "заказы")
    }
    @Test func selectionLimitsAndRegexCapturesUseOriginalUTF16Ranges() throws {
        let source = "😀 a1 a2 a3"
        let matches = try EditorSearch.matches(text: source, query: "a([0-9])",
            options: .init(regularExpression: true), ranges: [NSRange(location: 6, length: 5)])
        #expect(matches.count == 2)
        #expect(matches.first?.range == NSRange(location: 6, length: 2))
        let expression = try EditorSearch.expression("a([0-9])", options: .init(regularExpression: true))
        #expect(expression.replacementString(for: try #require(matches.first), in: source, offset: 0, template: "id$1") == "id2")
    }
    @Test func invalidPatternsAndEmptyMatchesAreBounded() throws {
        #expect(throws: (any Error).self) {
            try EditorSearch.matches(text: "abc", query: "[", options: .init(regularExpression: true))
        }
        #expect(try EditorSearch.matches(text: "abc", query: "", options: .init()).isEmpty)
        #expect(try EditorSearch.matches(text: "a\nb", query: "(?m)^", options: .init(regularExpression: true)).count == 2)
    }
    @Test @MainActor func contextualFindBindingsCanBeClearedAndRebound() throws {
        let name = "DBeer.EditorShortcuts." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppShortcutStore(defaults: defaults)
        let command = SQLToolCommand.find.commandID
        #expect(store.shortcut(for: command) == .init(key: "f", modifiers: .command))
        #expect(store.validationError(for: store.shortcut(for: command), command: command) == nil)
        #expect(store.update(store.shortcut(for: command), for: command) == nil)
        #expect(AppShortcutStore(defaults: defaults).shortcut(for: command) == .init(key: "f", modifiers: .command))
        #expect(store.update(nil, for: command) == nil)
        #expect(store.shortcut(for: command) == nil)
        #expect(store.shortcut(for: .findInConnections) == .init(key: "f", modifiers: .command))
        let rebound = AppShortcut(key: "l", modifiers: [.command, .option])
        #expect(store.update(rebound, for: command) == nil)
        #expect(AppShortcutStore(defaults: defaults).shortcut(for: command) == rebound)
    }
}
