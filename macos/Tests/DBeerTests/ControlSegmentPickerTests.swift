import AppKit
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct ControlSegmentPickerTests {
    private final class SelectionState: ObservableObject {
        @Published var selection = AppTheme.system
        @Published var isEnabled = true
    }

    private struct PickerHost: View {
        @ObservedObject var state: SelectionState

        var body: some View {
            ControlSegmentPicker("Appearance", selection: $state.selection,
                choices: AppTheme.allCases.map { .init($0.title, value: $0) })
                .disabled(!state.isEnabled)
                .padding(20)
                .frame(width: 500, height: 100)
        }
    }

    private func regions(in view: NSView) -> [ControlFeedbackView] {
        ((view as? ControlFeedbackView).map { [$0] } ?? []) + view.subviews.flatMap { regions(in: $0) }
    }

    private func hover(_ point: NSPoint, in window: NSWindow, regions: [ControlFeedbackView]) throws {
        for region in regions {
            region.updateTrackingAreas()
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

    private func arrow(_ code: UInt16, characters: String, in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    private func bitmap(_ view: NSView, named name: String) throws -> NSBitmapImageRep {
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: folder.appendingPathComponent(name + ".png"))
        }
        return bitmap
    }

    private func color(in bitmap: NSBitmapImageRep, region: ControlFeedbackView, hosting: NSView) throws -> NSColor {
        // Sample inside the selected fill, away from centered text and the focus border.
        let point = region.convert(NSPoint(x: region.feedbackRect.minX + 5, y: region.feedbackRect.midY), to: hosting)
        let x = Int((point.x - hosting.bounds.minX) * CGFloat(bitmap.pixelsWide) / hosting.bounds.width)
        let yInView = hosting.isFlipped ? point.y - hosting.bounds.minY : hosting.bounds.maxY - point.y
        let y = Int(yInView * CGFloat(bitmap.pixelsHigh) / hosting.bounds.height)
        return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }

    private func difference(_ first: NSColor, _ second: NSColor) -> CGFloat {
        abs(first.redComponent - second.redComponent) + abs(first.greenComponent - second.greenComponent) +
            abs(first.blueComponent - second.blueComponent)
    }

    @Test func segmentsHaveIndependentHoverAndSelectionInBothThemes() async throws {
        _ = NSApplication.shared
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let state = SelectionState()
            let hosting = NSHostingView(rootView: PickerHost(state: state))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            NSApplication.shared.activate(ignoringOtherApps: true)
            for _ in 0..<20 where !window.isKeyWindow {
                try await Task.sleep(for: .milliseconds(25))
                window.makeKey()
            }
            try #require(window.isKeyWindow)
            try await Task.sleep(for: .milliseconds(100))
            NativeButtonFocusPolicy().apply(to: window)
            let targets = regions(in: hosting).sorted {
                $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
            }
            #expect(targets.count == 3)
            guard targets.count == 3 else { continue }
            let rects = targets.map { $0.convert($0.cursorRect, to: nil) }
            #expect(rects.allSatisfy { !$0.isEmpty })
            for index in 0..<2 {
                #expect(!rects[index].intersects(rects[index + 1]))
                #expect(rects[index + 1].minX - rects[index].maxX >= ControlHoverAppearance.gap)
                let point = NSPoint(x: (rects[index].maxX + rects[index + 1].minX) / 2, y: rects[index].midY)
                try hover(point, in: window, regions: targets)
                #expect(targets.allSatisfy { !$0.isHovered })
            }
            for index in 0..<3 {
                let point = NSPoint(x: rects[index].midX, y: rects[index].midY)
                try hover(point, in: window, regions: targets)
                #expect(targets.filter { $0.isHovered }.count == 1)
                #expect(targets[index].isHovered)
                try click(point, in: window)
                try await Task.sleep(for: .milliseconds(50))
                #expect(state.selection == AppTheme.allCases[index])
                _ = try bitmap(hosting, named: "segments-\(name)-\(index)-hover")

                try hover(NSPoint(x: -20, y: -20), in: window, regions: targets)
                let image = try bitmap(hosting, named: "segments-\(name)-\(index)-selected")
                let selectedColor = try color(in: image, region: targets[index], hosting: hosting)
                let otherColor = try color(in: image, region: targets[(index + 1) % 3], hosting: hosting)
                #expect(difference(selectedColor, otherColor) > 0.03)
            }

            // Deliver real window key events to the focused production buttons.
            try click(NSPoint(x: rects[1].midX, y: rects[1].midY), in: window)
            try await Task.sleep(for: .milliseconds(50))
            for (code, characters, expected) in [
                (UInt16(124), "\u{F703}", AppTheme.dark),
                (UInt16(123), "\u{F702}", .light),
                (UInt16(123), "\u{F702}", .system),
                (UInt16(123), "\u{F702}", .system),
                (UInt16(125), "\u{F701}", .light),
                (UInt16(126), "\u{F700}", .system),
            ] {
                try arrow(code, characters: characters, in: window)
                try await Task.sleep(for: .milliseconds(50))
                #expect(state.selection == expected)
                let focused = targets.filter { $0.isKeyboardFocused }
                #expect(focused.count == 1)
                #expect(focused.first === targets[AppTheme.allCases.firstIndex(of: expected)!])
            }

            state.isEnabled = false
            try await Task.sleep(for: .milliseconds(100))
            NativeButtonFocusPolicy().apply(to: window)
            #expect(targets.allSatisfy { !$0.isEnabled })
            let disabledSelection = state.selection
            try click(NSPoint(x: rects[2].midX, y: rects[2].midY), in: window)
            try arrow(124, characters: "\u{F703}", in: window)
            try await Task.sleep(for: .milliseconds(50))
            #expect(state.selection == disabledSelection)
        }
    }
}
