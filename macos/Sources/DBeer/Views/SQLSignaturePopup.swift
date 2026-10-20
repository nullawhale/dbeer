import AppKit

/// Read-only signature help never becomes a key window or takes editor focus.
@MainActor
final class SQLSignaturePopup {
    private final class Panel: NSPanel, AppThemeIndependentWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let scroll = NSScrollView()
    private let textView = NSTextView(frame: .zero)
    private var theme: EditorTheme?
    private var isPositioning = false
    private(set) var help: SQLSignatureHelp?
    private(set) var highlightedRanges: [NSRange] = []
    var isVisible: Bool { panel.isVisible }

    init() {
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.setAccessibilityIdentifier("sqlSignaturePopup")
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Function signatures")
        textView.setAccessibilityIdentifier("sqlSignatureText")
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.borderWidth = 1
        scroll.layer?.cornerRadius = 5
        scroll.layer?.masksToBounds = true
        panel.contentView = scroll
    }

    func applyTheme(_ theme: EditorTheme?, appearance: NSAppearance) {
        self.theme = theme
        panel.appearance = appearance
        let background = theme?.color("editorSuggestWidget.background", default: .controlBackgroundColor) ?? .controlBackgroundColor
        panel.backgroundColor = background
        scroll.backgroundColor = background
        textView.backgroundColor = background
        appearance.performAsCurrentDrawingAppearance {
            scroll.layer?.borderColor = (theme?.color("editorSuggestWidget.border", default: .separatorColor) ?? .separatorColor).cgColor
        }
        render()
    }

    func show(_ help: SQLSignatureHelp, for editor: NSTextView) {
        guard let window = editor.window, window.isKeyWindow, window.firstResponder === editor else { hide(); return }
        self.help = help
        applyTheme((editor as? SQLTextView)?.editorTheme, appearance: editor.effectiveAppearance)
        reposition(for: editor)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    private func render() {
        guard let help else { return }
        let foreground = theme?.color("editorSuggestWidget.foreground", default: .labelColor) ?? .labelColor
        let selected = theme?.color("editorSuggestWidget.selectedBackground", default: .selectedContentBackgroundColor) ?? .selectedContentBackgroundColor
        let selectedText = theme?.color("editorSuggestWidget.selectedForeground",
            default: theme?.colors["editorSuggestWidget.selectedBackground"] == nil ? .alternateSelectedControlTextColor : foreground)
            ?? .alternateSelectedControlTextColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let text = NSMutableAttributedString(string: "")
        highlightedRanges = []
        let order = [help.activeSignature] + help.signatures.indices.filter { $0 != help.activeSignature }
        for index in order.prefix(8) {
            let signature = help.signatures[index]
            if text.length > 0 { text.append(NSAttributedString(string: "\n\n")) }
            let start = text.length
            text.append(NSAttributedString(string: signature.label, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: foreground, .paragraphStyle: paragraph
            ]))
            if let range = signature.activeParameterRange {
                let span = NSRange(location: start + range.location, length: range.length)
                highlightedRanges.append(span)
                text.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                    .backgroundColor: selected, .foregroundColor: selectedText], range: span)
            }
        }
        if help.signatures.count > 8 {
            text.append(NSAttributedString(string: "\n\n\(help.signatures.count) overloads", attributes: [.foregroundColor: foreground, .font: NSFont.systemFont(ofSize: 11)]))
        }
        textView.textStorage?.setAttributedString(text)
        textView.setAccessibilityValue(text.string)
    }

    func reposition(for editor: NSTextView) {
        guard !isPositioning, help != nil, let window = editor.window else { return }
        isPositioning = true
        defer { isPositioning = false }
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let width = min(540, max(280, screen.width - 24))
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        textView.textContainer?.containerSize = NSSize(width: width - 20, height: .greatestFiniteMagnitude)
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        let naturalHeight = (textView.textContainer.flatMap { textView.layoutManager?.usedRect(for: $0).height } ?? 24) + 16
        let caret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        let above = screen.maxY - caret.maxY - 8
        let height = min(220, min(max(36, naturalHeight), max(36, above)))
        let x = min(max(caret.minX, screen.minX + 8), screen.maxX - width - 8)
        // Signature help stays above the caret; completion occupies the space below.
        let y = min(caret.maxY + 4, screen.maxY - height - 4)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        textView.setFrameSize(NSSize(width: width, height: max(height, naturalHeight)))
    }

    func hide() {
        help = nil
        highlightedRanges = []
        panel.orderOut(nil)
        panel.parent?.removeChildWindow(panel)
    }
}
