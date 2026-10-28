import AppKit
import SwiftUI
import Testing
@testable import DBeer

/// These tests use detached text views; they never create windows or activate the app.
@Suite(.serialized)
@MainActor
struct EditorUndoTests {
    private func editor(_ text: String) -> SQLTextView {
        let editor = SQLTextView(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.undoManager?.groupsByEvent = false
        editor.string = text
        editor.undoManager?.removeAllActions()
        return editor
    }

    private func historyKey(_ editor: SQLTextView, modifiers: NSEvent.ModifierFlags, text: String = "z") throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: 6))
        editor.keyDown(with: event)
    }

    @Test func keyboardUndoRedoUsesDocumentHistoryAndRestoresMultipleSelections() throws {
        for modifier: NSEvent.ModifierFlags in [.command, .control] {
            let editor = editor("a b")
            let ranges = [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)]
            editor.setEditorSelections(ranges)
            editor.insertText("😀", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(editor.string == "a😀 b😀")
            try historyKey(editor, modifiers: modifier)
            #expect(editor.string == "a b")
            #expect(editor.editorSelections == ranges)
            try historyKey(editor, modifiers: [modifier, .shift])
            #expect(editor.string == "a😀 b😀")
            #expect(editor.hasMultipleEditorSelections)
        }
    }

    @Test func nativeTypingAndResponderActionsUndoWithoutTouchingAnotherDocument() throws {
        let first = editor("SELECT "), second = editor("other")
        first.setSelectedRange(NSRange(location: 7, length: 0))
        first.undoManager?.beginUndoGrouping()
        first.insertText("123", replacementRange: first.selectedRange())
        first.undoManager?.endUndoGrouping()
        second.applyEditorEdits([.init(range: NSRange(location: 5, length: 0), text: "!")], actionName: "Typing")
        let undo = NSMenuItem(title: "Undo", action: #selector(SQLTextView.undo(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(SQLTextView.redo(_:)), keyEquivalent: "z")
        #expect(first.validateUserInterfaceItem(undo))
        #expect(!first.validateUserInterfaceItem(redo))
        #expect(first.validateMenuItem(undo))
        #expect(!first.validateMenuItem(redo))
        // Command equivalents also work with the physical Latin key on Cyrillic layouts.
        try historyKey(first, modifiers: .command, text: "я")
        #expect(first.string == "SELECT ")
        #expect(second.string == "other!")
        #expect(first.validateUserInterfaceItem(redo))
        #expect(first.validateMenuItem(redo))
        first.redo(nil)
        #expect(first.string == "SELECT 123")
        first.isEditable = false
        first.undo(nil)
        #expect(first.string == "SELECT 123")
        #expect(!first.validateUserInterfaceItem(undo))
    }

    @Test func extensionWorksInReadOnlyEditorWithoutChangingUndoHistory() {
        let editor = editor("SELECT sum(price + 1);")
        editor.setSelectedRange((editor.string as NSString).range(of: "price"))
        editor.isEditable = false
        editor.performEditorAction(.extendSelection)
        #expect((editor.string as NSString).substring(with: editor.selectedRange()) == "price + 1")
        #expect(editor.undoManager?.canUndo == false)
    }
}
