import AppKit
import Foundation
import Testing

/// Selects the native tab before existing UI checks inspect its controls.
/// This helper does not create or activate a window.
@MainActor
enum NativeConnectionEditorTabs {
    static func select(_ title: String, in root: NSView) async throws {
        func tabViews(_ view: NSView) -> [NSTabView] {
            ((view as? NSTabView).map { [$0] } ?? []) + view.subviews.flatMap(tabViews)
        }
        if let tabs = tabViews(root).first(where: { $0.tabViewItems.contains { $0.label == title } }),
           let item = tabs.tabViewItems.first(where: { $0.label == title }) {
            tabs.selectTabViewItem(item)
        } else {
            var visited = Set<ObjectIdentifier>()
            func find(_ object: NSObject) -> NSObject? {
                guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
                func value(_ name: String) -> AnyObject? {
                    let selector = NSSelectorFromString(name)
                    return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
                }
                let label = value("accessibilityLabel") as? String
                let role = value("accessibilityRole") as? String
                if label == title, role == "AXRadioButton" || role == "AXButton" || role == "AXTab" { return object }
                for child in (value("accessibilityChildren") as? [NSObject] ?? []) {
                    if let found = find(child) { return found }
                }
                for child in (object as? NSView)?.subviews ?? [] {
                    if let found = find(child) { return found }
                }
                return nil
            }
            let tab = try #require(find(root), "Missing connection editor tab: \(title)")
            let selector = NSSelectorFromString("accessibilityPerformPress")
            try #require(tab.responds(to: selector))
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            try #require(unsafeBitCast(tab.method(for: selector), to: Press.self)(tab, selector))
        }
        try await Task.sleep(for: .milliseconds(120))
        root.layoutSubtreeIfNeeded()
    }
}
