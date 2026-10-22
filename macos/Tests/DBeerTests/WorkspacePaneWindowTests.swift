import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Authorized native coverage in owned windows. No database, Keychain, global
/// input or external Accessibility permission is used by this suite.
@Suite(.serialized)
@MainActor
struct WorkspacePaneWindowTests {
    @MainActor private final class HelperCounter { var starts = 0 }

    @MainActor private final class Fixture {
        let defaultsName: String
        let defaults: UserDefaults
        let shortcuts: AppShortcutStore
        let store: MemorySQLDocumentStore
        let workspace: ApplicationWorkspace
        let left: SQLDocument
        let right: SQLDocument
        var invocations: [AppCommandInvocation] = []
        let helperCounter: HelperCounter

        init() async throws {
            let defaultsName = "dev.dbeer.tests.pane-windows.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: defaultsName))
            let shortcuts = AppShortcutStore(defaults: defaults)
            let store = MemorySQLDocumentStore()
            let helperCounter = HelperCounter()
            self.defaultsName = defaultsName
            self.defaults = defaults
            self.shortcuts = shortcuts
            self.store = store
            self.helperCounter = helperCounter
            let profile = SavedConnection(name: "Pane fixture", settings: ConnectionSettings(host: "fixture.invalid",
                port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable"))
            let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
                SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id)),
                credentialStore: MemoryConnectionCredentialStore(), documentStore: store,
                commandShortcuts: shortcuts, sqlFolders: SQLFolderLibrary(automaticallyRefresh: false),
                automaticallyWatchFiles: false, closeDecision: { _ in .discard },
                helperFactory: { helperCounter.starts += 1; return BackendClient() })
            self.workspace = workspace
            await workspace.restoreSavedWorkspace()
            await workspace.library.loadConnections()
            let left = workspace.newDocument(profileID: profile.id, text: "SELECT 11;\nSELECT 12;", in: .left)
            let right = workspace.newDocument(profileID: profile.id, text: "SELECT 21;\nSELECT 22;", in: .right)
            self.left = left
            self.right = right
            left.executions = [SQLExecution(sql: left.text, range: NSRange(location: 0, length: left.text.utf16.count),
                status: "Completed", result: Self.result("left"))]
            right.executions = [SQLExecution(sql: right.text, range: NSRange(location: 0, length: right.text.utf16.count),
                status: "Completed", result: Self.result("right"))]
            workspace.commands = AppCommandRegistry(workspace: workspace, shortcuts: shortcuts) { [weak self] in
                self?.invocations.append($0)
            }
        }

        static func result(_ side: String) -> BackendMessage {
            BackendMessage(type: "query.result", requestId: "pane-fixture", columns: [
                ResultColumn(index: 0, name: "value", typeOid: 25, engine: .postgresql, nativeType: "text")],
                rows: [[side + "-0"], [side + "-1"]], commandTag: "SELECT 2", rowCount: 2)
        }

        func finish() async {
            await workspace.shutdown()
            #expect(helperCounter.starts == 0)
            defaults.removePersistentDomain(forName: defaultsName)
        }
    }

    private struct Element {
        let object: NSObject

        func value<T>(_ name: String) -> T? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue() as? T
        }

        func flag(_ name: String) -> Bool {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return false }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func elements(in root: NSObject) -> [Element] {
        var result: [Element] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            let element = Element(object: object)
            result.append(element)
            let children: [NSObject] = element.value("accessibilityChildren") ?? []
            children.forEach(visit)
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(root)
        return result
    }

    private func element(_ identifier: String, in root: NSObject) throws -> Element {
        try #require(elements(in: root).first {
            let value: String? = $0.value("accessibilityIdentifier")
            return value == identifier
        }, "Missing pane control: \(identifier)")
    }

    private func press(_ identifier: String, in root: NSObject) throws {
        let element = try element(identifier, in: root)
        if let button = (element.object as? NSButton) ?? ((element.object as? NSCell)?.controlView as? NSButton) {
            try #require(button.isEnabled)
            button.performClick(nil)
        } else { try #require(element.flag("accessibilityPerformPress")) }
    }

    private func tabAction(_ name: String, document: SQLDocument, in root: NSObject) throws {
        let tab = try element("documentTab-\(document.id.uuidString)", in: root)
        let actions: [NSAccessibilityCustomAction] = tab.value("accessibilityCustomActions") ?? []
        let action = try #require(actions.first { $0.name == name }, "Missing accessible tab action: \(name)")
        if let handler = action.handler { try #require(handler()) }
        else {
            let target = try #require(action.target as? NSObject)
            let selector = try #require(action.selector)
            if NSStringFromSelector(selector).contains(":") {
                typealias Action = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
                try #require(unsafeBitCast(target.method(for: selector), to: Action.self)(target, selector, action))
            } else {
                typealias Action = @convention(c) (AnyObject, Selector) -> Bool
                try #require(unsafeBitCast(target.method(for: selector), to: Action.self)(target, selector))
            }
        }
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(140))
        window.contentView?.layoutSubtreeIfNeeded()
        NativeButtonFocusPolicy().apply(to: window)
    }

    private func host(_ workspace: ApplicationWorkspace, width: CGFloat = 1120,
                      scheme: ColorScheme = .light) async throws -> NSWindow {
        let application = NSApplication.shared
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DBeer working panes verification"
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
        let content = try #require(window.contentView)
        return try #require(descendants(content, of: WorkspacePaneContainerView.self).first { $0.paneID == id })
    }

    private func editor(_ document: SQLDocument, in window: NSWindow) throws -> SQLTextView {
        let content = try #require(window.contentView)
        return try #require(descendants(content, of: SQLTextView.self).first { $0.appCommandDocumentID == document.id })
    }

    private func grid(_ document: SQLDocument, in window: NSWindow) throws -> ResultGridTableView {
        let content = try #require(window.contentView)
        return try #require(descendants(content, of: ResultGridTableView.self).first { $0.appCommandDocumentID == document.id })
    }

    private func key(_ window: NSWindow, code: UInt16 = 15, characters: String = "r",
                     modifiers: NSEvent.ModifierFlags = [.command, .option]) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    @Test func oppositeToolbarAndNextResponderShortcutAndSaveUseTheirOwnVisibleDocument() async throws {
        let fixture = try await Fixture()
        let workspace = fixture.workspace
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/r11/native-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let leftURL = directory.appendingPathComponent("left.sql")
        let rightURL = directory.appendingPathComponent("right.sql")
        try workspace.saveSQLFile(fixture.left, to: leftURL, reviewedVersion: nil)
        try workspace.saveSQLFile(fixture.right, to: rightURL, reviewedVersion: nil)
        let window = try await host(workspace)
        defer { window.close() }
        let leftEditor = try editor(fixture.left, in: window)
        let rightEditor = try editor(fixture.right, in: window)
        #expect(leftEditor !== rightEditor)
        try #require(window.makeFirstResponder(leftEditor))
        leftEditor.setSelectedRange((fixture.left.text as NSString).range(of: "SELECT 12"))
        rightEditor.setSelectedRange((fixture.right.text as NSString).range(of: "SELECT 22"))
        try await settle(window)
        try press("runQuery", in: pane(.right, in: window))
        try await settle(window)
        #expect(fixture.invocations.last?.documentID == fixture.right.id)
        #expect(fixture.invocations.last?.fragment?.sourceSQL == "SELECT 22")
        #expect(workspace.activePaneID == .right && window.firstResponder === leftEditor)
        #expect(fixture.shortcuts.update(AppShortcut(key: "r", modifiers: [.command, .option]), for: .runCurrent) == nil)
        #expect(leftEditor.performKeyEquivalent(with: try key(window)))
        try await settle(window)
        #expect(fixture.invocations.last?.documentID == fixture.left.id)
        #expect(fixture.invocations.last?.fragment?.sourceSQL == "SELECT 12")
        #expect(workspace.activePaneID == .left)

        fixture.left.text = "SELECT 111;"
        fixture.right.text = "SELECT 222;"
        try await settle(window)
        workspace.activatePane(.right)
        #expect(workspace.commands.context().documentID == fixture.left.id)
        let save = try #require(workspace.commands.perform(.saveSQL))
        await save.value
        #expect(try Data(contentsOf: leftURL) == Data(fixture.left.text.utf8))
        #expect(try Data(contentsOf: rightURL) == Data("SELECT 21;\nSELECT 22;".utf8))
        #expect(workspace.activePaneID == .left)
        #expect(fixture.left.runtime == nil && fixture.right.runtime == nil)
        await fixture.finish()
    }

    @Test func focusedGridsCaptureCopyBeforePaneChangesAndCellFieldEditorKeepsNativeTextCopy() async throws {
        let fixture = try await Fixture()
        let workspace = fixture.workspace
        let reference = TableReference(schema: "public", name: "pane_fixture", kind: "table")
        let result = Fixture.result("right")
        let draft = GridDraft(reference: reference, result: result,
            metadata: [["name": "value", "primaryKey": "1", "editable": "true"]])
        fixture.right.table = reference
        fixture.right.tableResult = result
        fixture.right.attachGrid(draft)
        let window = try await host(workspace, width: 1400)
        defer { window.close() }
        let leftGrid = try grid(fixture.left, in: window)
        let rightGrid = try grid(fixture.right, in: window)
        try #require(window.makeFirstResponder(leftGrid))
        #expect(workspace.activePaneID == .left)
        try #require(window.makeFirstResponder(rightGrid))
        #expect(workspace.activePaneID == .right)
        rightGrid.selectRowNumber(0)
        workspace.activatePane(.left)
        let copied = try #require(workspace.commands.perform(.copyAsJSON))
        rightGrid.keyDown(with: try key(window, code: 125, characters: "", modifiers: []))
        workspace.activatePane(.left)
        await copied.value
        let text = try #require(NSPasteboard.general.string(forType: .string))
        #expect(text.contains("right-0") && !text.contains("right-1"))
        let copiedData = try #require(NSPasteboard.general.data(forType: ResultTableView.clipboardType))
        let typedCopy = try JSONDecoder().decode(ResultClipboardPayload.self, from: copiedData)
        #expect(typedCopy.columns == result.columns && typedCopy.sourceRows == [0] && typedCopy.sourceColumnIndices == [0])
        #expect(typedCopy.values == [[ResultClipboardValue(kind: .text, value: "right-0")]])
        #expect(workspace.activePaneID == .left)
        #expect(rightGrid.cellSelection?.focus.row == 1)

        rightGrid.keyDown(with: try key(window, code: 36, characters: "\r", modifiers: []))
        let fieldEditor = try #require(window.firstResponder as? NSTextView)
        try #require(fieldEditor.isFieldEditor)
        #expect(workspace.commands.context().focus == .textInput)
        #expect(workspace.commands.context().documentID == fixture.right.id)
        #expect(!workspace.commands.canPerform(.copyAsJSON))
        #expect(!workspace.commands.handleKeyEvent(try key(window, code: 8, characters: "c", modifiers: .command),
            documentID: fixture.right.id))
        fieldEditor.setSelectedRange(NSRange(location: 0, length: 5))
        fieldEditor.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "right")
        #expect(fixture.invocations.isEmpty)
        #expect(draft.pendingCount == 0)
        try #require(window.makeFirstResponder(rightGrid))
        fixture.left.isRunning = true
        try await settle(window)
        try press("stopQuery", in: pane(.left, in: window))
        try await settle(window)
        #expect(fixture.invocations.last?.command == .stop && fixture.invocations.last?.documentID == fixture.left.id)
        #expect(window.firstResponder === rightGrid && workspace.activePaneID == .left)
        fixture.left.isRunning = false
        #expect(fixture.right.grid === draft && draft.rows.count == 2 && draft.pendingCount == 0)
        await fixture.finish()
    }

    @Test func accessibleRepeatedMovesKeepTheNativeEditorUndoSelectionAndCommandHandlers() async throws {
        let fixture = try await Fixture()
        let workspace = fixture.workspace
        fixture.left.text += "\n" + (0..<90).map { "-- pane handoff line \($0)" }.joined(separator: "\n")
        let original = fixture.left.text
        let window = try await host(workspace, width: 1400)
        defer { window.close() }
        let cached = try editor(fixture.left, in: window)
        try #require(window.makeFirstResponder(cached))
        cached.setSelectedRange(NSRange(location: cached.string.utf16.count, length: 0))
        cached.insertText(" edited", replacementRange: cached.selectedRange())
        cached.scrollRangeToVisible(cached.selectedRange())
        let undo = try #require(cached.undoManager)
        let selection = cached.selectedRange()
        try #require(undo.canUndo)
        for destination in [WorkspacePaneID.right, .left, .right, .left] {
            let source = try #require(workspace.pane(containing: fixture.left.id))
            try tabAction(destination == .left ? "Move to Left Pane" : "Move to Right Pane",
                document: fixture.left, in: pane(source, in: window))
            try await settle(window)
            let moved = try editor(fixture.left, in: window)
            #expect(moved === cached && moved.undoManager === undo)
            #expect(moved.selectedRange() == selection)
            #expect(moved.delegate != nil && moved.commandEvent != nil)
            #expect(workspace.selectedDocument(in: destination) === fixture.left)
            #expect(fixture.left.runtime == nil && fixture.right.runtime == nil)
            #expect(window.firstResponder === moved)
        }
        undo.undo()
        #expect(SQLFileDocument.sameBytes(fixture.left.text, original))
        cached.setSelectedRange((cached.string as NSString).range(of: "SELECT 12"))
        #expect(fixture.shortcuts.update(AppShortcut(key: "r", modifiers: [.command, .option]), for: .runCurrent) == nil)
        #expect(cached.performKeyEquivalent(with: try key(window)))
        try await settle(window)
        #expect(fixture.invocations.last?.documentID == fixture.left.id)
        #expect(fixture.invocations.last?.fragment?.sourceSQL == "SELECT 12")
        let secondLeft = workspace.newDocument(text: "SELECT 99;", in: .left)
        try await settle(window)
        try tabAction("Move Tab Left", document: secondLeft, in: pane(.left, in: window))
        #expect(workspace.documents(in: .left).map(\.id) == [secondLeft.id, fixture.left.id])
        #expect(workspace.selectedDocument(in: .right) === fixture.right)
        await fixture.finish()
    }

    @Test func minimumAndDefaultLayoutsKeepActionsAndDesiredWidthRestoresInBothAppearances() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let fixture = try await Fixture()
            let workspace = fixture.workspace
            workspace.setSplitFraction(0.23)
            let window = try await host(workspace, width: 1800, scheme: scheme)
            let rightEditor = try editor(fixture.right, in: window)
            try #require(window.makeFirstResponder(rightEditor))
            for width: CGFloat in [900, 1120, 1800] {
                window.setContentSize(NSSize(width: width, height: 760))
                try await settle(window)
                let leftPane = try pane(.left, in: window)
                let rightPane = try pane(.right, in: window)
                #expect(leftPane.bounds.width >= 279 && rightPane.bounds.width >= 279)
                #expect(abs(workspace.paneLayout.splitFraction - 0.23) < 0.000_001)
                #expect(window.firstResponder === rightEditor)
                #expect(workspace.selectedDocument(in: .left) === fixture.left)
                #expect(workspace.selectedDocument(in: .right) === fixture.right)
                _ = try element("runQuery", in: leftPane)
                _ = try element("stopQuery", in: leftPane)
                _ = try element("runQuery", in: rightPane)
                _ = try element("stopQuery", in: rightPane)
                if width == 900 {
                    _ = try element("queryActions", in: leftPane)
                    _ = try element("queryActions", in: rightPane)
                }
                if width == 1800 {
                    let available = leftPane.frame.width + rightPane.frame.width
                    #expect(abs(Double(leftPane.frame.width / available) - 0.23) < 0.01)
                }
            }
            await workspace.flushDocuments()
            let saved = await fixture.store.load()
            #expect(saved.paneLayout.splitFraction == 0.23)
            await fixture.finish()
            window.close()
            let restored = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
                credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(snapshot: saved),
                sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), automaticallyWatchFiles: false)
            await restored.restoreSavedWorkspace()
            let restoredWindow = try await host(restored, width: 1800, scheme: scheme)
            let leftPane = try pane(.left, in: restoredWindow)
            let rightPane = try pane(.right, in: restoredWindow)
            #expect(abs(Double(leftPane.frame.width / (leftPane.frame.width + rightPane.frame.width)) - 0.23) < 0.01)
            #expect(restored.documents.allSatisfy { $0.runtime == nil })
            await restored.shutdown()
            restoredWindow.close()
        }
    }
}
