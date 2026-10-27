import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Exercise the real SwiftUI/AppKit bridge as well as the shared paint surface.
/// A control can look correct in isolation while an AppKit fallback silently
/// adds a second highlight, so both paths belong in this regression matrix.
@Suite(.serialized)
@MainActor
struct HoverConsistencyTests {
    private enum Fixture: String, CaseIterable {
        case automatic = "Automatic button"
        case bordered = "Bordered button"
        case prominent = "Prominent button"
        case plain = "Plain button"
        case borderless = "Borderless button"
        case link = "Link button"
        case icon = "Icon button"
        case menu = "Menu"
        case picker = "Menu picker"
        case labelledPicker = "Labelled picker"
        case checkbox = "Checkbox"
        case switchToggle = "Switch"
        case segments = "Segmented picker"
    }

    private final class EnabledState: ObservableObject {
        @Published var isEnabled = true
    }

    private struct FixtureView: View {
        let fixture: Fixture
        @ObservedObject var state: EnabledState

        var body: some View {
            HStack(spacing: 12) {
                Text(fixture.rawValue).font(.caption).frame(width: 112, alignment: .leading)
                control.fixedSize().controlHover().disabled(!state.isEnabled)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(width: 344, height: 52)
        }

        @ViewBuilder private var control: some View {
            switch fixture {
            case .automatic: Button("Action") {}
            case .bordered: Button("Action") {}.buttonStyle(.bordered)
            case .prominent: Button("Action") {}.buttonStyle(.borderedProminent)
            case .plain: Button("Action") {}.buttonStyle(.plain)
            case .borderless: Button("Action") {}.buttonStyle(.borderless)
            case .link: Button("Action") {}.buttonStyle(.link)
            case .icon:
                Button {} label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                    .buttonStyle(.borderless)
            case .menu: Menu("Action") { Button("First item") {} }
            case .picker:
                Picker("Choice", selection: .constant(0)) {
                    Text("First").tag(0)
                    Text("Second").tag(1)
                }.labelsHidden().pickerStyle(.menu)
            case .labelledPicker:
                Picker("Choice", selection: .constant(0)) {
                    Text("First").tag(0)
                    Text("Second").tag(1)
                }.pickerStyle(.menu)
            case .checkbox: Toggle("Option", isOn: .constant(false)).toggleStyle(.checkbox)
            case .switchToggle: Toggle("Option", isOn: .constant(false)).toggleStyle(.switch)
            case .segments:
                Picker("Choice", selection: .constant(0)) {
                    Text("First").tag(0)
                    Text("Second").tag(1)
                }.labelsHidden().pickerStyle(.segmented)
            }
        }
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
            if object.responds(to: id), object.perform(id)?.takeUnretainedValue() as? String == identifier {
                return object
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: children), let children = object.perform(children)?.takeUnretainedValue() as? [Any] {
                for case let child as NSObject in children { if let found = find(child) { return found } }
            }
            if let view = object as? NSView {
                for child in view.subviews { if let found = find(child) { return found } }
            }
            return nil
        }
        let element = try #require(find(hosting), "Missing plus action: \(identifier)")
        let screen = try #require(element.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let frame = hosting.convert(window.convertFromScreen(screen), from: nil)
        let matches = regions.filter {
            let rect = $0.convert($0.bounds, to: hosting)
            return abs(rect.midX - frame.midX) <= 1 && abs(rect.midY - frame.midY) <= 1
        }
        #expect(matches.count == 1, "\(identifier) must own exactly one compact hover surface")
        return try #require(matches.first)
    }

    private func makeWindow(content: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: content.bounds, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFront(nil)
        return window
    }

    private func settle(_ content: NSView, policy: NativeButtonFocusPolicy, window: NSWindow) async throws {
        // SwiftUI may defer rebuilding the native controls after environment or
        // enabled-state changes. Repeated policy application must be harmless.
        try await Task.sleep(for: .milliseconds(100))
        content.layoutSubtreeIfNeeded()
        policy.apply(to: window)
        policy.apply(to: window)
        content.layoutSubtreeIfNeeded()
    }

    private func expectInsetAndPassThrough(_ region: ControlFeedbackView) {
        let rect = region.feedbackRect
        #expect(!rect.isEmpty)
        #expect(rect.minX - region.bounds.minX >= ControlHoverAppearance.inset - 0.01)
        #expect(rect.minY - region.bounds.minY >= ControlHoverAppearance.inset - 0.01)
        #expect(region.bounds.maxX - rect.maxX >= ControlHoverAppearance.inset - 0.01)
        #expect(region.bounds.maxY - rect.maxY >= ControlHoverAppearance.inset - 0.01)
        for point in [NSPoint(x: rect.midX, y: rect.midY), rect.origin,
                      NSPoint(x: rect.maxX, y: rect.maxY)] {
            #expect(region.hitTest(point) == nil)
        }
        #expect(!region.isAccessibilityElement())
    }

    /// Draw only the hover paint, excluding the intentionally different native
    /// bezels and labels. Align its feedback rectangle on a transparent canvas
    /// so equivalent native and SwiftUI targets can be compared pixel for pixel.
    private func render(_ region: ControlFeedbackView, appearance: NSAppearance) throws -> NSBitmapImageRep {
        let rect = region.feedbackRect
        let margin: CGFloat = 3
        let width = Int(ceil(rect.width + margin * 2))
        let height = Int(ceil(rect.height + margin * 2))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32))
        let pixels = try #require(bitmap.bitmapData)
        pixels.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let transform = NSAffineTransform()
        transform.translateX(by: margin - rect.minX, yBy: margin - rect.minY)
        transform.concat()
        appearance.performAsCurrentDrawingAppearance { region.draw(region.bounds) }
        context.flushGraphics()
        return bitmap
    }

    private func bytes(_ bitmap: NSBitmapImageRep) throws -> [UInt8] {
        let data = try #require(bitmap.bitmapData)
        return Array(UnsafeBufferPointer(start: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }

    private func isTransparent(_ bitmap: NSBitmapImageRep) -> Bool {
        (0..<bitmap.pixelsHigh).allSatisfy { y in
            (0..<bitmap.pixelsWide).allSatisfy { x in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1) == 0
            }
        }
    }

    private func capture(_ content: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        content.displayIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("hover-consistency-\(name).png"))
    }

    @Test func allSwiftUIStylesKeepOneInsetHoverSurfaceThroughThemeAndEnabledChanges() async throws {
        let state = EnabledState()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 704, height: CGFloat((Fixture.allCases.count + 1) / 2 * 52 + 16)))
        let hosts = Fixture.allCases.enumerated().map { index, fixture in
            let host = NSHostingView(rootView: FixtureView(fixture: fixture, state: state))
            host.frame = NSRect(x: CGFloat(8 + (index % 2) * 344), y: CGFloat(8 + (index / 2) * 52),
                width: 344, height: 52)
            content.addSubview(host)
            return host
        }
        let window = makeWindow(content: content)
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()

        for (theme, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try #require(NSAppearance(named: name))
            window.appearance = appearance
            state.isEnabled = true
            try await settle(content, policy: policy, window: window)

            for (fixture, host) in zip(Fixture.allCases, hosts) {
                let regions = descendants(host, of: ControlFeedbackView.self)
                #expect(regions.count == 1, "\(fixture.rawValue) in \(theme) must have one hover surface")
                let region = try #require(regions.first)
                #expect(region.isEnabled)
                expectInsetAndPassThrough(region)
                // An explicit region must own the paint even when its backing
                // control is native; otherwise hover opacity is doubled.
                #expect(!(region is NativeButtonHoverView))
                for control in descendants(host, of: NSControl.self)
                    where control is NSButton || control is NSSegmentedControl {
                    #expect(control.focusRingType == .none)
                    #expect(!control.subviews.contains { $0 is NativeButtonHoverView })
                }
                region.isHovered = false
                #expect(isTransparent(try render(region, appearance: appearance)))
                region.isHovered = true
                #expect(!isTransparent(try render(region, appearance: appearance)))
                let unfocused = try bytes(render(region, appearance: appearance))
                region.isKeyboardFocused = true
                #expect(try bytes(render(region, appearance: appearance)) == unfocused)
                region.isKeyboardFocused = false
            }
            try capture(content, name: "\(theme)-swiftui-enabled")

            state.isEnabled = false
            try await settle(content, policy: policy, window: window)
            for host in hosts {
                let regions = descendants(host, of: ControlFeedbackView.self)
                #expect(regions.count == 1)
                let region = try #require(regions.first)
                #expect(!region.isEnabled)
                region.isHovered = true
                #expect(isTransparent(try render(region, appearance: appearance)))
                expectInsetAndPassThrough(region)
            }
            try capture(content, name: "\(theme)-swiftui-disabled")
        }
    }

    @Test func connectionAndTabPlusesHaveIdenticalHoverGeometryAndPixels() async throws {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let model = WorkspaceModel(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1416, height: 600))
        let app = NSHostingView(rootView: ApplicationWorkspaceView(workspace: workspace))
        app.frame = NSRect(x: 0, y: 0, width: 1120, height: 600)
        content.addSubview(app)
        let sidebar = NSHostingView(rootView: ConnectionsSidebar(model: model, onCreate: {}, onEdit: { _ in })
            .background(AppPalette.background).tint(AppPalette.accent))
        sidebar.frame = NSRect(x: 1128, y: 0, width: 288, height: 600)
        content.addSubview(sidebar)
        let window = makeWindow(content: content)
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()

        for (theme, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try #require(NSAppearance(named: name))
            window.appearance = appearance
            try await settle(content, policy: policy, window: window)
            // Sidebar actions also use compact icon controls. Select the actual
            // plus actions by identity while retaining the real containers, so
            // a new sidebar button cannot replace a plus in this comparison.
            func compactRegions(in view: NSView) -> [ControlFeedbackView] {
                descendants(view, of: ControlFeedbackView.self).filter {
                    !$0.isHiddenOrHasHiddenAncestor && !$0.cursorRect.isEmpty &&
                        $0.bounds.width <= 40 && $0.bounds.height <= 32
                }
            }
            let appRegions = compactRegions(in: app)
            let workspacePluses = try ["newConnection", "newSQLTab"].map {
                try feedback($0, in: app, window: window, regions: appRegions)
            }
            #expect(Set(workspacePluses.map(ObjectIdentifier.init)).count == 2)
            let legacyPlus = try feedback("newConnection", in: sidebar, window: window,
                regions: compactRegions(in: sidebar))
            let pluses = workspacePluses + [legacyPlus]
            let reference = try #require(pluses.first)
            reference.isHovered = true
            let expected = try bytes(render(reference, appearance: appearance))
            #expect(!isTransparent(try render(reference, appearance: appearance)))
            for plus in pluses {
                #expect(plus.bounds.size == NSSize(width: 22, height: 22))
                #expect(plus.feedbackRect.size == NSSize(width: 20, height: 20))
                #expect(plus.cursorRect == plus.bounds)
                #expect(!(plus is NativeButtonHoverView))
                expectInsetAndPassThrough(plus)
                plus.updateTrackingAreas()
                #expect(plus.trackingAreas.count == 1)
                #expect(plus.trackingAreas.first?.rect == plus.bounds)
                plus.isHovered = true
                #expect(try bytes(render(plus, appearance: appearance)) == expected)
                let rect = plus.convert(plus.feedbackRect, to: content)
                #expect(rect.minY >= ControlHoverAppearance.gap)
                #expect(content.bounds.maxY - rect.maxY >= ControlHoverAppearance.gap)
                #expect(content.bounds.maxX - rect.maxX >= ControlHoverAppearance.gap)
            }
            try capture(content, name: "\(theme)-actual-plus-buttons")
        }
    }

    @Test func nativeFallbacksPaintTheSameRoundedFillAndBorderAsExplicitHover() throws {
        let button = NSButton(title: "Button", target: nil, action: nil)
        let borderless = NSButton(title: "Borderless", target: nil, action: nil)
        borderless.isBordered = false
        let disclosure = NSButton(title: "", target: nil, action: nil)
        disclosure.bezelStyle = .disclosure
        let checkbox = NSButton(checkboxWithTitle: "Checkbox", target: nil, action: nil)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["First", "Second"])
        let segments = NSSegmentedControl(labels: ["First", "Second"],
            trackingMode: .selectOne, target: nil, action: nil)
        let controls: [NSControl] = [button, borderless, disclosure, checkbox, popup, segments]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 260))
        let alignmentSize = NSSize(width: 120, height: 28)
        for (index, control) in controls.enumerated() {
            let alignmentRect = NSRect(origin: NSPoint(x: 28, y: CGFloat(12 + index * 40)), size: alignmentSize)
            control.frame = control.frame(forAlignmentRect: alignmentRect)
            content.addSubview(control)
        }
        let window = makeWindow(content: content)
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()
        policy.apply(to: window)
        policy.apply(to: window)
        let reference = ControlFeedbackView(frame: NSRect(origin: .zero, size: alignmentSize))
        reference.isHovered = true

        for (theme, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try #require(NSAppearance(named: name))
            window.appearance = appearance
            let expected = try render(reference, appearance: appearance)
            #expect(!isTransparent(expected))
            let center = try #require(expected.colorAt(x: expected.pixelsWide / 2, y: expected.pixelsHigh / 2))
            let edge = try #require(expected.colorAt(x: expected.pixelsWide / 2, y: 3))
            #expect(center.alphaComponent > 0)
            #expect(edge.alphaComponent > center.alphaComponent)
            // The outer gap and the rounded corner must stay transparent.
            #expect(expected.colorAt(x: 0, y: expected.pixelsHigh / 2)?.alphaComponent == 0)
            #expect(expected.colorAt(x: 3, y: 3)?.alphaComponent == 0)

            for control in controls {
                let overlays = descendants(control, of: NativeButtonHoverView.self)
                #expect(overlays.count == 1)
                let overlay = try #require(overlays.first)
                #expect(overlay.nativeControl === control)
                expectInsetAndPassThrough(overlay)
                #expect(abs(overlay.feedbackRect.width - reference.feedbackRect.width) < 0.01)
                #expect(abs(overlay.feedbackRect.height - reference.feedbackRect.height) < 0.01)
                overlay.isHovered = true
                #expect(try bytes(render(overlay, appearance: appearance)) == bytes(expected))

                overlay.isHovered = false
                #expect(isTransparent(try render(overlay, appearance: appearance)))
                // Disabled native controls must suppress stale hover state even
                // before AppKit next refreshes their cursor rectangles.
                control.isEnabled = false
                overlay.isHovered = true
                #expect(isTransparent(try render(overlay, appearance: appearance)))
                overlay.resetCursorRects()
                #expect(!overlay.isEnabled)
                control.isEnabled = true
                overlay.resetCursorRects()
                #expect(overlay.isEnabled)
                #expect(try bytes(render(overlay, appearance: appearance)) == bytes(expected))
            }
            try capture(content, name: "\(theme)-native-enabled")
        }
    }
}
