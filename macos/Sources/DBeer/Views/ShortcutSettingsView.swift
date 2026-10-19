import AppKit
import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject var store: AppShortcutStore

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(store.descriptors) { descriptor in
                        ShortcutSettingsRow(store: store, descriptor: descriptor)
                    }
                } header: {
                    Text("Query shortcuts")
                } footer: {
                    Text("Click a shortcut and press a key with Command, Control, or Option. Escape cancels; Tab moves to the next control. Standard editing and navigation shortcuts stay available.")
                }
            }.formStyle(.grouped)
                .appFormSurface()
            HStack {
                Spacer()
                Button("Restore Defaults") { store.resetDefaults() }
                    .buttonStyle(.bordered)
                    .controlHover()
                    .accessibilityIdentifier("restoreShortcutDefaults")
            }.padding(.horizontal, 20).padding(.bottom, 12)
        }
        .padding(8)
        .frame(width: 650, height: 460)
        .background(AppPalette.window)
        .tint(AppPalette.accent)
        .focusEffectDisabled()
    }
}

private struct ShortcutSettingsRow: View {
    @ObservedObject var store: AppShortcutStore
    let descriptor: AppCommandDescriptor
    private var errorState = SwiftUI.State<String?>(initialValue: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.title)
                    Text(descriptor.scope.title).font(.caption).appSecondaryText()
                }
                Spacer(minLength: 8)
                ShortcutRecorder(shortcut: store.shortcut(for: descriptor.id),
                    commandTitle: descriptor.title, identifier: descriptor.id.rawValue,
                    record: { shortcut in
                        let message = store.update(shortcut, for: descriptor.id)
                        errorState.wrappedValue = message
                        return message
                    })
                    .frame(width: 145, height: 26)
                ControlIconButton(systemName: "xmark.circle") {
                    errorState.wrappedValue = store.update(nil, for: descriptor.id)
                }
                .help("Clear shortcut")
                .accessibilityLabel("Clear shortcut for \(descriptor.title)")
                .accessibilityIdentifier("clearShortcut-\(descriptor.id.rawValue)")
                .disabled(store.shortcut(for: descriptor.id) == nil)
                ControlIconButton(systemName: "arrow.counterclockwise") {
                    errorState.wrappedValue = store.restoreDefault(for: descriptor.id)
                }
                .help("Restore default shortcut")
                .accessibilityLabel("Restore default shortcut for \(descriptor.title)")
                .accessibilityIdentifier("restoreShortcut-\(descriptor.id.rawValue)")
                .disabled(store.overrides[descriptor.id] == nil)
            }
            if let error = errorState.wrappedValue {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("shortcutError-\(descriptor.id.rawValue)")
            }
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: AppShortcut?
    let commandTitle: String
    let identifier: String
    let record: (AppShortcut) -> String?

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(frame: .zero)
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.focusRingType = .none
        button.installHoverFeedback()
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
        button.record = record
        button.setAccessibilityLabel("Shortcut for \(commandTitle)")
        button.setAccessibilityIdentifier("shortcutRecorder-\(identifier)")
        button.refreshTitle()
    }
}

/// The recorder is a native first responder, so only its focused capture state
/// consumes keys. No window/application event monitor sees ordinary typing.
final class ShortcutRecorderButton: NSButton {
    var shortcut: AppShortcut?
    var record: ((AppShortcut) -> String?)?
    private(set) var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(beginRecording)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        target = self
        action = #selector(beginRecording)
    }

    override var acceptsFirstResponder: Bool { true }

    @objc func beginRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        refreshTitle()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { isRecording = false; refreshTitle() }
        return resigned
    }

    func refreshTitle() {
        title = isRecording ? "Type shortcut…" : (shortcut?.displayString ?? "None")
        toolTip = isRecording ? "Press a shortcut; Escape cancels." : "Click to record a shortcut"
        setAccessibilityValue(isRecording ? "Recording" : (shortcut?.displayString ?? "None"))
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        capture(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if isRecording { capture(event) }
        else { super.keyDown(with: event) }
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 {
            isRecording = false
            refreshTitle()
        } else if event.keyCode == 48 {
            isRecording = false
            refreshTitle()
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        } else if let candidate = AppShortcut(event: event), record?(candidate) == nil {
            shortcut = candidate
            isRecording = false
            refreshTitle()
        }
    }
}
