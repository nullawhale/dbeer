import Foundation
import SwiftUI

struct ERDiagramAreaPanel: View {
    @ObservedObject var model: ERDiagramModel
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject var document: SQLDocument
    let focus: () -> Void
    private var schemaState: SwiftUI.State<String>
    private var searchState = SwiftUI.State(initialValue: "")
    private var exactNameState = SwiftUI.State(initialValue: "")
    private var listSearchState = SwiftUI.State(initialValue: "")
    private var addExpandedState: SwiftUI.State<Bool>
    private var bindingReview = SwiftUI.State<ERDiagramSource?>(initialValue: nil)
    private var showingBindingReview = SwiftUI.State(initialValue: false)
    private var rebindReview = SwiftUI.State<ERDiagramRebindReview?>(initialValue: nil)
    private var showingRebindReview = SwiftUI.State(initialValue: false)
    private var removalReview = SwiftUI.State<ERDiagramRemovalReview?>(initialValue: nil)
    private var showingRemovalReview = SwiftUI.State(initialValue: false)

    init(model: ERDiagramModel, workspace: ApplicationWorkspace, document: SQLDocument, focus: @escaping () -> Void) {
        self.model = model; self.workspace = workspace; self.document = document; self.focus = focus
        schemaState = SwiftUI.State(initialValue: model.initialSchema ?? model.stored.tables.first?.schema ??
            (model.stored.engine == .mysql ? model.stored.database : model.stored.engine == .sqlite ? "main" : "public"))
        addExpandedState = SwiftUI.State(initialValue: model.stored.tables.isEmpty)
    }

    private var connected: Bool { workspace.erDiagramContext(model) != nil }
    private var canDiscoverAll: Bool {
        connected && !model.activeSourceIsLoading && !model.isSearching && model.visibleTableDiscovery?.isBusy != true && model.neighbourDiscovery?.isBusy != true
    }
    private var canSearch: Bool { canDiscoverAll && ERTableID.validName(schemaState.wrappedValue) }
    private var tables: [ERTableID] {
        model.stored.tables.filter { listSearchState.wrappedValue.isEmpty || $0.label.localizedCaseInsensitiveContains(listSearchState.wrappedValue) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tables").font(.headline)
                Spacer()
                Text("\(model.stored.tables.count)").font(.caption).monospacedDigit().appSecondaryText()
            }.padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 10)
            sourcePicker.padding(.horizontal, 12).padding(.bottom, 10)
            TextField("Filter diagram tables", text: listSearchState.projectedValue)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Filter diagram tables")
                .padding(.horizontal, 12).padding(.bottom, 10)
            DisclosureGroup(isExpanded: addExpandedState.projectedValue) {
                addTables.padding(.top, 8)
            } label: {
                Label("Add Tables", systemImage: "plus.circle").font(.callout)
            }.padding(.horizontal, 12).padding(.bottom, 12)
            Divider()
            if model.stored.tables.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Choose your diagram area").font(.callout).fontWeight(.medium)
                    Text("Add tables, then Build to load their columns and relationships.")
                        .font(.caption).appSecondaryText()
                }.padding(14)
                Spacer(minLength: 0)
            } else {
                tableList
            }
            Divider()
            HStack(spacing: 8) {
                Button { focus() } label: { Label("Focus", systemImage: "scope") }
                    .controlHover().disabled(model.stored.selected == nil)
                    .help("Center the selected table on the canvas")
                Spacer(minLength: 0)
                ControlIconButton(systemName: "minus.circle") {
                    if let table = model.stored.selected { model.remove(table) }
                }.disabled(model.stored.selected == nil || model.stored.selected.map { model.sourceState($0.profileID).loading } == true)
                    .help("Remove selected table from this diagram")
                    .accessibilityLabel("Remove table from diagram")
            }.padding(10)
            if model.draftDiffersFromGraph {
                Label("Selection changed. Build to update.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 12).padding(.bottom, 10)
            }
        }.background(AppPalette.panel)
            .onChange(of: model.activeSourceID) { _, id in
                let source = model.source(id)
                schemaState.wrappedValue = model.stored.tables.first(where: { $0.profileID == id })?.schema ??
                    (source?.engine == .mysql ? source?.database ?? "" : source?.engine == .sqlite ? "main" : "public")
                searchState.wrappedValue = ""; exactNameState.wrappedValue = ""
            }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Profile", selection: Binding(get: { model.activeSourceID }, set: { workspace.selectERDiagramSource(model, profileID: $0) })) {
                ForEach(Array(model.sourceProfileIDs).sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                    Text(model.source(id)?.name ?? workspace.library.savedConnections.first(where: { $0.id == id })?.name ?? "Missing profile " + id.uuidString).tag(id)
                }
            }.accessibilityLabel("Active diagram source profile")
            Menu("Add Profile") {
                ForEach(workspace.library.savedConnections.filter { [.postgresql, .mysql, .sqlite].contains($0.engine) && !model.ownsSource($0.id) }) { profile in
                    Button(profile.name) { workspace.confirmERDiagramSource(document, profileID: profile.id) }
                }
            }.controlHover().disabled(model.stored.sourceProfileIDs.count >= ERDiagramLimits.sources)
            Button("Remove Source…") {
                let id = model.activeSourceID
                removalReview.wrappedValue = .init(profileID: id, name: model.ownerName(id), fingerprint: model.source(id)?.fingerprint ?? "legacy",
                    tables: model.stored.tables.filter { $0.profileID == id })
                showingRemovalReview.wrappedValue = true
            }.controlHover()
            if model.source(model.activeSourceID) == nil {
                Text("This legacy diagram has no saved server identity. Review its current saved profile before reading metadata.").font(.caption2).foregroundStyle(.orange)
                Button("Review Current Binding…") {
                    if let profile = workspace.library.savedConnections.first(where: { $0.id == model.activeSourceID }) {
                        bindingReview.wrappedValue = .init(profile); showingBindingReview.wrappedValue = true
                    }
                }.controlHover().disabled(!workspace.library.savedConnections.contains { $0.id == model.activeSourceID })
            } else if let source = model.source(model.activeSourceID), !workspace.library.savedConnections.contains(where: { source.matches($0) }) {
                Text("The original saved profile is missing or changed. Rebind an object explicitly; no replacement is selected automatically.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            ForEach(model.stored.sources) { source in
                let state = model.sourceState(source.profileID)
                if state.loading {
                    Text(source.name + ": loading " + String(state.progress) + "/" + String(model.stored.tables.filter { $0.profileID == source.profileID }.count))
                        .font(.caption2).appSecondaryText()
                } else if let reason = state.notice {
                    Text(source.name + ": " + reason).font(.caption2).appSecondaryText().lineLimit(3).help(reason)
                }
            }
        }
        .confirmationDialog("Remove Diagram Source", isPresented: showingRemovalReview.projectedValue, presenting: removalReview.wrappedValue) { review in
            Button("Remove Source and Its Tables") {
                workspace.removeERDiagramSource(document, profileID: review.profileID, expectedFingerprint: review.fingerprint, expectedTables: review.tables)
            }
        } message: { review in
            Text("Remove " + review.name + " and its " + String(review.tables.count) + " selected tables from this diagram? Saved profiles, databases and confirmed local mappings are retained.")
        }
        .confirmationDialog("Confirm Diagram Source", isPresented: showingBindingReview.projectedValue, presenting: bindingReview.wrappedValue) { source in
            Button("Bind to This Saved Profile") {
                workspace.confirmERDiagramSource(document, profileID: source.profileID, expectedFingerprint: source.fingerprint)
            }
        } message: { source in
            Text("Use " + source.name + " (" + source.engine.rawValue + " · " + source.database + ") for this diagram's original objects? This records its current nonsecret identity. Loading and connecting remain separate explicit actions.")
        }
    }

    private var tableList: some View {
        List(selection: Binding(get: { model.stored.selected }, set: { model.select($0); focus() })) {
            ForEach(tables) { table in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "tablecells").font(.system(size: 13)).appSecondaryText().padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(table.name).font(.callout).lineLimit(1)
                        Text(model.ownerName(table.profileID) + " · " + table.schema).font(.caption).appSecondaryText().lineLimit(1)
                        if let state = model.metadata[table]?.columnState.reason {
                            Text(state).font(.caption2).appSecondaryText().lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 4).tag(table).help(model.ownerName(table.profileID) + " · " + table.label + " · " + table.profileID.uuidString)
            }
        }.listStyle(.plain).scrollContentBackground(.hidden)
            .accessibilityLabel("Tables in diagram")
            .overlay {
                if tables.isEmpty {
                    Text("No matching tables").font(.caption).appSecondaryText().padding(12)
                }
            }
    }

    private var addTables: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Schema / database", text: schemaState.projectedValue)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Exact schema or database")
            HStack(spacing: 6) {
                TextField("Search tables", text: searchState.projectedValue)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Search tables in schema")
                ControlIconButton(systemName: "magnifyingglass") {
                    Task { await workspace.searchERDiagram(document, schema: schemaState.wrappedValue, search: searchState.wrappedValue) }
                }.disabled(!canSearch).help("Search table metadata in the exact schema or database")
                    .accessibilityLabel("Search tables")
            }
            HStack(spacing: 6) {
                Button("Discover Schema") { Task { await workspace.discoverERVisibleTables(document, schema: schemaState.wrappedValue) } }
                    .controlHover().disabled(!canSearch || !workspace.supportsRelationshipDiscovery(profileID: model.activeSourceID))
                Button("Discover All Visible") { Task { await workspace.discoverERVisibleTables(document) } }
                    .controlHover().disabled(!canDiscoverAll || !workspace.supportsRelationshipDiscovery(profileID: model.activeSourceID))
            }
            Text("Explicit discovery retains up to 256 schemas and 10,000 table names for two minutes. Stop keeps a partial list. Add tables, then Build (100 tables maximum).")
                .font(.caption2).appSecondaryText()
            if let discovery = model.visibleTableDiscovery {
                VisibleTableDiscoveryPanel(discovery: discovery, diagram: model)
            }
            if model.isSearching { ProgressView().controlSize(.small) }
            if let notice = model.candidateNotice {
                Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !model.candidates.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(model.candidates) { table in
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(table.name).font(.caption).lineLimit(1)
                                    Text(table.schema).font(.caption2).appSecondaryText().lineLimit(1)
                                }.help(table.label)
                                Spacer(minLength: 0)
                                Button(model.stored.tables.contains(table) ? "Added" : "Add") { model.add(table) }
                                    .controlHover().controlSize(.small)
                                    .disabled(model.stored.tables.contains(table) || model.sourceState(table.profileID).loading)
                            }
                        }
                    }.padding(.vertical, 3)
                }.frame(maxHeight: 150)
            }
            HStack(spacing: 6) {
                TextField("Exact table name", text: exactNameState.projectedValue).textFieldStyle(.roundedBorder)
                ControlIconButton(systemName: "plus") {
                    model.add(.init(profileID: model.activeSourceID, schema: schemaState.wrappedValue, name: exactNameState.wrappedValue))
                    exactNameState.wrappedValue = ""
                }.disabled(model.activeSourceIsLoading || !ERTableID.validName(schemaState.wrappedValue) || !ERTableID.validName(exactNameState.wrappedValue))
                    .help("Add this exact schema and table name without searching")
                    .accessibilityLabel("Add exact table name")
            }
            if let selected = model.stored.selected {
                Button("Rebind Selected Table…") {
                    guard let profile = workspace.library.savedConnections.first(where: { $0.id == model.activeSourceID }) else { return }
                    rebindReview.wrappedValue = .init(original: selected,
                        replacement: .init(profileID: profile.id, schema: schemaState.wrappedValue, name: exactNameState.wrappedValue),
                        originalFingerprint: model.source(selected.profileID)?.fingerprint ?? "legacy",
                        originalOwner: model.ownerName(selected.profileID), destination: .init(profile))
                    showingRebindReview.wrappedValue = true
                }.controlHover().disabled(!ERTableID.validName(schemaState.wrappedValue) || !ERTableID.validName(exactNameState.wrappedValue))
            }
            Text("Names are exact identifiers. Build checks availability.")
                .font(.caption2).appSecondaryText()
                .help("Schema and table names are separate exact identifiers, including any punctuation. Metadata is read only when you explicitly Search or Build.")
        }.controlSize(.small)
            .confirmationDialog("Rebind Diagram Object", isPresented: showingRebindReview.projectedValue, presenting: rebindReview.wrappedValue) { review in
                Button("Rebind and Clear Metadata") {
                    workspace.rebindERDiagramTable(document, original: review.original, replacement: review.replacement,
                        expectedOriginalFingerprint: review.originalFingerprint, expectedDestinationFingerprint: review.destination.fingerprint)
                }
            } message: { review in
                Text(review.originalOwner + " · " + review.original.label + " → " + review.destination.name + " · " + review.replacement.label + ". Columns and relationships will be cleared until an explicit Build. Confirmed local mappings retain their original endpoints.")
            }
    }
}

private struct ERDiagramRemovalReview {
    let profileID: UUID
    let name: String
    let fingerprint: String
    let tables: [ERTableID]
}

private struct ERDiagramRebindReview {
    let original: ERTableID
    let replacement: ERTableID
    let originalFingerprint: String
    let originalOwner: String
    let destination: ERDiagramSource
}

struct ERDiagramInspector: View {
    @ObservedObject var model: ERDiagramModel
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject var document: SQLDocument
    private var columnsExpandedState = SwiftUI.State(initialValue: true)

    private var connected: Bool { workspace.erDiagramContext(model, profileID: model.stored.selected?.profileID ?? model.activeSourceID) != nil }
    private var relationships: [ERRelationship] {
        model.relationships.filter { model.stored.selected == nil || $0.source == model.stored.selected || $0.target == model.stored.selected }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let table = model.stored.selected { tableDetails(table) }
                else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Inspector", systemImage: "info.circle").font(.headline)
                        Text("Select a table to inspect its columns and relationships.")
                            .font(.caption).appSecondaryText()
                    }
                }
                relationshipSection
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }.background(AppPalette.panel).accessibilityLabel("ER diagram inspector")
    }

    @ViewBuilder
    private func tableDetails(_ table: ERTableID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "tablecells").font(.title3).foregroundStyle(AppPalette.accent).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(table.name).font(.headline).textSelection(.enabled)
                    Text(model.ownerName(table.profileID) + " · " + table.schema).font(.caption).appSecondaryText().textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Button { Task { await workspace.openERTable(document, table: table) } } label: {
                    Label("Open Data", systemImage: "tablecells")
                }.controlHover()
                Menu {
                    Button("Open Data in New Tab") { Task { await workspace.openERTable(document, table: table, newTab: true) } }
                    Button("Show Structure") { Task { await workspace.openERTable(document, table: table, structure: true) } }
                    Divider()
                    Button(model.stored.collapsed.contains(table) ? "Show All Columns" : "Collapse Non-key Columns") { model.toggleCollapse(table) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().controlHover().accessibilityLabel("Table actions")
            }.controlSize(.small)
            Button("Find Neighbours") { Task { await workspace.discoverERNeighbours(document) } }
                .controlHover().controlSize(.small)
                .disabled(!connected || model.sourceState(table.profileID).loading || model.isSearching || model.neighbourDiscovery?.isBusy == true ||
                    model.visibleTableDiscovery?.isBusy == true || !workspace.supportsRelationshipDiscovery(profileID: table.profileID))
            if let discovery = model.neighbourDiscovery, (discovery.resolvedTarget ?? discovery.target) == table {
                ERNeighbourDiscoveryPanel(discovery: discovery, diagram: model)
            }
            if let facts = model.metadata[table] {
                metadataState(facts)
                Divider()
                DisclosureGroup(isExpanded: columnsExpandedState.projectedValue) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(facts.columns.enumerated()), id: \.offset) { index, column in
                            inspectorColumn(column, facts: facts)
                            if index + 1 < facts.columns.count { Divider().opacity(0.5) }
                        }
                        if facts.columns.isEmpty {
                            Text(facts.columnState.isAvailable ? "No columns reported." : "Column metadata is unavailable.")
                                .font(.caption).appSecondaryText().padding(.vertical, 8)
                        }
                    }.padding(.top, 6)
                } label: {
                    HStack {
                        Text("Columns").font(.callout).fontWeight(.semibold)
                        Spacer()
                        Text("\(facts.columns.count)").font(.caption).monospacedDigit().appSecondaryText()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metadataState(_ facts: ERTableMetadata) -> some View {
        if let reason = facts.columnState.reason {
            Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
        if let reason = facts.relationshipState.reason {
            Text("Relationships: " + reason).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
        if !facts.columnState.isAvailable || !facts.relationshipState.isAvailable {
            Button("Retry Metadata") { Task { await workspace.buildERDiagram(document, profileID: facts.table.profileID, retryFailuresOnly: true) } }
                .controlHover().controlSize(.small).disabled(model.sourceState(facts.table.profileID).loading || workspace.erDiagramContext(model, profileID: facts.table.profileID) == nil)
        }
    }

    private func inspectorColumn(_ column: ERColumn, facts: ERTableMetadata) -> some View {
        let isForeignKey = facts.relationshipState.isAvailable && facts.foreignKeys.contains { key in
            key.columns.contains { Data($0.source.utf8) == Data(column.name.utf8) }
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(column.name).font(.system(.caption, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 0)
                if facts.columnState.isAvailable, let position = column.primaryKeyPosition {
                    ERDiagramPanelBadge(text: "PK \(position)", prominent: true).accessibilityLabel("Primary key position \(position)")
                }
                if isForeignKey { ERDiagramPanelBadge(text: "FK", prominent: false).accessibilityLabel("Foreign key column") }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(column.nativeType).font(.caption).appSecondaryText().lineLimit(2).textSelection(.enabled).help(column.nativeType)
                Spacer(minLength: 0)
                Text(column.nullable ? "NULL" : "NOT NULL").font(.system(size: 9, weight: .medium)).appSecondaryText()
            }
        }.padding(.vertical, 8)
    }

    private var relationshipSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text("Relationships").font(.callout).fontWeight(.semibold)
                Spacer()
                Text("\(relationships.count)").font(.caption).monospacedDigit().appSecondaryText()
            }
            Text("Solid: declared foreign key · Dashed: local confirmed mapping")
                .font(.caption).appSecondaryText().help("Local mappings do not enforce database constraints. No cardinality is inferred.")
            if relationships.isEmpty {
                Text("No loaded relationships in this selection.")
                    .font(.caption).appSecondaryText()
                Text("Unavailable metadata does not mean that no foreign keys exist.")
                    .font(.caption2).appSecondaryText()
            }
            ForEach(relationships) { edge in relationshipCard(edge) }
        }
    }

    private func relationshipCard(_ edge: ERRelationship) -> some View {
        let selected = model.selectedRelationshipID == edge.id
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                model.selectedRelationshipID = edge.id
                guard model.stored.tables.contains(edge.target) else { return }
                model.stored.collapsed.removeAll { $0 == edge.source || $0 == edge.target }; model.changed?()
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: edge.kind == .logical ? "link" : "arrow.triangle.branch").foregroundStyle(selected ? AppPalette.accent : AppPalette.secondaryText)
                    Text(edge.key.name).font(.caption).fontWeight(.semibold).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).controlHover().help(edge.key.name).accessibilityLabel("Highlight \(edge.kind == .logical ? "local relationship" : "foreign key") \(edge.key.name)")
            VStack(alignment: .leading, spacing: 4) {
                Text((edge.sourceProfileName ?? model.ownerName(edge.source.profileID)) + " · " + edge.source.label).font(.caption).textSelection(.enabled)
                Label((edge.targetProfileName ?? model.ownerName(edge.target.profileID)) + " · " + edge.target.label, systemImage: "arrow.turn.down.right").font(.caption).textSelection(.enabled)
            }.foregroundStyle(AppPalette.secondaryText)
            if edge.kind == .logical {
                Text("Local · User-confirmed · No database constraint").font(.caption2).appSecondaryText()
                if let notice = edge.validationNotice { Text(notice).font(.caption2).foregroundStyle(.orange).textSelection(.enabled) }
                HStack {
                    Button("Open Source") { Task { await workspace.openLogicalRelationshipEndpoint(edge, target: false, from: document) } }
                    Button("Open Target") { Task { await workspace.openLogicalRelationshipEndpoint(edge, target: true, from: document) } }
                }.controlHover().controlSize(.small)
                    .disabled(!workspace.canStartOperation(document))
                Button("Edit Local Mapping…") {
                    guard let id = edge.logicalID, let relationship = workspace.logicalRelationships.relationship(id: id) else { return }
                    workspace.editLogicalRelationship(relationship)
                }.controlHover().controlSize(.small)
            }
            Divider()
            ForEach(Array(edge.key.columns.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(pair.position)").font(.caption2).monospacedDigit().appSecondaryText().frame(minWidth: 10, alignment: .leading)
                    Text(pair.source).lineLimit(2)
                    Image(systemName: "arrow.right").font(.system(size: 9)).appSecondaryText()
                    Text(pair.target).lineLimit(2)
                    Spacer(minLength: 0)
                }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            if !model.stored.tables.contains(edge.target) {
                Text("Referenced table is outside the diagram.").font(.caption2).appSecondaryText()
                if model.ownsSource(edge.target.profileID) {
                    Button("Add to Diagram") { model.add(edge.target) }.controlHover().controlSize(.small).disabled(model.sourceState(edge.target.profileID).loading)
                } else if let profile = workspace.library.savedConnections.first(where: { $0.id == edge.target.profileID }) {
                    Button("Add Target Profile and Table") {
                        workspace.confirmERDiagramSource(document, profileID: profile.id)
                        model.add(edge.target)
                    }.controlHover().controlSize(.small)
                } else { Text("The external saved profile is missing.").font(.caption2).appSecondaryText() }
            } else if model.metadata[edge.target]?.columnState.isAvailable != true {
                Text("Target columns are unavailable or stale. Table-level reference only.")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }.padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? AppPalette.accent.opacity(0.09) : AppPalette.background.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? AppPalette.accent.opacity(0.7) : AppPalette.border, lineWidth: 1))
    }
}

private struct ERDiagramPanelBadge: View {
    let text: String
    let prominent: Bool
    var body: some View {
        Text(text).font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(prominent ? AppPalette.accent : AppPalette.secondaryText)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(prominent ? AppPalette.accent.opacity(0.12) : AppPalette.secondaryText.opacity(0.09)))
    }
}
