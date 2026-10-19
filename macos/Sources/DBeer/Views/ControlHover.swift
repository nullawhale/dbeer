import AppKit
import SwiftUI

/// Both SwiftUI and AppKit use the same shape, color and inset. Native button
/// alignment insets exclude the invisible margin around the painted bezel.
enum ControlHoverAppearance {
    static let cornerRadius: CGFloat = 5
    static let inset: CGFloat = 1
    static let gap: CGFloat = 4
    static let fillOpacity = 0.12
    static let borderOpacity = 0.25
}

private struct ControlKeyboardFocusKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var controlKeyboardFocus: Bool {
        get { self[ControlKeyboardFocusKey.self] }
        set { self[ControlKeyboardFocusKey.self] = newValue }
    }
}

extension View {
    func controlHover() -> some View {
        modifier(ControlHover(usesNativeAlignment: true))
    }
}

extension Toggle {
    func controlHover() -> some View {
        // The checkbox and its SwiftUI label form one clickable target.
        modifier(ControlHover(usesNativeAlignment: false))
    }
}

private struct ControlHover: ViewModifier {
    let usesNativeAlignment: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlKeyboardFocus) private var isKeyboardFocused
    @FocusState private var isControlFocused: Bool

    func body(content: Content) -> some View {
        content.overlay {
            ControlFeedbackRegion(isEnabled: isEnabled, isKeyboardFocused: isKeyboardFocused || isControlFocused,
                usesNativeAlignment: usesNativeAlignment)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .focused($isControlFocused)
        .focusEffectDisabled()
    }
}

private struct ControlFeedbackRegion: NSViewRepresentable {
    let isEnabled: Bool
    let isKeyboardFocused: Bool
    let usesNativeAlignment: Bool

    func makeNSView(context: Context) -> ControlFeedbackView { ControlFeedbackView() }

    func updateNSView(_ view: ControlFeedbackView, context: Context) {
        view.isEnabled = isEnabled
        view.isKeyboardFocused = isKeyboardFocused
        view.usesNativeAlignment = usesNativeAlignment
    }
}

/// Cursor rectangles restore the editor's I-beam and support nested tab/close
/// targets without balancing a global cursor push/pop stack.
class ControlCursorView: NSView {
    var cursorRect: NSRect { bounds.intersection(visibleRect) }
    var isInteractionBlocked = false {
        didSet {
            if isInteractionBlocked != oldValue {
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
            }
        }
    }
    var isEnabled = true {
        didSet {
            if isEnabled != oldValue {
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled, !isInteractionBlocked, !cursorRect.isEmpty {
            addCursorRect(cursorRect, cursor: .pointingHand)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }
}

class ControlFeedbackView: ControlCursorView {
    override var isInteractionBlocked: Bool {
        didSet {
            if isInteractionBlocked { isHovered = false }
            else if oldValue, let window, window.isVisible {
                isHovered = cursorRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
            }
        }
    }
    var usesNativeAlignment = true {
        didSet {
            if usesNativeAlignment != oldValue {
                needsDisplay = true
                window?.invalidateCursorRects(for: self)
                updateTrackingAreas()
            }
        }
    }
    weak var nativeControl: NSControl? {
        didSet {
            if nativeControl !== oldValue {
                needsDisplay = true
                window?.invalidateCursorRects(for: self)
                updateTrackingAreas()
            }
        }
    }
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    var isKeyboardFocused = false {
        didSet { if isKeyboardFocused != oldValue { needsDisplay = true } }
    }
    var isNativeKeyboardFocused = false {
        didSet { if isNativeKeyboardFocused != oldValue { needsDisplay = true } }
    }
    private var hoverArea: NSTrackingArea?
    private var trackedWindowRect: NSRect?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let rect = cursorRect
        let windowRect = window.map { _ in convert(rect, to: nil) }
        if let hoverArea, hoverArea.rect == rect, trackedWindowRect == windowRect,
           trackingAreas.contains(where: { $0 === hoverArea }) { return }
        if let hoverArea { removeTrackingArea(hoverArea) }
        if isHovered, let window {
            // Removing an old tracking area does not deliver its mouseExited.
            // Recheck a stationary pointer after scrolling/resizing/moving.
            isHovered = rect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        trackedWindowRect = windowRect
        guard !rect.isEmpty else { hoverArea = nil; isHovered = false; return }
        let area = NSTrackingArea(rect: rect,
            options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
    }

    override func mouseEntered(with event: NSEvent) { isHovered = !isInteractionBlocked }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private var paintBounds: NSRect {
        if usesNativeAlignment, let nativeControl {
            let rect = convert(nativeControl.hoverAlignmentRect, from: nativeControl)
            return rect.intersection(bounds)
        }
        return bounds
    }

    override var cursorRect: NSRect {
        paintBounds.intersection(super.cursorRect)
    }

    var feedbackRect: NSRect {
        // Paint remains stable while clipping; only pointer/tracking is clipped.
        paintBounds.insetBy(dx: ControlHoverAppearance.inset, dy: ControlHoverAppearance.inset)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered || isKeyboardFocused || isNativeKeyboardFocused,
              isEnabled, !isInteractionBlocked, nativeControl?.isEnabled != false, !feedbackRect.isEmpty else { return }
        let rect = feedbackRect
        let path = NSBezierPath(roundedRect: rect,
            xRadius: ControlHoverAppearance.cornerRadius, yRadius: ControlHoverAppearance.cornerRadius)
        let accent = NSColor(AppPalette.accent)
        if isHovered {
            accent.withAlphaComponent(ControlHoverAppearance.fillOpacity).setFill()
            path.fill()
        }
        accent.withAlphaComponent(isHovered ? ControlHoverAppearance.borderOpacity : 0.45).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

extension NSControl {
    var hoverAlignmentRect: NSRect {
        // alignmentRect(forFrame:) works in the superview's coordinates. A
        // popup is flipped while its SwiftUI adaptor is not, so applying its
        // asymmetric insets to bounds shifts the feedback down by three points.
        guard let superview else { return bounds }
        return convert(alignmentRect(forFrame: frame), from: superview)
    }

    func installHoverFeedback() {
        guard !subviews.contains(where: { $0 is NativeButtonHoverView }) else { return }
        let hover = NativeButtonHoverView(frame: bounds)
        hover.nativeControl = self
        hover.autoresizingMask = [.width, .height]
        addSubview(hover)
    }
}

/// Alerts and outline disclosure buttons have no SwiftUI hover modifier.
final class NativeButtonHoverView: ControlFeedbackView {
    override func resetCursorRects() {
        isEnabled = nativeControl?.isEnabled == true
        super.resetCursorRects()
    }
}
