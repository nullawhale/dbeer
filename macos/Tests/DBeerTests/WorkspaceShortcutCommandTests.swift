import AppKit
import Foundation
import Testing
@testable import DBeer

/// Uses model state and injected command contexts without opening windows.
@Suite(.serialized)
@MainActor
struct WorkspaceShortcutCommandTests {
    @MainActor private final class Counter { var helperStarts = 0 }

    @MainActor private struct Fixture {
        let defaultsName = "dev.dbeer.tests.workspace-shortcuts.\(UUID().uuidString)"
        let defaults: UserDefaults
        let shortcuts: AppShortcutStore
        let workspace: ApplicationWorkspace
        let registry: AppCommandRegistry
        let counter = Counter()

        init(closeDecision: @escaping @MainActor (WorkspaceCloseIssue) async -> WorkspaceCloseDecision = { _ in .cancel }) throws {
            defaults = try #require(UserDefaults(suiteName: defaultsName))
            shortcuts = AppShortcutStore(defaults: defaults)
            let counter = counter
            workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
                credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
                commandShortcuts: shortcuts, sqlFolders: SQLFolderLibrary(automaticallyRefresh: false),
                automaticallyWatchFiles: false, closeDecision: closeDecision,
                helperFactory: { counter.helperStarts += 1; return BackendClient() })
            registry = AppCommandRegistry(workspace: workspace, shortcuts: shortcuts)
        }

        func context(focus: AppCommandFocus = .workspace, hasModal: Bool = false,
                     isWorkspaceWindow: Bool = true, isComposingText: Bool = false) -> AppCommandContext {
            AppCommandContext(documentID: workspace.selectedDocumentID, focus: focus,
                isWorkspaceWindow: isWorkspaceWindow, hasModal: hasModal, isComposingText: isComposingText)
        }
    }

    @Test func expandedDefaultsAreUniqueOwnedAndPersistAfterRestoring() throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        let descriptors = fixture.shortcuts.descriptors
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        let bindings = descriptors.compactMap(\.defaultShortcut)
        #expect(Set(bindings).count == bindings.count)
        let standardCommands: [AppCommandID] = [.newConnection, .newSQLTab, .openSQL,
            .saveSQL, .saveSQLAs, .findInConnections, .reopenClosedTab, .previousTab, .nextTab]
        for command in standardCommands {
            let binding = try #require(fixture.shortcuts.shortcut(for: command))
            #expect(fixture.shortcuts.validationError(for: binding, command: command) == nil)
            #expect(fixture.shortcuts.update(nil, for: command) == nil)
            #expect(fixture.shortcuts.update(binding, for: .stop) != nil)
            #expect(fixture.shortcuts.restoreDefault(for: command) == nil)
            #expect(AppShortcutStore(defaults: fixture.defaults).shortcut(for: command) == binding)
        }
        let custom = AppShortcut(key: "k", modifiers: [.command, .shift])
        #expect(fixture.shortcuts.update(custom, for: .closeTab) == nil)
        #expect(fixture.shortcuts.update(custom, for: .showSQLHistory) != nil)
        #expect(fixture.shortcuts.update(nil, for: .closeTab) == nil)
        #expect(fixture.shortcuts.update(custom, for: .showSQLHistory) == nil)
        #expect(AppShortcutStore(defaults: fixture.defaults).shortcut(for: .showSQLHistory) == custom)
        fixture.shortcuts.resetDefaults()
        #expect(fixture.shortcuts.shortcut(for: .showSQLHistory) == nil)
        #expect(fixture.shortcuts.shortcut(for: .closeTab) == nil)
    }

    @Test func tabNavigationMatchesShiftedBracketsAndNonLatinCommandEvents() throws {
        for (command, character, code) in [(AppCommandID.previousTab, "{", UInt16(33)), (.nextTab, "}", UInt16(30)),
                                          (.previousTab, "Х", UInt16(33)), (.nextTab, "Ъ", UInt16(30))] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
                characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
            let shortcut = try #require(AppCommandDescriptor.builtins.first { $0.id == command }?.defaultShortcut)
            #expect(shortcut.matches(event: event))
            #expect(AppShortcut(event: event)?.isCanonical == true)
        }
    }

    @Test func workspaceCommandsWorkWithoutConnectionsAndNavigationWrapsSynchronously() async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        await fixture.workspace.restoreSavedWorkspace()
        #expect(!fixture.registry.canPerform(.nextTab, context: fixture.context()))
        #expect(!fixture.registry.canPerform(.closeTab, context: fixture.context()))
        #expect(!fixture.registry.canPerform(.exportConnections, context: fixture.context()))
        let newTab = try #require(fixture.registry.perform(.newSQLTab, context: fixture.context(focus: .textInput)))
        let first = try #require(fixture.workspace.selectedDocument)
        #expect(!fixture.registry.canPerform(.nextTab, context: fixture.context()))
        let second = fixture.workspace.newDocument(text: "SELECT 2;")
        let third = fixture.workspace.newDocument(text: "SELECT 3;")
        for expected in [first.id, second.id, third.id, first.id] {
            let task = try #require(fixture.registry.perform(.nextTab, context: fixture.context(focus: .textInput)))
            #expect(fixture.workspace.selectedDocumentID == expected)
            await task.value
        }
        let previous = try #require(fixture.registry.perform(.previousTab, context: fixture.context()))
        #expect(fixture.workspace.selectedDocumentID == third.id)
        let history = try #require(fixture.registry.perform(.showSQLHistory, context: fixture.context()))
        #expect(fixture.workspace.isHistoryPresented)
        #expect(!fixture.registry.canPerform(.showSQLHistory, context: fixture.context()))
        fixture.workspace.isHistoryPresented = false
        let connection = try #require(fixture.registry.perform(.newConnection, context: fixture.context()))
        #expect(fixture.workspace.library.isConnectionEditorPresented)
        fixture.workspace.library.isConnectionEditorPresented = false
        await newTab.value
        await previous.value
        await history.value
        await connection.value
        #expect(fixture.counter.helperStarts == 0)
        await fixture.workspace.shutdown()
        #expect(!fixture.registry.canPerform(.newSQLTab, context: fixture.context()))
    }

    @Test func fileCommandsRespectDocumentKindAndWorkspaceCommandsRespectModalAndCompositionGuards() async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        await fixture.workspace.restoreSavedWorkspace()
        let document = fixture.workspace.newDocument()
        fixture.workspace.newDocument()
        fixture.workspace.selectedDocumentID = document.id
        for command: AppCommandID in [.saveSQL, .saveSQLAs] {
            #expect(fixture.registry.canPerform(command, context: fixture.context(focus: .textInput)))
            // Saving a disconnected SQL draft does not depend on query eligibility.
            #expect(!fixture.registry.canPerform(.runCurrent, context: fixture.context()))
            document.table = TableReference(schema: "public", name: "items", kind: "table")
            #expect(!fixture.registry.canPerform(command, context: fixture.context()))
            document.table = nil
        }
        let commands: [AppCommandID] = [.newConnection, .newSQLTab, .closeTab, .nextTab, .previousTab,
            .openSQL, .saveSQL, .saveSQLAs, .attachSQLFolder, .checkSQLFiles, .showSQLHistory, .importConnections]
        for command in commands {
            #expect(fixture.registry.canPerform(command, context: fixture.context()))
            for context in [fixture.context(hasModal: true), fixture.context(isWorkspaceWindow: false),
                            fixture.context(isComposingText: true)] {
                #expect(!fixture.registry.canPerform(command, context: context))
                #expect(fixture.registry.perform(command, context: context) == nil)
            }
        }
        #expect(fixture.workspace.documents.count == 2 && !fixture.workspace.isHistoryPresented)
        #expect(fixture.counter.helperStarts == 0)
        await fixture.workspace.shutdown()
    }

    @Test func closeCommandCapturesItsTabAndUsesPendingEditReview() async throws {
        var reviewed: [WorkspaceCloseIssue] = []
        let fixture = try Fixture(closeDecision: { issue in reviewed.append(issue); return .cancel })
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        await fixture.workspace.restoreSavedWorkspace()
        let first = fixture.workspace.newDocument()
        let close = try #require(fixture.registry.perform(.closeTab, context: fixture.context()))
        let second = fixture.workspace.newDocument()
        await close.value
        #expect(fixture.workspace.documents.map(\.id) == [second.id])
        #expect(fixture.workspace.closedTabs.first?.state.id == first.id)

        let reference = TableReference(schema: "public", name: "items", kind: "table")
        second.table = reference
        let grid = GridDraft(reference: reference,
            result: BackendMessage(type: "query.result", requestId: "fixture",
                columns: [ResultColumn(index: 0, name: "id", nativeType: "int4")], rows: [["1"]]),
            metadata: [["name": "id", "primaryKey": "1", "editable": "true"]])
        grid.set(ChangeValue(kind: "text", value: "2"), row: 0, column: 0)
        second.attachGrid(grid)
        let cancelled = try #require(fixture.registry.perform(.closeTab, context: fixture.context(focus: .grid)))
        await cancelled.value
        #expect(reviewed.count == 1)
        #expect(fixture.workspace.documents.map(\.id) == [second.id])
        #expect(fixture.workspace.closedTabs.count == 1 && grid.pendingCount == 1)
        #expect(fixture.counter.helperStarts == 0)
        await fixture.workspace.shutdown()
    }
}
