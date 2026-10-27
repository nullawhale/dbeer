import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SynchronizationPlanView: View {
    @ObservedObject var draft: SynchronizationPlanDraft
    let close: () -> Void
    var makeSavePanel: @MainActor () -> NSSavePanel = { NSSavePanel() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Synchronization SQL Plan").font(.title2.weight(.semibold)).accessibilityIdentifier("syncPlanTitle")
                    Text("\(draft.source.name) → \(draft.target.name)").font(.callout).textSelection(.enabled).lineLimit(2).accessibilityIdentifier("syncPlanDirection")
                    Text("Target: \(draft.target.engine.displayName) · \(draft.target.host):\(String(draft.target.port)) · \(draft.target.database)")
                        .font(.caption).appSecondaryText().textSelection(.enabled).lineLimit(2).accessibilityIdentifier("syncPlanTarget")
                }
                Spacer()
                Button("Back to Comparison", action: close).keyboardShortcut(.cancelAction).controlHover().accessibilityIdentifier("syncPlanBack")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(draft.plan.warnings.enumerated()), id: \.offset) { index, warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("syncPlanWarning-\(index)")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 100).accessibilityIdentifier("syncPlanWarnings")
            Text("Choose operations to include. Destructive operations require explicit selection; manual steps need separate work.")
                .font(.callout).appSecondaryText()
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(draft.plan.steps) { step in
                            VStack(alignment: .leading, spacing: 5) {
                                Toggle(isOn: Binding(get: { draft.selected.contains(step.id) }, set: { value in
                                    if value { draft.selected.insert(step.id) } else { draft.selected.remove(step.id) }
                                })) {
                                    Text(step.title).font(.callout.weight(.medium))
                                }.disabled(step.manual || !draft.isValid).accessibilityIdentifier("syncPlanStep-\(step.id)")
                                if step.manual { Label("Manual", systemImage: "hand.raised").font(.caption).foregroundStyle(.orange).accessibilityIdentifier("syncPlanManual-\(step.id)") }
                                else if step.destructive { Label("Destructive", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).accessibilityIdentifier("syncPlanDestructive-\(step.id)") }
                                if !step.reason.isEmpty { Text(step.reason).font(.caption).appSecondaryText().textSelection(.enabled).accessibilityIdentifier("syncPlanReason-\(step.id)") }
                                if !step.dependsOn.isEmpty {
                                    Text("Requires: " + step.dependsOn.map { id in draft.plan.steps.first { $0.id == id }?.title ?? id }.joined(separator: ", "))
                                        .font(.caption).appSecondaryText().accessibilityIdentifier("syncPlanDependencies-\(step.id)")
                                }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppPalette.background, in: RoundedRectangle(cornerRadius: 6))
                        }
                        if draft.plan.steps.isEmpty { Text("No synchronization operations are needed.").appSecondaryText() }
                    }.padding(8)
                }.frame(minWidth: 280, idealWidth: 350, maxWidth: 460)
                VStack(alignment: .leading, spacing: 8) {
                    Text("SQL Preview").font(.headline)
                    ScrollView(draft.sql == nil ? .vertical : [.horizontal, .vertical]) {
                        Text(draft.sql ?? previewNotice)
                            .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(10).accessibilityIdentifier("syncPlanPreview")
                    }.background(AppPalette.background, in: RoundedRectangle(cornerRadius: 6))
                }.padding(8).frame(minWidth: 420)
            }
            if let error = draft.error ?? draft.selectionError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled).lineLimit(3).accessibilityIdentifier("syncPlanSelectionError")
            }
            Divider()
            HStack {
                Text("Planning does not change either server. Execute reviewed SQL through the target editor.").font(.caption).appSecondaryText()
                Spacer()
                if draft.saved { Label("Saved", systemImage: "checkmark").font(.caption).appSecondaryText().accessibilityIdentifier("syncPlanSaved") }
                Button("Save .sql…", action: save).keyboardShortcut("s", modifiers: .command).disabled(draft.sql == nil).controlHover().accessibilityIdentifier("syncPlanSave")
                Button("Open in Target Editor") { _ = draft.openInEditor() }.keyboardShortcut(.defaultAction).disabled(draft.sql == nil).controlHover().accessibilityIdentifier("syncPlanOpen")
            }
        }.padding(20)
            .frame(minWidth: 900, idealWidth: 1120, minHeight: 660, idealHeight: 780)
            .background(AppPalette.panel).foregroundStyle(AppPalette.text).tint(AppPalette.accent)
            .accessibilityElement(children: .contain).accessibilityIdentifier("synchronizationPlan")
    }

    private var previewNotice: String {
        if draft.plan.steps.isEmpty { return "No synchronization SQL is needed for the captured scope." }
        if draft.plan.steps.allSatisfy(\.manual) { return "The listed operations require manual SQL. No automatic SQL is available." }
        return "Select operations with all required dependencies to preview SQL."
    }

    private func save() {
        guard let sql = draft.sql else { return }
        let panel = makeSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = "synchronization-plan.sql"
        panel.begin { response in if response == .OK, let url = panel.url { draft.save(to: url, expectedSQL: sql) } }
    }
}
