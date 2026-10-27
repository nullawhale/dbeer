import AppKit
import Foundation
import Testing
@testable import DBeer

/// Model state and injected command context only; no windows, controls or
/// application activation are used to dispatch these commands.
@Suite(.serialized)
@MainActor
struct ReopenTabCommandTests {
    @MainActor private final class Counter { var helperStarts = 0 }

    @MainActor
    private struct Fixture {
        let defaultsName: String
        let defaults: UserDefaults
        let shortcuts: AppShortcutStore
        let workspace: ApplicationWorkspace
        let registry: AppCommandRegistry
        let counter: Counter

        init(closeDecision: @escaping @MainActor (WorkspaceCloseIssue) async -> WorkspaceCloseDecision = { _ in .cancel }) throws {
            defaultsName = "dev.dbeer.tests.reopen-command.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: defaultsName))
            shortcuts = AppShortcutStore(defaults: defaults)
            let counter = Counter()
            self.counter = counter
            workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
                credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
                commandShortcuts: shortcuts, closeDecision: closeDecision,
                helperFactory: { counter.helperStarts += 1; return BackendClient() })
            registry = AppCommandRegistry(workspace: workspace, shortcuts: shortcuts)
        }

        var context: AppCommandContext {
            AppCommandContext(documentID: workspace.selectedDocumentID, focus: .workspace,
                isWorkspaceWindow: true, hasModal: false)
        }

        func seedClosed(_ title: String) async -> SQLDocument {
            let document = workspace.newDocument(text: "SELECT '\(title)';")
            document.title = title
            await workspace.closeDocument(document)
            return document
        }
    }

    @Test func workspaceDefaultShortcutPersistsOverridesWithoutClaimingOtherNativeKeys() throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        let binding = AppShortcut(key: "t", modifiers: [.command, .shift])
        let descriptor = try #require(fixture.shortcuts.descriptors.first { $0.id == .reopenClosedTab })
        #expect(descriptor.scope == .workspace && descriptor.defaultShortcut == binding)
        #expect(fixture.shortcuts.shortcut(for: .reopenClosedTab) == binding)
        #expect(fixture.shortcuts.validationError(for: binding, command: .reopenClosedTab) == nil)
        for shortcut in [AppShortcut(key: "t", modifiers: .command),
                         AppShortcut(key: "c", modifiers: .command),
                         AppShortcut(key: "tab", modifiers: .control),
                         AppShortcut(key: "leftArrow", modifiers: .option),
                         AppShortcut(key: " ", modifiers: .control)] {
            #expect(fixture.shortcuts.update(shortcut, for: .reopenClosedTab) != nil)
        }
        #expect(fixture.shortcuts.update(nil, for: .reopenClosedTab) == nil)
        // Removing Reopen does not make its protected native binding available
        // to a query command or an unrelated future workspace command.
        #expect(fixture.shortcuts.update(binding, for: .runCurrent) != nil)
        let future = AppCommandID(rawValue: "future.workspace.command")
        let store = AppShortcutStore(defaults: fixture.defaults,
            descriptors: AppCommandDescriptor.builtins + [.init(id: future, title: "Future", scope: .workspace)])
        #expect(store.update(binding, for: future) != nil)
        let custom = AppShortcut(key: "r", modifiers: [.command, .option])
        #expect(fixture.shortcuts.update(custom, for: .reopenClosedTab) == nil)
        #expect(AppShortcutStore(defaults: fixture.defaults).shortcut(for: .reopenClosedTab) == custom)
        #expect(fixture.shortcuts.update(custom, for: .runScript) != nil)
        #expect(fixture.shortcuts.restoreDefault(for: .reopenClosedTab) == nil)
        #expect(AppShortcutStore(defaults: fixture.defaults).shortcut(for: .reopenClosedTab) == binding)
        #expect(fixture.shortcuts.update(nil, for: .reopenClosedTab) == nil)
        #expect(AppShortcutStore(defaults: fixture.defaults).shortcut(for: .reopenClosedTab) == nil)
        fixture.shortcuts.resetDefaults()
        #expect(AppShortcutStore(defaults: fixture.defaults).shortcut(for: .reopenClosedTab) == binding)
    }

    @Test func commandReopensTheLastDocumentWithoutAnOpenTabProfileOrHelper() async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        await fixture.workspace.restoreSavedWorkspace()
        let closed = await fixture.seedClosed("Last draft")
        #expect(fixture.workspace.documents.isEmpty && fixture.workspace.selectedDocumentID == nil)
        #expect(fixture.workspace.library.savedConnections.isEmpty)
        #expect(fixture.registry.canPerform(.reopenClosedTab, context: fixture.context))
        let task = try #require(fixture.registry.perform(.reopenClosedTab, context: fixture.context))
        let reopened = try #require(fixture.workspace.selectedDocument)
        #expect(reopened.title == closed.title && reopened.text == closed.text)
        #expect(reopened.id != closed.id && reopened !== closed)
        #expect(reopened.runtime == nil && reopened.grid == nil && fixture.counter.helperStarts == 0)
        #expect(fixture.workspace.closedTabs.isEmpty)
        await task.value
        #expect(!fixture.registry.canPerform(.reopenClosedTab, context: fixture.context))
        await fixture.workspace.shutdown()
    }

    @Test func repeatedCommandsConsumeDistinctEntriesBeforeTheReturnedTasksRun() async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        await fixture.workspace.restoreSavedWorkspace()
        let first = await fixture.seedClosed("First")
        let second = await fixture.seedClosed("Second")
        let context = fixture.context
        let firstTask = try #require(fixture.registry.perform(.reopenClosedTab, context: context))
        let reopenedSecond = try #require(fixture.workspace.selectedDocument)
        #expect(reopenedSecond.title == second.title && reopenedSecond.id != second.id)
        let secondTask = try #require(fixture.registry.perform(.reopenClosedTab, context: context))
        let reopenedFirst = try #require(fixture.workspace.selectedDocument)
        #expect(reopenedFirst.title == first.title && reopenedFirst.id != first.id)
        #expect(reopenedFirst !== reopenedSecond && fixture.workspace.closedTabs.isEmpty)
        #expect(fixture.registry.perform(.reopenClosedTab, context: context) == nil)
        await firstTask.value
        await secondTask.value
        #expect(fixture.workspace.selectedDocumentID == reopenedFirst.id)
        #expect(fixture.counter.helperStarts == 0)
        await fixture.workspace.shutdown()
    }

    @Test func windowModalAndCompositionGuardsDoNotConsumeClosedEntries() async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        await fixture.workspace.restoreSavedWorkspace()
        _ = await fixture.seedClosed("Keep")
        for context in [
            AppCommandContext(documentID: nil, focus: .workspace, isWorkspaceWindow: false, hasModal: false),
            AppCommandContext(documentID: nil, focus: .workspace, isWorkspaceWindow: true, hasModal: true),
            AppCommandContext(documentID: nil, focus: .sqlEditor, isWorkspaceWindow: true, hasModal: false, isComposingText: true),
            AppCommandContext(documentID: nil, focus: .textInput, isWorkspaceWindow: true, hasModal: false, isComposingText: true)
        ] {
            #expect(!fixture.registry.canPerform(.reopenClosedTab, context: context))
            #expect(fixture.registry.perform(.reopenClosedTab, context: context) == nil)
            #expect(fixture.workspace.closedTabs.count == 1)
        }
        for focus: AppCommandFocus in [.workspace, .sqlEditor, .grid, .textInput] {
            let context = AppCommandContext(documentID: nil, focus: focus, isWorkspaceWindow: true, hasModal: false)
            #expect(fixture.registry.canPerform(.reopenClosedTab, context: context))
        }
        await fixture.workspace.shutdown()
        #expect(!fixture.registry.canPerform(.reopenClosedTab, context: fixture.context))
        #expect(fixture.registry.perform(.reopenClosedTab, context: fixture.context) == nil)
    }

    @MainActor private final class CloseGate {
        var entered = false
        private var continuation: CheckedContinuation<WorkspaceCloseDecision, Never>?

        func wait() async -> WorkspaceCloseDecision {
            entered = true
            return await withCheckedContinuation { continuation = $0 }
        }

        func cancel() { continuation?.resume(returning: .cancel); continuation = nil }
    }

    @Test func closeReviewDisablesReopenAndCancellationKeepsTheStack() async throws {
        let gate = CloseGate()
        let fixture = try Fixture(closeDecision: { _ in await gate.wait() })
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        await fixture.workspace.restoreSavedWorkspace()
        _ = await fixture.seedClosed("Keep")
        let current = fixture.workspace.newDocument()
        let reference = TableReference(schema: "public", name: "items", kind: "table")
        current.table = reference
        let grid = GridDraft(reference: reference,
            result: BackendMessage(type: "query.result", requestId: "fixture",
                columns: [ResultColumn(index: 0, name: "id", nativeType: "int4")], rows: [["1"]]),
            metadata: [["name": "id", "primaryKey": "1", "editable": "true"]])
        grid.set(ChangeValue(kind: "text", value: "2"), row: 0, column: 0)
        current.attachGrid(grid)
        let close = Task { await fixture.workspace.closeDocument(current) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(gate.entered)
        #expect(!fixture.registry.canPerform(.reopenClosedTab, context: fixture.context))
        #expect(fixture.registry.perform(.reopenClosedTab, context: fixture.context) == nil)
        #expect(fixture.workspace.closedTabs.count == 1)
        gate.cancel()
        await close.value
        #expect(fixture.registry.canPerform(.reopenClosedTab, context: fixture.context))
        #expect(fixture.workspace.closedTabs.count == 1 && fixture.workspace.documents.contains { $0 === current })
        await fixture.workspace.shutdown()
    }
}
