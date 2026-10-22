import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

private final class InvestigationSnapshotReadBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var entered = false
    var hasEntered: Bool { lock.withLock { entered } }
    func wait() {
        lock.withLock { entered = true }
        _ = released.wait(timeout: .now() + 10)
    }
    func resume() { released.signal() }
}

private extension ResultSnapshotStore {
    /// Hold this fixture's actor queue without changing production read APIs.
    func holdReadsForInvestigationFixture(_ barrier: InvestigationSnapshotReadBarrier) { barrier.wait() }
}

/// Explicitly authorized native checks use owned synthetic windows and local
/// stores. Command capture replaces execution; no helper, database, Keychain,
/// global input, or external Accessibility permission is needed.
@Suite(.serialized)
@MainActor
struct InvestigationWindowTests {
    @MainActor private final class Counter { var starts = 0 }

    @MainActor private final class Fixture {
        let root: URL
        let defaultsName: String
        let defaults: UserDefaults
        let shortcuts: AppShortcutStore
        let store: MemoryInvestigationStore
        let snapshots: ResultSnapshotsModel
        let library: InvestigationLibraryModel
        let workspace: ApplicationWorkspace
        let profile: SavedConnection
        let counter: Counter
        var invocations: [AppCommandInvocation] = []

        init() async throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/r18/window-\(UUID().uuidString)")
            let defaultsName = "dev.dbeer.tests.investigation-windows.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: defaultsName))
            let shortcuts = AppShortcutStore(defaults: defaults)
            let store = MemoryInvestigationStore()
            let snapshots = ResultSnapshotsModel(store: ResultSnapshotStore(rootURL: root.appendingPathComponent("snapshots")))
            let library = InvestigationLibraryModel(store: store, snapshotStore: snapshots.store, autosaveDelay: nil)
            let profile = SavedConnection(name: "Investigation fixture", settings: ConnectionSettings(host: "fixture.invalid",
                port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable"))
            let starts = Counter()
            let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
                    SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id)),
                credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
                commandShortcuts: shortcuts, sqlFolders: SQLFolderLibrary(automaticallyRefresh: false),
                resultSnapshots: snapshots, investigations: library, automaticallyWatchFiles: false,
                closeDecision: { _ in .discard }, helperFactory: { starts.starts += 1; return BackendClient() })
            self.root = root
            self.defaultsName = defaultsName
            self.defaults = defaults
            self.shortcuts = shortcuts
            self.store = store
            self.snapshots = snapshots
            self.library = library
            self.profile = profile
            self.counter = starts
            self.workspace = workspace
            await workspace.restoreSavedWorkspace()
            await workspace.library.loadConnections()
            workspace.commands = AppCommandRegistry(workspace: workspace, shortcuts: shortcuts) { [weak self] in
                self?.invocations.append($0)
            }
        }

        func finish() async {
            await workspace.shutdown()
            #expect(counter.starts == 0)
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private struct Element {
        let object: NSObject
        func value<T>(_ name: String) -> T? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue() as? T
        }
        func flag(_ name: String, fallback: Bool = false) -> Bool {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return fallback }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        var identifier: String? { value("accessibilityIdentifier") }
        var text: String {
            let label: String? = value("accessibilityLabel")
            let plain: String? = value("accessibilityValue")
            let attributed: NSAttributedString? = value("accessibilityValue")
            return [label, plain, attributed?.string].compactMap { $0 }.joined(separator: " ")
        }
    }

    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, of: type) }
    }

    private func elements(in root: NSObject) -> [Element] {
        var found: [Element] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            let item = Element(object: object)
            found.append(item)
            let children: [NSObject] = item.value("accessibilityChildren") ?? []
            children.forEach(visit)
            if let view = object as? NSView { view.subviews.forEach(visit) }
            if let window = object as? NSWindow {
                if let content = window.contentView { visit(content) }
                if let sheet = window.attachedSheet { visit(sheet) }
            }
        }
        visit(root)
        return found
    }

    private func element(_ id: String, in root: NSObject) throws -> Element {
        try #require(elements(in: root).first { $0.identifier == id }, "Missing investigation control: \(id)")
    }

    private func press(_ id: String, in root: NSObject) async throws {
        let item = try element(id, in: root)
        if let button = (item.object as? NSButton) ?? ((item.object as? NSCell)?.controlView as? NSButton) {
            try #require(button.isEnabled)
            button.performClick(nil)
        } else {
            try #require(item.flag("isAccessibilityEnabled", fallback: true) && item.flag("accessibilityPerformPress"))
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    private func waitFor(_ window: NSWindow, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "Investigation window identifiers: \(elements(in: window).compactMap(\.identifier).sorted())")
        try await settle(window)
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(130))
        window.contentView?.layoutSubtreeIfNeeded()
        NativeButtonFocusPolicy().apply(to: window)
    }

    /// Save routing requires this fixture's window to own the native command
    /// context. Reacquire it after desktop focus changes without bypassing the
    /// registry's foreign-window, modal, or composition guards.
    private func prepareSaveWindow(_ window: NSWindow, responder: NSResponder,
                                   workspace: ApplicationWorkspace, documentID: UUID) async throws {
        let application = NSApplication.shared
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while application.keyWindow !== window || !window.isKeyWindow || !application.isActive {
            guard ContinuousClock.now < deadline else { break }
            application.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(application.keyWindow === window && window.isKeyWindow && application.isActive)
        if window.firstResponder !== responder { try #require(window.makeFirstResponder(responder)) }
        try #require(window.firstResponder === responder)
        let context = workspace.commands.context()
        try #require(context.isWorkspaceWindow && !context.hasModal && !context.isComposingText)
        try #require(context.documentID == documentID)
    }

    private func host(_ workspace: ApplicationWorkspace, width: CGFloat = 1800,
                      scheme: ColorScheme = .light) async throws -> NSWindow {
        let application = NSApplication.shared
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: 840),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DBeer synthetic investigation verification"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: ApplicationWorkspaceView(workspace: workspace).preferredColorScheme(scheme))
        workspace.presentationWindow = window
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        for _ in 0..<30 where !window.isKeyWindow {
            try await Task.sleep(for: .milliseconds(20))
            window.makeKeyAndOrderFront(nil)
        }
        try #require(window.isKeyWindow)
        try await settle(window)
        return window
    }

    private func pane(_ id: WorkspacePaneID, in window: NSWindow) throws -> WorkspacePaneContainerView {
        let root = try #require(window.contentView)
        return try #require(descendants(root, of: WorkspacePaneContainerView.self).first { $0.paneID == id })
    }

    private func editor(_ child: SQLDocument, in window: NSWindow) throws -> SQLTextView {
        let root = try #require(window.contentView)
        return try #require(descendants(root, of: SQLTextView.self).first { $0.appCommandDocumentID == child.id })
    }

    private func plainEditor(in pane: WorkspacePaneID, window: NSWindow) throws -> NSTextView {
        let container = try self.pane(pane, in: window)
        return try #require(descendants(container, of: NSTextView.self).first {
            !($0 is SQLTextView) && !$0.isFieldEditor && $0.isEditable
        })
    }

    private func replace(_ text: String, in editor: NSTextView, window: NSWindow) throws {
        try #require(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func key(_ window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .option, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "r", charactersIgnoringModifiers: "r",
            isARepeat: false, keyCode: 15))
    }

    @Test func nativeCreationMarkdownEditingContentsReorderAndSaveSurviveClosingAndLibraryReopen() async throws {
        let fixture = try await Fixture()
        let workspace = fixture.workspace
        let window = try await host(workspace)
        defer { window.close() }
        try await press("newInvestigation", in: window)
        try await waitFor(window) { workspace.selectedDocument?.isInvestigation == true }
        let parent = try #require(workspace.selectedDocument)
        let model = try #require(parent.investigationModel)
        try await press("addFirstInvestigationMarkdown", in: pane(.left, in: window))
        let markdownID = try #require(model.selectedBlockID)
        let markdown = "# Local findings\n\nExact **Markdown** and 🌍 notes.\n"
        try replace(markdown, in: plainEditor(in: .left, window: window), window: window)
        try await waitFor(window) { model.selectedBlock?.text == markdown }
        _ = try element("investigationMarkdownPreview", in: pane(.left, in: window))

        let sqlID = try #require(workspace.addInvestigationSQL(parent, profileID: fixture.profile.id))
        let sql = try #require(model.sqlDocument(for: sqlID))
        try await settle(window)
        let sqlText = "SELECT 'current native block';\nSELECT 18;"
        try replace(sqlText, in: editor(sql, in: window), window: window)
        try await waitFor(window) { sql.text == sqlText }
        try await press("selectInvestigationBlock-\(markdownID.uuidString)", in: pane(.left, in: window))
        try await press("moveInvestigationBlockDown", in: pane(.left, in: window))
        #expect(model.blocks.map(\.id) == [sqlID, markdownID])
        let notesEditor = try plainEditor(in: .left, window: window)
        try #require(window.makeFirstResponder(notesEditor))
        notesEditor.setSelectedRange(NSRange(location: 0, length: notesEditor.string.utf16.count))
        notesEditor.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == markdown)
        try await prepareSaveWindow(window, responder: notesEditor, workspace: workspace, documentID: parent.id)
        #expect(workspace.commands.context().focus == .textInput)
        #expect(!workspace.commands.canPerform(.runScript) && !workspace.commands.canPerform(.copyAsJSON))
        let save = try #require(workspace.commands.perform(.saveSQL))
        await save.value
        let titleContent = try #require(window.contentView)
        let titleField = try #require(descendants(titleContent, of: NSTextField.self)
            .first { $0.placeholderString == "Investigation title" })
        try #require(window.makeFirstResponder(titleField))
        titleField.selectText(nil)
        let fieldEditor = try #require(window.firstResponder as? NSTextView)
        fieldEditor.insertText("Native investigation title", replacementRange: fieldEditor.selectedRange())
        let titleSave = try #require(workspace.commands.perform(.saveSQL))
        await titleSave.value
        let saved = try await fixture.store.load()
        let record = try #require(saved.documents.first { $0.id == model.id })
        #expect(record.title == "Native investigation title")
        #expect(record.blocks.map(\.id) == [sqlID, markdownID])
        #expect(record.blocks.map(\.text) == [sqlText, markdown])
        #expect(sql.runtime == nil && fixture.counter.starts == 0)
        try await press("closeDocument-\(parent.id.uuidString)", in: pane(.left, in: window))
        try await waitFor(window) { !workspace.documents.contains { $0.id == parent.id } }
        #expect(fixture.library.documents.contains { $0.id == model.id })
        try await press("openInvestigationsLibrary", in: window)
        try await waitFor(window) { elements(in: window).contains { $0.identifier == "openInvestigation-\(model.id.uuidString)" } }
        try await press("openInvestigation-\(model.id.uuidString)", in: window)
        try await waitFor(window) { workspace.selectedDocument?.investigationID == model.id && window.attachedSheet == nil }
        let reopened = try #require(workspace.selectedDocument?.investigationModel)
        #expect(reopened.title == record.title && reopened.blocks == record.blocks)
        #expect(reopened.sqlDocument(for: sqlID)?.id != sql.id)
        #expect(reopened.allSQLDocuments.allSatisfy { $0.runtime == nil })
        await fixture.finish()
    }

    @Test func selectedBlockToolbarAndNativeShortcutCaptureTheirOwnPaneAndRejectStaleEditors() async throws {
        let fixture = try await Fixture()
        let workspace = fixture.workspace
        let left = try #require(await workspace.newInvestigation(title: "Left investigation"))
        let leftModel = try #require(left.investigationModel)
        let firstID = try #require(workspace.addInvestigationSQL(left, text: "SELECT 11;\nSELECT 12;", profileID: fixture.profile.id))
        let secondID = try #require(workspace.addInvestigationSQL(left, text: "SELECT 13;", profileID: fixture.profile.id))
        leftModel.selectBlock(firstID)
        workspace.activatePane(.right)
        let right = try #require(await workspace.newInvestigation(title: "Right investigation"))
        let rightModel = try #require(right.investigationModel)
        let rightID = try #require(workspace.addInvestigationSQL(right, text: "SELECT 21;\nSELECT 22;", profileID: fixture.profile.id))
        let first = try #require(leftModel.sqlDocument(for: firstID))
        let second = try #require(leftModel.sqlDocument(for: secondID))
        let rightSQL = try #require(rightModel.sqlDocument(for: rightID))
        let window = try await host(workspace, scheme: .dark)
        defer { window.close() }
        let leftEditor = try editor(first, in: window)
        try #require(window.makeFirstResponder(leftEditor))
        try await press("runInvestigationBlock", in: pane(.right, in: window))
        try await waitFor(window) { fixture.invocations.count == 1 }
        #expect(fixture.invocations[0].command == .runScript && fixture.invocations[0].documentID == rightSQL.id)
        #expect(fixture.invocations[0].fragment?.sourceSQL == rightSQL.text)
        #expect(window.firstResponder === leftEditor && workspace.activePaneID == .right)
        #expect(fixture.shortcuts.update(AppShortcut(key: "r", modifiers: [.command, .option, .shift]), for: .runScript) == nil)
        leftEditor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(leftEditor.performKeyEquivalent(with: try key(window)))
        leftModel.selectBlock(secondID)
        try await waitFor(window) { fixture.invocations.count == 2 }
        #expect(fixture.invocations[1].documentID == first.id && fixture.invocations[1].fragment?.sourceSQL == first.text)
        #expect(first.runtime == nil && second.runtime == nil && rightSQL.runtime == nil)
        #expect(!workspace.commands.canPerform(.runScript, context: AppCommandContext(documentID: first.id,
            focus: .sqlEditor, isWorkspaceWindow: true, hasModal: false)))
        #expect(!leftEditor.performKeyEquivalent(with: try key(window)))
        try await settle(window)
        let secondEditor = try editor(second, in: window)
        try #require(window.makeFirstResponder(secondEditor))
        try await prepareSaveWindow(window, responder: secondEditor, workspace: workspace, documentID: second.id)
        #expect(workspace.commands.canPerform(.saveSQL))
        #expect(!workspace.commands.canPerform(.saveSQLAs))
        window.setContentSize(NSSize(width: 900, height: 840))
        try await settle(window)
        _ = try element("investigationCompactContents", in: pane(.left, in: window))
        _ = try element("runInvestigationBlock", in: pane(.left, in: window))
        _ = try element("saveInvestigation", in: pane(.right, in: window))
        await fixture.finish()
    }

    @Test func nativeSnapshotPagesCopyAndClosedReferenceDeletionKeepTheMissingExplanation() async throws {
        let fixture = try await Fixture()
        let workspace = fixture.workspace
        let summary = try await fixture.snapshots.store.save(ResultSnapshotCapture(title: "Offline block fixture",
            sql: "SELECT local_fixture;", engine: .postgresql,
            columns: [ResultColumn(index: 0, name: "value", nativeType: "text")],
            rows: (0..<230).map { ["offline-\($0)"] }))
        let parent = try #require(await workspace.newInvestigation())
        let model = try #require(parent.investigationModel)
        let blockID = try #require(workspace.addInvestigationSnapshot(parent, snapshotID: summary.id))
        let page = try #require(model.snapshotModel(for: blockID))
        let window = try await host(workspace)
        defer { window.close() }
        try await waitFor(window) { page.result != nil }
        #expect(page.result?.rows?.count == 200 && page.pageIndex == 0)
        let snapshot = try #require(workspace.investigationSnapshotDocument(parent, blockID: blockID))
        let content = try #require(window.contentView)
        let grid = try #require(descendants(content, of: ResultGridTableView.self).first { $0.appCommandDocumentID == snapshot.id })
        try #require(window.makeFirstResponder(grid))
        grid.selectRowNumber(0)
        let copy = try #require(workspace.commands.perform(.copyAsJSON))
        await copy.value
        #expect(NSPasteboard.general.string(forType: .string)?.contains("offline-0") == true)
        #expect(!workspace.commands.canPerform(.runScript))
        try await press("snapshotNextPage", in: pane(.left, in: window))
        try await waitFor(window) { page.pageIndex == 1 && page.result?.rows?.count == 30 }
        let explanation = "Keep **the reason** even when the saved data is missing."
        try replace(explanation, in: plainEditor(in: .left, window: window), window: window)
        try await waitFor(window) { model.selectedBlock?.explanation == explanation }
        let save = try #require(workspace.commands.perform(.saveSQL))
        await save.value
        try await press("closeDocument-\(parent.id.uuidString)", in: pane(.left, in: window))
        try await waitFor(window) { workspace.documents.isEmpty }
        #expect(try fixture.library.referencingInvestigations(snapshotID: summary.id) == [model.id])
        workspace.isSnapshotsPresented = true
        try await waitFor(window) { elements(in: window).contains { $0.identifier == "deleteSnapshot-\(summary.id.uuidString)" } }
        try await press("deleteSnapshot-\(summary.id.uuidString)", in: window)
        try await waitFor(window) { elements(in: window).contains { $0.text.contains("used by 1 investigation") } }
        try await press("confirmDeleteSnapshot", in: window)
        try await waitFor(window) { fixture.snapshots.snapshots.isEmpty && !fixture.snapshots.isBusy }
        try await press("closeResultSnapshots", in: window)
        try await waitFor(window) { window.attachedSheet == nil }
        let reopened = try #require(workspace.openInvestigation(id: model.id))
        let reopenedModel = try #require(reopened.investigationModel)
        let missing = try #require(reopenedModel.snapshotModel(for: blockID))
        try await waitFor(window) { missing.error != nil && elements(in: window).contains { $0.identifier == "snapshotUnavailable" } }
        #expect(missing.result == nil && reopenedModel.selectedBlock?.explanation == explanation)
        let preview = try element("investigationSnapshotExplanationPreview", in: pane(.left, in: window))
        #expect(elements(in: preview.object).contains { $0.text.contains("the reason") })
        #expect(fixture.invocations.isEmpty && fixture.counter.starts == 0)
        await fixture.finish()
    }

    @Test func hiddenSnapshotDeletionInvalidatesRetainedNativeCopyAndRevalidationKeepsItsCurrentPage() async throws {
        let fixture = try await Fixture()
        let workspace = fixture.workspace
        let summary = try await fixture.snapshots.store.save(ResultSnapshotCapture(title: "Hidden offline fixture",
            sql: "SELECT hidden_fixture;", engine: .postgresql,
            columns: [ResultColumn(index: 0, name: "value", nativeType: "text")],
            rows: (0..<230).map { ["hidden-\($0)"] }))
        let parent = try #require(await workspace.newInvestigation())
        let model = try #require(parent.investigationModel)
        let explanation = "The saved artifact explains **this finding**."
        let snapshotID = try #require(workspace.addInvestigationSnapshot(parent, snapshotID: summary.id, explanation: explanation))
        let markdownID = try #require(workspace.addInvestigationMarkdown(parent, text: "# Other notes"))
        model.selectBlock(snapshotID)
        let page = try #require(model.snapshotModel(for: snapshotID))
        let snapshot = try #require(workspace.investigationSnapshotDocument(parent, blockID: snapshotID))
        let window = try await host(workspace, scheme: .dark)
        defer { window.close() }
        try await waitFor(window) { page.isAvailable }
        try await press("snapshotNextPage", in: pane(.left, in: window))
        try await waitFor(window) { page.isAvailable && page.pageIndex == 1 }
        let snapshotContent = try #require(window.contentView)
        let grid = try #require(descendants(snapshotContent, of: ResultGridTableView.self)
            .first { $0.appCommandDocumentID == snapshot.id })
        // Retain the old coordinator as well as the native table: it can still
        // receive Copy before SwiftUI has removed the now-invalid presentation.
        let retainedCoordinator = try #require(grid.copyCoordinator)
        #expect(retainedCoordinator.copyAvailability != nil)
        try #require(window.makeFirstResponder(grid))
        grid.selectRowNumber(0)
        let board = NSPasteboard.general
        board.clearContents()
        try #require(board.setString("unchanged snapshot clipboard fixture", forType: .string))
        let originalChangeCount = board.changeCount
        let acceptedCopy = try #require(grid.captureGridCopy(.copyAsJSON))
        #expect(retainedCoordinator.copyAllowed && grid.canPerformGridCopy(.copyAsJSON))

        let barrier = InvestigationSnapshotReadBarrier()
        defer { barrier.resume() }
        let store = fixture.snapshots.store
        let heldRead = Task { await store.holdReadsForInvestigationFixture(barrier) }
        try await waitFor(window) { barrier.hasEntered }
        let revalidation = Task { await page.revalidateCurrentPage() }
        try await waitFor(window) { page.isLoading }
        #expect(!page.isAvailable && page.pageIndex == 1 && page.pageOffset == 200)
        #expect(!grid.canPerformGridCopy(.copyAsJSON) && grid.captureGridCopy(.copyAsJSON) == nil)
        grid.copy(nil)
        await acceptedCopy()
        #expect(board.changeCount == originalChangeCount)
        #expect(board.string(forType: .string) == "unchanged snapshot clipboard fixture")
        let count = workspace.documents.count
        workspace.openSnapshotSQLInNewTab(snapshot)
        #expect(workspace.documents.count == count)
        #expect(!(try element("openSnapshotSQLInNewTab", in: pane(.left, in: window)))
            .flag("isAccessibilityEnabled", fallback: true))
        // A known deletion supersedes an already queued read. Exercise the
        // generation fence synchronously before any native-view update.
        page.invalidateArtifact(.notFound)
        grid.copy(nil)
        #expect(!grid.canPerformGridCopy(.copyAsJSON) && board.changeCount == originalChangeCount)
        barrier.resume()
        await heldRead.value
        await revalidation.value
        #expect(!page.isAvailable && page.result == nil && page.error?.contains("no longer available") == true)
        await page.revalidateCurrentPage()
        try await waitFor(window) { page.isAvailable }
        #expect(page.pageIndex == 1 && page.pageOffset == 200 && page.result?.rows?.first == ["hidden-200"])
        try await press("selectInvestigationBlock-\(markdownID.uuidString)", in: pane(.left, in: window))
        #expect(!elements(in: window).contains { $0.identifier == "offlineSnapshotDocument" })
        #expect(page.isAvailable)
        await fixture.snapshots.refresh()
        let request = try #require(fixture.snapshots.requestDeletion(summary.id))
        #expect(request.investigationIDs == [model.id])
        #expect(await fixture.snapshots.deleteConfirmed(request))
        // The selected block is still Markdown: invalidation is independent of
        // the snapshot view's lifecycle, and leaves the explanation untouched.
        #expect(model.selectedBlockID == markdownID && page.result == nil && !page.isAvailable)
        #expect(page.error?.contains("no longer available") == true && page.pageIndex == 1)
        #expect(model.blocks.first { $0.id == snapshotID }?.explanation == explanation)
        try await press("selectInvestigationBlock-\(snapshotID.uuidString)", in: pane(.left, in: window))
        try await waitFor(window) { page.error != nil && elements(in: window).contains { $0.identifier == "snapshotUnavailable" } }
        #expect(model.snapshotModel(for: snapshotID) === page)
        #expect(page.result == nil && !page.isAvailable && page.pageOffset == 200)
        #expect(!(try element("openSnapshotSQLInNewTab", in: pane(.left, in: window)))
            .flag("isAccessibilityEnabled", fallback: true))
        #expect(!grid.canPerformGridCopy(.copyAsJSON) && grid.captureGridCopy(.copyAsJSON) == nil)
        grid.copy(nil)
        #expect(grid.copyCoordinator === retainedCoordinator)
        #expect(board.changeCount == originalChangeCount && fixture.counter.starts == 0)
        await fixture.finish()
    }
}
