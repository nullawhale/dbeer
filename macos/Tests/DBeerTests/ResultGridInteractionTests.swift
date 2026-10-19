import AppKit
import Observation
import SwiftUI
import Testing
@testable import DBeer

@MainActor
struct ResultGridInteractionTests {
    private let columns = [ResultColumn(index: 0, name: "id", typeOid: 23),
        ResultColumn(index: 1, name: "value", typeOid: 25)]

    private func mouse(_ table: NSTableView, row: Int, column: Int = 0,
                       modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) throws -> NSEvent {
        let rect = table.frameOfCell(atColumn: column, row: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        return try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: modifiers,
            timestamp: 0, windowNumber: table.window?.windowNumber ?? 0, context: nil, eventNumber: 1,
            clickCount: clickCount, pressure: 1))
    }

    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code))
    }

    private func host(_ view: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    @Test func selectionFeedbackDoesNotReloadCellsOrRepublishExternalSparseRows() throws {
        let coordinator = ResultTableView.Coordinator()
        let scroll = coordinator.makeScrollView()
        let rows = (0..<12).map { [String($0), "row \($0)"] as [String?] }
        coordinator.update(columns: columns, rows: rows, in: scroll)
        let window = host(scroll)
        defer { window.close() }
        let table = try #require(scroll.documentView as? ResultGridTableView)
        let firstView = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        var publications: [IndexSet] = []
        coordinator.onSelectedRows = { selected in
            publications.append(selected)
            // A bounded feedback callback catches the old deselection/reload
            // recursion without letting a regression hang the native runner.
            if publications.count < 20 { coordinator.update(columns: columns, rows: rows, in: scroll) }
        }
        table.mouseDown(with: try mouse(table, row: 0))
        table.mouseDown(with: try mouse(table, row: 5, modifiers: .shift))
        #expect(publications == [IndexSet(integer: 0), IndexSet(integersIn: 0...5)])
        #expect(table.selectedRowIndexes == IndexSet(integersIn: 0...5))
        #expect(table.view(atColumn: 0, row: 0, makeIfNecessary: false) === firstView)
        table.keyDown(with: try key(125, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet(integersIn: 0...6))
        #expect(publications.count == 3)
        let sparse = IndexSet([1, 4, 8])
        table.setRowsExternally(sparse)
        #expect(table.selectedRowIndexes == sparse)
        #expect(publications.count == 3)
        table.mouseDown(with: try mouse(table, row: 4, modifiers: .command))
        #expect(table.selectedRowIndexes == IndexSet([1, 8]))
        #expect(publications.last == IndexSet([1, 8]))
        #expect(table.cellSelection?.focus.row == 8)
        coordinator.editableColumns = IndexSet([0, 1])
        var editedCell: ResultGridCell?
        coordinator.onEditCell = { editedCell = $0 }
        table.keyDown(with: try key(36))
        #expect(editedCell?.row == 8)
    }

    @Observable final class SelectionModel {
        var rows = (0..<30).map { [String($0), "row \($0)"] as [String?] }
        var selection: IndexSet = []
        var notifications = 0
    }

    private struct SelectionHost: View {
        let model: SelectionModel
        var body: some View {
            ResultTableView(columns: [ResultColumn(index: 0, name: "id", typeOid: 23),
                ResultColumn(index: 1, name: "value", typeOid: 25)], rows: model.rows,
                selectedRows: model.selection, dataIdentity: model,
                onSelectedRows: { model.selection = $0; model.notifications += 1 })
        }
    }

    @Test func hostedSwiftUISelectionSurvivesMouseAndKeyboardUpdates() async throws {
        let model = SelectionModel()
        let hostView = NSHostingView(rootView: SelectionHost(model: model))
        let window = host(hostView)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(30))
        let table = try #require(descendants(hostView, of: ResultGridTableView.self).first)
        table.mouseDown(with: try mouse(table, row: 2))
        try await Task.sleep(for: .milliseconds(30))
        table.mouseDown(with: try mouse(table, row: 9, modifiers: .shift))
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.selection == IndexSet(integersIn: 2...9))
        for _ in 0..<8 {
            table.keyDown(with: try key(125, modifiers: .shift))
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.selection == IndexSet(integersIn: 2...17))
        #expect(table.selectedRowIndexes == model.selection)
        #expect(model.notifications == 10)
        model.selection = IndexSet([1, 5, 12])
        try await Task.sleep(for: .milliseconds(30))
        #expect(table.selectedRowIndexes == IndexSet([1, 5, 12]))
        #expect(model.notifications == 10)
    }

    @Test func inlineEditingPreservesUntouchedModesStagesExactTextAndCancels() throws {
        let coordinator = ResultTableView.Coordinator()
        let scroll = coordinator.makeScrollView()
        coordinator.editableColumns = IndexSet(integer: 1)
        coordinator.valueKinds = [["text", "null"], ["text", "default"], ["text", "text"]]
        coordinator.update(columns: columns, rows: [["1", nil], ["2", nil], ["3", "9007199254740993.123456789"]], in: scroll)
        let window = host(scroll)
        defer { window.close() }
        let table = try #require(scroll.documentView as? ResultGridTableView)
        var commits: [(ResultGridCell, String)] = []
        var dirtySignals: [Bool] = []
        coordinator.onCommitCell = { commits.append(($0, $1)) }
        coordinator.onInlineDraftChanged = { dirtySignals.append($0) }
        for row in 0...1 {
            table.mouseDown(with: try mouse(table, row: row, column: 1, clickCount: 2))
            let field = try #require(descendants(table, of: NSTextField.self)
                .first { $0.identifier?.rawValue == "inlineGridCellEditor" })
            #expect(field.placeholderString == (row == 0 ? "NULL" : "DEFAULT"))
            coordinator.finishInlineEdit()
        }
        #expect(commits.isEmpty)
        #expect(dirtySignals.isEmpty)
        coordinator.beginInlineEdit(ResultGridCell(row: 2, column: 1))
        let field = try #require(descendants(table, of: NSTextField.self)
            .first { $0.identifier?.rawValue == "inlineGridCellEditor" })
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.string == "9007199254740993.123456789")
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("NULL", replacementRange: editor.selectedRange())
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(commits.count == 1)
        #expect(commits[0].0 == ResultGridCell(row: 2, column: 1))
        #expect(commits[0].1 == "NULL")
        #expect(dirtySignals == [true, false])
        coordinator.beginInlineEdit(ResultGridCell(row: 1, column: 1))
        let emptyField = try #require(descendants(table, of: NSTextField.self)
            .first { $0.identifier?.rawValue == "inlineGridCellEditor" })
        let emptyEditor = try #require(emptyField.currentEditor() as? NSTextView)
        emptyEditor.insertText("x", replacementRange: emptyEditor.selectedRange())
        emptyEditor.setSelectedRange(NSRange(location: 0, length: 1))
        emptyEditor.insertText("", replacementRange: emptyEditor.selectedRange())
        coordinator.finishInlineEdit()
        #expect(commits.count == 2)
        #expect(commits[1].0 == ResultGridCell(row: 1, column: 1))
        #expect(commits[1].1.isEmpty)
        coordinator.beginInlineEdit(ResultGridCell(row: 0, column: 1))
        let cancelField = try #require(descendants(table, of: NSTextField.self)
            .first { $0.identifier?.rawValue == "inlineGridCellEditor" })
        let cancelEditor = try #require(cancelField.currentEditor() as? NSTextView)
        cancelEditor.insertText("discard me", replacementRange: cancelEditor.selectedRange())
        #expect(coordinator.control(cancelField, textView: cancelEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(commits.count == 2)
        #expect(dirtySignals == [true, false, true, false, true, false])
    }

    @Test func contextValueActionsKeepNullDefaultEmptyAndLiteralNullDistinct() throws {
        let coordinator = ResultTableView.Coordinator()
        let scroll = coordinator.makeScrollView()
        coordinator.editableColumns = IndexSet([0, 1])
        coordinator.canSetNullColumns = IndexSet(integer: 1)
        coordinator.canSetDefaultColumns = IndexSet([0, 1])
        coordinator.canSetEmptyColumns = IndexSet(integer: 1)
        coordinator.update(columns: columns, rows: [["1", "NULL"]], in: scroll)
        let window = host(scroll)
        defer { window.close() }
        let table = try #require(scroll.documentView as? ResultGridTableView)
        var staged: [ChangeValue] = []
        coordinator.onSetCellValue = { _, value in staged.append(value) }
        table.mouseDown(with: try mouse(table, row: 0, column: 1))
        coordinator.setContextNull(nil)
        coordinator.setContextDefault(nil)
        coordinator.setContextEmpty(nil)
        #expect(staged == [ChangeValue(kind: "null", value: nil), ChangeValue(kind: "default", value: nil),
            ChangeValue(kind: "text", value: "")])
        table.mouseDown(with: try mouse(table, row: 0, column: 0))
        coordinator.setContextNull(nil)
        coordinator.setContextEmpty(nil)
        #expect(staged.count == 3)
        coordinator.deletedRows = IndexSet(integer: 0)
        coordinator.setContextDefault(nil)
        #expect(staged.count == 3)
    }

    @Test func reopeningCurrentInlineCellReadsTheJustStagedValue() throws {
        let coordinator = ResultTableView.Coordinator()
        let scroll = coordinator.makeScrollView()
        coordinator.editableColumns = IndexSet(integer: 1)
        coordinator.update(columns: columns, rows: [["1", "old"]], in: scroll)
        let window = host(scroll)
        defer { window.close() }
        let table = try #require(scroll.documentView as? ResultGridTableView)
        var commits = 0
        coordinator.onCommitCell = { _, value in
            commits += 1
            coordinator.update(columns: columns, rows: [["1", value]], in: scroll)
        }
        let cell = ResultGridCell(row: 0, column: 1)
        coordinator.beginInlineEdit(cell)
        let first = try #require(descendants(table, of: NSTextField.self)
            .first { $0.identifier?.rawValue == "inlineGridCellEditor" })
        let editor = try #require(first.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("new", replacementRange: editor.selectedRange())
        coordinator.beginInlineEdit(cell)
        let reopened = try #require(descendants(table, of: NSTextField.self)
            .first { $0.identifier?.rawValue == "inlineGridCellEditor" })
        #expect(reopened.stringValue == "new")
        #expect(commits == 1)
        coordinator.finishInlineEdit(cancel: true)
    }

    @Test func headerSortDelegatesToDatabaseWithoutReorderingLoadedRows() throws {
        let coordinator = ResultTableView.Coordinator()
        let scroll = coordinator.makeScrollView()
        var requestedColumns: [Int] = []
        coordinator.onSortColumn = { requestedColumns.append($0) }
        coordinator.sortColumn = "id"
        coordinator.sortAscending = false
        coordinator.update(columns: columns, rows: [["2", "b"], ["10", "a"]], in: scroll)
        let table = try #require(scroll.documentView as? ResultGridTableView)
        #expect(table.sortDescriptors.first?.ascending == false)
        #expect(table.sortDescriptors.first?.key == table.tableColumns[0].identifier.rawValue)
        #expect(requestedColumns.isEmpty)
        coordinator.tableView(table, didClick: table.tableColumns[1])
        #expect(requestedColumns == [1])
        let first = try #require(coordinator.tableView(table, viewFor: table.tableColumns[0], row: 0) as? NSTableCellView)
        #expect(first.textField?.stringValue == "2")
        coordinator.onSortColumn = nil
        coordinator.update(columns: columns, rows: [["2", "b"], ["10", "a"]], in: scroll)
        #expect(table.tableColumns.allSatisfy { $0.sortDescriptorPrototype == nil })
    }
}
