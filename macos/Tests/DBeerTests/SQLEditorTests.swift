import AppKit
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct SQLEditorTests {
    @MainActor
    private final class TextStorage {
        var text = ""
        var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
    }

    private func window(containing scroll: NSScrollView) async throws -> NSWindow {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 100, width: 820, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        for _ in 0..<20 where !window.isKeyWindow {
            try await Task.sleep(for: .milliseconds(25))
            window.makeKey()
        }
        try #require(window.isKeyWindow)
        try #require(window.makeFirstResponder(scroll.documentView))
        return window
    }

    private func key(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func saveQA(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: destination.appendingPathComponent(name + ".png"))
    }

    private func importedTheme(dark: Bool) throws -> EditorTheme {
        let json: [String: Any] = [
            "name": dark ? "QA Midnight" : "QA Paper", "type": dark ? "dark" : "light",
            "colors": [
                "editor.background": dark ? "#112233" : "#F4F5F6",
                "editor.foreground": dark ? "#E8E9EA" : "#17202A",
                "editorCursor.foreground": dark ? "#FFE199" : "#563A00",
                "editor.selectionBackground": dark ? "#37506A" : "#C6DCEF",
                "editor.selectionForeground": dark ? "#FFFFFF" : "#102030",
                "editor.lineHighlightBackground": dark ? "#192D40" : "#E5ECF2",
                "editorGutter.background": dark ? "#0C1926" : "#E9EEF2",
                "editorLineNumber.foreground": dark ? "#8094A8" : "#526A80",
                "editorLineNumber.activeForeground": dark ? "#FFFFFF" : "#112233",
                "editorError.foreground": dark ? "#FF8191" : "#A80024",
                "editorSuggestWidget.background": dark ? "#182B3E" : "#FFFFFF",
                "editorSuggestWidget.foreground": dark ? "#EEEEEE" : "#152535",
                "editorSuggestWidget.selectedBackground": dark ? "#355677" : "#C6DCEF",
                "editorSuggestWidget.selectedForeground": dark ? "#FFFFFF" : "#102030",
                "editorSuggestWidget.border": dark ? "#58738C" : "#667788"
            ],
            "tokenColors": [
                ["scope": "keyword", "settings": ["foreground": dark ? "#F3A8E2" : "#7B235E", "fontStyle": "bold italic"]],
                ["scope": "string", "settings": ["foreground": dark ? "#BBE6AA" : "#28551E"]],
                ["scope": "constant.numeric", "settings": ["foreground": dark ? "#AACFFF" : "#214C84"]],
                ["scope": "comment", "settings": ["foreground": dark ? "#9DB2C6" : "#526A80", "fontStyle": "italic"]],
                ["scope": "variable", "settings": ["foreground": dark ? "#E8E9EA" : "#17202A"]]
            ]
        ]
        return try EditorThemeParser.parse(data: JSONSerialization.data(withJSONObject: json), id: dark ? "qa-dark" : "qa-light")
    }

    @Test func cachedTabsReceiveLatestSchemeAndRetainIndependentNativeState() throws {
        let light = try importedTheme(dark: false)
        let dark = try importedTheme(dark: true)
        let first = TextStorage()
        let second = TextStorage()
        first.text = "SELECT 'IPA', 5.5 FROM beers;\n-- inventory"
        second.text = "SELECT 2;"
        let state = SQLEditorState()
        let firstID = UUID()
        let secondID = UUID()
        let coordinator = SQLEditorView.Coordinator(text: first.binding)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: first.binding, isEditable: true, in: scroll,
            editorState: state, documentID: firstID, editorTheme: light)
        let firstEditor = try #require(scroll.documentView as? SQLTextView)
        firstEditor.setSelectedRange(NSRange(location: 7, length: 5))
        firstEditor.insertText("'Lager'", replacementRange: firstEditor.selectedRange())
        let selection = NSRange(location: 0, length: 6)
        firstEditor.setSelectedRange(selection)
        coordinator.update(text: second.binding, isEditable: true, in: scroll,
            editorState: state, documentID: secondID, editorTheme: dark)
        let secondEditor = try #require(scroll.documentView as? SQLTextView)
        #expect(secondEditor !== firstEditor)
        #expect(secondEditor.backgroundColor == dark.colors["editor.background"]?.nsColor)
        coordinator.update(text: first.binding, isEditable: true, in: scroll,
            editorState: state, documentID: firstID, editorTheme: dark)
        #expect(scroll.documentView === firstEditor)
        #expect(firstEditor.selectedRange() == selection)
        #expect(firstEditor.backgroundColor == dark.colors["editor.background"]?.nsColor)
        let keywordColor = firstEditor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor
        #expect(keywordColor == dark.style(for: ["source.sql", "keyword.other.sql"]).foreground?.nsColor)
        #expect(firstEditor.undoManager?.canUndo == true)
        firstEditor.undoManager?.undo()
        #expect(first.text == "SELECT 'IPA', 5.5 FROM beers;\n-- inventory")
        #expect(second.text == "SELECT 2;")
        coordinator.update(text: first.binding, isEditable: true, in: scroll,
            editorState: state, documentID: firstID)
        #expect(firstEditor.appearance == nil)
        #expect(scroll.appearance == nil)
        #expect(firstEditor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor == SQLSyntaxPalette.keyword)
    }

    @Test func sparseSchemesInheritTheirForegroundAndClearPreviousTokenStyles() async throws {
        let rich = try EditorThemeParser.parse(data: Data(#"""
        {"type":"dark","colors":{"editor.background":"#112233","editor.foreground":"#EEEEEE"},
         "tokenColors":[{"scope":"string","settings":{"foreground":"#BBE6AA","background":"#21412E","fontStyle":"bold italic underline strikethrough"}}]}
        """#.utf8))
        let sparse = try EditorThemeParser.parse(data: Data(#"""
        {"type":"light","colors":{"editor.background":"#EEEEEE","editor.foreground":"#222222"}}
        """#.utf8))
        let storage = TextStorage()
        storage.text = "SELECT 'IPA'; -- inventory\nSELECT us"
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: storage.binding, isEditable: true, in: scroll,
            completions: ["users"], editorTheme: rich)
        let editor = try #require(scroll.documentView as? SQLTextView)
        let window = try await window(containing: scroll)
        defer { window.close() }
        editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
        let manager = try #require(editor.layoutManager)
        let literal = (storage.text as NSString).range(of: "'IPA'")
        #expect(manager.temporaryAttribute(.backgroundColor, atCharacterIndex: literal.location, effectiveRange: nil) as? NSColor
            == rich.style(for: ["source.sql", "string.quoted.single.sql"]).background?.nsColor)
        #expect(manager.temporaryAttribute(.strokeWidth, atCharacterIndex: literal.location, effectiveRange: nil) as? Double == -2)
        #expect(manager.temporaryAttribute(.obliqueness, atCharacterIndex: literal.location, effectiveRange: nil) as? Double == 0.16)
        #expect(manager.temporaryAttribute(.underlineStyle, atCharacterIndex: literal.location, effectiveRange: nil) != nil)
        #expect(manager.temporaryAttribute(.strikethroughStyle, atCharacterIndex: literal.location, effectiveRange: nil) != nil)

        coordinator.update(text: storage.binding, isEditable: true, in: scroll,
            completions: ["users"], editorTheme: sparse)
        for index in [0, literal.location, (storage.text as NSString).range(of: "-- inventory").location] {
            #expect(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
                == sparse.colors["editor.foreground"]?.nsColor)
        }
        for attribute in [NSAttributedString.Key.backgroundColor, .font, .underlineStyle, .strikethroughStyle, .strokeWidth, .obliqueness] {
            #expect(manager.temporaryAttribute(attribute, atCharacterIndex: literal.location, effectiveRange: nil) == nil)
        }
        #expect(editor.selectedTextAttributes[.backgroundColor] as? NSColor == .selectedTextBackgroundColor)
        #expect(editor.selectedTextAttributes[.foregroundColor] as? NSColor == .selectedTextColor)
        editor.complete(nil)
        let panel = try #require(window.childWindows?.first)
        let popupScroll = try #require(panel.contentView as? NSScrollView)
        let table = try #require(popupScroll.documentView as? NSTableView)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        #expect(cell.textField?.textColor == .alternateSelectedControlTextColor)
        #expect(editor.string == storage.text)
        #expect(editor.undoManager?.canUndo == false)
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
        #expect(keyword == SQLSyntaxPalette.keyword)
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

    @Test func executionHighlightFollowsNativeCursorSelectionTypingAndUndo() throws {
        let storage = TextStorage()
        storage.text = "SELECT '😀';\n\nSELECT * FROM people;"
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        var reportedSelection: NSRange?
        coordinator.update(text: storage.binding, isEditable: true, in: scroll,
            selectionChanged: { reportedSelection = $0 })
        let editor = try #require(scroll.documentView as? NSTextView)
        let manager = try #require(editor.layoutManager)
        let first = (storage.text as NSString).range(of: "SELECT '😀'")
        let second = (storage.text as NSString).range(of: "SELECT * FROM people")
        func background(at index: Int) -> NSColor? {
            manager.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
        }

        // Reproduce the screenshot: insertion point just after the first semicolon.
        let cursor = NSRange(location: NSMaxRange(first) + 1, length: 0)
        editor.setSelectedRange(cursor)
        #expect(reportedSelection == cursor)
        #expect(background(at: first.location) != nil)
        #expect(background(at: second.location) == nil)
        #expect(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: first.location, effectiveRange: nil) as? NSColor == SQLSyntaxPalette.keyword)

        editor.setSelectedRange(NSRange(location: second.location + 3, length: 0))
        #expect(background(at: first.location) == nil)
        #expect(background(at: second.location) != nil)

        let selection = (storage.text as NSString).range(of: "* FROM people")
        editor.setSelectedRange(selection)
        #expect(background(at: second.location) == nil)
        #expect(background(at: selection.location) != nil)
        #expect(background(at: NSMaxRange(selection)) == nil)
        #expect(editor.selectedRange() == selection)

        editor.insertText("42", replacementRange: selection)
        #expect(storage.text == "SELECT '😀';\n\nSELECT 42;")
        #expect(reportedSelection == editor.selectedRange())
        #expect(background(at: first.location) == nil)
        #expect(background(at: second.location) != nil)
        editor.undoManager?.undo()
        #expect(storage.text == "SELECT '😀';\n\nSELECT * FROM people;")
        #expect(editor.selectedRange() == selection)
        #expect(background(at: selection.location) != nil)
        #expect(background(at: second.location) == nil)

        storage.text = "-- comment only"
        coordinator.update(text: storage.binding, isEditable: true, in: scroll)
        #expect(background(at: 0) == nil)
    }

    @Test func executionUsesTheNativeCursorAndCachedEditorsCannotRetargetAnotherTab() throws {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let first = workspace.newDocument(text: "SELECT 1;\nSELECT 2;")
        let second = workspace.newDocument(text: "SELECT 3;\nSELECT 4;")
        let firstBinding = Binding(get: { first.text }, set: { first.text = $0 })
        let secondBinding = Binding(get: { second.text }, set: { second.text = $0 })
        let coordinator = SQLEditorView.Coordinator(text: firstBinding)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: firstBinding, isEditable: true, in: scroll,
            editorState: workspace.editorState, documentID: first.id, selectionChanged: { first.selection = $0 })
        let firstEditor = try #require(scroll.documentView as? NSTextView)
        firstEditor.setSelectedRange(NSRange(location: 9, length: 0))
        // Native selection is authoritative even if an update callback was suppressed.
        first.selection = NSRange(location: 12, length: 0)
        #expect(workspace.executionFragment(first)?.sourceSQL == "SELECT 1")

        coordinator.update(text: secondBinding, isEditable: true, in: scroll,
            editorState: workspace.editorState, documentID: second.id, selectionChanged: { second.selection = $0 })
        let secondEditor = try #require(scroll.documentView as? NSTextView)
        secondEditor.setSelectedRange(NSRange(location: 12, length: 0))
        firstEditor.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(second.selection == NSRange(location: 12, length: 0))
        #expect(workspace.executionFragment(second)?.sourceSQL == "SELECT 4")
        #expect(second.text == "SELECT 3;\nSELECT 4;")

        coordinator.update(text: firstBinding, isEditable: true, in: scroll,
            editorState: workspace.editorState, documentID: first.id, selectionChanged: { first.selection = $0 })
        #expect(scroll.documentView === firstEditor)
        #expect(firstEditor.selectedRange() == NSRange(location: 2, length: 0))
        #expect(workspace.executionFragment(first)?.sourceSQL == "SELECT 1")
        #expect(firstEditor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil)
        #expect(firstEditor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 10, effectiveRange: nil) == nil)
    }


}
