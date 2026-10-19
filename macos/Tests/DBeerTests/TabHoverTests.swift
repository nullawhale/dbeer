import AppKit
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct TabHoverTests {
    private func regions(in view: NSView) -> [ControlFeedbackView] {
        ((view as? ControlFeedbackView).map { [$0] } ?? []) + view.subviews.flatMap { regions(in: $0) }
    }

    /// Deliver the tracking-area events AppKit sends for a point. Checking every
    /// area detects overlapping parent/child targets as well as stale exits.
    private func hover(_ point: NSPoint, in window: NSWindow, regions: [ControlFeedbackView]) throws {
        for region in regions {
            region.updateTrackingAreas()
            #expect(region.trackingAreas.contains { $0.rect == region.cursorRect })
            let inside = region.cursorRect.contains(region.convert(point, from: nil))
            let event = try #require(NSEvent.enterExitEvent(with: inside ? .mouseEntered : .mouseExited,
                location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            if inside { region.mouseEntered(with: event) } else { region.mouseExited(with: event) }
        }
    }

    private func click(_ point: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
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

    @Test func wholeTabHoverIncludesCloseAndPaddingWhileCloseKeepsItsOwnActionInBothThemes() async throws {
        _ = NSApplication.shared
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            for selected in [false, true] {
                let document = SQLDocument(title: "Customers")
                var selections = 0
                var closes = 0
                let hosting = NSHostingView(rootView:
                    DocumentTab(document: document, isSelected: selected,
                        select: { selections += 1 }, close: { closes += 1 })
                        .padding(8).frame(width: 220, height: 44)
                        .background(AppPalette.background))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = hosting
                window.makeKeyAndOrderFront(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(100))
                NativeButtonFocusPolicy().apply(to: window)
                let targets = regions(in: hosting).sorted {
                    $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
                }
                #expect(targets.count == 2)
                let tab = try #require(targets.first)
                let close = try #require(targets.last)
                let tabRect = tab.convert(tab.bounds, to: nil)
                let closeRect = close.convert(close.bounds, to: nil)
                #expect(tabRect.contains(closeRect))
                #expect(tabRect.maxX - closeRect.maxX >= ControlHoverAppearance.gap)
                #expect(abs(tab.feedbackRect.width - tab.bounds.width + ControlHoverAppearance.inset * 2) < 0.01)
                #expect(tab.cursorRect == tab.bounds.intersection(tab.visibleRect))
                let titlePoint = NSPoint(x: tabRect.minX + tabRect.width / 3, y: tabRect.midY)
                let closePoint = NSPoint(x: closeRect.midX, y: closeRect.midY)
                let gapPoint = NSPoint(x: closeRect.minX - ControlHoverAppearance.gap / 2, y: tabRect.midY)
                try hover(titlePoint, in: window, regions: targets)
                #expect(tab.isHovered && !close.isHovered)
                try capture(hosting, named: "tab-\(name)-\(selected)-title")
                try click(titlePoint, in: window)
                #expect(selections == 1 && closes == 0)
                try hover(closePoint, in: window, regions: targets)
                #expect(close.isHovered && tab.isHovered)
                try capture(hosting, named: "tab-\(name)-\(selected)-close")
                try click(closePoint, in: window)
                #expect(selections == 1 && closes == 1)
                try hover(gapPoint, in: window, regions: targets)
                #expect(tab.isHovered && !close.isHovered)
                try click(gapPoint, in: window)
                #expect(selections == 2 && closes == 1)
                for x in [tabRect.minX + 2, tabRect.maxX - 2] {
                    try hover(NSPoint(x: x, y: tabRect.midY), in: window, regions: targets)
                    #expect(tab.isHovered && !close.isHovered)
                }
                try hover(NSPoint(x: -20, y: -20), in: window, regions: targets)
                #expect(targets.allSatisfy { !$0.isHovered })
            }
        }
    }

    @Test func policyClearsMovedNativeOwnersAndNeverAssignsTwoControlsToOneRegion() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 100))
        let targetRect = NSRect(x: 20, y: 20, width: 100, height: 24)
        let region = ControlFeedbackView(frame: targetRect)
        let first = NSButton(title: "First", target: nil, action: nil)
        first.frame = first.frame(forAlignmentRect: targetRect)
        content.addSubview(first)
        content.addSubview(region)
        let window = NSWindow(contentRect: content.bounds, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()
        policy.apply(to: window)
        #expect(region.nativeControl === first)
        first.frame.origin.x += 120
        policy.apply(to: window)
        #expect(region.nativeControl == nil)
        #expect(first.subviews.contains { $0 is NativeButtonHoverView })
        let second = NSButton(title: "Second", target: nil, action: nil)
        second.frame = second.frame(forAlignmentRect: targetRect)
        content.addSubview(second)
        policy.apply(to: window)
        policy.apply(to: window)
        #expect(region.nativeControl === second)
        #expect(!second.subviews.contains { $0 is NativeButtonHoverView })
        #expect(first.subviews.filter { $0 is NativeButtonHoverView }.count == 1)
    }

    @Test func scrollingATargetOutOfViewRemovesItsTrackingAndClearsHover() throws {
        let clip = NSClipView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        let region = ControlFeedbackView(frame: NSRect(x: 0, y: 0, width: 100, height: 23))
        document.addSubview(region)
        clip.documentView = document
        region.updateTrackingAreas()
        #expect(region.cursorRect.width == 50)
        #expect(region.trackingAreas.count == 1)
        #expect(region.trackingAreas.first?.rect == region.cursorRect)
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        region.mouseEntered(with: event)
        #expect(region.isHovered)
        clip.scroll(to: NSPoint(x: 120, y: 0))
        region.updateTrackingAreas()
        #expect(region.cursorRect.isEmpty)
        #expect(region.trackingAreas.isEmpty)
        #expect(!region.isHovered)
    }

    @Test func movingAStillVisibleTargetAwayFromAStationaryPointerClearsHover() throws {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        let region = ControlFeedbackView(frame: NSRect(x: 10, y: 10, width: 100, height: 24))
        content.addSubview(region)
        let window = NSWindow(contentRect: content.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFront(nil)
        defer { window.close() }
        region.updateTrackingAreas()
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: NSPoint(x: 20, y: 20),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        region.mouseEntered(with: event)
        #expect(region.isHovered)
        let pointer = window.mouseLocationOutsideOfEventStream
        region.setFrameOrigin(NSPoint(x: pointer.x < 130 ? 150 : 10, y: 40))
        region.updateTrackingAreas()
        #expect(!region.cursorRect.isEmpty)
        #expect(!region.isHovered)
    }
}
