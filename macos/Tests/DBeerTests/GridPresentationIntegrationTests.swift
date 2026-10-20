import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Exercises the production grid in its own native window without a database,
/// saved profile, Keychain credentials or operating-system Accessibility access.
@Suite(.serialized)
@MainActor
struct GridPresentationIntegrationTests {
    @MainActor private final class Presentation: ObservableObject {
        @Published var scheme = ColorScheme.light
    }

    @MainActor private final class CloseRecorder {
        var issues: [WorkspaceCloseIssue] = []
    }

    @MainActor private struct Fixture {
        let workspace: ApplicationWorkspace
        let document: SQLDocument
        let grid: GridDraft
        let result: BackendMessage
        let presentation = Presentation()
    }

    private struct PresentedGrid: View {
        let fixture: Fixture
        @ObservedObject var presentation: Presentation

        var body: some View {
            SQLDocumentPane(document: fixture.document, workspace: fixture.workspace)
                .foregroundStyle(.primary)
                .background(AppPalette.background).tint(AppPalette.accent)
                .preferredColorScheme(presentation.scheme).focusEffectDisabled()
        }
    }

    private struct Element {
        let object: NSObject

        func objectValue<T>(_ name: String) -> T? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue() as? T
        }

        func boolValue(_ name: String, default fallback: Bool = false) -> Bool {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return fallback }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }

        var identifier: String? { objectValue("accessibilityIdentifier") }
        var enabled: Bool { boolValue("isAccessibilityEnabled", default: true) }
        var value: String? { objectValue("accessibilityValue") }
        var label: String? { objectValue("accessibilityLabel") }

        var frame: NSRect? {
            guard object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
            return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
        }
    }

    private func elements(in root: NSView) -> [Element] {
        var result: [Element] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let object = object as? NSObject {
                let element = Element(object: object)
                result.append(element)
                let children: [Any] = element.objectValue("accessibilityChildren") ?? []
                for child in children { visit(child as AnyObject) }
            }
            if let view = object as? NSView { view.subviews.forEach { visit($0) } }
        }
        visit(root)
        return result
    }

    private func element(_ identifier: String, in root: NSView) throws -> Element {
        try #require(elements(in: root).first { $0.identifier == identifier },
            "Missing native grid element: \(identifier)")
    }

    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, of: type) }
    }

    private func fixture(managed: Bool = false,
                         closeDecision: @escaping @MainActor (WorkspaceCloseIssue) async -> WorkspaceCloseDecision = { _ in .cancel }) -> Fixture {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: closeDecision)
        let reference = TableReference(schema: "public", name: "orders", kind: "table")
        let columns = [
            ResultColumn(index: 0, name: "id", typeOid: 23, nativeType: "int4"),
            ResultColumn(index: 1, name: "status", typeOid: 1043, nativeType: "varchar(32)"),
            ResultColumn(index: 2, name: "note", typeOid: 1043, nativeType: "varchar(255)"),
            ResultColumn(index: 3, name: "computed", typeOid: 23, nativeType: "int4"),
            ResultColumn(index: 4, name: "description", typeOid: 25, nativeType: "text"),
        ]
        let result = BackendMessage(type: "query.result", requestId: "grid-presentation-fixture", durationMs: 0.9,
            columns: columns, rows: [
                ["1", "shipped", "", "2", "Delivered to the local pickup point.\nTracking has been confirmed."],
                ["2", "paid", nil, "4", "Payment received.\nPreparing the order for shipment."],
                ["3", "new", "NULL", "6", nil],
            ],
            commandTag: "SELECT 3", rowCount: 3, displayedRowCount: 3)
        let metadata = [
            ["name": "id", "nativeType": "integer", "primaryKey": "1", "editable": "true", "generated": ""],
            ["name": "status", "nativeType": "varchar(32)", "primaryKey": "0", "editable": "true", "generated": ""],
            ["name": "note", "nativeType": "varchar(255)", "primaryKey": "0", "editable": "true", "generated": ""],
            ["name": "computed", "nativeType": "integer", "primaryKey": "0", "editable": "false", "generated": "id * 2"],
            ["name": "description", "nativeType": "text", "primaryKey": "0", "editable": "true", "generated": ""],
        ]
        let grid = GridDraft(reference: reference, result: result, metadata: metadata)
        let document = managed ? workspace.newDocument() : SQLDocument(title: "orders")
        document.title = "orders"
        document.table = reference
        document.tableColumns = metadata
        document.attachGrid(grid)
        document.executions = [SQLExecution(sql: "", range: NSRange(location: 0, length: 0),
            status: "Completed", result: result)]
        return Fixture(workspace: workspace, document: document, grid: grid, result: result)
    }

    private func host(_ fixture: Fixture, width: CGFloat = 1180, height: CGFloat = 720) -> (NSWindow, NSView) {
        let app = NSApplication.shared
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let content = NSHostingView(rootView: PresentedGrid(fixture: fixture, presentation: fixture.presentation))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DBeer grid presentation verification"
        window.isReleasedWhenClosed = false
        window.contentView = content
        fixture.workspace.presentationWindow = window
        window.makeKeyAndOrderFront(nil)
        return (window, content)
    }

    private func settle(_ content: NSView) async throws {
        try await Task.sleep(for: .milliseconds(140))
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
    }

    private func key(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func click(_ cell: ResultGridCell, in table: ResultGridTableView, count: Int) throws {
        let window = try #require(table.window)
        let rect = table.frameOfCell(atColumn: cell.column, row: cell.row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: count, clickCount: count, pressure: 1))
            window.sendEvent(event)
        }
    }

    private func capture(_ content: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        // Include this owned window's backing below the transparent SwiftUI
        // hierarchy, matching the production workspace screenshot harness.
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func partitionFixture() -> Fixture {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore())
        let reference = TableReference(schema: "shop", name: "orders", kind: "table")
        let names = ["customer_id", "year", "order_id", "status", "amount"]
        let columns = names.enumerated().map { ResultColumn(index: $0.offset, name: $0.element, engine: .cassandra, nativeType: $0.offset < 3 ? "int" : "text") }
        let result = BackendMessage(type: "query.result", requestId: "partition-presentation", columns: columns, rows: [
            ["10", "2026", "101", "paid", "120.00"], ["10", "2026", "102", "shipped", "89.50"],
            ["20", "2026", "103", "new", "45.00"], ["10", "2026", "104", "paid", "60.00"],
            ["20", "2026", "105", "new", "32.00"], ["10", "2026", "106", "pending", "25.00"],
        ], commandTag: "SELECT", rowCount: 6, displayedRowCount: 6)
        let metadata = names.enumerated().map { index, name in
            ["name": name, "nativeType": columns[index].nativeType, "primaryKey": index < 3 ? "\(index + 1)" : "0",
             "partitionKeyPosition": index < 2 ? "\(index + 1)" : "0", "editable": index < 3 ? "false" : "true"]
        }
        let grid = GridDraft(reference: reference, result: result, metadata: metadata)
        let document = workspace.newDocument()
        document.title = "orders"
        document.table = reference
        document.tableColumns = metadata
        document.attachGrid(grid)
        document.executions = [SQLExecution(sql: "", range: NSRange(location: 0, length: 0), status: "Completed", result: result)]
        return Fixture(workspace: workspace, document: document, grid: grid, result: result)
    }

    @Test func partitionMarkersAndApplyStatusFollowPendingRowsInBothAppearances() async throws {
        let fixture = partitionFixture()
        for (row, amount) in [(0, "125.00"), (1, "90.00"), (3, "65.00")] {
            fixture.grid.set(ChangeValue(kind: "text", value: amount), row: row, column: 4)
        }
        let (window, content) = host(fixture)
        defer { window.close() }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            fixture.presentation.scheme = name == "dark" ? .dark : .light
            window.appearance = NSAppearance(named: appearance)
            try await settle(content)
            let table = try #require(descendants(content, of: ResultGridTableView.self).first)
            let ruler = try #require(table.enclosingScrollView?.verticalRulerView as? ResultGridRowNumberRuler)
            #expect(table.numberOfColumns == 5 && ruler.ruleThickness >= 120)
            #expect(ruler.partitionMarker(forRow: 0)?.label == "P1" && ruler.partitionMarker(forRow: 3)?.label == "P1")
            #expect(ruler.partitionMarker(forRow: 2)?.label == "P2")
            #expect(try element("gridApply", in: content).enabled)
            let status = try element("gridPartitionStatus", in: content)
            #expect(status.label == "1 partition · P1" || status.value == "1 partition · P1")
            try capture(content, name: "grid-partitions-\(name)")
        }
        let table = try #require(descendants(content, of: ResultGridTableView.self).first)
        let ruler = try #require(table.enclosingScrollView?.verticalRulerView as? ResultGridRowNumberRuler)
        let rect = ruler.rect(forRow: 2)
        let point = ruler.convert(NSPoint(x: rect.maxX - 44, y: rect.midY), to: nil)
        let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        #expect(hit === ruler)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
        try await settle(content)
        #expect(table.selectedRowIndexes == IndexSet([2, 4]))
        #expect(fixture.grid.selectedRows == IndexSet([2, 4]))
        let selectedStatus = try element("gridPartitionStatus", in: content)
        #expect(selectedStatus.label == "1 partition · P1" || selectedStatus.value == "1 partition · P1")
        fixture.grid.set(ChangeValue(kind: "text", value: "46.00"), row: 2, column: 4)
        try await settle(content)
        let mixedStatus = try element("gridPartitionStatus", in: content)
        #expect(mixedStatus.label == "2 partitions" || mixedStatus.value == "2 partitions")
        #expect(try !element("gridApply", in: content).enabled)
        try capture(content, name: "grid-partitions-mixed-dark")
        #expect(!(await fixture.workspace.applyGrid(fixture.document)))
        #expect(fixture.grid.pendingCount == 4 && fixture.grid.error?.contains("one partition") == true)
        fixture.grid.set(ChangeValue(kind: "text", value: "45.00"), row: 2, column: 4)
        try await settle(content)
        #expect(try element("gridApply", in: content).enabled)
        window.setContentSize(NSSize(width: 600, height: 620))
        try await settle(content)
        let apply = try #require(element("gridApply", in: content).frame)
        let status = try #require(element("gridPartitionStatus", in: content).frame)
        let frame = window.convertToScreen(content.bounds)
        #expect(apply.minX >= frame.minX && apply.maxX <= frame.maxX + 1)
        #expect(status.minX >= frame.minX && status.maxX <= apply.minX)
        try capture(content, name: "grid-partitions-compact-dark")
        await fixture.workspace.shutdown()
    }

    @Test func filterLivesBesideConnectionAboveTheGridAndRowActionsStayBelow() async throws {
        let fixture = fixture()
        let (window, content) = host(fixture)
        defer { window.close() }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            fixture.presentation.scheme = name == "dark" ? .dark : .light
            window.appearance = NSAppearance(named: appearance)
            try await settle(content)
            let table = try #require(descendants(content, of: ResultGridTableView.self).first)
            let scroll = try #require(table.enclosingScrollView)
            let tableFrame = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            let filterFrame = try #require(element("gridFilter", in: content).frame)
            let connectionFrame = try #require(element("documentConnection", in: content).frame)
            #expect(filterFrame.minY >= tableFrame.maxY - 1)
            #expect(filterFrame.minX >= connectionFrame.maxX)
            #expect(abs(filterFrame.midY - connectionFrame.midY) < 5)
            for ids in [
                ["gridInsertRow", "gridDeleteRows", "gridColumns", "tablePreviousPage", "tablePage", "tableNextPage"],
                ["gridSelectionSummary", "gridExport", "gridDiscard", "gridApply"],
            ] {
                let frames = try ids.map { try #require(element($0, in: content).frame) }
                #expect(frames.allSatisfy { $0.maxY <= tableFrame.minY + 1 },
                    "Grid management belongs below the data in \(name)")
                let centers = frames.map(\.midY)
                let highestCenter = try #require(centers.max())
                let lowestCenter = try #require(centers.min())
                #expect(highestCenter - lowestCenter < 5,
                    "Related grid actions must remain on one line in \(name)")
            }
            #expect(try !element("tablePreviousPage", in: content).enabled)
            #expect(try !element("tableNextPage", in: content).enabled)
            #expect(!elements(in: content).contains { $0.identifier == "gridPreviewSQL" })
            try capture(content, name: "grid-tableplus-footer-\(name)")
        }
        await fixture.workspace.shutdown()
    }

    @Test(arguments: [Int64(3), Int64(13)])
    func queryResultsShowDisplayedAndTotalCountsWithoutTheSelectHeading(_ total: Int64) async throws {
        let fixture = fixture()
        fixture.document.table = nil
        fixture.document.attachGrid(nil)
        fixture.document.executions[0].result?.rowCount = total
        let (window, content) = host(fixture)
        defer { window.close() }
        try await settle(content)
        let summary = try element("queryRowCount", in: content)
        let expected = "3 from \(total) rows shown"
        #expect(summary.label == expected || summary.value == expected)
        #expect(!elements(in: content).contains { $0.label == "SELECT 3" || $0.value == "SELECT 3" })
        let table = try #require(descendants(content, of: ResultGridTableView.self).first)
        let tableFrame = window.convertToScreen(table.convert(table.bounds, to: nil))
        let summaryFrame = try #require(summary.frame)
        #expect(summaryFrame.midX > tableFrame.midX)
        try capture(content, name: "query-row-count-\(total)")
        await fixture.workspace.shutdown()
    }

    @Test func previewIsPresentOnlyWhileChangesCanBePreviewed() async throws {
        let fixture = fixture()
        let (window, content) = host(fixture)
        defer { window.close() }
        try await settle(content)
        #expect(!elements(in: content).contains { $0.identifier == "gridPreviewSQL" })
        fixture.grid.set(ChangeValue(kind: "text", value: "cancelled"), row: 0, column: 1)
        try await settle(content)
        #expect(try element("gridPreviewSQL", in: content).enabled)
        #expect(try !element("gridExport", in: content).enabled)
        #expect(try !element("gridFilter", in: content).enabled)

        fixture.grid.isPreviewing = true
        try await settle(content)
        #expect(!elements(in: content).contains { $0.identifier == "gridPreviewSQL" })
        fixture.grid.isPreviewing = false
        fixture.grid.isApplying = true
        try await settle(content)
        #expect(!elements(in: content).contains { $0.identifier == "gridPreviewSQL" })
        fixture.grid.isApplying = false
        fixture.document.isRunning = true
        try await settle(content)
        #expect(!elements(in: content).contains { $0.identifier == "gridPreviewSQL" })
        fixture.document.isRunning = false
        fixture.grid.isReloading = true
        try await settle(content)
        #expect(!elements(in: content).contains { $0.identifier == "gridPreviewSQL" })
        fixture.grid.isReloading = false
        fixture.grid.outcomeUnknown = true
        try await settle(content)
        #expect(!elements(in: content).contains { $0.identifier == "gridPreviewSQL" })
        fixture.grid.outcomeUnknown = false
        fixture.grid.isClosing = true
        try await settle(content)
        #expect(!elements(in: content).contains { $0.identifier == "gridPreviewSQL" })
        fixture.grid.isClosing = false
        fixture.grid.discard()
        try await settle(content)
        #expect(!elements(in: content).contains { $0.identifier == "gridPreviewSQL" })
        #expect(try element("gridExport", in: content).enabled)
        await fixture.workspace.shutdown()
    }

    @Test func minimumWidthKeepsAllFooterActionsAndInspectorInsideTheWindow() async throws {
        let fixture = fixture()
        fixture.grid.selectedRows = IndexSet(integer: 0)
        fixture.grid.set(ChangeValue(kind: "text", value: "packed"), row: 0, column: 1)
        let (window, content) = host(fixture, width: 600, height: 620)
        defer { window.close() }
        fixture.presentation.scheme = .dark
        window.appearance = NSAppearance(named: .darkAqua)
        try await settle(content)
        let table = try #require(descendants(content, of: ResultGridTableView.self).first)
        try #require(window.makeFirstResponder(table))
        table.keyDown(with: try key(49, characters: " "))
        try await settle(content)
        #expect(content.bounds.width <= 601)
        let visible = window.convertToScreen(content.convert(content.bounds, to: nil)).insetBy(dx: -1, dy: -1)
        for identifier in ["gridInsertRow", "gridDeleteRows", "gridColumns", "gridFilter",
                           "tablePreviousPage", "tablePage", "tableNextPage", "gridSelectionSummary", "gridExport",
                           "gridPreviewSQL", "gridDiscard", "gridApply", "gridRowInspector"] {
            let frame = try #require(element(identifier, in: content).frame)
            #expect(!frame.isEmpty && visible.contains(frame),
                "Native grid control must stay visible at 600 points: \(identifier)")
        }
        let actionFrames = try ["gridSelectionSummary", "gridExport", "gridPreviewSQL", "gridDiscard", "gridApply"]
            .map { try #require(element($0, in: content).frame) }
        let highestCenter = try #require(actionFrames.map(\.midY).max())
        let lowestCenter = try #require(actionFrames.map(\.midY).min())
        #expect(highestCenter - lowestCenter < 5)
        #expect(try #require(table.enclosingScrollView).bounds.width >= 200)
        try capture(content, name: "grid-tableplus-compact-dark")
        await fixture.workspace.shutdown()
    }

    @Test(arguments: ["tab", "window", "profile"])
    func dirtyInlineDraftIsStagedBeforeACancellableClose(_ scope: String) async throws {
        let recorder = CloseRecorder()
        let fixture = fixture(managed: true, closeDecision: { issue in
            recorder.issues.append(issue)
            return .cancel
        })
        let profileID = UUID()
        fixture.document.profileID = profileID
        let (window, content) = host(fixture)
        defer { window.close() }
        try await settle(content)
        let table = try #require(descendants(content, of: ResultGridTableView.self).first)
        let cell = table.frameOfCell(atColumn: 1, row: 0)
        let point = table.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
        let doubleClick = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 2, pressure: 1))
        table.mouseDown(with: doubleClick)
        try await settle(content)
        let field = try #require(descendants(content, of: NSTextField.self)
            .first { $0.identifier?.rawValue == "inlineGridCellEditor" })
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("packing", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await settle(content)
        #expect(fixture.grid.pendingCount == 0)
        #expect(fixture.grid.hasInlineDraft)
        #expect(try !element("gridFilter", in: content).enabled)
        #expect(try element("gridApply", in: content).enabled)

        switch scope {
        case "tab": await fixture.workspace.closeDocument(fixture.document)
        case "window":
            let mayClose = await fixture.workspace.prepareToClose(.application)
            #expect(!mayClose)
        default:
            let mayDisconnect = await fixture.workspace.disconnectProfile(profileID)
            #expect(!mayDisconnect)
        }
        #expect(recorder.issues == [.changes("orders", count: 1)])
        #expect(fixture.workspace.documents.contains { $0 === fixture.document })
        #expect(fixture.document.grid === fixture.grid)
        #expect(fixture.grid.pendingCount == 1)
        #expect(fixture.grid.value(row: 0, column: 1) == ChangeValue(kind: "text", value: "packing"))
        #expect(fixture.grid.canEdit)
        await fixture.workspace.shutdown()
    }

    @Test(arguments: [1, 2])
    func nativeDoubleClickOpensDetailsAndKeepsTheCellEditorReadyToType(_ column: Int) async throws {
        let fixture = fixture()
        let (window, content) = host(fixture, width: 600)
        defer { window.close() }
        descendants(content, of: NSScrollView.self).forEach { $0.scrollerStyle = .legacy }
        try await settle(content)
        #expect(!elements(in: content).contains { $0.identifier == "gridRowDetails" })
        #expect(!elements(in: content).contains { $0.identifier == "gridRowInspector" })
        let table = try #require(descendants(content, of: ResultGridTableView.self).first)
        let cell = ResultGridCell(row: 1, column: column)
        try click(cell, in: table, count: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!elements(in: content).contains { $0.identifier == "gridRowInspector" })
        try click(cell, in: table, count: 2)
        try await settle(content)
        _ = try element("gridRowInspector", in: content)
        #expect(fixture.grid.selectedRows == IndexSet(integer: 1))
        #expect(try element("gridInspectorValue-\(column)", in: content).value == (column == 1 ? "paid" : ""))
        #expect(window.attachedSheet == nil)
        let field = try #require(descendants(table, of: NSTextField.self)
            .first { $0.identifier?.rawValue == "inlineGridCellEditor" })
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(window.firstResponder === editor)
        let editorFrame = field.convert(field.bounds, to: table)
        #expect(table.visibleRect.contains(editorFrame),
            "table=\(table.frame), clip=\(String(describing: table.enclosingScrollView?.contentView.bounds))")
        let header = try #require(table.headerView)
        let headerFrame = table.convert(header.headerRect(ofColumn: column), from: header)
        #expect(abs(headerFrame.minX - table.rect(ofColumn: column).minX) < 1,
            "The scrolled editor must remain beneath its own column header")
        editor.insertText("packed", replacementRange: editor.selectedRange())
        fixture.grid.commitEditing?()
        try await settle(content)
        #expect(fixture.grid.value(row: 1, column: column) == ChangeValue(kind: "text", value: "packed"))
        #expect(try element("gridInspectorValue-\(column)", in: content).value == "packed")
        try capture(content, name: "grid-cell-details-double-click-\(column)")
        await fixture.workspace.shutdown()
    }

    @Test func contextMenuShowsTheClickedRowDetailsEvenWhenReadOnlyOrMultipleRowsAreSelected() async throws {
        let fixture = fixture()
        fixture.grid.policyReadOnly = true
        fixture.grid.selectedRows = IndexSet([0, 2])
        let (window, content) = host(fixture)
        defer { window.close() }
        try await settle(content)
        let table = try #require(descendants(content, of: ResultGridTableView.self).first)
        let rect = table.frameOfCell(atColumn: 1, row: 2)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try #require(table.menu(for: event))
        let details = try #require(menu.items.first { $0.title == "Row Details" })
        #expect(details.isEnabled)
        #expect(menu.items.allSatisfy { $0.title != "Edit Cell…" })
        menu.performActionForItem(at: menu.index(of: details))
        try await settle(content)
        #expect(fixture.grid.selectedRows == IndexSet(integer: 2))
        #expect(try element("gridInspectorValue-1", in: content).value == "new")
        #expect(try !element("gridInspectorValue-1", in: content).enabled)
        #expect(window.attachedSheet == nil)
        await fixture.workspace.shutdown()
    }

    @Test func spaceTogglesRowInspectorAndSelectionUpdatesItWithoutOpeningASheet() async throws {
        let fixture = fixture()
        let (window, content) = host(fixture)
        defer { window.close() }
        try await settle(content)
        let table = try #require(descendants(content, of: ResultGridTableView.self).first)
        fixture.grid.selectedRows = IndexSet(integer: 0)
        try await settle(content)
        try #require(window.makeFirstResponder(table))
        table.keyDown(with: try key(49, characters: " "))
        try await settle(content)
        _ = try element("gridRowInspector", in: content)
        #expect(window.attachedSheet == nil)
        #expect(try element("gridInspectorValue-1", in: content).value == "shipped")
        #expect(try element("gridInspectorValue-2", in: content).value == "")

        fixture.grid.selectedRows = IndexSet(integer: 1)
        try await settle(content)
        #expect(try element("gridInspectorValue-1", in: content).value == "paid")
        #expect(window.attachedSheet == nil)
        let status = try #require(descendants(content, of: NSTextField.self)
            .first { $0.isEditable && $0.stringValue == "paid" })
        try #require(window.makeFirstResponder(status))
        let editor = try #require(status.currentEditor() as? NSTextView)
        editor.insertText("packed", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try #require(window.makeFirstResponder(table))
        try await settle(content)
        #expect(fixture.grid.value(row: 1, column: 1) == ChangeValue(kind: "text", value: "packed"))
        #expect(fixture.grid.value(row: 0, column: 1) == ChangeValue(kind: "text", value: "shipped"))
        #expect(fixture.grid.pendingCount == 1)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            fixture.presentation.scheme = name == "dark" ? .dark : .light
            window.appearance = NSAppearance(named: appearance)
            try await settle(content)
            try capture(content, name: "grid-tableplus-row-inspector-\(name)")
        }

        // Starting to type into a SQL NULL text column must retain the same
        // native editor; replacing it after the first character loses focus.
        fixture.grid.selectedRows = IndexSet(integer: 2)
        try await settle(content)
        let nullEditor = try #require(descendants(content, of: NSTextView.self)
            .first { $0.isEditable && !$0.isFieldEditor })
        #expect(fixture.grid.value(row: 2, column: 4) == .null)
        #expect(nullEditor.string.isEmpty)
        try #require(window.makeFirstResponder(nullEditor))
        nullEditor.insertText("a", replacementRange: NSRange(location: 0, length: 0))
        try await settle(content)
        #expect(window.firstResponder === nullEditor)
        #expect(descendants(content, of: NSTextView.self).contains { $0 === nullEditor })
        nullEditor.insertText("b", replacementRange: NSRange(location: 1, length: 0))
        try await settle(content)
        #expect(window.firstResponder === nullEditor)
        #expect(fixture.grid.value(row: 2, column: 4) == ChangeValue(kind: "text", value: "ab"))

        fixture.grid.selectedRows = IndexSet([0, 1, 2])
        try await settle(content)
        #expect(table.selectedRowIndexes == IndexSet([0, 1, 2]))
        let summary = try element("gridSelectionSummary", in: content)
        #expect(summary.label == "3 of 3 selected" || summary.value == "3 of 3 selected")
        #expect(window.attachedSheet == nil)
        table.keyDown(with: try key(49, characters: " "))
        try await settle(content)
        #expect(!elements(in: content).contains { $0.identifier == "gridRowInspector" })
        await fixture.workspace.shutdown()
    }
}
