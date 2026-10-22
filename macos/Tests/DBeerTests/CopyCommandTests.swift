import AppKit
import Foundation
import Testing
@testable import DBeer

/// These tests inject command context and responders; no windows or native
/// controls are created and the application is never activated.
@Suite(.serialized)
@MainActor
struct CopyCommandTests {
    nonisolated private static let commands: [AppCommandID] = [.copyAsJSON, .copyAsMarkdown, .copyAsSQLInsert]

    @MainActor
    private final class CopyResponder: AppGridCopyCommandResponder {
        var appCommandFocus: AppCommandFocus = .grid
        var appCommandDocumentID: UUID?
        var isEnabled = true
        var canCapture = true
        var selection = "original selection"
        var capturedCommands: [AppCommandID] = []
        var copiedSelections: [String] = []

        init(documentID: UUID) { appCommandDocumentID = documentID }

        func canPerformGridCopy(_ command: AppCommandID) -> Bool {
            isEnabled && command.isGridCopyCommand
        }

        func captureGridCopy(_ command: AppCommandID) -> (@MainActor () async -> Void)? {
            guard canCapture, canPerformGridCopy(command) else { return nil }
            capturedCommands.append(command)
            let captured = selection
            return { [self] in copiedSelections.append(captured) }
        }
    }

    @MainActor
    private struct Fixture {
        let defaultsName: String
        let defaults: UserDefaults
        let shortcuts: AppShortcutStore
        let workspace: ApplicationWorkspace
        let document: SQLDocument
        let grid: GridDraft
        let responder: CopyResponder
        let registry: AppCommandRegistry

        init() throws {
            defaultsName = "dev.dbeer.tests.copy-commands.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: defaultsName))
            shortcuts = AppShortcutStore(defaults: defaults)
            workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
                credentialStore: MemoryConnectionCredentialStore(), commandShortcuts: shortcuts,
                closeDecision: { _ in .cancel })
            document = workspace.newDocument()
            let reference = TableReference(schema: "public", name: "fixture", kind: "table")
            grid = GridDraft(reference: reference,
                result: BackendMessage(type: "query.result", requestId: "fixture",
                    columns: [ResultColumn(index: 0, name: "value", nativeType: "text")], rows: [["first"]]),
                metadata: [["name": "value", "editable": "true"]])
            document.attachGrid(grid)
            let responder = CopyResponder(documentID: document.id)
            self.responder = responder
            registry = AppCommandRegistry(workspace: workspace, shortcuts: shortcuts,
                gridCopyResponderProvider: { responder })
        }

        var context: AppCommandContext {
            AppCommandContext(documentID: document.id, focus: .grid, isWorkspaceWindow: true, hasModal: false)
        }
    }

    @Test func copyCommandsHaveGridDefaultsAndPersistRemappingUnbindingAndReset() throws {
        let name = "dev.dbeer.tests.copy-shortcuts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppShortcutStore(defaults: defaults)
        let bindings: [(AppCommandID, String)] = [(.copyAsJSON, "j"), (.copyAsMarkdown, "m"), (.copyAsSQLInsert, "i")]
        for (command, key) in bindings {
            let descriptor = try #require(store.descriptors.first { $0.id == command })
            let shortcut = AppShortcut(key: key, modifiers: [.command, .option])
            #expect(descriptor.scope == .grid)
            #expect(descriptor.defaultShortcut == shortcut)
            #expect(store.shortcut(for: command) == shortcut)
            #expect(store.validationError(for: shortcut, command: command) == nil)
            #expect(store.update(AppShortcut(key: "c", modifiers: .command), for: command) != nil)
            #expect(store.shortcut(for: command) == shortcut)
        }
        #expect(store.update(AppShortcut(key: "j", modifiers: [.command, .option]), for: .runCurrent) != nil)
        #expect(store.update(AppShortcut(key: "m", modifiers: [.command, .option]), for: .stop) != nil)
        #expect(store.update(AppShortcut(key: "m", modifiers: .command), for: .copyAsMarkdown) != nil)
        let remapped = AppShortcut(key: "r", modifiers: [.command, .option])
        #expect(store.update(remapped, for: .copyAsJSON) == nil)
        #expect(store.update(nil, for: .copyAsMarkdown) == nil)
        let restored = AppShortcutStore(defaults: defaults)
        #expect(restored.shortcut(for: .copyAsJSON) == remapped)
        #expect(restored.overrides[.copyAsMarkdown] != nil)
        #expect(restored.shortcut(for: .copyAsMarkdown) == nil)
        #expect(restored.restoreDefault(for: .copyAsJSON) == nil)
        #expect(restored.restoreDefault(for: .copyAsMarkdown) == nil)
        for (command, key) in bindings {
            #expect(restored.shortcut(for: command) == AppShortcut(key: key, modifiers: [.command, .option]))
        }
        #expect(restored.update(nil, for: .copyAsSQLInsert) == nil)
        restored.resetDefaults()
        #expect(defaults.object(forKey: AppShortcutStore.preferenceKey) == nil)
        #expect(AppShortcutStore(defaults: defaults).shortcut(for: .copyAsSQLInsert) != nil)
    }

    @Test(arguments: Self.commands)
    func dispatchCapturesSelectionBeforeItsTaskAndTabSwitch(_ command: AppCommandID) async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        #expect(fixture.document.profileID == nil && fixture.document.runtime == nil)
        #expect(fixture.registry.canPerform(command, context: fixture.context))
        let task = try #require(fixture.registry.perform(command, context: fixture.context))
        #expect(fixture.responder.capturedCommands == [command])
        #expect(fixture.responder.copiedSelections.isEmpty)
        fixture.responder.selection = "new selection"
        let other = fixture.workspace.newDocument(text: "SELECT 'other document'")
        fixture.responder.appCommandDocumentID = other.id
        await task.value
        #expect(fixture.responder.copiedSelections == ["original selection"])
        #expect(fixture.workspace.selectedDocumentID == other.id)
        await fixture.workspace.shutdown()
    }

    private enum BlockedState: CaseIterable {
        case sqlEditor, textInput, workspaceFocus, foreignWindow, modal, staleDocument
        case responderFocus, responderDocument, emptySelection, running, applying, reloading, closing, navigating
    }

    @Test(arguments: BlockedState.allCases)
    private func copyCommandsRespectContextAndLifecycle(_ state: BlockedState) async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        var documentID: UUID? = fixture.document.id
        var focus: AppCommandFocus = .grid
        var isWorkspaceWindow = true
        var hasModal = false
        switch state {
        case .sqlEditor: focus = .sqlEditor
        case .textInput: focus = .textInput
        case .workspaceFocus: focus = .workspace
        case .foreignWindow: isWorkspaceWindow = false
        case .modal: hasModal = true
        case .staleDocument: documentID = UUID()
        case .responderFocus: fixture.responder.appCommandFocus = .textInput
        case .responderDocument: fixture.responder.appCommandDocumentID = UUID()
        case .emptySelection: fixture.responder.isEnabled = false
        case .running: fixture.document.isRunning = true
        case .applying: fixture.grid.isApplying = true
        case .reloading: fixture.grid.isReloading = true
        case .closing: fixture.grid.isClosing = true
        case .navigating: fixture.document.isNavigatingTable = true
        }
        let context = AppCommandContext(documentID: documentID, focus: focus,
            isWorkspaceWindow: isWorkspaceWindow, hasModal: hasModal)
        for command in Self.commands {
            #expect(!fixture.registry.canPerform(command, context: context))
            #expect(fixture.registry.perform(command, context: context) == nil)
        }
        #expect(fixture.responder.capturedCommands.isEmpty)
        #expect(fixture.responder.copiedSelections.isEmpty)
        await fixture.workspace.shutdown()
    }

    @Test func navigationBlocksQueryAndCopyCommandsButKeepsStopAvailable() async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        try #require(await fixture.workspace.library.saveConnection(name: "Navigation fixture",
            settings: ConnectionSettings(host: "localhost", port: 5432, database: "fixture",
                user: "fixture", password: "", sslMode: "disable")))
        fixture.document.profileID = try #require(fixture.workspace.library.selectedConnectionId)
        fixture.document.table = fixture.grid.reference
        #expect(fixture.registry.canPerform(.runCurrent, context: fixture.context))
        fixture.document.isNavigatingTable = true
        #expect(!fixture.registry.canPerform(.runCurrent, context: fixture.context))
        #expect(fixture.registry.perform(.runCurrent, context: fixture.context) == nil)
        #expect(!fixture.registry.canPerform(.copyAsJSON, context: fixture.context))
        fixture.document.isRunning = true
        #expect(fixture.registry.canPerform(.stop, context: fixture.context))
        fixture.document.isRunning = false
        fixture.document.isNavigatingTable = false
        #expect(fixture.registry.canPerform(.runCurrent, context: fixture.context))
        #expect(fixture.registry.canPerform(.copyAsJSON, context: fixture.context))
        await fixture.workspace.shutdown()
    }

    @Test func copyRequiresAFocusedCopyResponderAndSuccessfulSynchronousCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        let missingResponder = AppCommandRegistry(workspace: fixture.workspace, shortcuts: fixture.shortcuts,
            gridCopyResponderProvider: { nil })
        for command in Self.commands {
            #expect(!missingResponder.canPerform(command, context: fixture.context))
            #expect(missingResponder.perform(command, context: fixture.context) == nil)
        }
        fixture.responder.canCapture = false
        #expect(fixture.registry.canPerform(.copyAsJSON, context: fixture.context))
        #expect(fixture.registry.perform(.copyAsJSON, context: fixture.context) == nil)
        #expect(fixture.responder.capturedCommands.isEmpty)
        await fixture.workspace.shutdown()
    }

    @Test func closingOrStartingAnOperationBeforeTheTaskRunsCancelsTheCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        let task = try #require(fixture.registry.perform(.copyAsJSON, context: fixture.context))
        fixture.grid.isClosing = true
        await task.value
        #expect(fixture.responder.capturedCommands == [.copyAsJSON])
        #expect(fixture.responder.copiedSelections.isEmpty)
        fixture.grid.isClosing = false
        let next = try #require(fixture.registry.perform(.copyAsMarkdown, context: fixture.context))
        fixture.document.isRunning = true
        await next.value
        #expect(fixture.responder.copiedSelections.isEmpty)
        await fixture.workspace.shutdown()
        #expect(!fixture.registry.canPerform(.copyAsJSON, context: fixture.context))
        #expect(fixture.registry.perform(.copyAsJSON, context: fixture.context) == nil)
    }
}
