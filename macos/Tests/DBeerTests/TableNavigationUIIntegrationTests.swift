import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Production catalog menus, workspace controls and grid selection in owned
/// windows. The framed transport and persistent/credential stores are isolated;
/// live database correctness is covered by the separate adapter matrix.
@Suite(.serialized)
@MainActor
struct TableNavigationUIIntegrationTests {
    private struct Element {
        let object: NSObject
        func value<T>(_ name: String) -> T? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? T : nil
        }
        var identifier: String? { value("accessibilityIdentifier") }
        var button: NSButton? { (object as? NSButton) ?? ((object as? NSCell)?.controlView as? NSButton) }
    }

    private final class Transport {
        let directory: URL
        let client: BackendClient
        init() throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            directory = root.appendingPathComponent("build/closeout/table-transport-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: directory.appendingPathComponent("events"))
            client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
            import json, sys
            from pathlib import Path
            directory, prefix = Path(sys.argv[1]), sys.argv[2]
            connections = 0
            def record(value):
                with (directory / 'events').open('a') as output: output.write(value+'\\n')
            def columns(names):
                return [dict(index=i,name=name,engine='postgresql',nativeType='text') for i,name in enumerate(names)]
            for line in sys.stdin:
                command = json.loads(line)
                kind = command['type']
                reply = dict(requestId=command['requestId'])
                if kind == 'hello': reply.update(type='hello.ack',protocolVersion=\(BackendProtocol.version))
                elif kind == 'connect':
                    connections += 1
                    session = prefix+'-'+str(connections)
                    record('connect:'+session)
                    reply.update(type='connect.result',sessionId=session,engine='postgresql',transactionStatus='idle',
                        capabilities=['execute','cancel','catalog','transactions','gridEditing'])
                elif kind == 'operation.assess':
                    reply.update(type='operation.assessment',sessionId=command['sessionId'],queryId=command['queryId'],
                        assessment=dict(decision='allow',policy=dict(environment='unspecified',readOnly=False),authorization='fixture-grant',
                            operations=[dict(kind='read',statements=[]) for _ in command['operations']]))
                elif kind == 'catalog':
                    print(json.dumps(dict(type='query.started',requestId=command['requestId'],sessionId=command['sessionId'],queryId=command['queryId'])),flush=True)
                    request = command['catalog']
                    operation, table = request['kind'], request.get('object','')
                    record(operation+':'+table+':'+command['sessionId']+':'+str(request.get('page',0)))
                    names, rows = [], []
                    if operation == 'columns':
                        fields = [('tenant','text','1'),('id','bigint','2'),('label','text','0')] if table == 'customers' else [
                            ('id','bigint','1'),('tenant_id','text','0'),('customer_id','bigint','0'),('note','text','0')]
                        names = ['name','nativeType','nullable','primaryKey','editable']
                        rows = [[name,native,'false',primary,'true'] for name,native,primary in fields]
                    elif operation == 'foreignKeys':
                        names = ['name','targetSchema','targetTable','sourceColumn','targetColumn','position']
                        if table == 'orders': rows = [
                            ['orders_customer_fk','linked schema','customers','customer_id','id','2'],
                            ['orders_customer_fk','linked schema','customers','tenant_id','tenant','1']]
                    elif operation == 'browse':
                        if table == 'customers':
                            assert request.get('filters',[]) == [dict(column='tenant',operator='eq',value=''),dict(column='id',operator='eq',value='9007199254740993')]
                            names,rows = ['tenant','id','label'], [['','9007199254740993','linked exact parent']]
                        else:
                            names = ['id','tenant_id','customer_id','note']
                            start = request.get('page',0)*200
                            rows = [[str(start+i+1),'','9007199254740993','order '+str(start+i+1)] for i in range(200)]
                    reply.update(type='query.result',sessionId=command['sessionId'],queryId=command['queryId'],transactionStatus='idle',
                        durationMs=1,columns=columns(names),rows=rows,rowCount=len(rows),displayedRowCount=len(rows),
                        commandTag='SELECT '+str(len(rows)),truncated=False)
                elif kind == 'disconnect':
                    record('disconnect:'+command['sessionId'])
                    reply.update(type='disconnect.ack',sessionId=command['sessionId'])
                elif kind == 'cancel': reply.update(type='cancel.ack',sessionId=command['sessionId'],queryId=command['queryId'],status='alreadyFinished')
                elif kind == 'shutdown': reply.update(type='shutdown.ack')
                else: sys.exit(42)
                print(json.dumps(reply),flush=True)
                if kind == 'shutdown': break
            """, directory.path, UUID().uuidString])
        }
        func events() throws -> [String] {
            try String(contentsOf: directory.appendingPathComponent("events"), encoding: .utf8).split(separator: "\n").map(String.init)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func elements(_ window: NSWindow) -> [Element] {
        var seen = Set<ObjectIdentifier>()
        var result: [Element] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
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
        try #require(elements(window).first { $0.identifier == id }, "Missing table navigation control: \(id)")
    }

    private func wait(_ reason: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), Comment(rawValue: reason))
        try await Task.sleep(for: .milliseconds(120))
    }

    private func press(_ id: String, _ window: NSWindow) async throws {
        let target = try element(id, window)
        if let button = target.button {
            try #require(button.isEnabled)
            button.performClick(nil)
        } else {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            try #require(target.object.responds(to: selector))
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            try #require(unsafeBitCast(target.object.method(for: selector), to: Press.self)(target.object, selector))
        }
        try await Task.sleep(for: .milliseconds(120))
    }

    private func host<V: View>(_ view: V, theme: String, width: CGFloat, height: CGFloat = 760) async throws -> NSWindow {
        let application = NSApplication.shared
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 70, y: 70, width: width, height: height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DBeer table navigation verification"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view.preferredColorScheme(theme == "dark" ? .dark : .light))
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(200))
        return window
    }

    private func capture(_ window: NSWindow, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path).appendingPathComponent("closeout")
        try await NativeOwnedWindowCapture.write(window, to: directory.appendingPathComponent(name + ".png"))
    }

    /// Request the real row's production menu at its native geometry and perform
    /// its actual NSMenuItem action; no workspace navigation method is called.
    private func catalogAction(_ title: String, in window: NSWindow) throws {
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let table = try #require(descendants(content, of: NSOutlineView.self).first)
        let region = try #require(descendants(content, of: CatalogContextMenuView.self).first)
        try #require(table.numberOfRows == 1)
        let rect = table.rect(ofRow: 0)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(region.menu(for: event))
        menu.update()
        let item = try #require(menu.item(withTitle: title))
        try #require(item.isEnabled)
        menu.performActionForItem(at: menu.index(of: item))
    }

    private func selectFirstRow(_ document: SQLDocument, in window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let content = try #require(window.contentView)
        let table = try #require(descendants(content, of: ResultGridTableView.self).first { $0.appCommandDocumentID == document.id })
        try #require(table.numberOfRows > 0 && table.numberOfColumns > 0)
        let rect = table.frameOfCell(atColumn: 0, row: 0)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        table.mouseDown(with: event)
        try await wait("Native row selection was not published to the table draft.") { document.grid?.selectedRows == IndexSet(integer: 0) }
    }

    @Test(arguments: ["light", "dark"])
    func nativeTableMenusForeignKeysReopenAndRestartPreserveIndependentViews(_ theme: String) async throws {
        let transport = try Transport()
        let settings = ConnectionSettings(host: "fixture.invalid", port: 5432, database: "fixture", user: "reader", password: "", sslMode: "disable")
        let profile = SavedConnection(name: "Native navigation fixture", settings: settings)
        let library = MemoryConnectionLibraryStore(library: SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id))
        let defaultsName = "dev.dbeer.tests.table-navigation-ui." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = MemorySQLDocumentStore()
        let snapshots = ResultSnapshotStore(rootURL: transport.directory.appendingPathComponent("snapshots"))
        let themes = EditorThemeStore(defaults: defaults, directory: transport.directory.appendingPathComponent("themes"))
        let workspace = ApplicationWorkspace(connectionStore: library, credentialStore: MemoryConnectionCredentialStore(),
            documentStore: store, commandShortcuts: AppShortcutStore(defaults: defaults),
            copySettings: ResultCopySettings(defaults: defaults), editorThemes: themes,
            appearance: AppAppearance(defaults: defaults, editorThemes: themes),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false),
            resultSnapshots: ResultSnapshotsModel(store: snapshots),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots), automaticallyWatchFiles: false,
            closeDecision: { _ in .discard }, helperFactory: { transport.client })
        await workspace.start()
        defer { Task { await workspace.shutdown() } }
        // Normal startup creates a disconnected SQL draft. Keep it present and
        // prove table navigation leaves that unrelated document unchanged.
        let initialDocuments = workspace.documents.map(\.storedState)
        let initialCount = initialDocuments.count
        let window = try await host(ApplicationWorkspaceView(workspace: workspace), theme: theme, width: 1240)
        workspace.presentationWindow = window
        defer { window.close() }
        let node = CatalogNode(profileID: profile.id, name: "orders", kind: .object, schema: "source schema", objectKind: "table")
        let catalog = try await host(List { CatalogBranchView(node: node, workspace: workspace) }
            .listStyle(.sidebar).catalogContextMenu(), theme: theme, width: 360, height: 420)
        defer { catalog.close() }
        try catalogAction("Open Data", in: catalog)
        try await wait("The native catalog menu did not load the source table.") { workspace.selectedDocument?.grid?.rows.count == 200 }
        let source = try #require(workspace.selectedDocument)
        let sourceSession = try #require(source.runtime?.sessionId)
        window.makeKeyAndOrderFront(nil)
        try await press("tableNextPage", window)
        try await wait("The native next-page control did not load page two.") { source.page == 1 && !source.isRunning }
        let sourceState = source.storedState
        let sourceGrid = try #require(source.grid)
        let events = try transport.events()
        try catalogAction("Open Data", in: catalog)
        try await Task.sleep(for: .milliseconds(160))
        #expect(workspace.selectedDocument === source && workspace.documents.count == initialCount + 1)
        #expect(try transport.events() == events)
        try catalogAction("Open in New Tab", in: catalog)
        try await wait("Open in New Tab did not create an independent loaded table view.") {
            workspace.documents.count == initialCount + 2 && workspace.selectedDocument?.grid?.rows.count == 200 && workspace.selectedDocument !== source
        }
        let other = try #require(workspace.selectedDocument)
        let otherSession = try #require(other.runtime?.sessionId)
        #expect(other.tableViewID != source.tableViewID && otherSession != sourceSession)
        #expect(other.page == 0 && other.tableFilters.isEmpty && other.tableSort.isEmpty)
        #expect(source.storedState == sourceState && source.grid === sourceGrid && source.runtime?.sessionId == sourceSession)
        catalog.close()
        try await selectFirstRow(other, in: window)
        try await NativeThemeMenuActions.select("Open Related Rows", in: #require(element("gridRelatedRows", window).button))
        try await wait("The native relationship menu did not navigate to the exact parent row.") {
            other.table?.name == "customers" && other.grid?.rows.count == 1 && !other.isNavigatingTable
        }
        let filters = [CatalogFilter(column: "tenant", operator: "eq", value: ""), CatalogFilter(column: "id", operator: "eq", value: "9007199254740993")]
        #expect(other.tableFilters == filters && other.runtime?.sessionId == otherSession)
        #expect(other.grid?.rows.first?.values.last?.value == "linked exact parent")
        #expect(source.storedState == sourceState && source.grid === sourceGrid)
        try await capture(window, name: "table-related-row-" + theme)
        try await press("tableNavigateBack", window)
        try await wait("Native Back did not restore the table location.") { other.table?.name == "orders" && !other.isNavigatingTable }
        #expect(other.page == 0 && other.tableFilters.isEmpty && other.runtime?.sessionId == otherSession)
        try await press("tableNavigateForward", window)
        try await wait("Native Forward did not restore the exact parent filters.") { other.table?.name == "customers" && !other.isNavigatingTable }
        #expect(other.tableFilters == filters)
        try await press("tableNavigateBack", window)
        try await wait("Back did not return to the source before new-tab navigation.") { other.table?.name == "orders" && !other.isNavigatingTable }
        try await selectFirstRow(other, in: window)
        try await NativeThemeMenuActions.select("Open Related Rows in New Tab", in: #require(element("gridRelatedRows", window).button))
        try await wait("The relationship menu did not open an independent parent table.") {
            workspace.documents.count == initialCount + 3 && workspace.selectedDocument?.table?.name == "customers" && workspace.selectedDocument?.grid != nil
        }
        let related = try #require(workspace.selectedDocument)
        let relatedSession = try #require(related.runtime?.sessionId)
        #expect(related !== other && relatedSession != otherSession && relatedSession != sourceSession)
        #expect(related.tableFilters == filters && other.table?.name == "orders" && other.runtime?.sessionId == otherSession)
        let relatedState = related.storedState
        try await press("closeDocument-" + related.id.uuidString, window)
        try await wait("The native Close action did not finish retiring the related view.") {
            workspace.documents.count == initialCount + 2 && workspace.canReopenClosedTab
        }
        let focused = try #require(workspace.selectedDocument)
        try await selectFirstRow(focused, in: window)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        try #require(workspace.commands.handleKeyEvent(event, documentID: focused.id))
        try await wait("The native reopen shortcut did not restore a disconnected table tab.") {
            workspace.documents.count == initialCount + 3 && workspace.selectedDocument?.runtime == nil
        }
        let reopened = try #require(workspace.selectedDocument)
        #expect(reopened.id != related.id && reopened.table == relatedState.table?.reference)
        #expect(reopened.tableFilters == filters && reopened.grid == nil && reopened.tableNeedsExplicitLoad)
        #expect(reopened.tableBackHistory.isEmpty && reopened.tableForwardHistory.isEmpty)
        let beforeLoad = try transport.events()
        try await Task.sleep(for: .milliseconds(160))
        #expect(try transport.events() == beforeLoad)
        #expect(Array(workspace.documents.prefix(initialCount)).map(\.storedState) == initialDocuments)
        try await capture(window, name: "table-reopened-disconnected-" + theme)
        await workspace.flushDocuments()
        let saved = await store.load()
        await workspace.shutdown()
        #expect(await transport.client.waitForExit().status == 0)
        window.close()

        var restoredHelperStarts = 0
        let fresh = try Transport()
        let freshSnapshots = ResultSnapshotStore(rootURL: fresh.directory.appendingPathComponent("snapshots"))
        let restored = ApplicationWorkspace(connectionStore: library, credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(snapshot: saved), commandShortcuts: AppShortcutStore(defaults: defaults),
            copySettings: ResultCopySettings(defaults: defaults), editorThemes: themes,
            appearance: AppAppearance(defaults: defaults, editorThemes: themes),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false),
            resultSnapshots: ResultSnapshotsModel(store: freshSnapshots),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: freshSnapshots),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard },
            helperFactory: { restoredHelperStarts += 1; return fresh.client })
        await restored.restoreSavedWorkspace()
        await restored.library.loadConnections()
        defer { Task { await restored.shutdown() } }
        let restarted = try await host(ApplicationWorkspaceView(workspace: restored), theme: theme, width: 1240)
        restored.presentationWindow = restarted
        defer { restarted.close() }
        #expect(restored.documents.map(\.storedState) == saved.documents && restored.services.isEmpty && restoredHelperStarts == 0)
        for state in saved.documents where state.kind == .table {
            try await press("selectDocument-" + state.id.uuidString, restarted)
            let document = try #require(restored.selectedDocument)
            #expect(document.storedState == state && document.runtime == nil && document.grid == nil && document.tableNeedsExplicitLoad)
        }
        let freshEvents = try fresh.events()
        #expect(restoredHelperStarts == 0 && freshEvents.isEmpty)
        let unloaded = try #require(restored.documents.first { $0.id == reopened.id })
        try await press("selectDocument-" + unloaded.id.uuidString, restarted)
        try await press("runQuery", restarted)
        try await wait("Explicit native Load Data did not open a fresh table session.") { unloaded.grid?.rows.count == 1 && !unloaded.isRunning }
        let freshSession = try #require(unloaded.runtime?.sessionId)
        #expect(restoredHelperStarts == 1 && freshSession != relatedSession && unloaded.tableFilters == filters)
        try await capture(restarted, name: "table-restored-explicit-load-" + theme)
        await restored.shutdown()
        #expect(await fresh.client.waitForExit().status == 0)
    }
}
