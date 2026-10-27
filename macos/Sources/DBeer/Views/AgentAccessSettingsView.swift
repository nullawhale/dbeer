import AppKit
import SwiftUI

struct AgentAccessSettingsView: View {
    @ObservedObject var coordinator: AgentAccessCoordinator
    let brokerError: String?
    let revoke: @MainActor (UUID) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agent Access").font(.title2.bold())
            Text("Local MCP clients need your approval for specific PostgreSQL or MySQL profiles. Access lasts until the client disconnects or DBeer quits. Reading is the default; writes require a separate permission.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let brokerError { Text(brokerError).foregroundStyle(.red) }
            Text("MCP command").font(.headline)
            Text(BackendClient.bundledExecutableURL().path + " --mcp")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            if coordinator.clients.isEmpty {
                Text("No approved clients.").foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.clients) { client in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            Text(client.name).font(.headline)
                            Text(client.profiles.joined(separator: ", ")).font(.caption)
                            Text(client.readOnly ? "Read only" : "Includes write permission").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke Access") { Task { await revoke(client.id) } }
                            .accessibilityIdentifier("agentRevoke-\(client.id.uuidString)")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("agentClient-\(client.id.uuidString)")
                }
            }
            DisclosureGroup("Session activity (\(coordinator.audit.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(coordinator.audit.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.time.formatted(date: .omitted, time: .standard)) · \(entry.method) · \(entry.permission) · \(entry.outcome) · \(entry.responseBytes) bytes")
                            Text("Client \(entry.clientID.uuidString)" + (entry.profileID.map { " · Profile \($0.uuidString)" } ?? ""))
                                .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        }.font(.caption)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("agentActivity")
            }
            }
            Text("Revoking access cancels active operations and closes the client's database sessions. An interrupted write may have an unknown outcome. Password-command profiles are unavailable to agents.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 680, height: 470)
    }
}

@MainActor
enum AgentAccessApproval {
    static func present(clientName: String, profiles: [SavedConnection]) async -> [UUID: Bool]? {
        guard let window = presentationWindow(),
              !profiles.isEmpty, window.attachedSheet == nil else { return nil }
        let alert = NSAlert()
        alert.messageText = "Allow Agent Access?"
        alert.informativeText = "Local client: \(clientName)\nThe client name is self-reported. Select the profiles it may use for this session. Enable writes separately only if you trust this client. Existing readonly and production policies still apply."
        alert.addButton(withTitle: "Allow Selected Profiles")
        alert.addButton(withTitle: "Deny")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[0].setAccessibilityIdentifier("agentApprove")
        alert.buttons[1].setAccessibilityIdentifier("agentDeny")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let padding: CGFloat = 12
        let contentWidth: CGFloat = 540
        let rowWidth = contentWidth - padding * 2
        stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        let selection = AgentProfileSelection()
        stack.addArrangedSubview(selection.selectAll)
        for profile in profiles {
            let selected = NSButton(checkboxWithTitle: "\(profile.name) · \(profile.engine.displayName)", target: nil, action: nil)
            let write = NSButton(checkboxWithTitle: "Allow writes to \(profile.name)", target: nil, action: nil)
            selected.setAccessibilityIdentifier("agentProfile-\(profile.id.uuidString)")
            write.setAccessibilityIdentifier("agentWrite-\(profile.id.uuidString)")
            for button in [selected, write] {
                button.widthAnchor.constraint(lessThanOrEqualToConstant: rowWidth).isActive = true
                button.cell?.lineBreakMode = .byTruncatingTail
                button.toolTip = "\(profile.name) · \(profile.host):\(profile.port)/\(profile.database) · \(profile.user) · \(profile.policy.label) · \(profile.id.uuidString)"
            }
            write.isEnabled = !profile.policy.readOnly
            selected.state = .off; write.state = .off
            let details = NSTextField(wrappingLabelWithString: "\(profile.host):\(profile.port)/\(profile.database) · \(profile.user) · \(profile.policy.label)\nProfile \(profile.id.uuidString)")
            details.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            details.textColor = .secondaryLabelColor
            details.setAccessibilityIdentifier("agentProfileDetails-\(profile.id.uuidString)")
            details.preferredMaxLayoutWidth = rowWidth
            details.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
            stack.addArrangedSubview(selected)
            stack.addArrangedSubview(details)
            stack.addArrangedSubview(write)
            selection.add(profileID: profile.id, selected: selected, write: write)
        }
        let contentHeight = max(100, stack.fittingSize.height)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: min(300, contentHeight)))
        scroll.hasVerticalScroller = true
        stack.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        scroll.documentView = stack
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, contentHeight - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        alert.accessoryView = scroll
        let answer = await presentSheet(alert, for: window)
        guard answer == .alertFirstButtonReturn else { return nil }
        return selection.selectedProfiles
    }

    static func confirm(_ confirmation: OperationConfirmation) async -> Bool {
        guard let window = presentationWindow(),
              window.attachedSheet == nil else { return false }
        let alert = ExecutionConfirmation.makeAlert(confirmation)
        alert.buttons[0].setAccessibilityIdentifier("agentExecute")
        alert.buttons[1].setAccessibilityIdentifier("agentCancelOperation")
        return await presentSheet(alert, for: window) == .alertFirstButtonReturn
    }

    private static func presentationWindow() -> NSWindow? {
        var window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.sheetParent == nil }
        while let parent = window?.sheetParent { window = parent }
        return window?.isVisible == true ? window : nil
    }

    private static func presentSheet(_ alert: NSAlert, for window: NSWindow) async -> NSApplication.ModalResponse {
        let state = AgentApprovalSheet(alert: alert)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.begin(window: window, continuation: continuation, cancelled: Task.isCancelled)
            }
        } onCancel: { Task { @MainActor in state.cancel() } }
    }
}

@MainActor
private final class AgentProfileSelection: NSObject {
    let selectAll = NSButton(checkboxWithTitle: "Select All", target: nil, action: nil)
    private var profiles: [(id: UUID, selected: NSButton, write: NSButton)] = []

    override init() {
        super.init()
        selectAll.allowsMixedState = true
        selectAll.setAccessibilityIdentifier("agentSelectAll")
        selectAll.target = self
        selectAll.action = #selector(toggleAll)
    }

    func add(profileID: UUID, selected: NSButton, write: NSButton) {
        profiles.append((profileID, selected, write))
        selected.target = self
        selected.action = #selector(updateSelectAll)
    }

    var selectedProfiles: [UUID: Bool] {
        Dictionary(uniqueKeysWithValues: profiles.compactMap { id, selected, write in
            selected.state == .on ? (id, write.isEnabled && write.state == .on) : nil
        })
    }

    @objc private func toggleAll() {
        let state: NSControl.StateValue = profiles.allSatisfy { $0.selected.state == .on } ? .off : .on
        for profile in profiles { profile.selected.state = state }
        updateSelectAll()
    }

    @objc private func updateSelectAll() {
        let count = profiles.filter { $0.selected.state == .on }.count
        selectAll.state = count == profiles.count ? .on : count == 0 ? .off : .mixed
    }
}

@MainActor
private final class AgentApprovalSheet {
    let alert: NSAlert
    private var continuation: CheckedContinuation<NSApplication.ModalResponse, Never>?
    private var cancelled = false
    private var monitor: Any?

    init(alert: NSAlert) { self.alert = alert }

    func begin(window: NSWindow, continuation: CheckedContinuation<NSApplication.ModalResponse, Never>, cancelled: Bool) {
        guard !self.cancelled, !cancelled else { continuation.resume(returning: .alertSecondButtonReturn); return }
        self.continuation = continuation
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.alert.window.sheetParent != nil,
                      event.window === self.alert.window, [36, 53, 76].contains(event.keyCode),
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
                self.cancel(); return true
            }
            return consumed ? nil : event
        }
        alert.beginSheetModal(for: window) { [self] in finish($0) }
    }

    func cancel() {
        cancelled = true
        if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
        finish(.alertSecondButtonReturn)
    }

    private func finish(_ result: NSApplication.ModalResponse) {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        let continuation = self.continuation; self.continuation = nil
        continuation?.resume(returning: result)
    }
}
