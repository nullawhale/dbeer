import AppKit
import Testing
@testable import DBeer

@Suite(.serialized) @MainActor
struct EditorToolsUITests {
    private func languageService() -> SQLLanguageService {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return SQLLanguageService(helperURL: repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core"))
    }
    private func fixture(_ text: String, service: SQLLanguageService? = nil) -> (NSWindow, SQLTextView, SQLEditorToolsController, UUID) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 90, y: 110, width: 820, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let editor = SQLTextView(frame: scroll.bounds)
        editor.textContainer?.replaceLayoutManager(SQLFoldingLayoutManager())
        editor.string = text; editor.isEditable = true; editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        scroll.documentView = editor; window.contentView = scroll
        let tools = SQLEditorToolsController(), id = UUID()
        editor.editorTools = tools
        service?.update(documentID: id, text: text, engine: .postgresql, context: .empty)
        tools.configure(editor: editor, documentID: id, engine: .postgresql, languageService: service, completionContext: .empty)
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeFirstResponder(editor)
        return (window, editor, tools, id)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func findField(_ identifier: String, in window: NSWindow) throws -> NSTextField {
        try #require(window.contentView.flatMap { descendants($0).first { $0.accessibilityIdentifier() == identifier } } as? NSTextField)
    }
    private func saveQA(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent(name + ".png"))
    }

    @Test func commandFFindsInEditorAndRegexReplaceIsOneUndo() async throws {
        let (window, editor, tools, _) = fixture("select order_1, order_2;\n")
        defer { for child in window.childWindows ?? [] { child.close() }; window.close() }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        #expect(tools.handleKeyEvent(event))
        let panel = try #require(window.childWindows?.first { $0.title == "Find and Replace" })
        #expect(panel.isVisible)
        let query = try findField("editorFindField", in: panel)
        query.stringValue = "order_([12])"
        let regex = try #require(panel.contentView.flatMap { descendants($0).first { ($0 as? NSButton)?.title == "Regex" } } as? NSButton)
        regex.state = .on
        let replacement = try findField("editorReplaceField", in: panel); replacement.stringValue = "item_$1"
        await tools.replaceMatches(all: true)?.value
        #expect(editor.string == "select item_1, item_2;\n")
        editor.undoManager?.undo()
        #expect(editor.string == "select order_1, order_2;\n")
        tools.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: query))
        let status = try findField("editorSearchStatus", in: panel)
        for _ in 0..<40 where status.stringValue != "2 matches" { try await Task.sleep(for: .milliseconds(25)) }
        #expect(status.stringValue == "2 matches")
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            panel.appearance = NSAppearance(named: appearance)
            panel.contentView?.needsDisplay = true
            try saveQA(try #require(panel.contentView), name: "editor-find-replace-" + name)
        }
    }

    @Test func foldingKeepsSourceAndRevealsSearchAndErrorLocations() async throws {
        let service = languageService()
        let source = "SELECT\n    order_id,\n    customer_id\nFROM orders;\nSELECT 2;\n"
        let (window, editor, tools, _) = fixture(source, service: service)
        defer { for child in window.childWindows ?? [] { child.close() }; window.close() }
        for _ in 0..<80 where tools.analysis == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(tools.analysis != nil)
        let container = try #require(editor.textContainer)
        editor.layoutManager?.ensureLayout(for: container)
        let fullHeight = try #require(editor.layoutManager).usedRect(for: container).height
        tools.collapseAll()
        #expect(!tools.collapsedRanges.isEmpty)
        #expect(editor.string == source)
        #expect((editor.layoutManager as? SQLFoldingLayoutManager)?.hiddenRanges == tools.collapsedRanges)
        editor.layoutManager?.ensureLayout(for: container)
        #expect(try #require(editor.layoutManager).usedRect(for: container).height < fullHeight)
        try saveQA(try #require(window.contentView), name: "editor-folded")
        let hidden = try #require(tools.collapsedRanges.first)
        tools.showFind(replace: false)
        let panel = try #require(window.childWindows?.first { $0.title == "Find and Replace" })
        try findField("editorFindField", in: panel).stringValue = "customer_id"
        await tools.find(forward: true)?.value
        #expect(!tools.collapsedRanges.contains(hidden))
        #expect(editor.string == source)
        #expect((editor.string as NSString).substring(with: editor.selectedRange()) == "customer_id")
        await service.shutdown()
    }

    @Test func settingsAndThemePreserveSelectionsAndFolds() async throws {
        let service = languageService()
        let source = "SELECT\n    1,\n    2;\n"
        let (window, editor, tools, _) = fixture(source, service: service)
        defer { window.close() }
        for _ in 0..<80 where tools.analysis == nil { try await Task.sleep(for: .milliseconds(50)) }
        try #require(tools.analysis != nil)
        tools.collapseAll(); let folds = tools.collapsedRanges
        #expect(!folds.isEmpty)
        editor.setEditorSelections([NSRange(location: 0, length: 0), NSRange(location: source.utf16.count, length: 0)])
        let ranges = editor.editorSelections
        editor.applyTheme(nil)
        SQLEditorPreferences.shared.apply(to: editor)
        #expect(editor.editorSelections == ranges)
        #expect(tools.collapsedRanges == folds)
        #expect(editor.string == source)
        try saveQA(try #require(window.contentView), name: "editor-settings-folds")
        await service.shutdown()
    }
}
