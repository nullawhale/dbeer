import Combine
import Foundation

/// Saved profile equality normalizes Unicode; a live server binding must not.
struct SessionMonitorProfileBinding: Sendable {
    private let binding: ExplainProfileBinding

    init?(_ profile: SavedConnection) {
        guard let binding = ExplainProfileBinding(profile) else { return nil }
        self.binding = binding
    }
    func matches(_ profile: SavedConnection?) -> Bool { binding.matches(profile) }
    func matches(in profiles: [SavedConnection]) -> Bool {
        binding.matches(profiles.first { $0.id == binding.profile.id })
    }
}

/// Only the latest explicit open may present a window after async cleanup.
struct SessionMonitorPresentationIntent {
    private var generation: UInt64 = 0
    mutating func requestOpen() -> UInt64 { generation &+= 1; return generation }
    mutating func cancelPendingOpen() { generation &+= 1 }
    func isCurrent(_ intent: UInt64) -> Bool { generation == intent }
    static func mayClose(expectedID: UUID?, activeID: UUID?) -> Bool {
        activeID != nil && (expectedID == nil || expectedID == activeID)
    }
}

@MainActor
final class SessionMonitorClientLease {
    var client: BackendClient?
}

enum SessionMonitorSort: String, CaseIterable, Identifiable, Sendable {
    case sessionID, queryDuration, transactionDuration, waiting, blocking
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sessionID: "Session ID"
        case .queryDuration: "Query duration"
        case .transactionDuration: "Transaction duration"
        case .waiting: "Waiting on"
        case .blocking: "Blocking"
        }
    }
}

/// Observations are ephemeral and belong to a dedicated monitor-only session.
@MainActor
final class SessionMonitorModel: ObservableObject, Identifiable {
    let id = UUID()
    let profile: SavedConnection
    let isOffline: Bool
    @Published private(set) var snapshot: SessionMonitorSnapshot? { didSet { indexRelationships() } }
    @Published private(set) var isBusy = false
    @Published private(set) var isClosing = false
    @Published private(set) var isStale = false
    @Published private(set) var notice: String?
    @Published var selectedSessionID: String?
    @Published var filter = "" { didSet { reconcileSelection() } }
    @Published var waitingOnly = false { didSet { reconcileSelection() } }
    @Published var sort: SessionMonitorSort = .sessionID { didSet { if oldValue != sort { sortDescending = sort != .sessionID } } }
    @Published var sortDescending = false
    @Published var autoRefresh = false { didSet { updateAutoRefresh() } }

    private let connect: @MainActor () async throws -> String
    private let send: @MainActor (BackendCommand) async throws -> BackendMessage
    private let bindingIsCurrent: @MainActor () -> Bool
    private let cancelPreparation: @MainActor () -> Void
    private var sessionID: String?
    private var queryID: String?
    private var generation: UInt64 = 0
    private var operation: Task<Void, Never>?
    private var closingTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var closed = false
    private var waitingOn: [String: Set<String>] = [:]
    private var blocking: [String: Set<String>] = [:]

    init(profile: SavedConnection, connect: @escaping @MainActor () async throws -> String,
         send: @escaping @MainActor (BackendCommand) async throws -> BackendMessage,
         bindingIsCurrent: @escaping @MainActor () -> Bool,
         cancelPreparation: @escaping @MainActor () -> Void = {}, savedSnapshot: SessionMonitorSnapshot? = nil) {
        self.profile = profile
        isOffline = savedSnapshot != nil
        self.connect = connect
        self.send = send
        self.bindingIsCurrent = bindingIsCurrent
        self.cancelPreparation = cancelPreparation
        snapshot = savedSnapshot
        if savedSnapshot != nil { indexRelationships() }
    }

    static func offline(_ value: SavedEvidenceArtifact) throws -> SessionMonitorModel {
        guard value.valid, let snapshot = value.diagnostic else { throw PlanArtifactError.invalid }
        let profile = SavedConnection(name: value.profileName ?? "Saved diagnostic", settings: .init(host: "offline.invalid", port: 1,
            database: "", user: "", password: "", sslMode: "disable", engine: value.engine,
            policy: .init(environment: value.environment, readOnly: true)))
        let model = SessionMonitorModel(profile: profile,
            connect: { throw ExecutionPolicyError(message: "Saved diagnostics are offline.") },
            send: { _ in throw ExecutionPolicyError(message: "Saved diagnostics are offline.") },
            bindingIsCurrent: { false }, savedSnapshot: snapshot)
        model.isStale = value.sourceWasStale
        model.notice = "Saved offline observation. Session identifiers are historical labels; no live status is requested."
        return model
    }

    var selectedSession: MonitoredSession? { snapshot?.sessions.first { $0.id == selectedSessionID } }
    var visibleSessions: [MonitoredSession] {
        return (snapshot?.sessions ?? []).filter { session in
            (!waitingOnly || isWaiting(session)) &&
            (filter.isEmpty || [session.id, session.user, session.database, session.client, session.application,
                                session.state, session.query].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(filter) })
        }.sorted(by: ordered)
    }
    var visibleWaits: [MonitorWait] {
        guard let snapshot else { return [] }
        let ids = Set(visibleSessions.map(\.id))
        return snapshot.waits.filter { wait in
            if let selectedSessionID { return wait.waitingId == selectedSessionID || wait.blockingId == selectedSessionID }
            return filter.isEmpty && !waitingOnly || ids.contains(wait.waitingId) || ids.contains(wait.blockingId)
        }.sorted { left, right in
            if left.waitingId != right.waitingId { return Self.numberLess(left.waitingId, right.waitingId) }
            if left.blockingId != right.blockingId { return Self.numberLess(left.blockingId, right.blockingId) }
            return left.id.utf8.lexicographicallyPrecedes(right.id.utf8)
        }
    }
    var visibleWaitingCount: Int { visibleSessions.filter(isWaiting).count }
    var visibleBlockingCount: Int { visibleSessions.filter { blocksCount($0.id) > 0 }.count }
    func waitsOnCount(_ id: String) -> Int { waitingOn[id]?.count ?? 0 }
    func blocksCount(_ id: String) -> Int { blocking[id]?.count ?? 0 }
    func containsSession(_ id: String) -> Bool { snapshot?.sessions.contains { $0.id == id } == true }
    func isWaiting(_ session: MonitoredSession) -> Bool {
        if waitsOnCount(session.id) > 0 || session.waitType.map({ ["metadata", "Lock"].contains($0) }) == true { return true }
        let state = session.state?.lowercased() ?? ""
        return state.hasPrefix("waiting for ") && state.contains("metadata lock")
    }

    private func indexRelationships() {
        waitingOn = [:]; blocking = [:]
        for wait in snapshot?.waits ?? [] {
            waitingOn[wait.waitingId, default: []].insert(wait.blockingId)
            blocking[wait.blockingId, default: []].insert(wait.waitingId)
        }
    }

    /// Navigating a relationship reveals its endpoint even when a filter hid it.
    func selectSession(_ id: String) {
        guard containsSession(id) else { return }
        filter = ""
        waitingOnly = false
        selectedSessionID = id
    }
    private func reconcileSelection() {
        if let selectedSessionID, !visibleSessions.contains(where: { $0.id == selectedSessionID }) { self.selectedSessionID = nil }
    }
    /// Canonical decimal strings can exceed UInt64. Compare their digits exactly.
    private static func numberLess(_ left: String, _ right: String) -> Bool {
        left.utf8.count == right.utf8.count ? left.utf8.lexicographicallyPrecedes(right.utf8) : left.utf8.count < right.utf8.count
    }
    private func ordered(_ left: MonitoredSession, _ right: MonitoredSession) -> Bool {
        let lhs: String?, rhs: String?
        switch sort {
        case .sessionID: lhs = left.id; rhs = right.id
        case .queryDuration: lhs = left.queryAgeMs; rhs = right.queryAgeMs
        case .transactionDuration: lhs = left.transactionAgeMs; rhs = right.transactionAgeMs
        case .waiting: lhs = String(waitsOnCount(left.id)); rhs = String(waitsOnCount(right.id))
        case .blocking: lhs = String(blocksCount(left.id)); rhs = String(blocksCount(right.id))
        }
        // Unavailable measurements stay last in either direction.
        if lhs == nil || rhs == nil {
            if lhs == nil && rhs != nil { return false }
            if lhs != nil && rhs == nil { return true }
        } else if lhs != rhs, let lhs, let rhs {
            return sortDescending ? Self.numberLess(rhs, lhs) : Self.numberLess(lhs, rhs)
        }
        return Self.numberLess(left.id, right.id)
    }
    func sessionLabel(_ id: String) -> String {
        guard let session = snapshot?.sessions.first(where: { $0.id == id }) else {
            return id == "0" ? "Prepared transaction (0)" : "Session \(id) (outside visible sessions)"
        }
        return "\(session.id) · \(session.user ?? "Unavailable user")"
    }

    func refresh() async {
        guard !isOffline else { return }
        guard !closed, !isBusy, !isClosing else { return }
        guard bindingIsCurrent() else { invalidateBinding(); return }
        generation &+= 1
        let token = generation
        isBusy = true
        notice = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.collect(token: token)
        }
        operation = task
        await task.value
        if generation == token { operation = nil }
    }

    private func collect(token: UInt64) async {
        defer {
            queryID = nil; isBusy = false
            if !closed, !bindingIsCurrent() { invalidateBinding() }
        }
        do {
            if sessionID == nil {
                let opened = try await connect()
                guard current(token) else {
                    _ = try? await send(.disconnect(sessionId: opened))
                    return
                }
                sessionID = opened
            }
            guard current(token), let sessionID else { return }
            let query = UUID().uuidString
            queryID = query
            let reply = try await send(.monitorSnapshot(sessionId: sessionID, queryId: query))
            guard current(token) else { return }
            guard reply.type == "monitor.result", reply.sessionId == sessionID, reply.queryId == query,
                  reply.connected == true, reply.transactionStatus == .idle,
                  let observation = reply.monitor, observation.valid, observation.engine == profile.engine else {
                throw BackendTransportError(.invalidMessage)
            }
            snapshot = observation
            isStale = false
            notice = nil
            reconcileSelection()
        } catch {
            // A late cancelled read may still report a lost connection. Drop
            // that identity before the stale-response guard so one Refresh can
            // reconnect, without replaying the failed collection.
            if let remote = error as? BackendRemoteError, remote.reply.connected == false { sessionID = nil }
            if error is BackendTransportError {
                let failedSession = sessionID
                sessionID = nil
                if let failedSession { _ = try? await send(.disconnect(sessionId: failedSession)) }
            }
            guard generation == token, !closed else { return }
            isStale = snapshot != nil
            if !bindingIsCurrent() { invalidateBinding(); return }
            notice = error is CancellationError ? "Refresh stopped. The previous observation is stale." :
                "Refresh failed. \(error.localizedDescription)\(snapshot == nil ? "" : " The previous observation is stale.")"
            autoRefresh = false
        }
    }

    private func current(_ token: UInt64) -> Bool {
        generation == token && !closed && !Task.isCancelled && bindingIsCurrent()
    }

    func stop() async {
        guard !closed else { return }
        autoRefresh = false
        generation &+= 1
        operation?.cancel()
        cancelPreparation()
        isStale = snapshot != nil
        notice = snapshot == nil ? "Refresh stopped." : "Refresh stopped. The previous observation is stale."
        if let sessionID, let queryID { _ = try? await send(.cancel(sessionId: sessionID, queryId: queryID)) }
    }

    func invalidateBinding() {
        autoRefresh = false
        generation &+= 1
        snapshot = nil
        selectedSessionID = nil
        isStale = false
        notice = "The saved connection changed. Close this monitor and open it again."
    }

    func helperDidFail() {
        guard !closed else { return }
        autoRefresh = false
        generation &+= 1
        operation?.cancel()
        cancelPreparation()
        sessionID = nil
        isStale = snapshot != nil
        notice = "The helper connection ended. Refresh explicitly to reconnect.\(snapshot == nil ? "" : " The previous observation is stale.")"
    }

    func close() async {
        if let closingTask { await closingTask.value; return }
        closed = true
        isClosing = true
        autoRefresh = false
        generation &+= 1
        let task = Task { @MainActor in await self.finishClosing() }
        closingTask = task
        await task.value
    }

    private func finishClosing() async {
        operation?.cancel()
        cancelPreparation()
        if let sessionID, let queryID { _ = try? await send(.cancel(sessionId: sessionID, queryId: queryID)) }
        await operation?.value
        operation = nil
        if let sessionID { _ = try? await send(.disconnect(sessionId: sessionID)) }
        sessionID = nil
        snapshot = nil
        selectedSessionID = nil
        isBusy = false
    }

    private func updateAutoRefresh() {
        guard !isOffline else { return }
        timer?.cancel(); timer = nil
        guard autoRefresh, !closed else { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, !Task.isCancelled, self.autoRefresh, !self.closed else { return }
                await self.refresh()
            }
        }
    }
}
