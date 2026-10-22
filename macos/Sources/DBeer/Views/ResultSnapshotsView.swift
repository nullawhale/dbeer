import SwiftUI

struct ResultSnapshotsView: View {
    @ObservedObject var model: ResultSnapshotsModel
    var openSnapshot: ((ResultSnapshotSummary) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    private var quotaMiB = SwiftUI.State(initialValue: "1024")
    private var deletion = SwiftUI.State<ResultSnapshotsModel.DeletionRequest?>(initialValue: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Result Snapshots").font(.title2.weight(.semibold))
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await refresh() } }.controlHover()
                    .disabled(model.isBusy).accessibilityIdentifier("refreshResultSnapshots")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Storage limit")
                TextField("MiB", text: quotaMiB.projectedValue).textFieldStyle(.roundedBorder)
                    .frame(width: 100).accessibilityLabel("Snapshot storage limit in MiB")
                    .accessibilityIdentifier("snapshotQuotaMiB")
                Text("MiB")
                Button("Apply") { Task { await applyQuota() } }.controlHover()
                    .disabled(model.isBusy || quotaBytes == nil || quotaBytes == model.quotaBytes)
                    .accessibilityIdentifier("applySnapshotQuota")
                Button("Use 1 GiB") { quotaMiB.wrappedValue = "1024" }.controlHover()
                    .disabled(model.isBusy)
                Spacer()
                Text("\(ResultSnapshotsModel.byteCount(model.usedBytes)) used of \(ResultSnapshotsModel.byteCount(model.quotaBytes))")
                    .font(.caption).appSecondaryText()
            }
            .disabled(model.isBusy)
            if quotaBytes == nil {
                Text("Enter a positive whole number of MiB.").font(.caption).foregroundStyle(.orange)
            }
            Text("Snapshots are saved only when requested. Existing snapshots are never deleted automatically, including when storage is full.")
                .font(.callout).appSecondaryText()
            Table(model.snapshots) {
                TableColumn("Snapshot") { snapshot in
                    VStack(alignment: .leading, spacing: 3) {
                        if let openSnapshot, snapshot.isAvailable {
                            Button(snapshot.title) { openSnapshot(snapshot) }.buttonStyle(.plain).controlHover()
                                .accessibilityIdentifier("openSnapshot-\(snapshot.id.uuidString)")
                        } else { Text(snapshot.title) }
                        HStack(spacing: 6) {
                            if snapshot.isAvailable {
                                Text(snapshot.engine.displayName)
                                if let name = snapshot.profileName { Text("· \(name)") }
                                if snapshot.truncated || snapshot.partial {
                                    Label("Partial", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                }
                            } else {
                                Label("Unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }.font(.caption).appSecondaryText()
                    }
                }.width(min: 200, ideal: 280)
                TableColumn("Captured") { snapshot in
                    if snapshot.isAvailable {
                        Text(snapshot.capturedAt, format: .dateTime.year().month().day().hour().minute())
                    } else { Text("—") }
                }.width(min: 130, ideal: 160)
                TableColumn("Rows") { snapshot in
                    Text(snapshot.isAvailable ? snapshot.rowCount.formatted() : "—").monospacedDigit()
                }
                    .width(min: 55, ideal: 75)
                TableColumn("Size") { snapshot in Text(ResultSnapshotsModel.byteCount(snapshot.byteCount)).monospacedDigit() }
                    .width(min: 65, ideal: 90)
                TableColumn("") { snapshot in
                    Button(role: .destructive) { deletion.wrappedValue = model.requestDeletion(snapshot.id) } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.plain).controlHover().disabled(model.isBusy)
                        .help("Delete snapshot").accessibilityLabel("Delete \(snapshot.title)")
                        .accessibilityIdentifier("deleteSnapshot-\(snapshot.id.uuidString)")
                }.width(30)
            }
            .overlay {
                if model.snapshots.isEmpty && !model.isBusy {
                    VStack(spacing: 8) {
                        Image(systemName: "archivebox").font(.title).accessibilityHidden(true)
                        Text("No saved result snapshots").font(.headline)
                        Text("Captured results will appear here.").font(.callout)
                    }.appSecondaryText().allowsHitTesting(false)
                }
            }
            .accessibilityIdentifier("resultSnapshotsList")
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .accessibilityIdentifier("resultSnapshotsError")
            }
            HStack {
                Text("\(model.snapshots.count.formatted()) snapshots").font(.caption).appSecondaryText()
                Spacer()
                Button("Done") { dismiss() }.controlHover().keyboardShortcut(.cancelAction)
                    .disabled(model.isBusy).accessibilityIdentifier("closeResultSnapshots")
            }
        }
        .padding(20).frame(width: 820, height: 520)
        .tint(AppPalette.accent).focusEffectDisabled().interactiveDismissDisabled(model.isBusy)
        .task { await refresh() }
        .alert("Delete Snapshot?", isPresented: Binding(get: { deletion.wrappedValue != nil },
            set: { if !$0 { deletion.wrappedValue = nil } })) {
            Button("Cancel", role: .cancel) { deletion.wrappedValue = nil }
            Button("Delete", role: .destructive) {
                guard let request = deletion.wrappedValue else { return }
                deletion.wrappedValue = nil
                Task { _ = await model.deleteConfirmed(request) }
            }
        } message: {
            if let request = deletion.wrappedValue, !request.investigationIDs.isEmpty {
                Text("This snapshot is used by \(request.investigationIDs.count.formatted()) investigation documents. Delete its saved data? The documents will retain their explanations and show the snapshot as missing.")
            } else {
                Text("Permanently delete this saved result? Other snapshots will be kept.")
            }
        }
    }

    private var quotaBytes: Int64? { ResultSnapshotsModel.quotaBytes(fromMiB: quotaMiB.wrappedValue) }

    private func refresh() async {
        await model.refresh()
        quotaMiB.wrappedValue = String(max(1, model.quotaBytes / ResultSnapshotsModel.bytesPerMiB))
    }

    private func applyQuota() async {
        guard let value = quotaBytes else { return }
        _ = await model.updateQuotaBytes(value)
    }
}
