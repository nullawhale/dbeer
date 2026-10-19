import AppKit
import SwiftUI

/// Last-window close must remain cancellable before AppKit removes the window.
struct WorkspaceWindowCloseGuard: NSViewRepresentable {
    let workspace: ApplicationWorkspace

    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }

    func makeNSView(context: Context) -> WindowHookView {
        let view = WindowHookView()
        view.didFindWindow = { [weak coordinator = context.coordinator] in coordinator?.install(on: $0) }
        return view
    }

    func updateNSView(_ view: WindowHookView, context: Context) {
        if let window = view.window { context.coordinator.install(on: window) }
    }

    @MainActor final class WindowHookView: NSView {
        var didFindWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { didFindWindow?(window) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        private let workspace: ApplicationWorkspace
        private weak var window: NSWindow?
        // Objective-C forwarding is used only by AppKit on the main thread.
        // Preserve SwiftUI's original window delegate and its optional methods.
        nonisolated(unsafe) private weak var previous: (any NSWindowDelegate)?
        private var checking = false
        private var allowed = false

        init(workspace: ApplicationWorkspace) { self.workspace = workspace }

        func install(on window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            workspace.presentationWindow = window
            previous = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if allowed { return previous?.windowShouldClose?(sender) ?? true }
            guard !checking else { return false }
            checking = true
            Task { @MainActor [weak self, weak sender] in
                guard let self else { return }
                let mayClose = await workspace.prepareToClose(.application)
                checking = false
                if mayClose, let sender {
                    allowed = true
                    sender.performClose(nil)
                    allowed = false
                }
            }
            return false
        }

        nonisolated override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previous?.responds(to: selector) == true
        }

        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? { previous }
    }
}
