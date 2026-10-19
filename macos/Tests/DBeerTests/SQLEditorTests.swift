import AppKit
import SwiftUI
import Testing
@testable import DBeer

@MainActor
struct SQLEditorTests {
    @MainActor
    private final class TextStorage {
        var text = ""
        var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
    }

    @Test func nativeEditorDisablesSQLAlteringTextServices() throws {
        let storage = TextStorage()
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scrollView = coordinator.makeScrollView()
        let editor = try #require(scrollView.documentView as? NSTextView)

        #expect(!editor.isRichText)
        #expect(!editor.importsGraphics)
        #expect(editor.allowsUndo)
        #expect(editor.font == .monospacedSystemFont(ofSize: 13, weight: .regular))
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
        #expect(!editor.isAutomaticDashSubstitutionEnabled)
        #expect(!editor.isAutomaticTextReplacementEnabled)
        #expect(!editor.isAutomaticSpellingCorrectionEnabled)
        #expect(!editor.isAutomaticTextCompletionEnabled)
        #expect(!editor.isAutomaticLinkDetectionEnabled)
        #expect(!editor.isAutomaticDataDetectionEnabled)
        #expect(!editor.isContinuousSpellCheckingEnabled)
        #expect(!editor.isGrammarCheckingEnabled)
        #expect(!editor.smartInsertDeleteEnabled)
        #expect(editor.accessibilityLabel() == "SQL editor")
        #expect(editor.accessibilityIdentifier() == "sqlEditor")
        #expect(scrollView.hasVerticalScroller)
        #expect(scrollView.focusRingType == .none)
        #expect(editor.focusRingType == .none)
        #expect(editor.textContainer?.widthTracksTextView == true)
    }

    @Test func typingKeepsASCIIQuotesDashesAndSQLBindingUnchanged() throws {
        let storage = TextStorage()
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scrollView = coordinator.makeScrollView()
        coordinator.update(text: storage.binding, isEditable: true, in: scrollView)
        let editor = try #require(scrollView.documentView as? NSTextView)
        let sql = "SELECT 'teh', 'one--two', \"quoted_identifier\"; -- a comment\nSELECT '(c)', 'two  spaces';"

        for character in sql {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }

        #expect(editor.string == sql)
        #expect(storage.text == sql)
        #expect(editor.selectedRange() == NSRange(location: sql.utf16.count, length: 0))
    }

    @Test func bindingEchoPreservesSelectionAndExecutionKeepsTextSelectable() throws {
        let storage = TextStorage()
        storage.text = "SELECT 'unchanged';"
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scrollView = coordinator.makeScrollView()
        coordinator.update(text: storage.binding, isEditable: true, in: scrollView)
        let editor = try #require(scrollView.documentView as? NSTextView)
        let selection = NSRange(location: 7, length: 11)
        editor.setSelectedRange(selection)

        coordinator.update(text: storage.binding, isEditable: false, in: scrollView)

        #expect(editor.selectedRange() == selection)
        #expect(editor.string == storage.text)
        #expect(!editor.isEditable)
        #expect(editor.isSelectable)

        storage.text = "SELECT 1;"
        coordinator.update(text: storage.binding, isEditable: true, in: scrollView)
        #expect(editor.string == storage.text)
        #expect(editor.selectedRange() == NSRange(location: 7, length: 2))
        #expect(editor.isEditable)
    }

    @Test func switchingDocumentsRestoresNativeSelectionAndKeepsUndoIndependent() throws {
        let first = TextStorage()
        let second = TextStorage()
        let firstID = UUID()
        let secondID = UUID()
        let state = SQLEditorState()
        let coordinator = SQLEditorView.Coordinator(text: first.binding)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: first.binding, isEditable: true, in: scroll, editorState: state, documentID: firstID)
        let firstEditor = try #require(scroll.documentView as? NSTextView)
        firstEditor.insertText("SELECT 1;", replacementRange: firstEditor.selectedRange())
        firstEditor.setSelectedRange(NSRange(location: 7, length: 1))
        #expect(firstEditor.undoManager?.canUndo == true)
        coordinator.update(text: second.binding, isEditable: true, in: scroll, editorState: state, documentID: secondID)
        let secondEditor = try #require(scroll.documentView as? NSTextView)
        secondEditor.insertText("SELECT 2;", replacementRange: secondEditor.selectedRange())
        #expect(firstEditor !== secondEditor)
        #expect(firstEditor.undoManager !== secondEditor.undoManager)
        coordinator.update(text: first.binding, isEditable: true, in: scroll, editorState: state, documentID: firstID)
        #expect(scroll.documentView === firstEditor)
        #expect(firstEditor.selectedRange() == NSRange(location: 7, length: 1))
        #expect(state.selection(for: firstID) == NSRange(location: 7, length: 1))
        firstEditor.undoManager?.undo()
        #expect(first.text.isEmpty)
        #expect(second.text == "SELECT 2;")
        coordinator.update(text: second.binding, isEditable: true, in: scroll, editorState: state, documentID: secondID)
        #expect(secondEditor.string == "SELECT 2;")
    }

    @Test func nativeCommandReturnUsesSelectionAndEditorProvidesGutterHighlightAndCompletions() throws {
        let storage = TextStorage()
        storage.text = "SELECT user_table; -- comment"
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        var selectionEvents: [NSRange] = []
        var executed: NSRange?
        coordinator.update(text: storage.binding, isEditable: true, in: scroll,
            selectionChanged: { selectionEvents.append($0) }, onRunSelection: { executed = $0 },
            completions: ["user_table", "user_id"], errorPosition: 7)
        let editor = try #require(scroll.documentView as? NSTextView)
        let selection = NSRange(location: 7, length: 10)
        editor.setSelectedRange(selection)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        #expect(editor.performKeyEquivalent(with: event))
        #expect(executed == selection)
        #expect(selectionEvents.contains(selection))
        #expect(scroll.hasVerticalRuler && scroll.rulersVisible)
        #expect(scroll.verticalRulerView?.ruleThickness ?? 0 >= 40)
        let keyword = editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor
        #expect(keyword == .systemPurple)
        #expect(editor.layoutManager?.temporaryAttribute(.underlineStyle, atCharacterIndex: 7, effectiveRange: nil) != nil)
        var selected = -1
        let values = coordinator.textView(editor, completions: [], forPartialWordRange: NSRange(location: 7, length: 4),
            indexOfSelectedItem: &selected)
        #expect(values == ["user_id", "user_table"])
        #expect(selected == 0)
    }

    @Test func catalogCompletionQuotesIdentifiersForTheSelectedDialect() throws {
        let storage = TextStorage()
        storage.text = "Mi"
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: storage.binding, isEditable: true, in: scroll, engine: .postgresql,
            completions: ["Mixed\"Name", "Mixed Name"])
        let editor = try #require(scroll.documentView as? NSTextView)
        let postgres = coordinator.textView(editor, completions: [], forPartialWordRange: NSRange(location: 0, length: 2), indexOfSelectedItem: nil)
        #expect(Set(postgres) == ["\"Mixed\"\"Name\"", "\"Mixed Name\""])
        coordinator.update(text: storage.binding, isEditable: true, in: scroll, engine: .mysql, completions: ["Mixed`Name"])
        let mysql = coordinator.textView(editor, completions: [], forPartialWordRange: NSRange(location: 0, length: 2), indexOfSelectedItem: nil)
        #expect(mysql == ["`Mixed``Name`"])
    }
}
