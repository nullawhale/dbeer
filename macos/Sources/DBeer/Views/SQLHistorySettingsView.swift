import SwiftUI

struct SQLHistorySettingsView: View {
    @ObservedObject var workspace: ApplicationWorkspace
    @Environment(\.dismiss) private var dismiss
    private var maxEntries: SwiftUI.State<String>
    private var retentionDays: SwiftUI.State<String>
    private var isSaving = SwiftUI.State(initialValue: false)

    init(workspace: ApplicationWorkspace) {
        self.workspace = workspace
        maxEntries = SwiftUI.State(initialValue: String(workspace.historySettings.maxEntries))
        retentionDays = SwiftUI.State(initialValue: String(workspace.historySettings.retentionDays))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("History Storage").font(.title2)
            Text("History is stored on this Mac. Favorites are excluded from automatic deletion and from the ordinary entry limit.")
                .font(.callout).appSecondaryText()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                SwiftUI.GridRow {
                    Text("Ordinary entry limit")
                    TextField("Executions", text: maxEntries.projectedValue).textFieldStyle(.roundedBorder)
                        .frame(width: 120).accessibilityLabel("Ordinary entry limit")
                        .accessibilityIdentifier("historyMaxEntries")
                }
                SwiftUI.GridRow {
                    Text("Keep ordinary entries for")
                    HStack {
                        TextField("Days", text: retentionDays.projectedValue).textFieldStyle(.roundedBorder)
                            .frame(width: 120).accessibilityLabel("History retention days")
                            .accessibilityIdentifier("historyRetentionDays")
                        Text("days")
                    }
                }
            }.disabled(isSaving.wrappedValue)
            if settings == nil {
                Text("Enter whole numbers: \(SQLHistoryRetentionSettings.maxEntriesRange.lowerBound.formatted())–\(SQLHistoryRetentionSettings.maxEntriesRange.upperBound.formatted()) executions and \(SQLHistoryRetentionSettings.retentionDaysRange.lowerBound.formatted())–\(SQLHistoryRetentionSettings.retentionDaysRange.upperBound.formatted()) days.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Applying settings immediately removes ordinary entries outside these limits. Removing a favorite's star also applies these limits immediately and may delete that entry.")
                .font(.callout).appSecondaryText()
            HStack {
                Button("Use Defaults") {
                    maxEntries.wrappedValue = String(SQLHistoryRetentionSettings.default.maxEntries)
                    retentionDays.wrappedValue = String(SQLHistoryRetentionSettings.default.retentionDays)
                }.controlHover().disabled(isSaving.wrappedValue)
                Text("1,000 ordinary executions · 30 days").font(.caption).appSecondaryText()
            }
            if let error = workspace.historyError {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .accessibilityIdentifier("historySettingsError")
            }
            HStack {
                Button("Cancel") { dismiss() }.controlHover().keyboardShortcut(.cancelAction).disabled(isSaving.wrappedValue)
                Spacer()
                if isSaving.wrappedValue { ProgressView().controlSize(.small) }
                Button("Apply Settings", action: apply).controlHover().buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(settings == nil || isSaving.wrappedValue)
                    .accessibilityIdentifier("applyHistorySettings")
            }
        }
        .padding(20).frame(width: 520)
        .tint(AppPalette.accent).focusEffectDisabled().interactiveDismissDisabled(isSaving.wrappedValue)
    }

    private var settings: SQLHistoryRetentionSettings? {
        guard let maxEntries = Int(maxEntries.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let retentionDays = Int(retentionDays.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let settings = SQLHistoryRetentionSettings(maxEntries: maxEntries, retentionDays: retentionDays)
        return settings.isValid ? settings : nil
    }

    private func apply() {
        guard let settings, !isSaving.wrappedValue else { return }
        isSaving.wrappedValue = true
        Task {
            let saved = await workspace.updateHistorySettings(settings)
            isSaving.wrappedValue = false
            if saved { dismiss() }
        }
    }
}
