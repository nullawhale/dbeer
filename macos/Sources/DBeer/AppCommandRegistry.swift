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
    let parentDocumentID: UUID
    let investigationID: UUID?
    let blockID: UUID?
    let paneID: WorkspacePaneID
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

    private struct ResolvedContext {
        let context: AppCommandContext
        let document: SQLDocument?
        let tab: SQLDocument?
    }

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
        else if responder is NSTextView || responder is NSTextField {
            focus = .textInput
            if let pane = WorkspacePaneContainerView.owningPane(of: responder, in: workspace) {
                documentID = workspace.selectedDocument(in: pane)?.id
            }
        }
        else { focus = .workspace }
        return AppCommandContext(documentID: documentID, focus: focus,
            isWorkspaceWindow: window != nil && NSApp.keyWindow === window,
            hasModal: NSApp.modalWindow != nil || window?.attachedSheet != nil || workspace.library.isConnectionEditorPresented,
            isComposingText: (responder as? NSTextView)?.hasMarkedText() == true)
    }

    /// Toolbar buttons preserve the native responder, which may belong to the
    /// other pane. Their target is the visible document that owns the toolbar.
    func context(for document: SQLDocument) -> AppCommandContext {
        let current = context()
        return AppCommandContext(documentID: document.id, focus: .workspace,
            isWorkspaceWindow: current.isWorkspaceWindow, hasModal: current.hasModal,
            isComposingText: current.isComposingText)
    }

    private func resolve(_ context: AppCommandContext) -> ResolvedContext? {
        guard context.isWorkspaceWindow, !context.hasModal else { return nil }
        let document: SQLDocument?
        if let id = context.documentID {
            // Both panes are visible. A responder in a hidden tab must never
            // retarget execution to whichever tab happens to be active.
            document = workspace.commandDocument(for: id)
        } else if context.focus == .workspace || context.focus == .textInput {
            document = workspace.selectedDocument.flatMap { workspace.commandDocument(for: $0.id) }
        } else { document = nil }
        return ResolvedContext(context: context, document: document,
            tab: document.flatMap { workspace.ownedSQLContext(for: $0)?.tab })
    }

    /// Extension point for grid commands that operate on a document. Copy as
    /// commands instead capture the focused responder's selection synchronously.
    func registerGridCommand(_ command: AppCommandID, handler: @escaping (SQLDocument) async -> Void) {
        gridHandlers[command] = handler
    }

    func help(for command: AppCommandID) -> String {
        let title = shortcuts.descriptors.first { $0.id == command }?.title ?? command.rawValue
        return title + (shortcuts.shortcut(for: command).map { " (\($0.displayString))" } ?? "")
    }

    func canPerform(_ command: AppCommandID, context: AppCommandContext? = nil) -> Bool {
        guard let resolved = resolve(context ?? self.context()) else { return false }
        return canPerform(command, resolved: resolved)
    }

    private func canPerform(_ command: AppCommandID, resolved: ResolvedContext) -> Bool {
        let context = resolved.context
        guard let descriptor = shortcuts.descriptors.first(where: { $0.id == command }) else { return false }
        if descriptor.scope == .workspace {
            guard !context.isComposingText, workspace.canManageWorkspace else { return false }
            switch command {
            case .newConnection: return !workspace.library.isSavingConnection
            case .newSQLTab, .openSQL, .attachSQLFolder, .checkSQLFiles: return true
            case .reopenClosedTab: return workspace.canReopenClosedTab
            case .unsplitCurrent, .unsplitAll: return workspace.paneLayout.isSplit
            case .nextTab, .previousTab:
                return workspace.documents(in: workspace.activePaneID).count > 1 && workspace.selectedDocument != nil
            case .findInConnections, .toggleConnectionsPanel, .toggleFilesPanel,
                 .toggleSQLLibraryPanel, .toggleInvestigationsPanel: return true
            case .showSQLHistory: return !workspace.isHistoryPresented
            case .importConnections: return !workspace.isImportingProfiles && workspace.importPreview == nil
            case .exportConnections: return !workspace.library.savedConnections.isEmpty
            default: return false
            }
        }
        guard let document = resolved.document else { return false }
        if command.splitDirection != nil {
            return !context.isComposingText && workspace.canManageWorkspace && workspace.paneLayout.canSplit && resolved.tab != nil
        }
        if command == .closeTab {
            return !context.isComposingText && resolved.tab.map { workspace.canStartOperation($0) } == true
        }
        if command == .saveSQL || command == .saveSQLAs {
            if let tab = resolved.tab, tab.isInvestigation {
                return command == .saveSQL && !context.isComposingText && workspace.canStartOperation(tab) &&
                    tab.investigationModel?.isAvailable == true && tab.investigationModel?.isSaving != true
            }
            return !context.isComposingText && workspace.canStartOperation(document) &&
                document.isSQLDocument && document.fileDocument?.isSaving != true
        }
        if descriptor.scope == .grid {
            guard context.focus == .grid, Self.canCopyGrid(in: document, workspace: workspace) else { return false }
            if command.isGridCopyCommand {
                return gridCopyResponder(for: document)?.canPerformGridCopy(command) == true
            }
            return gridHandlers[command] != nil
        }
        if command == .stop { return document.isRunning || document.grid?.isApplying == true }
        guard !context.isComposingText else { return false }
        guard !document.isSnapshot, !document.isInvestigation else { return false }
        guard !document.isNavigatingTable else { return false }
        guard context.focus != .textInput else { return false }
        guard workspace.canStartOperation(document), !document.isRunning, document.grid?.isApplying != true,
              let profileID = document.profileID, workspace.library.savedConnections.contains(where: { $0.id == profileID }) else { return false }
        if descriptor.scope == .sqlDocument, document.table != nil { return false }
        if document.table != nil { return command == .runCurrent }
        guard workspace.sqlLibraryExecutionNotice(for: document) == nil else { return false }
        // Invalid SQL remains launchable so the normal parser diagnostic appears.
        let fragment = workspace.executionFragment(document, script: command == .runScript)
        return fragment.map { !$0.sourceSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
    }

    @discardableResult
    func perform(_ command: AppCommandID, context: AppCommandContext? = nil) -> Task<Void, Never>? {
        guard let resolved = resolve(context ?? self.context()), canPerform(command, resolved: resolved) else { return nil }
        return perform(command, resolved: resolved)
    }

    private func perform(_ command: AppCommandID, resolved: ResolvedContext) -> Task<Void, Never>? {
        WorkspacePaneContainerView.acknowledgeCurrentResponder(in: workspace)
        switch command {
        case .newConnection: workspace.library.isConnectionEditorPresented = true
        case .newSQLTab: workspace.newDocument()
        case .unsplitCurrent: workspace.unsplitPane(workspace.activePaneID)
        case .unsplitAll: workspace.mergePanes()
        case .openSQL: workspace.openSQLFile()
        case .attachSQLFolder: workspace.attachSQLFolder()
        case .checkSQLFiles: return Task { [workspace] in await workspace.reconcileSQLFiles() }
        case .findInConnections: workspace.findInConnections()
        case .toggleConnectionsPanel: workspace.toggleSidebar(.connections)
        case .toggleFilesPanel: workspace.toggleSidebar(.files)
        case .toggleSQLLibraryPanel: workspace.toggleSidebar(.library)
        case .toggleInvestigationsPanel: workspace.toggleSidebar(.investigations)
        case .showSQLHistory: workspace.isHistoryPresented = true
        case .importConnections: workspace.previewProfileImport()
        case .exportConnections: workspace.exportProfiles()
        case .nextTab, .previousTab:
            let pane = workspace.activePaneID
            let documents = workspace.documents(in: pane)
            guard let index = documents.firstIndex(where: { $0.id == workspace.selectedDocument(in: pane)?.id }) else { return nil }
            let count = documents.count
            let offset = command == .nextTab ? 1 : -1
            workspace.selectDocument(documents[(index + offset + count) % count].id, in: pane)
        case .reopenClosedTab:
            // Pop synchronously so repeated keypresses consume distinct entries
            // even before the next task can run, including with zero open tabs.
            guard workspace.reopenClosedTab() != nil else { return nil }
        default: return performDocumentCommand(command, resolved: resolved)
        }
        return Task {}
    }

    private func performDocumentCommand(_ command: AppCommandID, resolved: ResolvedContext) -> Task<Void, Never>? {
        guard let document = resolved.document, let owner = workspace.ownedSQLContext(for: document) else { return nil }
        let tab = owner.tab
        let pane = owner.paneID
        workspace.activatePane(pane)
        if let direction = command.splitDirection {
            workspace.splitDocument(tab.id, direction: direction)
            return Task {}
        }
        if command == .closeTab {
            return Task { [workspace] in await workspace.closeDocument(tab) }
        }
        if command == .saveSQL || command == .saveSQLAs {
            if tab.isInvestigation {
                return Task { [workspace] in _ = await workspace.saveInvestigation(tab) }
            }
            workspace.saveSQLFile(document, chooseLocation: command == .saveSQLAs)
            return Task {}
        }
        if command.isGridCopyCommand {
            guard let operation = gridCopyResponder(for: document)?.captureGridCopy(command) else { return nil }
            return Task { [workspace] in
                guard Self.canCopyGrid(in: document, workspace: workspace) else { return }
                await operation()
            }
        }
        let invocation = AppCommandInvocation(command: command, documentID: document.id, documentText: document.text,
            profile: workspace.library.savedConnections.first { $0.id == document.profileID },
            fragment: document.table == nil && command != .stop ? workspace.executionFragment(document, script: command == .runScript) : nil,
            parentDocumentID: tab.id, investigationID: owner.investigationID, blockID: owner.blockID, paneID: pane)
        let handler = gridHandlers[command]
        return Task { [workspace, invocationHandler] in
            if let invocationHandler { await invocationHandler(invocation); return }
            // Tab switches after the click do not retarget the operation.
            guard let currentOwner = workspace.ownedSQLContext(for: document), currentOwner.tab === tab,
                  currentOwner.blockID == invocation.blockID else { return }
            if command == .stop { await workspace.stop(document); return }
            guard SQLFileDocument.sameBytes(document.text, invocation.documentText),
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
        if document.isSnapshot, document.snapshotModel?.isAvailable != true { return false }
        return workspace.canStartOperation(document) && !document.isRunning && !document.isNavigatingTable && document.grid?.isApplying != true &&
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
        guard context.documentID == documentID, let resolved = resolve(context),
              let document = resolved.document, document.id == documentID,
              event.window === workspace.presentationWindow else { return false }
        if context.focus == .sqlEditor, let selection { document.selection = selection }
        guard let descriptor = shortcuts.descriptors.first(where: {
            shortcuts.shortcut(for: $0.id)?.matches(event: event) == true && canPerform($0.id, resolved: resolved)
        }) else { return false }
        return perform(descriptor.id, resolved: resolved) != nil
    }
}
