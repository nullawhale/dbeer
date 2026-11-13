import SwiftUI

struct LogicalRelationshipsView: View {
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject var store: LogicalRelationshipStore
    init(workspace: ApplicationWorkspace) { self.workspace = workspace; store = workspace.logicalRelationships }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Local Relationships", systemImage: "link").font(.headline)
                Spacer()
                Button("New Relationship…") { workspace.editLogicalRelationship() }.controlHover()
                    .disabled(!store.isLoaded || store.isBusy || !workspace.canManageWorkspace)
                Button("Done") { workspace.dismissLogicalRelationships() }.keyboardShortcut(.cancelAction).controlHover()
            }
            Text("Confirmed local mappings are separate from database constraints. They can navigate related rows, appear as dashed ER links, and assist same-profile JOIN completion. Restoring this library never connects to a database.")
                .font(.caption).appSecondaryText().textSelection(.enabled)
            if let error = store.error {
                HStack {
                    Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    Button("Reload Library") { Task { await store.reload() } }.controlHover().disabled(store.isBusy)
                }.font(.caption)
            }
            if store.isBusy { ProgressView().controlSize(.small) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.relationships.isEmpty, store.isLoaded {
                        Text("No confirmed local relationships.").appSecondaryText().padding(.vertical, 20)
                    }
                    ForEach(store.relationships) { relationship in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Label(relationship.name, systemImage: "link").fontWeight(.semibold)
                                Spacer()
                                Text("Local · Confirmed").font(.caption).foregroundStyle(.secondary)
                                Button("Edit…") { workspace.editLogicalRelationship(relationship) }.controlHover()
                                Button("Delete", role: .destructive) { Task { try? await store.delete(id: relationship.id) } }.controlHover()
                            }.disabled(store.isBusy || !workspace.canManageWorkspace)
                            Text(endpoint(relationship.source) + " → " + endpoint(relationship.target)).textSelection(.enabled)
                            ForEach(Array(relationship.columns.enumerated()), id: \.offset) { _, pair in
                                Text(pair.source + " → " + pair.target + (pair.sqliteStorage == "preserve" ? "" : " · SQLite " + pair.sqliteStorage.uppercased()))
                                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                            Text(workspace.logicalRelationshipJOINNotice(relationship)).font(.caption2).appSecondaryText().textSelection(.enabled)
                            if !workspace.logicalRelationshipProfilesMatch(relationship) {
                                Text("The saved profile is missing or changed. Edit and explicitly validate this mapping before use.")
                                    .font(.caption).foregroundStyle(.orange)
                            } else {
                                Text("Current-session metadata is checked again before navigation. This link does not enforce referential integrity.")
                                    .font(.caption2).appSecondaryText()
                            }
                        }.padding(10)
                            .background(RoundedRectangle(cornerRadius: 7).fill(AppPalette.panel))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppPalette.border, lineWidth: 1))
                    }
                }
            }
        }.padding(16).frame(minWidth: 680, idealWidth: 800, minHeight: 400, idealHeight: 560)
            .task { await store.load() }
            .sheet(item: $workspace.logicalRelationshipEditor) { model in
                LogicalRelationshipEditorView(model: model, store: store, close: { workspace.closeLogicalRelationshipEditor(id: model.id) })
            }
            .onDisappear { workspace.closeLogicalRelationshipEditor() }
    }
    private func endpoint(_ endpoint: LogicalRelationshipEndpoint) -> String {
        let profile = workspace.library.savedConnections.first { $0.id == endpoint.profileID }
        return (profile?.name ?? "Missing profile " + endpoint.profileID.uuidString) + " · " + endpoint.label + " (" + endpoint.kind + ")"
    }
}

struct LogicalRelationshipEditorView: View {
    @ObservedObject var model: LogicalRelationshipEditorModel
    @ObservedObject var store: LogicalRelationshipStore
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local Relationship").font(.headline)
            Text(model.scopeDescription).font(.caption).appSecondaryText().textSelection(.enabled)
            TextField("Relationship name", text: $model.name).textFieldStyle(.roundedBorder)
            HStack(alignment: .top, spacing: 18) {
                endpointEditor(source: true)
                Image(systemName: "arrow.right").padding(.top, 34)
                endpointEditor(source: false)
            }
            HStack {
                Button("Load Columns") { Task { await model.loadColumns() } }.controlHover()
                Button("Suggest by Name/Type") { model.inferSuggestions() }.controlHover().disabled(!model.metadataMatches)
                Spacer()
                Button("Add Column Pair") { model.addColumn() }.controlHover()
                    .disabled(model.columns.count >= LogicalRelationshipLimits.columns)
            }.disabled(model.isBusy)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.columns.indices), id: \.self) { index in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("\(index + 1)").monospacedDigit().frame(width: 24)
                                columnPicker(index: index, source: true)
                                Image(systemName: "arrow.right")
                                columnPicker(index: index, source: false)
                                Button { model.removeColumn(at: index) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).controlHover().accessibilityLabel("Remove column pair \(index + 1)")
                            }
                            if let endpoints = model.endpoints, endpoints.0.engine != endpoints.1.engine,
                               endpoints.0.engine == .sqlite || endpoints.1.engine == .sqlite {
                                Picker("SQLite bound storage", selection: $model.columns[index].sqliteStorage) {
                                    Text("Choose explicitly").tag("preserve")
                                    Text("TEXT · preserve text bytes").tag("text")
                                    Text("INTEGER · exact signed 64-bit").tag("integer")
                                    Text("REAL · reject lossy conversion").tag("real")
                                    Text("BLOB · binary values only").tag("blob")
                                }.font(.caption)
                                    .help("This policy is used when navigating toward the SQLite endpoint. It does not turn a local mapping into a declared SQLite foreign key.")
                            }
                        }.disabled(model.isBusy)
                    }
                    ForEach(model.suggestions) { suggestion in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Unconfirmed suggestion").font(.caption).fontWeight(.semibold)
                                Text(suggestion.relationship.columns.map { $0.source + " → " + $0.target }.joined(separator: ", "))
                                Text(suggestion.reason).font(.caption2).appSecondaryText()
                            }
                            Spacer()
                            Button("Use in Draft") { model.choose(suggestion) }.controlHover().disabled(model.isBusy)
                        }.padding(8).background(AppPalette.panel)
                    }
                }
            }.frame(minHeight: 120)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let notice = model.notice { Text(notice).font(.caption).appSecondaryText().textSelection(.enabled) }
            HStack {
                if model.isReading { ProgressView("Reading column metadata…").controlSize(.small) }
                Spacer()
                if model.isReading { Button("Stop") { model.stop() }.controlHover() }
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction).controlHover().disabled(model.isSaving)
                Button("Validate Mapping") { Task { await model.validate() } }.controlHover().disabled(model.isBusy)
                Button("Confirm and Save") { Task { await model.confirm(in: store); if model.saved { close() } } }
                    .keyboardShortcut(.defaultAction).controlHover().disabled(!model.canConfirm || store.isBusy)
            }
        }.padding(16).frame(minWidth: 740, idealWidth: 860, minHeight: 520, idealHeight: 650)
            .onDisappear { model.close() }
    }
    private func endpointEditor(source: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(source ? "Source" : "Target").fontWeight(.semibold)
            Picker("Profile", selection: source ? $model.sourceProfileID : $model.targetProfileID) {
                Text("Choose a saved profile").tag(UUID?.none)
                if let id = source ? model.sourceProfileID : model.targetProfileID, !model.availableProfiles.contains(where: { $0.id == id }) {
                    Text("Missing or unsupported profile").tag(Optional(id))
                }
                ForEach(model.availableProfiles) { profile in Text(profile.name + " · " + profile.engine.displayName).tag(Optional(profile.id)) }
            }
            Picker("Object", selection: source ? $model.sourceKind : $model.targetKind) {
                Text("Table").tag("table"); Text("View").tag("view")
            }.pickerStyle(.segmented)
            TextField("Exact schema", text: source ? $model.sourceSchema : $model.targetSchema).textFieldStyle(.roundedBorder)
            TextField("Exact object name", text: source ? $model.sourceName : $model.targetName).textFieldStyle(.roundedBorder)
        }.frame(maxWidth: .infinity).disabled(model.isBusy)
    }
    private func columnPicker(index: Int, source: Bool) -> some View {
        let binding = source ? $model.columns[index].source : $model.columns[index].target
        let columns = source ? model.sourceColumns : model.targetColumns
        return HStack {
            TextField(source ? "Exact source column" : "Exact target column", text: binding).textFieldStyle(.roundedBorder)
            Menu { ForEach(Array(columns.enumerated()), id: \.offset) { _, column in Button(column.name) { binding.wrappedValue = column.name } } }
                label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).fixedSize().controlHover().disabled(columns.isEmpty)
                .accessibilityLabel(source ? "Choose source column" : "Choose target column")
        }.frame(maxWidth: .infinity)
    }
}
