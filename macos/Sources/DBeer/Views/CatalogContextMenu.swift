import AppKit
import SwiftUI

extension View {
    func catalogContextMenu() -> some View {
        overlay {
            CatalogContextMenuRegion()
                .accessibilityHidden(true)
        }
    }

    func catalogRowContextMenu(_ makeMenu: @escaping @MainActor () -> NSMenu) -> some View {
        background {
            CatalogMenuAnchorRegion(makeMenu: makeMenu)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}

private struct CatalogMenuAnchorRegion: NSViewRepresentable {
    let makeMenu: @MainActor () -> NSMenu

    func makeNSView(context: Context) -> CatalogMenuAnchor { CatalogMenuAnchor() }
    func updateNSView(_ view: CatalogMenuAnchor, context: Context) { view.makeMenu = makeMenu }
}

private final class CatalogMenuAnchor: NSView {
    var makeMenu: (@MainActor () -> NSMenu)?
    override func isAccessibilityElement() -> Bool { false }
}

@MainActor private final class CatalogMenuAction: NSObject {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func invokeMenuAction(_ sender: NSMenuItem) { action() }
}

@MainActor extension NSMenu {
    func addCatalogAction(_ title: String, enabled: Bool = true, identifier: String? = nil,
                          action: @escaping @MainActor () -> Void) {
        autoenablesItems = false
        let target = CatalogMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(CatalogMenuAction.invokeMenuAction(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target // NSMenuItem does not retain its target.
        item.isEnabled = enabled
        if let identifier {
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.setAccessibilityIdentifier(identifier)
        }
        addItem(item)
    }
}

private struct CatalogContextMenuRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> CatalogContextMenuView { CatalogContextMenuView() }
    func updateNSView(_ view: CatalogContextMenuView, context: Context) {}
}

/// Present row menus from the viewport without asking NSTableView for its menu.
/// On macOS 14/15 that request itself enables the blue contextual row outline,
/// even when another view subsequently presents the returned menu.
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
        guard let table = catalogTable(for: event) else { return nil }
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        guard row >= 0, let rowView = table.rowView(atRow: row, makeIfNecessary: false) else { return nil }
        func anchor(in view: NSView) -> CatalogMenuAnchor? {
            if let anchor = view as? CatalogMenuAnchor { return anchor }
            for child in view.subviews {
                if let result = anchor(in: child) { return result }
            }
            return nil
        }
        return anchor(in: rowView)?.makeMenu?()
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
