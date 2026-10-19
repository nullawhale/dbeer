import AppKit
import SwiftUI

/// Native views retain selection and a separate undo manager for every document,
/// including while SwiftUI unmounts that document's editor.
@MainActor
final class SQLEditorState {
    fileprivate var editors: [UUID: SQLTextView] = [:]
    fileprivate var scrollOrigins: [UUID: NSPoint] = [:]

    func selection(for documentID: UUID) -> NSRange {
        editors[documentID]?.selectedRange() ?? NSRange(location: 0, length: 0)
    }

    func removeDocument(_ documentID: UUID) {
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
    var completions: [String] = []
    /// A zero-based UTF-16 offset in the document, matching NSTextView ranges.
    var errorPosition: Int?

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = context.coordinator.makeScrollView()
        update(scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        update(scrollView, coordinator: context.coordinator)
    }

    private func update(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.update(text: $text, isEditable: isEditable, in: scrollView,
            editorState: editorState, documentID: documentID, engine: engine,
            selectionChanged: selectionChanged, onRunSelection: onRunSelection,
            completions: completions, errorPosition: errorPosition)
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
        private var completionCandidates: [String] = []
        private var errorPosition: Int?
        private var lastScrolledError: Int?
        private var isUpdating = false

        init(text: Binding<String>) { self.text = text }

        func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView(frame: .zero)
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
                cached.delegate = self
                return cached
            }
            let textView = SQLTextView(frame: .zero)
            textView.delegate = self
            textView.focusRingType = .none
            textView.isRichText = false
            textView.importsGraphics = false
            textView.allowsUndo = true
            textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            textView.textColor = .labelColor
            textView.insertionPointColor = .labelColor
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: TextInputAppearance.padding, height: TextInputAppearance.padding)
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
                    onRunSelection: ((NSRange) -> Void)? = nil, completions: [String] = [], errorPosition: Int? = nil) {
            self.text = text
            self.engine = engine
            self.selectionChanged = selectionChanged
            self.onRunSelection = onRunSelection
            self.completionCandidates = completions
            self.errorPosition = errorPosition
            let state = editorState ?? localState
            let id = documentID ?? localDocumentID
            isUpdating = true
            defer { isUpdating = false }
            if activeState !== state || activeDocumentID != id {
                if let oldID = activeDocumentID { activeState?.scrollOrigins[oldID] = scrollView.contentView.bounds.origin }
                let next = editor(in: state, documentID: id)
                scrollView.documentView = next
                installRuler(in: scrollView, textView: next)
                activeState = state
                activeDocumentID = id
                lastScrolledError = nil
                if let origin = state.scrollOrigins[id] {
                    scrollView.contentView.scroll(to: origin)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
            guard let textView = scrollView.documentView as? SQLTextView else { return }
            textView.delegate = self
            if onRunSelection != nil {
                textView.runSelection = { [weak self] in self?.onRunSelection?($0) }
            } else { textView.runSelection = nil }
            textView.isEditable = isEditable
            textView.isSelectable = true
            if textView.string != text.wrappedValue {
                let selection = textView.selectedRanges
                textView.string = text.wrappedValue
                let length = textView.string.utf16.count
                textView.selectedRanges = selection.map { value in
                    let range = value.rangeValue
                    let location = min(range.location, length)
                    return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
                }
            }
            highlight(textView)
            (scrollView.verticalRulerView as? SQLLineNumberRuler)?.updateLines()
            if let errorPosition, errorPosition != lastScrolledError {
                let location = min(max(0, errorPosition), textView.string.utf16.count)
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
                lastScrolledError = errorPosition
            } else if errorPosition == nil { lastScrolledError = nil }
        }

        private func highlight(_ textView: NSTextView) {
            guard let manager = textView.layoutManager else { return }
            let full = NSRange(location: 0, length: textView.string.utf16.count)
            for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineColor, .underlineStyle] {
                manager.removeTemporaryAttribute(key, forCharacterRange: full)
            }
            let parsed = SQLScriptParser.parse(textView.string, engine: engine)
            for token in parsed.tokens {
                let color: NSColor
                switch token.kind {
                case .keyword: color = .systemPurple
                case .string: color = .systemGreen
                case .identifier: continue
                case .number: color = .systemBlue
                case .comment: color = .secondaryLabelColor
                }
                manager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
            }
            var ranges = parsed.diagnostics.map(\.range)
            if let errorPosition, full.length > 0 {
                ranges.append(NSRange(location: min(max(0, errorPosition), full.length - 1), length: 1))
            }
            for range in ranges where range.length > 0 {
                manager.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: NSColor.systemRed], forCharacterRange: range)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            highlight(textView)
            (textView.enclosingScrollView?.verticalRulerView as? SQLLineNumberRuler)?.updateLines()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            selectionChanged?(textView.selectedRange())
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let prefix = (textView.string as NSString).substring(with: charRange)
            let matches: (String) -> Bool = { $0.lowercased().hasPrefix(prefix.lowercased()) }
            let keywords = SQLScriptParser.keywords.filter(matches)
            let reserved = Set(SQLScriptParser.keywords)
            let identifiers = completionCandidates.filter(matches).map { name in
                let units = Array(name.utf16)
                let safe = !units.isEmpty && units.enumerated().allSatisfy { offset, unit in
                    (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 ||
                        (offset > 0 && ((48...57).contains(unit) || unit == 36))
                }
                let needsQuotes = !safe || reserved.contains(name.uppercased()) ||
                    (engine == .postgresql && name != name.lowercased())
                guard needsQuotes else { return name }
                let quote = engine == .postgresql ? "\"" : "`"
                return quote + name.replacingOccurrences(of: quote, with: quote + quote) + quote
            }
            index?.pointee = 0
            return Array(Set(keywords + identifiers))
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.prefix(100).map { $0 }
        }
    }
}

@MainActor
private final class SQLTextView: NSTextView {
    private let documentUndo = UndoManager()
    var runSelection: ((NSRange) -> Void)?
    override var undoManager: UndoManager? { documentUndo }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 36, let runSelection {
            runSelection(selectedRange())
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 36, let runSelection {
            runSelection(selectedRange())
            return
        }
        if event.modifierFlags.contains(.control), event.keyCode == 49 { complete(nil); return }
        super.keyDown(with: event)
    }
}

@MainActor
private final class SQLLineNumberRuler: NSRulerView {
    private weak var editor: NSTextView?
    private var starts: [Int] = [0]

    init(scrollView: NSScrollView, textView: NSTextView) {
        editor = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        updateLines()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func scrolled() { needsDisplay = true }

    func updateLines() {
        guard let editor else { return }
        let units = Array(editor.string.utf16)
        starts = [0]
        for index in units.indices where units[index] == 10 || (units[index] == 13 && (index + 1 == units.count || units[index + 1] != 10)) {
            starts.append(index + 1)
        }
        ruleThickness = max(40, CGFloat(String(starts.count).count * 9 + 16))
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor, let manager = editor.layoutManager, let container = editor.textContainer else { return }
        NSColor.windowBackgroundColor.withAlphaComponent(0.6).setFill()
        bounds.fill()
        manager.ensureLayout(for: container)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor]
        for (line, start) in starts.enumerated() {
            let fragment: NSRect
            if start < editor.string.utf16.count {
                let glyph = manager.glyphIndexForCharacter(at: start)
                fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else { fragment = manager.extraLineFragmentRect }
            let origin = convert(NSPoint(x: 0, y: fragment.minY + editor.textContainerOrigin.y), from: editor)
            guard origin.y + fragment.height >= rect.minY, origin.y <= rect.maxY else { continue }
            let number = "\(line + 1)" as NSString
            let width = number.size(withAttributes: attributes).width
            number.draw(at: NSPoint(x: ruleThickness - width - 8, y: origin.y), withAttributes: attributes)
        }
    }
}
