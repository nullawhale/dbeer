import SwiftUI

struct ProfileImportView: View {
    @ObservedObject var workspace: ApplicationWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Connections").font(.title2)
            Text("Choose the connections to import. Each selected profile becomes a new connection. Enter your own password in Edit Connection after importing.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Select All") { workspace.selectAllImportProfiles(true) }.controlHover()
                    .accessibilityIdentifier("selectAllImportProfiles")
                Button("Deselect All") { workspace.selectAllImportProfiles(false) }.controlHover()
                    .accessibilityIdentifier("deselectAllImportProfiles")
                Spacer()
                Text("\(workspace.selectedImportProfiles.count) of \(workspace.importPreview?.count ?? 0) selected")
                    .font(.callout).foregroundStyle(.secondary)
            }.disabled(workspace.isImportingProfiles)
            List(workspace.importPreview ?? []) { imported in
                HStack(alignment: .top, spacing: 10) {
                    Toggle("Import \(imported.profile.name)", isOn: Binding(
                        get: { imported.isSelected },
                        set: { workspace.selectImportProfile(imported.id, selected: $0) })).controlHover()
                        .toggleStyle(.checkbox).labelsHidden()
                        .accessibilityIdentifier("import-profile-\(imported.id.uuidString)")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(imported.profile.name).font(.headline)
                        Text("\(imported.profile.engine.displayName) · \(imported.profile.user)@\(imported.profile.host):\(imported.profile.port)/\(imported.profile.database)")
                            .font(.callout).textSelection(.enabled)
                        HStack {
                            Text("TLS: \(imported.profile.sslMode)").font(.caption).foregroundStyle(.secondary)
                            if imported.profile.sslRootCert != nil {
                                Button(imported.requiresCASelection ? "Choose Missing CA File…" : "Change CA File…") {
                                    workspace.chooseImportedCA(imported.id)
                                }.controlHover()
                                .disabled(!imported.isSelected)
                            }
                        }
                        if imported.requiresCASelection {
                            Text("The CA file is unavailable on this Mac.").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }.padding(.vertical, 6)
            }.disabled(workspace.isImportingProfiles)
            if let error = workspace.importError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Cancel") { workspace.importPreview = nil }.controlHover().keyboardShortcut(.cancelAction)
                    .disabled(workspace.isImportingProfiles)
                Spacer()
                Button("Import Selected") { Task { await workspace.importProfiles() } }.controlHover()
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!workspace.canImportProfiles)
                    .accessibilityIdentifier("importSelectedProfiles")
            }
        }.padding(20).frame(width: 720, height: 520)
            .tint(AppPalette.accent)
            .focusEffectDisabled()
            .interactiveDismissDisabled(workspace.isImportingProfiles)
    }
}
