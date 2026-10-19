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

    @Test func changingEditorSchemeRestylesOpenCompletionWithoutChangingDocumentOrUndo() async throws {
        let light = try importedTheme(dark: false)
        let dark = try importedTheme(dark: true)
        let storage = TextStorage()
        storage.text = (0..<70).map { "-- Inventory row \($0)" }.joined(separator: "\n") + "\nSELECT us"
        let original = storage.text
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: storage.binding, isEditable: true, in: scroll,
            completions: ["user_id", "users"], editorTheme: light)
        let editor = try #require(scroll.documentView as? SQLTextView)
        let window = try await window(containing: scroll)
        defer { window.close() }
        // A light editor remains light inside a dark application window.
        window.appearance = NSAppearance(named: .darkAqua)
        #expect(editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        #expect(scroll.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
        editor.insertText("e", replacementRange: editor.selectedRange())
        editor.scrollRangeToVisible(editor.selectedRange())
        editor.complete(nil)
        editor.keyDown(with: try key(125))
        #expect(coordinator.visibleCompletionLabels == ["user_id", "users"])
        #expect(coordinator.selectedCompletionIndex == 1)
        let panel = try #require(window.childWindows?.first)
        let originalText = editor.string
        let selection = editor.selectedRange()
        let origin = scroll.contentView.bounds.origin
        let undoName = editor.undoManager?.undoActionName
        #expect(editor.undoManager?.canUndo == true)
        #expect(origin.y > 0)

        window.appearance = NSAppearance(named: .aqua)
        coordinator.update(text: storage.binding, isEditable: true, in: scroll,
            completions: ["user_id", "users"], editorTheme: dark)
        #expect(editor.string == originalText)
        #expect(storage.text == originalText)
        #expect(editor.selectedRange() == selection)
        #expect(scroll.contentView.bounds.origin == origin)
        #expect(editor.undoManager?.undoActionName == undoName)
        #expect(editor.undoManager?.canUndo == true)
        #expect(editor.backgroundColor == dark.colors["editor.background"]?.nsColor)
        #expect(editor.textColor == dark.colors["editor.foreground"]?.nsColor)
        #expect(editor.insertionPointColor == dark.colors["editorCursor.foreground"]?.nsColor)
        #expect(editor.selectedTextAttributes[.backgroundColor] as? NSColor == dark.colors["editor.selectionBackground"]?.nsColor)
        #expect(editor.selectedTextAttributes[.foregroundColor] as? NSColor == dark.colors["editor.selectionForeground"]?.nsColor)
        #expect(editor.currentLineHighlightColor == dark.colors["editor.lineHighlightBackground"]?.nsColor)
        #expect(editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        #expect(scroll.verticalRulerView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        #expect(window.childWindows?.first === panel)
        #expect(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        #expect(coordinator.selectedCompletionIndex == 1)
        let popupScroll = try #require(panel.contentView as? NSScrollView)
        let table = try #require(popupScroll.documentView as? NSTableView)
        #expect(table.backgroundColor == dark.colors["editorSuggestWidget.background"]?.nsColor)
        let selectedCell = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView)
        #expect(selectedCell.textField?.textColor == dark.colors["editorSuggestWidget.selectedForeground"]?.nsColor)
        let keyword = (editor.string as NSString).range(of: "SELECT", options: .backwards)
        let manager = try #require(editor.layoutManager)
        #expect(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: keyword.location, effectiveRange: nil) as? NSColor
            == dark.style(for: ["source.sql", "keyword.other.sql"]).foreground?.nsColor)
        #expect(manager.temporaryAttribute(.strokeWidth, atCharacterIndex: keyword.location, effectiveRange: nil) as? Double == -2)
        #expect(manager.temporaryAttribute(.obliqueness, atCharacterIndex: keyword.location, effectiveRange: nil) as? Double == 0.16)
        #expect(editor.font == .monospacedSystemFont(ofSize: 13, weight: .regular))
        editor.keyDown(with: try key(53))
        editor.undoManager?.undo()
        #expect(storage.text == original)
    }

    @Test func completionMatchHighlightsFollowSelectionThemesAndComposedCharacters() async throws {
        let storage = TextStorage()
        storage.text = "SELECT * FROM oi"
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: storage.binding, isEditable: true, in: scroll)
        let editor = try #require(scroll.documentView as? SQLTextView)
        let window = try await window(containing: scroll)
        editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
        let popup = SQLCompletionPopup()
        defer { popup.hide(); window.close() }
        let range = NSRange(location: storage.text.utf16.count - 2, length: 2)
        popup.show(items: [
            SQLCompletionItem(label: "order_items", detail: "table · public", replacement: "order_items", replacementRange: range,
                matchRanges: [NSRange(location: 0, length: 1), NSRange(location: 6, length: 1)]),
            SQLCompletionItem(label: "OrderItems", detail: "view · Sales", replacement: "OrderItems", replacementRange: range,
                matchRanges: [NSRange(location: 0, length: 1), NSRange(location: 5, length: 1)]),
            SQLCompletionItem(label: "😀órder_items", detail: "Unicode column", replacement: "value", replacementRange: range,
                matchRanges: [NSRange(location: 2, length: 1), NSRange(location: 9, length: 1)])
        ], for: editor, accept: {})
        let panel = try #require(window.childWindows?.first)
        let popupScroll = try #require(panel.contentView as? NSScrollView)
        let table = try #require(popupScroll.documentView as? NSTableView)
        func title(_ row: Int) throws -> NSAttributedString {
            let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
            return try #require(cell.textField?.attributedStringValue)
        }
        for (dark, builtin) in [(false, false), (true, false), (false, true), (true, true)] {
            let base: EditorTheme
            if builtin {
                base = try #require(EditorThemeStore.builtinThemes().first { $0.id == (dark ? "native-dark" : "native-light") })
            } else {
                base = try importedTheme(dark: dark)
            }
            var colors = base.colors
            if !builtin {
                colors["editorSuggestWidget.highlightForeground"] = EditorThemeColor(hex: dark ? "#FFD788" : "#805000")
                colors["editorSuggestWidget.focusHighlightForeground"] = EditorThemeColor(hex: dark ? "#BBE6AA" : "#1133AA")
            }
            let theme = EditorTheme(id: base.id, name: base.name, appearance: base.appearance,
                colors: colors, tokenRules: base.tokenRules, isImported: true)
            popup.applyTheme(theme, appearance: try #require(NSAppearance(named: dark ? .darkAqua : .aqua)))
            popup.moveSelection(by: -100)
            let first = try title(0)
            #expect(first.string == "order_items")
            for index in [0, 6] {
                #expect(first.attribute(.font, at: index, effectiveRange: nil) as? NSFont == .monospacedSystemFont(ofSize: 12, weight: .bold))
                #expect(first.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
                    == colors["editorSuggestWidget.focusHighlightForeground"]?.nsColor)
            }
            #expect(first.attribute(.font, at: 1, effectiveRange: nil) as? NSFont == .monospacedSystemFont(ofSize: 12, weight: .medium))
            popup.moveSelection(by: 1)
            #expect(popup.selectedIndex == 1)
            let unselected = try title(0)
            #expect(unselected.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                == colors["editorSuggestWidget.highlightForeground"]?.nsColor)
            #expect(unselected.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
                == colors["editorSuggestWidget.foreground"]?.nsColor)
            let selected = try title(1)
            #expect(selected.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor
                == colors["editorSuggestWidget.focusHighlightForeground"]?.nsColor)
            let unicode = try title(2)
            #expect(unicode.attribute(.font, at: 1, effectiveRange: nil) as? NSFont == .monospacedSystemFont(ofSize: 12, weight: .medium))
            for index in [2, 3, 9] { // Base o and its combining accent receive the same style.
                #expect(unicode.attribute(.font, at: index, effectiveRange: nil) as? NSFont == .monospacedSystemFont(ofSize: 12, weight: .bold))
            }
            #expect(window.firstResponder === editor)
            #expect(storage.text == "SELECT * FROM oi")
            #expect(editor.selectedRange() == NSRange(location: storage.text.utf16.count, length: 0))
            #expect(editor.undoManager?.canUndo == false)
            try saveQA(popupScroll, name: "completion-matches-" + (builtin ? "dbeer-" : "imported-") + (dark ? "dark" : "light"))
        }
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

    @Test func importedSchemesColorAllSQLRolesDiagnosticsAndMixedAppearanceChrome() async throws {
        let storage = TextStorage()
        storage.text = """
        -- Beer inventory · PostgreSQL
        SELECT b.name, round(b.abv, 1) AS strength
        FROM public.beers AS b
        WHERE b.style = 'IPA' AND b.abv >= 5.5;

        SELECT us
        """
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        let window = try await window(containing: scroll)
        defer { window.close() }
        for dark in [false, true] {
            let theme = try importedTheme(dark: dark)
            window.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
            coordinator.update(text: storage.binding, isEditable: true, in: scroll,
                completions: ["user_id", "users", "user_activity"], errorPosition: 7, editorTheme: theme)
            let editor = try #require(scroll.documentView as? SQLTextView)
            let manager = try #require(editor.layoutManager)
            for (value, scope) in [("-- Beer", "comment.line.sql"), ("SELECT", "keyword.other.sql"),
                                   ("'IPA'", "string.quoted.single.sql"), ("5.5", "constant.numeric.sql"),
                                   ("b.name", "variable.other.sql")] {
                let range = (storage.text as NSString).range(of: value)
                #expect(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor
                    == theme.style(for: ["source.sql", scope]).foreground?.nsColor)
            }
            #expect(manager.temporaryAttribute(.underlineColor, atCharacterIndex: 7, effectiveRange: nil) as? NSColor
                == theme.colors["editorError.foreground"]?.nsColor)
            editor.setSelectedRange((storage.text as NSString).range(of: "b.name, round(b.abv, 1)"))
            try saveQA(scroll, name: "themes-\(dark ? "dark" : "light")-selection")
            editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
            editor.complete(nil)
            #expect(coordinator.visibleCompletionLabels.count == 3)
            try saveQA(scroll, name: "themes-\(dark ? "dark" : "light")-editor")
            let panel = try #require(window.childWindows?.first)
            try saveQA(try #require(panel.contentView), name: "themes-\(dark ? "dark" : "light")-completion")
            editor.keyDown(with: try key(53))
        }
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

    @Test func completionKeyboardReplacesUTF16PrefixAndUndoesAsOneNativeEdit() async throws {
        let storage = TextStorage()
        storage.text = "-- 😀\nSELECT us"
        let original = storage.text
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: storage.binding, isEditable: true, in: scroll, completions: ["user_id", "users"])
        let editor = try #require(scroll.documentView as? NSTextView)
        let window = try await window(containing: scroll)
        defer { window.close() }
        editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
        editor.keyDown(with: try key(49, characters: " ", modifiers: .control))
        #expect(coordinator.visibleCompletionLabels == ["user_id", "users"])
        #expect(window.firstResponder === editor)
        editor.keyDown(with: try key(125))
        #expect(coordinator.selectedCompletionIndex == 1)
        editor.keyDown(with: try key(126))
        #expect(coordinator.selectedCompletionIndex == 0)
        editor.keyDown(with: try key(48, characters: "\t"))
        #expect(storage.text == "-- 😀\nSELECT user_id")
        #expect(editor.selectedRange() == NSRange(location: storage.text.utf16.count, length: 0))
        #expect(coordinator.visibleCompletionLabels.isEmpty)
        editor.undoManager?.undo()
        #expect(storage.text == original)

        editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
        editor.complete(nil)
        editor.keyDown(with: try key(125))
        editor.keyDown(with: try key(36, characters: "\r"))
        #expect(storage.text == "-- 😀\nSELECT users")
        #expect(window.firstResponder === editor)
    }

    @Test func bundledServerCompletesTablesAndAliasColumnsInTheNativeEditor() async throws {
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        for engine in [DatabaseEngine.postgresql, .mysql] {
            let storage = TextStorage()
            storage.text = "SELECT * FROM "
            let language = SQLLanguageService(helperURL: executable)
            let coordinator = SQLEditorView.Coordinator(text: storage.binding)
            let scroll = coordinator.makeScrollView()
            let context = SQLCompletionContext(profileID: UUID(), catalog: [
                SQLCompletionRelation(schema: "public", name: "orders", kind: "table", columns: ["id", "Display Name"])
            ])
            coordinator.update(text: storage.binding, isEditable: true, in: scroll, engine: engine,
                languageService: language, completionContext: context)
            let editor = try #require(scroll.documentView as? NSTextView)
            let window = try await window(containing: scroll)
            defer { window.close() }
            editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
            editor.insertText("ord", replacementRange: editor.selectedRange())
            for _ in 0..<100 where !coordinator.visibleCompletionLabels.contains("orders") {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(coordinator.visibleCompletionLabels == ["orders"])
            editor.keyDown(with: try key(48, characters: "\t"))
            let quote = engine == .postgresql ? "\"" : "`"
            #expect(storage.text == "SELECT * FROM " + quote + "public" + quote + "." + quote + "orders" + quote)

            storage.text = "SELECT o. FROM public.orders o"
            coordinator.update(text: storage.binding, isEditable: true, in: scroll, engine: engine,
                languageService: language, completionContext: context)
            editor.setSelectedRange(NSRange(location: 9, length: 0))
            editor.complete(nil)
            for _ in 0..<100 where !coordinator.visibleCompletionLabels.contains("Display Name") {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(coordinator.visibleCompletionLabels == ["Display Name", "id"])
            editor.keyDown(with: try key(48, characters: "\t"))
            #expect(storage.text == "SELECT o." + quote + "Display Name" + quote + " FROM public.orders o")
            await language.shutdown()
        }
    }

    @Test func bundledServerSearchesAbbreviationsTyposAndPreservesColumnRanking() async throws {
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        for engine in [DatabaseEngine.postgresql, .mysql] {
            let storage = TextStorage()
            let language = SQLLanguageService(helperURL: executable)
            let coordinator = SQLEditorView.Coordinator(text: storage.binding)
            let scroll = coordinator.makeScrollView()
            let context = SQLCompletionContext(profileID: UUID(), catalog: [
                SQLCompletionRelation(schema: "public", name: "order_items", kind: "table", columns: ["order_id"]),
                SQLCompletionRelation(schema: "public", name: "orders", kind: "table", columns: ["count_items"])
            ])
            coordinator.update(text: storage.binding, isEditable: true, in: scroll, engine: engine,
                languageService: language, completionContext: context)
            let editor = try #require(scroll.documentView as? NSTextView)
            let window = try await window(containing: scroll)
            defer { window.close() }
            let quote = engine == .postgresql ? "\"" : "`"
            for (typed, label) in [("oi", "order_items"), ("ordres", "orders")] {
                storage.text = "SELECT * FROM "
                coordinator.update(text: storage.binding, isEditable: true, in: scroll, engine: engine,
                    languageService: language, completionContext: context)
                editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
                editor.insertText(typed, replacementRange: editor.selectedRange())
                let original = storage.text
                for _ in 0..<100 where coordinator.visibleCompletionLabels.first != label {
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(coordinator.visibleCompletionLabels.first == label)
                editor.keyDown(with: try key(48, characters: "\t"))
                #expect(storage.text == "SELECT * FROM " + quote + "public" + quote + "." + quote + label + quote)
                #expect(window.firstResponder === editor)
                editor.undoManager?.undo()
                #expect(storage.text == original)
            }
            storage.text = "SELECT  FROM orders o"
            coordinator.update(text: storage.binding, isEditable: true, in: scroll, engine: engine,
                languageService: language, completionContext: context)
            editor.setSelectedRange(NSRange(location: 7, length: 0))
            editor.insertText("co", replacementRange: editor.selectedRange())
            for _ in 0..<100 where !coordinator.visibleCompletionLabels.contains("COUNT") {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(coordinator.visibleCompletionLabels.first == "count_items")
            #expect(coordinator.visibleCompletionLabels.contains("COUNT"))
            editor.keyDown(with: try key(48, characters: "\t"))
            #expect(storage.text == "SELECT " + quote + "count_items" + quote + " FROM orders o")
            editor.undoManager?.undo()
            #expect(storage.text == "SELECT co FROM orders o")
            await language.shutdown()
        }
    }

    @Test func bundledServerInsertsScopedColumnsAndForeignKeyJoinsWithUndo() async throws {
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        for engine in [DatabaseEngine.postgresql, .mysql] {
            let storage = TextStorage()
            let language = SQLLanguageService(helperURL: executable)
            let coordinator = SQLEditorView.Coordinator(text: storage.binding)
            let scroll = coordinator.makeScrollView()
            let context = SQLCompletionContext(profileID: UUID(), catalog: [
                SQLCompletionRelation(schema: "public", name: "orders", kind: "table", columns: ["id", "customer_id"], foreignKeys: [
                    SQLCompletionForeignKey(name: "customer_fk", targetSchema: "public", targetTable: "customers",
                        columns: [SQLCompletionForeignKeyColumn(source: "customer_id", target: "id")])
                ]),
                SQLCompletionRelation(schema: "public", name: "customers", kind: "table", columns: ["id", "name"])
            ])
            coordinator.update(text: storage.binding, isEditable: true, in: scroll, engine: engine,
                languageService: language, completionContext: context)
            let editor = try #require(scroll.documentView as? NSTextView)
            let window = try await window(containing: scroll)
            defer { window.close() }
            let quote = engine == .postgresql ? "\"" : "`"
            for query in ["WITH recent AS (SELECT id AS order_id FROM orders) SELECT r.or FROM recent r",
                          "SELECT d.or FROM (SELECT id AS order_id FROM orders) d"] {
                storage.text = query
                coordinator.update(text: storage.binding, isEditable: true, in: scroll, engine: engine,
                    languageService: language, completionContext: context)
                editor.setSelectedRange(NSRange(location: NSMaxRange((query as NSString).range(of: ".or")), length: 0))
                editor.complete(nil)
                for _ in 0..<100 where !coordinator.visibleCompletionLabels.contains("order_id") {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(coordinator.visibleCompletionLabels == ["order_id"])
                editor.keyDown(with: try key(48, characters: "\t"))
                #expect(storage.text == query.replacingOccurrences(of: ".or ", with: "." + quote + "order_id" + quote + " "))
                editor.undoManager?.undo()
                #expect(storage.text == query)
            }
            storage.text = "SELECT * FROM orders o JOIN"
            coordinator.update(text: storage.binding, isEditable: true, in: scroll, engine: engine,
                languageService: language, completionContext: context)
            editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
            editor.insertText(" ", replacementRange: editor.selectedRange())
            let original = storage.text
            for _ in 0..<100 where !coordinator.visibleCompletionLabels.contains("customers") {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(coordinator.visibleCompletionLabels.first == "customers")
            editor.keyDown(with: try key(48, characters: "\t"))
            #expect(storage.text == "SELECT * FROM orders o JOIN " + quote + "public" + quote + "." + quote + "customers" + quote
                + " AS " + quote + "c" + quote + " ON " + quote + "o" + quote + "." + quote + "customer_id" + quote
                + " = " + quote + "c" + quote + "." + quote + "id" + quote)
            editor.undoManager?.undo()
            #expect(storage.text == original)
            await language.shutdown()
        }
    }

    @Test func functionSignaturesFollowTypingCursorEscapeAndNativeUndo() async throws {
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        for engine in [DatabaseEngine.postgresql, .mysql] {
            let storage = TextStorage()
            storage.text = "SELECT NULLIF"
            let language = SQLLanguageService(helperURL: executable)
            let coordinator = SQLEditorView.Coordinator(text: storage.binding)
            let scroll = coordinator.makeScrollView()
            coordinator.update(text: storage.binding, isEditable: true, in: scroll, engine: engine, languageService: language)
            let editor = try #require(scroll.documentView as? NSTextView)
            let window = try await window(containing: scroll)
            defer { window.close() }
            editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
            editor.insertText("(", replacementRange: editor.selectedRange())
            for _ in 0..<100 where !coordinator.activeSignatureParameterTexts.contains("value1: any") {
                try await Task.sleep(for: .milliseconds(15))
            }
            #expect(coordinator.activeSignatureParameterTexts == ["value1: any"])
            #expect(coordinator.visibleSignatureLabels.first?.hasSuffix(" → type of value1") == true)
            editor.insertText("LOWER('a,b'), ", replacementRange: editor.selectedRange())
            for _ in 0..<100 where !coordinator.activeSignatureParameterTexts.contains("value2: any") {
                try await Task.sleep(for: .milliseconds(15))
            }
            #expect(coordinator.activeSignatureParameterTexts == ["value2: any"])
            #expect(window.firstResponder === editor)
            let original = storage.text
            let argument = (storage.text as NSString).range(of: "'a,b'")
            editor.setSelectedRange(NSRange(location: argument.location + 2, length: 0))
            for _ in 0..<100 where coordinator.visibleSignatureLabels.first?.hasPrefix("LOWER(") != true {
                try await Task.sleep(for: .milliseconds(15))
            }
            #expect(coordinator.activeSignatureParameterTexts == [engine == .postgresql ? "value: text" : "value: string"])
            #expect(storage.text == original)
            editor.keyDown(with: try key(53))
            try await Task.sleep(for: .milliseconds(120))
            #expect(coordinator.visibleSignatureLabels.isEmpty)
            editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
            for _ in 0..<100 where !coordinator.activeSignatureParameterTexts.contains("value2: any") {
                try await Task.sleep(for: .milliseconds(15))
            }
            #expect(coordinator.activeSignatureParameterTexts == ["value2: any"])
            editor.breakUndoCoalescing()
            editor.insertText("1)", replacementRange: editor.selectedRange())
            editor.breakUndoCoalescing()
            for _ in 0..<100 where !coordinator.visibleSignatureLabels.isEmpty { try await Task.sleep(for: .milliseconds(15)) }
            #expect(coordinator.visibleSignatureLabels.isEmpty)
            editor.undoManager?.undo()
            #expect(storage.text == original)
            for _ in 0..<100 where coordinator.visibleSignatureLabels.isEmpty { try await Task.sleep(for: .milliseconds(15)) }
            #expect(coordinator.activeSignatureParameterTexts == ["value2: any"])
            window.makeFirstResponder(nil)
            #expect(coordinator.visibleSignatureLabels.isEmpty)
            coordinator.detach(from: scroll)
            await language.shutdown()
        }
    }

    @Test func signaturePanelHighlightsParametersAndSupportsBothEditorThemes() async throws {
        let storage = TextStorage()
        storage.text = "SELECT SUBSTRING('hello', 1, "
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        let editor = try #require(scroll.documentView as? NSTextView)
        let window = try await window(containing: scroll)
        defer { window.close() }
        let popup = SQLSignaturePopup()
        defer { popup.hide() }
        let label = "SUBSTRING(value: text, start: integer, count: integer = DEFAULT) → text"
        let range = (label as NSString).range(of: "count: integer = DEFAULT")
        let help = SQLSignatureHelp(signatures: [SQLSignatureInformation(label: label, parameterRanges: [range], activeParameter: 0)], activeSignature: 0)
        for dark in [false, true] {
            let theme = try importedTheme(dark: dark)
            coordinator.update(text: storage.binding, isEditable: true, in: scroll, editorTheme: theme)
            editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
            popup.show(help, for: editor)
            #expect(popup.isVisible && popup.highlightedRanges == [range])
            let panel = try #require(window.childWindows?.first { $0.identifier?.rawValue == "sqlSignaturePopup" || $0.contentView is NSScrollView })
            #expect(!panel.canBecomeKey && window.firstResponder === editor)
            let signatureScroll = try #require(panel.contentView as? NSScrollView)
            let signatureText = try #require(signatureScroll.documentView as? NSTextView)
            #expect(signatureText.string == label)
            #expect(signatureText.textStorage?.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil)
            #expect(signatureText.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
            #expect(panel.frame.width <= 540 && panel.frame.height >= 36)
            try saveQA(signatureScroll, name: "function-signatures-" + (dark ? "dark" : "light"))
            #expect(storage.text == "SELECT SUBSTRING('hello', 1, ")
        }
    }

    @Test func programmaticCaretScrollPreservesCompletionsUntilCaretLeavesViewport() async throws {
        let storage = TextStorage()
        storage.text = String(repeating: "SELECT 1;\n", count: 50) + "SELECT us"
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: storage.binding, isEditable: true, in: scroll, completions: ["user_id", "users"])
        let editor = try #require(scroll.documentView as? NSTextView)
        let window = try await window(containing: scroll)
        defer { window.close() }
        editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        scroll.layoutSubtreeIfNeeded()
        editor.complete(nil)
        editor.keyDown(with: try key(125))
        var origin = scroll.contentView.bounds.origin
        try #require(origin.y > 2)
        origin.y -= 2
        scroll.contentView.scroll(to: origin)
        #expect(coordinator.visibleCompletionLabels == ["user_id", "users"])
        #expect(coordinator.selectedCompletionIndex == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.visibleCompletionLabels == ["user_id", "users"])
        scroll.contentView.scroll(to: .zero)
        #expect(coordinator.visibleCompletionLabels.isEmpty)
    }

    @Test func automaticCompletionEscapeSelectionAndDocumentChangesDiscardPendingSuggestions() async throws {
        let first = TextStorage()
        let second = TextStorage()
        let state = SQLEditorState()
        let firstID = UUID()
        let secondID = UUID()
        let coordinator = SQLEditorView.Coordinator(text: first.binding)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: first.binding, isEditable: true, in: scroll,
            editorState: state, documentID: firstID, completions: ["users"])
        let editor = try #require(scroll.documentView as? NSTextView)
        let window = try await window(containing: scroll)
        defer { window.close() }
        editor.insertText("us", replacementRange: editor.selectedRange())
        editor.keyDown(with: try key(53))
        try await Task.sleep(for: .milliseconds(240))
        #expect(coordinator.visibleCompletionLabels.isEmpty)
        #expect(first.text == "us")

        editor.insertText("e", replacementRange: editor.selectedRange())
        for _ in 0..<50 where coordinator.visibleCompletionLabels.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(coordinator.visibleCompletionLabels == ["users"])
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(coordinator.visibleCompletionLabels.isEmpty)
        editor.setSelectedRange(NSRange(location: first.text.utf16.count, length: 0))
        editor.insertText("r", replacementRange: editor.selectedRange())
        coordinator.update(text: second.binding, isEditable: true, in: scroll,
            editorState: state, documentID: secondID, completions: ["orders"])
        try await Task.sleep(for: .milliseconds(240))
        #expect(coordinator.visibleCompletionLabels.isEmpty)
        #expect(second.text.isEmpty)
        #expect(first.text == "user")
        #expect(window.firstResponder === scroll.documentView)

        let secondEditor = try #require(scroll.documentView as? NSTextView)
        secondEditor.insertText("or", replacementRange: secondEditor.selectedRange())
        coordinator.update(text: second.binding, isEditable: false, in: scroll,
            editorState: state, documentID: secondID, engine: .mysql, completions: ["orders"])
        try await Task.sleep(for: .milliseconds(240))
        #expect(coordinator.visibleCompletionLabels.isEmpty)
        #expect(second.text == "or")
    }

    @Test func completionSuppressesCommentsAndLiteralBodiesAndFallsBackWithoutLanguageServer() async throws {
        let storage = TextStorage()
        let service = SQLLanguageService(helperURL: URL(fileURLWithPath: "/nonexistent/dbeer-helper"))
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        let window = try await window(containing: scroll)
        defer { window.close() }
        let editor = try #require(scroll.documentView as? NSTextView)
        for (engine, sql) in [(DatabaseEngine.postgresql, "-- us"), (.postgresql, "SELECT 'us"),
                              (.postgresql, "SELECT $$us"), (.mysql, "# us"), (.mysql, "SELECT \"us"),
                              (.postgresql, "/* us")] {
            storage.text = sql
            coordinator.update(text: storage.binding, isEditable: true, in: scroll, engine: engine,
                completions: ["users"], languageService: service)
            editor.setSelectedRange(NSRange(location: sql.utf16.count, length: 0))
            editor.complete(nil)
            #expect(coordinator.visibleCompletionLabels.isEmpty)
        }
        storage.text = "SELECT us"
        coordinator.update(text: storage.binding, isEditable: true, in: scroll,
            completions: ["users"], languageService: service)
        editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
        editor.complete(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!service.isAvailable)
        #expect(coordinator.visibleCompletionLabels == ["users"])
        editor.keyDown(with: try key(36, characters: "\r"))
        #expect(storage.text == "SELECT users")

        for (sql, cursor, expected) in [("SELECT \"Mi\"", 10, "SELECT \"Mixed Name\""),
                                         ("SELECT users", 9, "SELECT user_id")] {
            storage.text = sql
            coordinator.update(text: storage.binding, isEditable: true, in: scroll,
                completions: ["Mixed Name", "user_id"], languageService: service)
            editor.undoManager?.removeAllActions()
            editor.setSelectedRange(NSRange(location: cursor, length: 0))
            editor.complete(nil)
            for _ in 0..<100 where coordinator.visibleCompletionLabels.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(coordinator.visibleCompletionLabels.count == 1)
            editor.keyDown(with: try key(48, characters: "\t"))
            #expect(storage.text == expected)
            editor.undoManager?.undo()
            #expect(storage.text == sql)
        }
        await service.shutdown()
    }

    @Test func detachingEditorDismissesItsPanelAndPendingCompletion() async throws {
        let storage = TextStorage()
        storage.text = "SELECT us"
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: storage.binding, isEditable: true, in: scroll, completions: ["users"])
        let editor = try #require(scroll.documentView as? NSTextView)
        let window = try await window(containing: scroll)
        defer { window.close() }
        editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
        editor.complete(nil)
        #expect(coordinator.visibleCompletionLabels == ["users"])
        #expect(window.childWindows?.isEmpty == false)
        window.contentView = NSView(frame: scroll.frame)
        #expect(coordinator.visibleCompletionLabels.isEmpty)
        #expect(window.childWindows?.isEmpty != false)

        window.contentView = scroll
        try #require(window.makeFirstResponder(editor))
        editor.insertText("e", replacementRange: editor.selectedRange())
        SQLEditorView.dismantleNSView(scroll, coordinator: coordinator)
        try await Task.sleep(for: .milliseconds(240))
        #expect(coordinator.visibleCompletionLabels.isEmpty)
        #expect(window.childWindows?.isEmpty != false)
        #expect(storage.text == "SELECT use")
        #expect(editor.delegate == nil)
    }

    @Test func editorAndCompletionAppearanceInBothThemesAndVisibleGutterOnLongScripts() async throws {
        let storage = TextStorage()
        storage.text = """
        -- Beer inventory · PostgreSQL
        SELECT b.name, round(b.abv, 1) AS strength
        FROM public.beers AS b
        WHERE b.style = 'IPA' AND b.abv >= 5.5;

        SELECT us
        """
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: storage.binding, isEditable: true, in: scroll,
            completions: ["user_id", "users", "user_activity"])
        let editor = try #require(scroll.documentView as? SQLTextView)
        let window = try await window(containing: scroll)
        defer { window.close() }
        #expect(editor.textContainerInset == NSSize(width: 12, height: 12))
        #expect(editor.defaultParagraphStyle?.lineSpacing == 3)
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            let resolvedAppearance = try #require(window.appearance)
            var palette: [NSColor] = []
            var background: NSColor?
            resolvedAppearance.performAsCurrentDrawingAppearance {
                palette = [SQLSyntaxPalette.keyword, SQLSyntaxPalette.string, SQLSyntaxPalette.number].compactMap { $0.usingColorSpace(.sRGB) }
                background = NSColor.textBackgroundColor.usingColorSpace(.sRGB)
            }
            let backdrop = try #require(background)
            #expect(palette.count == 3)
            func luminance(_ color: NSColor) -> Double {
                let linear: (CGFloat) -> Double = { value in
                    let value = Double(value)
                    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
            }
            for color in palette {
                let light = max(luminance(color), luminance(backdrop))
                let dark = min(luminance(color), luminance(backdrop))
                #expect((light + 0.05) / (dark + 0.05) >= 4.5)
            }
            let blankLine = (storage.text as NSString).range(of: ";\n\n").location + 2
            editor.setSelectedRange(NSRange(location: blankLine, length: 0))
            try saveQA(scroll, name: "r33-r34-current-line-" + theme)
            editor.setSelectedRange((storage.text as NSString).range(of: "b.name, round(b.abv, 1)"))
            try saveQA(scroll, name: "r33-r34-selection-" + theme)
            editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
            editor.complete(nil)
            try await Task.sleep(for: .milliseconds(30))
            #expect(editor.currentLineHighlightRect?.height ?? 0 > 0)
            #expect(editor.currentLineHighlightRect?.minY ?? 0 > editor.textContainerOrigin.y)
            #expect(coordinator.visibleCompletionLabels.count == 3)
            #expect(window.firstResponder === editor)
            #expect(editor.layoutManager?.temporaryAttribute(.backgroundColor,
                atCharacterIndex: storage.text.utf16.count - 1, effectiveRange: nil) != nil)
            try saveQA(scroll, name: "r33-r34-editor-" + theme)
            let panel = try #require(window.childWindows?.first)
            #expect(!panel.canBecomeKey)
            try saveQA(try #require(panel.contentView), name: "r33-r34-completion-" + theme)
            editor.keyDown(with: try key(53))
        }

        storage.text = (0..<20_000).map { "SELECT \($0);" }.joined(separator: "\n")
        coordinator.update(text: storage.binding, isEditable: true, in: scroll, completions: ["users"])
        editor.setSelectedRange(NSRange(location: storage.text.utf16.count - 8, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        scroll.displayIfNeeded()
        let ruler = try #require(scroll.verticalRulerView as? SQLLineNumberRuler)
        ruler.display()
        #expect(ruler.lastDrawnLineCount > 0)
        #expect(ruler.lastDrawnLineCount < 100)
        #expect(editor.selectedRange().location > 200_000)
        try saveQA(scroll, name: "r33-r34-long-script")
        editor.setSelectedRange(NSRange(location: storage.text.utf16.count, length: 0))
        editor.insertText("\nSELECT us", replacementRange: editor.selectedRange())
        for _ in 0..<50 where coordinator.visibleCompletionLabels.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(coordinator.visibleCompletionLabels == ["users"])
    }
}
