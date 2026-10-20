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
                        Text(entry.outcome)
                    }.font(.caption).appSecondaryText()
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
