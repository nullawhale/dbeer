import AppKit
import SwiftUI

struct ResultGridCell: Hashable {
    let row: Int
    let column: Int
}

struct ResultGridSelection: Equatable {
    let anchor: ResultGridCell
    let focus: ResultGridCell
    var rowRange: ClosedRange<Int> { min(anchor.row, focus.row)...max(anchor.row, focus.row) }
    var columnRange: ClosedRange<Int> { min(anchor.column, focus.column)...max(anchor.column, focus.column) }
}

@MainActor
final class ResultGridTableView: NSTableView, AppGridCopyCommandResponder {
    var appCommandFocus: AppCommandFocus { .grid }
    var appCommandDocumentID: UUID?
    weak var copyCoordinator: ResultTableView.Coordinator?
    var commandHandler: ((NSEvent) -> Bool)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { WorkspacePaneContainerView.activatePane(containing: self) }
        return accepted
    }

    func canPerformGridCopy(_ command: AppCommandID) -> Bool {
        guard let format = command.resultCopyFormat else { return false }
        return copyCoordinator?.canCopy(format: format) == true
    }

    func captureGridCopy(_ command: AppCommandID) -> (@MainActor () async -> Void)? {
        guard let format = command.resultCopyFormat else { return nil }
        return copyCoordinator?.captureCopy(format: format)
    }
    private(set) var cellSelection: ResultGridSelection?
    private(set) var contextCell: ResultGridCell?
    private(set) var selectsWholeRows = false
    private var nativeBackground: NSColor?
    var fillsDocumentColumn = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationPaletteChanged),
            name: .applicationPaletteDidChange, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    /// Changing application colors never reloads result data or its selection.
    func applyApplicationPalette() {
        if nativeBackground == nil { nativeBackground = backgroundColor }
        let background = AppPalette.isCustom ? AppPalette.nsColor(.panel) : (nativeBackground ?? .controlBackgroundColor)
        if backgroundColor != background { backgroundColor = background }
        let grid = AppPalette.isCustom ? AppPalette.nsColor(.border) : NSColor.separatorColor
        if gridColor != grid { gridColor = grid }
        let alternating = !AppPalette.isCustom
        if usesAlternatingRowBackgroundColors != alternating { usesAlternatingRowBackgroundColors = alternating }
        copyCoordinator?.refreshVisibleTextColors(in: self)
    }

    @objc private func applicationPaletteChanged() {
        applyApplicationPalette()
        headerView?.needsDisplay = true
        invalidateCellSelection()
    }

    func clearCellSelection() {
        cellSelection = nil
        selectsWholeRows = false
        contextCell = nil
        deselectAll(nil)
        invalidateCellSelection()
    }

    func clampCellSelection() {
        guard let selection = cellSelection else { return }
        if selection.rowRange.upperBound >= numberOfRows || selection.columnRange.upperBound >= numberOfColumns {
            clearCellSelection()
        }
        invalidateCellSelection()
    }

    func setRowsExternally(_ rows: IndexSet) {
        // External model updates must not publish selection back to SwiftUI.
        if let copyCoordinator { copyCoordinator.synchronizeSelection { setWholeRowSelection(rows) } }
        else { setWholeRowSelection(rows) }
    }

    func selectPartitionRows(_ rows: IndexSet) {
        guard !rows.isEmpty, numberOfColumns > 0 else { return }
        copyCoordinator?.finishInlineEdit()
        window?.makeFirstResponder(self)
        // Publish the sparse group once, without scrolling to its first/last row.
        setWholeRowSelection(rows)
    }

    private func setWholeRowSelection(_ rows: IndexSet) {
        let validRows = rows.intersection(IndexSet(integersIn: 0..<numberOfRows))
        contextCell = nil
        selectsWholeRows = true
        if let first = validRows.first, let last = validRows.last, numberOfColumns > 0 {
            cellSelection = ResultGridSelection(anchor: ResultGridCell(row: first, column: 0),
                focus: ResultGridCell(row: last, column: numberOfColumns - 1))
        } else { cellSelection = nil }
        selectRowIndexes(validRows, byExtendingSelection: false)
        invalidateCellSelection()
    }

    private func select(_ cell: ResultGridCell, extending: Bool, wholeRow: Bool = false) {
        guard (0..<numberOfRows).contains(cell.row), (0..<numberOfColumns).contains(cell.column) else { return }
        let anchor = extending ? cellSelection?.anchor ?? cell : cell
        selectsWholeRows = wholeRow
        cellSelection = ResultGridSelection(
            anchor: wholeRow ? ResultGridCell(row: anchor.row, column: 0) : anchor,
            focus: wholeRow ? ResultGridCell(row: cell.row, column: numberOfColumns - 1) : cell)
        if let selection = cellSelection {
            selectRowIndexes(IndexSet(integersIn: selection.rowRange), byExtendingSelection: false)
        }
        scrollRowToVisible(cell.row)
        if !wholeRow { scrollColumnToVisible(cell.column) }
        invalidateCellSelection()
    }

    fileprivate func selectCellForEditing(_ cell: ResultGridCell) {
        select(cell, extending: false)
    }

    private func invalidateCellSelection() {
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
        // A horizontal move leaves the native row selection unchanged. Its
        // row view must still repaint the cell range and clear the old border.
        enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
        copyCoordinator?.refreshVisibleTextColors(in: self)
        copyCoordinator?.publishInspection()
    }

    private func cell(at event: NSEvent) -> ResultGridCell? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let column = column(at: point)
        guard row >= 0, column >= 0 else { return nil }
        return ResultGridCell(row: row, column: column)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if visibleRect.contains(local), let editor = copyCoordinator?.hitTestInlineEditor(at: local) { return editor }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        if fillsDocumentColumn, let column = tableColumns.first, let clip = enclosingScrollView?.contentView {
            let width = max(column.minWidth, clip.bounds.width - intercellSpacing.width)
            if abs(column.width - width) > 0.5 { column.width = width }
        }
        copyCoordinator?.layoutInlineEditor()
        copyCoordinator?.synchronizeHeaderScroll()
    }

    override func mouseDown(with event: NSEvent) {
        guard let cell = cell(at: event) else { super.mouseDown(with: event); return }
        contextCell = nil
        copyCoordinator?.finishInlineEdit()
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.command) {
            toggleRowSelection(cell.row)
        } else {
            select(cell, extending: event.modifierFlags.contains(.shift), wholeRow: event.modifierFlags.contains(.option))
        }
        if event.clickCount == 2 { copyCoordinator?.activateCell(cell) }
    }

    func selectRowNumber(_ row: Int, modifiers: NSEvent.ModifierFlags = [], extending: Bool = false) {
        guard (0..<numberOfRows).contains(row), numberOfColumns > 0 else { return }
        contextCell = nil
        if !extending {
            copyCoordinator?.finishInlineEdit()
            window?.makeFirstResponder(self)
        }
        if !extending, modifiers.contains(.command) { toggleRowSelection(row) }
        else {
            select(ResultGridCell(row: row, column: 0),
                extending: extending || modifiers.contains(.shift), wholeRow: true)
        }
    }

    private func toggleRowSelection(_ row: Int) {
        var rows = selectedRowIndexes
        if rows.contains(row) { rows.remove(row) } else { rows.insert(row) }
        let focusRow = rows.contains(row) ? row : (rows.last ?? row)
        cellSelection = rows.isEmpty ? nil : ResultGridSelection(
            anchor: ResultGridCell(row: rows.first ?? row, column: 0),
            focus: ResultGridCell(row: focusRow, column: numberOfColumns - 1))
        selectsWholeRows = true
        selectRowIndexes(rows, byExtendingSelection: false)
        invalidateCellSelection()
    }

    override func mouseDragged(with event: NSEvent) {
        _ = autoscroll(with: event)
        guard let cell = cell(at: event) else { return }
        select(cell, extending: true)
    }

    @objc func copy(_ sender: Any?) { copyCoordinator?.copyRange(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        WorkspacePaneContainerView.activatePane(containing: self)
        if commandHandler?(event) == true { return true }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            copy(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        WorkspacePaneContainerView.activatePane(containing: self)
        if commandHandler?(event) == true { return }
        if [51, 117].contains(event.keyCode), copyCoordinator?.supportsEditing == true {
            copyCoordinator?.deleteSelectedRows()
            return
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            copy(nil)
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a",
           numberOfRows > 0, numberOfColumns > 0 {
            select(ResultGridCell(row: 0, column: 0), extending: false)
            select(ResultGridCell(row: numberOfRows - 1, column: numberOfColumns - 1), extending: true)
            return
        }
        let focus = cellSelection?.focus ?? ResultGridCell(row: max(0, selectedRow), column: 0)
        if [36, 76].contains(event.keyCode) {
            if event.modifierFlags.contains(.shift) { copyCoordinator?.editCell(focus) }
            else { copyCoordinator?.activateCell(focus) }
            return
        }
        if event.keyCode == 49, event.modifierFlags.contains(.shift) {
            select(focus, extending: false, wholeRow: true)
            return
        }
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let toggle = copyCoordinator?.onToggleRowDetails {
            toggle()
            return
        }
        var row = focus.row
        var column = focus.column
        switch event.keyCode {
        case 123: column -= 1
        case 124: column += 1
        case 125: row += 1
        case 126: row -= 1
        default: super.keyDown(with: event); return
        }
        guard numberOfRows > 0, numberOfColumns > 0 else { return }
        select(ResultGridCell(row: min(max(0, row), numberOfRows - 1), column: min(max(0, column), numberOfColumns - 1)),
            extending: event.modifierFlags.contains(.shift), wholeRow: selectsWholeRows && [125, 126].contains(event.keyCode))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextCell = cell(at: event)
        if let cell = contextCell, !(selectedRowIndexes.contains(cell.row) &&
                                      cellSelection?.columnRange.contains(cell.column) == true) {
            select(cell, extending: false)
        }
        guard let copyCoordinator else { return nil }
        let menu = NSMenu(title: "Copy Results")
        menu.autoenablesItems = false
        for (title, action, enabled) in [
            ("Copy Cell", #selector(ResultTableView.Coordinator.copyCell(_:)), cellSelection != nil),
            ("Copy Rows", #selector(ResultTableView.Coordinator.copyRows(_:)), !selectedRowIndexes.isEmpty),
            ("Copy Range", #selector(ResultTableView.Coordinator.copyRange(_:)), cellSelection != nil)
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = copyCoordinator
            item.isEnabled = enabled && copyCoordinator.isCopyAllowed
            menu.addItem(item)
        }
        let formats = NSMenu(title: "Copy as")
        formats.autoenablesItems = false
        for format in ResultCopyFormat.allCases {
            let item = NSMenuItem(title: format.title,
                action: #selector(ResultTableView.Coordinator.copyAs(_:)), keyEquivalent: "")
            item.target = copyCoordinator
            item.representedObject = format.rawValue
            item.isEnabled = copyCoordinator.canCopy(format: format)
            formats.addItem(item)
        }
        let copyAs = NSMenuItem(title: "Copy as", action: nil, keyEquivalent: "")
        copyAs.submenu = formats
        menu.addItem(copyAs)
        if copyCoordinator.onShowRowDetails != nil {
            menu.addItem(.separator())
            let details = NSMenuItem(title: "Row Details", action: #selector(ResultTableView.Coordinator.showContextRowDetails(_:)), keyEquivalent: "")
            details.target = copyCoordinator
            details.isEnabled = contextCell != nil
            menu.addItem(details)
        }
        if copyCoordinator.supportsEditing {
            menu.addItem(.separator())
            let edit = NSMenuItem(title: "Edit Cell…", action: #selector(ResultTableView.Coordinator.editContextCell(_:)), keyEquivalent: "")
            edit.target = copyCoordinator
            edit.isEnabled = contextCell.map(copyCoordinator.canEditCell) ?? false
            menu.addItem(edit)
            if copyCoordinator.onSetCellValue != nil {
                for (title, action, allowed) in [
                    ("Set NULL", #selector(ResultTableView.Coordinator.setContextNull(_:)), copyCoordinator.canSetNullColumns),
                    ("Set DEFAULT", #selector(ResultTableView.Coordinator.setContextDefault(_:)), copyCoordinator.canSetDefaultColumns),
                    ("Set Empty String", #selector(ResultTableView.Coordinator.setContextEmpty(_:)), copyCoordinator.canSetEmptyColumns),
                ] {
                    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                    item.target = copyCoordinator
                    item.isEnabled = contextCell.map { copyCoordinator.canEditCell($0) && allowed.contains($0.column) } ?? false
                    menu.addItem(item)
                }
            }
            let delete = NSMenuItem(title: "Delete Selected Rows", action: #selector(ResultTableView.Coordinator.deleteContextRows(_:)), keyEquivalent: "")
            delete.target = copyCoordinator
            delete.isEnabled = !selectedRowIndexes.isEmpty
            menu.addItem(delete)
        }
        return menu
    }

    // AppKit's table implementation adds a blue context-menu outline even
    // with focus rings disabled. The cell selection already marks our target.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {}
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {}

    var selectedCellRect: NSRect {
        guard let selection = cellSelection else { return .zero }
        return frameOfCell(atColumn: selection.columnRange.lowerBound, row: selection.rowRange.lowerBound)
            .union(frameOfCell(atColumn: selection.columnRange.upperBound, row: selection.rowRange.upperBound))
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        drawCellSelection(in: clipRect, from: self)
    }

    fileprivate func drawCellSelection(in clipRect: NSRect, from view: NSView) {
        guard cellSelection != nil else { return }
        if selectsWholeRows {
            let visibleRows = rows(in: convert(clipRect, from: view))
            guard visibleRows.location != NSNotFound else { return }
            let clippedRows = IndexSet(integersIn: visibleRows.location..<(visibleRows.location + visibleRows.length))
            for row in selectedRowIndexes.intersection(clippedRows) {
                let rowRect = frameOfCell(atColumn: 0, row: row)
                    .union(frameOfCell(atColumn: numberOfColumns - 1, row: row))
                drawSelectionRect(rowRect, in: clipRect, from: view)
            }
        } else { drawSelectionRect(selectedCellRect, in: clipRect, from: view) }
    }

    private func drawSelectionRect(_ rect: NSRect, in clipRect: NSRect, from view: NSView) {
        let selectionRect = view.convert(rect, from: self)
        guard selectionRect.intersects(clipRect) else { return }
        let accent = AppPalette.nsColor(.accent)
        let fill = AppPalette.isCustom ? AppPalette.nsColor(.selection) : accent.withAlphaComponent(0.22)
        fill.setFill()
        selectionRect.intersection(clipRect).fill()
        accent.setStroke()
        let border = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }
}

private final class ResultGridRowView: NSTableRowView {
    weak var grid: ResultGridTableView?

    override func drawBackground(in dirtyRect: NSRect) {
        if AppPalette.isCustom {
            AppPalette.nsColor(.panel).setFill()
            dirtyRect.fill()
        } else {
            super.drawBackground(in: dirtyRect)
        }
        // Native alternating row backgrounds cover the table's background.
        // Paint the selection after that background, beneath the cell labels.
        grid?.drawCellSelection(in: dirtyRect, from: self)
    }
}

private final class ResultGridHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        guard AppPalette.isCustom, let tableView else { super.draw(dirtyRect); return }
        AppPalette.nsColor(.control).setFill()
        dirtyRect.fill()
        for (index, column) in tableView.tableColumns.enumerated() {
            let rect = headerRect(ofColumn: index)
            guard rect.intersects(dirtyRect) else { continue }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: AppPalette.nsColor(.secondaryText),
                .paragraphStyle: paragraph,
            ]
            let title = column.title as NSString
            let height = title.size(withAttributes: attributes).height
            let sorted = !tableView.sortDescriptors.isEmpty && tableView.sortDescriptors.first?.key == column.identifier.rawValue
            title.draw(in: NSRect(x: rect.minX + 6, y: rect.midY - height / 2,
                width: max(0, rect.width - (sorted ? 28 : 12)), height: height), withAttributes: attributes)
            if sorted {
                let ascending = tableView.sortDescriptors.first?.ascending == true
                let indicator = (ascending ? "▴" : "▾") as NSString
                indicator.draw(in: NSRect(x: rect.maxX - 18, y: rect.midY - height / 2,
                    width: 12, height: height), withAttributes: attributes)
            }
            AppPalette.nsColor(.border).setFill()
            NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        }
        AppPalette.nsColor(.border).setFill()
        NSRect(x: dirtyRect.minX, y: bounds.maxY - 1, width: dirtyRect.width, height: 1).fill()
    }
}

/// A zero-sized SwiftUI scroll view can initially place its first column
/// behind the row ruler. Wait for AppKit to finish the first inset layout, then
/// reveal that column using its native scrolling rules. Later scrolling and
/// pane resizing retain the user's chosen horizontal position.
@MainActor
private final class ResultGridScrollView: NSScrollView {
    private var needsInitialHorizontalOrigin = true
    private var initialOriginScheduled = false

    override func tile() {
        super.tile()
        guard needsInitialHorizontalOrigin, !initialOriginScheduled,
              window != nil, contentView.bounds.width > 0,
              let table = documentView as? ResultGridTableView, table.numberOfColumns > 0 else { return }
        initialOriginScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.initialOriginScheduled = false }
            guard self.needsInitialHorizontalOrigin, self.window != nil,
                  self.contentView.bounds.width > 0,
                  let table = self.documentView as? ResultGridTableView, table.numberOfColumns > 0 else { return }
            self.layoutSubtreeIfNeeded()
            self.needsInitialHorizontalOrigin = false
            // Rulers can be represented by adjusted insets rather than a clip
            // frame offset. A literal bounds.x = 0 still hides leading data.
            table.scrollColumnToVisible(0)
            self.reflectScrolledClipView(self.contentView)
            table.copyCoordinator?.synchronizeHeaderScroll()
        }
    }
}

struct ResultTableView: NSViewRepresentable {
    static let clipboardType = NSPasteboard.PasteboardType("dev.dbeer.result-selection.json")
    static let nullMarker = ResultCopy.nullMarker
    let columns: [ResultColumn]
    let rows: [[String?]]
    var pasteboard: NSPasteboard = .general
    var copySettings: ResultCopySettings = .shared
    var editableColumns: IndexSet = []
    var canSetNullColumns: IndexSet = []
    var canSetDefaultColumns: IndexSet = []
    var canSetEmptyColumns: IndexSet = []
    var modifiedCells: Set<ResultGridCell> = []
    var deletedRows: IndexSet = []
    var valueKinds: [[String]]?
    var selectedRows: IndexSet?
    var dataIdentity: AnyObject?
    var partitionMarkers: [GridPartitionMarker?]?
    var onEditCell: ((ResultGridCell) -> Void)?
    var onCommitCell: ((ResultGridCell, String) -> Void)?
    var onInlineDraftChanged: ((Bool) -> Void)?
    var onSetCellValue: ((ResultGridCell, ChangeValue) -> Void)?
    var onSelectedRows: ((IndexSet) -> Void)?
    var onInspectValue: ((InspectedValue?) -> Void)?
    var onDeleteRows: (() -> Void)?
    var onShowRowDetails: (() -> Void)?
    var onToggleRowDetails: (() -> Void)?
    var sortColumn: String?
    var sortAscending = true
    var onSortColumn: ((Int) -> Void)?
    var onCoordinatorReady: ((Coordinator) -> Void)?
    var onSQLInsertCopy: ((ResultClipboardPayload, NSPasteboard) -> Void)?
    var onCopyError: ((String) -> Void)?
    var copyAllowed = true
    var copyAvailability: (@MainActor () -> Bool)?
    var commandHandler: ((NSEvent) -> Bool)?
    var documentID: UUID?

    func makeCoordinator() -> Coordinator { Coordinator(pasteboard: pasteboard) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = context.coordinator.makeScrollView()
        update(scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        update(scrollView, coordinator: context.coordinator)
    }

    private func update(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.editableColumns = editableColumns
        coordinator.canSetNullColumns = canSetNullColumns
        coordinator.canSetDefaultColumns = canSetDefaultColumns
        coordinator.canSetEmptyColumns = canSetEmptyColumns
        coordinator.modifiedCells = modifiedCells
        coordinator.deletedRows = deletedRows
        coordinator.valueKinds = valueKinds
        coordinator.partitionMarkers = partitionMarkers
        coordinator.onEditCell = onEditCell
        coordinator.onCommitCell = onCommitCell
        coordinator.onInlineDraftChanged = onInlineDraftChanged
        coordinator.onSetCellValue = onSetCellValue
        coordinator.onSelectedRows = onSelectedRows
        coordinator.onInspectValue = onInspectValue
        coordinator.onDeleteRows = onDeleteRows
        coordinator.onShowRowDetails = onShowRowDetails
        coordinator.onToggleRowDetails = onToggleRowDetails
        coordinator.onSortColumn = onSortColumn
        coordinator.sortColumn = sortColumn
        coordinator.sortAscending = sortAscending
        coordinator.copySettings = copySettings
        coordinator.onSQLInsertCopy = onSQLInsertCopy
        coordinator.onCopyError = onCopyError
        coordinator.copyAllowed = copyAllowed
        coordinator.copyAvailability = copyAvailability
        coordinator.update(columns: columns, rows: rows, dataIdentity: dataIdentity, in: scrollView)
        (scrollView.documentView as? ResultGridTableView)?.appCommandDocumentID = documentID
        (scrollView.documentView as? ResultGridTableView)?.commandHandler = commandHandler
        if let selectedRows, let table = scrollView.documentView as? ResultGridTableView,
           table.selectedRowIndexes != selectedRows { table.setRowsExternally(selectedRows) }
        onCoordinatorReady?(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        private var columns: [ResultColumn] = []
        private var rows: [[String?]] = []
        private var columnOrdinals: [NSUserInterfaceItemIdentifier: Int] = [:]
        private let cellIdentifier = NSUserInterfaceItemIdentifier("result-cell")
        private let pasteboard: NSPasteboard
        var copySettings: ResultCopySettings = .shared
        var onSQLInsertCopy: ((ResultClipboardPayload, NSPasteboard) -> Void)?
        var onCopyError: ((String) -> Void)?
        var copyAllowed = true
        var copyAvailability: (@MainActor () -> Bool)?
        var isCopyAllowed: Bool { copyAllowed && (copyAvailability?() ?? true) }
        private weak var table: ResultGridTableView?
        var editableColumns: IndexSet = []
        var canSetNullColumns: IndexSet = []
        var canSetDefaultColumns: IndexSet = []
        var canSetEmptyColumns: IndexSet = []
        var modifiedCells: Set<ResultGridCell> = []
        var deletedRows: IndexSet = []
        var valueKinds: [[String]]?
        var partitionMarkers: [GridPartitionMarker?]?
        var onEditCell: ((ResultGridCell) -> Void)?
        var onCommitCell: ((ResultGridCell, String) -> Void)?
        var onInlineDraftChanged: ((Bool) -> Void)?
        var onSetCellValue: ((ResultGridCell, ChangeValue) -> Void)?
        var onSelectedRows: ((IndexSet) -> Void)?
        var onInspectValue: ((InspectedValue?) -> Void)?
        private var inspectionRevision: UInt64 = 0
        var onDeleteRows: (() -> Void)?
        var onShowRowDetails: (() -> Void)?
        var onToggleRowDetails: (() -> Void)?
        var sortColumn: String?
        var sortAscending = true
        var onSortColumn: ((Int) -> Void)?
        private var previousSelection: IndexSet = []
        private var isSynchronizingSelection = false
        private var previousDataIdentity: AnyObject?
        private var renderedModifiedCells: Set<ResultGridCell> = []
        private var renderedDeletedRows: IndexSet = []
        private var renderedValueKinds: [[String]]?
        private var inlineEditor: NSTextField?
        private var inlineViewportSize: NSSize?
        private var editingCell: ResultGridCell?
        private var originalInlineValue = ""
        private var originalInlineIsSpecial = false
        private var inlineTextChanged = false
        private var inlineDraftIsDirty = false
        var supportsEditing: Bool { onEditCell != nil || onCommitCell != nil }

        init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

        func makeScrollView() -> NSScrollView {
            let tableView = ResultGridTableView(frame: .zero)
            tableView.style = .plain
            tableView.focusRingType = .none
            tableView.copyCoordinator = self
            table = tableView
            tableView.dataSource = self
            tableView.delegate = self
            tableView.columnAutoresizingStyle = .noColumnAutoresizing
            tableView.allowsColumnResizing = true
            tableView.allowsColumnReordering = false
            tableView.allowsMultipleSelection = true
            tableView.selectionHighlightStyle = .none
            tableView.usesAlternatingRowBackgroundColors = true
            tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
            tableView.gridColor = .separatorColor
            tableView.headerView = ResultGridHeaderView(frame: tableView.headerView?.frame ??
                NSRect(x: 0, y: 0, width: 0, height: 23))
            tableView.intercellSpacing = NSSize(width: 8, height: 2)
            tableView.rowHeight = 24
            tableView.setAccessibilityLabel("Query results")

            let scrollView = ResultGridScrollView(frame: .zero)
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.focusRingType = .none
            scrollView.documentView = tableView
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            scrollView.hasVerticalRuler = true
            scrollView.verticalRulerView = ResultGridRowNumberRuler(scrollView: scrollView, table: tableView)
            scrollView.rulersVisible = true
            tableView.applyApplicationPalette()
            return scrollView
        }

        func update(columns: [ResultColumn], rows: [[String?]], dataIdentity: AnyObject? = nil, in scrollView: NSScrollView) {
            guard let tableView = scrollView.documentView as? ResultGridTableView else { return }
            let schemaChanged = self.columns != columns
            let rowsChanged = dataIdentity.map { previousDataIdentity !== $0 } ?? (self.rows != rows)
            let presentationChanged = renderedModifiedCells != modifiedCells || renderedDeletedRows != deletedRows ||
                (dataIdentity == nil && renderedValueKinds != valueKinds)
            self.columns = columns
            tableView.fillsDocumentColumn = columns.count == 1 && columns[0].engine == .mongodb && columns[0].nativeType == "BSON document"
            tableView.autoresizingMask = tableView.fillsDocumentColumn ? [.width] : []
            self.rows = rows
            previousDataIdentity = dataIdentity
            renderedModifiedCells = modifiedCells
            renderedDeletedRows = deletedRows
            renderedValueKinds = valueKinds

            synchronizeSelection {
                if schemaChanged {
                    finishInlineEdit(cancel: true)
                    tableView.clearCellSelection()
                    for column in tableView.tableColumns { tableView.removeTableColumn(column) }
                    columnOrdinals = [:]
                    for (ordinal, column) in columns.enumerated() {
                        // Names can repeat in SQL results; ordinal identifiers keep every column distinct.
                        let identifier = NSUserInterfaceItemIdentifier("result-column-\(ordinal)")
                        let tableColumn = NSTableColumn(identifier: identifier)
                        tableColumn.title = column.name
                        var typeDescription = column.engine.displayName
                        if !column.nativeType.isEmpty { typeDescription += " \(column.nativeType)" }
                        if column.engine == .postgresql, column.typeOid != 0 { typeDescription += " (OID \(column.typeOid))" }
                        if column.encoding == "base64" { typeDescription += " · binary as Base64" }
                        tableColumn.headerToolTip = "\(column.name) — \(typeDescription)"
                        tableColumn.isEditable = false
                        tableColumn.minWidth = 70
                        tableColumn.maxWidth = 2_000
                        tableColumn.width = tableView.fillsDocumentColumn ? max(140, scrollView.contentSize.width - tableView.intercellSpacing.width) :
                            max(140, min(320, tableColumn.headerCell.cellSize.width + 24))
                        tableColumn.resizingMask = .userResizingMask
                        tableView.addTableColumn(tableColumn)
                        columnOrdinals[identifier] = ordinal
                    }
                }

                if schemaChanged || rowsChanged {
                    finishInlineEdit(cancel: true)
                    let selectedRows = tableView.selectedRowIndexes
                    tableView.reloadData()
                    if !schemaChanged {
                        tableView.selectRowIndexes(selectedRows.intersection(IndexSet(integersIn: 0..<rows.count)),
                            byExtendingSelection: false)
                    }
                } else if presentationChanged {
                    refreshVisibleCells(in: tableView)
                }
                tableView.applyApplicationPalette()
                tableView.clampCellSelection()
            }
            updateSortIndicators(in: tableView)
            if let ruler = scrollView.verticalRulerView as? ResultGridRowNumberRuler {
                ruler.partitionMarkers = partitionMarkers
                ruler.updateRowCount()
            }
            // Keep the document at its natural width so wide results scroll horizontally.
            tableView.frame.size.width = max(scrollView.contentSize.width,
                tableView.tableColumns.reduce(0) { $0 + $1.width + tableView.intercellSpacing.width })
        }

        func synchronizeSelection(_ changes: () -> Void) {
            let wasSynchronizing = isSynchronizingSelection
            isSynchronizingSelection = true
            defer {
                previousSelection = table?.selectedRowIndexes ?? []
                isSynchronizingSelection = wasSynchronizing
                if !wasSynchronizing { publishInspection() }
            }
            changes()
        }

        private func updateSortIndicators(in table: NSTableView) {
            var descriptors: [NSSortDescriptor] = []
            for (index, column) in table.tableColumns.enumerated() {
                column.sortDescriptorPrototype = onSortColumn == nil ? nil :
                    NSSortDescriptor(key: column.identifier.rawValue, ascending: true)
                if columns[index].name == sortColumn {
                    descriptors = [NSSortDescriptor(key: column.identifier.rawValue, ascending: sortAscending)]
                }
            }
            // Descriptors only drive native header indicators. Rows are always
            // sorted by the database through the parent callback.
            if table.sortDescriptors != descriptors { table.sortDescriptors = descriptors }
            table.headerView?.needsDisplay = true
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            // Header clicks are handled below; model updates do not start queries.
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let index = columnOrdinals[tableColumn.identifier] else { return }
            finishInlineEdit()
            onSortColumn?(index)
        }

        @objc func copyCell(_ sender: Any?) {
            guard let point = table?.contextCell ?? table?.cellSelection?.focus else { return }
            copy(rowIndices: [point.row], columnIndices: [point.column])
        }

        func canEditCell(_ cell: ResultGridCell) -> Bool {
            editableColumns.contains(cell.column) && !deletedRows.contains(cell.row) && rows.indices.contains(cell.row) &&
                columns.indices.contains(cell.column) && rows[cell.row].indices.contains(cell.column)
        }

        func editCell(_ cell: ResultGridCell) { if canEditCell(cell) { onEditCell?(cell) } }

        func activateCell(_ cell: ResultGridCell) {
            showRowDetails(for: cell)
            beginInlineEdit(cell)
        }

        private func showRowDetails(for cell: ResultGridCell) {
            guard let onShowRowDetails, let table, rows.indices.contains(cell.row),
                  columns.indices.contains(cell.column) else { return }
            finishInlineEdit()
            table.selectCellForEditing(cell)
            onShowRowDetails()
        }

        @objc func showContextRowDetails(_ sender: Any?) {
            if let cell = table?.contextCell ?? table?.cellSelection?.focus { showRowDetails(for: cell) }
        }

        func beginInlineEdit(_ cell: ResultGridCell) {
            finishInlineEdit()
            guard canEditCell(cell) else { return }
            let value = rows[cell.row][cell.column]
            let column = columns[cell.column]
            guard onCommitCell != nil, column.encoding != "base64", column.typeOid != 17,
                  !(value?.contains("\n") ?? false), (value?.count ?? 0) <= 512,
                  let table, let window = table.window else { editCell(cell); return }
            table.scrollRowToVisible(cell.row)
            table.scrollColumnToVisible(cell.column)
            let field = NSTextField(frame: table.frameOfCell(atColumn: cell.column, row: cell.row).insetBy(dx: 1, dy: 0))
            field.identifier = NSUserInterfaceItemIdentifier("inlineGridCellEditor")
            field.setAccessibilityIdentifier("inlineGridCellEditor")
            field.setAccessibilityLabel("Edit \(column.name), row \(cell.row + 1)")
            field.isEditable = true
            field.isSelectable = true
            field.usesSingleLineMode = true
            field.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            field.focusRingType = .none
            field.isBezeled = true
            field.bezelStyle = .squareBezel
            field.backgroundColor = AppPalette.isCustom ? AppPalette.nsColor(.control) : .textBackgroundColor
            field.textColor = AppPalette.isCustom ? AppPalette.nsColor(.text) : .textColor
            field.stringValue = value ?? ""
            field.placeholderString = isDefault(cell) ? "DEFAULT" : (value == nil ? "NULL" : nil)
            originalInlineValue = field.stringValue
            originalInlineIsSpecial = value == nil || isDefault(cell)
            inlineTextChanged = false
            editingCell = cell
            inlineEditor = field
            inlineViewportSize = nil
            table.addSubview(field)
            if window.makeFirstResponder(field) { field.currentEditor()?.selectAll(nil) }
            field.delegate = self
            layoutInlineEditor()
            refreshInlineEditorColors()
        }

        fileprivate func hitTestInlineEditor(at point: NSPoint) -> NSView? {
            guard let field = inlineEditor, field.frame.contains(point) else { return nil }
            // NSTableView normally returns itself for cell hits, including an
            // overlay editor. Let AppKit place the caret inside the editor.
            return field.hitTest(point)
        }

        @objc private func viewportChanged() {
            layoutInlineEditor()
            synchronizeHeaderScroll()
        }

        fileprivate func synchronizeHeaderScroll() {
            guard let table, let header = table.headerView,
                  let clip = header.superview as? NSClipView, let scroll = table.enclosingScrollView else { return }
            // Ruler insets can leave the native header clip at its old offset
            // after scrolling a cell into view. Align their actual view origins.
            let offset = header.convert(.zero, to: scroll).x - table.convert(.zero, to: scroll).x
            if abs(offset) > 0.5 {
                clip.scroll(to: NSPoint(x: clip.bounds.minX + offset, y: clip.bounds.minY))
            }
        }

        fileprivate func layoutInlineEditor() {
            guard let field = inlineEditor, let cell = editingCell, let table else { return }
            if inlineViewportSize != table.visibleRect.size {
                // Opening row details changes the viewport after the editor
                // starts. Keep its column visible without resetting selection.
                inlineViewportSize = table.visibleRect.size
                let naturalWidth = table.tableColumns.reduce(0) { $0 + $1.width + table.intercellSpacing.width }
                if table.frame.width < naturalWidth { table.frame.size.width = naturalWidth }
                table.scrollRowToVisible(cell.row)
                table.scrollColumnToVisible(cell.column)
                // Column scrolling can leave the trailing edge clipped after
                // the ruler and inspector resize the viewport. Reveal the cell.
                table.scrollToVisible(table.frameOfCell(atColumn: cell.column, row: cell.row))
                if let scroll = table.enclosingScrollView {
                    let target = table.frameOfCell(atColumn: cell.column, row: cell.row)
                    let visible = table.visibleRect
                    let delta: CGFloat
                    if target.width <= visible.width, target.maxX > visible.maxX {
                        delta = target.maxX - visible.maxX
                    } else if target.minX < visible.minX {
                        delta = target.minX - visible.minX
                    } else { delta = 0 }
                    if delta != 0 {
                        let clip = scroll.contentView
                        clip.scroll(to: NSPoint(x: clip.bounds.minX + delta, y: clip.bounds.minY))
                        scroll.reflectScrolledClipView(clip)
                    }
                }
            }
            let frame = table.frameOfCell(atColumn: cell.column, row: cell.row).insetBy(dx: 1, dy: 0)
            if field.frame != frame { field.frame = frame }
        }

        func finishInlineEdit(cancel: Bool = false, restoreFocus: Bool = true) {
            guard let field = inlineEditor, let cell = editingCell else { return }
            let value = field.currentEditor()?.string ?? field.stringValue
            let changed = inlineValueChanged(value)
            // Clear state before changing first responder or publishing a draft
            // edit: both operations can synchronously re-enter this coordinator.
            inlineEditor = nil
            inlineViewportSize = nil
            editingCell = nil
            setInlineDraftChanged(false)
            field.delegate = nil
            if restoreFocus { field.window?.makeFirstResponder(table) }
            field.removeFromSuperview()
            if !cancel, changed, canEditCell(cell) { onCommitCell?(cell, value) }
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField, field === inlineEditor {
                inlineTextChanged = true
                setInlineDraftChanged(inlineValueChanged(field.currentEditor()?.string ?? field.stringValue))
            }
        }

        private func inlineValueChanged(_ value: String) -> Bool {
            value != originalInlineValue || (originalInlineIsSpecial && inlineTextChanged)
        }

        private func setInlineDraftChanged(_ changed: Bool) {
            guard inlineDraftIsDirty != changed else { return }
            inlineDraftIsDirty = changed
            onInlineDraftChanged?(changed)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if notification.object as? NSTextField === inlineEditor { finishInlineEdit(restoreFocus: false) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard control === inlineEditor else { return false }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finishInlineEdit(cancel: true)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finishInlineEdit()
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) || commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                let cell = editingCell
                let backwards = commandSelector == #selector(NSResponder.insertBacktab(_:))
                finishInlineEdit()
                if let cell, let table, !columns.isEmpty {
                    let step = backwards ? -1 : 1
                    var ordinal = cell.row * columns.count + cell.column + step
                    while ordinal >= 0, ordinal < rows.count * columns.count {
                        let next = ResultGridCell(row: ordinal / columns.count, column: ordinal % columns.count)
                        if canEditCell(next) {
                            table.selectCellForEditing(next)
                            beginInlineEdit(next)
                            break
                        }
                        ordinal += step
                    }
                }
                return true
            }
            return false
        }

        private func isDefault(_ cell: ResultGridCell) -> Bool {
            guard let valueKinds, valueKinds.indices.contains(cell.row), valueKinds[cell.row].indices.contains(cell.column) else { return false }
            return valueKinds[cell.row][cell.column] == "default"
        }
        @objc func editContextCell(_ sender: Any?) {
            if let cell = table?.contextCell ?? table?.cellSelection?.focus { editCell(cell) }
        }
        @objc func setContextNull(_ sender: Any?) {
            setContextValue(ChangeValue(kind: "null", value: nil), allowed: canSetNullColumns)
        }
        @objc func setContextDefault(_ sender: Any?) {
            setContextValue(ChangeValue(kind: "default", value: nil), allowed: canSetDefaultColumns)
        }
        @objc func setContextEmpty(_ sender: Any?) {
            setContextValue(ChangeValue(kind: "text", value: ""), allowed: canSetEmptyColumns)
        }
        private func setContextValue(_ value: ChangeValue, allowed: IndexSet) {
            guard let cell = table?.contextCell ?? table?.cellSelection?.focus,
                  canEditCell(cell), allowed.contains(cell.column) else { return }
            finishInlineEdit(cancel: true)
            onSetCellValue?(cell, value)
        }
        func deleteSelectedRows() { onDeleteRows?() }
        @objc func deleteContextRows(_ sender: Any?) { deleteSelectedRows() }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSynchronizingSelection, let table, previousSelection != table.selectedRowIndexes else { return }
            previousSelection = table.selectedRowIndexes
            onSelectedRows?(previousSelection)
            publishInspection()
        }

        func publishInspection() {
            guard !isSynchronizingSelection, onInspectValue != nil else { return }
            inspectionRevision &+= 1
            let revision = inspectionRevision
            // Representable updates may replace rows or clamp selection. Deliver
            // only the final snapshot after SwiftUI has finished that update.
            Task { @MainActor [weak self] in
                guard let self, self.inspectionRevision == revision, let table = self.table else { return }
                let cell = table.cellSelection?.focus
                self.onInspectValue?(InspectedValue.capture(
                    cell: cell.flatMap { table.selectedRowIndexes.contains($0.row) ? $0 : nil },
                    columns: self.columns, rows: self.rows, valueKinds: self.valueKinds))
            }
        }

        @objc func copyRows(_ sender: Any?) {
            guard let table else { return }
            copy(rowIndices: Array(table.selectedRowIndexes), columnIndices: Array(columns.indices))
        }

        @objc func copyRange(_ sender: Any?) {
            guard let selection = table?.cellSelection else { copyRows(sender); return }
            copy(rowIndices: table?.selectsWholeRows == true ? Array(table?.selectedRowIndexes ?? []) : Array(selection.rowRange),
                columnIndices: Array(selection.columnRange))
        }

        private func copy(rowIndices: [Int], columnIndices: [Int]) {
            guard isCopyAllowed else { return }
            var options = copySettings.options
            // Inspection grids do not own a target chooser. Their ordinary
            // Copy remains available when INSERT is the default for data grids.
            if options.format == .sqlInsert, onSQLInsertCopy == nil { options.format = .tsv }
            if options.format == .sqlInsert {
                guard let action = captureCopy(format: .sqlInsert, rowIndices: rowIndices,
                    columnIndices: columnIndices) else { return }
                Task { await action() }
                return
            }
            let publisher = ResultCopyPublication.shared
            let ticket = publisher.capture(changeCount: pasteboard.changeCount)
            do {
                let payload = try ResultCopy.selection(columns: columns, rows: rows, valueKinds: valueKinds,
                    rowIndices: rowIndices, columnIndices: columnIndices)
                let prepared = try PreparedResultCopy(payload: payload, format: options.format,
                    includesHeaders: options.includesHeaders)
                if !publisher.publish(prepared, to: pasteboard, ticket: ticket) {
                    onCopyError?("The selection could not be copied. Try copying again.")
                }
            } catch { onCopyError?(error.localizedDescription) }
        }

        @objc func copyAs(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let format = ResultCopyFormat(rawValue: raw), let action = captureCopy(format: format) else { return }
            Task { await action() }
        }

        func canCopy(format: ResultCopyFormat) -> Bool {
            guard isCopyAllowed, let table, !columns.isEmpty, !rows.isEmpty,
                  format != .sqlInsert || onSQLInsertCopy != nil else { return false }
            return table.cellSelection != nil || !table.selectedRowIndexes.isEmpty
        }

        func captureCopy(format: ResultCopyFormat) -> (@MainActor () async -> Void)? {
            guard canCopy(format: format), let table else { return nil }
            if let selection = table.cellSelection {
                return captureCopy(format: format,
                    rowIndices: table.selectsWholeRows ? Array(table.selectedRowIndexes) : Array(selection.rowRange),
                    columnIndices: Array(selection.columnRange))
            }
            return captureCopy(format: format, rowIndices: Array(table.selectedRowIndexes),
                columnIndices: Array(columns.indices))
        }

        private func captureCopy(format: ResultCopyFormat, rowIndices: [Int],
                                 columnIndices: [Int]) -> (@MainActor () async -> Void)? {
            guard isCopyAllowed else { return nil }
            let payload: ResultClipboardPayload
            do {
                payload = try ResultCopy.selection(columns: columns, rows: rows, valueKinds: valueKinds,
                    rowIndices: rowIndices, columnIndices: columnIndices)
            } catch {
                onCopyError?(error.localizedDescription)
                return nil
            }
            let board = pasteboard
            let reportError = onCopyError
            let options = copySettings.options
            let publisher = ResultCopyPublication.shared
            let ticket = publisher.capture(changeCount: board.changeCount)
            let availability = copyAvailability
            if format == .sqlInsert {
                guard let onSQLInsertCopy else { return nil }
                return {
                    guard availability?() != false, publisher.isCurrent(ticket) else { return }
                    onSQLInsertCopy(payload, board)
                }
            }
            return {
                guard availability?() != false else { return }
                do {
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try PreparedResultCopy(payload: payload, format: format, includesHeaders: options.includesHeaders)
                    }.value
                    guard availability?() != false, publisher.isCurrent(ticket) else { return }
                    if !publisher.publish(prepared, to: board, ticket: ticket) {
                        reportError?("The clipboard changed while preparing this selection. Copy again.")
                    }
                } catch {
                    guard availability?() != false, publisher.isCurrent(ticket) else { return }
                    reportError?(error.localizedDescription)
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = ResultGridRowView()
            rowView.grid = tableView as? ResultGridTableView
            return rowView
        }

        func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
            false
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let ordinal = columnOrdinals[tableColumn.identifier],
                  rows.indices.contains(row), rows[row].indices.contains(ordinal) else { return nil }

            let cell = (tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView)
                ?? makeCell()
            guard let field = cell.textField as? ResultTextField else { return cell }
            let value = rows[row][ordinal]
            let defaultValue = isDefault(ResultGridCell(row: row, column: ordinal))
            let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            field.stringValue = defaultValue ? "DEFAULT" : (value ?? "NULL")
            field.font = value == nil || defaultValue ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
            field.textColor = textColor(for: ResultGridCell(row: row, column: ordinal), in: tableView as? ResultGridTableView)
            cell.wantsLayer = true
            let modified = modifiedCells.contains(ResultGridCell(row: row, column: ordinal))
            cell.layer?.backgroundColor = modified ? NSColor.systemOrange.withAlphaComponent(0.15).cgColor : nil
            if deletedRows.contains(row) {
                field.attributedStringValue = NSAttributedString(string: field.stringValue,
                    attributes: [.font: font,
                        .foregroundColor: textColor(for: ResultGridCell(row: row, column: ordinal), in: tableView as? ResultGridTableView),
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue])
            }
            let accessibleValue = defaultValue ? "SQL DEFAULT" : (value.map { $0.isEmpty ? "Empty string" : $0 } ?? "SQL NULL")
            field.toolTip = accessibleValue
            cell.toolTip = accessibleValue
            field.setAccessibilityLabel("\(columns[ordinal].name), row \(row + 1)")
            field.resultAccessibilityValue = accessibleValue
            return cell
        }

        fileprivate func refreshVisibleTextColors(in table: ResultGridTableView) {
            table.enumerateAvailableRowViews { _, row in
                for column in self.columns.indices {
                    guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView,
                          let field = cell.textField else { continue }
                    let color = self.textColor(for: ResultGridCell(row: row, column: column), in: table)
                    if field.textColor != color { field.textColor = color }
                }
            }
            refreshInlineEditorColors()
        }

        private func refreshInlineEditorColors() {
            guard let field = inlineEditor else { return }
            let foreground = AppPalette.isCustom ? AppPalette.nsColor(.text) : NSColor.textColor
            let background = AppPalette.isCustom ? AppPalette.nsColor(.control) : NSColor.textBackgroundColor
            field.textColor = foreground
            field.backgroundColor = background
            if let editor = field.currentEditor() as? NSTextView {
                editor.textColor = foreground
                editor.backgroundColor = background
                editor.insertionPointColor = AppPalette.isCustom ? AppPalette.nsColor(.accent) : .controlAccentColor
                editor.selectedTextAttributes = [
                    .foregroundColor: AppPalette.isCustom ? AppPalette.nsColor(.selectionText) : NSColor.selectedTextColor,
                    .backgroundColor: AppPalette.isCustom ? AppPalette.nsColor(.selection) : NSColor.selectedTextBackgroundColor,
                ]
            }
        }

        private func refreshVisibleCells(in table: ResultGridTableView) {
            let rows = table.rows(in: table.visibleRect)
            guard rows.location != NSNotFound, rows.length > 0, !columns.isEmpty else { return }
            table.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<(rows.location + rows.length)),
                columnIndexes: IndexSet(integersIn: columns.indices))
        }

        private func textColor(for cell: ResultGridCell, in table: ResultGridTableView?) -> NSColor {
            let secondary = deletedRows.contains(cell.row) ||
                (rows.indices.contains(cell.row) && rows[cell.row].indices.contains(cell.column) && rows[cell.row][cell.column] == nil)
            guard AppPalette.isCustom else { return secondary ? .secondaryLabelColor : .labelColor }
            if let selection = table?.cellSelection, table?.selectedRowIndexes.contains(cell.row) == true,
               selection.columnRange.contains(cell.column) {
                return AppPalette.nsColor(.selectionText)
            }
            return AppPalette.nsColor(secondary ? .secondaryText : .text)
        }

        private func makeCell() -> NSTableCellView {
            let cell = NSTableCellView(frame: .zero)
            cell.identifier = cellIdentifier
            let field = ResultTextField(labelWithString: "")
            field.isEditable = false
            field.isSelectable = true
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private final class ResultTextField: NSTextField {
            var resultAccessibilityValue = ""

            // NSTextField derives this getter from stringValue and ignores an assigned AX value.
            // Supply the SQL meaning so VoiceOver distinguishes NULL, empty, and literal "NULL".
            override func accessibilityValue() -> String? { resultAccessibilityValue }

            private var grid: ResultGridTableView? {
                var view = superview
                while let current = view {
                    if let grid = current as? ResultGridTableView { return grid }
                    view = current.superview
                }
                return nil
            }

            override func mouseDown(with event: NSEvent) { grid?.mouseDown(with: event) }
            override func mouseDragged(with event: NSEvent) { grid?.mouseDragged(with: event) }
            override func menu(for event: NSEvent) -> NSMenu? { grid?.menu(for: event) }
        }
    }
}
