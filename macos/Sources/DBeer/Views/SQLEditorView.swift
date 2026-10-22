import AppKit
import SwiftUI

/// Native views retain selection and a separate undo manager for every document,
/// including while SwiftUI unmounts that document's editor.
@MainActor
final class SQLEditorState {
    let languageService = SQLLanguageService()
    fileprivate var editors: [UUID: SQLTextView] = [:]
    fileprivate var scrollOrigins: [UUID: NSPoint] = [:]

    func selection(for documentID: UUID, fallback: NSRange = NSRange(location: 0, length: 0)) -> NSRange {
        editors[documentID]?.selectedRange() ?? fallback
    }

    func prepareForPaneMove(_ documentID: UUID) {
        guard let editor = editors[documentID], editor.window?.firstResponder === editor else { return }
        editor.restoreFocusAfterPaneMove = true
    }

    func removeDocument(_ documentID: UUID) {
        languageService.close(documentID: documentID)
        editors[documentID]?.dismissCompletion?()
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
        private var lastScrolledError: Int?
        private var isUpdating = false
        private var languageService: SQLLanguageService?
        private var diagnosticsObserver: UUID?
        private var completionContext: SQLCompletionContext = .empty
        private var completionTask: Task<Void, Never>?
        private var completionGeneration = 0
        private let completionPopup = SQLCompletionPopup()
        private var completionSnapshot: CompletionSnapshot?
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
                let selection = textView.selectedRanges
                textView.string = text.wrappedValue
                let length = textView.string.utf16.count
                textView.selectedRanges = selection.map { value in
                    let range = value.rangeValue
                    let location = min(range.location, length)
                    return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
                }
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
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
                lastScrolledError = errorPosition
            } else if errorPosition == nil { lastScrolledError = nil }
            requestSignatureHelp(in: textView)
        }

        private func parse(_ value: String) -> SQLParseResult {
            if parsedText == value, parsedEngine == engine, let parsedResult { return parsedResult }
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
            highlightExecutionFragment(textView)
            let languageDiagnostics = activeDocumentID.flatMap { languageService?.diagnostics(documentID: $0) } ?? []
            if let editor = textView as? SQLTextView {
                guard editor.syntaxText != textView.string || editor.syntaxEngine != engine ||
                        editor.syntaxDiagnostics != languageDiagnostics || editor.syntaxErrorPosition != errorPosition ||
                        editor.syntaxTheme != editorTheme else { return }
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
            if selection.length == 0 {
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
            guard !isUpdating, let textView = notification.object as? NSTextView, isActiveEditor(textView) else { return }
            if completionSnapshot != snapshot(for: textView) { dismissCompletions() }
            textView.needsDisplay = true
            highlightExecutionFragment(textView)
            (textView.enclosingScrollView?.verticalRulerView as? SQLLineNumberRuler)?.needsDisplay = true
            selectionChanged?(textView.selectedRange())
            if let textView = textView as? SQLTextView { requestSignatureHelp(in: textView) }
        }

        private func snapshot(for textView: NSTextView) -> CompletionSnapshot? {
            guard isActiveEditor(textView), let activeDocumentID else { return nil }
            return CompletionSnapshot(documentID: activeDocumentID, text: textView.string,
                selection: textView.selectedRange(), engine: engine, context: completionContext)
        }

        private func dismissCompletions() {
            completionGeneration += 1
            completionTask?.cancel()
            completionTask = nil
            completionSnapshot = nil
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
            guard textView.isEditable, !textView.hasMarkedText(),
                  textView.window?.firstResponder === textView, textView.window?.isKeyWindow == true,
                  let snapshot = snapshot(for: textView), snapshot.selection.length == 0,
                  !suppressesCompletion(text: snapshot.text, offset: snapshot.selection.location) else { return }
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
            if event.keyCode == 53, completionTask != nil || !completionPopup.items.isEmpty || signatureTask != nil || signaturePopup.isVisible {
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
    private(set) var editorTheme: EditorTheme?
    var syntaxText: String?
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
    override var undoManager: UndoManager? { documentUndo }

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
        if commandEvent?(event, selectedRange()) == true { return }
        if commandEvent == nil, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 36, let runSelection {
            runSelection(selectedRange())
            return
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control, event.keyCode == 49 { complete(nil); return }
        super.keyDown(with: event)
    }

    override func complete(_ sender: Any?) { requestCompletion?() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowGeometryChanged),
                name: NSWindow.didResizeNotification, object: window)
            if restoreFocusAfterPaneMove {
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
