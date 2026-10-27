import AppKit
import SwiftUI

/// Selectable native text panes with aligned rows and one vertical scroll position.
struct ComparisonDiffView: View {
    var diff: ComparisonTextDiff
    var sourceTitle = "Source"
    var targetTitle = "Target"
    var syntaxEngine: DatabaseEngine? = nil
    var limitedMessage = "Limited diff. Use exact values to inspect the full content."

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                // Match the native pane constraints exactly, independently of
                // each heading's title or value label width.
                let columnWidth = max(0, (geometry.size.width - 1) / 2)
                HStack(spacing: 0) {
                    heading(sourceTitle, value: diff.source).frame(width: columnWidth)
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                    heading(targetTitle, value: diff.target).frame(width: columnWidth)
                }.frame(height: geometry.size.height)
            }
            .frame(height: 36)
            .background(AppPalette.panel)
            .clipped()
            Divider()
            NativeComparisonDiff(diff: diff, syntaxEngine: syntaxEngine)
            if diff.status == .limited {
                Divider()
                Label(limitedMessage, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } else if diff.status == .binary {
                Divider()
                Label("Binary values cannot be shown as text.", systemImage: "doc")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Value difference")
    }

    private func heading(_ title: String, value: ComparisonTextDiff.Value) -> some View {
        HStack(spacing: 8) {
            Text(title).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 4)
            if let label = value.label { Text(label).foregroundStyle(.secondary).lineLimit(1) }
        }
        .font(.caption).padding(.horizontal, 10).frame(maxWidth: .infinity)
    }
}

/// Color the complete aligned document so SQL lexical state survives line
/// boundaries and alignment gaps. Syntax changes foreground colors only;
/// intraline difference backgrounds remain owned by the comparison result.
@MainActor
enum ComparisonDiffSyntax {
    static func apply(to text: NSMutableAttributedString, engine: DatabaseEngine) {
        for token in SQLScriptParser.parse(text.string, engine: engine).tokens {
            let color: NSColor
            switch token.kind {
            case .keyword: color = SQLSyntaxPalette.keyword
            case .string: color = SQLSyntaxPalette.string
            case .number: color = SQLSyntaxPalette.number
            case .comment: color = .secondaryLabelColor
            case .identifier: continue
            }
            text.addAttribute(.foregroundColor, value: color, range: token.range)
        }
    }
}

private struct NativeComparisonDiff: NSViewRepresentable {
    var diff: ComparisonTextDiff
    var syntaxEngine: DatabaseEngine?

    func makeNSView(context: Context) -> ComparisonDiffPanes { ComparisonDiffPanes() }
    func updateNSView(_ view: ComparisonDiffPanes, context: Context) { view.update(diff, engine: syntaxEngine) }
}

@MainActor
private final class ComparisonDiffPanes: NSView {
    private let sourceScroll = NSScrollView()
    private let targetScroll = NSScrollView()
    private let sourceText = ComparisonDiffTextView(frame: .zero, textContainer: nil)
    private let targetText = ComparisonDiffTextView(frame: .zero, textContainer: nil)
    private var diff: ComparisonTextDiff?
    private var engine: DatabaseEngine?
    private var synchronizing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        for (scroll, text) in [(sourceScroll, sourceText), (targetScroll, targetText)] {
            scroll.clipsToBounds = true
            scroll.documentView = text
            scroll.verticalRulerView = ComparisonDiffLineNumberRuler(scrollView: scroll, textView: text)
            scroll.hasVerticalRuler = true
            scroll.rulersVisible = true
            scroll.hasHorizontalScroller = true
            scroll.hasVerticalScroller = scroll === targetScroll
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.translatesAutoresizingMaskIntoConstraints = false
            addSubview(scroll)
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        sourceText.setAccessibilityLabel("Source value")
        targetText.setAccessibilityLabel("Target value")
        NSLayoutConstraint.activate([
            sourceScroll.leadingAnchor.constraint(equalTo: leadingAnchor), sourceScroll.topAnchor.constraint(equalTo: topAnchor),
            sourceScroll.bottomAnchor.constraint(equalTo: bottomAnchor), sourceScroll.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5, constant: -0.5),
            targetScroll.leadingAnchor.constraint(equalTo: sourceScroll.trailingAnchor, constant: 1), targetScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            targetScroll.topAnchor.constraint(equalTo: topAnchor), targetScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func update(_ next: ComparisonTextDiff, engine: DatabaseEngine?) {
        guard diff != next || self.engine != engine else { return }
        diff = next; self.engine = engine
        sourceText.update(next.lines, source: true, engine: engine)
        targetText.update(next.lines, source: false, engine: engine)
        sourceScroll.contentView.scroll(to: .zero); targetScroll.contentView.scroll(to: .zero)
        sourceScroll.verticalRulerView?.needsDisplay = true; targetScroll.verticalRulerView?.needsDisplay = true
        needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let diff else { return }
        sourceText.update(diff.lines, source: true, engine: engine)
        targetText.update(diff.lines, source: false, engine: engine)
        sourceScroll.verticalRulerView?.needsDisplay = true; targetScroll.verticalRulerView?.needsDisplay = true
        needsLayout = true
    }
    override func layout() {
        super.layout()
        sourceText.fit(viewport: sourceScroll.contentView.bounds.size)
        targetText.fit(viewport: targetScroll.contentView.bounds.size)
    }
    override func draw(_ dirtyRect: NSRect) {
        // Paint only the seam. Filling an invalidation rectangle can include
        // surrounding SwiftUI headers during native view resizing.
        let seam = NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
        NSColor.separatorColor.setFill()
        seam.intersection(dirtyRect).fill()
    }
    @objc private func scrolled(_ notification: Notification) {
        guard !synchronizing, let clip = notification.object as? NSClipView else { return }
        synchronizing = true
        defer { synchronizing = false }
        let other = clip === sourceScroll.contentView ? targetScroll : sourceScroll
        var position = other.contentView.bounds.origin
        position.y = clip.bounds.origin.y
        other.contentView.scroll(to: position)
        other.reflectScrolledClipView(other.contentView)
        sourceText.needsDisplay = true; targetText.needsDisplay = true
        sourceScroll.verticalRulerView?.needsDisplay = true; targetScroll.verticalRulerView?.needsDisplay = true
    }
}

@MainActor
private final class ComparisonDiffTextView: NSTextView {
    static let lineHeight: CGFloat = 20
    static let top: CGFloat = 8
    private static let horizontalInset: CGFloat = 10
    private static let layoutSize = NSSize(width: 16_000_000, height: 16_000_000)
    private let backingTextStorage: NSTextStorage
    private(set) var rows: [ComparisonTextDiff.Line] = []
    private(set) var source = true
    private var contentWidth: CGFloat = 0

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        // The designated initializer accepts a container but does not create
        // a text system for nil. Keep a complete TextKit 1 stack for selectable
        // glyph rendering, including when instantiated with no container.
        let resolvedContainer = container ?? NSTextContainer(size: Self.layoutSize)
        let manager = resolvedContainer.layoutManager ?? NSLayoutManager()
        let storage = manager.textStorage ?? NSTextStorage()
        if manager.textStorage == nil { storage.addLayoutManager(manager) }
        if resolvedContainer.layoutManager == nil { manager.addTextContainer(resolvedContainer) }
        backingTextStorage = storage
        super.init(frame: frameRect, textContainer: resolvedContainer)
        isEditable = false; isSelectable = true; isRichText = false
        allowsUndo = false; isAutomaticLinkDetectionEnabled = false
        isVerticallyResizable = false; isHorizontallyResizable = false
        drawsBackground = true; backgroundColor = .textBackgroundColor
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textContainerInset = NSSize(width: Self.horizontalInset, height: Self.top)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.size = Self.layoutSize
        layoutManager?.showsInvisibleCharacters = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ rows: [ComparisonTextDiff.Line], source: Bool, engine: DatabaseEngine?) {
        self.rows = rows; self.source = source
        layoutManager?.showsInvisibleCharacters = engine == nil
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Self.lineHeight; paragraph.maximumLineHeight = Self.lineHeight
        let text = NSMutableAttributedString()
        var widestLine: CGFloat = 0
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        for (index, row) in rows.enumerated() {
            let line = source ? row.source : row.target
            let original = line?.text ?? ""
            // NSTextView treats these scalars as paragraph breaks. Keep one
            // UTF-16 unit per scalar so the helper's highlight offsets stay exact.
            let value = String(String.UnicodeScalarView(original.unicodeScalars.map { scalar in
                switch scalar.value {
                case 13: return Unicode.Scalar(0x240D)!
                case 11: return Unicode.Scalar(0x240B)!
                case 12: return Unicode.Scalar(0x240C)!
                case 0x85: return Unicode.Scalar(0x2424)!
                case 0x2028, 0x2029: return Unicode.Scalar(0x21B5)!
                default: return scalar
                }
            }))
            // Measure actual text independently of the deliberately wide
            // no-wrap layout container; usedRect may include paragraph fill.
            widestLine = max(widestLine, ceil((value as NSString).size(withAttributes: base).width))
            let offset = text.length
            text.append(NSAttributedString(string: value, attributes: base))
            for highlight in line?.highlights ?? [] {
                guard let range = highlight.cocoaRange(in: original) else { continue }
                text.addAttribute(.backgroundColor, value: changeColor.withAlphaComponent(0.32), range: NSRange(location: offset + range.location, length: range.length))
            }
            if index < rows.count - 1 { text.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        if let engine { ComparisonDiffSyntax.apply(to: text, engine: engine) }
        backingTextStorage.setAttributedString(text)
        guard let manager = layoutManager, let container = textContainer else {
            assertionFailure("The diff text view must retain its complete text system.")
            return
        }
        manager.ensureLayout(for: container)
        contentWidth = widestLine + Self.horizontalInset * 2
        needsDisplay = true
    }
    func fit(viewport: NSSize) {
        let size = NSSize(width: max(viewport.width, contentWidth), height: max(viewport.height, CGFloat(rows.count) * Self.lineHeight + Self.top * 2))
        if frame.size != size { setFrameSize(size) }
    }
    private var changeColor: NSColor { source ? .systemRed : .systemGreen }
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let first = max(0, Int((rect.minY - Self.top) / Self.lineHeight))
        let last = min(rows.count, Int(ceil((rect.maxY - Self.top) / Self.lineHeight)))
        guard first < last else { return }
        for index in first..<last {
            if let color = rowBackground(at: index) {
                color.setFill()
                NSRect(x: 0, y: Self.top + CGFloat(index) * Self.lineHeight, width: bounds.width, height: Self.lineHeight).fill()
            }
        }
    }
    func rowBackground(at index: Int) -> NSColor? {
        let row = rows[index]
        guard row.kind != .equal else { return nil }
        let present = source ? row.source != nil : row.target != nil
        return present ? changeColor.withAlphaComponent(0.10) : NSColor.labelColor.withAlphaComponent(0.035)
    }
}

@MainActor
private final class ComparisonDiffLineNumberRuler: NSRulerView {
    private weak var textView: ComparisonDiffTextView?
    override var isFlipped: Bool { true }

    init(scrollView: NSScrollView, textView: ComparisonDiffTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        canDrawConcurrently = false
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let textView else { return }
        let height = ComparisonDiffTextView.lineHeight
        let top = ComparisonDiffTextView.top
        let visible = textView.visibleRect
        let first = max(0, Int((visible.minY - top) / height))
        let last = min(textView.rows.count, Int(ceil((visible.maxY - top) / height)))
        guard first < last else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for index in first..<last {
            let origin = convert(NSPoint(x: 0, y: top + CGFloat(index) * height), from: textView)
            if let color = textView.rowBackground(at: index) {
                color.setFill()
                NSRect(x: 0, y: origin.y, width: ruleThickness, height: height).fill()
            }
            let row = textView.rows[index]
            guard let line = textView.source ? row.source : row.target else { continue }
            let number = String(line.number) as NSString
            number.draw(at: NSPoint(x: ruleThickness - number.size(withAttributes: attributes).width - 8, y: origin.y + 4), withAttributes: attributes)
        }
    }
}
