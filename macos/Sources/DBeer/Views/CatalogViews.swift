import AppKit
import SwiftUI

struct ProfileCatalogRow: View {
    let profile: SavedConnection
    @ObservedObject var workspace: ApplicationWorkspace
    let edit: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void
    private var expanded = SwiftUI.State(initialValue: false)
    private var isExpanding = SwiftUI.State(initialValue: false)

    init(profile: SavedConnection, workspace: ApplicationWorkspace, edit: @escaping () -> Void,
         duplicate: @escaping () -> Void, delete: @escaping () -> Void) {
        self.profile = profile
        self.workspace = workspace
        self.edit = edit
        self.duplicate = duplicate
        self.delete = delete
    }

    private var isConnected: Bool { workspace.services[profile.id]?.connectionState == .connected }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded.wrappedValue }, set: { setExpanded($0) })) {
            catalog
        } label: {
            row.padding(.leading, 8)
        }
        .onChange(of: isConnected) { _, value in
            if !value { expanded.wrappedValue = false }
        }
        .accessibilityIdentifier("profile-\(profile.id.uuidString)")
    }

    private func setExpanded(_ value: Bool) {
        guard value else { expanded.wrappedValue = false; return }
        guard !isExpanding.wrappedValue else { return }
        isExpanding.wrappedValue = true
        Task { @MainActor in
            defer { isExpanding.wrappedValue = false }
            await workspace.connectProfile(profile.id)
            guard isConnected else { return }
            expanded.wrappedValue = true
            await workspace.loadSchemas(profile.id)
        }
    }

    private var catalog: some View {
        Group {
            if profile.engine == .cassandra && isConnected {
                Button { Task { await workspace.showClusterNodes(profile.id) } } label: {
                    Label("Cluster Nodes", systemImage: "server.rack")
                }
                .buttonStyle(.plain).controlHover()
                .help("Show discovered Cassandra nodes and driver status")
                .accessibilityIdentifier("showClusterNodes-\(profile.id.uuidString)")
            }
            if !workspace.catalogSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if workspace.services[profile.id]?.connectionState != .connected {
                    Text("Connect to search this profile.").font(.caption).appSecondaryText()
                } else if let results = workspace.catalogSearchResults[profile.id] {
                    if results.isEmpty { Text("No matching objects").font(.caption).appSecondaryText() }
                    ForEach(results) { node in CatalogBranchView(node: node, workspace: workspace, showSchema: true) }
                } else { ProgressView().controlSize(.small) }
            } else if let roots = workspace.catalogRoots[profile.id] {
                ForEach(roots) { node in CatalogBranchView(node: node, workspace: workspace) }
            } else if workspace.catalogErrors[profile.id] == nil { ProgressView().controlSize(.small) }
            if let error = workspace.catalogErrors[profile.id] {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                Button("Retry") { Task { await workspace.loadSchemas(profile.id, refresh: true) } }.controlHover()
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            DatabaseEngineIcon(engine: profile.engine)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(profile.name).lineLimit(1)
                if profile.policy.environment != .unspecified {
                    Text(profile.policy.environment.label)
                        .font(.caption2.weight(.regular))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
            ZStack {
                if isConnected {
                    Circle().fill(.green).frame(width: 6, height: 6)
                } else if isExpanding.wrappedValue {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 16, height: 16)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { setExpanded(!expanded.wrappedValue) }
        .onTapGesture { Task { await workspace.library.selectConnection(profile.id) } }
        .catalogRowHover()
        .catalogRowContextMenu { contextMenu }
        .help(workspace.services[profile.id]?.connectionProgress ?? "\(profile.user)@\(profile.host):\(profile.port)/\(profile.database)")
    }

    private var contextMenu: NSMenu {
        let menu = NSMenu()
        if isConnected {
            menu.addCatalogAction("Disconnect") { Task { await workspace.disconnectProfile(profile.id) } }
        } else if workspace.services[profile.id]?.isConnecting == true {
            menu.addCatalogAction("Cancel Connection") { workspace.services[profile.id]?.cancelConnection() }
        } else {
            menu.addCatalogAction("Connect", enabled: workspace.services[profile.id]?.isConnecting != true) {
                Task { await workspace.connectProfile(profile.id) }
            }
        }
        menu.addCatalogAction(profile.engine == .mongodb ? "New JSON Script" : "New SQL Tab") { workspace.newDocument(profileID: profile.id) }
        if profile.engine == .cassandra {
            menu.addCatalogAction("Cluster Nodes…", enabled: isConnected) {
                Task { await workspace.showClusterNodes(profile.id) }
            }
        }
        menu.addCatalogAction("Refresh") { Task { await workspace.loadSchemas(profile.id, refresh: true) } }
        menu.addItem(.separator())
        menu.addCatalogAction("Export Connection…") { workspace.exportProfiles([profile]) }
        menu.addCatalogAction("Edit Connection…") { edit() }
        menu.addCatalogAction("Duplicate Connection…", enabled: !workspace.library.isSavingConnection,
            identifier: "duplicateConnection") { duplicate() }
        menu.addCatalogAction("Delete Connection…") { delete() }
        return menu
    }
}

struct CatalogBranchView: View {
    @ObservedObject var node: CatalogNode
    @ObservedObject var workspace: ApplicationWorkspace
    var showSchema = false

    var body: some View {
        Group {
            if node.isExpandable {
                DisclosureGroup(isExpanded: $node.isExpanded) {
                    if node.isLoading { ProgressView().controlSize(.mini) }
                    if let error = node.error {
                        Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        Button("Retry") { Task { await workspace.expand(node, refresh: true) } }.controlHover()
                    }
                    if let children = node.children {
                        ForEach(children) { child in
                            AnyView(CatalogBranchView(node: child, workspace: workspace))
                        }
                        if children.isEmpty { Text("No objects").font(.caption).appSecondaryText() }
                    }
                } label: { row }
                .onChange(of: node.isExpanded) { _, value in
                    if value { Task { await workspace.expand(node) } }
                }
            } else { row }
        }
    }

    private var contextMenu: NSMenu {
        let menu = NSMenu()
        if node.kind == .object {
            menu.addCatalogAction(node.isPostgresType ? "Inspect Type…" : "Structure and Definition…") {
                Task { await workspace.inspect(node) }
            }
            if ["table", "view"].contains(node.objectKind) {
                menu.addCatalogAction("Open Data") { Task { await workspace.openData(node) } }
                menu.addCatalogAction("Open in New Tab") { Task { await workspace.openData(node, inNewTab: true) } }
                menu.addCatalogAction(node.engine == .mongodb ? "Generate Find Request" : "Generate SELECT") {
                    Task { await workspace.openGeneratedSelect(node) }
                }
            }
            menu.addCatalogAction("Copy Name") { Task { await workspace.copyName(node) } }
            if node.isPostgresType {
                menu.addCatalogAction("Refresh") { Task { await workspace.inspect(node) } }
            }
        }
        if node.isExpandable {
            menu.addCatalogAction("Refresh") { Task { await workspace.expand(node, refresh: true) } }
        }
        return menu
    }

    private var row: some View {
        Group {
            if node.isPostgresType {
                Button { Task { await workspace.inspect(node) } } label: { rowLabel }
                    .buttonStyle(.plain)
                    .focusable()
                    .accessibilityLabel("Inspect \(node.objectKind == "enum" ? "enum" : "type") \(node.schema).\(node.name)")
                    .accessibilityIdentifier("catalogObject-\(node.id.uuidString)")
            } else {
                rowLabel
                    .onTapGesture(count: 2) {
                        if node.isExpandable { node.isExpanded.toggle() }
                        else if node.kind == .object { Task { await workspace.inspect(node) } }
                    }
            }
        }
        .catalogRowHover()
        .catalogRowContextMenu { contextMenu }
        .help(node.detail ?? node.name)
    }

    private var rowLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: node.symbol).appSecondaryText()
            Text(node.name).lineLimit(1)
            if showSchema { Text(node.schema).font(.caption2).appSecondaryText() }
        }
        .font(.callout)
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct CatalogInspectionView: View {
    let inspection: CatalogInspection
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(inspection.title).font(.title2)
                Spacer()
                Button("Done", action: close).controlHover().keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 20).padding(.top, 20)
            if inspection.isLoading { ProgressView().padding(.horizontal, 20) }
            if let error = inspection.error {
                Text(error).foregroundStyle(.orange).textSelection(.enabled).padding(.horizontal, 20)
            }
            if let result = inspection.structure {
                Text("Columns").font(.headline).padding(.horizontal, 20)
                ResultTableView(columns: result.columns ?? [], rows: result.rows ?? []).frame(minHeight: 180)
            }
            if let definition = inspection.definition {
                Text("Definition").font(.headline).padding(.horizontal, 20)
                ScrollView([.vertical, .horizontal]) {
                    Text(definition).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }.frame(minHeight: 180)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .tint(AppPalette.accent)
        .focusEffectDisabled()
    }
}
