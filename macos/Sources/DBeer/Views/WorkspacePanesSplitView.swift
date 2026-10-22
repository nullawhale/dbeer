import AppKit
import SwiftUI

/// The hosting boundary also records native responder ownership. Field editors
/// are shared by NSWindow, so their NSTextField delegate supplies the ancestry.
@MainActor
final class WorkspacePaneContainerView: NSView {
    let paneID: WorkspacePaneID
    weak var workspace: ApplicationWorkspace?
    let host: NSHostingView<AnyView>

    init(paneID: WorkspacePaneID, workspace: ApplicationWorkspace, content: AnyView) {
        self.paneID = paneID
        self.workspace = workspace
        host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(paneID == .left ? "Left working pane" : "Right working pane")
        setAccessibilityIdentifier("workspacePane-\(paneID.rawValue)")
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { workspace?.activatePane(paneID) }
        return accepted
    }

    static func owningPane(of responder: NSResponder?, in workspace: ApplicationWorkspace) -> WorkspacePaneID? {
        var view: NSView?
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            view = editor.delegate as? NSView
        } else { view = responder as? NSView }
        while let current = view {
            if let container = current as? WorkspacePaneContainerView, container.workspace === workspace {
                return container.paneID
            }
            view = current.superview
        }
        return nil
    }

    static func activatePane(containing responder: NSResponder?) {
        var view = responder as? NSView
        if let editor = responder as? NSTextView, editor.isFieldEditor { view = editor.delegate as? NSView }
        while let current = view {
            if let container = current as? WorkspacePaneContainerView {
                container.workspace?.activatePane(container.paneID)
                return
            }
            view = current.superview
        }
    }
}

/// NSSplitView provides the native divider, cursor and dragging behavior while
/// keeping the saved fraction independent from document/session ownership.
final class WorkspacePanesNativeSplitView: NSSplitView {
    private(set) var isUserAdjustingDivider = false

    override func mouseDown(with event: NSEvent) {
        isUserAdjustingDivider = true
        defer { isUserAdjustingDivider = false }
        super.mouseDown(with: event)
    }
}

struct WorkspacePanesSplitView<Left: View, Right: View>: NSViewRepresentable {
    @ObservedObject var workspace: ApplicationWorkspace
    let left: Left
    let right: Right

    init(workspace: ApplicationWorkspace, @ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.workspace = workspace
        self.left = left()
        self.right = right()
    }

    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }

    func makeNSView(context: Context) -> NSSplitView {
        let split = WorkspacePanesNativeSplitView(frame: .zero)
        split.isVertical = true
        split.dividerStyle = .thin
        split.setAccessibilityIdentifier("workspacePanesSplit")
        split.addArrangedSubview(WorkspacePaneContainerView(paneID: .left, workspace: workspace, content: AnyView(left)))
        split.addArrangedSubview(WorkspacePaneContainerView(paneID: .right, workspace: workspace, content: AnyView(right)))
        split.delegate = context.coordinator
        context.coordinator.install(in: split)
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        (split.arrangedSubviews[0] as? WorkspacePaneContainerView)?.host.rootView = AnyView(left)
        (split.arrangedSubviews[1] as? WorkspacePaneContainerView)?.host.rootView = AnyView(right)
        context.coordinator.applySavedFraction(in: split)
    }

    static func dismantleNSView(_ split: NSSplitView, coordinator: Coordinator) { coordinator.stopMonitoring() }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        private weak var workspace: ApplicationWorkspace?
        private weak var split: NSSplitView?
        private var eventMonitor: Any?
        private weak var previousResponder: NSResponder?
        private var applyingFraction = false
        private var savedFraction: Double?

        init(workspace: ApplicationWorkspace) { self.workspace = workspace }

        func install(in split: NSSplitView) {
            self.split = split
            NotificationCenter.default.addObserver(self, selector: #selector(updateResponder),
                name: NSApplication.willUpdateNotification, object: nil)
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let workspace = self.workspace, let split = self.split,
                      event.window === split.window, event.window === workspace.presentationWindow,
                      NSApp.modalWindow == nil, event.window?.attachedSheet == nil else { return event }
                let point = split.convert(event.locationInWindow, from: nil)
                if let pane = split.arrangedSubviews.compactMap({ $0 as? WorkspacePaneContainerView })
                    .first(where: { $0.frame.contains(point) }) { workspace.activatePane(pane.paneID) }
                return event
            }
            applySavedFraction(in: split, force: true)
        }

        func stopMonitoring() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func updateResponder() {
            guard let workspace, let window = split?.window, window === workspace.presentationWindow,
                  window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            let responder = window.firstResponder
            // A toolbar invocation deliberately preserves the opposite editor's
            // focus. Only a new native focus transition changes the active pane.
            guard responder !== previousResponder else { return }
            previousResponder = responder
            if let pane = WorkspacePaneContainerView.owningPane(of: responder, in: workspace) {
                workspace.activatePane(pane)
            }
        }

        private func dividerPosition(in split: NSSplitView, fraction: Double) -> CGFloat {
            let width = max(0, split.bounds.width - split.dividerThickness)
            let minimum = min(280, width / 2)
            return min(max(CGFloat(fraction) * width, minimum), width - minimum)
        }

        func applySavedFraction(in split: NSSplitView, force: Bool = false) {
            guard let workspace, split.arrangedSubviews.count == 2,
                  split.bounds.width > split.dividerThickness else { return }
            let fraction = workspace.paneLayout.splitFraction
            guard force || savedFraction != fraction else { return }
            applyingFraction = true
            defer { applyingFraction = false }
            // The resize delegate owns the complete arrangement. setPosition
            // cannot initialize zero-width panes because its possible divider
            // range is derived from their existing frames.
            let bounds = split.bounds
            let position = dividerPosition(in: split, fraction: fraction)
            let rightOrigin = bounds.minX + position + split.dividerThickness
            split.arrangedSubviews[0].frame = NSRect(x: bounds.minX, y: bounds.minY,
                width: position, height: bounds.height)
            split.arrangedSubviews[1].frame = NSRect(x: rightOrigin, y: bounds.minY,
                width: max(0, bounds.maxX - rightOrigin), height: bounds.height)
            split.needsDisplay = true
            savedFraction = fraction
        }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            applySavedFraction(in: splitView, force: true)
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            let width = max(0, splitView.bounds.width - splitView.dividerThickness)
            return max(min(280, width / 2), width * CGFloat(WorkspacePaneLayout.splitRange.lowerBound))
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            let width = max(0, splitView.bounds.width - splitView.dividerThickness)
            return min(width - min(280, width / 2), width * CGFloat(WorkspacePaneLayout.splitRange.upperBound))
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
        nonisolated func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView,
                                   forDoubleClickOnDividerAt dividerIndex: Int) -> Bool { false }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !applyingFraction, let workspace, let split,
                  (split as? WorkspacePanesNativeSplitView)?.isUserAdjustingDivider == true,
                  split.bounds.width > split.dividerThickness, let first = split.arrangedSubviews.first else { return }
            let fraction = Double(first.frame.width / (split.bounds.width - split.dividerThickness))
            savedFraction = fraction
            // Divider callbacks can happen during SwiftUI reconciliation. The
            // next main-actor turn publishes only the latest user position.
            Task { @MainActor [weak self] in
                guard let self, self.savedFraction == fraction else { return }
                workspace.setSplitFraction(fraction)
                self.savedFraction = workspace.paneLayout.splitFraction
            }
        }
    }
}
