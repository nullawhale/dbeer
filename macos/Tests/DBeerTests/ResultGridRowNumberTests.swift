import AppKit
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct ResultGridRowNumberTests {
    private let columns = [ResultColumn(index: 0, name: "id", typeOid: 23),
        ResultColumn(index: 1, name: "value", typeOid: 25)]

    private func host(_ scroll: NSScrollView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        return window
    }

    private func mouse(_ ruler: ResultGridRowNumberRuler, row: Int, modifiers: NSEvent.ModifierFlags = [],
                       type: NSEvent.EventType = .leftMouseDown, clickCount: Int = 1) throws -> NSEvent {
        let rect = ruler.rect(forRow: row)
        let point = ruler.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
            timestamp: 0, windowNumber: ruler.window?.windowNumber ?? 0, context: nil,
            eventNumber: 1, clickCount: clickCount, pressure: 1))
    }

    @Test func gutterSelectsRangesAndSparseRowsWithoutReloadingOrCopyingNumbers() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.dbeer.tests.row-numbers.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let coordinator = ResultTableView.Coordinator(pasteboard: board)
        let scroll = coordinator.makeScrollView()
        let rows = (0..<8).map { [String(100 + $0), "value \($0)"] as [String?] }
        coordinator.update(columns: columns, rows: rows, in: scroll)
        let window = host(scroll)
        defer { window.close() }
        let table = try #require(scroll.documentView as? ResultGridTableView)
        let ruler = try #require(scroll.verticalRulerView as? ResultGridRowNumberRuler)
        let firstView = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        var publications: [IndexSet] = []
        coordinator.onSelectedRows = { selected in
            publications.append(selected)
            coordinator.update(columns: columns, rows: rows, in: scroll)
        }
        var edits = 0
        coordinator.editableColumns = IndexSet([0, 1])
        coordinator.onEditCell = { _ in edits += 1 }
        ruler.mouseDown(with: try mouse(ruler, row: 1, clickCount: 2))
        #expect(table.selectsWholeRows)
        #expect(table.cellSelection?.columnRange == 0...1)
        #expect(table.selectedRowIndexes == IndexSet(integer: 1))
        #expect(window.firstResponder === table)
        #expect(edits == 0)
        ruler.mouseDown(with: try mouse(ruler, row: 4, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet(integersIn: 1...4))
        ruler.mouseDown(with: try mouse(ruler, row: 2, modifiers: .command))
        ruler.mouseDown(with: try mouse(ruler, row: 6, modifiers: .command))
        #expect(table.selectedRowIndexes == IndexSet([1, 3, 4, 6]))
        #expect(publications.count == 4)
        #expect(table.view(atColumn: 0, row: 0, makeIfNecessary: false) === firstView)
        table.copy(nil)
        let data = try #require(board.data(forType: ResultTableView.clipboardType))
        let payload = try JSONDecoder().decode(ResultClipboardPayload.self, from: data)
        #expect(payload.sourceRows == [1, 3, 4, 6])
        #expect(payload.sourceColumnIndices == [0, 1])
        #expect(payload.columns == columns)
        #expect(board.string(forType: .string) == "101\tvalue 1\n103\tvalue 3\n104\tvalue 4\n106\tvalue 6")
    }

    @Test func gutterStaysFixedDuringScrollingAndDragAndKeyboardKeepWholeRows() throws {
        let coordinator = ResultTableView.Coordinator()
        let scroll = coordinator.makeScrollView()
        coordinator.update(columns: columns, rows: (0..<80).map { [String($0), "value"] }, in: scroll)
        let window = host(scroll)
        defer { window.close() }
        let table = try #require(scroll.documentView as? ResultGridTableView)
        let ruler = try #require(scroll.verticalRulerView as? ResultGridRowNumberRuler)
        table.tableColumns[0].width = 500
        table.tableColumns[1].width = 500
        coordinator.update(columns: columns, rows: (0..<80).map { [String($0), "value"] }, in: scroll)
        table.scroll(NSPoint(x: 300, y: table.rect(ofRow: 20).minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.layoutSubtreeIfNeeded()
        let horizontalOffset = table.visibleRect.minX
        #expect(horizontalOffset > 0)
        let fixedFrame = ruler.convert(ruler.bounds, to: nil)
        let rowRect = ruler.rect(forRow: 21)
        let point = ruler.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: scroll)
        #expect(scroll.hitTest(point) === ruler)
        ruler.mouseDown(with: try mouse(ruler, row: 21))
        ruler.mouseDragged(with: try mouse(ruler, row: 24, type: .leftMouseDragged))
        ruler.mouseUp(with: try mouse(ruler, row: 24, type: .leftMouseUp))
        #expect(table.selectedRowIndexes == IndexSet(integersIn: 21...24))
        #expect(table.selectsWholeRows)
        #expect(table.visibleRect.minX == horizontalOffset)
        #expect(ruler.convert(ruler.bounds, to: nil) == fixedFrame)
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
        table.keyDown(with: down)
        #expect(table.selectedRowIndexes == IndexSet(integersIn: 21...25))
        #expect(table.selectsWholeRows)
        #expect(table.cellSelection?.columnRange == 0...1)
        let number = try #require((ruler.accessibilityChildren() as? [NSAccessibilityElement])?
            .first { $0.accessibilityLabel() == "Select row 26" })
        #expect(number.accessibilityLabel() == "Select row 26")
        #expect(number.accessibilityPerformPress())
        #expect(table.selectedRowIndexes == IndexSet(integer: 25))
    }

    @Test func numberingResizesWithLoadedRowsAndRendersInLightAndDark() throws {
        let coordinator = ResultTableView.Coordinator()
        let scroll = coordinator.makeScrollView()
        coordinator.update(columns: columns, rows: [["101", "first"], [nil, ""], ["103", "NULL"]], in: scroll)
        let window = host(scroll)
        defer { window.close() }
        let table = try #require(scroll.documentView as? ResultGridTableView)
        let ruler = try #require(scroll.verticalRulerView as? ResultGridRowNumberRuler)
        let originalWidth = ruler.ruleThickness
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            ruler.mouseDown(with: try mouse(ruler, row: 1))
            scroll.displayIfNeeded()
            let bitmap = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.effectiveAppearance.performAsCurrentDrawingAppearance {
                scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            }
            if let path = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: directory.appendingPathComponent("grid-row-numbers-\(name).png"))
            }
        }
        let numbers = try #require(ruler.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(numbers.map { $0.accessibilityLabel() } == ["Select row 1", "Select row 2", "Select row 3"])
        let width = table.tableColumns[0].width
        coordinator.update(columns: columns, rows: Array(repeating: ["value", nil], count: 10_000), in: scroll)
        #expect(ruler.ruleThickness > originalWidth)
        #expect(table.tableColumns[0].width == width)
        table.scrollRowToVisible(9_999)
        #expect(ruler.accessibilityChildren()?.compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
            .last == "Select row 10000")
        coordinator.update(columns: columns, rows: [], in: scroll)
        #expect(ruler.accessibilityChildren()?.isEmpty == true)
        #expect(table.cellSelection == nil)
        #expect(ruler.ruleThickness == originalWidth)
    }

    @Test func scrolledRowNumbersDoNotDrawOrSelectBehindTheColumnHeader() throws {
        let coordinator = ResultTableView.Coordinator()
        let scroll = coordinator.makeScrollView()
        coordinator.update(columns: columns, rows: (0..<100).map { [String($0), "value"] }, in: scroll)
        let window = host(scroll)
        defer { window.close() }
        let table = try #require(scroll.documentView as? ResultGridTableView)
        let ruler = try #require(scroll.verticalRulerView as? ResultGridRowNumberRuler)
        let header = try #require(table.headerView)
        let headerFrame = ruler.convert(header.bounds, from: header)
        let corner = NSRect(x: ruler.bounds.minX, y: ruler.bounds.minY,
            width: ruler.bounds.width, height: headerFrame.maxY - ruler.bounds.minY)
        func headerPixels() throws -> Data {
            ruler.needsDisplay = true
            ruler.displayIfNeeded()
            let bitmap = try #require(ruler.bitmapImageRepForCachingDisplay(in: corner))
            ruler.effectiveAppearance.performAsCurrentDrawingAppearance {
                ruler.cacheDisplay(in: corner, to: bitmap)
            }
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        table.setRowsExternally(IndexSet(integersIn: 0..<100))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            table.scroll(.zero)
            let baseline = try headerPixels()
            for offset in [17, 26, 75, 520] {
                table.scroll(NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                #expect(try headerPixels() == baseline,
                    "Row numbers and selection must stay out of the header at offset \(offset)")
                let headerScreenFrame = window.convertToScreen(ruler.convert(corner, to: nil))
                let elements = try #require(ruler.accessibilityChildren() as? [NSAccessibilityElement])
                #expect(elements.allSatisfy { $0.accessibilityFrame().maxY <= headerScreenFrame.minY + 0.5 })
            }
        }
        let selection = table.selectedRowIndexes
        let point = ruler.convert(NSPoint(x: corner.midX, y: corner.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        ruler.mouseDown(with: event)
        #expect(table.selectedRowIndexes == selection)
    }
}
