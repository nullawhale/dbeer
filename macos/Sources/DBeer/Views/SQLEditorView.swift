import AppKit
import SwiftUI

/// Native views retain selection and a separate undo manager for every document,
/// including while SwiftUI unmounts that document's editor.
@MainActor
final class SQLEditorState {
    let languageService = SQLLanguageService()
    fileprivate var editors: [UUID: SQLTextView] = [:]
    fileprivate var scrollOrigins: [UUID: NSPoint] = [:]
    fileprivate var focusRequest: (documentID: UUID, condition: @MainActor () -> Bool)?

    func requestFocus(_ documentID: UUID, condition: @escaping @MainActor () -> Bool) {
        focusRequest = (documentID, condition)
    }

    func selection(for documentID: UUID, fallback: NSRange = NSRange(location: 0, length: 0)) -> NSRange {
        editors[documentID]?.selectedRange() ?? fallback
    }

    func hasMultipleSelections(for documentID: UUID) -> Bool {
        editors[documentID]?.hasMultipleEditorSelections == true
    }

    func editor(for documentID: UUID) -> SQLTextView? { editors[documentID] }

    func prepareForPaneMove(_ documentID: UUID) {
        guard let editor = editors[documentID], editor.window?.firstResponder === editor else { return }
        editor.restoreFocusAfterPaneMove = true
    }

    func removeDocument(_ documentID: UUID) {
        if focusRequest?.documentID == documentID { focusRequest = nil }
        languageService.close(documentID: documentID)
        editors[documentID]?.dismissCompletion?()
        editors[documentID]?.editorTools?.detach()
        editors[documentID] = nil
        scrollOrigins[documentID] = nil
    }
}

struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var editorState: SQLEditorState?
    var documentID: UUID?
    var engine: DatabaseEngine = .postgresql
    var selectionChanged: ((NSRange) -> Void)?
    var onRunSelection: ((NSRange) -> Void)?
    var onCommandEvent: ((NSEvent, NSRange) -> Bool)?
    var completions: [String] = []
    var languageService: SQLLanguageService?
    var completionContext: SQLCompletionContext = .empty
    /// A zero-based UTF-16 offset in the document, matching NSTextView ranges.
    var errorPosition: Int?
    /// A resolved scheme is independent from the surrounding window appearance.
    var editorTheme: EditorTheme? = nil
    var successfulExecutionRanges: [NSRange] = []

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = context.coordinator.makeScrollView()
        update(scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        update(scrollView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach(from: scrollView)
    }

    private func update(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.update(text: $text, isEditable: isEditable, in: scrollView,
            editorState: editorState, documentID: documentID, engine: engine,
            selectionChanged: selectionChanged, onRunSelection: onRunSelection, onCommandEvent: onCommandEvent,
            completions: completions, errorPosition: errorPosition,
            languageService: languageService, completionContext: completionContext, editorTheme: editorTheme,
            successfulExecutionRanges: successfulExecutionRanges)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        private let localState = SQLEditorState()
        private let localDocumentID = UUID()
        private var activeState: SQLEditorState?
        private var activeDocumentID: UUID?
        private var engine: DatabaseEngine = .postgresql
        private var selectionChanged: ((NSRange) -> Void)?
        private var onRunSelection: ((NSRange) -> Void)?
        private var onCommandEvent: ((NSEvent, NSRange) -> Bool)?
        private var completionCandidates: [String] = []
        private var errorPosition: Int?
        private var parsedText: String?
        private var parsedEngine: DatabaseEngine?
        private var parsedResult: SQLParseResult?
        private let backgroundParser = SQLEditorBackgroundParser()
        private var backgroundParseTask: Task<Void, Never>?
        private var backgroundParseText: String?
        private var backgroundParseEngine: DatabaseEngine?
        private let backgroundParseThreshold = 128 * 1024
        private var lastScrolledError: Int?
        private var isUpdating = false
        private var languageService: SQLLanguageService?
        private var diagnosticsObserver: UUID?
        private var completionContext: SQLCompletionContext = .empty
        private var completionTask: Task<Void, Never>?
        private var completionGeneration = 0
        private let completionPopup = SQLCompletionPopup()
        private var completionSnapshot: CompletionSnapshot?
        private var completionSuppressedSnapshot: CompletionSnapshot?
        private var pendingLargeCompletion: (snapshot: CompletionSnapshot, explicit: Bool)?
        private var signatureTask: Task<Void, Never>?
        private var signatureGeneration = 0
        private var signatureSnapshot: CompletionSnapshot?
        private var signatureSuppressedSnapshot: CompletionSnapshot?
        private let signaturePopup = SQLSignaturePopup()
        private var editorTheme: EditorTheme?
        private var tokenStyles: [[String]: EditorThemeTokenStyle] = [:]

        private struct CompletionSnapshot: Equatable {
            let documentID: UUID
            let text: String
            let selection: NSRange
            let engine: DatabaseEngine
            let context: SQLCompletionContext
        }

        var visibleCompletionLabels: [String] { completionPopup.items.map(\.label) }
        var selectedCompletionIndex: Int? { completionPopup.selectedIndex }
        var visibleSignatureLabels: [String] { signaturePopup.help?.signatures.map(\.label) ?? [] }
        var activeSignatureParameterTexts: [String] {
            signaturePopup.help?.signatures.compactMap { signature in
                signature.activeParameterRange.map { (signature.label as NSString).substring(with: $0) }
            } ?? []
        }

        deinit {
            completionTask?.cancel()
            signatureTask?.cancel()
            backgroundParseTask?.cancel()
            let service = languageService
            let observer = diagnosticsObserver
            let popup = completionPopup
            let signaturePopup = signaturePopup
            Task { @MainActor in
                popup.hide()
                signaturePopup.hide()
                if let observer { service?.removeDiagnosticsObserver(observer) }
            }
        }

        init(text: Binding<String>) { self.text = text }

        func detach(from scrollView: NSScrollView) {
            backgroundParseTask?.cancel()
            backgroundParseText = nil
            dismissCompletions()
            dismissSignatures()
            if let diagnosticsObserver { languageService?.removeDiagnosticsObserver(diagnosticsObserver) }
            diagnosticsObserver = nil
            languageService = nil
            // A move can mount the cached editor in its new pane before the old
            // representable dismantles. Only its current coordinator may clear
            // delegates, command closures or the saved viewport.
            if let editor = scrollView.documentView as? SQLTextView,
               editor.delegate === self, editor.enclosingScrollView === scrollView {
                if let activeDocumentID { activeState?.scrollOrigins[activeDocumentID] = scrollView.contentView.bounds.origin }
                editor.delegate = nil
                editor.requestCompletion = nil
                editor.dismissCompletion = nil
                editor.viewportChanged = nil
                editor.completionKey = nil
                editor.runSelection = nil
                editor.commandEvent = nil
            }
            activeState = nil
            activeDocumentID = nil
        }

        func makeScrollView() -> NSScrollView {
            let scrollView = SQLScrollView(frame: .zero)
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.focusRingType = .none
            let textView = editor(in: localState, documentID: localDocumentID)
            scrollView.documentView = textView
            installRuler(in: scrollView, textView: textView)
            activeState = localState
            activeDocumentID = localDocumentID
            return scrollView
        }

        private func editor(in state: SQLEditorState, documentID: UUID) -> SQLTextView {
            if let cached = state.editors[documentID] {
                if let oldScroll = cached.enclosingScrollView {
                    state.scrollOrigins[documentID] = oldScroll.contentView.bounds.origin
                }
                cached.dismissCompletion?()
                cached.delegate = self
                return cached
            }
            let textView = SQLTextView(frame: .zero)
            textView.textContainer?.replaceLayoutManager(SQLFoldingLayoutManager())
            textView.delegate = self
            textView.focusRingType = .none
            textView.canDrawConcurrently = false
            textView.isRichText = false
            textView.importsGraphics = false
            textView.allowsUndo = true
            textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            textView.textColor = .labelColor
            textView.insertionPointColor = .labelColor
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor,
                .foregroundColor: NSColor.selectedTextColor]
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            textView.defaultParagraphStyle = paragraph
            textView.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            textView.textContainerInset = NSSize(width: 12, height: 12)
            textView.textContainer?.lineFragmentPadding = 0
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.minSize = .zero
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isAutomaticTextCompletionEnabled = false
            textView.isAutomaticLinkDetectionEnabled = false
            textView.isAutomaticDataDetectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.isGrammarCheckingEnabled = false
            textView.smartInsertDeleteEnabled = false
            textView.setAccessibilityLabel("SQL editor")
            textView.setAccessibilityIdentifier("sqlEditor")
            if let request = state.focusRequest, request.documentID == documentID {
                textView.focusOnAttach = request.condition
                state.focusRequest = nil
            }
            state.editors[documentID] = textView
            return textView
        }

        private func installRuler(in scrollView: NSScrollView, textView: SQLTextView) {
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
            scrollView.verticalRulerView = SQLLineNumberRuler(scrollView: scrollView, textView: textView)
        }

        func update(text: Binding<String>, isEditable: Bool, in scrollView: NSScrollView,
                    editorState: SQLEditorState? = nil, documentID: UUID? = nil,
                    engine: DatabaseEngine = .postgresql, selectionChanged: ((NSRange) -> Void)? = nil,
                    onRunSelection: ((NSRange) -> Void)? = nil, onCommandEvent: ((NSEvent, NSRange) -> Bool)? = nil,
                    completions: [String] = [], errorPosition: Int? = nil,
                    languageService: SQLLanguageService? = nil, completionContext: SQLCompletionContext = .empty,
                    editorTheme: EditorTheme? = nil, successfulExecutionRanges: [NSRange] = []) {
            if self.languageService !== languageService {
                dismissCompletions()
                dismissSignatures()
                if let diagnosticsObserver { self.languageService?.removeDiagnosticsObserver(diagnosticsObserver) }
                self.languageService = languageService
                diagnosticsObserver = languageService?.addDiagnosticsObserver { [weak self] documentID, _ in
                    guard let self, self.activeDocumentID == documentID,
                          let editor = self.activeState?.editors[documentID], editor.delegate === self else { return }
                    self.highlight(editor)
                }
            }
            if self.engine != engine || self.completionContext != completionContext { dismissCompletions(); dismissSignatures() }
            self.completionContext = completionContext
            self.text = text
            self.engine = engine
            self.selectionChanged = selectionChanged
            self.onRunSelection = onRunSelection
            self.onCommandEvent = onCommandEvent
            if self.completionCandidates != completions { dismissCompletions() }
            self.completionCandidates = completions
            self.errorPosition = errorPosition
            if self.editorTheme != editorTheme { tokenStyles.removeAll(keepingCapacity: true) }
            self.editorTheme = editorTheme
            let state = editorState ?? localState
            let id = documentID ?? localDocumentID
            isUpdating = true
            defer { isUpdating = false }
            if activeState !== state || activeDocumentID != id {
                if let oldID = activeDocumentID, let oldEditor = scrollView.documentView as? SQLTextView,
                   oldEditor.delegate === self, oldEditor.enclosingScrollView === scrollView {
                    activeState?.scrollOrigins[oldID] = scrollView.contentView.bounds.origin
                }
                dismissCompletions()
                dismissSignatures()
                let hadFocus = scrollView.window?.firstResponder === scrollView.documentView
                let cachedHadFocus = state.editors[id].map { $0.window?.firstResponder === $0 } ?? false
                let next = editor(in: state, documentID: id)
                if cachedHadFocus { next.restoreFocusAfterPaneMove = true }
                scrollView.documentView = next
                if hadFocus || cachedHadFocus { scrollView.window?.makeFirstResponder(next) }
                installRuler(in: scrollView, textView: next)
                activeState = state
                activeDocumentID = id
                lastScrolledError = nil
                if let origin = state.scrollOrigins[id] {
                    scrollView.contentView.scroll(to: origin)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
            guard let textView = scrollView.documentView as? SQLTextView,
                  textView.enclosingScrollView === scrollView else { return }
            textView.applyTheme(editorTheme)
            scrollView.appearance = textView.appearance
            scrollView.backgroundColor = textView.backgroundColor
            scrollView.verticalRulerView?.appearance = textView.appearance
            completionPopup.applyTheme(editorTheme, appearance: textView.effectiveAppearance)
            signaturePopup.applyTheme(editorTheme, appearance: textView.effectiveAppearance)
            textView.appCommandDocumentID = documentID
            textView.editorEngine = engine
            if textView.editorTools == nil { textView.editorTools = SQLEditorToolsController() }
            textView.editorTools?.configure(editor: textView, documentID: id, engine: engine,
                languageService: languageService, completionContext: completionContext)
            textView.requestCompletion = { [weak self, weak textView] in
                guard let textView else { return }
                self?.requestCompletion(in: textView, explicit: true)
                self?.signatureSuppressedSnapshot = nil
                self?.requestSignatureHelp(in: textView)
            }
            textView.dismissCompletion = { [weak self] in self?.dismissCompletions(); self?.dismissSignatures() }
            textView.viewportChanged = { [weak self, weak textView] in
                guard let self, let textView else { return }
                guard textView.currentLineHighlightRect?.intersects(textView.visibleRect) == true else {
                    self.dismissCompletions()
                    self.dismissSignatures()
                    return
                }
                if self.completionSnapshot == self.snapshot(for: textView) { self.completionPopup.reposition(for: textView) }
                if self.signatureSnapshot == self.snapshot(for: textView) { self.signaturePopup.reposition(for: textView) }
            }
            textView.completionKey = { [weak self, weak textView] event in
                guard let textView else { return false }
                return self?.handleCompletionKey(event, in: textView) ?? false
            }
            textView.delegate = self
            if onRunSelection != nil {
                textView.runSelection = { [weak self] in self?.onRunSelection?($0) }
            } else { textView.runSelection = nil }
            textView.commandEvent = onCommandEvent.map { _ in { [weak self] event, selection in
                self?.onCommandEvent?(event, selection) ?? false
            } }
            if !isEditable { dismissCompletions(); dismissSignatures() }
            textView.isEditable = isEditable
            textView.isSelectable = true
            if textView.string != text.wrappedValue {
                dismissCompletions()
                dismissSignatures()
                let selection = textView.editorSelections
                textView.string = text.wrappedValue
                let length = textView.string.utf16.count
                textView.setEditorSelections(selection.map { range in
                    let location = min(range.location, length)
                    return NSRange(location: location, length: min(range.length, length - location))
                })
            }
            languageService?.update(documentID: id, text: textView.string, engine: engine, context: completionContext)
            let sourceLength = textView.string.utf16.count
            textView.successfulExecutionLocations = Set(successfulExecutionRanges.compactMap { range in
                range.location >= 0 && range.location < sourceLength && range.length > 0 &&
                    range.length <= sourceLength - range.location
                    ? range.location : nil
            })
            highlight(textView)
            (scrollView.verticalRulerView as? SQLLineNumberRuler)?.updateLines()
            if let errorPosition, errorPosition != lastScrolledError {
                let location = min(max(0, errorPosition), textView.string.utf16.count)
                textView.editorTools?.reveal(NSRange(location: location, length: 0))
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
                lastScrolledError = errorPosition
            } else if errorPosition == nil { lastScrolledError = nil }
            requestSignatureHelp(in: textView)
        }

        private func parse(_ value: String) -> SQLParseResult {
            if parsedText == value, parsedEngine == engine, let parsedResult { return parsedResult }
            if (value as NSString).length > backgroundParseThreshold {
                if backgroundParseText != value || backgroundParseEngine != engine {
                    backgroundParseTask?.cancel()
                    backgroundParseText = value
                    backgroundParseEngine = engine
                    let dialect = engine
                    let worker = backgroundParser
                    backgroundParseTask = Task { [weak self] in
                        let result = await worker.parse(value, engine: dialect)
                        guard !Task.isCancelled, let self, self.engine == dialect,
                              self.backgroundParseText == value else { return }
                        self.backgroundParseText = nil
                        self.backgroundParseTask = nil
                        guard let result, let id = self.activeDocumentID, let editor = self.activeState?.editors[id],
                              editor.delegate === self, editor.string == value else { return }
                        self.parsedText = value
                        self.parsedEngine = dialect
                        self.parsedResult = result
                        editor.syntaxText = nil
                        self.highlight(editor)
                        if let pending = self.pendingLargeCompletion, self.snapshot(for: editor) == pending.snapshot {
                            self.pendingLargeCompletion = nil
                            self.requestCompletion(in: editor, explicit: pending.explicit)
                        }
                    }
                }
                return SQLParseResult(statements: [], statementEditorRanges: [], tokens: [], diagnostics: [])
            }
            backgroundParseTask?.cancel()
            backgroundParseText = nil
            let result = SQLScriptParser.parse(value, engine: engine)
            parsedText = value
            parsedEngine = engine
            parsedResult = result
            return result
        }

        private func highlight(_ textView: NSTextView) {
            guard let manager = textView.layoutManager else { return }
            let full = NSRange(location: 0, length: textView.string.utf16.count)
            let parsed = parse(textView.string)
            guard (textView.string as NSString).length <= backgroundParseThreshold || parsedText == textView.string else { return }
            highlightExecutionFragment(textView)
            let languageDiagnostics = activeDocumentID.flatMap { languageService?.diagnostics(documentID: $0) } ?? []
            if let editor = textView as? SQLTextView {
                guard editor.syntaxText != textView.string || editor.syntaxEngine != engine ||
                        editor.syntaxDiagnostics != languageDiagnostics || editor.syntaxErrorPosition != errorPosition ||
                        editor.syntaxTheme != editorTheme else { return }
                editor.protectedParse = parsed
                editor.syntaxText = textView.string
                editor.syntaxEngine = engine
                editor.syntaxDiagnostics = languageDiagnostics
                editor.syntaxErrorPosition = errorPosition
                editor.syntaxTheme = editorTheme
            }
            for key in [NSAttributedString.Key.foregroundColor, .font, .underlineColor, .underlineStyle,
                        .strikethroughStyle, .strikethroughColor, .obliqueness, .strokeWidth] {
                manager.removeTemporaryAttribute(key, forCharacterRange: full)
            }
            for token in parsed.tokens {
                let color: NSColor
                let scopes: [String]
                switch token.kind {
                case .keyword: color = SQLSyntaxPalette.keyword; scopes = ["source.sql", "keyword.other.sql"]
                case .string: color = SQLSyntaxPalette.string; scopes = syntaxScopes(for: token, in: textView.string)
                case .identifier: color = textView.textColor ?? .labelColor; scopes = ["source.sql", "entity.name.sql", "variable.other.sql"]
                case .number: color = SQLSyntaxPalette.number; scopes = ["source.sql", "constant.numeric.sql"]
                case .comment: color = .secondaryLabelColor; scopes = syntaxScopes(for: token, in: textView.string)
                }
                let style = tokenStyle(for: scopes)
                let fallback = editorTheme == nil ? color : (textView.textColor ?? .labelColor)
                manager.addTemporaryAttribute(.foregroundColor, value: style?.foreground?.nsColor ?? fallback,
                    forCharacterRange: token.range)
                if let fontStyle = style?.fontStyle {
                    let traits = Set(fontStyle.split(separator: " ").map(String.init))
                    // Temporary font attributes do not affect NSLayoutManager
                    // drawing. These drawing traits preserve monospaced metrics,
                    // selection and viewport while honoring theme emphasis.
                    if traits.contains("bold") {
                        manager.addTemporaryAttribute(.strokeWidth, value: -2.0, forCharacterRange: token.range)
                    }
                    if traits.contains("italic") {
                        manager.addTemporaryAttribute(.obliqueness, value: 0.16, forCharacterRange: token.range)
                    }
                    if traits.contains("underline") {
                        manager.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                            forCharacterRange: token.range)
                    }
                    if traits.contains("strikethrough") {
                        manager.addTemporaryAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                            forCharacterRange: token.range)
                    }
                }
            }
            textView.toolTip = (parsed.diagnostics.map(\.message) + languageDiagnostics.map(\.message)).joined(separator: "\n")
            var ranges = parsed.diagnostics.map(\.range) + languageDiagnostics.map(\.range)
            if let errorPosition, full.length > 0 {
                ranges.append(NSRange(location: min(max(0, errorPosition), full.length - 1), length: 1))
            }
            for range in ranges where range.location != NSNotFound && range.location < full.length && range.length > 0 {
                let range = NSIntersectionRange(range, full)
                manager.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: editorTheme?.color("editorError.foreground", default: .systemRed) ?? .systemRed],
                    forCharacterRange: range)
            }
        }

        private func tokenStyle(for scopes: [String]) -> EditorThemeTokenStyle? {
            guard let editorTheme else { return nil }
            if let cached = tokenStyles[scopes] { return cached }
            let style = editorTheme.style(for: scopes)
            tokenStyles[scopes] = style
            return style
        }

        private func highlightExecutionFragment(_ textView: NSTextView) {
            guard let manager = textView.layoutManager else { return }
            let full = NSRange(location: 0, length: textView.string.utf16.count)
            let editor = textView as? SQLTextView
            let previous = editor?.executionHighlightText == textView.string && editor?.executionHighlightTheme == editorTheme
                ? editor?.executionHighlightRange : full
            if let previous { manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSIntersectionRange(previous, full)) }
            if let editorTheme, editorTheme.tokenRules.contains(where: { $0.style.background != nil }) {
                for token in parse(textView.string).tokens {
                    if let background = tokenStyle(for: syntaxScopes(for: token, in: textView.string))?.background {
                        manager.addTemporaryAttribute(.backgroundColor, value: background.nsColor, forCharacterRange: token.range)
                    }
                }
            }
            let range: NSRange?
            let selection = textView.selectedRange()
            if editor?.hasMultipleEditorSelections == true {
                range = nil
            } else if selection.length == 0 {
                range = parse(textView.string).statement(atUTF16: selection.location)?.range
            } else {
                let source = textView.string as NSString
                var start = min(selection.location, source.length)
                var end = min(NSMaxRange(selection), source.length)
                while start < end, isWhitespace(source.character(at: start)) { start += 1 }
                while end > start, isWhitespace(source.character(at: end - 1)) { end -= 1 }
                let selected = NSRange(location: start, length: end - start)
                range = selected.length > 0 && !SQLScriptParser.parse(source.substring(with: selected), engine: engine).statements.isEmpty ? selected : nil
            }
            editor?.executionHighlightText = textView.string
            editor?.executionHighlightTheme = editorTheme
            editor?.executionHighlightRange = range
            guard let range else { return }
            manager.addTemporaryAttribute(.backgroundColor,
                value: (textView as? SQLTextView)?.executionHighlightColor ?? NSColor(AppPalette.accent).withAlphaComponent(0.12),
                forCharacterRange: range)
        }

        private func syntaxScopes(for token: SQLToken, in text: String) -> [String] {
            let scope: String
            switch token.kind {
            case .keyword: scope = "keyword.other.sql"
            case .number: scope = "constant.numeric.sql"
            case .identifier: return ["source.sql", "entity.name.sql", "variable.other.sql"]
            case .string:
                let value = (text as NSString).substring(with: token.range)
                scope = value.hasPrefix("$") ? "string.quoted.other.sql"
                    : (value.hasPrefix("\"") ? "string.quoted.double.sql" : "string.quoted.single.sql")
            case .comment:
                let value = (text as NSString).substring(with: token.range)
                scope = value.hasPrefix("/*") ? "comment.block.sql" : "comment.line.sql"
            }
            return ["source.sql", scope]
        }

        private func isWhitespace(_ unit: UInt16) -> Bool {
            unit == 32 || (9...13).contains(unit) || unit == 0xA0
        }

        private func isActiveEditor(_ textView: NSTextView) -> Bool {
            guard let activeDocumentID else { return false }
            return activeState?.editors[activeDocumentID] === textView && textView.delegate === self
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView, isActiveEditor(textView) else { return }
            (textView as? SQLTextView)?.successfulExecutionLocations = []
            (textView as? SQLTextView)?.editorTools?.textDidChange()
            text.wrappedValue = textView.string
            if let activeDocumentID {
                languageService?.update(documentID: activeDocumentID, text: textView.string,
                    engine: engine, context: completionContext)
            }
            highlight(textView)
            selectionChanged?(textView.selectedRange())
            (textView.enclosingScrollView?.verticalRulerView as? SQLLineNumberRuler)?.updateLines()
            if let textView = textView as? SQLTextView {
                requestCompletion(in: textView, explicit: false)
                requestSignatureHelp(in: textView)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView, isActiveEditor(textView),
                  (textView as? SQLTextView)?.movingAllEditorSelections != true else { return }
            (textView as? SQLTextView)?.editorTools?.selectionDidChange()
            if (textView as? SQLTextView)?.hasMultipleEditorSelections == true { dismissCompletions(); dismissSignatures() }
            if completionSnapshot != snapshot(for: textView) { dismissCompletions() }
            textView.needsDisplay = true
            highlightExecutionFragment(textView)
            (textView.enclosingScrollView?.verticalRulerView as? SQLLineNumberRuler)?.needsDisplay = true
            selectionChanged?(textView.selectedRange())
            if let textView = textView as? SQLTextView { requestSignatureHelp(in: textView) }
        }

        private func snapshot(for textView: NSTextView) -> CompletionSnapshot? {
            guard isActiveEditor(textView), let activeDocumentID,
                  (textView as? SQLTextView)?.hasMultipleEditorSelections != true else { return nil }
            return CompletionSnapshot(documentID: activeDocumentID, text: textView.string,
                selection: textView.selectedRange(), engine: engine, context: completionContext)
        }

        private func dismissCompletions() {
            completionGeneration += 1
            completionTask?.cancel()
            completionTask = nil
            completionSnapshot = nil
            pendingLargeCompletion = nil
            completionPopup.hide()
        }

        private func dismissSignatures() {
            signatureGeneration += 1
            signatureTask?.cancel()
            signatureTask = nil
            signatureSnapshot = nil
            signaturePopup.hide()
        }

        private func requestSignatureHelp(in textView: SQLTextView) {
            guard textView.isEditable, !textView.hasMarkedText(),
                  textView.window?.firstResponder === textView, textView.window?.isKeyWindow == true,
                  let service = languageService, let snapshot = snapshot(for: textView), snapshot.selection.length == 0 else {
                dismissSignatures()
                return
            }
            guard snapshot != signatureSuppressedSnapshot, signatureSnapshot != snapshot else { return }
            signatureGeneration += 1
            let generation = signatureGeneration
            signatureTask?.cancel()
            signatureSnapshot = snapshot
            signatureTask = Task { @MainActor [weak self, weak textView] in
                do { try await Task.sleep(for: .milliseconds(75)) } catch { return }
                guard !Task.isCancelled else { return }
                let value = await service.signatureHelp(documentID: snapshot.documentID, offset: snapshot.selection.location)
                guard let self, let textView, !Task.isCancelled, generation == self.signatureGeneration,
                      self.snapshot(for: textView) == snapshot else { return }
                guard textView.window?.firstResponder === textView, textView.window?.isKeyWindow == true,
                      textView.currentLineHighlightRect?.intersects(textView.visibleRect) == true else { self.dismissSignatures(); return }
                self.signatureTask = nil
                if let value { self.signaturePopup.show(value, for: textView) }
                else { self.signaturePopup.hide() }
            }
        }

        private func requestCompletion(in textView: SQLTextView, explicit: Bool) {
            dismissCompletions()
            if explicit { completionSuppressedSnapshot = nil }
            guard textView.isEditable, !textView.hasMarkedText(),
                  textView.window?.firstResponder === textView, textView.window?.isKeyWindow == true,
                  let snapshot = snapshot(for: textView), snapshot.selection.length == 0,
                  explicit || snapshot != completionSuppressedSnapshot else { return }
            if (snapshot.text as NSString).length > backgroundParseThreshold, parsedText != snapshot.text {
                completionSnapshot = snapshot
                pendingLargeCompletion = (snapshot, explicit)
                _ = parse(snapshot.text)
                return
            }
            guard !suppressesCompletion(text: snapshot.text, offset: snapshot.selection.location) else { return }
            let offset = snapshot.selection.location
            let input = completionInput(text: snapshot.text, offset: offset)
            guard explicit || offset > 0 else { return }
            let fallback = localCompletions(prefix: input.prefix, quoted: input.quoted).map { label in
                let quote = engine == .mysql ? "`" : "\""
                let quoted = label.hasPrefix(quote)
                let prefix = quoted ? input.prefix.replacingOccurrences(of: quote, with: quote + quote) : input.prefix
                let source = label as NSString
                let start = quoted ? 1 : 0
                let match = source.range(of: prefix, options: [.anchored, .caseInsensitive],
                    range: NSRange(location: start, length: source.length - start))
                return SQLCompletionItem(label: label, replacement: label, replacementRange: input.range,
                    matchRanges: !prefix.isEmpty && match.location != NSNotFound ? [match] : [])
            }
            let generation = completionGeneration
            // A duplicate selection notification during native layout must not
            // invalidate a request for this exact insertion point.
            completionSnapshot = snapshot
            if explicit, languageService == nil { showCompletions(fallback, snapshot: snapshot, in: textView) }
            completionTask = Task { @MainActor [weak self, weak textView] in
                if !explicit {
                    do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                }
                guard let self, let textView, !Task.isCancelled,
                      generation == self.completionGeneration, self.snapshot(for: textView) == snapshot else { return }
                guard let service = self.languageService else {
                    if !explicit { self.showCompletions(fallback, snapshot: snapshot, in: textView) }
                    return
                }
                let values = await service.completion(documentID: snapshot.documentID, offset: offset)
                guard !Task.isCancelled, generation == self.completionGeneration,
                      self.snapshot(for: textView) == snapshot else { return }
                if !values.isEmpty { self.showCompletions(values, snapshot: snapshot, in: textView) }
                else if service.isAvailable { self.dismissCompletions() }
                else { self.showCompletions(fallback, snapshot: snapshot, in: textView) }
            }
        }

        private func completionInput(text: String, offset: Int) -> (range: NSRange, prefix: String, quoted: Bool) {
            let source = text as NSString
            if let token = parse(text).tokens.first(where: {
                ($0.kind == .identifier || $0.kind == .keyword) &&
                    offset >= $0.range.location && offset <= NSMaxRange($0.range)
            }) {
                var prefix = source.substring(with: NSRange(location: token.range.location, length: offset - token.range.location))
                let first = source.character(at: token.range.location)
                let quoted = first == 34 || first == 96
                if quoted {
                    let quote = first == 34 ? "\"" : "`"
                    if prefix.hasPrefix(quote) { prefix.removeFirst() }
                    if prefix.hasSuffix(quote) { prefix.removeLast() }
                    prefix = prefix.replacingOccurrences(of: quote + quote, with: quote)
                }
                return (token.range, prefix, quoted)
            }
            return (NSRange(location: offset, length: 0), "", false)
        }

        private func suppressesCompletion(text: String, offset: Int) -> Bool {
            if engine == .mongodb { return false }
            if (text as NSString).length > backgroundParseThreshold, parsedText != text { return true }
            let parsed = parse(text)
            let source = text as NSString
            return parsed.tokens.contains { token in
                guard token.kind == .comment || token.kind == .string,
                      offset > token.range.location, offset <= NSMaxRange(token.range) else { return false }
                if offset < NSMaxRange(token.range) { return true }
                let value = source.substring(with: token.range)
                if token.kind == .comment { return !value.hasPrefix("/*") || !value.hasSuffix("*/") }
                return parsed.diagnostics.contains { $0.range == token.range && $0.message.hasPrefix("Unterminated") }
            }
        }

        private func showCompletions(_ values: [SQLCompletionItem], snapshot: CompletionSnapshot, in textView: SQLTextView) {
            guard textView.isEditable, self.snapshot(for: textView) == snapshot, textView.window?.firstResponder === textView,
                  textView.window?.isKeyWindow == true,
                  textView.currentLineHighlightRect?.intersects(textView.visibleRect) == true else { return }
            let length = snapshot.text.utf16.count
            let valid = Array(values.filter {
                $0.replacementRange.location != NSNotFound && $0.replacementRange.location <= length &&
                    $0.replacementRange.length <= length - $0.replacementRange.location
            }.prefix(100))
            guard !valid.isEmpty else { return }
            completionSnapshot = snapshot
            completionPopup.show(items: valid, for: textView) { [weak self, weak textView] in
                guard let textView else { return }
                self?.acceptCompletion(in: textView)
            }
        }

        private func handleCompletionKey(_ event: NSEvent, in textView: SQLTextView) -> Bool {
            guard isActiveEditor(textView) else { return false }
            if event.keyCode == 53 { completionSuppressedSnapshot = snapshot(for: textView) }
            if event.keyCode == 53, completionTask != nil || pendingLargeCompletion != nil || !completionPopup.items.isEmpty || signatureTask != nil || signaturePopup.isVisible {
                signatureSuppressedSnapshot = snapshot(for: textView)
                dismissCompletions()
                dismissSignatures()
                return true
            }
            guard !completionPopup.items.isEmpty else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.isEmpty || flags == .numericPad || flags == [.numericPad, .function] || flags == .function else { return false }
            switch event.keyCode {
            case 125: completionPopup.moveSelection(by: 1)
            case 126: completionPopup.moveSelection(by: -1)
            case 36, 48, 76: acceptCompletion(in: textView)
            case 53: dismissCompletions()
            default: return false
            }
            return true
        }

        private func acceptCompletion(in textView: SQLTextView) {
            guard let expected = completionSnapshot, snapshot(for: textView) == expected,
                  let item = completionPopup.selectedItem else { dismissCompletions(); return }
            dismissCompletions()
            // NSTextView owns replacement, selection and a single native undo operation.
            textView.breakUndoCoalescing()
            textView.insertText(item.replacement, replacementRange: item.replacementRange)
            textView.breakUndoCoalescing()
            dismissCompletions()
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let prefix = (textView.string as NSString).substring(with: charRange)
            index?.pointee = 0
            return localCompletions(prefix: prefix)
        }

        private func localCompletions(prefix: String, quoted: Bool = false) -> [String] {
            if engine == .mongodb { return [] }
            let matches: (String) -> Bool = { $0.lowercased().hasPrefix(prefix.lowercased()) }
            let keywords = quoted ? [] : SQLScriptParser.keywords(for: engine).filter(matches)
            let reserved = Set(SQLScriptParser.keywords(for: engine))
            let identifiers = completionCandidates.filter(matches).map { name in
                let units = Array(name.utf16)
                let safe = !units.isEmpty && units.enumerated().allSatisfy { offset, unit in
                    (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 ||
                        (offset > 0 && ((48...57).contains(unit) || (engine != .cassandra && unit == 36)))
                }
                let needsQuotes = quoted || !safe || reserved.contains(name.uppercased()) ||
                    (engine != .mysql && name != name.lowercased())
                guard needsQuotes else { return name }
                let quote = engine == .mysql ? "`" : "\""
                return quote + name.replacingOccurrences(of: quote, with: quote + quote) + quote
            }
            return Array(Set(keywords + identifiers))
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.prefix(100).map { $0 }
        }
    }
}

@MainActor
private final class SQLScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        (documentView as? SQLTextView)?.dismissCompletion?()
        super.scrollWheel(with: event)
    }
}

enum SQLSyntaxPalette {
    static let keyword = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.78, green: 0.60, blue: 0.95, alpha: 1)
            : NSColor(red: 0.43, green: 0.22, blue: 0.65, alpha: 1)
    }
    static let string = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.55, green: 0.76, blue: 0.49, alpha: 1)
            : NSColor(red: 0.16, green: 0.43, blue: 0.27, alpha: 1)
    }
    static let number = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.48, green: 0.70, blue: 0.96, alpha: 1)
            : NSColor(red: 0.09, green: 0.34, blue: 0.68, alpha: 1)
    }
}

@MainActor
final class SQLTextView: NSTextView, AppCommandFocusResponder {
    private let documentUndo = UndoManager()
    var editorEngine: DatabaseEngine = .postgresql
    var editorIndentWidth = 4
    var editorUsesTabs = false
    var editorAutoPairs = true
    var editorAutoIndent = true
    var editorTools: SQLEditorToolsController?
    private var additionalEditorSelections: [NSRange] = []
    private var applyingEditorBatch = false
    private var insertingPlainText = false
    private var changingEditorSelections = false
    private(set) var movingAllEditorSelections = false
    private(set) var editorSelectionLimitReached = false
    static let maximumEditorSelections = 4096
    var hasMultipleEditorSelections: Bool { !additionalEditorSelections.isEmpty }
    var editorSelections: [NSRange] { [selectedRange()] + additionalEditorSelections }
    var editorIndent: String { editorUsesTabs ? "\t" : String(repeating: " ", count: max(1, min(8, editorIndentWidth))) }

    private(set) var editorTheme: EditorTheme?
    var syntaxText: String?
    var protectedParse: SQLParseResult?
    var syntaxEngine: DatabaseEngine?
    var syntaxTheme: EditorTheme?
    var syntaxErrorPosition: Int?
    var syntaxDiagnostics: [SQLLanguageDiagnostic] = []
    var executionHighlightText: String?
    var executionHighlightTheme: EditorTheme?
    var executionHighlightRange: NSRange?
    var successfulExecutionLocations: Set<Int> = [] {
        didSet {
            if successfulExecutionLocations != oldValue {
                (enclosingScrollView?.verticalRulerView as? SQLLineNumberRuler)?.updateLines()
            }
        }
    }
    var runSelection: ((NSRange) -> Void)?
    var commandEvent: ((NSEvent, NSRange) -> Bool)?
    var requestCompletion: (() -> Void)?
    var dismissCompletion: (() -> Void)?
    var viewportChanged: (() -> Void)?
    var completionKey: ((NSEvent) -> Bool)?
    var appCommandFocus: AppCommandFocus { .sqlEditor }
    var appCommandDocumentID: UUID?
    var restoreFocusAfterPaneMove = false
    var focusOnAttach: (@MainActor () -> Bool)?
    override var undoManager: UndoManager? { documentUndo }

    // Route native responder-chain actions to this document's history rather
    // than the hosting window's undo manager.
    @objc func undo(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), documentUndo.canUndo else { return }
        dismissCompletion?()
        editorTools?.prepareForEdit()
        breakUndoCoalescing()
        documentUndo.undo()
        scrollRangeToVisible(selectedRange())
    }

    @objc func redo(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), documentUndo.canRedo else { return }
        dismissCompletion?()
        editorTools?.prepareForEdit()
        breakUndoCoalescing()
        documentUndo.redo()
        scrollRangeToVisible(selectedRange())
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return isEditable && !hasMarkedText() && documentUndo.canUndo }
        if item.action == #selector(redo(_:)) { return isEditable && !hasMarkedText() && documentUndo.canRedo }
        return super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) || menuItem.action == #selector(redo(_:)) {
            return validateUserInterfaceItem(menuItem)
        }
        return super.validateMenuItem(menuItem)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { WorkspacePaneContainerView.activatePane(containing: self) }
        return accepted
    }

    /// Theme changes affect presentation attributes only. The document, native
    /// undo manager, selection and scroll position remain owned by this view.
    func applyTheme(_ theme: EditorTheme?) {
        guard editorTheme != theme else { return }
        editorTheme = theme
        appearance = theme.flatMap { NSAppearance(named: $0.appearance == .dark ? .darkAqua : .aqua) }
        backgroundColor = theme?.color("editor.background", default: .textBackgroundColor) ?? .textBackgroundColor
        textColor = theme?.color("editor.foreground", default: .labelColor) ?? .labelColor
        insertionPointColor = theme?.color("editorCursor.foreground", default: textColor ?? .labelColor) ?? .labelColor
        selectedTextAttributes = [
            .backgroundColor: theme?.color("editor.selectionBackground", default: .selectedTextBackgroundColor) ?? .selectedTextBackgroundColor,
            .foregroundColor: theme?.color("editor.selectionForeground",
                default: theme?.colors["editor.selectionBackground"] == nil ? .selectedTextColor : (textColor ?? .selectedTextColor)) ?? .selectedTextColor
        ]
        var attributes = typingAttributes
        attributes[.foregroundColor] = textColor
        typingAttributes = attributes
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    var executionHighlightColor: NSColor {
        if let background = editorTheme?.colors["editor.rangeHighlightBackground"] { return background.nsColor }
        if let selection = editorTheme?.colors["editor.selectionBackground"] { return selection.nsColor.withAlphaComponent(0.22) }
        return NSColor(AppPalette.accent).withAlphaComponent(0.12)
    }

    var currentLineHighlightColor: NSColor {
        editorTheme?.color("editor.lineHighlightBackground", default: NSColor.labelColor.withAlphaComponent(0.045))
            ?? NSColor.labelColor.withAlphaComponent(0.045)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        WorkspacePaneContainerView.activatePane(containing: self)
        if editorTools?.handleKeyEvent(event) == true || handleCoreKeyEvent(event) { return true }
        if commandEvent?(event, selectedRange()) == true { return true }
        if commandEvent == nil, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 36, let runSelection {
            runSelection(selectedRange())
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        WorkspacePaneContainerView.activatePane(containing: self)
        if completionKey?(event) == true { return }
        if editorTools?.handleKeyEvent(event) == true || handleCoreKeyEvent(event) { return }
        if commandEvent?(event, selectedRange()) == true { return }
        if commandEvent == nil, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 36, let runSelection {
            runSelection(selectedRange())
            return
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control, event.keyCode == 49 { complete(nil); return }
        if hasMultipleEditorSelections, handleMultipleCursorMovement(event) { return }
        super.keyDown(with: event)
    }

    override func complete(_ sender: Any?) {
        guard !hasMultipleEditorSelections else { dismissCompletion?(); return }
        requestCompletion?()
    }

    override func setSelectedRange(_ charRange: NSRange) {
        if !changingEditorSelections && !applyingEditorBatch && !movingAllEditorSelections { additionalEditorSelections = [] }
        super.setSelectedRange(charRange)
        needsDisplay = true
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        if !changingEditorSelections && !applyingEditorBatch && !movingAllEditorSelections { additionalEditorSelections = [] }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
        needsDisplay = true
    }

    private func handleMultipleCursorMovement(_ event: NSEvent) -> Bool {
        guard [123, 124, 125, 126].contains(event.keyCode), !hasMarkedText() else { return false }
        let original = editorSelections
        movingAllEditorSelections = true
        additionalEditorSelections = []
        var moved: [NSRange] = []
        for range in original {
            super.setSelectedRange(range)
            super.keyDown(with: event)
            moved.append(selectedRange())
        }
        movingAllEditorSelections = false
        setEditorSelections(moved)
        return true
    }

    func setEditorSelections(_ ranges: [NSRange]) {
        editorSelectionLimitReached = ranges.count > Self.maximumEditorSelections
        let normalized = SQLTextEditing.normalized(Array(ranges.prefix(Self.maximumEditorSelections)), length: string.utf16.count)
        changingEditorSelections = true
        additionalEditorSelections = Array(normalized.dropFirst())
        super.setSelectedRange(normalized[0])
        changingEditorSelections = false
        if hasMultipleEditorSelections { dismissCompletion?() }
        needsDisplay = true
        editorTools?.selectionDidChange()
    }

    func applyEditorEdits(_ edits: [SQLTextEdit], selections: [NSRange]? = nil, actionName: String) {
        guard isEditable, !edits.isEmpty else { return }
        let source = string as NSString
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        var previousEnd = 0
        var delta = 0
        var inverse: [SQLTextEdit] = []
        for edit in sorted {
            guard edit.range.location != NSNotFound, edit.range.location >= previousEnd,
                  edit.range.length >= 0, edit.range.location <= source.length,
                  edit.range.length <= source.length - edit.range.location else { return }
            inverse.append(SQLTextEdit(range: NSRange(location: edit.range.location + delta, length: edit.text.utf16.count),
                text: source.substring(with: edit.range)))
            previousEnd = NSMaxRange(edit.range)
            delta += edit.text.utf16.count - edit.range.length
        }
        let replaying = documentUndo.isUndoing || documentUndo.isRedoing
        if !replaying {
            // NSTextView normally records its own inverse in this preflight.
            // This batch owns one inverse for every range and its selections.
            documentUndo.disableUndoRegistration()
            let accepted = shouldChangeText(inRanges: sorted.map { NSValue(range: $0.range) }, replacementStrings: sorted.map(\.text))
            documentUndo.enableUndoRegistration()
            guard accepted else { return }
        }
        if zip(sorted, inverse).allSatisfy({ $0.text == $1.text }) {
            if let selections { setEditorSelections(selections) }
            return
        }
        let previousSelections = editorSelections
        let nextSelections = selections ?? SQLTextEditing.mappedRanges(previousSelections, through: sorted)
        editorTools?.prepareForEdit()
        let ownsUndoGroup = !replaying && documentUndo.groupingLevel == 0
        if ownsUndoGroup { documentUndo.beginUndoGrouping() }
        defer { if ownsUndoGroup { documentUndo.endUndoGrouping() } }
        let undoEdits = inverse
        documentUndo.registerUndo(withTarget: self) { target in
            target.applyEditorEdits(undoEdits, selections: previousSelections, actionName: actionName)
        }
        documentUndo.setActionName(actionName)
        applyingEditorBatch = true
        documentUndo.disableUndoRegistration()
        textStorage?.beginEditing()
        for edit in sorted.reversed() { textStorage?.replaceCharacters(in: edit.range, with: edit.text) }
        textStorage?.endEditing()
        setEditorSelections(nextSelections)
        applyingEditorBatch = false
        didChangeText()
        documentUndo.enableUndoRegistration()
    }

    func performEditorAction(_ action: SQLTextEditorAction) {
        guard !hasMarkedText() else { return }
        switch action {
        case .extendSelection:
            let scopes = SQLSelectionExpansion(text: string, engine: editorEngine)
            setEditorSelections(editorSelections.map { scopes.extending($0) })
            scrollRangeToVisible(selectedRange())
        case .selectNextOccurrence: selectOccurrence(all: false)
        case .selectAllOccurrences: selectOccurrence(all: true)
        case .addCursorAbove: addEditorCursor(direction: -1)
        case .addCursorBelow: addEditorCursor(direction: 1)
        default:
            let edits = SQLTextEditing.lineEdits(action: action, text: string, selections: editorSelections,
                indent: editorIndent, engine: editorEngine)
            let selections = action == .moveLinesUp || action == .moveLinesDown
                ? SQLTextEditing.selectionsAfterMovingLines(action: action, text: string, selections: editorSelections, edits: edits) : nil
            applyEditorEdits(edits, selections: selections, actionName: action.undoTitle)
        }
    }

    private func selectOccurrence(all: Bool) {
        let source = string as NSString
        var ranges = editorSelections
        if ranges[0].length == 0 {
            guard let word = SQLTextEditing.wordRange(in: string, at: ranges[0].location) else { return }
            ranges[0] = word
            if !all { setEditorSelections(ranges); return }
        }
        let needle = source.substring(with: ranges[0])
        guard !needle.isEmpty else { return }
        let selected = Set(ranges)
        if all {
            var found = [ranges[0]]
            var location = 0
            while location < source.length, found.count <= Self.maximumEditorSelections {
                let range = source.range(of: needle, options: .literal, range: NSRange(location: location, length: source.length - location))
                guard range.location != NSNotFound else { break }
                if range != ranges[0] { found.append(range) }
                location = NSMaxRange(range)
            }
            setEditorSelections(found)
        } else {
            guard ranges.count < Self.maximumEditorSelections else {
                editorSelectionLimitReached = true; needsDisplay = true; return
            }
            let last = ranges.last ?? ranges[0]
            let start = NSMaxRange(last)
            let intervals = [NSRange(location: start, length: source.length - start), NSRange(location: 0, length: start)]
            for interval in intervals {
                var location = interval.location
                while location < NSMaxRange(interval) {
                    let range = source.range(of: needle, options: .literal, range: NSRange(location: location, length: NSMaxRange(interval) - location))
                    guard range.location != NSNotFound else { break }
                    if !selected.contains(range), !ranges.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                        setEditorSelections(ranges + [range]); scrollRangeToVisible(range); return
                    }
                    location = NSMaxRange(range)
                }
            }
        }
    }

    private func addEditorCursor(direction: Int) {
        let source = string as NSString
        let last = editorSelections.last ?? selectedRange()
        let line = source.lineRange(for: NSRange(location: last.location, length: 0))
        let column = last.location - line.location
        let target: NSRange
        if direction < 0 {
            guard line.location > 0 else { return }
            target = source.lineRange(for: NSRange(location: line.location - 1, length: 0))
        } else {
            guard NSMaxRange(line) < source.length || NSMaxRange(line) == source.length && line.length > 0 && string.hasSuffix("\n") else { return }
            target = source.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
        }
        let content = source.substring(with: target).trimmingCharacters(in: .newlines)
        var location = target.location + min(column, content.utf16.count)
        if location < source.length {
            let composed = source.rangeOfComposedCharacterSequence(at: location)
            if location > composed.location { location = composed.location }
        }
        let range = NSRange(location: location, length: 0)
        setEditorSelections(editorSelections + [range])
        scrollRangeToVisible(range)
    }

    private func handleCoreKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if let shortcut = AppShortcut(event: event), shortcut.key == "z",
           flags == .command || flags == .control || flags == [.command, .shift] || flags == [.control, .shift] {
            if flags.contains(.shift) { redo(nil) } else { undo(nil) }
            return true
        }
        if event.keyCode == 53, hasMultipleEditorSelections { setEditorSelections([selectedRange()]); return true }
        if commandEvent == nil, flags == .command, event.charactersIgnoringModifiers?.lowercased() == "d" { performEditorAction(.selectNextOccurrence); return true }
        if commandEvent == nil, flags == [.command, .control], event.charactersIgnoringModifiers?.lowercased() == "g" { performEditorAction(.selectAllOccurrences); return true }
        if commandEvent == nil, flags == [.control, .shift], event.keyCode == 126 || event.keyCode == 125 {
            performEditorAction(event.keyCode == 126 ? .addCursorAbove : .addCursorBelow); return true
        }
        if commandEvent == nil, flags == .command, event.charactersIgnoringModifiers == "/" { performEditorAction(.toggleLineComment); return true }
        if commandEvent == nil, hasMultipleEditorSelections, flags == .command, event.keyCode == 36 {
            NSSound.beep()
            return true
        }
        return false
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .option {
            let point = convert(event.locationInWindow, from: nil)
            let location = characterIndexForInsertion(at: point)
            setEditorSelections(editorSelections + [NSRange(location: location, length: 0)])
            window?.makeFirstResponder(self)
            return
        }
        additionalEditorSelections = []
        super.mouseDown(with: event)
        needsDisplay = true
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if hasMultipleEditorSelections { setEditorSelections([self.selectedRange()]) }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        let value = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        guard let value, !hasMarkedText(), !applyingEditorBatch else { super.insertText(insertString, replacementRange: replacementRange); return }
        if replacementRange.location != NSNotFound {
            if hasMultipleEditorSelections { setEditorSelections([selectedRange()]) }
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let pairs = ["(": ")", "[": "]", "{": "}", "'": "'", "\"": "\"", "`": "`"]
        if editorAutoPairs, !insertingPlainText, value.utf16.count == 1 {
            let ranges = editorSelections
            if !hasMultipleEditorSelections, ranges[0].length == 0, [")", "]", "}", "'", "\"", "`"].contains(value),
               ranges[0].location < string.utf16.count,
               (string as NSString).substring(with: NSRange(location: ranges[0].location, length: 1)) == value,
               !insideProtectedText(at: ranges[0].location) || isClosingQuote(value, at: ranges[0].location) {
                setEditorSelections([NSRange(location: ranges[0].location + 1, length: 0)])
                return
            }
            if let close = pairs[value], !(editorEngine == .mongodb && (value == "'" || value == "`")),
               !(value == "`" && editorEngine != .mysql), ranges.allSatisfy({ !insideProtectedText(at: $0.location) }) {
                let source = string as NSString
                let edits = ranges.map { SQLTextEdit(range: $0, text: value + source.substring(with: $0) + close) }
                let sorted = edits.sorted { $0.range.location < $1.range.location }
                let selections = ranges.map { range in
                    let shift = sorted.filter { $0.range.location < range.location }.reduce(0) { $0 + $1.text.utf16.count - $1.range.length }
                    return NSRange(location: range.location + shift + 1, length: range.length)
                }
                applyEditorEdits(edits, selections: selections, actionName: "Insert Pair")
                return
            }
        }
        if hasMultipleEditorSelections {
            let edits = editorSelections.map { SQLTextEdit(range: $0, text: value) }
            let selections = SQLTextEditing.insertionCarets(for: editorSelections, edits: edits)
            applyEditorEdits(edits, selections: selections, actionName: "Typing")
        } else {
            editorTools?.prepareForEdit()
            super.insertText(insertString, replacementRange: replacementRange)
        }
    }

    private func protectedParseForCurrentSource() -> SQLParseResult {
        if syntaxText == string, syntaxEngine == editorEngine, let protectedParse { return protectedParse }
        guard (string as NSString).length <= 128 * 1024 else {
            return SQLParseResult(statements: [], statementEditorRanges: [], tokens: [], diagnostics: [])
        }
        return SQLScriptParser.parse(string, engine: editorEngine)
    }

    private func isClosingQuote(_ value: String, at location: Int) -> Bool {
        guard ["'", "\"", "`"].contains(value) else { return false }
        let parsed = protectedParseForCurrentSource()
        return parsed.tokens.contains { token in
            (token.kind == .string || token.kind == .identifier) && NSMaxRange(token.range) - 1 == location &&
                !parsed.diagnostics.contains(where: { $0.range == token.range }) &&
                (string as NSString).substring(with: NSRange(location: token.range.location, length: 1)) == value
        }
    }

    private func insideProtectedText(at location: Int) -> Bool {
        if (string as NSString).length > 128 * 1024, syntaxText != string { return true }
        let parsed = protectedParseForCurrentSource()
        return parsed.tokens.contains { token in
            let quotedIdentifier = token.kind == .identifier && token.range.length > 0 &&
                [34, 96].contains((string as NSString).character(at: token.range.location))
            guard token.kind == .string || token.kind == .comment || quotedIdentifier,
                  location > token.range.location, location <= NSMaxRange(token.range) else { return false }
            if location < NSMaxRange(token.range) { return true }
            return parsed.diagnostics.contains { $0.range == token.range } ||
                (token.kind == .comment && !(string as NSString).substring(with: token.range).hasSuffix("*/"))
        }
    }

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertNewline(sender); return }
        guard editorAutoIndent else {
            if hasMultipleEditorSelections { insertText(SQLTextEditing.newline(in: string), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            else { super.insertNewline(sender) }
            return
        }
        let source = string as NSString
        let edits = editorSelections.map { range -> SQLTextEdit in
            let line = source.lineRange(for: NSRange(location: range.location, length: 0))
            let before = source.substring(with: NSRange(location: line.location, length: range.location - line.location))
            var indentation = String(before.prefix(while: { $0 == " " || $0 == "\t" }))
            let tail = before.trimmingCharacters(in: .whitespaces)
            if !insideProtectedText(at: range.location), ["(", "[", "{"].contains(where: { tail.hasSuffix($0) }) { indentation += editorIndent }
            return SQLTextEdit(range: range, text: SQLTextEditing.newline(in: string) + indentation)
        }
        let selections = SQLTextEditing.insertionCarets(for: editorSelections, edits: edits)
        applyEditorEdits(edits, selections: selections, actionName: "Insert Newline")
    }

    override func insertTab(_ sender: Any?) {
        if editorSelections.contains(where: { $0.length > 0 }) { performEditorAction(.indent) }
        else if editorUsesTabs { insertText("\t", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        else { insertText(editorIndent, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    override func insertBacktab(_ sender: Any?) { performEditorAction(.outdent) }

    override func deleteBackward(_ sender: Any?) {
        guard hasMultipleEditorSelections else { editorTools?.prepareForEdit(); super.deleteBackward(sender); return }
        let source = string as NSString
        let ranges = editorSelections.map { range -> NSRange in
            if range.length > 0 || range.location == 0 { return range }
            return source.rangeOfComposedCharacterSequence(at: range.location - 1)
        }
        let edits = SQLTextEditing.normalized(ranges, length: source.length).map { SQLTextEdit(range: $0, text: "") }
        applyEditorEdits(edits, selections: ranges.map { SQLTextEditing.mapped(NSRange(location: $0.location, length: 0), through: edits) }, actionName: "Delete")
    }

    override func deleteForward(_ sender: Any?) {
        guard hasMultipleEditorSelections else { editorTools?.prepareForEdit(); super.deleteForward(sender); return }
        let source = string as NSString
        let ranges = editorSelections.map { range -> NSRange in
            if range.length > 0 || range.location >= source.length { return range }
            return source.rangeOfComposedCharacterSequence(at: range.location)
        }
        let edits = SQLTextEditing.normalized(ranges, length: source.length).map { SQLTextEdit(range: $0, text: "") }
        applyEditorEdits(edits, selections: ranges.map { SQLTextEditing.mapped(NSRange(location: $0.location, length: 0), through: edits) }, actionName: "Delete")
    }

    override func paste(_ sender: Any?) {
        insertingPlainText = true
        defer { insertingPlainText = false }
        guard hasMultipleEditorSelections, let value = NSPasteboard.general.string(forType: .string) else { super.paste(sender); return }
        insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func drawAdditionalSelections(in rect: NSRect) {
        guard hasMultipleEditorSelections, let manager = layoutManager, let container = textContainer else { return }
        for range in additionalEditorSelections {
            if range.length > 0 {
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { selection, _ in
                    let selection = selection.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                    guard selection.intersects(rect) else { return }
                    (self.selectedTextAttributes[.backgroundColor] as? NSColor ?? .selectedTextBackgroundColor).setFill()
                    selection.fill()
                }
            } else {
                let location = range.location
                let caret: NSRect
                if location < string.utf16.count {
                    let glyph = manager.glyphIndexForCharacter(at: location)
                    let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let point = manager.location(forGlyphAt: glyph)
                    caret = NSRect(x: line.minX + point.x + textContainerOrigin.x, y: line.minY + textContainerOrigin.y, width: 1, height: line.height)
                } else {
                    let line = manager.extraLineFragmentRect
                    caret = NSRect(x: line.minX + textContainerOrigin.x, y: line.minY + textContainerOrigin.y, width: 1, height: max(line.height, font?.boundingRectForFont.height ?? 16))
                }
                if caret.intersects(rect) { insertionPointColor.setFill(); caret.fill() }
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowGeometryChanged),
                name: NSWindow.didResizeNotification, object: window)
            if let focusOnAttach {
                self.focusOnAttach = nil
                Task { @MainActor [weak self, weak window] in
                    guard let self, let window, self.window === window, window.isKeyWindow,
                          NSApp.modalWindow == nil, window.attachedSheet == nil, focusOnAttach() else { return }
                    window.makeFirstResponder(self)
                }
            } else if restoreFocusAfterPaneMove {
                Task { @MainActor [weak self, weak window] in
                    guard let self, let window, self.window === window, self.restoreFocusAfterPaneMove else { return }
                    self.restoreFocusAfterPaneMove = false
                    let responder = window.firstResponder
                    if responder == nil || responder === window || responder === window.contentView || responder === self {
                        window.makeFirstResponder(self)
                    }
                }
            }
        } else { dismissCompletion?() }
    }

    @objc private func windowResignedKey() { dismissCompletion?() }
    @objc private func windowGeometryChanged() { viewportChanged?() }

    override func resignFirstResponder() -> Bool {
        dismissCompletion?()
        return super.resignFirstResponder()
    }

    var currentLineHighlightRect: NSRect? {
        guard selectedRange().length == 0, let manager = layoutManager, let container = textContainer else { return nil }
        let location = min(selectedRange().location, string.utf16.count)
        let line: NSRect
        if location < string.utf16.count {
            let glyph = manager.glyphIndexForCharacter(at: location)
            line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else if manager.extraLineFragmentTextContainer === container, manager.extraLineFragmentRect.height > 0 {
            line = manager.extraLineFragmentRect
        } else if location > 0 {
            let glyph = manager.glyphIndexForCharacter(at: location - 1)
            line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            line = NSRect(x: 0, y: 0, width: bounds.width, height: font?.boundingRectForFont.height ?? 16)
        }
        return NSRect(x: 0, y: line.minY + textContainerOrigin.y,
            width: bounds.width, height: max(line.height, font?.boundingRectForFont.height ?? 16))
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawAdditionalSelections(in: rect)
        editorTools?.drawOverlay(in: self, rect: rect)
        guard let highlight = currentLineHighlightRect else { return }
        guard highlight.intersects(rect) else { return }
        currentLineHighlightColor.setFill()
        highlight.intersection(rect).fill()
        if let border = editorTheme?.colors["editor.lineHighlightBorder"] {
            border.nsColor.setStroke()
            NSBezierPath(rect: highlight.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }
}

@MainActor
final class SQLLineNumberRuler: NSRulerView {
    private weak var editor: NSTextView?
    private var starts: [Int] = [0]
    private var indexedText: String?
    private(set) var lastDrawnLineCount = 0
    private(set) var successfulLines: Set<Int> = []
    private var previousScrollOrigin: NSPoint

    init(scrollView: NSScrollView, textView: NSTextView) {
        editor = textView
        previousScrollOrigin = scrollView.contentView.bounds.origin
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        canDrawConcurrently = false
        clientView = textView
        ruleThickness = 40
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        updateLines()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func scrolled() {
        let origin = scrollView?.contentView.bounds.origin ?? .zero
        if previousScrollOrigin != origin {
            previousScrollOrigin = origin
            if let event = NSApp.currentEvent, event.type == .leftMouseDragged || event.type == .scrollWheel {
                (editor as? SQLTextView)?.dismissCompletion?()
            } else { (editor as? SQLTextView)?.viewportChanged?() }
        }
        needsDisplay = true
    }

    func updateLines() {
        guard let editor else { return }
        if indexedText != editor.string {
            indexedText = editor.string
            let units = Array(editor.string.utf16)
            starts = [0]
            for index in units.indices where units[index] == 10 || (units[index] == 13 && (index + 1 == units.count || units[index + 1] != 10)) {
                starts.append(index + 1)
            }
        }
        successfulLines = Set(((editor as? SQLTextView)?.successfulExecutionLocations ?? []).map { lineIndex(at: $0) })
        // Reserve the status column even before a run, so success never moves
        // the text or changes wrapping in a long document.
        ruleThickness = max(40, CGFloat(String(starts.count).count * 9 + 24))
        toolTip = successfulLines.isEmpty ? nil : "Successfully executed lines: " +
            successfulLines.sorted().map { String($0 + 1) }.joined(separator: ", ")
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        lastDrawnLineCount = 0
        guard let editor, let manager = editor.layoutManager, let container = editor.textContainer else { return }
        let theme = (editor as? SQLTextView)?.editorTheme
        (theme?.color("editorGutter.background", default: editor.backgroundColor) ?? NSColor.windowBackgroundColor.withAlphaComponent(0.6)).setFill()
        bounds.fill()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font,
            .foregroundColor: theme?.color("editorLineNumber.foreground", default: .secondaryLabelColor) ?? .secondaryLabelColor]
        let visible = editor.visibleRect.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y)
        // Resolve only glyphs in the viewport. Never force layout or visit every
        // logical line while scrolling a long script.
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = lineIndex(at: characters.location)
        let last = lineIndex(at: min(editor.string.utf16.count, NSMaxRange(characters)))
        for line in first...max(first, last) {
            let start = starts[line]
            let fragment: NSRect
            if start < editor.string.utf16.count {
                let glyph = manager.glyphIndexForCharacter(at: start)
                fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else { fragment = manager.extraLineFragmentRect }
            let origin = convert(NSPoint(x: 0, y: fragment.minY + editor.textContainerOrigin.y), from: editor)
            guard origin.y + fragment.height >= rect.minY, origin.y <= rect.maxY else { continue }
            lastDrawnLineCount += 1
            let isCurrent = line == lineIndex(at: editor.selectedRange().location)
            var lineAttributes = attributes
            if isCurrent {
                lineAttributes[.foregroundColor] = theme?.color("editorLineNumber.activeForeground", default: editor.textColor ?? .labelColor) ?? .labelColor
            }
            let number = "\(line + 1)" as NSString
            let width = number.size(withAttributes: lineAttributes).width
            number.draw(at: NSPoint(x: ruleThickness - width - 10, y: origin.y + 1), withAttributes: lineAttributes)
            if successfulLines.contains(line) {
                NSColor.systemGreen.setStroke()
                let check = NSBezierPath()
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                let y = origin.y + max(0, (font.ascender - font.descender - 8) / 2) + 1
                check.move(to: NSPoint(x: 5, y: y + 4))
                check.line(to: NSPoint(x: 8, y: y + 7))
                check.line(to: NSPoint(x: 13, y: y + 1))
                check.stroke()
            }
            if isCurrent {
                (theme?.color("editorLineNumber.activeForeground", default: editor.textColor ?? .labelColor)
                    ?? NSColor(AppPalette.accent).withAlphaComponent(0.7)).setFill()
                NSRect(x: ruleThickness - 2, y: origin.y + 2, width: 2, height: max(12, fragment.height - 4)).fill()
            }
        }
        if let border = theme?.colors["editorOverviewRuler.border"] {
            border.nsColor.setFill()
            NSRect(x: ruleThickness - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        }
    }

    private func lineIndex(at location: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= location { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }
}
