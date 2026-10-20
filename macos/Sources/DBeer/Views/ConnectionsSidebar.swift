import AppKit
import SwiftUI

struct ConnectionsSidebar: View {
    @ObservedObject var model: WorkspaceModel
    let onCreate: () -> Void
    let onEdit: (SavedConnection) -> Void

    private var expandedState = SwiftUI.State(initialValue: true)
    private var deletionState = SwiftUI.State<SavedConnection?>(initialValue: nil)
    private var amber: Color { AppPalette.accent }

    init(model: WorkspaceModel, onCreate: @escaping () -> Void, onEdit: @escaping (SavedConnection) -> Void) {
        self.model = model
        self.onCreate = onCreate
        self.onEdit = onEdit
    }

    private var selection: Binding<UUID?> {
        Binding(get: { model.selectedConnectionId }, set: { id in
            if let id { Task { await model.selectConnection(id) } }
        })
    }

    private var deletionIsPresented: Binding<Bool> {
        Binding(get: { deletionState.wrappedValue != nil }, set: { visible in
            if !visible { deletionState.wrappedValue = nil }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connections").font(.headline)
                Spacer(minLength: 8)
                ControlIconButton(systemName: "plus", action: onCreate)
                .connectionButtonFocus()
                .disabled(model.isSavingConnection)
                .help("New Connection (⌘N)")
                .accessibilityLabel("New Connection")
                .accessibilityIdentifier("newConnection")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            Divider()

            List(selection: selection) {
                DisclosureGroup(isExpanded: expandedState.projectedValue) {
                    ForEach(model.savedConnections) { connection in
                        connectionRow(connection)
                            .tag(connection.id)
                            .listRowBackground(model.selectedConnectionId == connection.id
                                ? AppPalette.accent.opacity(0.12) : Color.clear)
                            .catalogRowContextMenu { contextMenu(for: connection) }
                    }
                } label: {
                    Label("PostgreSQL", systemImage: "externaldrive.connected.to.line.below")
                        .font(.callout.weight(.medium))
                        .appSecondaryText()
                        .catalogRowHover()
                }
                .accessibilityIdentifier("postgresConnectionsGroup")
            }
            .listStyle(.sidebar)
            .catalogContextMenu()
            .scrollContentBackground(.hidden)
            .overlay {
                if model.savedConnections.isEmpty {
                    VStack(spacing: 10) {
                        Text("No saved connections")
                            .font(.callout).appSecondaryText()
                        Text("Use + above to add a connection.")
                            .font(.caption).appSecondaryText()
                    }
                    .padding(20)
                }
            }

            if let error = model.connectionsError, !model.isConnectionEditorPresented {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { model.dismissConnectionsError() } label: {
                        Image(systemName: "xmark")
                            .frame(width: 18, height: 18)
                    }.controlHover()
                    .buttonStyle(.plain)
                    .connectionButtonFocus()
                    .accessibilityLabel("Dismiss connection error")
                }
                .font(.caption)
                .padding(14)
                .accessibilityIdentifier("connectionsError")
            }
        }
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 280)
        .frame(maxHeight: .infinity)
        .background(AppPalette.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectionsSidebar")
        .alert("Delete Connection?", isPresented: deletionIsPresented, presenting: deletionState.wrappedValue) { connection in
            Button("Cancel", role: .cancel) { deletionState.wrappedValue = nil }
            Button("Delete", role: .destructive) {
                deletionState.wrappedValue = nil
                Task { _ = await model.deleteConnection(connection.id) }
            }
            .accessibilityIdentifier("deleteConnection")
        } message: { connection in
            Text("Delete “\(connection.name)” and its saved password? This cannot be undone.")
        }
    }

    private func connectionRow(_ connection: SavedConnection) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "server.rack")
                .foregroundStyle(model.activeConnectionId == connection.id ? amber : .secondary)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(connection.host):\(String(connection.port))/\(connection.database)")
                    .font(.caption)
                    .appSecondaryText()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if model.activeConnectionId == connection.id {
                Circle().fill(.green).frame(width: 6, height: 6)
                    .accessibilityLabel("Connected")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .catalogRowHover()
        .onTapGesture(count: 2) {
            guard model.canConnect else { return }
            Task { await model.connectSavedConnection(connection.id) }
        }
        .help("\(connection.name) — \(connection.user)@\(connection.host):\(connection.port)/\(connection.database). Double-click to connect.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectionRow-\(connection.id.uuidString)")
    }

    private func connect(_ connection: SavedConnection) {
        guard model.canConnect, !model.isSavingConnection else { return }
        Task { await model.connectSavedConnection(connection.id) }
    }

    private func contextMenu(for connection: SavedConnection) -> NSMenu {
        let menu = NSMenu()
        if model.activeConnectionId == connection.id {
            menu.addCatalogAction("Disconnect", enabled: model.canDisconnect, identifier: "disconnect") {
                Task { await model.disconnect() }
            }
        } else {
            menu.addCatalogAction("Connect", enabled: model.canConnect && !model.isSavingConnection,
                                  identifier: "connectSavedConnection") { connect(connection) }
        }
        menu.addItem(.separator())
        menu.addCatalogAction("Edit Connection…", enabled: !model.isSavingConnection, identifier: "editConnection") {
            onEdit(connection)
        }
        menu.addCatalogAction("Delete Connection…", enabled: canDelete(connection), identifier: "deleteConnectionRequest") {
            deletionState.wrappedValue = connection
        }
        return menu
    }

    private func canDelete(_ connection: SavedConnection) -> Bool {
        model.activeConnectionId != connection.id && !model.isSavingConnection &&
            model.connectionState != .connecting && model.connectionState != .disconnecting
    }
}
