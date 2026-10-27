import AppKit
import Testing
@testable import DBeer

@MainActor
struct ResultTableTests {
    private let duplicateColumns = [
        ResultColumn(index: 0, name: "x", typeOid: 25),
        ResultColumn(index: 1, name: "x", typeOid: 1700),
    ]

    @Test func multipleSortHeadersShowPriorityAndDescriptorsFollowSortOrder() throws {
        let coordinator = ResultTableView.Coordinator()
        let scroll = coordinator.makeScrollView()
        coordinator.onSortColumn = { _ in }
        coordinator.sortOrders = [.init(column: "label", direction: "desc"), .init(column: "id", direction: "asc")]
        coordinator.update(columns: [.init(index: 0, name: "id"), .init(index: 1, name: "label")],
                           rows: [["1", "a"]], in: scroll)
        let table = try #require(scroll.documentView as? NSTableView)
        #expect(table.tableColumns.map(\.title) == ["id  2 ↑", "label  1 ↓"])
        #expect(table.sortDescriptors.map(\.key) == [table.tableColumns[1].identifier.rawValue, table.tableColumns[0].identifier.rawValue])
        #expect(table.sortDescriptors.map(\.ascending) == [false, true])
        coordinator.sortOrders = []
        coordinator.onSortColumn = nil
        coordinator.update(columns: [.init(index: 0, name: "id"), .init(index: 1, name: "label")],
                           rows: [["1", "a"]], in: scroll)
        #expect(table.tableColumns.map(\.title) == ["id", "label"] && table.sortDescriptors.isEmpty)
        #expect(table.tableColumns.allSatisfy { $0.sortDescriptorPrototype == nil })
    }

    private func field(_ coordinator: ResultTableView.Coordinator, table: NSTableView,
                       column: Int, row: Int) throws -> NSTextField {
        let cell = try #require(coordinator.tableView(table, viewFor: table.tableColumns[column], row: row)
            as? NSTableCellView)
        return try #require(cell.textField)
    }

    @Test func duplicateHeadersHaveDistinctNativeIdentifiersAndKeepTheirValues() throws {
        let coordinator = ResultTableView.Coordinator()
        let scrollView = coordinator.makeScrollView()
        coordinator.update(columns: duplicateColumns, rows: [["left", "9007199254740993.123456789"]], in: scrollView)
        let table = try #require(scrollView.documentView as? NSTableView)

        #expect(table.headerView != nil)
        #expect(table.tableColumns.map(\.title) == ["x", "x"])
        #expect(Set(table.tableColumns.map(\.identifier)).count == 2)
        #expect(table.tableColumns[0].headerToolTip?.contains("OID 25") == true)
        #expect(table.tableColumns[1].headerToolTip?.contains("OID 1700") == true)
        #expect(try field(coordinator, table: table, column: 0, row: 0).stringValue == "left")
        let preciseValue = try field(coordinator, table: table, column: 1, row: 0)
        #expect(preciseValue.stringValue == "9007199254740993.123456789")
        #expect(preciseValue.toolTip == preciseValue.stringValue)
    }

    @Test func nativeTableIsReadOnlyResizableAndAllowsHorizontalOverflow() throws {
        let coordinator = ResultTableView.Coordinator()
        let scrollView = coordinator.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 100, height: 120)
        coordinator.update(columns: duplicateColumns, rows: [["first", "second"]], in: scrollView)
        let table = try #require(scrollView.documentView as? NSTableView)

        #expect(scrollView.hasVerticalScroller)
        #expect(scrollView.hasHorizontalScroller)
        #expect(table.allowsColumnResizing)
        #expect(table.columnAutoresizingStyle == .noColumnAutoresizing)
        #expect(table.frame.width > scrollView.contentSize.width)
        #expect(!coordinator.tableView(table, shouldEdit: table.tableColumns[0], row: 0))
        for column in table.tableColumns {
            #expect(!column.isEditable)
            #expect(column.resizingMask.contains(.userResizingMask))
            #expect(!column.resizingMask.contains(.autoresizingMask))
        }
        #expect(try !field(coordinator, table: table, column: 0, row: 0).isEditable)
    }

    @Test func nullEmptyAndLiteralNULLHaveDistinctNativePresentationAndAccessibility() throws {
        let coordinator = ResultTableView.Coordinator()
        let scrollView = coordinator.makeScrollView()
        coordinator.update(columns: [duplicateColumns[0]], rows: [[nil], [""], ["NULL"]], in: scrollView)
        let table = try #require(scrollView.documentView as? NSTableView)
        let null = try field(coordinator, table: table, column: 0, row: 0)
        let empty = try field(coordinator, table: table, column: 0, row: 1)
        let literal = try field(coordinator, table: table, column: 0, row: 2)

        #expect(null.stringValue == "NULL")
        #expect(empty.stringValue.isEmpty)
        #expect(literal.stringValue == "NULL")
        #expect(NSFontManager.shared.traits(of: try #require(null.font)).contains(.italicFontMask))
        #expect(!NSFontManager.shared.traits(of: try #require(literal.font)).contains(.italicFontMask))
        #expect(null.textColor == .secondaryLabelColor)
        #expect(empty.textColor == .labelColor)
        #expect(literal.textColor == .labelColor)
        #expect(null.accessibilityValue() == "SQL NULL")
        #expect(empty.accessibilityValue() == "Empty string")
        #expect(literal.accessibilityValue() == "NULL")
        #expect(null.toolTip == "SQL NULL")
        #expect(empty.toolTip == "Empty string")
    }

    @Test func sameSchemaReplacesRowsAndPreservesUserWidths() throws {
        let coordinator = ResultTableView.Coordinator()
        let scrollView = coordinator.makeScrollView()
        coordinator.update(columns: duplicateColumns, rows: [["old", nil]], in: scrollView)
        let table = try #require(scrollView.documentView as? NSTableView)
        let originalColumn = table.tableColumns[0]
        originalColumn.width = 437

        coordinator.update(columns: duplicateColumns, rows: [["new", ""], ["last", "value"]], in: scrollView)
        #expect(table.tableColumns[0] === originalColumn)
        #expect(table.tableColumns[0].width == 437)
        #expect(table.numberOfRows == 2)
        #expect(try field(coordinator, table: table, column: 0, row: 0).stringValue == "new")
        #expect(try field(coordinator, table: table, column: 1, row: 1).stringValue == "value")

        coordinator.update(columns: duplicateColumns, rows: [], in: scrollView)
        #expect(table.numberOfRows == 0)
        #expect(table.numberOfColumns == 2)
        #expect(table.headerView != nil)
        #expect(table.tableColumns[0] === originalColumn)
        #expect(table.tableColumns[0].width == 437)
    }

    @Test func changesToColumnNameTypeOrIndexRebuildNativeSchema() throws {
        let coordinator = ResultTableView.Coordinator()
        let scrollView = coordinator.makeScrollView()
        coordinator.update(columns: [duplicateColumns[0]], rows: [["old"]], in: scrollView)
        let table = try #require(scrollView.documentView as? NSTableView)
        for column in [
            ResultColumn(index: 0, name: "renamed", typeOid: 25),
            ResultColumn(index: 0, name: "renamed", typeOid: 23),
            ResultColumn(index: 1, name: "renamed", typeOid: 23),
        ] {
            let previous = table.tableColumns[0]
            previous.width = 437
            coordinator.update(columns: [column], rows: [], in: scrollView)
            #expect(table.tableColumns[0] !== previous)
            #expect(table.tableColumns[0].title == column.name)
            #expect(table.tableColumns[0].headerToolTip?.contains("OID \(column.typeOid)") == true)
            #expect(table.numberOfRows == 0)
            #expect(table.tableColumns[0].width != 437)
        }
    }

    @Test func mysqlHeaderUsesNativeTypeAndBinaryEncodingWithoutPostgreSQLOID() throws {
        let coordinator = ResultTableView.Coordinator()
        let scrollView = coordinator.makeScrollView()
        let column = ResultColumn(index: 0, name: "payload", engine: .mysql, nativeType: "BLOB", encoding: "base64")
        coordinator.update(columns: [column], rows: [["AAEC"]], in: scrollView)
        let table = try #require(scrollView.documentView as? NSTableView)
        let tooltip = try #require(table.tableColumns.first?.headerToolTip)
        #expect(tooltip.contains("MySQL BLOB"))
        #expect(tooltip.contains("Base64"))
        #expect(!tooltip.contains("PostgreSQL") && !tooltip.contains("OID"))
    }
}
