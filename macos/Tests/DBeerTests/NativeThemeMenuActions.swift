import AppKit
import Foundation
import Testing

/// SwiftUI populates popup menus lazily on some SDKs. Open the real menu before
/// invoking its item target/action rather than inspecting an empty cached menu.
@MainActor
enum NativeThemeMenuActions {
    static func buttons(in root: NSView) -> [NSButton] {
        func descendants(_ view: NSView) -> [NSButton] {
            ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(descendants)
        }
        return descendants(root).filter {
            $0 is NSPopUpButton || $0.accessibilityRole() == .popUpButton ||
                String(describing: type(of: $0)).localizedCaseInsensitiveContains("popupbutton")
        }
    }

    static func select(_ title: String, in button: NSButton) async throws {
        let state = TrackingState(title: title)
        NotificationCenter.default.addObserver(state, selector: #selector(TrackingState.menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        // A menu tracks synchronously. A timer in AppKit's tracking run loop
        // performs the actual NSMenuItem action while that loop is active.
        let timer = Timer(timeInterval: 0.02, target: state, selector: #selector(TrackingState.tick(_:)),
            userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer {
            timer.invalidate()
            state.menu?.cancelTracking()
            NotificationCenter.default.removeObserver(state, name: NSMenu.didBeginTrackingNotification, object: nil)
        }
        button.performClick(nil)
        if state.menu == nil && !state.completed {
            try await Task.sleep(for: .milliseconds(100))
        }
        if state.menu == nil && !state.completed {
            // SwiftUI's popup subclass can leave performClick as a plain button
            // action. Send its normal local mouse-down path to open the menu.
            let window = try #require(button.window)
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            button.mouseDown(with: event)
        }
        while !state.completed && Date() < state.deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(state.completed,
            "Native popup did not perform \(title). Visible menu items: \(state.visibleTitles)")
    }

    @MainActor
    private final class TrackingState: NSObject {
        let title: String
        let deadline = Date().addingTimeInterval(3)
        var menu: NSMenu?
        var visibleTitles: [String] = []
        var completed = false

        init(title: String) { self.title = title }

        @objc func menuDidBeginTracking(_ notification: Notification) {
            menu = notification.object as? NSMenu
        }

        @objc func tick(_ timer: Timer) {
            guard !completed else { timer.invalidate(); return }
            if let menu {
                menu.update()
                visibleTitles = menu.items.map(\.title)
                if let action = action(in: menu) {
                    action.menu.performActionForItem(at: action.index)
                    completed = true
                    menu.cancelTracking()
                    timer.invalidate()
                    return
                }
            }
            if Date() >= deadline {
                menu?.cancelTracking()
                timer.invalidate()
            }
        }

        func action(in menu: NSMenu) -> (menu: NSMenu, index: Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.title == title && item.isEnabled { return (menu, index) }
                if let submenu = item.submenu, let action = action(in: submenu) { return action }
            }
            return nil
        }
    }
}
