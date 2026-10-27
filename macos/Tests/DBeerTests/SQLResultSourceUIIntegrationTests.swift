import AppKit
import Foundation
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import DBeer

/// Explicit opt-in native UI verification against disposable database fixtures.
/// The runner supplies temporary credentials; every table and profile is synthetic.
@Suite(.serialized, .enabled(if:
    ProcessInfo.processInfo.environment["DBEER_R22_UI_QA"] == "1" &&
    ProcessInfo.processInfo.environment["DBEER_R22_UI_DISPOSABLE"] == "1" &&
    !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty &&
    !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
@MainActor
struct SQLResultSourceUIIntegrationTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private var executable: URL { repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core") }

    private func settings(_ engine: DatabaseEngine) throws -> ConnectionSettings {
        let env = ProcessInfo.processInfo.environment
        if engine == .mysql {
            return ConnectionSettings(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
                port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")),
                database: try #require(env["DBEER_TEST_MYSQL_DATABASE"]), user: try #require(env["DBEER_TEST_MYSQL_USER"]),
                password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: env["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable",
                sslRootCert: env["DBEER_TEST_MYSQL_CA_FILE"], engine: .mysql)
        }
        let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
        return ConnectionSettings(host: try #require(url.host), port: url.port ?? 5432,
            database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "",
            sslMode: url.queryItems?.first { $0.name == "sslmode" }?.value ?? "disable")
    }

    private func execute(_ sql: String, client: BackendClient, session: String) async throws -> BackendMessage {
        let command = BackendCommand.execute(sessionId: session, sql: sql)
        let assessment = try #require(try await client.request(.assess(sessionId: session,
            operations: [OperationRequest(type: "execute", sql: sql)])).assessment)
        try #require(assessment.decision != "deny")
        var approved = command
        approved.authorization = assessment.authorization
        return try await client.request(approved)
    }

    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
    }

    @MainActor private struct Element {
        let object: NSObject
        func value<T>(_ name: String) -> T? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? T : nil
        }
        func flag(_ name: String, fallback: Bool = false) -> Bool {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return fallback }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        var identifier: String? { value("accessibilityIdentifier") }
        var label: String? { value("accessibilityLabel") }
        var text: String? { value("accessibilityValue") }
        var button: NSButton? { (object as? NSButton) ?? ((object as? NSCell)?.controlView as? NSButton) }
        var enabled: Bool { button?.isEnabled ?? flag("isAccessibilityEnabled", fallback: true) }
    }

    private func elements(_ window: NSWindow) -> [Element] {
        var visited = Set<ObjectIdentifier>()
        var result: [Element] = []
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
        if let sheet = window.attachedSheet { result += elements(sheet) }
        return result
    }

    private func element(_ id: String, _ window: NSWindow) throws -> Element {
        try #require(elements(window).first { $0.identifier == id }, "Missing native R22 control: \(id)")
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition(), Comment(rawValue: message))
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(180))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func press(_ id: String, _ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        // Text changes update the model synchronously; SwiftUI publishes the
        // corresponding native command state on a later run-loop turn.
        try await settle(window)
        try await waitFor("The native R22 control did not become enabled: \(id)") {
            elements(window).first { $0.identifier == id }?.enabled == true
        }
        let control = try element(id, window)
        if let button = control.button { button.performClick(nil) }
        else {
            let pressed = control.flag("accessibilityPerformPress")
            try #require(pressed, "Cannot press R22 control: \(id)")
        }
        try await settle(window)
    }

    private func host(_ workspace: ApplicationWorkspace, dark: Bool) async throws -> NSWindow {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1420, height: 920),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DBeer SQL result source verification"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: ApplicationWorkspaceView(workspace: workspace)
            .preferredColorScheme(dark ? .dark : .light))
        workspace.presentationWindow = window
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        try await waitFor("The R22 verification window did not activate.") { window.makeKey(); return window.isKeyWindow }
        try await settle(window)
        return window
    }

    private func capture(_ window: NSWindow, name: String) async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if #available(macOS 14.4, *) {
            let available = try await SCShareableContent.currentProcess
            let ownWindow = try #require(available.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * 2)
            configuration.height = Int(window.frame.height * 2)
            configuration.scalesToFit = true
            configuration.captureResolution = .best
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent(name + ".png"))
        } else {
            let content = try #require(window.contentView)
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
    }

    private func runInEditor(_ sql: String, profileID: UUID, workspace: ApplicationWorkspace, window: NSWindow) async throws -> SQLDocument {
        let document = workspace.newDocument(profileID: profileID, text: "")
        document.title = "SQL source verification"
        try await settle(window)
        let content = try #require(window.contentView)
        let editor = try #require(descendants(content, SQLTextView.self).first)
        try #require(window.makeFirstResponder(editor))
        editor.insertText(sql, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try await waitFor("The native SQL editor did not update its document.") { document.text == sql }
        try await settle(window)
        let context = workspace.commands.context(for: document)
        let commandEnabled = workspace.commands.canPerform(.runCurrent, context: context)
        try #require(commandEnabled, Comment(rawValue: "R22 Run command unavailable: workspace=\(context.isWorkspaceWindow), modal=\(context.hasModal), composing=\(context.isComposingText), selected=\(workspace.selectedDocumentID == document.id), textBytes=\(document.text.utf8.count)"))
        try await press("runQuery", window)
        try await waitFor("The native Run control did not complete the SQL result.") {
            !document.isRunning && document.executions.first?.result != nil
        }
        try #require(document.executions.first?.failure == nil && document.localError == nil,
            "SQL failed through the native editor.")
        let rowCount = document.executions.first?.result?.rows?.count ?? 0
        try await waitFor("The completed SQL result did not mount its native grid.") {
            descendants(content, ResultGridTableView.self).contains {
                $0.window === window && $0.appCommandDocumentID == document.id && $0.numberOfRows == rowCount
            }
        }
        // Terminal model state precedes mounting the new result view. Allow its
        // deferred initial ruler layout to finish before asserting geometry.
        try await settle(window)
        return document
    }

    private func nativeGrid(_ window: NSWindow, documentID: UUID? = nil) throws -> ResultGridTableView {
        let content = try #require(window.contentView)
        return try #require(descendants(content, ResultGridTableView.self).first {
            documentID == nil || $0.appCommandDocumentID == documentID
        })
    }

    private func requireFirstColumnVisible(_ window: NSWindow, document: SQLDocument, stage: String) throws {
        let table = try nativeGrid(window, documentID: document.id)
        let scroll = try #require(table.enclosingScrollView)
        let ruler = try #require(scroll.verticalRulerView)
        let header = try #require(table.headerView)
        let cell = table.frameOfCell(atColumn: 0, row: 0)
        let dataFrame = table.convert(cell, to: scroll)
        let rulerFrame = ruler.convert(ruler.bounds, to: scroll)
        let headerFrame = header.convert(header.headerRect(ofColumn: 0), to: scroll)
        #expect(dataFrame.minX >= rulerFrame.maxX - 0.5,
            Comment(rawValue: "\(stage): first value is behind row numbers; dataX=\(dataFrame.minX), rulerEdge=\(rulerFrame.maxX), clip=\(scroll.contentView.bounds), insets=\(scroll.contentInsets)"))
        #expect(table.visibleRect.minX <= cell.minX + 0.5,
            Comment(rawValue: "\(stage): leading first-column data is clipped."))
        #expect(abs(dataFrame.minX - headerFrame.minX - table.intercellSpacing.width / 2) <= 0.5,
            Comment(rawValue: "\(stage): column header and data do not align."))
    }

    private func click(_ cell: ResultGridCell, table: ResultGridTableView, count: Int) throws {
        let window = try #require(table.window)
        table.scrollRowToVisible(cell.row)
        table.scrollColumnToVisible(cell.column)
        table.enclosingScrollView?.layoutSubtreeIfNeeded()
        let rect = table.frameOfCell(atColumn: cell.column, row: cell.row)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        try #require(table.visibleRect.contains(point), "R22 click must reach a visible cell.")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: table.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: count, clickCount: count, pressure: 1)))
        }
    }

    private func editNote(_ text: String, grid: GridDraft, window: NSWindow) async throws {
        let table = try nativeGrid(window)
        try click(ResultGridCell(row: 0, column: 0), table: table, count: 1)
        try click(ResultGridCell(row: 0, column: 0), table: table, count: 2)
        try await settle(window)
        let field = try #require(descendants(table, NSTextField.self).first { $0.identifier?.rawValue == "inlineGridCellEditor" })
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await waitFor("Typing did not create a native inline draft.") { grid.hasInlineDraft }
        try #require(window.makeFirstResponder(table))
        try await waitFor("Finishing the native cell edit did not create a pending change.") { !grid.hasInlineDraft && grid.pendingCount == 1 }
        #expect(grid.rows[0].values[0].value == text)
    }

    @Test(arguments: ["postgresql-dark", "postgresql-light", "mysql-dark", "mysql-light"])
    func nativeRunSourceRowApplyConflictAndReadonly(_ scenario: String) async throws {
        let engine: DatabaseEngine = scenario.hasPrefix("mysql") ? .mysql : .postgresql
        let settings = try settings(engine)
        let schema = engine == .postgresql ? "public" : settings.database
        let name = "dbeer_r22_ui_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        func quoted(_ identifier: String) -> String {
            let quote = engine == .postgresql ? "\"" : "`"
            return quote + identifier.replacingOccurrences(of: quote, with: quote + quote) + quote
        }
        let table = quoted(schema) + "." + quoted(name)
        let control = BackendClient(executableURL: executable)
        try await control.start()
        let session = try #require(try await control.request(.connect(settings)).sessionId)
        let defaultsName = "dbeer-r22-ui-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let artifactRoot = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"]))
            .appendingPathComponent("artifacts-" + scenario)
        let snapshots = ResultSnapshotStore(rootURL: artifactRoot.appendingPathComponent("snapshots"))
        let themes = EditorThemeStore(defaults: defaults, directory: artifactRoot.appendingPathComponent("themes"))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(), commandShortcuts: AppShortcutStore(defaults: defaults),
            copySettings: ResultCopySettings(defaults: defaults), editorThemes: themes,
            appearance: AppAppearance(defaults: defaults, editorThemes: themes), sqlFolders: SQLFolderLibrary(automaticallyRefresh: false),
            sqlLibrary: SQLLibrary(), resultSnapshots: ResultSnapshotsModel(store: snapshots),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in true },
            helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        let window = try await host(workspace, dark: scenario.hasSuffix("dark"))
        defer { window.attachedSheet?.orderOut(nil); window.close() }
        do {
            let binaryType = engine == .postgresql ? "bytea" : "blob"
            let jsonType = engine == .postgresql ? "jsonb" : "json"
            _ = try await execute("CREATE TABLE \(table) (id bigint PRIMARY KEY, note varchar(64), amount decimal(30,9), payload \(binaryType), doc \(jsonType), day varchar(10))", client: control, session: session)
            let binary = engine == .postgresql ? "decode('00ff','hex')" : "X'00FF'"
            let json = "'{\"large\":9007199254740993,\"note\":\"synthetic\"}'" + (engine == .postgresql ? "::jsonb" : "")
            _ = try await execute("INSERT INTO \(table) VALUES (9223372036854775807,'original',12345678901234567890.123456789,\(binary),\(json),'2026-10-27'),(4,'NULL',NULL,NULL,NULL,NULL),(3,'',NULL,NULL,NULL,NULL),(2,NULL,NULL,NULL,NULL,NULL)", client: control, session: session)
            try #require(await workspace.library.saveConnection(name: "R22 \(engine.displayName) synthetic fixture", settings: settings))
            let profileID = try #require(workspace.library.selectedConnectionId)
            let fullSQL = "SELECT note AS shown,id,amount,payload,doc,day FROM \(table) ORDER BY id DESC;"
            let document = try await runInEditor(fullSQL, profileID: profileID, workspace: workspace, window: window)
            let grid = try #require(document.grid)
            try #require(grid.canEdit && grid.rows.count == 4)
            #expect(grid.columns.map(\.name) == ["shown", "id", "amount", "payload", "doc", "day"])
            #expect(grid.querySource?.columns.map(\.tableIndex) == [1, 0, 2, 3, 4, 5])
            #expect(grid.rows[0].values[1].value == "9223372036854775807")
            #expect(grid.rows[0].values[2].value == "12345678901234567890.123456789")
            #expect(grid.rows[0].values[3] == ChangeValue(kind: "binary", value: "AP8="))
            #expect(grid.rows[0].values[4].value?.contains("9007199254740993") == true)
            #expect(grid.rows[1].values[0].value == "NULL" && grid.rows[2].values[0].value == "" && grid.rows[3].values[0] == .null)
            #expect(try nativeGrid(window).numberOfRows == 4)
            let executionID = try #require(document.executions.first?.id)
            let queryID = document.runtime?.result?.queryId
            try requireFirstColumnVisible(window, document: document, stage: "\(scenario)-typed-result")
            try await capture(window, name: "\(scenario)-typed-result")

            try await editNote("native edited", grid: grid, window: window)
            try await press("gridPreviewSQL", window)
            try await waitFor("The native SQL preview sheet did not open.") { grid.preview != nil && window.attachedSheet != nil }
            #expect(grid.preview?.catalogRecords.first?["sql"]?.contains("note") == true)
            #expect(grid.preview?.catalogRecords.first?["sql"]?.contains("shown") == false)
            try await capture(try #require(window.attachedSheet), name: "\(scenario)-preview")
            let done = try #require(elements(window).first { $0.label == "Done" || $0.button?.title == "Done" })
            if let button = done.button { button.performClick(nil) }
            else { try #require(done.flag("accessibilityPerformPress"), "Cannot close the native preview sheet.") }
            try await waitFor("The preview sheet did not close.") { grid.preview == nil && window.attachedSheet == nil }
            try await press("gridApply", window)
            try await waitFor("Apply did not mark the captured SQL result stale.") { !grid.isApplying && grid.resultIsStale }
            #expect(grid.pendingCount == 0 && !grid.canEdit && !grid.outcomeUnknown)
            #expect(document.grid === grid && document.executions.count == 1 && document.executions[0].id == executionID)
            #expect(document.runtime?.result?.queryId == queryID)
            #expect(try !element("gridApply", window).enabled)
            #expect(try !element("pinQueryResult", window).enabled)
            #expect(try !element("gridExport", window).enabled)
            #expect(try await execute("SELECT note FROM \(table) WHERE id=9223372036854775807", client: control, session: session).rows == [["native edited"]])
            try await capture(window, name: "\(scenario)-applied-stale")

            let conflictDocument = try await runInEditor(fullSQL, profileID: profileID, workspace: workspace, window: window)
            let conflict = try #require(conflictDocument.grid)
            try await editNote("local conflict", grid: conflict, window: window)
            _ = try await execute("UPDATE \(table) SET note='server changed' WHERE id=9223372036854775807", client: control, session: session)
            try await press("gridApply", window)
            try await waitFor("The native conflicting Apply did not return its result.") { !conflict.isApplying && conflict.error != nil }
            #expect(conflict.pendingCount == 1 && conflict.resultIsStale && !conflict.outcomeUnknown)
            #expect(conflict.rows[0].values[0].value == "local conflict")
            #expect(try !element("gridApply", window).enabled)
            #expect(try await execute("SELECT note FROM \(table) WHERE id=9223372036854775807", client: control, session: session).rows == [["server changed"]])
            try await capture(window, name: "\(scenario)-conflict-retained")

            let projection = try await runInEditor("SELECT id,note AS shown FROM \(table) WHERE id=9223372036854775807;", profileID: profileID, workspace: workspace, window: window)
            let projectedGrid = try #require(projection.grid)
            #expect(!projectedGrid.canEdit && projectedGrid.querySource?.canOpenRow == true)
            try click(ResultGridCell(row: 0, column: 0), table: nativeGrid(window), count: 1)
            try await settle(window)
            try #require(projectedGrid.selectedRows == IndexSet(integer: 0))
            let count = workspace.documents.count
            let projectedSession = projection.runtime?.sessionId
            try await press("openSQLSourceRow", window)
            try await waitFor("Open Source Row did not load an independent native table tab.") {
                workspace.documents.count == count + 1 && workspace.selectedDocument?.table != nil && workspace.selectedDocument?.grid != nil &&
                    workspace.selectedDocument?.isRunning == false && workspace.selectedDocument?.isNavigatingTable == false
            }
            let source = try #require(workspace.selectedDocument)
            #expect(source.table == TableReference(schema: schema, name: name, kind: "table"))
            #expect(source.tableFilters == [CatalogFilter(column: "id", operator: "eq", value: "9223372036854775807")])
            #expect(source.runtime?.sessionId != projectedSession && source.grid?.rows.count == 1)
            #expect(source.grid?.rows[0].values[0].value == "9223372036854775807")
            #expect(projection.grid === projectedGrid && projection.executions.count == 1)
            try await settle(window)
            try requireFirstColumnVisible(window, document: source, stage: "\(scenario)-source-row")
            try await capture(window, name: "\(scenario)-source-row")

            let unsafe = try await runInEditor("SELECT id+0 AS computed FROM \(table);", profileID: profileID, workspace: workspace, window: window)
            #expect(unsafe.grid == nil && unsafe.executions.first?.result?.source?.readOnlyReason?.isEmpty == false)
            #expect(!elements(window).contains { $0.identifier == "openSQLSourceRow" })
            try await capture(window, name: "\(scenario)-readonly-computed")
            _ = try await execute("DROP TABLE \(table)", client: control, session: session)
            await workspace.shutdown()
            _ = await control.shutdown()
        } catch {
            try? await capture(window.attachedSheet ?? window, name: "\(scenario)-failure")
            _ = try? await execute("DROP TABLE IF EXISTS \(table)", client: control, session: session)
            await workspace.shutdown()
            _ = await control.shutdown()
            throw error
        }
    }
}
