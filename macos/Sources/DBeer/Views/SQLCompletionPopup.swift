import AppKit

/// A child panel keeps the native editor as the key responder while candidates
/// can still be inspected and selected with the mouse.
@MainActor
final class SQLCompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private final class Panel: NSPanel, AppThemeIndependentWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class Row: NSTableRowView {
        var selectionColor = NSColor.selectedContentBackgroundColor
        override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
        override func drawSelection(in dirtyRect: NSRect) {
            selectionColor.setFill()
            bounds.intersection(dirtyRect).fill()
        }
    }

    private final class Cell: NSTableCellView {
        var detailField: NSTextField?
    }

    private let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: true)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var accept: (() -> Void)?
    private var isPositioning = false
    private var editorTheme: EditorTheme?
    private(set) var items: [SQLCompletionItem] = []
    var selectedIndex: Int? { items.indices.contains(table.selectedRow) ? table.selectedRow : nil }
    var selectedItem: SQLCompletionItem? { selectedIndex.map { items[$0] } }

    private var backgroundColor: NSColor { editorTheme?.color("editorSuggestWidget.background", default: .controlBackgroundColor) ?? .controlBackgroundColor }
    private var foregroundColor: NSColor { editorTheme?.color("editorSuggestWidget.foreground", default: .labelColor) ?? .labelColor }
    private var selectedBackgroundColor: NSColor { editorTheme?.color("editorSuggestWidget.selectedBackground", default: .selectedContentBackgroundColor) ?? .selectedContentBackgroundColor }
    private var selectedForegroundColor: NSColor {
        editorTheme?.color("editorSuggestWidget.selectedForeground",
            default: editorTheme?.colors["editorSuggestWidget.selectedBackground"] == nil ? .alternateSelectedControlTextColor : foregroundColor)
            ?? .alternateSelectedControlTextColor
    }

    override init() {
        super.init()
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .controlBackgroundColor
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.setAccessibilityIdentifier("sqlCompletionPopup")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.style = .plain
        table.headerView = nil
        table.rowHeight = 38
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .controlBackgroundColor
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(acceptClickedRow)
        table.setAccessibilityLabel("SQL completions")
        table.setAccessibilityIdentifier("sqlCompletionList")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.wantsLayer = true
        scroll.layer?.borderWidth = 1
        scroll.layer?.cornerRadius = 5
        scroll.layer?.masksToBounds = true
        panel.contentView = scroll
    }

    /// Restyle the existing panel without replacing candidates or their selection.
    func applyTheme(_ theme: EditorTheme?, appearance: NSAppearance) {
        editorTheme = theme
        panel.appearance = appearance
        panel.backgroundColor = backgroundColor
        table.backgroundColor = backgroundColor
        scroll.backgroundColor = backgroundColor
        appearance.performAsCurrentDrawingAppearance {
            scroll.layer?.borderColor = (theme?.color("editorSuggestWidget.border", default: .separatorColor) ?? .separatorColor).cgColor
        }
        for row in items.indices {
            if let view = table.rowView(atRow: row, makeIfNecessary: false) as? Row {
                view.selectionColor = selectedBackgroundColor
                view.needsDisplay = true
            }
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? Cell { style(cell, row: row) }
        }
    }

    func show(items: [SQLCompletionItem], for editor: NSTextView, accept: @escaping () -> Void) {
        guard let window = editor.window, window.firstResponder === editor, window.isKeyWindow else { hide(); return }
        self.items = items
        self.accept = accept
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        applyTheme((editor as? SQLTextView)?.editorTheme, appearance: editor.effectiveAppearance)
        reposition(for: editor)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    /// AppKit may scroll the caret into view while resolving its screen rect.
    /// Keep the list and selection through that layout, without re-entering it.
    func reposition(for editor: NSTextView) {
        guard !isPositioning, !items.isEmpty, let window = editor.window else { return }
        isPositioning = true
        defer { isPositioning = false }
        let caret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let width = min(440.0, max(280.0, screen.width - 24))
        let height = CGFloat(min(8, items.count)) * (table.rowHeight + table.intercellSpacing.height) + 2
        let x = min(max(caret.minX, screen.minX + 8), screen.maxX - width - 8)
        let y = caret.minY - height >= screen.minY ? caret.minY - height : min(caret.maxY, screen.maxY - height)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        table.tableColumns.first?.width = width - 2
    }

    func hide() {
        items = []
        accept = nil
        panel.orderOut(nil)
        panel.parent?.removeChildWindow(panel)
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), items.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func acceptClickedRow() { accept?() }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = Row()
        view.selectionColor = selectedBackgroundColor
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        for row in items.indices {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? Cell { style(cell, row: row) }
        }
    }

    private func style(_ cell: Cell, row: Int) {
        let selected = row == table.selectedRow
        let foreground = selected ? selectedForegroundColor : foregroundColor
        cell.textField?.textColor = foreground
        if let title = cell.textField, items.indices.contains(row) {
            let label = items[row].label as NSString
            let attributed = NSMutableAttributedString(string: label as String, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: foreground
            ])
            let highlight = editorTheme?.color(selected ? "editorSuggestWidget.focusHighlightForeground" : "editorSuggestWidget.highlightForeground",
                default: selected ? selectedForegroundColor : foregroundColor)
                ?? (selected ? selectedForegroundColor : .linkColor)
            for range in items[row].matchRanges {
                guard range.location >= 0, range.location <= label.length, range.length > 0,
                      range.length <= label.length - range.location else { continue }
                // A matching base letter also styles its combining marks.
                let composed = label.rangeOfComposedCharacterSequences(for: range)
                attributed.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: highlight
                ], range: composed)
            }
            title.attributedStringValue = attributed
        }
        // Explicit schemes keep detail text readable even when the app and the
        // editor use different appearances.
        cell.detailField?.textColor = editorTheme == nil && !selected ? .secondaryLabelColor
            : (selected ? selectedForegroundColor : foregroundColor)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let cell = Cell()
        let title = NSTextField(labelWithString: item.label)
        title.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = title
        cell.addSubview(title)
        let detail = NSTextField(labelWithString: item.detail ?? "SQL")
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(detail)
        cell.detailField = detail
        style(cell, row: row)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1)
        ])
        cell.setAccessibilityLabel([item.label, item.detail].compactMap { $0 }.joined(separator: ", "))
        return cell
    }
}
