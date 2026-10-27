import AppKit
import SwiftUI

extension View {
    /// Disclosure arrows belong to AppKit's outline row, outside the SwiftUI
    /// label. Mark the row instead of painting each part independently.
    func catalogRowHover() -> some View {
        background {
            CatalogRowHoverRegion()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .focusEffectDisabled()
    }
}

private struct CatalogRowHoverRegion: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> CatalogRowHoverAnchor { CatalogRowHoverAnchor() }

    func updateNSView(_ view: CatalogRowHoverAnchor, context: Context) {
        view.isEnabled = isEnabled
        view.installFeedback()
    }

    static func dismantleNSView(_ view: CatalogRowHoverAnchor, coordinator: ()) {
        view.releaseFeedback()
    }
}

final class CatalogRowHoverAnchor: NSView {
    fileprivate static let feedbacks = NSMapTable<NSTableRowView, CatalogRowFeedbackView>.weakToWeakObjects()
    var isEnabled = true { didSet { feedback?.refresh() } }
    private weak var feedback: CatalogRowFeedbackView?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        installFeedback()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installFeedback()
    }

    override func layout() {
        super.layout()
        installFeedback()
    }

    func enclosingRow() -> NSTableRowView? {
        var ancestor = superview
        while let view = ancestor {
            if let row = view as? NSTableRowView { return row }
            ancestor = view.superview
        }
        return nil
    }

    func installFeedback() {
        guard let row = enclosingRow() else { releaseFeedback(); return }
        let existing = Self.feedbacks.object(forKey: row)
        let region = existing ?? CatalogRowFeedbackView(frame: .zero)
        if feedback !== region { releaseFeedback() }
        if existing == nil {
            region.usesNativeAlignment = false
            region.autoresizingMask = [.width, .height]
            region.row = row
            Self.feedbacks.setObject(region, forKey: row)
        }
        feedback = region
        region.anchors.add(self)
        region.refresh()
    }

    func releaseFeedback() {
        let previous = feedback
        feedback = nil
        previous?.anchors.remove(self)
        previous?.refresh()
    }

    @discardableResult static func apply(in content: NSView) -> [CatalogRowFeedbackView] {
        func anchors(in view: NSView) -> [CatalogRowHoverAnchor] {
            ((view as? CatalogRowHoverAnchor).map { [$0] } ?? []) + view.subviews.flatMap { anchors(in: $0) }
        }
        let markers = anchors(in: content)
        var regions: [CatalogRowFeedbackView] = []
        var seen = Set<ObjectIdentifier>()
        for marker in markers {
            marker.installFeedback()
            if let region = marker.feedback, seen.insert(ObjectIdentifier(region)).inserted { regions.append(region) }
        }
        return regions
    }

    static func feedback(containing view: NSView) -> CatalogRowFeedbackView? {
        var ancestor: NSView? = view
        while let candidate = ancestor {
            if let row = candidate as? NSTableRowView {
                return feedbacks.object(forKey: row)
            }
            ancestor = candidate.superview
        }
        return nil
    }
}

final class CatalogRowFeedbackView: ControlFeedbackView {
    weak var row: NSTableRowView?
    let anchors = NSHashTable<CatalogRowHoverAnchor>.weakObjects()

    func refresh() {
        guard let row else { removeFromSuperview(); return }
        for anchor in anchors.allObjects where anchor.enclosingRow() !== row { anchors.remove(anchor) }
        guard !anchors.allObjects.isEmpty else {
            if CatalogRowHoverAnchor.feedbacks.object(forKey: row) === self {
                CatalogRowHoverAnchor.feedbacks.removeObject(forKey: row)
            }
            removeFromSuperview()
            return
        }
        // Keep feedback inside the native row so outline animation snapshots
        // and live content cannot paint two independently positioned surfaces.
        if superview !== row { row.addSubview(self, positioned: .above, relativeTo: nil) }
        let rect = row.bounds
        let target = rect.width > ControlHoverAppearance.gap * 2
            ? rect.insetBy(dx: ControlHoverAppearance.gap, dy: 0) : .zero
        if frame != target { frame = target }
        isEnabled = anchors.allObjects.allSatisfy { $0.isEnabled }
        updateTrackingAreas()
    }
}
