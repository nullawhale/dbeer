import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SavedEvidenceView: View {
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject var model: SavedEvidenceModel
    var snapshotID: UUID? = nil
    var insert: ((SavedEvidenceSummary) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    private var selectedID = SwiftUI.State<UUID?>(initialValue: nil)
    private var deleting = SwiftUI.State<UUID?>(initialValue: nil)
    private var query = SwiftUI.State(initialValue: "")
    private var selected: SavedEvidenceSummary? { model.artifacts.first { $0.id == selectedID.wrappedValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(snapshotID == nil ? "Saved Operation Evidence" : "Snapshot Operation Evidence").font(.title2)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Import…", action: importFile).controlHover().disabled(model.isBusy)
                Button("Refresh") { Task { await model.refresh() } }.controlHover().disabled(model.isBusy)
                Button("Done") { dismiss() }.controlHover().keyboardShortcut(.cancelAction).disabled(model.isBusy)
            }
            TextField("Search saved evidence", text: query.projectedValue).textFieldStyle(.roundedBorder)
            HSplitView {
                List(selection: selectedID.projectedValue) {
                    ForEach(model.artifacts.filter { query.wrappedValue.isEmpty || $0.title.localizedCaseInsensitiveContains(query.wrappedValue) }) { artifact in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(artifact.title).lineLimit(2)
                            if artifact.isAvailable {
                                Text(artifact.kind.title + " · " + artifact.engine.displayName).font(.caption).appSecondaryText()
                                Text(artifact.savedAt, format: .dateTime.year().month().day().hour().minute()).font(.caption).appSecondaryText()
                                if !artifact.complete { Text(artifact.kind == .structure ? "Outcome open or unknown" : "Partial observation").font(.caption).foregroundStyle(.orange) }
                                if let snapshotID, model.links.contains(.init(snapshotID: snapshotID, evidence: artifact.reference)) {
                                    Label("Attached to this snapshot", systemImage: "paperclip").font(.caption)
                                }
                            } else { Text("Local file unavailable or damaged").font(.caption).foregroundStyle(.orange) }
                        }.tag(artifact.id)
                    }
                }.frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
                VStack(alignment: .leading, spacing: 8) {
                    if let selected {
                        HStack {
                            Button("Export…") { exportFile(selected) }.controlHover().disabled(model.isBusy || !selected.isAvailable)
                            if let snapshotID {
                                let attached = model.links.contains(.init(snapshotID: snapshotID, evidence: selected.reference))
                                Button(attached ? "Detach from Snapshot" : "Attach to Snapshot") {
                                    Task {
                                        if attached { _ = await model.detach(selected.reference, snapshotID: snapshotID) }
                                        else { _ = await model.attach(selected.reference, snapshotID: snapshotID, snapshotStore: workspace.resultSnapshots.store) }
                                    }
                                }.controlHover().disabled(model.isBusy || !selected.isAvailable)
                            }
                            if let insert {
                                Button("Insert Evidence Reference") { insert(selected); dismiss() }.controlHover()
                                    .disabled(model.isBusy || !selected.isAvailable || !workspace.canManageWorkspace)
                            }
                            Spacer(minLength: 4)
                            Button(role: .destructive) { deleting.wrappedValue = selected.id } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).controlHover().disabled(model.isBusy).accessibilityLabel("Delete saved evidence")
                        }
                        ForEach(model.links.filter { $0.evidence.id == selected.id }, id: \.self) { link in
                            HStack {
                                Text("Snapshot attachment · " + (workspace.resultSnapshots.snapshots.first { $0.id == link.snapshotID }?.title ?? link.snapshotID.uuidString))
                                    .font(.caption).lineLimit(1)
                                Button("Remove Link") { Task { _ = await model.detach(link.evidence, snapshotID: link.snapshotID) } }
                                    .controlHover().disabled(model.isBusy)
                            }
                        }
                        SavedEvidenceArtifactView(store: model.store, reference: selected.reference, revision: model.revision)
                            .id(selected.id)
                    } else {
                        Text("Save a retained structure outcome or session observation, or import a .dbeerevidence file.")
                            .appSecondaryText().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 520).padding(.leading, 8)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text("Immutable local evidence · opening files preserves their recorded state and collection times").font(.caption).appSecondaryText()
        }.padding(16).frame(minWidth: 1_000, idealWidth: 1_280, minHeight: 650, idealHeight: 760)
        .interactiveDismissDisabled(model.isBusy)
        .task { await workspace.investigations.restore(); await workspace.resultSnapshots.refresh(); await model.refresh() }
        .confirmationDialog("Delete this saved evidence?", isPresented: Binding(get: { deleting.wrappedValue != nil }, set: { if !$0 { deleting.wrappedValue = nil } })) {
            Button("Delete", role: .destructive) {
                guard let id = deleting.wrappedValue else { return }; deleting.wrappedValue = nil
                Task { _ = await model.delete(id) }
            }
            Button("Cancel", role: .cancel) { deleting.wrappedValue = nil }
        } message: { Text("Snapshot and investigation references must be removed first. The recorded database operation is unaffected.") }
    }

    private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "dbeerevidence") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        Task { _ = await model.importFile(file) }
    }
    private func exportFile(_ value: SavedEvidenceSummary) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "dbeerevidence") ?? .data]
        panel.nameFieldStringValue = value.title + ".dbeerevidence"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let parent = try SQLFileBinding.parentIdentity(of: url)
            let reviewed = try SQLFileBinding.reviewedVersion(at: url, maximumBytes: SavedEvidenceArtifact.maximumBytes)
            Task { _ = await model.exportFile(value.reference, to: url, reviewedVersion: reviewed, parent: parent) }
        } catch { model.captureFailed() }
    }
}

/// The viewer has a store reference only. Historical IDs have no live executor.
struct SavedEvidenceArtifactView: View {
    let store: PlanArtifactStore
    let reference: SavedEvidenceReference
    var revision: UInt64 = 0
    private var artifact = SwiftUI.State<SavedEvidenceArtifact?>(initialValue: nil)
    private var diagnostic = SwiftUI.State<SessionMonitorModel?>(initialValue: nil)
    private var error = SwiftUI.State<String?>(initialValue: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let value = artifact.wrappedValue {
                HStack {
                    Text(value.kind.title).font(.headline)
                    Spacer()
                    Text("Saved " + value.savedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                }
                Text([value.engine.displayName, value.profileName ?? "No recorded profile", value.environment.label].joined(separator: " · "))
                    .font(.caption).appSecondaryText().textSelection(.enabled)
                if value.sourceWasStale { Text("The source was already stale when this evidence was saved.").font(.caption).foregroundStyle(.orange) }
                if let structure = value.structure {
                    ScrollView { TableStructureExecutionReportView(review: structure.displayReview).frame(maxWidth: .infinity, alignment: .leading) }
                } else if let diagnostic = diagnostic.wrappedValue {
                    ScrollView(.horizontal) { SessionMonitorView(model: diagnostic, close: {}).frame(minWidth: 1_000) }
                }
            } else if let error = error.wrappedValue {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else { ProgressView("Reading local evidence…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: reference.id.uuidString + reference.kind.rawValue + String(revision)) {
            artifact.wrappedValue = nil; diagnostic.wrappedValue = nil; error.wrappedValue = nil
            do {
                let value = try await store.loadEvidence(reference.id, kind: reference.kind)
                try Task.checkCancellation()
                let model = value.diagnostic != nil ? try SessionMonitorModel.offline(value) : nil
                artifact.wrappedValue = value; diagnostic.wrappedValue = model
            } catch is CancellationError {}
            catch { self.error.wrappedValue = "This saved evidence is missing, damaged, or uses an unsupported format." }
        }
    }
}


struct SavedEvidenceStatusView: View {
    @ObservedObject var model: SavedEvidenceModel
    var body: some View {
        Group {
            if model.isBusy { Text("Updating local evidence…").appSecondaryText() }
            else if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            else if let notice = model.notice { Text(notice).appSecondaryText() }
        }.font(.caption)
    }
}
