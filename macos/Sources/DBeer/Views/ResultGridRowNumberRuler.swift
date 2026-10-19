import AppKit

/// Row selectors stay outside the data columns, including while scrolling horizontally.
@MainActor
final class ResultGridRowNumberRuler: NSRulerView {
    private weak var table: ResultGridTableView?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    private var hoverTracking: NSTrackingArea?
    private var hoveredRow: Int? {
        didSet { if hoveredRow != oldValue { needsDisplay = true } }
    }
    private var isSelectingRows = false

    override var isFlipped: Bool { true }

    init(scrollView: NSScrollView, table: ResultGridTableView) {
        self.table = table
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = table
        ruleThickness = 40
        toolTip = "Select rows. Shift-click to select a range; Command-click to toggle individual rows."
        setAccessibilityLabel("Row numbers")
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateRowCount() {
        let number = String(max(1, table?.numberOfRows ?? 0)) as NSString
        let width = max(40, ceil(number.size(withAttributes: [.font: font]).width) + 20)
        if ruleThickness != width { ruleThickness = width }
        needsDisplay = true
    }

    @objc private func scrolled() {
        hoveredRow = nil
        needsDisplay = true
    }

    private var visibleRows: Range<Int> {
        guard let table else { return 0..<0 }
        let rows = table.rows(in: table.visibleRect)
        guard rows.location != NSNotFound else { return 0..<0 }
        return rows.location..<min(table.numberOfRows, NSMaxRange(rows))
    }

    func rect(forRow row: Int) -> NSRect {
        guard let table else { return .zero }
        let rect = convert(table.rect(ofRow: row), from: table)
        return NSRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height)
    }

    private var dataRect: NSRect {
        guard let header = table?.headerView else { return bounds }
        let top = max(bounds.minY, convert(header.bounds, from: header).maxY)
        return NSRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top))
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let table else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        let background = AppPalette.isCustom ? AppPalette.nsColor(.control) : NSColor.controlBackgroundColor
        let border = AppPalette.isCustom ? AppPalette.nsColor(.border) : NSColor.separatorColor
        background.setFill()
        bounds.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: dataRect).addClip()
        for row in visibleRows {
            let rowRect = self.rect(forRow: row)
            guard rowRect.intersects(rect) else { continue }
            let selected = table.selectedRowIndexes.contains(row)
            let accent = AppPalette.nsColor(.accent)
            if selected {
                (AppPalette.isCustom ? AppPalette.nsColor(.selection) : accent.withAlphaComponent(0.22)).setFill()
                rowRect.fill()
            } else if hoveredRow == row {
                accent.withAlphaComponent(0.1).setFill()
                rowRect.fill()
            }
            let foreground = AppPalette.isCustom ? AppPalette.nsColor(selected ? .selectionText : .secondaryText) :
                (selected ? NSColor.labelColor : NSColor.secondaryLabelColor)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
            let number = String(row + 1) as NSString
            let size = number.size(withAttributes: attributes)
            number.draw(at: NSPoint(x: bounds.maxX - size.width - 10, y: rowRect.midY - size.height / 2),
                withAttributes: attributes)
            border.setFill()
            NSRect(x: 0, y: rowRect.maxY - 1, width: bounds.width, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        border.setFill()
        if dataRect.minY > bounds.minY {
            NSRect(x: bounds.minX, y: dataRect.minY - 1, width: bounds.width, height: 1).fill()
        }
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
    }

    private func row(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        guard dataRect.contains(point) else { return nil }
        let row = row(atWindowPoint: event.locationInWindow)
        return row >= 0 ? row : nil
    }

    private func row(atWindowPoint point: NSPoint) -> Int {
        guard let table else { return -1 }
        // NSTableView rejects points outside its horizontal bounds. The gutter
        // sits to its left, so only use the pointer's vertical coordinate.
        let y = table.convert(point, from: nil).y
        return table.row(at: NSPoint(x: table.visibleRect.midX, y: y))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Rulers contain native drawing subviews; keep mouse tracking here.
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        isSelectingRows = false
        guard let row = row(at: event) else { return }
        isSelectingRows = true
        table?.selectRowNumber(row, modifiers: event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelectingRows, let table, table.numberOfRows > 0 else { return }
        let point = table.convert(event.locationInWindow, from: nil)
        // Autoscroll vertically without moving back to the first data column.
        let location = table.convert(NSPoint(x: table.visibleRect.midX, y: point.y), to: nil)
        if let scrollEvent = NSEvent.mouseEvent(with: .leftMouseDragged, location: location,
            modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber,
            context: nil, eventNumber: event.eventNumber, clickCount: 1, pressure: event.pressure) {
            _ = table.autoscroll(with: scrollEvent)
        }
        let row = row(atWindowPoint: event.locationInWindow)
        table.selectRowNumber(row >= 0 ? row : (point.y < 0 ? 0 : table.numberOfRows - 1), extending: true)
    }

    override func mouseUp(with event: NSEvent) { isSelectingRows = false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { hoveredRow = row(at: event) }
    override func mouseMoved(with event: NSEvent) { hoveredRow = row(at: event) }
    override func mouseExited(with event: NSEvent) { hoveredRow = nil }

    override func accessibilityChildren() -> [Any]? {
        visibleRows.compactMap { row -> NSAccessibilityElement? in
            let visibleRect = rect(forRow: row).intersection(dataRect)
            guard !visibleRect.isEmpty else { return nil }
            let element = ResultGridRowNumberAccessibilityElement { [weak table] in
                guard let table, row < table.numberOfRows else { return false }
                table.selectRowNumber(row)
                return true
            }
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("Select row \(row + 1)")
            element.setAccessibilitySelected(table?.selectedRowIndexes.contains(row) == true)
            if let window {
                element.setAccessibilityFrame(window.convertToScreen(convert(visibleRect, to: nil)))
            }
            return element
        }
    }
}

private final class ResultGridRowNumberAccessibilityElement: NSAccessibilityElement {
    private let press: @MainActor @Sendable () -> Bool

    init(press: @escaping @MainActor @Sendable () -> Bool) {
        self.press = press
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        let press = press
        return MainActor.assumeIsolated { press() }
    }
}
