import Foundation
import Testing
@testable import DBeer

/// Preferences and filtering only; no native controls or windows.
@Suite(.serialized)
@MainActor
struct ShortcutSearchTests {
    private func store() throws -> (AppShortcutStore, UserDefaults, String) {
        let name = "dev.dbeer.tests.shortcut-search.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (AppShortcutStore(defaults: defaults), defaults, name)
    }

    @Test func everyCommandAppearsOnceInAStableGroupAndPaneCommandsAreTogether() throws {
        let (store, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let groups = store.groups(matching: " \n ")
        let ids = groups.flatMap { $0.commands.map(\.id) }
        #expect(ids.count == store.descriptors.count && Set(ids).count == ids.count)
        #expect(groups.map(\.group) == [.connections, .sidebar, .tabs, .panes, .files, .editor, .execution, .results, .history])
        #expect(store.groups(matching: "Sidebar Panels").flatMap { $0.commands.map(\.id) } ==
            WorkspaceSidebarPanel.allCases.map(\.command))
        #expect(store.groups(matching: "Cmd+4").flatMap { $0.commands.map(\.id) } == [.toggleInvestigationsPanel])
        let panes = try #require(groups.first { $0.group == .panes })
        #expect(Set(panes.commands.map(\.id)) == [.splitLeft, .splitRight, .splitUp, .splitDown, .unsplitCurrent, .unsplitAll])
        #expect(store.groups(matching: "SQL Files and Folders").map(\.group) == [.files])
        #expect(store.groups(matching: "sPLit uP").flatMap { $0.commands.map(\.id) } == [.splitUp])
        #expect(store.groups(matching: "no such command anywhere").isEmpty)
    }

    @Test func searchUnderstandsSymbolsModifierNamesAndTheCurrentlyAssignedKey() throws {
        let (store, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        for query in ["Cmd+Option+Shift+Backslash", "⌥⇧⌘\\", "alt shift command \\"] {
            #expect(store.groups(matching: query).flatMap { $0.commands.map(\.id) } == [.unsplitCurrent])
        }
        let custom = AppShortcut(key: "r", modifiers: .control)
        #expect(store.update(custom, for: .splitRight) == nil)
        #expect(store.groups(matching: "ctrl+r").flatMap { $0.commands.map(\.id) } == [.splitRight])
        #expect(!store.groups(matching: "⌘\\").flatMap { $0.commands.map(\.id) }.contains(.splitRight))
        #expect(store.update(nil, for: .splitRight) == nil)
        #expect(store.groups(matching: "unassigned").flatMap { $0.commands.map(\.id) }.contains(.splitRight))
        #expect(!store.groups(matching: "ctrl+r").flatMap { $0.commands.map(\.id) }.contains(.splitRight))
        #expect(store.restoreDefault(for: .splitRight) == nil)
        #expect(store.groups(matching: "⌘\\").flatMap { $0.commands.map(\.id) }.contains(.splitRight))
        let restored = AppShortcutStore(defaults: defaults)
        #expect(restored.shortcut(for: .unsplitAll) == store.shortcut(for: .mergePanes))
    }
}
