import AppKit
import Testing
@testable import DBeer

@MainActor
struct EditorShortcutTests {
    @Test func extendSelectionPersistsCustomBindingAndCanBeDisabled() throws {
        let name = "dev.dbeer.editor-shortcut-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let command = SQLToolCommand.extendSelection.commandID
        let store = AppShortcutStore(defaults: defaults)
        #expect(store.shortcut(for: command) == AppShortcut(key: "w", modifiers: .command))
        #expect(store.restoreDefault(for: command) == nil)
        #expect(store.validationError(for: .init(key: "w", modifiers: .command), command: .closeTab) != nil)
        let custom = AppShortcut(key: "w", modifiers: .control)
        #expect(store.update(custom, for: command) == nil)
        #expect(AppShortcutStore(defaults: defaults).shortcut(for: command) == custom)
        #expect(store.groups(matching: "extend selection").flatMap(\.commands).map(\.id) == [command])
        #expect(store.update(nil, for: command) == nil)
        #expect(AppShortcutStore(defaults: defaults).shortcut(for: command) == nil)
        #expect(store.restoreDefault(for: command) == nil)
        for modifiers: NSEvent.ModifierFlags in [.command, .control, [.command, .shift], [.control, .shift]] {
            #expect(store.update(.init(key: "z", modifiers: modifiers), for: command) != nil)
        }
    }
}
