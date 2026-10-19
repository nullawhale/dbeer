import AppKit
import SwiftUI

struct ResultClipboardValue: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case null, text, binary, `default` }
    let kind: Kind
    let value: String?
}

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
final class ResultGridTableView: NSTableView {
    weak var copyCoordinator: ResultTableView.Coordinator?
    private(set) var cellSelection: ResultGridSelection?
    private(set) var contextCell: ResultGridCell?

    func clearCellSelection() {
        cellSelection = nil
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
        guard let first = rows.first, let last = rows.last, numberOfColumns > 0 else { clearCellSelection(); return }
        select(ResultGridCell(row: first, column: 0), extending: false, wholeRow: true)
        if last != first { select(ResultGridCell(row: last, column: numberOfColumns - 1), extending: true, wholeRow: true) }
    }

    private func select(_ cell: ResultGridCell, extending: Bool, wholeRow: Bool = false) {
        guard (0..<numberOfRows).contains(cell.row), (0..<numberOfColumns).contains(cell.column) else { return }
        let anchor = extending ? cellSelection?.anchor ?? cell : cell
        cellSelection = ResultGridSelection(
            anchor: wholeRow ? ResultGridCell(row: anchor.row, column: 0) : anchor,
            focus: wholeRow ? ResultGridCell(row: cell.row, column: numberOfColumns - 1) : cell)
        if let selection = cellSelection {
            selectRowIndexes(IndexSet(integersIn: selection.rowRange), byExtendingSelection: false)
        }
        scrollRowToVisible(cell.row)
        scrollColumnToVisible(cell.column)
        invalidateCellSelection()
    }

    private func invalidateCellSelection() {
        needsDisplay = true
        // A horizontal move leaves the native row selection unchanged. Its
        // row view must still repaint the cell range and clear the old border.
        enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
    }

    private func cell(at event: NSEvent) -> ResultGridCell? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let column = column(at: point)
        guard row >= 0, column >= 0 else { return nil }
        return ResultGridCell(row: row, column: column)
    }

    override func mouseDown(with event: NSEvent) {
        guard let cell = cell(at: event) else { super.mouseDown(with: event); return }
        contextCell = nil
        window?.makeFirstResponder(self)
        select(cell, extending: event.modifierFlags.contains(.shift), wholeRow: event.modifierFlags.contains(.option))
        if event.clickCount == 2 { copyCoordinator?.editCell(cell) }
    }

    override func mouseDragged(with event: NSEvent) {
        _ = autoscroll(with: event)
        guard let cell = cell(at: event) else { return }
        select(cell, extending: true)
    }

    @objc func copy(_ sender: Any?) { copyCoordinator?.copyRange(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            copy(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if [51, 117].contains(event.keyCode), copyCoordinator?.supportsEditing == true {
            copyCoordinator?.deleteSelectedRows()
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
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
        if event.keyCode == 49, event.modifierFlags.contains(.shift) {
            select(focus, extending: false, wholeRow: true)
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
            extending: event.modifierFlags.contains(.shift))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextCell = cell(at: event)
        if let cell = contextCell, !(cellSelection?.rowRange.contains(cell.row) == true &&
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
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if copyCoordinator.supportsEditing {
            menu.addItem(.separator())
            let edit = NSMenuItem(title: "Edit Cell…", action: #selector(ResultTableView.Coordinator.editContextCell(_:)), keyEquivalent: "")
            edit.target = copyCoordinator
            edit.isEnabled = contextCell.map(copyCoordinator.canEditCell) ?? false
            menu.addItem(edit)
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
        let selectionRect = view.convert(selectedCellRect, from: self)
        guard selectionRect.intersects(clipRect) else { return }
        let accent = NSColor(AppPalette.accent)
        accent.withAlphaComponent(0.22).setFill()
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
        super.drawBackground(in: dirtyRect)
        // Native alternating row backgrounds cover the table's background.
        // Paint the selection after that background, beneath the cell labels.
        grid?.drawCellSelection(in: dirtyRect, from: self)
    }
}

struct ResultClipboardPayload: Codable, Equatable, Sendable {
    let version: Int
    let columns: [ResultColumn]
    let sourceRows: [Int]
    let sourceColumnIndices: [Int]
    let values: [[ResultClipboardValue]]
}

struct ResultTableView: NSViewRepresentable {
    static let clipboardType = NSPasteboard.PasteboardType("dev.dbeer.result-selection+json")
    static let nullMarker = "\\N"
    let columns: [ResultColumn]
    let rows: [[String?]]
    var pasteboard: NSPasteboard = .general
    var editableColumns: IndexSet = []
    var modifiedCells: Set<ResultGridCell> = []
    var deletedRows: IndexSet = []
    var valueKinds: [[String]]?
    var selectedRows: IndexSet?
    var onEditCell: ((ResultGridCell) -> Void)?
    var onSelectedRows: ((IndexSet) -> Void)?
    var onDeleteRows: (() -> Void)?

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
        coordinator.modifiedCells = modifiedCells
        coordinator.deletedRows = deletedRows
        coordinator.valueKinds = valueKinds
        coordinator.onEditCell = onEditCell
        coordinator.onSelectedRows = onSelectedRows
        coordinator.onDeleteRows = onDeleteRows
        coordinator.update(columns: columns, rows: rows, in: scrollView)
        if let selectedRows, let table = scrollView.documentView as? ResultGridTableView,
           table.selectedRowIndexes != selectedRows { table.setRowsExternally(selectedRows) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var columns: [ResultColumn] = []
        private var rows: [[String?]] = []
        private var columnOrdinals: [NSUserInterfaceItemIdentifier: Int] = [:]
        private let cellIdentifier = NSUserInterfaceItemIdentifier("result-cell")
        private let pasteboard: NSPasteboard
        private weak var table: ResultGridTableView?
        var editableColumns: IndexSet = []
        var modifiedCells: Set<ResultGridCell> = []
        var deletedRows: IndexSet = []
        var valueKinds: [[String]]?
        var onEditCell: ((ResultGridCell) -> Void)?
        var onSelectedRows: ((IndexSet) -> Void)?
        var onDeleteRows: (() -> Void)?
        private var previousSelection: IndexSet = []
        var supportsEditing: Bool { onEditCell != nil }

        init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

        func makeScrollView() -> NSScrollView {
            let tableView = ResultGridTableView(frame: .zero)
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
            tableView.intercellSpacing = NSSize(width: 8, height: 2)
            tableView.rowHeight = 24
            tableView.setAccessibilityLabel("Query results")

            let scrollView = NSScrollView(frame: .zero)
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.focusRingType = .none
            scrollView.documentView = tableView
            return scrollView
        }

        func update(columns: [ResultColumn], rows: [[String?]], in scrollView: NSScrollView) {
            guard let tableView = scrollView.documentView as? ResultGridTableView else { return }
            let schemaChanged = self.columns != columns
            self.columns = columns
            self.rows = rows

            if schemaChanged {
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
                    tableColumn.width = max(140, min(320, tableColumn.headerCell.cellSize.width + 24))
                    tableColumn.resizingMask = .userResizingMask
                    tableView.addTableColumn(tableColumn)
                    columnOrdinals[identifier] = ordinal
                }
            }

            tableView.reloadData()
            tableView.clampCellSelection()
            // Keep the document at its natural width so wide results scroll horizontally.
            tableView.frame.size.width = max(scrollView.contentSize.width,
                tableView.tableColumns.reduce(0) { $0 + $1.width + tableView.intercellSpacing.width })
        }

        @objc func copyCell(_ sender: Any?) {
            guard let point = table?.contextCell ?? table?.cellSelection?.focus else { return }
            copy(rowIndices: [point.row], columnIndices: [point.column])
        }

        func canEditCell(_ cell: ResultGridCell) -> Bool {
            editableColumns.contains(cell.column) && !deletedRows.contains(cell.row) && rows.indices.contains(cell.row)
        }

        func editCell(_ cell: ResultGridCell) { if canEditCell(cell) { onEditCell?(cell) } }
        @objc func editContextCell(_ sender: Any?) {
            if let cell = table?.contextCell ?? table?.cellSelection?.focus { editCell(cell) }
        }
        func deleteSelectedRows() { onDeleteRows?() }
        @objc func deleteContextRows(_ sender: Any?) { deleteSelectedRows() }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, previousSelection != table.selectedRowIndexes else { return }
            previousSelection = table.selectedRowIndexes
            onSelectedRows?(previousSelection)
        }

        @objc func copyRows(_ sender: Any?) {
            guard let table else { return }
            copy(rowIndices: Array(table.selectedRowIndexes), columnIndices: Array(columns.indices))
        }

        @objc func copyRange(_ sender: Any?) {
            guard let selection = table?.cellSelection else { copyRows(sender); return }
            copy(rowIndices: Array(selection.rowRange), columnIndices: Array(selection.columnRange))
        }

        private func copy(rowIndices: [Int], columnIndices: [Int]) {
            guard !rowIndices.isEmpty, !columnIndices.isEmpty,
                  rowIndices.allSatisfy(rows.indices.contains), columnIndices.allSatisfy(columns.indices.contains),
                  rowIndices.allSatisfy({ row in columnIndices.allSatisfy(rows[row].indices.contains) }) else { return }
            let selectedColumns = columnIndices.map { ordinal in
                let column = columns[ordinal]
                guard column.engine == .postgresql, column.typeOid == 17, column.encoding == nil else { return column }
                return ResultColumn(index: column.index, name: column.name, typeOid: column.typeOid,
                    engine: column.engine, nativeType: column.nativeType, encoding: "base64")
            }
            let values = rowIndices.map { row in
                columnIndices.map { column -> ResultClipboardValue in
                    if let valueKinds, valueKinds.indices.contains(row), valueKinds[row].indices.contains(column), valueKinds[row][column] == "default" {
                        return ResultClipboardValue(kind: .default, value: nil)
                    }
                    guard let value = rows[row][column] else { return ResultClipboardValue(kind: .null, value: nil) }
                    let metadata = columns[column]
                    if metadata.encoding == "base64" { return ResultClipboardValue(kind: .binary, value: value) }
                    if metadata.engine == .postgresql, metadata.typeOid == 17, let binary = Self.postgresBinary(value) {
                        return ResultClipboardValue(kind: .binary, value: binary)
                    }
                    return ResultClipboardValue(kind: .text, value: value)
                }
            }
            let payload = ResultClipboardPayload(version: 1, columns: selectedColumns, sourceRows: rowIndices,
                sourceColumnIndices: columnIndices, values: values)
            guard let encoded = try? JSONEncoder().encode(payload) else { return }
            let tsv = values.map { row in row.map(Self.tsv).joined(separator: "\t") }.joined(separator: "\n")
            pasteboard.clearContents()
            pasteboard.declareTypes([.string, ResultTableView.clipboardType], owner: nil)
            pasteboard.setData(encoded, forType: ResultTableView.clipboardType)
            pasteboard.setString(tsv, forType: .string)
        }

        private static func tsv(_ value: ResultClipboardValue) -> String {
            if value.kind == .default { return "<DEFAULT>" }
            guard value.kind != .null, let string = value.value else { return ResultTableView.nullMarker }
            if string.isEmpty || string == ResultTableView.nullMarker || string.contains("\t") || string.contains("\n") ||
                string.contains("\r") || string.contains("\"") {
                return "\"" + string.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return string
        }

        private static func postgresBinary(_ value: String) -> String? {
            guard value.hasPrefix("\\x") else { return nil }
            let hex = Array(value.dropFirst(2).utf8)
            guard hex.count.isMultiple(of: 2) else { return nil }
            var bytes = Data()
            for index in stride(from: 0, to: hex.count, by: 2) {
                guard let byte = UInt8(String(decoding: hex[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
                bytes.append(byte)
            }
            return bytes.base64EncodedString()
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
            let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            field.stringValue = value ?? "NULL"
            field.font = value == nil ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
            field.textColor = value == nil ? .secondaryLabelColor : .labelColor
            cell.wantsLayer = true
            let modified = modifiedCells.contains(ResultGridCell(row: row, column: ordinal))
            cell.layer?.backgroundColor = modified ? NSColor.systemOrange.withAlphaComponent(0.15).cgColor : nil
            if deletedRows.contains(row) {
                field.attributedStringValue = NSAttributedString(string: field.stringValue,
                    attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue])
            }
            let accessibleValue = value.map { $0.isEmpty ? "Empty string" : $0 } ?? "SQL NULL"
            field.toolTip = accessibleValue
            cell.toolTip = accessibleValue
            field.setAccessibilityLabel("\(columns[ordinal].name), row \(row + 1)")
            field.resultAccessibilityValue = accessibleValue
            return cell
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
