import AppKit
import SwiftUI

struct SchemaBundleView: View {
    @ObservedObject var model: SchemaBundleModel
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.gearshape").font(.title2).foregroundStyle(AppPalette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Export Schema Bundle").font(.title2.weight(.semibold))
                    Text(model.profile.name + " · " + model.profile.engine.displayName).font(.callout).appSecondaryText()
                }
                Spacer()
                Label("Read-only", systemImage: "lock").font(.caption).appSecondaryText()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
            Divider()
            if !model.hasStarted { configuration }
            else if let summary = model.summary { report(summary) }
            else {
                VStack(alignment: .leading, spacing: 12) {
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Text(model.isWorking ? "Capturing the selected schemas…" : model.phase == .cancelled ? "Capture stopped." : "Capture did not complete.")
                    Text("Capture uses a separate read-only connection and has a two-minute deadline.").font(.callout).appSecondaryText()
                }
            }
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            Spacer(minLength: 0)
            Divider()
            HStack {
                if model.isWorking || model.isExporting { Button("Stop") { Task { await model.stop() } } }
                else if model.hasStarted { Button("New Capture") { Task { await model.reset() } } }
                Spacer()
                if !model.hasStarted { Button("Capture Schema") { Task { await model.start() } }.buttonStyle(.borderedProminent).disabled(!model.canStart) }
                else { Button("Export…", action: chooseDestination).buttonStyle(.borderedProminent).disabled(!model.canExport) }
            }
        }
        .padding(22).frame(minWidth: 680, idealWidth: 760, minHeight: 500, idealHeight: 560)
        .background(AppPalette.panel).foregroundStyle(AppPalette.text).tint(AppPalette.accent)
        .interactiveDismissDisabled(model.isWorking || model.isExporting)
        .accessibilityIdentifier("schemaBundle")
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.profile.endpointDescription).font(.caption).appSecondaryText().textSelection(.enabled)
            Text("Choose the schemas to capture. Names match exactly.").font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.schemas.indices, id: \.self) { index in
                        HStack {
                            TextField("Schema", text: $model.schemas[index]).textFieldStyle(.roundedBorder)
                                .disabled(model.profile.engine == .sqlite)
                            if model.schemas.count > 1 { Button { model.schemas.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove schema") }
                        }
                    }
                    if model.profile.engine != .sqlite { Button("Add Schema") { model.schemas.append("") }.disabled(model.schemas.count >= 32) }
                }
            }
            Text("Exports supported table, type and sequence definitions, with dependencies and an object report. Stored rows, privileges and sequence counters are excluded.")
                .font(.callout).appSecondaryText().fixedSize(horizontal: false, vertical: true)
        }
    }
    private func report(_ summary: SchemaBundleSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schema capture ready").font(.headline)
            Text(summary.schemas.joined(separator: " · ")).font(.callout).textSelection(.enabled)
            HStack(spacing: 24) {
                count("Included", summary.included)
                count("Omitted", summary.omitted)
                count("Incomplete", summary.incomplete)
            }
            Text("The bundle contains SQL files, a typed metadata snapshot and a manifest with checksums and dependencies. Omitted or incomplete definitions contain a comment; review their reasons in the manifest.")
                .font(.callout).appSecondaryText().fixedSize(horizontal: false, vertical: true)
            if model.isExporting {
                ProgressView(value: Double(model.transferredBytes), total: Double(summary.totalBytes))
                Text("Saving bundle…").font(.caption).appSecondaryText()
            } else if model.exported { Label("Bundle saved.", systemImage: "checkmark.circle").foregroundStyle(.green) }
            Text("Choose a new directory name when exporting. Existing files and directories are kept.").font(.caption).appSecondaryText()
        }
    }
    private func count(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(value.formatted()).font(.title2.monospacedDigit()); Text(title).font(.caption).appSecondaryText() }
    }
    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Export Schema Bundle"; panel.prompt = "Export"; panel.nameFieldStringValue = "schema-bundle"
        panel.canCreateDirectories = true; panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.export(to: url) }
    }
}
