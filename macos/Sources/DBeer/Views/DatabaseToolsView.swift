import AppKit
import SwiftUI

struct DatabaseToolsView: View {
    @ObservedObject var model: DatabaseToolsModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Database Dump & Restore").font(.title2.weight(.semibold))
                    Text("PostgreSQL, MySQL and MariaDB native utilities").font(.caption).appSecondaryText()
                }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Close", action: close).keyboardShortcut(.cancelAction).disabled(model.isBusy).controlHover()
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    configuration
                    if let preview = model.preview { prepared(preview) }
                    if let result = model.result { outcome(result) }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                            .accessibilityIdentifier("databaseToolsError")
                    }
                }.padding(20)
            }
            Divider()
            HStack(spacing: 12) {
                if model.isBusy {
                    Button(model.isStopping ? "Stopping…" : "Stop") { Task { await model.stop() } }
                        .disabled(model.isStopping).controlHover().accessibilityIdentifier("databaseToolsStop")
                } else if model.result != nil {
                    Button("New Operation") { Task { await model.reset() } }.controlHover()
                        .accessibilityIdentifier("databaseToolsReset")
                }
                Spacer()
                Button("Preview") { Task { await model.prepare() } }.disabled(!model.canPreview).controlHover()
                    .accessibilityIdentifier("databaseToolsPreview")
                Button(model.operation == .dump ? "Start Dump" : "Restore…") { Task { await model.start() } }
                    .disabled(!model.canStart).controlHover().accessibilityIdentifier("databaseToolsStart")
            }.padding(16)
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 590, idealHeight: 720)
        .background(AppPalette.panel).tint(AppPalette.accent).focusEffectDisabled()
        .interactiveDismissDisabled(model.isBusy)
        .accessibilityElement(children: .contain).accessibilityIdentifier("databaseTools")
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Connection", selection: $model.profileID) {
                Text("Choose connection").tag(UUID?.none)
                ForEach(model.profiles) { profile in
                    Text("\(profile.name) · \(profile.engine.displayName)").tag(Optional(profile.id))
                }
            }.accessibilityIdentifier("databaseToolsConnection")
            if let profile = model.selectedProfile {
                Text("\(profile.endpointDescription) · \(profile.policy.label)")
                    .font(.caption).appSecondaryText().lineLimit(1).textSelection(.enabled)
            }
            HStack {
                TextField("Database", text: $model.database).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("databaseToolsDatabase")
                Picker("Operation", selection: $model.operation) {
                    ForEach(DatabaseToolsOperation.allCases) { operation in Text(operation.title).tag(operation) }
                }.frame(width: 190).accessibilityIdentifier("databaseToolsOperation")
            }
            Picker("Format", selection: $model.format) {
                ForEach(model.formats) { format in Text(format.title).tag(format) }
            }.accessibilityIdentifier("databaseToolsFormat")
            HStack {
                TextField(model.operation == .dump ? "Output file" : "Input file", text: $model.path)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("databaseToolsPath")
                Button("Choose File…", action: chooseFile).controlHover()
            }
            HStack {
                TextField("Path to \(model.expectedToolName)", text: $model.toolPath)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("databaseToolsUtility")
                Button("Choose \(model.expectedToolName)…", action: chooseUtility).controlHover()
            }
            Text("Preview checks the utility and server versions and binds the selected file. An existing dump destination is replaced only after a successful operation.")
                .font(.caption).appSecondaryText().textSelection(.enabled)
            if model.operation == .restore {
                Label("Restore executes the selected file and can change existing database objects. Use a trusted dump. Failed or stopped restores can leave partial changes.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                if model.selectedProfile?.policy.readOnly == true {
                    Text("This connection is readonly. Select a writable connection to restore.").font(.callout).foregroundStyle(.orange)
                }
            }
        }.disabled(!model.canConfigure)
    }

    private func prepared(_ preview: DatabaseToolsReply) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Preview ready", systemImage: "checkmark.circle").font(.headline)
            LabeledContent("Database", value: preview.database ?? "—")
            LabeledContent("Utility", value: "\(preview.toolName ?? "—") \(preview.toolVersion ?? "")")
            LabeledContent("Server", value: preview.serverVersion ?? "—")
            LabeledContent("File", value: preview.path ?? "—")
            ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "info.circle").font(.callout).appSecondaryText()
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.background, in: RoundedRectangle(cornerRadius: 8)).textSelection(.enabled)
            .accessibilityIdentifier("databaseToolsPrepared")
    }

    private func outcome(_ result: DatabaseToolsReply) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(outcomeTitle(result)).font(.headline)
            if let profile = model.capturedProfile {
                Text("\(profile.name) · \(model.capturedDatabase ?? "")").font(.caption).appSecondaryText()
            }
            if result.state.isWorking {
                if let progress = model.progress { ProgressView(value: progress) }
                else { ProgressView().progressViewStyle(.linear) }
                Text(result.phase ?? "Running utility…").font(.callout).appSecondaryText()
            }
            if let count = result.bytesProcessed {
                Text(result.totalBytes.map { "\(count) of \($0) file bytes transferred" } ?? "\(count) file bytes transferred")
                    .font(.caption).monospacedDigit().appSecondaryText()
                if model.capturedOperation == .restore && result.state.isWorking {
                    Text("File transfer progress does not mean the database has finished applying the restore.")
                        .font(.caption).appSecondaryText()
                }
            }
            if let message = result.message { Text(message).textSelection(.enabled) }
            if result.state.isUncertain {
                Label("Inspect the destination before starting another restore. No automatic retry will run.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled)
            }
            if result.outputPublished {
                Label("Dump file saved", systemImage: "checkmark.circle").foregroundStyle(.green)
                if let path = result.path { Text(path).font(.caption).textSelection(.enabled) }
            }
            if let exitCode = result.exitCode { Text("Utility exit status: \(exitCode)").font(.caption).appSecondaryText() }
            ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning).font(.callout).appSecondaryText().textSelection(.enabled)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.background, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("databaseToolsResult")
    }
    private func outcomeTitle(_ result: DatabaseToolsReply) -> String {
        switch result.state {
        case .prepared: "Prepared"
        case .running: model.capturedOperation == .restore ? "Restoring…" : "Dumping…"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        case .partial: "Restore stopped with partial changes"
        case .outcomeUnknown: "Restore outcome is uncertain"
        case .closed: "Closed"
        }
    }
    private func chooseFile() {
        guard model.canConfigure else { return }
        if model.operation == .dump {
            let panel = NSSavePanel()
            panel.title = "Choose Dump Destination"
            panel.nameFieldStringValue = (model.database.isEmpty ? "database" : model.database) + "." + model.format.pathExtension
            if panel.runModal() == .OK, let url = panel.url { model.path = url.path }
        } else {
            let panel = NSOpenPanel()
            panel.title = "Choose Trusted Database Dump"
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url { model.path = url.path }
        }
    }
    private func chooseUtility() {
        guard model.canConfigure else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose \(model.expectedToolName)"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.toolPath = url.path }
    }
}
