import AppKit
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct SelectHoverTests {
    private final class FlippedPopup: NSPopUpButton {
        override var isFlipped: Bool { true }
    }

    private final class FlippedContainer: NSView {
        override var isFlipped: Bool { true }
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: folder.appendingPathComponent(name + ".png"))
    }

    private func expectEqual(_ actual: NSRect, _ expected: NSRect) {
        #expect(abs(actual.minX - expected.minX) < 0.01)
        #expect(abs(actual.minY - expected.minY) < 0.01)
        #expect(abs(actual.width - expected.width) < 0.01)
        #expect(abs(actual.height - expected.height) < 0.01)
    }

    @Test func popupFeedbackUsesTheParentsCoordinatesAtEveryControlSize() throws {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 120))
        let window = NSWindow(contentRect: content.bounds, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFront(nil)
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()
        for parentIsFlipped in [false, true] {
            let parent = parentIsFlipped ? FlippedContainer() : NSView()
            parent.frame = NSRect(x: 12, y: 17, width: 400, height: 90)
            content.addSubview(parent)
            defer { parent.removeFromSuperview() }
            for popupIsFlipped in [false, true] {
                let popup = popupIsFlipped ? FlippedPopup(frame: .zero, pullsDown: false)
                    : NSPopUpButton(frame: .zero, pullsDown: false)
                popup.addItems(withTitles: ["dbeer", "Other connection"])
                parent.addSubview(popup)
                defer { popup.removeFromSuperview() }
                for size in [NSControl.ControlSize.mini, .small, .regular, .large] {
                    popup.controlSize = size
                    for width in [CGFloat(100), 220] {
                        let target = NSRect(x: 35, y: 23, width: width, height: popup.intrinsicContentSize.height)
                        popup.frame = target
                        // This API accepts a frame in the parent's coordinate
                        // system. Do not derive the oracle from control bounds.
                        let alignment = popup.alignmentRect(forFrame: popup.frame)
                        let expected = parent.convert(alignment, to: content)
                        let region = ControlFeedbackView(frame: expected)
                        content.addSubview(region)
                        policy.apply(to: window)
                        policy.apply(to: window)
                        #expect(region.nativeControl === popup)
                        #expect(descendants(popup, of: NativeButtonHoverView.self).isEmpty)
                        expectEqual(region.convert(region.feedbackRect, to: content),
                            expected.insetBy(dx: ControlHoverAppearance.inset, dy: ControlHoverAppearance.inset))
                        expectEqual(region.convert(region.cursorRect, to: content), expected)
                        region.updateTrackingAreas()
                        #expect(region.trackingAreas.first?.rect == region.cursorRect)
                        region.removeFromSuperview()
                        // Native fallback controls must use the same conversion.
                        policy.apply(to: window)
                        let fallback = try #require(descendants(popup, of: NativeButtonHoverView.self).first)
                        expectEqual(fallback.convert(fallback.feedbackRect, to: content),
                            expected.insetBy(dx: ControlHoverAppearance.inset, dy: ControlHoverAppearance.inset))
                        fallback.removeFromSuperview()
                    }
                }
            }
        }
    }

    @Test func selectGeometryAcrossRealScreensAndWindowSizesInBothThemes() async throws {
        _ = NSApplication.shared
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "dbeer",
            user: "fixture", password: "", sslMode: "disable")
        try #require(await workspace.library.saveConnection(name: "dbeer", settings: settings))
        let document = workspace.newDocument(profileID: workspace.library.selectedConnectionId)
        document.tableColumns = [["name": "id"], ["name": "name"]]
        let screens: [(String, AnyView, Int)] = [
            ("workspace", AnyView(ApplicationWorkspaceView(workspace: workspace)), 2),
            ("filters", AnyView(TableBrowseControls(document: document, workspace: workspace)), 2),
            ("connection", AnyView(ConnectionEditorView(model: workspace.library, connection: nil) {}), 2),
        ]
        var usesNativePickers = false
        for (name, screen, nativeCount) in screens {
            let host = NSHostingView(rootView: screen.background(AppPalette.background)
                .tint(AppPalette.accent).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            defer { window.close() }
            for _ in 0..<20 where !window.isKeyWindow {
                try await Task.sleep(for: .milliseconds(25))
                window.makeKey()
            }
            try #require(window.isKeyWindow)
            for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                host.rootView = screen.background(AppPalette.background).tint(AppPalette.accent)
                    .preferredColorScheme(theme == "dark" ? .dark : .light)
                window.appearance = NSAppearance(named: appearance)
                for width in [CGFloat(1120), 1320] {
                    window.setContentSize(NSSize(width: width, height: 720))
                    try await Task.sleep(for: .milliseconds(200))
                    host.layoutSubtreeIfNeeded()
                    // Selecting a tab mounts its controls. Ownership must be
                    // assigned after that hierarchy exists, as it is during a
                    // production window update, rather than on the old tab.
                    if name == "connection" { try await NativeConnectionEditorTabs.select("Options", in: host) }
                    let policy = NativeButtonFocusPolicy()
                    policy.apply(to: window)
                    policy.apply(to: window)
                    host.layoutSubtreeIfNeeded()
                    let popups = descendants(host, of: NSPopUpButton.self).filter { !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }
                    if name == "workspace" { usesNativePickers = !popups.isEmpty }
                    #expect(popups.count == (usesNativePickers ? nativeCount : (name == "connection" ? 1 : 0)))
                    let regions = descendants(host, of: ControlFeedbackView.self)
                    for popup in popups {
                        let parent = try #require(popup.superview)
                        let owners = regions.filter { $0.nativeControl === popup }
                        #expect(owners.count == 1)
                        let region = try #require(owners.first)
                        #expect(!(region is NativeButtonHoverView))
                        #expect(descendants(popup, of: NativeButtonHoverView.self).isEmpty)
                        let alignment = parent.convert(popup.alignmentRect(forFrame: popup.frame), to: region)
                        // The entire native popup must fit the feedback view;
                        // accepting its intersection hid clipped Form hovers.
                        #expect(region.bounds.contains(alignment))
                        expectEqual(region.feedbackRect, alignment.insetBy(
                            dx: ControlHoverAppearance.inset, dy: ControlHoverAppearance.inset))
                        expectEqual(region.cursorRect, alignment.intersection(region.visibleRect))
                        #expect(!region.feedbackRect.isEmpty)
                        #expect(region.hitTest(.zero) == nil)
                    }
                    for region in regions { region.isHovered = true }
                    try capture(host, name: "select-\(name)-\(theme)-\(Int(width))-hover")
                }
            }
        }
    }
}
