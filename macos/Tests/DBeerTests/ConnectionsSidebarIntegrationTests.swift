import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Exercises the real SwiftUI sidebar and sheets in a local AppKit window.
/// Metadata uses a temporary file and passwords use an injected in-memory vault;
/// these tests neither access the login Keychain nor need Accessibility permission.
@Suite(.serialized)
@MainActor
struct ConnectionsSidebarIntegrationTests {
    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private func helper() -> BackendClient {
        helper(gate: nil)
    }

    private func helper(gate: URL?, catalogGate: URL? = nil) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time
        from pathlib import Path
        for line in sys.stdin:
            command = json.loads(line)
            reply = {'requestId': command['requestId']}
            kind = command['type']
            if kind == 'hello':
                reply.update(type='hello.ack', protocolVersion=4)
            elif kind == 'connect':
                if len(sys.argv) > 1 and sys.argv[1]:
                    deadline = time.monotonic() + 5
                    while not Path(sys.argv[1]).exists() and time.monotonic() < deadline:
                        time.sleep(.005)
                if command['connection']['host'] == 'reject.test':
                    reply.update(type='error', category='connection', message='Connection refused.', connected=False, outcomeUnknown=False)
                else:
                    reply.update(type='connect.result', engine='postgresql', capabilities=['execute','cancel','transactions','catalog'], sessionId='sidebar-test-session', transactionStatus='idle')
            elif kind == 'catalog':
                if len(sys.argv) > 2 and sys.argv[2]:
                    deadline = time.monotonic() + 5
                    while not Path(sys.argv[2]).exists() and time.monotonic() < deadline:
                        time.sleep(.005)
                print(json.dumps({'type':'query.started', 'requestId':command['requestId'],
                    'sessionId':command['sessionId'], 'queryId':command['queryId']}), flush=True)
                reply.update(type='query.result', sessionId=command['sessionId'], queryId=command['queryId'], transactionStatus='idle',
                    columns=[{'index':0, 'name':'name', 'engine':'postgresql', 'nativeType':'text'}], rows=[['public']],
                    durationMs=1, commandTag='SELECT 1', rowCount=1, displayedRowCount=1, truncated=False)
            elif kind == 'disconnect':
                reply.update(type='disconnect.ack', sessionId=command['sessionId'])
            elif kind == 'shutdown':
                reply.update(type='shutdown.ack')
            else:
                sys.exit(21)
            print(json.dumps(reply), flush=True)
            if kind == 'shutdown':
                break
        """, gate?.path ?? "", catalogGate?.path ?? ""])
    }

    private func window(for model: WorkspaceModel) -> NSWindow {
        window(for: WorkspaceView(model: model))
    }

    private func window<Content: View>(for view: Content) -> NSWindow {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DBeer saved connections verification"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.preferredColorScheme(.dark))
        window.orderFront(nil)
        return window
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(100)) }

    private func waitFor(_ condition: () -> Bool, _ failure: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard condition() else { throw TestFailure(failure) }
        try await settle()
    }

    /// SwiftUI's virtual accessibility nodes implement Objective-C selectors but
    /// do not all declare NSAccessibilityProtocol conformance. Duck-typing the
    /// same native methods keeps traversal inside this test window.
    private struct NativeElement {
        let object: NSObject

        func objectValue<T>(_ selectorName: String) -> T? {
            let selector = NSSelectorFromString(selectorName)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue() as? T
        }

        func boolValue(_ selectorName: String, default fallback: Bool = false) -> Bool {
            let selector = NSSelectorFromString(selectorName)
            guard object.responds(to: selector) else { return fallback }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }

        func accessibilityIdentifier() -> String? { objectValue("accessibilityIdentifier") }
        func accessibilityChildren() -> [Any] { objectValue("accessibilityChildren") ?? [] }
        func isAccessibilityEnabled() -> Bool { boolValue("isAccessibilityEnabled", default: true) }
        func accessibilityPerformPress() -> Bool { boolValue("accessibilityPerformPress") }

    }

    private func elements(in window: NSWindow) -> [NativeElement] {
        var result: [NativeElement] = []
        var visited: Set<ObjectIdentifier> = []
        func visit(_ object: AnyObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let object = object as? NSObject {
                let accessible = NativeElement(object: object)
                result.append(accessible)
                for child in accessible.accessibilityChildren() { visit(child as AnyObject) }
            }
            if let view = object as? NSView { view.subviews.forEach { visit($0) } }
        }
        visit(window)
        if let content = window.contentView { visit(content) }
        if let sheet = window.attachedSheet {
            visit(sheet)
            if let content = sheet.contentView { visit(content) }
        }
        return result
    }

    private func element(_ identifier: String, in window: NSWindow) throws -> NativeElement {
        guard let element = elements(in: window).first(where: { $0.accessibilityIdentifier() == identifier }) else {
            throw TestFailure("Native workspace element is missing: \(identifier)")
        }
        return element
    }

    private func press(_ identifier: String, in window: NSWindow) async throws {
        let button = try element(identifier, in: window)
        let nativeButton = (button.object as? NSButton) ?? ((button.object as? NSCell)?.controlView as? NSButton)
        if let nativeButton, nativeButton.isEnabled {
            nativeButton.performClick(nil)
        } else {
            guard button.isAccessibilityEnabled(), button.accessibilityPerformPress() else {
                throw TestFailure("Native workspace action could not be invoked: \(identifier) (\(type(of: button.object)))")
            }
        }
        try await settle()
    }

    private func enter(_ value: String, into identifier: String, in window: NSWindow) async throws {
        let field = try element(identifier, in: window)
        let nativeField = (field.object as? NSTextField) ?? ((field.object as? NSCell)?.controlView as? NSTextField)
        guard let nativeField else { throw TestFailure("The native text control is missing: \(identifier)") }
        nativeField.stringValue = value
        nativeField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: nativeField))
        try await settle()
    }

    private func fillProfile(name: String, database: String, password: String, in window: NSWindow) async throws {
        try await enter(name, into: "connectionName", in: window)
        try await enter("127.0.0.1", into: "Host", in: window)
        try await enter("54329", into: "Port", in: window)
        try await enter(database, into: "Database", in: window)
        try await enter("dbeer", into: "User", in: window)
        try await enter(password, into: "password", in: window)
    }

    private func capture(_ window: NSWindow, named name: String = "connections-sidebar") throws {
        guard let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"], !directory.isEmpty,
              let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try png.write(to: destination.appendingPathComponent("\(name).png"))
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func contextMenu(for row: Int, in window: NSWindow) throws -> NSMenu {
        let content = try #require(window.contentView)
        let list = try #require(descendants(content, of: NSTableView.self).first)
        let region = try #require(descendants(content, of: CatalogContextMenuView.self).first)
        let rowRect = list.rect(ofRow: row)
        let location = list.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(region.menu(for: event))
        menu.update()
        return menu
    }

    private func pressMenuItem(_ title: String, for row: Int, in window: NSWindow) async throws {
        let menu = try contextMenu(for: row, in: window)
        let item = try #require(menu.item(withTitle: title))
        #expect(item.isEnabled)
        guard item.isEnabled else { throw TestFailure("Disabled context menu action: \(title)") }
        menu.performActionForItem(at: menu.index(of: item))
        try await settle()
    }

    @Test func headerEngineMenuSelectsMySQLAndSavesItsDefaults() async throws {
        let model = WorkspaceModel(helperFactory: helper, connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        await model.start()
        var closed = false
        let window = window(for: ConnectionEditorView(model: model, connection: nil) { closed = true })
        window.setContentSize(NSSize(width: 520, height: 680))
        defer { window.close(); Task { await model.shutdown() } }
        try await settle()

        let engine = try element("connectionEngine", in: window)
        let button = try #require((engine.object as? NSButton) ?? ((engine.object as? NSCell)?.controlView as? NSButton))
        let selectorSize = button.frame.size
        #expect(selectorSize.width <= 80 && selectorSize.height <= 48)
        try capture(window)
        var selectedMySQL = false
        // Menu tracking may be entered from a main-queue job; another main-
        // queue job cannot reliably run inside that nested tracking loop.
        let selectionTimer = Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let menu = button.menu else { return }
                #expect(menu.item(withTitle: "PostgreSQL") != nil)
                if let mysql = menu.item(withTitle: "MySQL") {
                    menu.performActionForItem(at: menu.index(of: mysql))
                    selectedMySQL = true
                }
                menu.cancelTrackingWithoutAnimation()
            }
        }
        RunLoop.main.add(selectionTimer, forMode: .eventTracking)
        defer { selectionTimer.invalidate() }
        button.performClick(nil)
        try await settle()
        try #require(selectedMySQL)
        try capture(window, named: "connection-editor-mysql")
        try await enter("MySQL fixture", into: "connectionName", in: window)
        try await press("saveConnection", in: window)
        let saved = try #require(model.savedConnections.first)
        #expect(closed)
        #expect(saved.engine == .mysql && saved.port == 3306)
        #expect(saved.database == "mysql" && saved.user == "root")
        await model.shutdown()
    }

    @Test func workspaceDisclosureWaitsForConnectionAndKeepsFailedProfilesCollapsed() async throws {
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: gate) }
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), helperFactory: { helper(gate: gate) })
        await workspace.start()
        var settings = ConnectionSettings(host: "localhost", port: 5432, database: "fixture",
            user: "fixture", password: "", sslMode: "disable")
        try #require(await workspace.library.saveConnection(name: "Works", settings: settings))
        let first = try #require(workspace.library.selectedConnectionId)
        settings.host = "reject.test"
        try #require(await workspace.library.saveConnection(name: "Fails", settings: settings))
        let failed = try #require(workspace.library.selectedConnectionId)
        let window = window(for: ApplicationWorkspaceView(workspace: workspace))
        defer { window.close(); Task { await workspace.shutdown() } }
        try await settle()

        let content = try #require(window.contentView)
        let outline = try #require(descendants(content, of: NSTableView.self).first as? NSOutlineView)
        let firstItem = try #require(outline.item(atRow: 0))
        #expect(outline.isExpandable(firstItem))
        outline.expandItem(firstItem)
        try await waitFor({ workspace.services[first]?.connectionState == .connecting }, "Disclosure did not start connecting.")
        #expect(outline.numberOfRows == 2)
        #expect(!outline.isItemExpanded(firstItem))
        try Data().write(to: gate)
        try await waitFor({ workspace.catalogRoots[first]?.first?.name == "public" && outline.numberOfRows == 3 },
            "The connected profile did not expand.")
        #expect(workspace.services[first]?.connectionState == .connected)
        #expect(outline.isItemExpanded(firstItem))

        try #require(await workspace.disconnectProfile(first))
        try await waitFor({ outline.numberOfRows == 2 }, "Disconnect did not collapse the profile.")
        #expect(outline.isExpandable(firstItem))
        let failedItem = try #require(outline.item(atRow: 1))
        #expect(outline.isExpandable(failedItem))
        outline.expandItem(failedItem)
        try await waitFor({ workspace.error != nil && window.attachedSheet != nil }, "A connection error was not shown.")
        #expect(workspace.services[failed]?.connectionState == .disconnected)
        #expect(!outline.isItemExpanded(failedItem))
        #expect(outline.numberOfRows == 2)
        window.attachedSheet?.endEditing(for: nil)
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        await workspace.shutdown()
    }

    @Test func connectedStatusStaysInPlaceWhileDisclosureLoadsSchemas() async throws {
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: gate) }
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), helperFactory: { helper(gate: nil, catalogGate: gate) })
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "fixture",
            user: "fixture", password: "", sslMode: "disable")
        try #require(await workspace.library.saveConnection(name: "Connected", settings: settings))
        let profileID = try #require(workspace.library.selectedConnectionId)
        await workspace.connectProfile(profileID)
        try #require(workspace.services[profileID]?.connectionState == .connected)
        let window = window(for: ApplicationWorkspaceView(workspace: workspace))
        defer { window.close(); Task { await workspace.shutdown() } }
        try await settle()
        let content = try #require(window.contentView)
        let outline = try #require(descendants(content, of: NSTableView.self).first as? NSOutlineView)
        let item = try #require(outline.item(atRow: 0))
        let policy = NativeButtonFocusPolicy()
        policy.start()
        policy.apply(to: window)

        func statusCenter() throws -> NSPoint {
            let rect = outline.rect(ofRow: 0)
            let bitmap = try #require(outline.bitmapImageRepForCachingDisplay(in: rect))
            outline.cacheDisplay(in: rect, to: bitmap)
            var pixels: [NSPoint] = []
            for y in 0..<bitmap.pixelsHigh {
                for x in (bitmap.pixelsWide / 2)..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.greenComponent > color.redComponent + 0.2,
                          color.greenComponent > color.blueComponent + 0.1 else { continue }
                    pixels.append(NSPoint(x: CGFloat(x), y: CGFloat(y)))
                }
            }
            try #require(!pixels.isEmpty, "The connected status dot must stay visible.")
            return NSPoint(x: pixels.map(\.x).reduce(0, +) / CGFloat(pixels.count),
                y: pixels.map(\.y).reduce(0, +) / CGFloat(pixels.count))
        }

        let initial = try statusCenter()
        outline.expandItem(item)
        try await waitFor({ outline.isItemExpanded(item) }, "The profile did not expand.")
        let loading = try statusCenter()
        #expect(abs(initial.x - loading.x) < 1)
        #expect(abs(initial.y - loading.y) < 1)
        try Data().write(to: gate)
        try await waitFor({ workspace.catalogRoots[profileID] != nil }, "The schema load did not finish.")
        let loaded = try statusCenter()
        #expect(abs(initial.x - loaded.x) < 1)
        #expect(abs(initial.y - loaded.y) < 1)

        func disclosureButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title.isEmpty { return button }
            return view.subviews.lazy.compactMap { disclosureButton(in: $0) }.first
        }
        // Sample real disclosure-button animations, rather than waiting for
        // their final layout. Keep the row highlighted in captured frames.
        for transition in 0..<4 {
            let row = try #require(outline.rowView(atRow: 0, makeIfNecessary: true))
            let feedback = try #require(CatalogRowHoverAnchor.feedback(containing: row))
            feedback.isHovered = true
            feedback.isKeyboardFocused = true
            let button = try #require(disclosureButton(in: row))
            button.performClick(nil)
            for frame in 0..<12 {
                try await Task.sleep(for: .milliseconds(16))
                let center = try statusCenter()
                #expect(abs(initial.x - center.x) < 1)
                #expect(abs(initial.y - center.y) < 1)
                let activeRow = try #require(outline.rowView(atRow: 0, makeIfNecessary: true))
                let activeFeedback = try #require(CatalogRowHoverAnchor.feedback(containing: activeRow))
                #expect(activeFeedback.isDescendant(of: activeRow))
                let paint = activeFeedback.convert(activeFeedback.feedbackRect, to: outline)
                let bounds = activeRow.convert(activeRow.bounds, to: outline)
                #expect(bounds.contains(paint))
                if frame == 2, let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] {
                    let rect = NSRect(x: 0, y: 0, width: outline.bounds.width, height: 150)
                    let bitmap = try #require(outline.bitmapImageRepForCachingDisplay(in: rect))
                    outline.cacheDisplay(in: rect, to: bitmap)
                    let destination = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    try bitmap.representation(using: .png, properties: [:])?.write(
                        to: destination.appendingPathComponent("catalog-disclosure-transition-\(transition).png"))
                }
            }
        }
        await workspace.shutdown()
    }

    @Test func workspaceContextMenuFollowsConnectionStateAndImportSheetHonorsCheckboxes() async throws {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), helperFactory: helper)
        await workspace.start()
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "fixture",
            user: "fixture", password: "", sslMode: "disable")
        try #require(await workspace.library.saveConnection(name: "First", settings: settings))
        let first = try #require(workspace.library.selectedConnectionId)
        var mysqlSettings = settings
        mysqlSettings.engine = .mysql
        mysqlSettings.port = 3306
        try #require(await workspace.library.saveConnection(name: "Second", settings: mysqlSettings))
        let window = window(for: ApplicationWorkspaceView(workspace: workspace))
        defer { window.close(); Task { await workspace.shutdown() } }
        try await settle()

        let disconnected = try contextMenu(for: 0, in: window)
        #expect(disconnected.item(withTitle: "Connect")?.isEnabled == true)
        #expect(disconnected.item(withTitle: "Disconnect") == nil)
        #expect(disconnected.item(withTitle: "Export Connection…")?.isEnabled == true)
        try await pressMenuItem("Connect", for: 0, in: window)
        try await waitFor({ workspace.services[first]?.connectionState == .connected }, "The profile did not connect.")
        try capture(window)
        let connected = try contextMenu(for: 0, in: window)
        #expect(connected.item(withTitle: "Connect") == nil)
        #expect(connected.item(withTitle: "Disconnect")?.isEnabled == true)
        let other = try contextMenu(for: 1, in: window)
        #expect(other.item(withTitle: "Connect")?.isEnabled == true)
        #expect(other.item(withTitle: "Disconnect") == nil)
        try await pressMenuItem("Disconnect", for: 0, in: window)
        try await waitFor({ workspace.services[first] == nil }, "The profile did not disconnect.")
        #expect(try contextMenu(for: 0, in: window).item(withTitle: "Disconnect") == nil)

        let preview = try ProfileTransfer.preview(ProfileTransfer.encode(workspace.library.savedConnections))
        workspace.importPreview = preview
        try await waitFor({ window.attachedSheet != nil }, "The import sheet did not open.")
        try await press("deselectAllImportProfiles", in: window)
        #expect(workspace.selectedImportProfiles.isEmpty)
        #expect(try !element("importSelectedProfiles", in: window).isAccessibilityEnabled())
        try await press("selectAllImportProfiles", in: window)
        #expect(workspace.selectedImportProfiles.count == 2)
        try await press("import-profile-\(preview[0].id.uuidString)", in: window)
        #expect(workspace.selectedImportProfiles.map(\.id) == [preview[1].id])
        try await press("importSelectedProfiles", in: window)
        try await waitFor({ window.attachedSheet == nil }, "The import sheet did not close.")
        #expect(workspace.library.savedConnections.count == 3)
        #expect(workspace.library.savedConnections.filter { $0.name == "First" }.count == 1)
        #expect(workspace.library.savedConnections.filter { $0.name == "Second" }.count == 2)
        await workspace.shutdown()
    }

    @Test func nativeCreateEditSelectConnectDeleteAndReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-sidebar-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("connections.json")
        let store = FileConnectionLibraryStore(fileURL: file)
        let vault = MemoryConnectionCredentialStore()
        let model = WorkspaceModel(helperFactory: helper, connectionStore: store, credentialStore: vault)
        await model.start()
        let window = window(for: model)
        defer { window.close() }
        do {
            try await settle()
            _ = try element("connectionsSidebar", in: window)
            try await press("newConnection", in: window)
            _ = try element("connectionEditor", in: window)
            #expect(try !element("saveConnection", in: window).isAccessibilityEnabled())
            let firstPassword = UUID().uuidString
            try await fillProfile(name: "Local playground", database: "dbeer", password: firstPassword, in: window)
            try await enter("65536", into: "Port", in: window)
            #expect(try !element("saveConnection", in: window).isAccessibilityEnabled())
            try await enter("54329", into: "Port", in: window)
            try await press("saveConnection", in: window)
            try await waitFor({ model.savedConnections.count == 1 && window.attachedSheet == nil }, "New profile was not saved from its native sheet.")
            let first = try #require(model.savedConnections.first)
            #expect(first.name == "Local playground")
            #expect(model.selectedConnectionId == first.id)
            let savedList = try #require(window.contentView.flatMap { descendants($0, of: NSTableView.self).first })
            #expect(savedList.numberOfRows == 2)
            let firstPasswordMatches = await vault.password(for: first.id) == firstPassword
            #expect(firstPasswordMatches)

            try await pressMenuItem("Edit Connection…", for: 1, in: window)
            let changedPassword = UUID().uuidString
            try await enter("Local PostgreSQL", into: "connectionName", in: window)
            try await enter(changedPassword, into: "password", in: window)
            try await press("saveConnection", in: window)
            try await waitFor({ model.savedConnections.first?.name == "Local PostgreSQL" && window.attachedSheet == nil }, "Edit did not update the existing profile.")
            #expect(model.savedConnections.first?.id == first.id)
            let changedPasswordMatches = await vault.password(for: first.id) == changedPassword
            #expect(changedPasswordMatches)

            try await press("newConnection", in: window)
            try await fillProfile(name: "Reporting", database: "reporting", password: UUID().uuidString, in: window)
            try await press("saveAndConnect", in: window)
            try await waitFor({ model.savedConnections.count == 2 && model.connectionState == .connected }, "Save and Connect did not open the new profile.")
            let second = try #require(model.savedConnections.last)
            #expect(model.activeConnectionId == second.id)
            _ = try element("connectionsSidebar", in: window)
            let activeMenu = try contextMenu(for: 2, in: window)
            #expect(activeMenu.item(withTitle: "Connect") == nil)
            #expect(try #require(activeMenu.item(withTitle: "Disconnect")).isEnabled)
            #expect(try !#require(activeMenu.item(withTitle: "Delete Connection…")).isEnabled)

            // The real native List owns selection. Selecting another profile must
            // leave the live database fields and active session attached to Reporting.
            let content = try #require(window.contentView)
            let list = try #require(descendants(content, of: NSTableView.self).first)
            #expect(list.numberOfRows == 3)
            list.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            try await waitFor({ model.selectedConnectionId == first.id }, "Native sidebar selection did not select the saved profile.")
            #expect(model.activeConnectionId == second.id)
            #expect(model.database == "reporting")
            let inactiveMenu = try contextMenu(for: 1, in: window)
            #expect(inactiveMenu.item(withTitle: "Disconnect") == nil)
            #expect(try !#require(inactiveMenu.item(withTitle: "Connect")).isEnabled)
            try capture(window)

            let metadata = try Data(contentsOf: file)
            let metadataText = String(decoding: metadata, as: UTF8.self)
            let noSecretInMetadata = !metadataText.contains(firstPassword) && !metadataText.contains(changedPassword) && !metadataText.contains("\"password\"")
            #expect(noSecretInMetadata)
            try await pressMenuItem("Disconnect", for: 2, in: window)
            try await waitFor({ model.connectionState == .disconnected }, "Disconnect did not release the active saved profile.")
            try await pressMenuItem("Connect", for: 1, in: window)
            try await waitFor({ model.activeConnectionId == first.id && model.connectionState == .connected }, "The selected profile did not connect after Disconnect.")
            try await pressMenuItem("Disconnect", for: 1, in: window)
            try await waitFor({ model.connectionState == .disconnected }, "Second Disconnect did not finish.")
            try await pressMenuItem("Delete Connection…", for: 1, in: window)
            try await press("deleteConnection", in: window)
            try await waitFor({ model.savedConnections.count == 1 && window.attachedSheet == nil }, "Delete confirmation did not remove the saved profile.")
            let deletedPasswordMissing = await vault.password(for: first.id) == nil
            #expect(deletedPasswordMissing)
            #expect(model.savedConnections.first?.id == second.id)
            await model.shutdown()

            // A fresh workspace reloads metadata and selection with the same vault,
            // but does not open a PostgreSQL session merely because a profile exists.
            let reopened = WorkspaceModel(helperFactory: helper,
                connectionStore: FileConnectionLibraryStore(fileURL: file), credentialStore: vault)
            await reopened.start()
            #expect(reopened.savedConnections.count == 1)
            #expect(reopened.savedConnections.first?.id == second.id)
            #expect(reopened.selectedConnectionId == second.id)
            #expect(reopened.connectionState == .disconnected)
            #expect(reopened.activeConnectionId == nil)
            await reopened.shutdown()
        } catch {
            await model.shutdown()
            throw error
        }
    }

    private actor UnavailableVault: ConnectionCredentialStore {
        func password(for id: UUID) -> String? { nil }
        func savePassword(_ password: String, for id: UUID) throws { throw ConnectionLibraryError.credentialWrite }
        func deletePassword(for id: UUID) {}
    }

    @Test func nativeSaveFailureKeepsDraftForRetryOrCancel() async throws {
        let model = WorkspaceModel(helperFactory: helper, credentialStore: UnavailableVault())
        await model.start()
        let window = window(for: model)
        defer { window.close() }
        do {
            try await settle()
            try await press("newConnection", in: window)
            try await fillProfile(name: "Cannot save yet", database: "dbeer", password: UUID().uuidString, in: window)
            try await press("saveConnection", in: window)
            try await waitFor({ model.connectionsError != nil && !model.isSavingConnection }, "Credential failure did not reach the editor.")
            _ = try element("connectionEditorError", in: window)
            #expect(window.attachedSheet != nil)
            #expect(model.savedConnections.isEmpty)
            #expect(try element("saveConnection", in: window).isAccessibilityEnabled())
            try await press("cancelConnectionEditor", in: window)
            try await waitFor({ window.attachedSheet == nil }, "Cancel did not close the failed-save draft.")
            #expect(model.savedConnections.isEmpty)
            await model.shutdown()
        } catch {
            await model.shutdown()
            throw error
        }
    }

    private actor TemporarilyLockedVault: ConnectionCredentialStore {
        private var secrets: [UUID: String] = [:]
        private var rejectsNextRead = false

        func rejectNextRead() { rejectsNextRead = true }
        func password(for id: UUID) throws -> String? {
            if rejectsNextRead {
                rejectsNextRead = false
                throw ConnectionLibraryError.credentialRead
            }
            return secrets[id]
        }
        func savePassword(_ password: String, for id: UUID) { secrets[id] = password }
        func deletePassword(for id: UUID) { secrets[id] = nil }
        func hasPassword(_ password: String, for id: UUID) -> Bool { secrets[id] == password }
    }

    @Test func nativeEditCannotOverwritePasswordAfterFailedKeychainRead() async throws {
        let vault = TemporarilyLockedVault()
        let secret = UUID().uuidString
        let profile = SavedConnection(name: "Locked credential", settings: ConnectionSettings(
            host: "127.0.0.1", port: 54329, database: "dbeer", user: "dbeer", password: "", sslMode: "disable"))
        await vault.savePassword(secret, for: profile.id)
        let store = MemoryConnectionLibraryStore(library: SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id))
        let model = WorkspaceModel(helperFactory: helper, connectionStore: store, credentialStore: vault)
        await model.start()
        let window = window(for: model)
        defer { window.close() }
        do {
            try await settle()
            await vault.rejectNextRead()
            try await pressMenuItem("Edit Connection…", for: 1, in: window)
            try await waitFor({ model.connectionsError != nil }, "Credential read failure did not reach the edit form.")
            _ = try element("connectionEditorError", in: window)
            #expect(try !element("saveConnection", in: window).isAccessibilityEnabled())
            try await enter("Renamed safely", into: "connectionName", in: window)
            #expect(try !element("saveConnection", in: window).isAccessibilityEnabled())
            let preservedAfterFailure = await vault.hasPassword(secret, for: profile.id)
            #expect(preservedAfterFailure)
            try await press("retryConnectionPassword", in: window)
            try await waitFor({ (try? element("saveConnection", in: window).isAccessibilityEnabled()) == true }, "Retry did not unlock Save after reading the password.")
            try await press("saveConnection", in: window)
            try await waitFor({ model.savedConnections.first?.name == "Renamed safely" && window.attachedSheet == nil }, "Rename after password retry did not save.")
            let preservedAfterSave = await vault.hasPassword(secret, for: profile.id)
            #expect(preservedAfterSave)
            #expect(model.savedConnections.first?.id == profile.id)
            await model.shutdown()
        } catch {
            await model.shutdown()
            throw error
        }
    }

}
