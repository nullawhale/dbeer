import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PlanArtifactsView: View {
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject var model: PlanArtifactsModel
    var snapshotID: UUID? = nil
    var insert: ((PlanArtifactSummary) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    private var query = SwiftUI.State(initialValue: "")
    private var mode = SwiftUI.State(initialValue: "all")
    private var baselinesOnly = SwiftUI.State(initialValue: false)
    private var selectedID = SwiftUI.State<UUID?>(initialValue: nil)
    private var comparisonID = SwiftUI.State<UUID?>(initialValue: nil)
    private var renaming = SwiftUI.State<PlanArtifactSummary?>(initialValue: nil)
    private var deleting = SwiftUI.State<UUID?>(initialValue: nil)

    private var selected: PlanArtifactSummary? { model.artifacts.first { $0.id == selectedID.wrappedValue } }
    private var filtered: [PlanArtifactSummary] {
        model.artifacts.filter {
            (query.wrappedValue.isEmpty || $0.title.localizedCaseInsensitiveContains(query.wrappedValue) ||
                $0.baselineName?.localizedCaseInsensitiveContains(query.wrappedValue) == true) &&
            (mode.wrappedValue == "all" || $0.isAvailable && $0.mode.rawValue == mode.wrappedValue) &&
            (!baselinesOnly.wrappedValue || $0.baselineName != nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(snapshotID == nil ? "Saved Execution Plans" : "Snapshot Execution Plans").font(.title2)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Import…", action: importFile).controlHover().disabled(model.isBusy)
                Button("Refresh") { Task { await model.refresh() } }.controlHover().disabled(model.isBusy)
                Button("Done") { dismiss() }.controlHover().keyboardShortcut(.cancelAction).disabled(model.isBusy)
            }
            HStack {
                TextField("Search titles and baselines", text: query.projectedValue).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search saved execution plans")
                Picker("Operation", selection: mode.projectedValue) {
                    Text("All operations").tag("all")
                    Text("Explain").tag(ExplainMode.plan.rawValue)
                    Text("Explain Analyze").tag(ExplainMode.analyze.rawValue)
                }.frame(width: 190)
                Toggle("Baselines", isOn: baselinesOnly.projectedValue).toggleStyle(.checkbox)
            }
            HSplitView {
                List(selection: selectedID.projectedValue) {
                    ForEach(filtered) { artifact in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(artifact.title).lineLimit(2)
                            if artifact.isAvailable {
                                Text("\(artifact.engine.displayName) · \(artifact.mode.title(engine: artifact.engine)) · \(artifact.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).appSecondaryText()
                            } else { Text("Local artifact is damaged or unavailable").font(.caption).foregroundStyle(.orange) }
                            if let name = artifact.baselineName { Label(name, systemImage: "flag").font(.caption) }
                            if artifact.isAvailable && !artifact.complete { Text("Incomplete captured evidence").font(.caption).foregroundStyle(.orange) }
                            if let snapshotID, model.links.contains(.init(snapshotID: snapshotID, planID: artifact.id)) {
                                Label("Attached to this snapshot", systemImage: "paperclip").font(.caption)
                            }
                        }.tag(artifact.id)
                    }
                }.frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
                    .accessibilityIdentifier("savedExecutionPlans")
                VStack(alignment: .leading, spacing: 8) {
                    if let selected {
                        HStack {
                            Button("Export…") { exportFile(selected.id) }.controlHover().disabled(model.isBusy || !selected.isAvailable)
                            Button("Name / Baseline…") { renaming.wrappedValue = selected }.controlHover().disabled(model.isBusy || !selected.isAvailable)
                            if let snapshotID {
                                let attached = model.links.contains(.init(snapshotID: snapshotID, planID: selected.id))
                                Button(attached ? "Detach from Snapshot" : "Attach to Snapshot") {
                                    Task {
                                        if attached { _ = await model.detach(planID: selected.id, snapshotID: snapshotID) }
                                        else { _ = await model.attach(planID: selected.id, snapshotID: snapshotID, snapshotStore: workspace.resultSnapshots.store) }
                                    }
                                }.controlHover().disabled(model.isBusy || !selected.isAvailable)
                            }
                            if let insert {
                                Button("Insert Plan Reference") { insert(selected); dismiss() }.controlHover()
                                    .disabled(model.isBusy || !selected.isAvailable || !workspace.canManageWorkspace)
                            }
                            Spacer(minLength: 4)
                            Button(role: .destructive) { deleting.wrappedValue = selected.id } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).controlHover().disabled(model.isBusy).accessibilityLabel("Delete saved execution plan")
                        }
                        ForEach(model.links.filter { $0.planID == selected.id }, id: \.self) { link in
                            HStack {
                                Text("Snapshot attachment · " + (workspace.resultSnapshots.snapshots.first { $0.id == link.snapshotID }?.title ?? link.snapshotID.uuidString))
                                    .font(.caption).lineLimit(1)
                                Button("Remove Link") { Task { _ = await model.detach(planID: selected.id, snapshotID: link.snapshotID) } }
                                    .controlHover().disabled(model.isBusy)
                            }
                        }
                        Picker("Compare with", selection: comparisonID.projectedValue) {
                            Text("View this plan").tag(UUID?.none)
                            ForEach(model.artifacts.filter { $0.id != selected.id && $0.isAvailable }) { other in
                                Text(other.title + (other.baselineName.map { " · \($0)" } ?? "")).tag(Optional(other.id))
                            }
                        }
                        if let other = comparisonID.wrappedValue, other != selected.id {
                            SavedPlanComparisonView(store: model.store, beforeID: selected.id, afterID: other, refreshRevision: model.revision)
                                .id(selected.id.uuidString + other.uuidString)
                        } else { SavedPlanArtifactView(store: model.store, id: selected.id, refreshRevision: model.revision).id(selected.id) }
                    } else {
                        Text(model.artifacts.isEmpty ? "Save a completed execution plan or import a .dbeerplan file." : "Select a saved execution plan.")
                            .appSecondaryText().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 480).padding(.leading, 8)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text("Local saved evidence · \(model.artifacts.count) plans · opening and comparing plans reads local files")
                .font(.caption).appSecondaryText()
        }.padding(16).frame(minWidth: 900, idealWidth: 1_100, minHeight: 600, idealHeight: 720)
            .interactiveDismissDisabled(model.isBusy)
            .task { await workspace.investigations.restore(); await workspace.resultSnapshots.refresh(); await model.refresh() }
            .onChange(of: selectedID.wrappedValue) { _, _ in comparisonID.wrappedValue = nil }
            .sheet(item: renaming.projectedValue) { artifact in
                PlanArtifactNameView(summary: artifact) { title, baseline in
                    await model.updateMetadata(id: artifact.id, title: title, baselineName: baseline)
                }
            }
            .confirmationDialog("Delete this saved execution plan?", isPresented: Binding(get: { deleting.wrappedValue != nil }, set: { if !$0 { deleting.wrappedValue = nil } })) {
                Button("Delete Plan", role: .destructive) {
                    guard let id = deleting.wrappedValue else { return }
                    deleting.wrappedValue = nil
                    Task { if await model.delete(id) { selectedID.wrappedValue = nil } }
                }
                Button("Cancel", role: .cancel) { deleting.wrappedValue = nil }
            }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dbeerplan", conformingTo: .json) ?? .json, .json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url, !workspace.isClosing else { return }
            Task { if let imported = await model.importArtifact(from: url) { selectedID.wrappedValue = imported.id } }
        }
    }

    private func exportFile(_ id: UUID) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dbeerplan", conformingTo: .json) ?? .json]
        panel.nameFieldStringValue = "execution-plan.dbeerplan"
        panel.begin { response in
            guard response == .OK, let url = panel.url, !workspace.isClosing else { return }
            do {
                let version = try SQLFileBinding.reviewedVersion(at: url)
                Task { _ = await model.exportArtifact(id, to: url, expectedVersion: version) }
            } catch { model.report(error) }
        }
    }
}

struct SavedPlanArtifactView: View {
    let store: PlanArtifactStore
    let id: UUID
    var refreshRevision: UInt64 = 0
    private var localRevision = SwiftUI.State<UInt64>(initialValue: 0)
    private var artifact = SwiftUI.State<PlanArtifact?>(initialValue: nil)
    private var error = SwiftUI.State<String?>(initialValue: nil)
    var body: some View {
        Group {
            if let artifact = artifact.wrappedValue {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button("Reload Local Plan") { localRevision.wrappedValue &+= 1 }.controlHover()
                        Spacer()
                    }
                    Text([artifact.profileName ?? "Unrecorded connection", artifact.environment?.label ?? "Unrecorded environment"].joined(separator: " · "))
                        .font(.caption).appSecondaryText().textSelection(.enabled)
                    ExplainPlanView(plan: artifact.displayPlan, stale: false)
                }
            } else if let error = error.wrappedValue {
                Text(error).foregroundStyle(.orange).textSelection(.enabled).padding()
            } else { ProgressView("Reading saved plan") }
        }.task(id: id.uuidString + "|\(refreshRevision)|\(localRevision.wrappedValue)") {
            artifact.wrappedValue = nil
            error.wrappedValue = nil
            do {
                let loaded = try await store.load(id)
                guard !Task.isCancelled else { return }
                artifact.wrappedValue = loaded
            } catch { self.error.wrappedValue = error.localizedDescription }
        }
    }
}

private struct SavedPlanComparisonView: View {
    let store: PlanArtifactStore
    let beforeID: UUID
    let afterID: UUID
    var refreshRevision: UInt64 = 0
    private var pair = SwiftUI.State<[PlanArtifact]>(initialValue: [])
    private var error = SwiftUI.State<String?>(initialValue: nil)
    var body: some View {
        Group {
            if pair.wrappedValue.count == 2 {
                let before = pair.wrappedValue[0]
                let after = pair.wrappedValue[1]
                let comparison = PlanComparison(before: before, after: after)
                VStack(alignment: .leading, spacing: 8) {
                    Text(before.title + " → " + after.title).font(.headline)
                    Text("Before · \(before.result.support.engine.displayName) \(before.result.support.serverVersion) · \(before.result.support.format) · \(before.request.mode.title(engine: before.result.support.engine))").font(.caption)
                    Text("After · \(after.result.support.engine.displayName) \(after.result.support.serverVersion) · \(after.result.support.format) · \(after.request.mode.title(engine: after.result.support.engine))").font(.caption)
                    if let message = comparison.diagnosticMessage {
                        Text(message).font(.caption).foregroundStyle(.orange)
                        HSplitView {
                            ExplainPlanView(plan: before.displayPlan, stale: false)
                            ExplainPlanView(plan: after.displayPlan, stale: false)
                        }
                    } else {
                        if !comparison.metricsComparable { Text("Captured contexts differ. Metric values are shown independently.").font(.caption).foregroundStyle(.orange) }

                        Text(comparison.shapeAvailable ? (comparison.shapeChanged ? "Plan shape changed" : "Same recorded plan shape") : "Plan shape unavailable from captured evidence").font(.caption)
                        if !comparison.comparableEngine { Text("Different engines — operations are shown independently.").foregroundStyle(.orange) }
                        if comparison.incomplete { Text("Captured evidence limits node comparison.").foregroundStyle(.orange) }
                        Text("Node matching uses structural paths and native operation/relation/index identity. Duplicate paths stay ambiguous. Inclusive metrics overlap.")
                            .font(.caption).appSecondaryText()
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(comparison.matches) { match in
                                    GroupBox {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(match.label).fontWeight(.medium)
                                            Text(match.status).font(.caption).foregroundStyle(match.isAmbiguous ? Color.orange : Color.secondary)
                                            if !match.isAmbiguous {
                                                let left = match.before.first
                                                let right = match.after.first
                                                if let reason = comparison.metricComparisonReason(match) { Text(reason).font(.caption).foregroundStyle(.orange) }
                                                ForEach(PlanComparison.metricPairs(before: left?.metrics ?? [:], after: right?.metrics ?? [:])) { metric in
                                                    let comparable = comparison.metricComparisonReason(match) == nil && metric.sameDefinition
                                                    Text("\(metric.name) · Before \(metric.before?.label ?? "Absent")" + (comparable ? " → " : " | After ") + (metric.after?.label ?? "Absent"))
                                                        .font(.caption).textSelection(.enabled)
                                                }
                                                let changes = PlanComparison.detailChanges(before: left?.details ?? [:], after: right?.details ?? [:])
                                                if !changes.isEmpty {
                                                    DisclosureGroup("Changed native details") {
                                                        ForEach(changes) { change in
                                                            Text("\(change.name) · \(change.before ?? "Absent") → \(change.after ?? "Absent")")
                                                                .font(.caption).textSelection(.enabled)
                                                            if change.unicodeRepresentationChanged {
                                                                Text("Unicode byte representation changed").font(.caption).foregroundStyle(.orange)
                                                            }
                                                        }
                                                    }
                                                }
                                            } else {
                                                Text("\(match.before.count) before candidates · \(match.after.count) after candidates")
                                                    .font(.caption).textSelection(.enabled)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                }
            } else if let error = error.wrappedValue { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            else { ProgressView("Reading plan comparison") }
        }.task(id: refreshRevision) {
            pair.wrappedValue = []
            error.wrappedValue = nil
            do {
                let before = try await store.load(beforeID)
                let after = try await store.load(afterID)
                guard !Task.isCancelled else { return }
                pair.wrappedValue = [before, after]
            } catch { self.error.wrappedValue = error.localizedDescription }
        }
    }
}

struct PlanArtifactNameView: View {
    let title: String
    let save: (String, String?) async -> Bool
    @Environment(\.dismiss) private var dismiss
    private var name: SwiftUI.State<String>
    private var baseline: SwiftUI.State<String>
    private var isSaving = SwiftUI.State(initialValue: false)
    private var failed = SwiftUI.State(initialValue: false)
    init(summary: PlanArtifactSummary, save: @escaping (String, String?) async -> Bool) {
        title = "Name Saved Plan"
        self.save = save
        name = SwiftUI.State(initialValue: summary.title)
        baseline = SwiftUI.State(initialValue: summary.baselineName ?? "")
    }
    init(title: String, initialName: String, save: @escaping (String, String?) async -> Bool) {
        self.title = title
        self.save = save
        name = SwiftUI.State(initialValue: initialName)
        baseline = SwiftUI.State(initialValue: "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Plan title", text: name.projectedValue).textFieldStyle(.roundedBorder)
            TextField("Baseline name (optional)", text: baseline.projectedValue).textFieldStyle(.roundedBorder)
            if failed.wrappedValue { Text("The plan could not be saved. Review the library error and try again.").font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving.wrappedValue)
                Button("Save") {
                    isSaving.wrappedValue = true
                    Task {
                        if await save(name.wrappedValue, baseline.wrappedValue.isEmpty ? nil : baseline.wrappedValue) { dismiss() }
                        else { failed.wrappedValue = true; isSaving.wrappedValue = false }
                    }
                }.controlHover().disabled(isSaving.wrappedValue || name.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.wrappedValue.utf8.count > 16_384 || baseline.wrappedValue.utf8.count > 16_384)
            }
        }.padding(20).frame(width: 460).interactiveDismissDisabled(isSaving.wrappedValue)
    }
}
