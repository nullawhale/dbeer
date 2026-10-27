import AppKit
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct EditorCoreUITests {
    private func editor(_ source: String) -> SQLTextView {
        let editor = SQLTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        editor.isRichText = false
        editor.isEditable = true
        editor.allowsUndo = true
        editor.undoManager?.groupsByEvent = false
        editor.string = source
        editor.undoManager?.removeAllActions()
        return editor
    }

    private func event(_ code: UInt16, text: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }

    private func typing(_ editor: SQLTextView, _ value: String) {
        editor.undoManager?.beginUndoGrouping()
        editor.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.undoManager?.endUndoGrouping()
    }

    @Test func multipleInsertionUndoRedoRestoreIndependentCarets() throws {
        let editor = editor("ab ab")
        let ranges = [NSRange(location: 2, length: 0), NSRange(location: 5, length: 0)]
        editor.setEditorSelections(ranges)
        typing(editor, "😀")
        #expect(editor.string == "ab😀 ab😀")
        #expect(editor.editorSelections == [NSRange(location: 4, length: 0), NSRange(location: 9, length: 0)])
        editor.undoManager?.undo()
        #expect(editor.string == "ab ab")
        #expect(editor.editorSelections == ranges)
        editor.undoManager?.redo()
        #expect(editor.string == "ab😀 ab😀")
        #expect(editor.hasMultipleEditorSelections)
    }

    @Test func nextOccurrenceAndEscapeUseOnePrimarySelection() throws {
        let editor = editor("orders orders orders")
        editor.setEditorSelections([NSRange(location: 2, length: 0)])
        editor.keyDown(with: try event(2, text: "d", modifiers: .command))
        #expect(editor.editorSelections == [NSRange(location: 0, length: 6)])
        editor.keyDown(with: try event(2, text: "d", modifiers: .command))
        #expect(editor.editorSelections == [NSRange(location: 0, length: 6), NSRange(location: 7, length: 6)])
        editor.keyDown(with: try event(53, text: "\u{1b}"))
        #expect(editor.editorSelections == [NSRange(location: 0, length: 6)])
    }

    @Test func markedTextCollapsesSecondaryCarets() {
        let editor = editor("a b")
        editor.setEditorSelections([NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
        editor.undoManager?.beginUndoGrouping()
        editor.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.hasMultipleEditorSelections)
        editor.unmarkText()
        editor.undoManager?.endUndoGrouping()
    }

    @Test func multipleCaretsSuppressCompletionAndRunCurrent() throws {
        let editor = editor("select 1; select 2;")
        editor.setEditorSelections([NSRange(location: 1, length: 0), NSRange(location: 11, length: 0)])
        var completions = 0
        var runs = 0
        editor.requestCompletion = { completions += 1 }
        editor.runSelection = { _ in runs += 1 }
        editor.complete(nil)
        editor.keyDown(with: try event(36, text: "\r", modifiers: .command))
        #expect(completions == 0)
        #expect(runs == 0)
    }

    @Test func workspaceOwnedRunScriptShortcutReachesDispatcherWithMultipleCarets() throws {
        let editor = editor("SELECT 1; SELECT 2;")
        editor.setEditorSelections([NSRange(location: 1, length: 0), NSRange(location: 11, length: 0)])
        var dispatched = false
        editor.commandEvent = { event, _ in
            dispatched = event.modifierFlags.contains(.command) && event.keyCode == 36
            return dispatched
        }
        editor.keyDown(with: try event(36, text: "\r", modifiers: .command))
        #expect(dispatched)
    }

    @Test func pastePreservesSingleBracketAndQuoteAtAllCarets() {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let editor = editor("a b")
        editor.setEditorSelections([NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
        board.clearContents(); board.setString("(", forType: .string)
        editor.paste(nil)
        #expect(editor.string == "a( b(")
        editor.setEditorSelections([NSRange(location: 0, length: 0)])
        board.clearContents(); board.setString("'", forType: .string)
        editor.undoManager?.beginUndoGrouping()
        editor.paste(nil)
        editor.undoManager?.endUndoGrouping()
        #expect(editor.string == "'a( b(")
    }

    @Test func deletionTreatsEmojiAsOneCharacterAtEveryCaret() {
        let editor = editor("a😀 b😀")
        editor.setEditorSelections([NSRange(location: 3, length: 0), NSRange(location: 7, length: 0)])
        editor.undoManager?.beginUndoGrouping()
        editor.deleteBackward(nil)
        editor.undoManager?.endUndoGrouping()
        #expect(editor.string == "a b")
        #expect(editor.editorSelections == [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
        editor.undoManager?.undo()
        #expect(editor.string == "a😀 b😀")
    }

    @Test func cursorMovementRetainsEveryCaretAndVerticalAdditionDoesNotSplitEmoji() throws {
        let editor = editor("aa\n😀x\naa")
        editor.setEditorSelections([NSRange(location: 1, length: 0)])
        editor.performEditorAction(.addCursorBelow)
        #expect(editor.editorSelections == [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
        editor.keyDown(with: try event(124, text: "\u{f703}"))
        #expect(editor.hasMultipleEditorSelections)
        #expect(editor.editorSelections == [NSRange(location: 2, length: 0), NSRange(location: 5, length: 0)])
    }

    @Test func tabIndentsSelectedLinesInTabsModeAndMoveFollowsOriginalLine() {
        let editor = editor("one\ntwo\nthree")
        editor.editorUsesTabs = true
        editor.setEditorSelections([NSRange(location: 0, length: 7)])
        editor.insertTab(nil)
        #expect(editor.string == "\tone\n\ttwo\nthree")
        editor.undoManager?.undo()
        #expect(editor.string == "one\ntwo\nthree")
        editor.setEditorSelections([NSRange(location: 5, length: 0)])
        editor.performEditorAction(.moveLinesUp)
        #expect(editor.string == "two\none\nthree")
        #expect(editor.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func selectionLimitBoundsExplicitSelectAllOccurrences() {
        let editor = editor(String(repeating: "x ", count: 5000))
        editor.setEditorSelections([NSRange(location: 0, length: 1)])
        editor.performEditorAction(.selectAllOccurrences)
        #expect(editor.editorSelections.count == SQLTextView.maximumEditorSelections)
        #expect(editor.editorSelectionLimitReached)
    }

    @Test func staleLargeDocumentParseCannotReplaceLatestHighlightOrCaret() async throws {
        let storage = EditorSource()
        storage.text = String(repeating: "SELECT 1; -- marker\n", count: 90_000)
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: storage.binding, isEditable: true, in: scroll)
        let editor = try #require(scroll.documentView as? SQLTextView)
        storage.text = "SELECT 'latest';"
        coordinator.update(text: storage.binding, isEditable: true, in: scroll)
        editor.setEditorSelections([NSRange(location: 4, length: 0)])
        try await Task.sleep(for: .milliseconds(400))
        #expect(editor.string == storage.text)
        #expect(editor.syntaxText == storage.text)
        #expect(editor.selectedRange() == NSRange(location: 4, length: 0))
        coordinator.detach(from: scroll)
    }

    @Test func escapeCancelsCompletionWaitingForLargeBackgroundParse() async throws {
        let storage = EditorSource()
        storage.text = String(repeating: "SELECT 1;\n", count: 18_000)
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: storage.binding, isEditable: true, in: scroll, completions: ["users"])
        let editor = try #require(scroll.documentView as? SQLTextView)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { coordinator.detach(from: scroll); window.close() }
        for _ in 0..<20 where !window.isKeyWindow { try await Task.sleep(for: .milliseconds(25)); window.makeKey() }
        try #require(window.isKeyWindow)
        try #require(window.makeFirstResponder(editor))
        editor.setEditorSelections([NSRange(location: storage.text.utf16.count, length: 0)])
        editor.scrollRangeToVisible(editor.selectedRange())
        editor.insertText("us", replacementRange: editor.selectedRange())
        editor.keyDown(with: try event(53, text: "\u{1b}"))
        try await Task.sleep(for: .milliseconds(350))
        #expect(coordinator.visibleCompletionLabels.isEmpty)
        editor.complete(nil)
        for _ in 0..<50 where coordinator.visibleCompletionLabels.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(coordinator.visibleCompletionLabels == ["users"])
    }

    @MainActor private final class EditorSource {
        var text = ""
        var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
    }

    @Test func pairInsertionAndAutoindentAreUndoable() {
        let editor = editor("")
        typing(editor, "(")
        #expect(editor.string == "()")
        #expect(editor.selectedRange() == NSRange(location: 1, length: 0))
        editor.undoManager?.beginUndoGrouping()
        editor.insertNewline(nil)
        editor.undoManager?.endUndoGrouping()
        #expect(editor.string == "(\n    )")
        editor.undoManager?.undo()
        #expect(editor.string == "()")
    }
}
