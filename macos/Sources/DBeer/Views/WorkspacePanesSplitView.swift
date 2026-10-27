import AppKit
import SwiftUI

@MainActor
private protocol WorkspacePaneFocusSampling: AnyObject {
    func acknowledgeResponder(_ responder: NSResponder?)
}

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
        setAccessibilityLabel(workspace.paneTitle(paneID))
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
        if accepted { Self.activatePane(containing: self) }
        return accepted
    }

    static func owningPane(of responder: NSResponder?, in workspace: ApplicationWorkspace) -> WorkspacePaneID? {
        guard let container = container(owning: responder), container.workspace === workspace,
              workspace.paneLayout.paneIDs.contains(container.paneID) else { return nil }
        return container.paneID
    }

    /// Accepted commands may target the opposite pane while keeping native
    /// focus. Consume its current baseline before that explicit activation, so
    /// the deferred focus sampler cannot replay an earlier transition over it.
    static func acknowledgeCurrentResponder(in workspace: ApplicationWorkspace) {
        let responder = workspace.presentationWindow?.firstResponder
        guard let container = container(owning: responder), container.workspace === workspace else { return }
        container.acknowledgeResponder(responder)
    }

    static func activatePane(containing responder: NSResponder?) {
        guard let container = container(owning: responder),
              container.workspace?.paneLayout.paneIDs.contains(container.paneID) == true else { return }
        container.acknowledgeResponder(responder)
        container.workspace?.activatePane(container.paneID)
    }

    private static func container(owning responder: NSResponder?) -> WorkspacePaneContainerView? {
        var view: NSView?
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            view = editor.delegate as? NSView
        } else { view = responder as? NSView }
        while let current = view {
            if let container = current as? WorkspacePaneContainerView { return container }
            view = current.superview
        }
        return nil
    }

    private func acknowledgeResponder(_ responder: NSResponder?) {
        var ancestor: NSView? = self
        while let current = ancestor {
            if let host = current as? WorkspacePanesHostView, let sampling = host.focusSampler {
                sampling.acknowledgeResponder(responder)
                return
            }
            ancestor = current.superview
        }
    }
}

/// Native split views retain stable hosting boundaries as the tree changes.
final class WorkspacePanesNativeSplitView: NSSplitView {
    var splitID = UUID()
    var fraction = 0.5
    var applyingFraction = false
    private(set) var isUserAdjustingDivider = false
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isUserAdjustingDivider = true
        defer { isUserAdjustingDivider = false }
        super.mouseDown(with: event)
    }
}

final class WorkspacePanesHostView: NSView {
    fileprivate weak var focusSampler: (any WorkspacePaneFocusSampling)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }
}

struct WorkspacePanesSplitView<Content: View>: NSViewRepresentable {
    @ObservedObject var workspace: ApplicationWorkspace
    let content: (WorkspacePaneID) -> Content

    init(workspace: ApplicationWorkspace, @ViewBuilder content: @escaping (WorkspacePaneID) -> Content) {
        self.workspace = workspace
        self.content = content
    }

    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }

    func makeNSView(context: Context) -> WorkspacePanesHostView {
        let host = WorkspacePanesHostView(frame: .zero)
        host.setAccessibilityIdentifier("workspacePanesSplit")
        context.coordinator.install(in: host)
        context.coordinator.update(in: host, contents: contents)
        return host
    }

    private var contents: [WorkspacePaneID: AnyView] {
        Dictionary(uniqueKeysWithValues: workspace.paneLayout.paneIDs.map { ($0, AnyView(content($0))) })
    }

    func updateNSView(_ host: WorkspacePanesHostView, context: Context) {
        context.coordinator.update(in: host, contents: contents)
    }

    static func dismantleNSView(_ host: WorkspacePanesHostView, coordinator: Coordinator) { coordinator.stopMonitoring() }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate, WorkspacePaneFocusSampling {
        private weak var workspace: ApplicationWorkspace?
        private weak var host: WorkspacePanesHostView?
        private var eventMonitor: Any?
        private weak var previousResponder: NSResponder?
        private var panes: [WorkspacePaneID: WorkspacePaneContainerView] = [:]
        private var splits: [UUID: WorkspacePanesNativeSplitView] = [:]
        private var pendingFractions: [UUID: Double] = [:]

        init(workspace: ApplicationWorkspace) { self.workspace = workspace }

        func update(in host: WorkspacePanesHostView, contents: [WorkspacePaneID: AnyView]) {
            guard let workspace else { return }
            let root = workspace.paneLayout.root
            let rootView = view(for: root, contents: contents, workspace: workspace)
            if host.subviews.first !== rootView {
                host.subviews.forEach { $0.removeFromSuperview() }
                rootView.autoresizingMask = [.width, .height]
                host.addSubview(rootView)
            }
            rootView.frame = host.bounds
            panes = panes.filter { root.paneIDs.contains($0.key) }
            splits = splits.filter { root.splitIDs.contains($0.key) }
            pendingFractions = pendingFractions.filter { root.splitIDs.contains($0.key) }
        }

        private func view(for node: WorkspacePaneNode, contents: [WorkspacePaneID: AnyView], workspace: ApplicationWorkspace) -> NSView {
            switch node {
            case .pane(let id):
                if let pane = panes[id] {
                    pane.host.rootView = contents[id] ?? AnyView(EmptyView())
                    pane.setAccessibilityLabel(workspace.paneTitle(id))
                    return pane
                }
                let pane = WorkspacePaneContainerView(paneID: id, workspace: workspace, content: contents[id] ?? AnyView(EmptyView()))
                panes[id] = pane
                return pane
            case .split(let id, let axis, let fraction, let first, let second):
                let split = splits[id] ?? WorkspacePanesNativeSplitView(frame: .zero)
                splits[id] = split
                split.splitID = id
                split.delegate = self
                split.isVertical = axis == .horizontal
                split.dividerStyle = .thin
                split.fraction = pendingFractions[id] ?? fraction
                let children = [view(for: first, contents: contents, workspace: workspace),
                    view(for: second, contents: contents, workspace: workspace)]
                if split.arrangedSubviews.count != 2 || zip(split.arrangedSubviews, children).contains(where: { $0 !== $1 }) {
                    for child in split.arrangedSubviews {
                        split.removeArrangedSubview(child)
                        child.removeFromSuperview()
                    }
                    children.forEach { split.addArrangedSubview($0) }
                }
                applyFraction(in: split)
                return split
            }
        }

        func install(in host: WorkspacePanesHostView) {
            self.host = host
            host.focusSampler = self
            NotificationCenter.default.addObserver(self, selector: #selector(updateResponder),
                name: NSApplication.willUpdateNotification, object: nil)
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let workspace = self.workspace, let host = self.host,
                      event.window === host.window, event.window === workspace.presentationWindow,
                      NSApp.modalWindow == nil, event.window?.attachedSheet == nil else { return event }
                if let pane = self.panes.values.first(where: {
                    $0.window === event.window && $0.bounds.contains($0.convert(event.locationInWindow, from: nil))
                }) { workspace.activatePane(pane.paneID) }
                return event
            }
        }

        func stopMonitoring() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            NotificationCenter.default.removeObserver(self)
        }

        func acknowledgeResponder(_ responder: NSResponder?) { previousResponder = responder }

        @objc private func updateResponder() {
            guard let workspace, let window = host?.window, window === workspace.presentationWindow,
                  window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            let responder = window.firstResponder
            guard responder !== previousResponder else { return }
            previousResponder = responder
            if let pane = WorkspacePaneContainerView.owningPane(of: responder, in: workspace) { workspace.activatePane(pane) }
        }

        private func extent(of split: NSSplitView) -> CGFloat {
            max(0, (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness)
        }

        private func minimumExtent(of split: NSSplitView) -> CGFloat {
            min(split.isVertical ? 280 : 160, extent(of: split) / 2)
        }

        private func applyFraction(in split: WorkspacePanesNativeSplitView) {
            guard split.arrangedSubviews.count == 2 else { return }
            split.applyingFraction = true
            defer { split.applyingFraction = false }
            let available = extent(of: split)
            let minimum = minimumExtent(of: split)
            let position = min(max(CGFloat(split.fraction) * available, minimum), available - minimum)
            let bounds = split.bounds
            if split.isVertical {
                split.arrangedSubviews[0].frame = NSRect(x: bounds.minX, y: bounds.minY, width: position, height: bounds.height)
                split.arrangedSubviews[1].frame = NSRect(x: bounds.minX + position + split.dividerThickness, y: bounds.minY,
                    width: available - position, height: bounds.height)
            } else {
                split.arrangedSubviews[0].frame = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: position)
                split.arrangedSubviews[1].frame = NSRect(x: bounds.minX, y: bounds.minY + position + split.dividerThickness,
                    width: bounds.width, height: available - position)
            }
            split.needsDisplay = true
        }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            if let split = splitView as? WorkspacePanesNativeSplitView { applyFraction(in: split) }
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            max(minimumExtent(of: splitView), extent(of: splitView) * CGFloat(WorkspacePaneLayout.splitRange.lowerBound))
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            min(extent(of: splitView) - minimumExtent(of: splitView), extent(of: splitView) * CGFloat(WorkspacePaneLayout.splitRange.upperBound))
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
        nonisolated func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView,
                                   forDoubleClickOnDividerAt dividerIndex: Int) -> Bool { false }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let split = notification.object as? WorkspacePanesNativeSplitView,
                  !split.applyingFraction, split.isUserAdjustingDivider, let workspace,
                  extent(of: split) > 0, let first = split.arrangedSubviews.first else { return }
            let fraction = Double((split.isVertical ? first.frame.width : first.frame.height) / extent(of: split))
            let id = split.splitID
            split.fraction = fraction
            pendingFractions[id] = fraction
            Task { @MainActor [weak self] in
                guard let self, self.pendingFractions[id] == fraction else { return }
                workspace.setSplitFraction(fraction, for: id)
                self.pendingFractions[id] = nil
            }
        }
    }
}
