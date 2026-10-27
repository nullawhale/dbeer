import AppKit
import Foundation
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import DBeer

/// Opt-in native windows against scripts/test-mongodb-ui.sh's disposable server.
/// All profiles, credentials, documents and artifacts are isolated from user data.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DBEER_MONGODB_UI_FIXTURE"] == "1"))
@MainActor
struct MongoDBUIIntegrationTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private var executable: URL { repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core") }

    private func settings() throws -> ConnectionSettings {
        let env = ProcessInfo.processInfo.environment
        return ConnectionSettings(host: try #require(env["DBEER_TEST_MONGODB_HOST"]),
            port: try #require(Int(env["DBEER_TEST_MONGODB_PORT"] ?? "")),
            database: "dbeer_mongodb_ui", user: env["DBEER_TEST_MONGODB_USER"] ?? "",
            password: env["DBEER_TEST_MONGODB_PASSWORD"] ?? "", sslMode: env["DBEER_TEST_MONGODB_SSLMODE"] ?? "disable",
            sslRootCert: env["DBEER_TEST_MONGODB_SSLMODE"] == "verify-full" ? env["DBEER_TEST_MONGODB_CA"] : nil,
            engine: .mongodb, mongodb: MongoDBSettings())
    }

    private func workspace() -> ApplicationWorkspace {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"]!)
            .appendingPathComponent("artifacts-\(UUID().uuidString)")
        let snapshots = ResultSnapshotStore(rootURL: folder.appendingPathComponent("snapshots"))
        return ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false),
            resultSnapshots: ResultSnapshotsModel(store: snapshots),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .rollback }, executionDecision: { _ in true },
            helperFactory: { BackendClient(executableURL: executable) })
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
        var text: String? { value("accessibilityValue") }
        var button: NSButton? { (object as? NSButton) ?? ((object as? NSCell)?.controlView as? NSButton) }
        var field: NSTextField? { (object as? NSTextField) ?? ((object as? NSCell)?.controlView as? NSTextField) }
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
        for child in window.childWindows ?? [] where child !== window.attachedSheet { result += elements(child) }
        return result
    }

    private func element(_ id: String, _ window: NSWindow) throws -> Element {
        try #require(elements(window).first { $0.identifier == id }, "Missing native MongoDB control: \(id)")
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition(), Comment(rawValue: message))
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(180)) }

    private func press(_ id: String, _ window: NSWindow) async throws {
        let e = try element(id, window)
        if let button = e.button { try #require(button.isEnabled); button.performClick(nil) }
        else {
            let didPress = e.flag("accessibilityPerformPress")
            try #require(didPress, "Cannot press MongoDB control: \(id)")
        }
        try await settle()
    }

    private func enter(_ text: String, _ id: String, _ window: NSWindow) async throws {
        let field = try #require(element(id, window).field, "Missing native text field: \(id)")
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await settle()
    }

    private func choose(_ title: String, _ id: String, _ window: NSWindow) async throws {
        try await NativeThemeMenuActions.select(title, in: #require(element(id, window).button, "Missing native picker: \(id)"))
        try await settle()
    }

    private func window<V: View>(_ view: V, dark: Bool = true, width: Double = 1340, height: Double = 850) async throws -> NSWindow {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 60, width: width, height: height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DBeer MongoDB verification"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view.preferredColorScheme(dark ? .dark : .light))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        try await waitFor("The native verification window did not activate.") { window.makeKey(); return window.isKeyWindow }
        try await settle()
        return window
    }

    private func capture(_ window: NSWindow, _ name: String, includeChildren: Bool = false) async throws {
        guard #available(macOS 14.4, *) else { return }
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"]))
        let available = try await SCShareableContent.currentProcess
        let ownWindow = try #require(available.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2)
        configuration.height = Int(window.frame.height * 2)
        configuration.scalesToFit = true
        configuration.captureResolution = .best
        configuration.includeChildWindows = includeChildren
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent(name + ".png"))
    }

    private func key(_ code: UInt16, _ characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    @Test(arguments: ["dark", "light"])
    func connectionDocumentsFiltersAggregationAndTypes(_ theme: String) async throws {
        let workspace = workspace()
        await workspace.start()
        defer { Task { await workspace.shutdown() } }
        let window = try await window(ApplicationWorkspaceView(workspace: workspace), dark: theme == "dark")
        defer { window.attachedSheet?.orderOut(nil); window.close() }
        let settings = try settings()
        do {
            try await press("newConnection", window)
            try await waitFor("The new connection sheet did not open.") { window.attachedSheet != nil }
            try await choose("MongoDB", "connectionEngine", window)
            try await enter("MongoDB UI fixture", "connectionName", window)
            try await enter(settings.host, "Host", window)
            try await enter(String(settings.port), "Port", window)
            try await enter(settings.database, "Database", window)
            try await enter(settings.user, "User", window)
            try await enter(settings.password, "password", window)
            let sheet = try #require(window.attachedSheet)
            try await NativeConnectionEditorTabs.select("TLS", in: #require(sheet.contentView))
            try await choose(settings.sslMode, "sslMode", window)
            if let ca = settings.sslRootCert { try await enter(ca, "trustedCAFile", window) }
            try await press("testConnection", window)
            try await waitFor("The native MongoDB connection test did not succeed.") {
                elements(window).contains { ($0.label ?? $0.text ?? "").contains("Connection successful. Test session closed.") }
            }
            try await capture(sheet, "\(theme)-connection")
            try await press("saveAndConnect", window)
            try await waitFor("Save and Connect did not open the MongoDB session.") {
                window.attachedSheet == nil && workspace.library.savedConnections.first.map { workspace.services[$0.id]?.connectionState == .connected } == true
            }
            let profile = try #require(workspace.library.savedConnections.first)
            #expect(profile.engine == .mongodb)
            #expect(workspace.services[profile.id]?.transactionStatus == .unsupported)
            #expect(workspace.services[profile.id]?.supportsGridEditing == false)
            await workspace.loadSchemas(profile.id)
            if let content = window.contentView, let outline = descendants(content, NSOutlineView.self).first, outline.numberOfRows > 0 {
                outline.expandItem(outline.item(atRow: 0))
            }
            let database = try #require(workspace.catalogRoots[profile.id]?.first { $0.name == settings.database })
            database.isExpanded = true
            await workspace.expand(database)
            let collections = try #require(database.children?.first { $0.name == "Collections" })
            collections.isExpanded = true
            await workspace.expand(collections)
            let orders = try #require(collections.children?.first { $0.name == "orders" })
            let document = try #require(await workspace.openData(orders))
            try #require(document.runtime?.queryFailure == nil, "MongoDB document browsing failed.")
            try #require(document.grid?.rows.count == 200)
            try await settle()
            let content = try #require(window.contentView)
            let grid = try #require(descendants(content, ResultGridTableView.self).first)
            #expect(grid.numberOfRows == 200 && grid.numberOfColumns == 1)
            #expect(document.tableNextCursor != nil && document.grid?.canEdit == false)
            #expect(document.foreignKeysError == nil)
            #expect(!elements(window).contains { $0.identifier == "gridRelatedRows" })
            #expect(grid.tableColumns[0].width >= (grid.enclosingScrollView?.contentSize.width ?? 0) - 10)
            let point = grid.convert(NSPoint(x: grid.rect(ofColumn: 0).midX, y: grid.rect(ofRow: 0).midY), to: nil)
            grid.mouseDown(with: try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
            try await waitFor("The native BSON inspector did not display the selected document.") {
                descendants(content, NSTextView.self).contains { $0.accessibilityLabel() == "Inspected value" && $0.string.contains("$numberDecimal") }
            }
            let inspector = try #require(descendants(content, NSTextView.self).first { $0.accessibilityLabel() == "Inspected value" })
            try await waitFor("The native BSON formatter did not become available.") { elements(window).contains { $0.identifier == "valueInspectorFormatJSON" } }
            try await press("valueInspectorFormatJSON", window)
            try await waitFor("The native BSON formatter did not expand the document.") { inspector.string.contains("\n") }
            for tag in ["$oid", "$numberInt", "$numberLong", "$numberDecimal", "$date", "$binary", "$timestamp", "$minKey", "$maxKey"] {
                #expect(inspector.string.contains(tag), "Missing BSON type in the native inspector: \(tag)")
            }
            #expect(inspector.string.contains("9007199254740993") && inspector.string.contains("123456789.1234567890123456789"))
            try await capture(window, "\(theme)-documents-and-types")
            try await press("tableNextPage", window)
            try await waitFor("The native next-page control did not load the second page.") { !document.isRunning && document.page == 1 && document.grid?.rows.count == 200 }
            try await press("gridFilter", window)
            try await choose("index", "tableFilterColumn", window)
            try await choose("≥", "tableFilterOperator", window)
            try await enter("440", "tableFilterValue", window)
            try await press("tableAddFilter", window)
            try await waitFor("The native filter did not return ten documents.") { !document.isRunning && document.grid?.rows.count == 10 && document.page == 0 }
            try await choose("index", "mongoSortField", window)
            try await choose("Descending", "mongoSortDirection", window)
            try await press("mongoApplySort", window)
            try await waitFor("The native MongoDB sort did not finish.") { !document.isRunning && document.tableSort.first?.direction == "desc" }
            #expect(document.grid?.displayedRows.first?.first??.contains("449") == true)
            try await capture(window, "\(theme)-filtered-and-sorted")
            try await press("gridFilter", window)
            try await press("gridFilter", window)
            #expect(try element("mongoSortField", window).text == "index")
            #expect(try element("mongoSortDirection", window).text == "Descending")
            if let popover = window.childWindows?.first(where: { elements($0).contains { $0.identifier == "mongoApplySort" } }) {
                try await capture(popover, "\(theme)-filter-panel")
            }
            try await press("gridFilter", window)
            let generated = try #require(await workspace.openGeneratedSelect(orders))
            #expect(generated.text.contains("\"find\"") && generated.runtime == nil)
            let aggregate = workspace.newDocument(profileID: profile.id, text: """
            {"collection":"orders","aggregate":[
              {"$group":{"_id":"$category","count":{"$sum":1}}},
              {"$sort":{"_id":1}}
            ]}
            """)
            aggregate.title = "MongoDB aggregation"
            // Direct accessibility presses do not activate the parent window as a mouse click would.
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            try await waitFor("The editor window did not regain focus after closing its popover.") { window.isKeyWindow }
            try await settle()
            try await press("runQuery", window)
            try await waitFor("The native Run control did not finish the aggregation.") { aggregate.runtime != nil && !aggregate.isRunning }
            try #require(aggregate.runtime?.queryFailure == nil, "The aggregation failed through the native editor.")
            #expect(aggregate.runtime?.result?.rows?.count == 2)
            #expect(aggregate.runtime?.result?.commandTag == "AGGREGATE")
            try await capture(window, "\(theme)-aggregation")
            await workspace.shutdown()
        } catch {
            try? await capture(window.attachedSheet ?? window, "\(theme)-failure")
            throw error
        }
    }

    @MainActor private final class TextStorage {
        var text = ""
        var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
    }

    @Test func completionInNativeJSONEditorPreservesKeyboardAndUndo() async throws {
        let workspace = workspace()
        await workspace.start()
        defer { Task { await workspace.shutdown() } }
        try #require(await workspace.library.saveConnection(name: "MongoDB completion fixture", settings: settings()))
        let profile = try #require(workspace.library.selectedConnectionId)
        await workspace.connectProfile(profile)
        try #require(workspace.services[profile]?.connectionState == .connected, "The completion fixture did not connect.")
        let metadata = try await workspace.catalog(CatalogRequest(kind: "completion"), profileID: profile)
        try #require(metadata.truncated != true, "MongoDB completion metadata was marked truncated.")
        try #require(metadata.catalogRecords.contains { $0["name"] == "orders" && $0["columns"]?.contains("amount") == true }, "MongoDB completion metadata is missing sampled fields.")
        try await waitFor("Connected MongoDB metadata did not populate field completion.") {
            workspace.completionContext(profileID: profile).catalog.first { $0.name == "orders" }?.columns.contains("amount") == true
        }
        let context = workspace.completionContext(profileID: profile)
        let language = SQLLanguageService(helperURL: executable)
        defer { Task { await language.shutdown() } }
        let storage = TextStorage()
        let coordinator = SQLEditorView.Coordinator(text: storage.binding)
        let scroll = coordinator.makeScrollView()
        let window = try await window(EmptyView(), width: 950, height: 500)
        window.contentView = scroll
        defer { window.close() }
        let editor = try #require(scroll.documentView as? NSTextView)
        let historyCount = workspace.history.count
        let sessionCount = workspace.services.count
        for (prefix, suffix, label, replacement) in [
            (#"{"collection":""#, "ord", "orders", #""orders""#),
            (#"{"collection":"orders","find":{""#, "amo", "amount", #""amount": null"#),
            (#"{"collection":"orders","aggregate":[{""#, "$mat", "$match", #""$match": {}"#),
            (#"{"collection":"orders","find":{"amount":{""#, "$numberDec", "$numberDecimal", #""$numberDecimal": "0.00""#)
        ] {
            storage.text = prefix
            coordinator.update(text: storage.binding, isEditable: true, in: scroll, engine: .mongodb,
                languageService: language, completionContext: context)
            try #require(window.makeFirstResponder(editor))
            editor.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
            editor.insertText(suffix, replacementRange: editor.selectedRange())
            try await waitFor("Automatic JSON completion did not show \(label).") { coordinator.visibleCompletionLabels.contains(label) }
            #expect(!coordinator.visibleCompletionLabels.contains("SELECT"))
            let index = try #require(coordinator.visibleCompletionLabels.firstIndex(of: label))
            for _ in 0..<index { editor.keyDown(with: try key(125, "")) }
            try await settle()
            try await capture(window, "completion-\(label.replacingOccurrences(of: "$", with: ""))", includeChildren: true)
            editor.keyDown(with: try key(48, "\t"))
            #expect(storage.text.hasSuffix(replacement), "Completion did not insert valid JSON for \(label).")
            #expect(window.firstResponder === editor)
            editor.undoManager?.undo()
            #expect(!storage.text.hasSuffix(replacement), "Completion insertion could not be undone.")
        }
        #expect(workspace.history.count == historyCount && workspace.services.count == sessionCount)
        await language.shutdown()
        await workspace.shutdown()
    }
}
