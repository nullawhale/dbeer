import Foundation

enum WorkspaceSidebarPanel: String, CaseIterable, Identifiable, Sendable {
    case connections, files, library, investigations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connections: "Connections"
        case .files: "Files"
        case .library: "SQL Library"
        case .investigations: "Investigations"
        }
    }

    var systemImage: String {
        switch self {
        case .connections: "externaldrive.connected.to.line.below"
        case .files: "folder"
        case .library: "books.vertical"
        case .investigations: "doc.richtext"
        }
    }

    var command: AppCommandID {
        switch self {
        case .connections: .toggleConnectionsPanel
        case .files: .toggleFilesPanel
        case .library: .toggleSQLLibraryPanel
        case .investigations: .toggleInvestigationsPanel
        }
    }
}

@MainActor
extension ApplicationWorkspace {
    func toggleSidebar(_ panel: WorkspaceSidebarPanel) {
        guard canManageWorkspace else { return }
        sidebarPanel = sidebarPanel == panel ? nil : panel
    }

    func findInConnections() {
        guard canManageWorkspace else { return }
        sidebarPanel = .connections
        catalogSearchFocusRequested = true
    }
}
