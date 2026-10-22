import AppKit
import Combine

enum AppCommandFocus: Equatable { case workspace, sqlEditor, grid, textInput }

/// Native responders declare their command scope. A cell's field editor stays
/// a text input, so grid shortcuts cannot replace text editing commands.
@MainActor protocol AppCommandFocusResponder: AnyObject {
    var appCommandFocus: AppCommandFocus { get }
    var appCommandDocumentID: UUID? { get }
}

/// Capture an immutable grid selection before asynchronous serialization starts.
/// Text field editors do not conform, preserving their native editing commands.
@MainActor protocol AppGridCopyCommandResponder: AppCommandFocusResponder {
    func canPerformGridCopy(_ command: AppCommandID) -> Bool
    func captureGridCopy(_ command: AppCommandID) -> (@MainActor () async -> Void)?
}

struct AppCommandContext: Equatable {
    let documentID: UUID?
    let focus: AppCommandFocus
    let isWorkspaceWindow: Bool
    let hasModal: Bool
    let isComposingText: Bool

    init(documentID: UUID?, focus: AppCommandFocus, isWorkspaceWindow: Bool, hasModal: Bool,
         isComposingText: Bool = false) {
        self.documentID = documentID
        self.focus = focus
        self.isWorkspaceWindow = isWorkspaceWindow
        self.hasModal = hasModal
        self.isComposingText = isComposingText
    }
}

struct AppCommandInvocation {
    let command: AppCommandID
    let documentID: UUID
    let documentText: String
    let profile: SavedConnection?
    let fragment: SQLExecutionFragment?
}

/// Menus, toolbar controls and native key events all enter here. A synchronous
/// invocation captures the document and fragment before a Task can suspend.
@MainActor final class AppCommandRegistry: NSObject, ObservableObject {
    let shortcuts: AppShortcutStore
    private unowned let workspace: ApplicationWorkspace
    private var shortcutObservation: AnyCancellable?
    private var gridHandlers: [AppCommandID: (SQLDocument) async -> Void] = [:]
    private let gridCopyResponderProvider: (@MainActor () -> (any AppGridCopyCommandResponder)?)?
    private let invocationHandler: ((AppCommandInvocation) async -> Void)?
    private var previousContext: AppCommandContext?
    private var previousScopedCommands: Set<AppCommandID> = []

    convenience init(workspace: ApplicationWorkspace, shortcuts: AppShortcutStore,
                     invocationHandler: ((AppCommandInvocation) async -> Void)? = nil) {
        self.init(workspace: workspace, shortcuts: shortcuts, gridCopyResponderProvider: nil,
            invocationHandler: invocationHandler)
    }

    init(workspace: ApplicationWorkspace, shortcuts: AppShortcutStore,
         gridCopyResponderProvider: (@MainActor () -> (any AppGridCopyCommandResponder)?)?,
         invocationHandler: ((AppCommandInvocation) async -> Void)? = nil) {
        self.workspace = workspace
        self.shortcuts = shortcuts
        self.gridCopyResponderProvider = gridCopyResponderProvider
        self.invocationHandler = invocationHandler
        super.init()
        shortcutObservation = shortcuts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshContext),
            name: NSApplication.willUpdateNotification, object: nil)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshContext), name: name, object: nil)
        }
    }

    @objc private func refreshContext() {
        let context = context()
        // Selection and the closed-tab stack can change without moving focus.
        let scopedCommands = Set(shortcuts.descriptors.filter {
            ($0.scope == .grid || $0.scope == .workspace) && canPerform($0.id, context: context)
        }.map(\.id))
        guard context != previousContext || scopedCommands != previousScopedCommands else { return }
        previousContext = context
        previousScopedCommands = scopedCommands
        objectWillChange.send()
    }

    func context() -> AppCommandContext {
        let window = workspace.presentationWindow
        let responder = window?.firstResponder
        let focus: AppCommandFocus
        var documentID = workspace.selectedDocumentID
        if let scoped = responder as? any AppCommandFocusResponder {
            focus = scoped.appCommandFocus
            documentID = scoped.appCommandDocumentID
        }
        else if responder is NSTextView || responder is NSTextField { focus = .textInput }
        else { focus = .workspace }
        return AppCommandContext(documentID: documentID, focus: focus,
            isWorkspaceWindow: window != nil && NSApp.keyWindow === window,
            hasModal: NSApp.modalWindow != nil || window?.attachedSheet != nil || workspace.library.isConnectionEditorPresented,
            isComposingText: (responder as? NSTextView)?.hasMarkedText() == true)
    }

    /// Extension point for grid commands that operate on a document. Copy as
    /// commands instead capture the focused responder's selection synchronously.
    func registerGridCommand(_ command: AppCommandID, handler: @escaping (SQLDocument) async -> Void) {
        gridHandlers[command] = handler
    }

    func canPerform(_ command: AppCommandID, context: AppCommandContext? = nil) -> Bool {
        let context = context ?? self.context()
        guard context.isWorkspaceWindow, !context.hasModal,
              let descriptor = shortcuts.descriptors.first(where: { $0.id == command }) else { return false }
        if descriptor.scope == .workspace {
            return command == .reopenClosedTab && !context.isComposingText &&
                workspace.canReopenClosedTab
        }
        guard let document = workspace.selectedDocument, context.documentID == document.id else { return false }
        if descriptor.scope == .grid {
            guard context.focus == .grid, Self.canCopyGrid(in: document, workspace: workspace) else { return false }
            if command.isGridCopyCommand {
                return gridCopyResponder(for: document)?.canPerformGridCopy(command) == true
            }
            return gridHandlers[command] != nil
        }
        if command == .stop { return document.isRunning || document.grid?.isApplying == true }
        guard context.focus != .textInput else { return false }
        guard workspace.canStartOperation(document), !document.isRunning, document.grid?.isApplying != true,
              let profileID = document.profileID, workspace.library.savedConnections.contains(where: { $0.id == profileID }) else { return false }
        if descriptor.scope == .sqlDocument, document.table != nil { return false }
        if document.table != nil { return command == .runCurrent }
        // Invalid SQL remains launchable so the normal parser diagnostic appears.
        let fragment = workspace.executionFragment(document, script: command == .runScript)
        return fragment.map { !$0.sourceSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
    }

    @discardableResult
    func perform(_ command: AppCommandID, context: AppCommandContext? = nil) -> Task<Void, Never>? {
        guard canPerform(command, context: context) else { return nil }
        if command == .reopenClosedTab {
            // Pop synchronously so repeated keypresses consume distinct entries
            // even before the next task can run, including with zero open tabs.
            guard workspace.reopenClosedTab() != nil else { return nil }
            return Task {}
        }
        guard let document = workspace.selectedDocument else { return nil }
        if command.isGridCopyCommand {
            guard let operation = gridCopyResponder(for: document)?.captureGridCopy(command) else { return nil }
            return Task { [workspace] in
                guard Self.canCopyGrid(in: document, workspace: workspace) else { return }
                await operation()
            }
        }
        let invocation = AppCommandInvocation(command: command, documentID: document.id, documentText: document.text,
            profile: workspace.library.savedConnections.first { $0.id == document.profileID },
            fragment: document.table == nil && command != .stop ? workspace.executionFragment(document, script: command == .runScript) : nil)
        let handler = gridHandlers[command]
        return Task { [workspace, invocationHandler] in
            if let invocationHandler { await invocationHandler(invocation); return }
            // Tab switches after the click do not retarget the operation.
            guard workspace.documents.contains(where: { $0 === document }) else { return }
            if command == .stop { await workspace.stop(document); return }
            guard document.text == invocation.documentText,
                  document.profileID == invocation.profile?.id,
                  workspace.library.savedConnections.first(where: { $0.id == document.profileID }) == invocation.profile else { return }
            if let handler { await handler(document) }
            else if command == .runCurrent {
                if document.table != nil {
                    if TableBrowseNavigation.isCassandra(document: document, workspace: workspace) { document.resetTablePaging() }
                    await workspace.run(document)
                }
                else if let fragment = invocation.fragment { await workspace.runResolved(document, fragment: fragment) }
            } else if command == .runScript, let fragment = invocation.fragment {
                await workspace.runResolved(document, fragment: fragment, script: true)
            } else if command == .runToJSON || command == .runToCSV {
                await workspace.runToFile(document, format: command == .runToJSON ? "json" : "csv", fragment: invocation.fragment)
            }
        }
    }

    private static func canCopyGrid(in document: SQLDocument, workspace: ApplicationWorkspace) -> Bool {
        workspace.canStartOperation(document) && !document.isRunning && document.grid?.isApplying != true &&
            document.grid?.isReloading != true && document.grid?.isClosing != true
    }

    private func gridCopyResponder(for document: SQLDocument) -> (any AppGridCopyCommandResponder)? {
        let responder: (any AppGridCopyCommandResponder)?
        if let gridCopyResponderProvider { responder = gridCopyResponderProvider() }
        else { responder = workspace.presentationWindow?.firstResponder as? any AppGridCopyCommandResponder }
        guard let responder, responder.appCommandFocus == .grid,
              responder.appCommandDocumentID == document.id else { return nil }
        return responder
    }

    func handleKeyEvent(_ event: NSEvent, documentID: UUID, selection: NSRange? = nil) -> Bool {
        let context = self.context()
        guard context.documentID == documentID, context.documentID == workspace.selectedDocumentID,
              context.isWorkspaceWindow, !context.hasModal,
              event.window === workspace.presentationWindow else { return false }
        if context.focus == .sqlEditor, let selection { workspace.selectedDocument?.selection = selection }
        guard let descriptor = shortcuts.descriptors.first(where: {
            shortcuts.shortcut(for: $0.id)?.matches(event: event) == true && canPerform($0.id, context: context)
        }) else { return false }
        return perform(descriptor.id, context: context) != nil
    }
}
