import AppKit
import SwiftUI

enum TextInputAppearance {
    static let padding: CGFloat = 4
}

/// A field keeps AppKit's editor, caret, selection and I-beam. Only its native
/// blue ring is replaced; this view never takes a click or installs a cursor.
@MainActor
final class NativeFieldFocusView: NSView {
    func updateFrame(for field: NSTextField) {
        // Native bezels already provide some padding; borderless Form fields
        // provide none. Fill only the missing space, including compact fields.
        // Keep search icons and clear buttons inside the outline as well.
        let textRect = field.cell?.drawingRect(forBounds: field.bounds) ?? field.bounds
        let frame = field.bounds.union(textRect.insetBy(
            dx: -TextInputAppearance.padding, dy: -TextInputAppearance.padding))
        if self.frame != frame { self.frame = frame }
    }

    var isFocused = false {
        didSet { if isFocused != oldValue { needsDisplay = true } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard isFocused else { return }
        let rect = bounds.insetBy(dx: ControlHoverAppearance.inset, dy: ControlHoverAppearance.inset)
        guard !rect.isEmpty else { return }
        NSColor(AppPalette.accent).withAlphaComponent(0.45).setStroke()
        let path = NSBezierPath(roundedRect: rect,
            xRadius: ControlHoverAppearance.cornerRadius, yRadius: ControlHoverAppearance.cornerRadius)
        path.lineWidth = 1
        path.stroke()
    }
}
