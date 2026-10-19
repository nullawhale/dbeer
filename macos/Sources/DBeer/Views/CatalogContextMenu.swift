import AppKit
import SwiftUI

extension View {
    func catalogContextMenu() -> some View {
        overlay {
            CatalogContextMenuRegion()
                .accessibilityHidden(true)
        }
    }
}

private struct CatalogContextMenuRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> CatalogContextMenuView { CatalogContextMenuView() }
    func updateNSView(_ view: CatalogContextMenuView, context: Context) {}
}

/// Keep SwiftUI's outline menus, but present them from the catalog's viewport.
/// NSTableView otherwise adds its own blue context-menu outline independently
/// of both the SwiftUI tint and the native focus-ring setting.
final class CatalogContextMenuView: NSView {
    override func isAccessibilityElement() -> Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApplication.shared.currentEvent,
              isContextClick(event),
              bounds.contains(convert(point, from: superview)),
              catalogTable(for: event) != nil else { return nil }
        return self
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        catalogTable(for: event)?.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if isContextClick(event) { rightMouseDown(with: event) }
        else { super.mouseDown(with: event) }
    }

    private func isContextClick(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown ||
            (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    private func catalogTable(for event: NSEvent) -> NSTableView? {
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView,
               table.visibleRect.contains(table.convert(event.locationInWindow, from: nil)) {
                return table
            }
            for child in view.subviews where child !== self {
                if let table = table(in: child) { return table }
            }
            return nil
        }

        // SwiftUI places the overlay beside the outline's platform host, so
        // search the nearest containing subtree rather than relying on a
        // particular private SwiftUI view class or the window's first table.
        var ancestor = superview
        while let view = ancestor {
            if let result = table(in: view) { return result }
            ancestor = view.superview
        }
        return nil
    }
}
