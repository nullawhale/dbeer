import AppKit
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct CatalogRowHoverTests {
    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func window<Content: View>(for view: Content, width: CGFloat = 1120) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 720),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        return window
    }

    private func settle(_ window: NSWindow, policy: NativeButtonFocusPolicy) async throws {
        // Native sidebar resize/expand animation must settle before geometry QA.
        try await Task.sleep(for: .milliseconds(350))
        window.contentView?.layoutSubtreeIfNeeded()
        policy.apply(to: window)
        window.contentView?.layoutSubtreeIfNeeded()
        policy.apply(to: window)
    }

    private func hover(_ point: NSPoint, in outline: NSOutlineView) throws {
        let window = try #require(outline.window)
        let windowPoint = outline.convert(point, to: nil)
        for region in descendants(outline, of: CatalogRowFeedbackView.self) {
            region.updateTrackingAreas()
            let inside = region.cursorRect.contains(region.convert(windowPoint, from: nil))
            let event = try #require(NSEvent.enterExitEvent(with: inside ? .mouseEntered : .mouseExited,
                location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            if inside { region.mouseEntered(with: event) } else { region.mouseExited(with: event) }
        }
    }

    private func capture(_ view: NSView, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent(name + ".png"))
    }

    private func expectOneFullRowSurface(_ rowIndex: Int, in outline: NSOutlineView) throws {
        let row = try #require(outline.rowView(atRow: rowIndex, makeIfNecessary: true))
        if let window = outline.window { NativeButtonFocusPolicy().apply(to: window) }
        let regions = descendants(outline, of: CatalogRowFeedbackView.self).filter { $0.row === row }
        #expect(regions.count == 1)
        let region = try #require(regions.first)
        #expect(region.superview === outline)
        #expect(region.row === row)
        #expect(!region.usesNativeAlignment)
        #expect(region.nativeControl == nil)
        #expect(descendants(row, of: NativeButtonHoverView.self).isEmpty)
        let anchors = descendants(row, of: CatalogRowHoverAnchor.self)
        #expect(anchors.count == 1)
        let anchor = try #require(anchors.first)
        #expect(CatalogRowHoverAnchor.feedback(containing: anchor) === region)

        let rect = region.convert(region.feedbackRect, to: outline)
        let rowRect = outline.rect(ofRow: rowIndex)
        #expect(abs(rect.minY - rowRect.minY - ControlHoverAppearance.inset) < 0.5)
        #expect(abs(rowRect.maxY - rect.maxY - ControlHoverAppearance.inset) < 0.5)
        #expect(rect.minX - rowRect.minX >= ControlHoverAppearance.gap)
        #expect(rowRect.maxX - rect.maxX >= ControlHoverAppearance.gap)
        #expect(rect.width >= rowRect.width - 2 * (ControlHoverAppearance.gap + ControlHoverAppearance.inset) - 0.5)

        let label = anchor.convert(anchor.bounds, to: outline)
        let labelPoint = NSPoint(x: label.minX + min(8, label.width / 2), y: label.midY)
        let trailingPoint = NSPoint(x: rect.maxX - 2, y: rect.midY)
        var points = [labelPoint, trailingPoint]
        if outline.isExpandable(outline.item(atRow: rowIndex)) {
            let arrow = outline.frameOfOutlineCell(atRow: rowIndex)
            #expect(!arrow.isEmpty)
            points.append(NSPoint(x: arrow.midX, y: arrow.midY))
        }
        for point in points {
            #expect(rect.contains(point))
            let local = region.convert(point, from: outline)
            #expect(region.cursorRect.contains(local))
            #expect(region.hitTest(local) == nil)
            try hover(point, in: outline)
            #expect(region.isHovered)
            #expect(region.convert(region.feedbackRect, to: outline) == rect)
            #expect(descendants(outline, of: CatalogRowFeedbackView.self).filter { $0.isHovered }.count == 1)
        }
        #expect(!region.isAccessibilityElement())
        #expect(anchor.hitTest(.zero) == nil)
        for button in descendants(row, of: NSButton.self) {
            #expect(button.focusRingType == .none)
            #expect(button.cell?.focusRingType == NSFocusRingType.none)
        }
    }

    @Test func savedConnectionHoverIncludesDisclosureLabelAndEmptyTrailingSpace() async throws {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "fixture",
            user: "fixture", password: "", sslMode: "disable")
        try #require(await workspace.library.saveConnection(name: "dbeer", settings: settings))
        try #require(await workspace.library.saveConnection(name: "Other", settings: settings))
        let window = window(for: ApplicationWorkspaceView(workspace: workspace))
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            window.appearance = NSAppearance(named: appearance)
            try await settle(window, policy: policy)
            let content = try #require(window.contentView)
            let outline = try #require(descendants(content, of: NSOutlineView.self).first)
            #expect(outline.numberOfRows == 2)
            for index in 0..<outline.numberOfRows {
                try expectOneFullRowSurface(index, in: outline)
            }
            let arrow = outline.frameOfOutlineCell(atRow: 0)
            try hover(NSPoint(x: arrow.midX, y: arrow.midY), in: outline)
            if let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] {
                let row = try #require(outline.rowView(atRow: 0, makeIfNecessary: true))
                let region = try #require(CatalogRowHoverAnchor.feedback(containing: row))
                #expect(region.isHovered)
                content.displayIfNeeded()
                let rect = outline.rect(ofRow: 0)
                let bitmap = try #require(outline.bitmapImageRepForCachingDisplay(in: rect))
                outline.cacheDisplay(in: rect, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let folder = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: folder.appendingPathComponent("whole-catalog-row-\(appearance.rawValue).png"))
            }
            try capture(content, named: "catalog-profile-row-\(appearance.rawValue)")
            try hover(NSPoint(x: -20, y: -20), in: outline)
        }
        await workspace.shutdown()
    }

    @Test func nestedCatalogRowsKeepOneSurfaceThroughExpansionAndResizing() async throws {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let profile = UUID()
        let root = CatalogNode(profileID: profile, name: "public", kind: .schema, schema: "public")
        let group = CatalogNode(profileID: profile, name: "Tables", kind: .group, schema: "public")
        let leaf = CatalogNode(profileID: profile, name: "orders", kind: .detail, schema: "public")
        root.children = [group]
        group.children = [leaf]
        root.isExpanded = true
        group.isExpanded = true
        let window = window(for: List {
            CatalogBranchView(node: root, workspace: workspace)
        }.listStyle(.sidebar).catalogContextMenu().background(AppPalette.background), width: 340)
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            window.appearance = NSAppearance(named: appearance)
            for width in [CGFloat(340), 480] {
                window.setContentSize(NSSize(width: width, height: 720))
                try await settle(window, policy: policy)
                let content = try #require(window.contentView)
                let outline = try #require(descendants(content, of: NSOutlineView.self).first)
                #expect(outline.numberOfRows == 3)
                for index in 0..<outline.numberOfRows {
                    try expectOneFullRowSurface(index, in: outline)
                }
                try capture(content, named: "catalog-nested-rows-\(appearance.rawValue)-\(Int(width))")
                let item = try #require(outline.item(atRow: 0))
                outline.collapseItem(item)
                try await settle(window, policy: policy)
                #expect(!root.isExpanded)
                #expect(outline.numberOfRows == 1)
                try expectOneFullRowSurface(0, in: outline)
                outline.expandItem(item)
                try await settle(window, policy: policy)
                #expect(root.isExpanded)
                #expect(outline.numberOfRows == 3)
                for index in 0..<outline.numberOfRows {
                    try expectOneFullRowSurface(index, in: outline)
                }
            }
        }
        await workspace.shutdown()
    }

    @Test func removingTheMarkerRemovesFeedbackBeforeATableRowIsReused() throws {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 100))
        let row = NSTableRowView(frame: NSRect(x: 0, y: 20, width: 340, height: 30))
        let marker = CatalogRowHoverAnchor(frame: NSRect(x: 30, y: 0, width: 300, height: 30))
        content.addSubview(row)
        row.addSubview(marker)
        CatalogRowHoverAnchor.apply(in: content)
        CatalogRowHoverAnchor.apply(in: content)
        #expect(descendants(row, of: CatalogRowFeedbackView.self).count == 1)
        let first = try #require(CatalogRowHoverAnchor.feedback(containing: marker))
        #expect(!first.usesNativeAlignment)
        first.isHovered = true
        marker.removeFromSuperview()
        CatalogRowHoverAnchor.apply(in: content)
        #expect(descendants(row, of: CatalogRowFeedbackView.self).isEmpty)
        #expect(CatalogRowHoverAnchor.feedback(containing: row) == nil)

        row.addSubview(marker)
        CatalogRowHoverAnchor.apply(in: content)
        let replacement = try #require(CatalogRowHoverAnchor.feedback(containing: marker))
        #expect(replacement !== first)
        #expect(!replacement.isHovered)
        #expect(descendants(row, of: CatalogRowFeedbackView.self).count == 1)
    }
}
