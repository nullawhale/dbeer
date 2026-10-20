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
                       type: NSEvent.EventType = .leftMouseDown, clickCount: Int = 1, partition: Bool = false) throws -> NSEvent {
        let rect = ruler.rect(forRow: row)
        let point = ruler.convert(NSPoint(x: partition ? rect.maxX - 44 : 20, y: rect.midY), to: nil)
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

    @Test func partitionGutterStaysOutsideCopiedDataAndSelectionDoesNotReloadCells() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.dbeer.tests.partition-gutter.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let coordinator = ResultTableView.Coordinator(pasteboard: board)
        let scroll = coordinator.makeScrollView()
        let rows: [[String?]] = [["1", "first"], ["2", "second"], ["3", "third"]]
        let one = GridPartitionMarker(number: 1, keyDescription: "tenant = one")
        let two = GridPartitionMarker(number: 2, keyDescription: "tenant = two")
        coordinator.partitionMarkers = [one, two, one]
        coordinator.update(columns: columns, rows: rows, in: scroll)
        let window = host(scroll)
        defer { window.close() }
        let table = try #require(scroll.documentView as? ResultGridTableView)
        let ruler = try #require(scroll.verticalRulerView as? ResultGridRowNumberRuler)
        let first = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let width = ruler.ruleThickness
        #expect(width >= 120 && table.numberOfColumns == 2)
        ruler.mouseDown(with: try mouse(ruler, row: 0))
        ruler.mouseDown(with: try mouse(ruler, row: 2, modifiers: .command))
        coordinator.update(columns: columns, rows: rows, in: scroll)
        #expect(table.view(atColumn: 0, row: 0, makeIfNecessary: false) === first)
        #expect(table.selectedRowIndexes == IndexSet([0, 2]))
        table.copy(nil)
        #expect(board.string(forType: .string) == "1\tfirst\n3\tthird")
        let payload = try JSONDecoder().decode(ResultClipboardPayload.self, from: #require(board.data(forType: ResultTableView.clipboardType)))
        #expect(payload.columns == columns && payload.sourceColumnIndices == [0, 1])
        let children = try #require(ruler.accessibilityChildren() as? [NSAccessibilityElement])
        let marker = try #require(children.first { $0.accessibilityIdentifier() == "gridPartitionMarker-0" })
        #expect(marker.accessibilityValue() as? String == "P1")
        #expect(marker.accessibilityHelp()?.contains("tenant = one") == true)
        ruler.mouseMoved(with: try mouse(ruler, row: 0, type: .mouseMoved, partition: true))
        #expect(ruler.toolTip?.contains("tenant = one") == true)
        let fixedFrame = ruler.convert(ruler.bounds, to: nil)
        table.tableColumns.forEach { $0.width = 500 }
        coordinator.update(columns: columns, rows: rows, in: scroll)
        table.scroll(NSPoint(x: 200, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.layoutSubtreeIfNeeded()
        #expect(table.visibleRect.minX > 0 && ruler.convert(ruler.bounds, to: nil) == fixedFrame)
        #expect(ruler.partitionMarker(forRow: 2) == one)
        coordinator.partitionMarkers = nil
        coordinator.update(columns: columns, rows: rows, in: scroll)
        #expect(ruler.ruleThickness < width)
    }

    @Test func partitionClickSelectsSparseLoadedGroupWithoutScrollingOrReloading() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.dbeer.tests.partition-selection.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let coordinator = ResultTableView.Coordinator(pasteboard: board)
        let scroll = coordinator.makeScrollView()
        let rows = (0..<80).map { [String($0), "value \($0)"] as [String?] }
        let one = GridPartitionMarker(number: 1, keyDescription: "tenant = one")
        let two = GridPartitionMarker(number: 2, keyDescription: "tenant = two")
        coordinator.partitionMarkers = rows.indices.map { $0 == 22 ? nil : ($0.isMultiple(of: 3) ? one : two) }
        coordinator.update(columns: columns, rows: rows, in: scroll)
        let window = host(scroll)
        defer { window.close() }
        let table = try #require(scroll.documentView as? ResultGridTableView)
        let ruler = try #require(scroll.verticalRulerView as? ResultGridRowNumberRuler)
        table.tableColumns.forEach { $0.width = 500 }
        coordinator.update(columns: columns, rows: rows, in: scroll)
        table.scroll(NSPoint(x: 300, y: table.rect(ofRow: 20).minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.layoutSubtreeIfNeeded()
        let visibleRect = table.visibleRect
        let firstView = try #require(table.view(atColumn: 0, row: 21, makeIfNecessary: true))
        var publications: [IndexSet] = []
        coordinator.onSelectedRows = { selected in
            publications.append(selected)
            coordinator.update(columns: columns, rows: rows, in: scroll)
        }
        let group = IndexSet(rows.indices.filter { $0.isMultiple(of: 3) })
        ruler.mouseDown(with: try mouse(ruler, row: 21, partition: true))
        ruler.mouseDragged(with: try mouse(ruler, row: 24, type: .leftMouseDragged, partition: true))
        ruler.mouseUp(with: try mouse(ruler, row: 24, type: .leftMouseUp, partition: true))
        #expect(table.selectedRowIndexes == group)
        #expect(table.selectsWholeRows && table.cellSelection?.columnRange == 0...1)
        #expect(publications == [group])
        #expect(window.firstResponder === table)
        #expect(table.visibleRect == visibleRect)
        #expect(table.view(atColumn: 0, row: 21, makeIfNecessary: false) === firstView)
        table.copy(nil)
        let payload = try JSONDecoder().decode(ResultClipboardPayload.self, from: #require(board.data(forType: ResultTableView.clipboardType)))
        #expect(payload.sourceRows == Array(group) && payload.sourceColumnIndices == [0, 1])
        let children = try #require(ruler.accessibilityChildren() as? [NSAccessibilityElement])
        let marker = try #require(children.first { $0.accessibilityIdentifier() == "gridPartitionMarker-23" })
        let number = try #require(children.first { $0.accessibilityLabel() == "Select row 24" })
        #expect(marker.accessibilityFrame().minX >= number.accessibilityFrame().maxX)
        #expect(marker.accessibilityLabel() == "Select all loaded rows in partition P2")
        #expect(marker.accessibilityPerformPress())
        #expect(table.selectedRowIndexes == IndexSet(rows.indices.filter { !$0.isMultiple(of: 3) && $0 != 22 }))
        #expect(publications.count == 2)
        // Unknown keys never group unrelated rows together.
        ruler.mouseDown(with: try mouse(ruler, row: 22, partition: true))
        #expect(table.selectedRowIndexes == IndexSet(integer: 22))
        // A partition click finishes the current inline draft before selecting.
        var commits: [String] = []
        coordinator.editableColumns = IndexSet(integer: 1)
        coordinator.onCommitCell = { _, value in commits.append(value) }
        coordinator.beginInlineEdit(ResultGridCell(row: 23, column: 1))
        let editor = try #require(table.subviews.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "inlineGridCellEditor" })
        let fieldEditor = try #require(editor.currentEditor())
        fieldEditor.string = "updated"
        ruler.mouseDown(with: try mouse(ruler, row: 21, partition: true))
        #expect(commits == ["updated"] && editor.superview == nil)
        #expect(table.selectedRowIndexes == group && window.firstResponder === table)
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
