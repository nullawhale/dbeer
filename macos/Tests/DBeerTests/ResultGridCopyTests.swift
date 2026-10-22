import AppKit
import Foundation
import Testing
@testable import DBeer

@MainActor
struct ResultGridCopyTests {
    private func mouse(_ table: NSTableView, row: Int, column: Int, modifiers: NSEvent.ModifierFlags = [],
                       type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        let cell = table.frameOfCell(atColumn: column, row: row)
        let point = table.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
            windowNumber: table.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    private func key(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code))
    }

    private func host(_ scroll: NSScrollView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        return window
    }

    private func payload(_ pasteboard: NSPasteboard) throws -> ResultClipboardPayload {
        let data = try #require(pasteboard.data(forType: ResultTableView.clipboardType))
        return try JSONDecoder().decode(ResultClipboardPayload.self, from: data)
    }

    @Test func shiftMouseRectangleAndCommandCopyPreserveNullEmptyDuplicatesAndTSVQuoting() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.dbeer.tests.grid.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let coordinator = ResultTableView.Coordinator(pasteboard: board)
        let scroll = coordinator.makeScrollView()
        let columns = [ResultColumn(index: 0, name: "x", typeOid: 25), ResultColumn(index: 1, name: "x", typeOid: 25),
            ResultColumn(index: 2, name: "binary", engine: .mysql, nativeType: "BLOB", encoding: "base64")]
        coordinator.update(columns: columns, rows: [[nil, "", "AAEC"], ["\\N", "tabs\tand\n\"quotes\"", nil]], in: scroll)
        let window = host(scroll)
        defer { window.close() }
        let table = try #require(scroll.documentView as? ResultGridTableView)
        let firstCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        try #require(firstCell.textField).mouseDown(with: mouse(table, row: 0, column: 0))
        table.mouseDown(with: try mouse(table, row: 1, column: 1, modifiers: .shift))
        #expect(table.cellSelection?.rowRange == 0...1)
        #expect(table.cellSelection?.columnRange == 0...1)
        #expect(!table.selectedCellRect.isEmpty)
        #expect(table.performKeyEquivalent(with: try key(8, characters: "c", modifiers: .command)))
        let copied = try payload(board)
        #expect(copied.columns.map(\.name) == ["x", "x"])
        #expect(copied.sourceRows == [0, 1] && copied.sourceColumnIndices == [0, 1])
        #expect(copied.values[0][0].kind == .null)
        #expect(copied.values[0][1] == ResultClipboardValue(kind: .text, value: ""))
        #expect(copied.values[1][0] == ResultClipboardValue(kind: .text, value: "\\N"))
        #expect(board.string(forType: .string) == "\\N\t\"\"\n\"\\N\"\t\"tabs\tand\n\"\"quotes\"\"\"")
    }

    @Test func keyboardShiftSelectionAndNativeContextActionsCopyCellRowsAndBinary() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.dbeer.tests.grid.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let coordinator = ResultTableView.Coordinator(pasteboard: board)
        let scroll = coordinator.makeScrollView()
        coordinator.update(columns: [ResultColumn(index: 0, name: "bytes", engine: .mysql, nativeType: "BLOB", encoding: "base64"),
            ResultColumn(index: 1, name: "precise", typeOid: 1700)], rows: [["AAEC", "9007199254740993.123456789"], [nil, "2"]], in: scroll)
        let window = host(scroll)
        defer { window.close() }
        let table = try #require(scroll.documentView as? ResultGridTableView)
        table.mouseDown(with: try mouse(table, row: 0, column: 0))
        table.keyDown(with: try key(124, modifiers: .shift))
        table.keyDown(with: try key(125, modifiers: .shift))
        let menu = try #require(table.menu(for: mouse(table, row: 0, column: 0, type: .rightMouseDown)))
        #expect(menu.items.map(\.title) == ["Copy Cell", "Copy Rows", "Copy Range", "Copy as"])
        menu.performActionForItem(at: 0)
        #expect(try payload(board).values == [[ResultClipboardValue(kind: .binary, value: "AAEC")]])
        menu.performActionForItem(at: 1)
        let copied = try payload(board)
        #expect(copied.sourceRows == [0, 1])
        #expect(copied.values[0][0] == ResultClipboardValue(kind: .binary, value: "AAEC"))
        #expect(copied.values[0][1].value == "9007199254740993.123456789")
        #expect(copied.values[1][0].kind == .null)
        table.keyDown(with: try key(49, characters: " ", modifiers: .shift))
        #expect(table.cellSelection?.columnRange == 0...1)
        #expect(table.cellSelection?.rowRange == 1...1)
    }

    @Test func mouseDragAndSelectAllUseTheSameRangeWhileLegacyPostgresBytesNormalizeToBase64() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.dbeer.tests.grid.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let coordinator = ResultTableView.Coordinator(pasteboard: board)
        let scroll = coordinator.makeScrollView()
        coordinator.update(columns: [ResultColumn(index: 0, name: "bytes", typeOid: 17, nativeType: "bytea"),
            ResultColumn(index: 1, name: "text", typeOid: 25)], rows: [["\\x000102ff", "one"], ["\\x", "two"]], in: scroll)
        let window = host(scroll)
        defer { window.close() }
        let table = try #require(scroll.documentView as? ResultGridTableView)
        table.mouseDown(with: try mouse(table, row: 0, column: 0))
        table.mouseDragged(with: try mouse(table, row: 1, column: 1, type: .leftMouseDragged))
        table.copy(nil)
        let dragged = try payload(board)
        #expect(dragged.values[0][0] == ResultClipboardValue(kind: .binary, value: "AAEC/w=="))
        #expect(dragged.values[1][0] == ResultClipboardValue(kind: .binary, value: ""))
        #expect(dragged.columns[0].encoding == "base64")
        table.keyDown(with: try key(0, characters: "a", modifiers: .command))
        table.copy(nil)
        #expect(try payload(board) == dragged)
        coordinator.update(columns: [], rows: [], in: scroll)
        #expect(table.cellSelection == nil)
    }
}
