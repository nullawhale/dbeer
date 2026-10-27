import AppKit
import Foundation
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import DBeer

/// Synthetic, owned native windows only. Explicit UI opt-in shares the browse
/// runner's isolated output directory and never opens a database connection.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DBEER_TABLE_BROWSE_UI_FIXTURE"] == "1"))
@MainActor
struct TableBrowseUIBoundaryTests {
    private struct Fixture {
        let workspace: ApplicationWorkspace
        let document: SQLDocument
        let presets: TableBrowsePresetStore
        let defaults: UserDefaults
        let defaultsName: String
        let originalAppearance: NSAppearance?
        let originalIcon: NSImage?

        @MainActor func restoreAppearance() {
            workspace.appearance.chooseSelection("system")
            NSApplication.shared.appearance = originalAppearance
            NSApplication.shared.applicationIconImage = originalIcon
        }
    }

    private func fixture(_ theme: String, engine: DatabaseEngine = .postgresql) async throws -> Fixture {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"]))
        let root = output.appendingPathComponent("boundary-artifacts-\(theme)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaultsName = "dev.dbeer.tests.browse-boundary." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let themes = EditorThemeStore(defaults: defaults, directory: root.appendingPathComponent("themes"))
        let appearance = AppAppearance(defaults: defaults, editorThemes: themes)
        appearance.theme = theme == "dark" ? .dark : .light
        let originalAppearance = NSApplication.shared.appearance
        let originalIcon = NSApplication.shared.applicationIconImage
        appearance.start()
        let presets = TableBrowsePresetStore(fileURL: root.appendingPathComponent("saved-views/library.json"))
        let snapshots = ResultSnapshotStore(rootURL: root.appendingPathComponent("snapshots"))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
            commandShortcuts: AppShortcutStore(defaults: defaults), copySettings: ResultCopySettings(defaults: defaults),
            editorThemes: themes, appearance: appearance, sqlFolders: SQLFolderLibrary(automaticallyRefresh: false),
            sqlLibrary: SQLLibrary(), tableBrowsePresets: presets, resultSnapshots: ResultSnapshotsModel(store: snapshots),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in false },
            helperFactory: { BackendClient(executableURL: URL(fileURLWithPath: "/nonexistent/dbeer-core")) })
        let settings = ConnectionSettings(host: "localhost", port: engine == .cassandra ? 9042 : 5432,
            database: "fixture", user: "fixture", password: "", sslMode: "disable", engine: engine,
            contactPoints: engine == .cassandra ? ["localhost"] : nil,
            localDatacenter: engine == .cassandra ? "datacenter1" : nil, consistency: engine == .cassandra ? "LOCAL_ONE" : nil)
        try #require(await workspace.library.saveConnection(name: "Private boundary fixture", settings: settings))
        let document = workspace.newDocument(profileID: workspace.library.selectedConnectionId)
        document.table = TableReference(schema: "fixture", name: "records", kind: "table")
        await presets.load()
        try #require(presets.isLoaded)
        return Fixture(workspace: workspace, document: document, presets: presets, defaults: defaults, defaultsName: defaultsName,
                       originalAppearance: originalAppearance, originalIcon: originalIcon)
    }

    @MainActor private struct Element {
        let object: NSObject
        func value<T>(_ name: String) -> T? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? T : nil
        }
        func flag(_ name: String) -> Bool {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return false }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        var screenFrame: NSRect? {
            if let view, let window = view.window {
                return window.convertToScreen(view.convert(view.bounds, to: nil))
            }
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector) else { return nil }
            typealias Getter = @convention(c) (AnyObject, Selector) -> NSRect
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        var enabled: Bool { button?.isEnabled ?? flag("isAccessibilityEnabled") }
        var identifier: String? { value("accessibilityIdentifier") }
        var button: NSButton? { (object as? NSButton) ?? ((object as? NSCell)?.controlView as? NSButton) }
        var view: NSView? { (object as? NSView) ?? (object as? NSCell)?.controlView }
    }

    private func elements(_ window: NSWindow) -> [Element] {
        var visited = Set<ObjectIdentifier>(), result: [Element] = []
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            let element = Element(object: object)
            result.append(element)
            let children: [NSObject] = element.value("accessibilityChildren") ?? []
            children.forEach(visit)
            (object as? NSView)?.subviews.forEach(visit)
        }
        visit(window)
        if let content = window.contentView { visit(content) }
        return result
    }

    private func element(_ id: String, _ window: NSWindow) throws -> Element {
        let matching = elements(window).filter { $0.identifier == id && !($0.object is ControlCursorView) }
        return try #require(matching.first { $0.button != nil } ?? matching.first,
            "Missing native boundary control: \(id)")
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(180)) }

    private func host<V: View>(_ view: V, theme: String, size: NSSize = NSSize(width: 560, height: 650)) async throws -> NSWindow {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 60), size: size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DBeer private browse boundary verification"
        window.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view.background(AppPalette.background).tint(AppPalette.accent)
            .preferredColorScheme(theme == "dark" ? .dark : .light))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        for _ in 0..<80 where !window.isKeyWindow {
            window.makeKey()
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(window.isKeyWindow)
        try await settle()
        return window
    }

    private func reveal(_ id: String, _ window: NSWindow) async throws -> Element {
        let candidate = try element(id, window)
        if let view = candidate.view {
            _ = view.scrollToVisible(view.bounds)
        } else {
            // SwiftUI buttons can be virtual accessibility elements. Their
            // screen frame still locates them in the native scroll document.
            let frame = try #require(candidate.screenFrame, "Native control has no frame: \(id)")
            let content = try #require(window.contentView)
            let candidates: [(NSView, NSRect)] = descendants(content, NSScrollView.self).compactMap { scroll in
                guard !scroll.isHiddenOrHasHiddenAncestor, let document = scroll.documentView else { return nil }
                let rectangle = document.convert(window.convertFromScreen(frame), from: nil)
                guard document.bounds.insetBy(dx: -2, dy: -2).intersects(rectangle) else { return nil }
                return (document, rectangle)
            }
            if let target = candidates.min(by: { $0.0.bounds.width * $0.0.bounds.height < $1.0.bounds.width * $1.0.bounds.height }) {
                _ = target.0.scrollToVisible(target.1)
            }
        }
        window.contentView?.layoutSubtreeIfNeeded()
        try await settle()
        return try element(id, window)
    }

    private func expectVisible(_ id: String, _ window: NSWindow) async throws {
        let element = try await reveal(id, window)
        let content = try #require(window.contentView)
        let rectangle = try #require(element.screenFrame, "Native control has no screen frame: \(id)")
        let viewport = window.convertToScreen(content.convert(content.bounds, to: nil))
        #expect(rectangle.width > 0 && rectangle.height > 0, "Native control has an empty frame: \(id)")
        #expect(viewport.insetBy(dx: -1, dy: -1).contains(rectangle), "Native control exceeds the 560-point viewport: \(id)")
        if let view = element.view {
            #expect(view.window === window && !view.isHiddenOrHasHiddenAncestor)
            #expect(view.visibleRect.width >= view.bounds.width - 1 && view.visibleRect.height >= view.bounds.height - 1,
                "Native control is clipped after scrolling: \(id)")
        }
    }

    private func press(_ id: String, _ window: NSWindow) async throws {
        let element = try await reveal(id, window)
        try #require(element.enabled, "Native button is disabled: \(id)")
        if let button = element.button { button.performClick(nil) }
        else { try #require(element.flag("accessibilityPerformPress"), "Native button action unavailable: \(id)") }
        try await settle()
    }

    private func choose(_ title: String, _ id: String, _ window: NSWindow) async throws {
        let element = try await reveal(id, window)
        try await NativeThemeMenuActions.select(title, in: #require(element.button, "Native popup unavailable: \(id)"))
        try await settle()
    }

    private func capture(_ window: NSWindow, name: String) async throws {
        guard #available(macOS 14.4, *) else { return }
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"]))
        let available = try await SCShareableContent.currentProcess
        let owned = try #require(available.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2)
        configuration.height = Int(window.frame.height * 2)
        configuration.scalesToFit = true
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: owned), configuration: configuration)
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent(name + ".png"))
    }

    private func predicate(_ column: String, operator operation: String = "eq", value: String = "1") -> CatalogFilterExpression {
        .predicate(CatalogFilter(column: column, operator: operation, value: value))
    }

    @Test(arguments: ["light", "dark"])
    func deepestAllowedGroupsAndLongNamesRemainReachable(_ theme: String) async throws {
        let fixture = try await fixture(theme)
        defer { fixture.restoreAppearance(); fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        let document = fixture.document
        let first = "customer_segment_with_a_long_but_valid_database_column_name_for_native_width"
        let second = "archived_external_reference_with_another_long_database_column_name_for_native_width"
        document.tableColumns = [["name": "id"], ["name": first], ["name": second]]
        let expression = CatalogFilterExpression.group("and", [predicate("id"), .group("or", [predicate(first, value: "needle"),
            .group("and", [predicate(second, value: "A quoted Unicode value: Ω 猫")])])])
        let configuration = TableBrowseConfiguration(filterExpression: expression,
            sort: [.init(column: first, direction: "asc"), .init(column: second, direction: "desc"), .init(column: "id", direction: "asc")])
        try #require(configuration.isValid)
        let name = "Review customer segments and archived external references with a deliberately long saved view name"
        _ = try await fixture.presets.saveNew(name: name, profileID: #require(document.profileID),
            table: #require(document.table), configuration: configuration)
        let window = try await host(TableBrowseControls(document: document, workspace: fixture.workspace), theme: theme)
        defer { window.close() }
        do {
            try await choose(name, "tableBrowsePreset", window)
            #expect(document.browseDraftConfiguration == configuration && document.hasPendingBrowseChanges)
            try await expectVisible("tableFilterGroup-root", window)
            try await capture(window, name: "boundary-\(theme)-deep-groups-top")
            for id in ["tableFilterColumn-1-1-0", "tableFilterOperator-1-1-0", "tableFilterValue-1-1-0"] {
                try await expectVisible(id, window)
            }
            try await capture(window, name: "boundary-\(theme)-deep-groups-value")
            for id in ["tableSortColumn-0", "tableSortDirection-0", "tableSortColumn-2", "tableBrowsePreset", "tableBrowsePresetName", "tableBrowseApply", "tableBrowseReset"] {
                try await expectVisible(id, window)
            }
            try await capture(window, name: "boundary-\(theme)-deep-groups-bottom")
            #expect(try element("tableBrowseApply", window).enabled == true)
            try await press("tableBrowseReset", window)
            #expect(!document.hasPendingBrowseChanges && document.browseDraftConfiguration == .init())
            #expect(document.runtime == nil && document.grid == nil)
            await fixture.workspace.shutdown()
        } catch {
            try? await capture(window, name: "boundary-\(theme)-deep-groups-failure")
            await fixture.workspace.shutdown()
            throw error
        }
    }

    @Test(arguments: ["light", "dark"])
    func inheritedCassandraORAndUnsupportedOperatorCanBeRepairedNatively(_ theme: String) async throws {
        let fixture = try await fixture(theme, engine: .cassandra)
        defer { fixture.restoreAppearance(); fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        let document = fixture.document
        document.tableColumns = [["name": "tenant", "nativeType": "int", "partitionKeyPosition": "1"],
            ["name": "rank", "nativeType": "int", "clusteringPosition": "1"]]
        let expression = CatalogFilterExpression.group("or", [predicate("tenant", operator: "ne"), predicate("rank", operator: "gte", value: "2")])
        let configuration = TableBrowseConfiguration(filterExpression: expression)
        _ = try await fixture.presets.saveNew(name: "Inherited unsupported Cassandra view", profileID: #require(document.profileID),
            table: #require(document.table), configuration: configuration)
        let window = try await host(TableBrowseControls(document: document, workspace: fixture.workspace), theme: theme)
        defer { window.close() }
        do {
            try await choose("Inherited unsupported Cassandra view", "tableBrowsePreset", window)
            #expect(document.browseDraftConfiguration == configuration)
            _ = try element("tableBrowseValidation", window)
            try await expectVisible("tableBrowseApply", window)
            #expect(try element("tableBrowseApply", window).enabled == false)
            try await capture(window, name: "boundary-\(theme)-cassandra-invalid")
            try await choose("All (AND)", "tableFilterGroup-root", window)
            #expect(document.browseDraftConfiguration.filterExpression?.kind == "and")
            #expect(try element("tableBrowseApply", window).enabled == false)
            try await choose("=", "tableFilterOperator-0", window)
            #expect(document.browseDraftConfiguration.filterExpression?.flattenedConjunction?.first?.operator == "eq")
            #expect(!elements(window).contains { $0.identifier == "tableBrowseValidation" })
            try await expectVisible("tableBrowseApply", window)
            #expect(try element("tableBrowseApply", window).enabled == true)
            try await capture(window, name: "boundary-\(theme)-cassandra-repaired")
            #expect(document.runtime == nil && document.grid == nil && document.tableFilterExpression == nil)
            await fixture.workspace.shutdown()
        } catch {
            try? await capture(window, name: "boundary-\(theme)-cassandra-failure")
            await fixture.workspace.shutdown()
            throw error
        }
    }

    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
    }

    @Test(arguments: ["light", "dark"])
    func arbitrarySQLResultHasNoNativeSortAction(_ theme: String) async throws {
        let fixture = try await fixture(theme)
        defer { fixture.restoreAppearance(); fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        let document = fixture.document
        document.table = nil
        let result = BackendMessage(type: "query.result", requestId: "boundary-result",
            columns: [.init(index: 0, name: "id", nativeType: "int4"), .init(index: 1, name: "label", nativeType: "text")],
            rows: [["2", "second"], ["1", "first"]])
        let grid = GridDraft(reference: .init(schema: "fixture", name: "records", kind: "table"), result: result,
            metadata: [["name": "id"], ["name": "label"]])
        grid.policyReadOnly = true
        document.attachGrid(grid)
        let window = try await host(DataGridView(document: document, workspace: fixture.workspace, grid: grid, result: result),
            theme: theme, size: NSSize(width: 900, height: 500))
        defer { window.close() }
        do {
            let content = try #require(window.contentView)
            let table = try #require(descendants(content, ResultGridTableView.self).first)
            let coordinator = try #require(table.delegate as? ResultTableView.Coordinator)
            #expect(coordinator.onSortColumn == nil && table.sortDescriptors.isEmpty)
            #expect(table.tableColumns.allSatisfy { $0.sortDescriptorPrototype == nil })
            let header = try #require(table.headerView)
            let rectangle = header.headerRect(ofColumn: 0)
            let point = header.convert(NSPoint(x: rectangle.midX, y: rectangle.midY), to: nil)
            let time = ProcessInfo.processInfo.systemUptime
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 21, clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.01,
                windowNumber: window.windowNumber, context: nil, eventNumber: 22, clickCount: 1, pressure: 0))
            NSApplication.shared.postEvent(up, atStart: true)
            header.mouseDown(with: down)
            try await settle()
            #expect(table.sortDescriptors.isEmpty && document.tableBrowseDraft == nil && document.runtime == nil)
            #expect(grid.displayedRows == [["2", "second"], ["1", "first"]])
            try await capture(window, name: "boundary-\(theme)-sql-result-unsorted")
            await fixture.workspace.shutdown()
        } catch {
            try? await capture(window, name: "boundary-\(theme)-sql-result-failure")
            await fixture.workspace.shutdown()
            throw error
        }
    }
}
