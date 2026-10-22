import SwiftUI

struct SQLHistoryView: View {
    @ObservedObject var workspace: ApplicationWorkspace
    private var clearDrafts = SwiftUI.State(initialValue: false)

    init(workspace: ApplicationWorkspace) {
        self.workspace = workspace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SQL History").font(.title2)
                Spacer()
                Button("Done") { workspace.isHistoryPresented = false }.controlHover().keyboardShortcut(.cancelAction)
            }
            Toggle("Record executed SQL", isOn: $workspace.historyEnabled).controlHover()
            Text("Up to 1000 executions from the last 30 days, stored on this Mac.")
                .font(.caption).appSecondaryText()
            List(Array(workspace.history.reversed())) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(entry.date, style: .date)
                        Text(entry.date, style: .time)
                        Spacer()
                        Text(entry.outcomeLabel)
                    }.font(.caption).appSecondaryText()
                    if let profile = entry.profile {
                        Text(profile.summary)
                            .font(.caption).appSecondaryText().textSelection(.enabled)
                    } else {
                        Text("Original connection details unavailable")
                            .font(.caption).appSecondaryText()
                    }
                    if let startedAt = entry.startedAt, let finishedAt = entry.finishedAt {
                        Text("Started \(startedAt.formatted(date: .abbreviated, time: .standard)) · Finished \(finishedAt.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption).appSecondaryText()
                    }
                    Text(entry.executionSummary).font(.caption).appSecondaryText()
                    if entry.truncated == true {
                        Text("Result display truncated. Loaded rows are not the full result.")
                            .font(.caption).appSecondaryText()
                    }
                    if entry.countsArePartial == true {
                        Text("Counts cover retained results only; additional results may be unavailable.")
                            .font(.caption).appSecondaryText()
                    }
                    if entry.sqlCompleted == true, entry.outcome != .succeeded {
                        Text("SQL completion was confirmed; result delivery or export failed. Do not rerun SQL to recover the result.")
                            .font(.caption).appSecondaryText()
                    } else if entry.outcome == .unknown, entry.legacyOutcome == nil {
                        Text("SQL outcome is unknown. Inspect the database before retrying.")
                            .font(.caption).appSecondaryText()
                    }
                    if let message = entry.errorMessage {
                        Text(message + (entry.sqlState.map { " (SQLSTATE \($0))" } ?? ""))
                            .font(.caption).textSelection(.enabled)
                    }
                    Text(entry.sql).font(.system(.callout, design: .monospaced)).lineLimit(4).textSelection(.enabled)
                    Button {
                        workspace.newDocument(profileID: entry.profileID, text: entry.sql)
                        workspace.isHistoryPresented = false
                    } label: {
                        Text("Open in SQL Tab")
                            .padding(.horizontal, 8).frame(minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(AppPalette.accent).controlHover()
                }.padding(.vertical, 5)
            }
            HStack {
                Button("Clear History", role: .destructive) { Task { await workspace.clearHistory() } }.controlHover()
                Spacer()
                Button("Clear SQL Drafts…", role: .destructive) { clearDrafts.wrappedValue = true }.controlHover()
            }
        }
        .padding(20).frame(minWidth: 720, minHeight: 520)
        .tint(AppPalette.accent)
        .focusEffectDisabled()
        .alert("Clear SQL Drafts?", isPresented: clearDrafts.projectedValue) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Drafts", role: .destructive) { Task { await workspace.clearRestoredDocuments() } }
        } message: {
            Text("Close the current documents and remove the saved drafts. Saved .sql files stay on disk.")
        }
    }
}
