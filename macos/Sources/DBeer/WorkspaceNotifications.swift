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
    static let maximumToastCount = 5
    static let toastDuration: Duration = .seconds(5)
    @Published private(set) var entries: [WorkspaceNotification] = []
    @Published private(set) var activeToasts: [WorkspaceNotification] = []

    private struct ToastTimer: Sendable {
        var remaining: Duration
        var deadline: ContinuousClock.Instant?
        var task: Task<Void, Never>?
        // Layout transitions can briefly display multiple views of one banner.
        var hoverSources: Set<UUID> = []
    }

    private let toastDuration: Duration
    private var toastTimers: [UUID: ToastTimer] = [:]

    init(toastDuration: Duration = WorkspaceNotifications.toastDuration) {
        self.toastDuration = toastDuration
    }

    deinit { toastTimers.values.forEach { $0.task?.cancel() } }

    var unreadCount: Int { entries.count { !$0.isRead } }

    func toastRemainingFraction(_ id: UUID, at now: ContinuousClock.Instant = .now) -> Double {
        guard let timer = toastTimers[id], toastDuration > .zero else { return 0 }
        let remaining = timer.deadline.map { now.duration(to: $0) } ?? timer.remaining
        return min(1, max(0, remaining / toastDuration))
    }

    func isToastPaused(_ id: UUID) -> Bool {
        toastTimers[id]?.deadline == nil
    }

    func post(_ message: String, source: String = "Workspace", connection: WorkspaceNotification.Connection? = nil) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let entry = WorkspaceNotification(message: message, source: source, connection: connection)
        entries.insert(entry, at: 0)
        if entries.count > Self.maximumCount { entries.removeLast(entries.count - Self.maximumCount) }
        if activeToasts.count == Self.maximumToastCount, let oldest = activeToasts.last {
            dismissToast(oldest.id)
        }
        activeToasts.insert(entry, at: 0)
        toastTimers[entry.id] = ToastTimer(remaining: toastDuration)
        startToastTimer(entry.id)
    }

    func pauseToast(_ id: UUID, source: UUID) {
        guard var timer = toastTimers[id], timer.hoverSources.insert(source).inserted else { return }
        if let deadline = timer.deadline {
            objectWillChange.send()
            timer.remaining = max(.zero, ContinuousClock.now.duration(to: deadline))
            timer.deadline = nil
            timer.task?.cancel()
            timer.task = nil
        }
        toastTimers[id] = timer
    }

    func resumeToast(_ id: UUID, source: UUID) {
        guard var timer = toastTimers[id], timer.hoverSources.remove(source) != nil else { return }
        if timer.hoverSources.isEmpty { objectWillChange.send() }
        toastTimers[id] = timer
        if timer.hoverSources.isEmpty { startToastTimer(id) }
    }

    private func startToastTimer(_ id: UUID) {
        guard var timer = toastTimers[id], timer.deadline == nil, timer.hoverSources.isEmpty else { return }
        let deadline = ContinuousClock.now.advanced(by: timer.remaining)
        timer.deadline = deadline
        timer.task = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard !Task.isCancelled, let self, self.toastTimers[id]?.deadline == deadline else { return }
            self.dismissToast(id)
        }
        toastTimers[id] = timer
    }

    func markAllRead() {
        guard unreadCount > 0 else { return }
        entries = entries.map { entry in
            var entry = entry
            entry.isRead = true
            return entry
        }
    }

    func dismissToast(_ id: UUID) {
        guard activeToasts.contains(where: { $0.id == id }) else { return }
        toastTimers.removeValue(forKey: id)?.task?.cancel()
        activeToasts.removeAll { $0.id == id }
    }

    func dismiss(_ id: UUID) {
        entries.removeAll { $0.id == id }
        dismissToast(id)
    }

    func clear() {
        entries = []
        toastTimers.values.forEach { $0.task?.cancel() }
        toastTimers.removeAll()
        activeToasts = []
    }
}
