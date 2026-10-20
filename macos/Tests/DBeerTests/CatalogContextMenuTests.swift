import AppKit
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct CatalogContextMenuTests {
    @MainActor private final class MenuSample {
        let menu: NSMenu
        let action: NSMenuItem
        var sampled = false

        init(menu: NSMenu, action: NSMenuItem) {
            self.menu = menu
            self.action = action
        }
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private let contextClicks: [(String, NSEvent.EventType, NSEvent.ModifierFlags)] = [
        ("right-click", .rightMouseDown, []),
        ("control-click", .leftMouseDown, .control),
    ]

    private static func blueEdgePixels(in bitmap: NSBitmapImageRep) -> Set<Int> {
        var pixels = Set<Int>()
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where x < 32 || x >= bitmap.pixelsWide - 32 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.blueComponent > color.redComponent + 0.2 &&
                    color.blueComponent > color.greenComponent + 0.1 {
                    pixels.insert(y * bitmap.pixelsWide + x)
                }
            }
        }
        return pixels
    }

    private func presentAndSample(_ menu: NSMenu, action: NSMenuItem, table: NSTableView,
                                  row: NSRect, event: NSEvent, region: CatalogContextMenuView,
                                  name: String) throws {
        let sample = MenuSample(menu: menu, action: action)
        let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated {
                defer { sample.menu.cancelTrackingWithoutAnimation() }
                do {
                    let bitmap = try #require(table.bitmapImageRepForCachingDisplay(in: row))
                    table.cacheDisplay(in: row, to: bitmap)
                    let bluePixelCount = Self.blueEdgePixels(in: bitmap).count
                    #expect(bluePixelCount == 0, "Unexpected blue context-menu outline in \(name)")
                    if let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] {
                        let destination = URL(fileURLWithPath: directory, isDirectory: true)
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                        try bitmap.representation(using: .png, properties: [:])?.write(
                            to: destination.appendingPathComponent("\(name).png"))
                    }
                    sample.menu.performActionForItem(at: sample.menu.index(of: sample.action))
                    sample.sampled = true
                } catch { Issue.record(error) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        NSMenu.popUpContextMenu(sample.menu, with: event, for: region)
        timer.invalidate()
        #expect(sample.sampled)
    }

    @Test func nestedRowsBuildMenusForTheClickedObject() async throws {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let profile = UUID()
        let root = CatalogNode(profileID: profile, name: "public", kind: .schema, schema: "public")
        root.children = [
            CatalogNode(profileID: profile, name: "orders", kind: .object, schema: "public", objectKind: "table"),
            CatalogNode(profileID: profile, name: "calculate", kind: .object, schema: "public", objectKind: "function"),
        ]
        root.isExpanded = true
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: List {
            CatalogBranchView(node: root, workspace: workspace)
        }.listStyle(.sidebar).catalogContextMenu())
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let table = try #require(descendants(host, of: NSOutlineView.self).first)
        let region = try #require(descendants(host, of: CatalogContextMenuView.self).first)
        try #require(table.numberOfRows == 3)
        for row in 0..<3 {
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let menu = try #require(region.menu(for: event))
            menu.update()
            #expect((menu.item(withTitle: "Structure and Definition…") != nil) == (row != 0))
            #expect((menu.item(withTitle: "Open Data") != nil) == (row == 1))
            #expect((menu.item(withTitle: "Copy Name") != nil) == (row != 0))
        }
        await workspace.shutdown()
    }

    @Test func catalogMenuKeepsItsActionsWithoutDrawingTheNativeBlueOutline() async throws {
        _ = NSApplication.shared
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "fixture",
            user: "fixture", password: "", sslMode: "disable")
        try #require(await workspace.library.saveConnection(name: "dbeer", settings: settings))
        let profileID = try #require(workspace.library.selectedConnectionId)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1120, height: 760),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ApplicationWorkspaceView(workspace: workspace).preferredColorScheme(.dark))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            host.rootView = ApplicationWorkspaceView(workspace: workspace)
                .preferredColorScheme(theme == "dark" ? .dark : .light)
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            NativeButtonFocusPolicy().apply(to: window)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let table = try #require(descendants(host, of: NSOutlineView.self).first)
            let region = try #require(descendants(host, of: CatalogContextMenuView.self).first)
            let row = table.rect(ofRow: 0)
            let point = table.convert(NSPoint(x: row.midX, y: row.midY), to: nil)
            for (click, type, modifiers) in contextClicks {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                let previousSelection = table.selectedRowIndexes
                let menu = try #require(region.menu(for: event))
                menu.update()
                #expect(menu.item(withTitle: "Connect")?.isEnabled == true)
                let newTab = try #require(menu.item(withTitle: "New SQL Tab"))
                let previousCount = workspace.documents.count
                try presentAndSample(menu, action: newTab, table: table, row: row, event: event,
                    region: region, name: "catalog-context-menu-\(theme)-\(click)")
                #expect(workspace.documents.count == previousCount + 1)
                #expect(workspace.selectedDocument?.profileID == profileID)
                #expect(table.selectedRowIndexes == previousSelection)
            }
        }
        await workspace.shutdown()
    }

    @Test func connectionsSidebarMenusKeepEditAndSelectionWithoutDrawingTheNativeBlueOutline() async throws {
        _ = NSApplication.shared
        let model = WorkspaceModel(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "fixture",
            user: "fixture", password: "", sslMode: "disable")
        try #require(await model.saveConnection(name: "dbeer", settings: settings))
        let profileID = try #require(model.selectedConnectionId)
        var editedProfiles: [UUID] = []
        let sidebar = ConnectionsSidebar(model: model, onCreate: {}, onEdit: { editedProfiles.append($0.id) })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: sidebar.preferredColorScheme(.dark))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            host.rootView = sidebar.preferredColorScheme(theme == "dark" ? .dark : .light)
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            NativeButtonFocusPolicy().apply(to: window)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let table = try #require(descendants(host, of: NSOutlineView.self).first)
            let region = try #require(descendants(host, of: CatalogContextMenuView.self).first)
            #expect(table.numberOfRows == 2)
            #expect(table.selectionHighlightStyle == .none)
            let row = table.rect(ofRow: 1)
            let point = table.convert(NSPoint(x: row.midX, y: row.midY), to: nil)
            for (click, type, modifiers) in contextClicks {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                let previousSelection = table.selectedRowIndexes
                let menu = try #require(region.menu(for: event))
                menu.update()
                #expect(menu.item(withTitle: "Connect") != nil)
                #expect(menu.item(withTitle: "Delete Connection…")?.isEnabled == true)
                let edit = try #require(menu.item(withTitle: "Edit Connection…"))
                #expect(edit.isEnabled)
                let previousEdits = editedProfiles.count
                try presentAndSample(menu, action: edit, table: table, row: row, event: event,
                    region: region, name: "connections-sidebar-context-menu-\(theme)-\(click)")
                #expect(editedProfiles.count == previousEdits + 1)
                #expect(editedProfiles.last == profileID)
                #expect(model.selectedConnectionId == profileID)
                #expect(table.selectedRowIndexes == previousSelection)
            }
        }
        await model.shutdown()
    }
}
