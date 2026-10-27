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
    var partitionMarkers: [GridPartitionMarker?]?
    private var numberWidth: CGFloat = 40
    private let selectionHelp = "Select rows. Shift-click to select a range; Command-click to toggle individual rows."

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(scrollView: NSScrollView, table: ResultGridTableView) {
        self.table = table
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = table
        ruleThickness = 40
        toolTip = selectionHelp
        setAccessibilityLabel("Row numbers")
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateRowCount() {
        let number = String(max(1, table?.numberOfRows ?? 0)) as NSString
        numberWidth = max(40, ceil(number.size(withAttributes: [.font: font]).width) + 20)
        let width = numberWidth + (partitionMarkers == nil ? 0 : 88)
        if ruleThickness != width { ruleThickness = width }
        setAccessibilityLabel(partitionMarkers == nil ? "Row numbers" : "Row numbers and partitions")
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    @objc private func scrolled() {
        hoveredRow = nil
        toolTip = selectionHelp
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func partitionMarker(forRow row: Int) -> GridPartitionMarker? {
        guard let partitionMarkers, partitionMarkers.indices.contains(row) else { return nil }
        return partitionMarkers[row]
    }

    private func rows(in marker: GridPartitionMarker) -> IndexSet {
        guard let partitionMarkers, let table else { return [] }
        return IndexSet(partitionMarkers.indices.prefix(table.numberOfRows).filter {
            partitionMarkers[$0]?.number == marker.number
        })
    }

    @discardableResult
    private func selectPartition(at row: Int) -> Bool {
        guard let marker = partitionMarker(forRow: row), let table else { return false }
        table.selectPartitionRows(rows(in: marker))
        return true
    }

    private func partitionRect(forRow row: Int) -> NSRect {
        var rect = rect(forRow: row)
        rect.origin.x = numberWidth
        rect.size.width = max(0, bounds.width - numberWidth)
        return rect.intersection(dataRect)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard partitionMarkers != nil else { return }
        for row in visibleRows where partitionMarker(forRow: row) != nil {
            let rect = partitionRect(forRow: row)
            if !rect.isEmpty { addCursorRect(rect, cursor: .pointingHand) }
        }
    }

    private func partitionColor(_ marker: GridPartitionMarker) -> NSColor {
        let colors: [NSColor] = [.systemBlue, .systemOrange, .systemTeal, .systemPurple, .systemPink, .systemIndigo]
        return colors[(marker.number - 1) % colors.count]
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
            number.draw(at: NSPoint(x: numberWidth - size.width - 10, y: rowRect.midY - size.height / 2),
                withAttributes: attributes)
            if partitionMarkers != nil {
                let marker = partitionMarker(forRow: row)
                if let marker {
                    let color = partitionColor(marker)
                    color.setFill()
                    NSRect(x: numberWidth, y: rowRect.minY, width: 3, height: rowRect.height).fill()
                    NSBezierPath(ovalIn: NSRect(x: numberWidth + 13, y: rowRect.midY - 4, width: 8, height: 8)).fill()
                }
                let label = (marker?.label ?? "—") as NSString
                let labelSize = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: numberWidth + 28, y: rowRect.midY - labelSize.height / 2), withAttributes: attributes)
            }
            border.setFill()
            NSRect(x: 0, y: rowRect.maxY - 1, width: bounds.width, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        border.setFill()
        if dataRect.minY > bounds.minY {
            NSRect(x: bounds.minX, y: dataRect.minY - 1, width: bounds.width, height: 1).fill()
            if partitionMarkers != nil {
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: AppPalette.isCustom ? AppPalette.nsColor(.text) : NSColor.labelColor]
                let title = "Partition" as NSString
                let size = title.size(withAttributes: attributes)
                title.draw(at: NSPoint(x: numberWidth + 8, y: (bounds.minY + dataRect.minY - size.height) / 2), withAttributes: attributes)
            }
        }
        if partitionMarkers != nil {
            border.setFill()
            NSRect(x: numberWidth - 1, y: rect.minY, width: 1, height: rect.height).fill()
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
        if convert(event.locationInWindow, from: nil).x >= numberWidth, selectPartition(at: row) { return }
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

    private func updateHover(with event: NSEvent) {
        hoveredRow = row(at: event)
        let point = convert(event.locationInWindow, from: nil)
        let help: String
        if partitionMarkers != nil, point.x >= numberWidth, let hoveredRow {
            help = partitionMarker(forRow: hoveredRow)?.help ?? "A complete partition key is unavailable for this row."
        } else { help = selectionHelp }
        if toolTip != help { toolTip = help }
    }

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) { hoveredRow = nil; toolTip = selectionHelp }

    override func accessibilityChildren() -> [Any]? {
        visibleRows.flatMap { row -> [NSAccessibilityElement] in
            let visibleRect = rect(forRow: row).intersection(dataRect)
            guard !visibleRect.isEmpty else { return [] }
            let element = ResultGridRowNumberAccessibilityElement { [weak table] in
                guard let table, row < table.numberOfRows else { return false }
                table.selectRowNumber(row)
                return true
            }
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("Select row \(row + 1)")
            element.setAccessibilitySelected(table?.selectedRowIndexes.contains(row) == true)
            element.setAccessibilityHelp(selectionHelp)
            var numberRect = visibleRect
            numberRect.size.width = numberWidth
            if let window {
                element.setAccessibilityFrame(window.convertToScreen(convert(numberRect, to: nil)))
            }
            guard let marker = partitionMarker(forRow: row) else { return [element] }
            let partition = ResultGridRowNumberAccessibilityElement { [weak self] in
                self?.selectPartition(at: row) ?? false
            }
            partition.setAccessibilityParent(self)
            partition.setAccessibilityRole(.button)
            partition.setAccessibilityLabel("Select all loaded rows in partition \(marker.label)")
            partition.setAccessibilityValue(marker.label)
            partition.setAccessibilityHelp(marker.help)
            partition.setAccessibilityIdentifier("gridPartitionMarker-\(row)")
            partition.setAccessibilitySelected(rows(in: marker).isSubset(of: table?.selectedRowIndexes ?? []))
            if let window {
                partition.setAccessibilityFrame(window.convertToScreen(convert(partitionRect(forRow: row), to: nil)))
            }
            return [element, partition]
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
