import AppKit
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct ControlHoverTests {
    private final class RecordingCursorView: ControlCursorView {
        var regions: [(NSRect, NSCursor)] = []
        override func addCursorRect(_ rect: NSRect, cursor: NSCursor) {
            regions.append((rect, cursor))
        }
    }

    private final class EnabledState: ObservableObject {
        @Published var isEnabled = true
    }

    private struct Controls: View {
        @ObservedObject var state: EnabledState
        var body: some View {
            HStack {
                Button("Run") {}.controlHover().disabled(!state.isEnabled)
                Button {} label: { Image(systemName: "plus") }.buttonStyle(.borderless).controlHover()
                TextField("SQL", text: .constant("SELECT 1"))
            }.padding(20).frame(width: 400, height: 100)
        }
    }

    private final class ActionTarget: NSObject {
        var presses = 0
        @objc func press() { presses += 1 }
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func feedback(_ identifier: String, in hosting: NSView, window: NSWindow,
                          regions: [ControlFeedbackView]) throws -> ControlFeedbackView {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            let id = NSSelectorFromString("accessibilityIdentifier")
            if object.responds(to: id), object.perform(id)?.takeUnretainedValue() as? String == identifier { return object }
            let children = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: children), let children = object.perform(children)?.takeUnretainedValue() as? [Any] {
                for case let child as NSObject in children { if let found = find(child) { return found } }
            }
            if let view = object as? NSView {
                for child in view.subviews { if let found = find(child) { return found } }
            }
            return nil
        }
        let element = try #require(find(hosting))
        let screen = try #require(element.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let frame = hosting.convert(window.convertFromScreen(screen), from: nil)
        return try #require(regions.first {
            let rect = $0.convert($0.bounds, to: hosting)
            return abs(rect.midX - frame.midX) <= 1 && abs(rect.midY - frame.midY) <= 1
        })
    }

    @Test func pointingHandUsesClippedBoundsAndDisabledControlsLeaveCursorAlone() {
        let clip = NSClipView(frame: NSRect(x: 0, y: 0, width: 50, height: 25))
        let view = RecordingCursorView(frame: NSRect(x: 0, y: 0, width: 100, height: 25))
        clip.documentView = view
        view.resetCursorRects()
        #expect(view.regions.count == 1)
        #expect(view.regions.first?.0 == view.visibleRect)
        #expect(view.regions.first?.0.width == 50)
        #expect(view.regions.first?.1 == NSCursor.pointingHand)
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) == nil)

        view.regions.removeAll()
        view.isInteractionBlocked = true
        view.resetCursorRects()
        #expect(view.regions.isEmpty)
        view.isInteractionBlocked = false

        view.regions.removeAll()
        view.isEnabled = false
        view.resetCursorRects()
        #expect(view.regions.isEmpty)
    }

    @Test func swiftUIButtonsFollowEnabledChangesWithoutAddingATargetToTextFields() async throws {
        _ = NSApplication.shared
        let state = EnabledState()
        let hosting = NSHostingView(rootView: Controls(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let regions = descendants(hosting, of: ControlCursorView.self)
        #expect(regions.count == 2)
        #expect(regions.allSatisfy { $0.isEnabled })
        #expect(regions.allSatisfy { !$0.bounds.isEmpty && $0.hitTest(.zero) == nil })

        state.isEnabled = false
        try await Task.sleep(for: .milliseconds(100))
        let updated = descendants(hosting, of: ControlCursorView.self)
        #expect(updated.filter { $0.isEnabled }.count == 1)
        #expect(descendants(hosting, of: NSTextField.self).contains { window.makeFirstResponder($0) })
    }

    @Test func sheetsSuppressBackgroundHoverAndRestoreItAfterDismissal() async throws {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let target = ControlFeedbackView(frame: NSRect(x: 20, y: 20, width: 100, height: 24))
        content.addSubview(target)
        let native = NSButton(title: "Native", target: nil, action: nil)
        native.frame = NSRect(x: 180, y: 20, width: 100, height: 32)
        content.addSubview(native)
        let window = NSWindow(contentRect: content.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFront(nil)
        defer { window.close() }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        let policy = NativeButtonFocusPolicy()
        policy.apply(to: window)
        let fallback = try #require(native.subviews.compactMap { $0 as? NativeButtonHoverView }.first)
        target.isHovered = true
        fallback.isHovered = true
        window.beginSheet(sheet, completionHandler: nil)
        policy.apply(to: window)
        #expect(target.isInteractionBlocked && fallback.isInteractionBlocked)
        #expect(!target.isHovered && !fallback.isHovered)
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        target.mouseEntered(with: enter)
        #expect(!target.isHovered)
        window.endSheet(sheet)
        sheet.orderOut(nil)
        try await Task.sleep(for: .milliseconds(150))
        policy.apply(to: window)
        #expect(!target.isInteractionBlocked && !fallback.isInteractionBlocked)
        target.mouseEntered(with: enter)
        #expect(target.isHovered)
        sheet.close()
    }

    @Test func appModalPanelsBlockOtherWindowsButKeepTheirChildrenInteractive() throws {
        _ = NSApplication.shared
        func makeWindow() -> (NSWindow, ControlFeedbackView) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let region = ControlFeedbackView(frame: NSRect(x: 20, y: 20, width: 80, height: 24))
            window.contentView!.addSubview(region)
            window.orderFront(nil)
            return (window, region)
        }
        let (background, backgroundRegion) = makeWindow()
        let (panel, panelRegion) = makeWindow()
        let (child, childRegion) = makeWindow()
        defer { child.close(); panel.close(); background.close() }
        let session = NSApplication.shared.beginModalSession(for: panel)
        defer { NSApplication.shared.endModalSession(session) }
        _ = NSApplication.shared.runModalSession(session)
        let policy = NativeButtonFocusPolicy()
        policy.apply(to: background)
        policy.apply(to: panel)
        #expect(backgroundRegion.isInteractionBlocked)
        #expect(!panelRegion.isInteractionBlocked)
        panel.addChildWindow(child, ordered: .above)
        policy.apply(to: child)
        #expect(!childRegion.isInteractionBlocked)
        panel.removeChildWindow(child)
    }

    @Test func nativeDisclosureAndAlertFeedbackPreservesActionsAndDoesNotDuplicate() throws {
        _ = NSApplication.shared
        let target = ActionTarget()
        let button = NSButton(title: "Expand", target: target, action: #selector(ActionTarget.press))
        button.bezelStyle = .disclosure
        button.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        let window = NSWindow(contentRect: button.bounds, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = button
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()
        policy.apply(to: window)
        policy.apply(to: window)
        let overlay = try #require(button.subviews.compactMap { $0 as? NativeButtonHoverView }.first)
        #expect(button.subviews.filter { $0 is NativeButtonHoverView }.count == 1)
        #expect(overlay.hitTest(NSPoint(x: 12, y: 12)) == nil)
        button.performClick(nil)
        #expect(target.presses == 1)
        button.isEnabled = false
        overlay.resetCursorRects()
        #expect(!overlay.isEnabled)
        button.performClick(nil)
        #expect(target.presses == 1)

        let alert = NSAlert()
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        policy.apply(to: alert.window)
        policy.apply(to: alert.window)
        #expect(alert.buttons.allSatisfy { button in
            button.subviews.filter { $0 is NativeButtonHoverView }.count == 1
        })
    }

    @Test func workspaceHoverUsesOneLayerAndKeepsGapsAtWindowEdges() async throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let document = workspace.newDocument(profileID: UUID())
        document.title = "Query"
        let hosting = NSHostingView(rootView: ApplicationWorkspaceView(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }
        for _ in 0..<20 where !window.isKeyWindow {
            try await Task.sleep(for: .milliseconds(25))
            window.makeKey()
        }
        try #require(window.isKeyWindow)
        try await Task.sleep(for: .milliseconds(150))
        let policy = NativeButtonFocusPolicy()
        policy.apply(to: window)
        policy.apply(to: window)
        let regions = descendants(hosting, of: ControlFeedbackView.self)
            .filter { !($0 is NativeButtonHoverView) }
        let runToFile = try feedback("runToFile", in: hosting, window: window, regions: regions)
        let menuFrame = runToFile.convert(runToFile.bounds, to: hosting)
        // SwiftUI renders the labels of ordinary NSButtons itself, leaving
        // NSButton.title empty. Find the adjacent action by its layout.
        let runScript = try #require(regions.filter {
            let rect = $0.convert($0.bounds, to: hosting)
            return abs(rect.midY - menuFrame.midY) < 1 && rect.maxX < menuFrame.minX
        }.max { $0.convert($0.bounds, to: hosting).maxX < $1.convert($1.bounds, to: hosting).maxX })
        // A native button's alignment margin must not create a second, larger
        // rectangle around the common highlight.
        for region in [runScript, runToFile] {
            if let button = region.nativeControl {
                #expect(!button.subviews.contains { $0 is NativeButtonHoverView })
            }
            #expect(region.bounds.contains(region.feedbackRect))
        }
        let scriptRect = runScript.convert(runScript.feedbackRect, to: hosting)
        let fileRect = runToFile.convert(runToFile.feedbackRect, to: hosting)
        #expect(fileRect.width < 160)
        #expect(fileRect.minX - scriptRect.maxX >= ControlHoverAppearance.gap)
        let newTab = try feedback("newSQLTab", in: hosting, window: window, regions: regions)
        let tabRect = newTab.convert(newTab.feedbackRect, to: hosting)
        #expect(hosting.bounds.maxX - tabRect.maxX >= ControlHoverAppearance.gap)
        #expect(tabRect.minY - hosting.bounds.minY >= ControlHoverAppearance.gap)

        guard let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            window.appearance = NSAppearance(named: appearance)
            for (control, region) in [("script", runScript), ("file", runToFile), ("tab", newTab)] {
                region.isHovered = true
                hosting.displayIfNeeded()
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("hover-\(name)-\(control).png"))
                region.isHovered = false
            }
        }
    }
}
