import AppKit
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import DBeer

private let tableBrowseUIAllScenarios = ["postgresql-light", "postgresql-dark", "mysql-light", "mysql-dark",
    "cassandra-light", "cassandra-dark", "mongodb-light", "mongodb-dark"]
private let tableBrowseUIScenarios: [String] = ProcessInfo.processInfo.environment["DBEER_TABLE_BROWSE_UI_SCENARIO"]
    .map { [$0] } ?? tableBrowseUIAllScenarios

/// Opt-in desktop verification. scripts/test-table-browse-ui.sh supplies four
/// disposable servers; every profile, preference, document and saved view is private.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DBEER_TABLE_BROWSE_UI_FIXTURE"] == "1"))
@MainActor
struct TableBrowseUIIntegrationTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private var executable: URL {
        ProcessInfo.processInfo.environment["DBEER_TABLE_BROWSE_UI_HELPER"].map(URL.init(fileURLWithPath:)) ??
            repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
    }
    private let tableName = "browse_ui_items"

    private func settings(_ engine: DatabaseEngine) throws -> ConnectionSettings {
        let env = ProcessInfo.processInfo.environment
        switch engine {
        case .postgresql:
            let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
            return ConnectionSettings(host: try #require(url.host), port: url.port ?? 5432,
                database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "",
                sslMode: url.queryItems?.first { $0.name == "sslmode" }?.value ?? "disable")
        case .mysql:
            return ConnectionSettings(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
                port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")), database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer",
                user: try #require(env["DBEER_TEST_MYSQL_USER"]), password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "",
                sslMode: env["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable", sslRootCert: env["DBEER_TEST_MYSQL_CA_FILE"], engine: .mysql)
        case .cassandra:
            let host = env["DBEER_TEST_CASSANDRA_HOST"] ?? "localhost"
            return ConnectionSettings(host: host, port: try #require(Int(env["DBEER_TEST_CASSANDRA_PORT"] ?? "")),
                database: env["DBEER_TEST_CASSANDRA_DATABASE"] ?? "dbeer", user: env["DBEER_TEST_CASSANDRA_USER"] ?? "",
                password: env["DBEER_TEST_CASSANDRA_PASSWORD"] ?? "", sslMode: env["DBEER_TEST_CASSANDRA_SSLMODE"] ?? "disable",
                sslRootCert: env["DBEER_TEST_CASSANDRA_CA_FILE"], engine: .cassandra, contactPoints: [host],
                localDatacenter: env["DBEER_TEST_CASSANDRA_DATACENTER"] ?? "datacenter1", consistency: "LOCAL_ONE")
        case .mongodb:
            return ConnectionSettings(host: env["DBEER_TEST_MONGODB_HOST"] ?? "localhost",
                port: try #require(Int(env["DBEER_TEST_MONGODB_PORT"] ?? "")), database: env["DBEER_TEST_MONGODB_DATABASE"] ?? "dbeer_browse_ui",
                user: env["DBEER_TEST_MONGODB_USER"] ?? "", password: env["DBEER_TEST_MONGODB_PASSWORD"] ?? "",
                sslMode: env["DBEER_TEST_MONGODB_SSLMODE"] ?? "disable", sslRootCert: env["DBEER_TEST_MONGODB_CA"],
                engine: .mongodb, mongodb: MongoDBSettings())
        }
    }

    private func execute(_ sql: String, client: BackendClient, session: String) async throws {
        let assessment = try #require(try await client.request(.assess(sessionId: session,
            operations: [OperationRequest(type: "execute", sql: sql)])).assessment)
        try #require(assessment.decision != "deny", "Disposable fixture preparation was rejected.")
        var command = BackendCommand.execute(sessionId: session, sql: sql)
        command.authorization = assessment.authorization
        let response = try await client.request(command)
        try #require(response.type != "error", "Disposable table preparation failed.")
    }

    private func seed(_ settings: ConnectionSettings, schema: String) async throws {
        guard settings.engine != .mongodb else { return } // Seeded by the runner's mongosh fixture.
        let client = BackendClient(executableURL: executable)
        try await client.start()
        do {
            let session = try #require(try await client.request(.connect(settings)).sessionId)
            let quote = settings.engine == .mysql ? "`" : "\""
            func quoted(_ value: String) -> String { quote + value.replacingOccurrences(of: quote, with: quote + quote) + quote }
            let qualified = quoted(schema) + "." + quoted(tableName)
            try await execute("DROP TABLE IF EXISTS \(qualified)", client: client, session: session)
            let primary = settings.engine == .cassandra ? ", PRIMARY KEY ((\"tenant\"), \"rank\", \"id\")" : ", PRIMARY KEY (\(quoted("id")))"
            let columns = ["tenant", "rank", "id"].map { quoted($0) + " int" } + [quoted("label") + " text", quoted("nullable") + " text"]
            try await execute("CREATE TABLE \(qualified) (\(columns.joined(separator: ", "))\(primary))", client: client, session: session)
            let rows = ["1,1,1,'alpha',NULL", "1,1,2,'beta',''", "1,2,3,'alpha','NULL'", "1,2,4,'beta','v'",
                "1,3,5,'alpha','v'", "2,1,6,'gamma',NULL", "2,2,7,'alpha',''", "2,3,8,'beta','NULL'"]
            for row in rows {
                try await execute("INSERT INTO \(qualified) (\(["tenant", "rank", "id", "label", "nullable"].map(quoted).joined(separator: ","))) VALUES (\(row))", client: client, session: session)
            }
            _ = await client.shutdown()
        } catch {
            _ = await client.shutdown()
            throw error
        }
    }

    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
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
        var identifier: String? { value("accessibilityIdentifier") }
        var label: String? { value("accessibilityLabel") }
        var button: NSButton? { (object as? NSButton) ?? ((object as? NSCell)?.controlView as? NSButton) }
        var field: NSTextField? { (object as? NSTextField) ?? ((object as? NSCell)?.controlView as? NSTextField) }
        var view: NSView? { (object as? NSView) ?? (object as? NSCell)?.controlView }
        var enabled: Bool { button?.isEnabled ?? flag("isAccessibilityEnabled") }
        var screenFrame: NSRect? {
            if let view, let window = view.window { return window.convertToScreen(view.convert(view.bounds, to: nil)) }
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector) else { return nil }
            typealias Getter = @convention(c) (AnyObject, Selector) -> NSRect
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
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
        for child in window.childWindows ?? [] { result += elements(child) }
        return result
    }
    private func element(_ id: String, _ window: NSWindow) throws -> Element {
        let matching = elements(window).filter { $0.identifier == id && !($0.object is ControlCursorView) }
        return try #require(matching.first { $0.button != nil } ?? matching.first, "Missing native browse control: \(id)")
    }
    private func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition(), Comment(rawValue: message))
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(160)) }
    private func reveal(_ e: Element, in window: NSWindow) async throws {
        if let view = e.view { _ = view.scrollToVisible(view.bounds); view.window?.contentView?.layoutSubtreeIfNeeded() }
        else if let frame = e.screenFrame {
            func ownedWindows(_ root: NSWindow) -> [NSWindow] {
                (root.childWindows ?? []).flatMap(ownedWindows) + [root]
            }
            let windows = ownedWindows(window)
            let accessibleWindow: NSWindow? = e.value("accessibilityWindow")
            let ordered = accessibleWindow.map { preferred in [preferred] + windows.filter { $0 !== preferred } } ?? windows
            for owner in ordered {
                guard let content = owner.contentView else { continue }
                let candidates: [(NSView, NSRect)] = descendants(content, NSScrollView.self).compactMap { scroll in
                    guard !scroll.isHiddenOrHasHiddenAncestor, let document = scroll.documentView else { return nil }
                    let rectangle = document.convert(owner.convertFromScreen(frame), from: nil)
                    guard document.bounds.insetBy(dx: -2, dy: -2).contains(rectangle) else { return nil }
                    return (document, rectangle)
                }
                if let target = candidates.min(by: { $0.0.bounds.width * $0.0.bounds.height < $1.0.bounds.width * $1.0.bounds.height }) {
                    _ = target.0.scrollToVisible(target.1)
                    content.layoutSubtreeIfNeeded()
                    break
                }
            }
        }
        try await settle()
    }
    private func press(_ id: String, _ window: NSWindow) async throws {
        let e = try element(id, window)
        try await reveal(e, in: window)
        try #require(e.enabled, "Disabled browse control: \(id)")
        if let button = e.button { try #require(button.isEnabled, "Disabled browse control: \(id)"); button.performClick(nil) }
        else { try #require(e.flag("accessibilityPerformPress"), "Cannot press browse control: \(id)") }
        try await settle()
    }
    private func choose(_ title: String, _ id: String, _ window: NSWindow) async throws {
        let e = try element(id, window)
        try await reveal(e, in: window)
        try await NativeThemeMenuActions.select(title, in: #require(e.button, "Missing native popup: \(id)"))
        try await settle()
    }
    private func enter(_ text: String, _ id: String, _ window: NSWindow) async throws {
        let e = try element(id, window)
        try await reveal(e, in: window)
        let field = try #require(e.field, "Missing native browse field: \(id)")
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await settle()
    }
    private func host(_ workspace: ApplicationWorkspace, dark: Bool) async throws -> NSWindow {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 55, y: 45, width: 1420, height: 920),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DBeer table browsing verification"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: ApplicationWorkspaceView(workspace: workspace).preferredColorScheme(dark ? .dark : .light))
        workspace.presentationWindow = window
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        try await wait("The owned browse window did not activate.") { window.makeKey(); return window.isKeyWindow }
        try await settle()
        return window
    }
    private func panel(_ window: NSWindow) throws -> NSWindow {
        try #require((window.childWindows ?? []).first { elements($0).contains { $0.identifier == "tableBrowseApply" } }, "The filter popover did not open as an owned child window.")
    }
    private func capture(_ window: NSWindow, name: String) async throws {
        guard #available(macOS 14.4, *) else { return }
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"]))
        // Popovers can share their parent's backing surface. Capture that owned
        // root window at its own dimensions and composite the child windows.
        var capturedWindow = window
        while let parent = capturedWindow.parent { capturedWindow = parent }
        let available = try await SCShareableContent.currentProcess
        let owned = try #require(available.windows.first { $0.windowID == CGWindowID(capturedWindow.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(capturedWindow.frame.width * 2); configuration.height = Int(capturedWindow.frame.height * 2)
        configuration.scalesToFit = true; configuration.captureResolution = .best
        configuration.includeChildWindows = true
        configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: owned), configuration: configuration)
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
    }
    private func values(_ document: SQLDocument, column: String, engine: DatabaseEngine) throws -> [Int] {
        let grid = try #require(document.grid)
        if engine != .mongodb {
            let index = try #require(grid.columns.firstIndex { $0.name == column })
            return try grid.rows.map { try #require(Int($0.values[index].value ?? "")) }
        }
        return try grid.rows.map { row in
            let text = try #require(row.values.first?.value)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            if let number = object[column] as? NSNumber { return number.intValue }
            let wrapped = try #require(object[column] as? [String: String])
            return try #require(Int(wrapped["$numberInt"] ?? wrapped["$numberLong"] ?? ""))
        }
    }
    private func headerClick(_ window: NSWindow, document: SQLDocument, column: String) async throws {
        let content = try #require(window.contentView)
        let grid = try #require(descendants(content, ResultGridTableView.self).first { $0.appCommandDocumentID == document.id })
        let index = try #require(document.grid?.columns.firstIndex { $0.name == column })
        let header = try #require(grid.headerView)
        grid.scrollColumnToVisible(index)
        let rectangle = header.headerRect(ofColumn: index)
        let point = header.convert(NSPoint(x: rectangle.midX, y: rectangle.midY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 11, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 12, clickCount: 1, pressure: 0))
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.postEvent(up, atStart: true)
        header.mouseDown(with: down)
        try await settle()
    }

    @MainActor private final class QueryCounter {
        var starts: [String] = []
        var observation: AnyCancellable?
        init(_ runtime: WorkspaceModel) {
            observation = runtime.$activeQueryId.compactMap { $0 }.sink { [weak self] id in self?.starts.append(id) }
        }
    }

    @Test(arguments: tableBrowseUIScenarios)
    func nativeFiltersSortingSavedViewsAndExplicitApply(_ scenario: String) async throws {
        try #require(tableBrowseUIAllScenarios.contains(scenario), "Unknown DBEER_TABLE_BROWSE_UI_SCENARIO; choose an exact engine-theme name.")
        let engine: DatabaseEngine = scenario.hasPrefix("postgresql") ? .postgresql : scenario.hasPrefix("mysql") ? .mysql : scenario.hasPrefix("cassandra") ? .cassandra : .mongodb
        let connection = try settings(engine)
        let schema = engine == .postgresql ? "public" : connection.database
        try await seed(connection, schema: schema)
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"]))
        let root = output.appendingPathComponent("artifacts-" + scenario + "-" + UUID().uuidString)
        let defaultsName = "dev.dbeer.tests.table-browse-ui." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let themes = EditorThemeStore(defaults: defaults, directory: root.appendingPathComponent("themes"))
        let appearance = AppAppearance(defaults: defaults, editorThemes: themes)
        appearance.theme = scenario.hasSuffix("dark") ? .dark : .light
        let originalAppearance = NSApplication.shared.appearance
        let originalIcon = NSApplication.shared.applicationIconImage
        appearance.start()
        defer {
            appearance.chooseSelection("system")
            NSApplication.shared.appearance = originalAppearance
            NSApplication.shared.applicationIconImage = originalIcon
        }
        let expectedAppearance: NSAppearance.Name = scenario.hasSuffix("dark") ? .darkAqua : .aqua
        #expect(NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expectedAppearance)
        let snapshots = ResultSnapshotStore(rootURL: root.appendingPathComponent("snapshots"))
        let presetURL = root.appendingPathComponent("saved-views/library.json")
        let presets = TableBrowsePresetStore(fileURL: presetURL)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(), commandShortcuts: AppShortcutStore(defaults: defaults), copySettings: ResultCopySettings(defaults: defaults),
            editorThemes: themes, appearance: appearance, sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: SQLLibrary(),
            tableBrowsePresets: presets, resultSnapshots: ResultSnapshotsModel(store: snapshots),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in true }, helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        let window = try await host(workspace, dark: scenario.hasSuffix("dark"))
        defer { window.attachedSheet?.orderOut(nil); window.close() }
        do {
            try #require(await workspace.library.saveConnection(name: "Browse \(engine.displayName) fixture", settings: connection))
            let profileID = try #require(workspace.library.selectedConnectionId)
            await workspace.connectProfile(profileID)
            try #require(workspace.services[profileID]?.connectionState == .connected, "The disposable browse profile did not connect.")
            let node = CatalogNode(profileID: profileID, name: tableName, kind: .object, schema: schema, object: tableName, objectKind: "table", engine: engine)
            let document = try #require(await workspace.openData(node))
            try #require(document.grid?.rows.count == 8 && document.tableFailure == nil && document.localError == nil,
                "The initial real table/collection did not load eight fixture rows.")
            let runtime = try #require(document.runtime)
            let counter = QueryCounter(runtime)
            defer { counter.observation?.cancel() }
            let originalGrid = try #require(document.grid)
            let originalQuery = runtime.result?.queryId
            if engine == .cassandra || engine == .mongodb {
                #expect(document.foreignKeysError == nil && document.tableForeignKeys.isEmpty)
                #expect(!elements(window).contains { $0.identifier == "gridRelatedRows" })
            }
            try await capture(window, name: scenario + "-initial")
            try await press("gridFilter", window)
            try await wait("The draft filter panel did not mount.") { elements(window).contains { $0.identifier == "tableBrowseApply" } }
            #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expectedAppearance)
            #expect(try panel(window).effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expectedAppearance)
            try await press("tableAddFilter", window)
            try await choose("tenant", "tableFilterColumn-0", window)
            try await enter("1", "tableFilterValue-0", window)
            if engine == .cassandra {
                try await press("tableFilterAddCondition-root", window)
                try await choose("rank", "tableFilterColumn-1", window)
                try await choose("≥", "tableFilterOperator-1", window)
                try await enter("2", "tableFilterValue-1", window)
                try await choose("All (AND)", "tableFilterGroup-root", window)
                #expect(document.browseDraftConfiguration.filterExpression?.flattenedConjunction?.count == 2)
            } else {
                try await press("tableFilterAddGroup-root", window)
                try await choose("Any (OR)", "tableFilterGroup-1", window)
                try await choose("label", "tableFilterColumn-1-0", window)
                try await enter(engine == .mongodb ? "\"gamma\"" : "gamma", "tableFilterValue-1-0", window)
                try await enter(engine == .mongodb ? "\"alpha\"" : "alpha", "tableFilterValue-1-0", window)
                try await press("tableFilterAddCondition-1", window)
                try await choose("rank", "tableFilterColumn-1-1", window)
                try await choose("≥", "tableFilterOperator-1-1", window)
                try await enter("2", "tableFilterValue-1-1", window)
                try await press("tableFilterAddGroup-1", window)
                try await choose("nullable", "tableFilterColumn-1-2-0", window)
                try await choose("IS NULL", "tableFilterOperator-1-2-0", window)
                try await press("tableFilterRemoveGroup-1-2", window)
            }
            try await press("tableFilterAddCondition-root", window)
            try await press("tableFilterRemove-2", window)
            #expect(document.grid === originalGrid && runtime.result?.queryId == originalQuery && counter.starts.isEmpty)
            #expect(document.tableFilterExpression == nil && document.hasPendingBrowseChanges)
            try await reveal(try element("tableFilterGroup-root", window), in: window)
            try await capture(try panel(window), name: scenario + "-filter-groups")

            try await press("tableAddSort", window)
            try await choose("rank", "tableSortColumn-0", window)
            try await choose("Descending", "tableSortDirection-0", window)
            if engine != .cassandra {
                try await press("tableAddSort", window)
                try await choose("id", "tableSortColumn-1", window)
                try await press("tableSortUp-1", window)
                #expect(document.browseDraftConfiguration.sort.first?.column == "id")
                try await press("tableSortDown-0", window)
                try await choose("Ascending", "tableSortDirection-0", window)
                try await choose("Descending", "tableSortDirection-0", window)
                #expect(document.browseDraftConfiguration.sort.map(\.column) == ["rank", "id"])
            } else {
                #expect(try !element("tableAddSort", window).enabled)
            }
            #expect(counter.starts.isEmpty && document.grid === originalGrid)
            try await press("tableBrowseApply", window)
            try await wait("Applying the grouped filters did not complete.") { !document.isRunning && !document.isApplyingBrowse && counter.starts.count == 1 }
            try #require(document.tableFailure == nil && document.localError == nil,
                Comment(rawValue: document.tableFailure?.message ?? document.localError ?? "Browse Apply failed."))
            if engine == .cassandra {
                #expect(Set(try values(document, column: "id", engine: engine)) == [3, 4, 5])
                #expect(try values(document, column: "rank", engine: engine) == [3, 2, 2])
            } else { #expect(try values(document, column: "id", engine: engine) == [5, 3, 4, 1]) }
            #expect(document.page == 0 && !document.hasPendingBrowseChanges)
            let applied = document.browseConfiguration
            try await press("gridFilter", window)
            try await capture(window, name: scenario + "-filtered-sorted")
            // A real owned header click changes only a sort draft. MongoDB's
            // single BSON document column intentionally offers no header sorting.
            try await headerClick(window, document: document, column: engine == .mongodb ? "document" : "rank")
            if engine == .mongodb { #expect(document.browseDraftConfiguration == applied) }
            else { #expect(document.hasPendingBrowseChanges && document.tableSort == applied.sort) }
            #expect(counter.starts.count == 1)
            try await press("gridFilter", window)
            if engine != .mongodb { try await press("tableBrowseReset", window) }
            #expect(document.browseDraftConfiguration == applied)

            try await enter("Tenant one review", "tableBrowsePresetName", window)
            try await press("tableBrowseSavePreset", window)
            try await wait("Save New did not privately publish the view.") { presets.isLoaded && !presets.isBusy && presets.presets.count == 1 }
            let savedID = try #require(presets.presets.first?.id)
            try await enter("2", "tableFilterValue-0", window)
            #expect(document.hasPendingBrowseChanges)
            try await press("tableBrowseLoadPreset", window)
            #expect(document.browseDraftConfiguration == applied && counter.starts.count == 1)
            try await choose("Choose…", "tableBrowsePreset", window)
            try await choose("Tenant one review", "tableBrowsePreset", window)
            let rankPath = engine == .cassandra ? "1" : "1-1"
            try await enter("3", "tableFilterValue-" + rankPath, window)
            let updated = document.browseDraftConfiguration
            try await press("tableBrowseUpdatePreset", window)
            try await wait("Update Selected did not save the edited configuration.") { !presets.isBusy && presets.presets.first?.configuration == updated }
            try await enter("Reviewed tenant one", "tableBrowsePresetName", window)
            try await press("tableBrowseRenamePreset", window)
            try await wait("Rename did not retain the saved view identity.") { !presets.isBusy && presets.presets.first?.name == "Reviewed tenant one" }
            #expect(presets.presets.first?.id == savedID && counter.starts.count == 1)
            try await reveal(try element("tableBrowsePresetName", window), in: window)
            try await capture(try panel(window), name: scenario + "-saved-view")
            try await press("tableBrowseClearFilters", window)
            #expect(document.browseDraftConfiguration.filterExpression == nil && counter.starts.count == 1)
            try await press("tableBrowseReset", window)
            #expect(document.browseDraftConfiguration == applied)
            try await press("tableBrowseLoadPreset", window)
            #expect(document.browseDraftConfiguration == updated)
            try await press("tableBrowseApply", window)
            try await wait("The saved draft did not apply exactly once.") { !document.isRunning && !document.isApplyingBrowse && counter.starts.count == 2 }
            try #require(document.tableFailure == nil && document.localError == nil,
                Comment(rawValue: document.tableFailure?.message ?? document.localError ?? "Saved-view Apply failed."))
            #expect(try values(document, column: "id", engine: engine) == (engine == .cassandra ? [5] : [5, 3, 1]))
            try await press("tableBrowseDeletePreset", window)
            try await wait("Delete did not remove only the selected saved view.") { !presets.isBusy && presets.presets.isEmpty }
            let reopened = TableBrowsePresetStore(fileURL: presetURL)
            await reopened.load()
            #expect(reopened.isLoaded && reopened.presets.isEmpty && counter.starts.count == 2)
            try await press("tableBrowseClearFilters", window)
            if engine == .cassandra { try await press("tableSortRemove-0", window) }
            try await press("tableBrowseApply", window)
            try await wait("Clear Filters did not reload the complete fixture once.") { !document.isRunning && !document.isApplyingBrowse && counter.starts.count == 3 }
            #expect(document.grid?.rows.count == 8 && document.tableFailure == nil)
            try await press("gridFilter", window)
            try await capture(window, name: scenario + "-cleared")
            if engine == .postgresql || engine == .mysql {
                let quote = engine == .mysql ? "`" : "\""
                let sql = "SELECT * FROM " + quote + schema + quote + "." + quote + tableName + quote + ";"
                let sqlDocument = workspace.newDocument(profileID: profileID, text: sql)
                sqlDocument.title = "SQL header remains a captured result"
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                try await wait("The SQL result verification editor did not mount.") {
                    guard let content = window.contentView else { return false }
                    return descendants(content, SQLTextView.self).contains { $0.appCommandDocumentID == sqlDocument.id }
                }
                let content = try #require(window.contentView)
                let editor = try #require(descendants(content, SQLTextView.self).first { $0.appCommandDocumentID == sqlDocument.id })
                try #require(window.makeFirstResponder(editor))
                try await press("runQuery", window)
                try await wait("Native Run did not finish the SQL header verification result.") {
                    !sqlDocument.isRunning && sqlDocument.grid?.rows.count == 8
                }
                try #require(sqlDocument.localError == nil && sqlDocument.runtime?.queryFailure == nil)
                let capturedQuery = sqlDocument.runtime?.result?.queryId
                let capturedGrid = try #require(sqlDocument.grid)
                try await headerClick(window, document: sqlDocument, column: "rank")
                let nativeTable = try #require(descendants(content, ResultGridTableView.self).first { $0.appCommandDocumentID == sqlDocument.id })
                #expect(sqlDocument.table == nil && sqlDocument.tableBrowseDraft == nil)
                #expect(sqlDocument.grid === capturedGrid && sqlDocument.runtime?.result?.queryId == capturedQuery)
                #expect(nativeTable.sortDescriptors.isEmpty)
                #expect(nativeTable.tableColumns.allSatisfy { $0.sortDescriptorPrototype == nil && !$0.title.contains("↑") && !$0.title.contains("↓") })
                try await capture(window, name: scenario + "-sql-result-header")
            }
            await workspace.shutdown()
        } catch {
            if let child = window.childWindows?.first { try? await capture(child, name: scenario + "-failure-panel") }
            try? await capture(window, name: scenario + "-failure")
            await workspace.shutdown()
            throw error
        }
    }
}
