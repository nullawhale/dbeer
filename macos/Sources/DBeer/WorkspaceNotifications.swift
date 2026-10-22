import Combine
import Foundation

struct WorkspaceNotification: Identifiable {
    struct Connection: Equatable {
        let id: UUID
        let name: String

        init(_ profile: SavedConnection) { id = profile.id; name = profile.name }
    }

    let id = UUID()
    let message: String
    let source: String
    let connection: Connection?
    let createdAt = Date()
    var isRead = false
}

/// Session-only messages never enter workspace persistence or application logs.
@MainActor
final class WorkspaceNotifications: ObservableObject {
    static let maximumCount = 100
    @Published private(set) var entries: [WorkspaceNotification] = []

    var unreadCount: Int { entries.count { !$0.isRead } }

    func post(_ message: String, source: String = "Workspace", connection: WorkspaceNotification.Connection? = nil) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.insert(WorkspaceNotification(message: message, source: source, connection: connection), at: 0)
        if entries.count > Self.maximumCount { entries.removeLast(entries.count - Self.maximumCount) }
    }

    func markAllRead() {
        guard unreadCount > 0 else { return }
        entries = entries.map { entry in
            var entry = entry
            entry.isRead = true
            return entry
        }
    }

    func dismiss(_ id: UUID) { entries.removeAll { $0.id == id } }

    func clear() { entries = [] }
}
