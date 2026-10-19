import AppKit

/// SwiftUI's focus effect and AppKit's button/cell focus rings are separate.
/// Replace native rings before a window draws, including newly created sheets.
/// Native buttons in alerts and outline disclosures also need hover feedback.
@MainActor
final class NativeButtonFocusPolicy: NSObject {
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateAllWindows),
            name: NSApplication.willUpdateNotification, object: nil)
        for name in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateWindow(_:)),
                name: name, object: nil)
        }
        for window in NSApplication.shared.windows { apply(to: window) }
    }

    func apply(to window: NSWindow) {
        guard let content = window.contentView else { return }
        let isInteractionBlocked = Self.isInteractionBlocked(in: window)
        let rowRegions = CatalogRowHoverAnchor.apply(in: content)
        let regions = hoverRegions(in: content)
        let controls = nativeControls(in: content)
        // Compute ownership before mutating the view tree. A wide clickable row
        // must never steal a small child's native button or retain an old owner.
        var owners: [ObjectIdentifier: NSControl] = [:]
        var claimed = Set<ObjectIdentifier>()
        for control in controls {
            if CatalogRowHoverAnchor.feedback(containing: control) != nil { continue }
            let rect = control.convert(control.hoverAlignmentRect, to: nil)
            let region = regions.filter { region in
                let bounds = region.convert(region.bounds, to: nil)
                let sameBounds = abs(bounds.midX - rect.midX) <= 4 && abs(bounds.midY - rect.midY) <= 4 &&
                    abs(bounds.width - rect.width) <= 4 && abs(bounds.height - rect.height) <= 4 &&
                    owners[ObjectIdentifier(region)] == nil
                // Labelled pickers/toggles can include SwiftUI text outside
                // their native control. Keep ownership on that explicit target.
                let labelledControl =
                    bounds.contains(NSPoint(x: rect.midX, y: rect.midY)) &&
                    rect.width <= bounds.width + 4 && rect.height <= bounds.height + 4 &&
                    owners[ObjectIdentifier(region)] == nil
                return sameBounds || labelledControl
            }.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
            if let region {
                owners[ObjectIdentifier(region)] = control
                claimed.insert(ObjectIdentifier(control))
            }
        }
        for region in regions {
            region.isInteractionBlocked = isInteractionBlocked
            region.nativeControl = owners[ObjectIdentifier(region)]
            region.isNativeKeyboardFocused = region.nativeControl.map { Self.hasKeyboardFocus($0, in: window) } ?? false
        }
        for region in rowRegions {
            region.isInteractionBlocked = isInteractionBlocked
            region.isNativeKeyboardFocused = controls.contains {
                CatalogRowHoverAnchor.feedback(containing: $0) === region && Self.hasKeyboardFocus($0, in: window)
            }
        }
        for control in controls {
            // AppKit offsets the disclosure image within its button. Align the
            // image itself with the row, using current geometry to avoid drift.
            if let button = control as? NSButton, button.title.isEmpty,
               let cell = button.cell,
               let row = CatalogRowHoverAnchor.feedback(containing: button)?.row,
               let parent = button.superview {
                let imageRect = button.convert(cell.imageRect(forBounds: button.bounds), to: parent)
                let rowRect = row.convert(row.bounds, to: parent)
                let offset = rowRect.midY - imageRect.midY
                if abs(offset) > 0.01 {
                    button.setFrameOrigin(NSPoint(x: button.frame.minX, y: button.frame.minY + offset))
                }
            }
            if control.focusRingType != .none { control.focusRingType = .none }
            if let cell = control.cell, cell.focusRingType != .none { cell.focusRingType = .none }
            if claimed.contains(ObjectIdentifier(control)) || CatalogRowHoverAnchor.feedback(containing: control) != nil {
                for overlay in control.subviews where overlay is NativeButtonHoverView {
                    overlay.removeFromSuperview()
                }
            } else {
                control.installHoverFeedback()
                for overlay in control.subviews.compactMap({ $0 as? NativeButtonHoverView }) {
                    overlay.isInteractionBlocked = isInteractionBlocked
                    overlay.isEnabled = control.isEnabled
                    overlay.isNativeKeyboardFocused = Self.hasKeyboardFocus(control, in: window)
                }
            }
        }
        // File panels belong to macOS. App fields and alert accessories use our
        // amber indication without touching their field editor or selection.
        if !(window is NSSavePanel) {
            suppressContainerRings(in: content)
            for field in textFields(in: content) {
                let overlays = field.subviews.compactMap { $0 as? NativeFieldFocusView }
                guard field.isEditable || field.isSelectable else {
                    for overlay in overlays { overlay.removeFromSuperview() }
                    continue
                }
                if field.focusRingType != .none { field.focusRingType = .none }
                if let cell = field.cell, cell.focusRingType != .none { cell.focusRingType = .none }
                // Read-only result labels use the grid's selection indication.
                guard field.isEditable || field.isBordered || field.isBezeled else {
                    for overlay in overlays { overlay.removeFromSuperview() }
                    continue
                }
                let overlay = overlays.first ?? {
                    let overlay = NativeFieldFocusView(frame: field.bounds)
                    overlay.autoresizingMask = [.width, .height]
                    field.addSubview(overlay)
                    return overlay
                }()
                overlay.updateFrame(for: field)
                overlay.isFocused = Self.hasKeyboardFocus(field, in: window)
            }
        }
    }

    private static func isInteractionBlocked(in window: NSWindow) -> Bool {
        if window.attachedSheet != nil { return true }
        guard let modal = NSApplication.shared.modalWindow else { return false }
        // App-modal Open/Save panels block other windows too. Their sheets and
        // child popovers remain interactive while they belong to that panel.
        var owner: NSWindow? = window
        while let current = owner {
            if current === modal { return false }
            owner = current.sheetParent ?? current.parent
        }
        return true
    }

    static func hasKeyboardFocus(_ control: NSControl, in window: NSWindow) -> Bool {
        guard window.isKeyWindow, control.isEnabled else { return false }
        if window.firstResponder === control { return true }
        // NSTextField lends editing to the window's shared NSTextView. The
        // editor's delegate is deliberately left to AppKit/SwiftUI.
        guard let editor = (control as? NSTextField)?.currentEditor() else { return false }
        return window.firstResponder === editor
    }

    @objc private func updateWindow(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        apply(to: window)
    }

    @objc private func updateAllWindows() {
        for window in NSApplication.shared.windows { apply(to: window) }
    }

    private func hoverRegions(in view: NSView) -> [ControlFeedbackView] {
        if let region = view as? ControlFeedbackView {
            return region is NativeButtonHoverView || region is CatalogRowFeedbackView ? [] : [region]
        }
        return view.subviews.flatMap { hoverRegions(in: $0) }
    }

    private func nativeControls(in view: NSView) -> [NSControl] {
        let controls: [NSControl]
        if let control = view as? NSControl, control is NSButton || control is NSSegmentedControl {
            controls = [control]
        } else { controls = [] }
        return controls + view.subviews.flatMap { nativeControls(in: $0) }
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
    }

    private func suppressContainerRings(in view: NSView) {
        if view is NSScrollView || view is NSTextView || view is NSTableView {
            if view.focusRingType != .none { view.focusRingType = .none }
        }
        if let textView = view as? NSTextView, textView.isEditable, !textView.isFieldEditor {
            let inset = NSSize(width: TextInputAppearance.padding, height: TextInputAppearance.padding)
            if textView.textContainerInset != inset { textView.textContainerInset = inset }
            if let container = textView.textContainer, container.lineFragmentPadding != 0 {
                container.lineFragmentPadding = 0
            }
        }
        if let table = view as? NSTableView, table.selectionHighlightStyle != .none {
            // Result grids and selectable connection rows paint the amber
            // selection themselves. AppKit's source-list fill ignores tint.
            table.selectionHighlightStyle = .none
        }
        for subview in view.subviews { suppressContainerRings(in: subview) }
    }
}
