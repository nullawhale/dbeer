import Combine
import Foundation

/// Only bounds are restored. SQL, values, owners, grants and running state are process-local.
struct ExplainCollectorConfiguration: Codable, Equatable, Sendable {
    var intervalSeconds = 60
    var maximumCaptures = 20
    var maximumRuntimeSeconds = 1_800
    var maximumStorageBytes = 16 * 1_024 * 1_024
    var retentionDays = 7
    var valid: Bool {
        (30...3_600).contains(intervalSeconds) && (1...100).contains(maximumCaptures) &&
            (30...3_600).contains(maximumRuntimeSeconds) && (1_048_576...33_554_432).contains(maximumStorageBytes) && (1...30).contains(retentionDays)
    }
    init() {}
    private enum CodingKeys: String, CodingKey { case intervalSeconds, maximumCaptures, maximumRuntimeSeconds, maximumStorageBytes, retentionDays }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["intervalSeconds", "maximumCaptures", "maximumRuntimeSeconds", "maximumStorageBytes", "retentionDays"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        intervalSeconds = try fields.decode(Int.self, forKey: .intervalSeconds)
        maximumCaptures = try fields.decode(Int.self, forKey: .maximumCaptures)
        maximumRuntimeSeconds = try fields.decode(Int.self, forKey: .maximumRuntimeSeconds)
        maximumStorageBytes = try fields.decode(Int.self, forKey: .maximumStorageBytes)
        retentionDays = try fields.decode(Int.self, forKey: .retentionDays)
        guard valid else { throw PlanArtifactError.invalid }
    }
}

/// A deterministic scheduler, with at most one in-flight observation.
struct ExplainCollectorSchedule {
    private(set) var startedAt: TimeInterval?
    private(set) var nextAt: TimeInterval?
    private(set) var captures = 0
    private(set) var inFlight = false
    private(set) var generation = UUID()
    mutating func start(at time: TimeInterval) { stop(); startedAt = time; nextAt = time; captures = 0 }
    mutating func stop() { generation = UUID(); startedAt = nil; nextAt = nil; inFlight = false }
    mutating func reserve(at time: TimeInterval, configuration: ExplainCollectorConfiguration) -> UUID? {
        guard configuration.valid, let startedAt, let nextAt, !inFlight, time >= nextAt,
              time >= startedAt, time - startedAt < Double(configuration.maximumRuntimeSeconds), captures < configuration.maximumCaptures else { return nil }
        inFlight = true
        return generation
    }
    mutating func finish(_ token: UUID, at time: TimeInterval, configuration: ExplainCollectorConfiguration) -> Bool {
        guard token == generation, let startedAt, inFlight else { return false }
        inFlight = false; captures += 1
        if captures >= configuration.maximumCaptures || time - startedAt >= Double(configuration.maximumRuntimeSeconds) { stop() }
        else { nextAt = time + Double(configuration.intervalSeconds) }
        return true
    }
}

/// Invalidation and the final synchronous file publication have a single ordering.
final class ExplainCollectorLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func invalidate() { lock.lock(); active = false; lock.unlock() }
    func whileActive<T>(_ action: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw CancellationError() }
        return try action()
    }
}

/// Dispatch linearizes on the writer queue. Stop may revoke a queued frame,
/// but never holds this lock during a pipe write or suspension.
final class ExplainCollectorAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var dispatched = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func whileWaiting<T>(_ action: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !dispatched else { throw CancellationError() }
        return try action()
    }
    func beginDispatch() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !dispatched else { return false }
        dispatched = true
        return true
    }
}

/// A capture may own cancellation only while its exact helper query is pending.
@MainActor
final class ExplainCollectorCaptureLease {
    let admission = ExplainCollectorAdmission()
    private var cancelled = false
    private var bound = false
    private var query: (id: String, cancel: @MainActor (String) async -> Void)?
    var isActive: Bool { !cancelled }
    func bind(queryID: String, cancel: @escaping @MainActor (String) async -> Void) -> Bool {
        guard !cancelled, !bound else { return false }
        bound = true
        query = (queryID, cancel)
        return true
    }
    func finishQuery(_ queryID: String) { if query?.id == queryID { query = nil } }
    func stop() -> (@MainActor () async -> Void)? {
        guard !cancelled else { return nil }
        cancelled = true
        admission.cancel()
        guard let owned = query else { return nil }
        return { [self] in
            guard query?.id == owned.id else { return }
            await owned.cancel(owned.id)
        }
    }
}

@MainActor
final class ExplainCollector: ObservableObject {
    typealias Capture = @MainActor (ExplainCollectorCaptureLease) async throws -> PlanArtifact
    @Published private(set) var status = "Stopped — explicit Start is required"
    @Published private(set) var running = false
    @Published private(set) var captures: [PlanArtifactSummary] = []
    let store: PlanArtifactStore
    private var schedule = ExplainCollectorSchedule()
    private var task: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var activeCapture: ExplainCollectorCaptureLease?
    private var lease: ExplainCollectorLease?
    private let publishCapture: @MainActor (PlanArtifact, ExplainCollectorConfiguration, ExplainCollectorLease) async throws -> Void
    private let now: @MainActor () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    var observations: [AnyCancellable] = []

    init(store: PlanArtifactStore, now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         publishCapture: (@MainActor (PlanArtifact, ExplainCollectorConfiguration, ExplainCollectorLease) async throws -> Void)? = nil) {
        self.store = store; self.now = now; self.sleep = sleep
        self.publishCapture = publishCapture ?? { artifact, configuration, lease in
            _ = try await store.saveCollected(artifact, configuration: configuration, now: .now, lease: lease)
        }
    }
    func refreshEvidence() async {
        guard !running else { return }
        do { captures = try await store.list() }
        catch { status = "Stopped — stored capture inventory is unavailable" }
    }
    func stop(_ reason: String = "Stopped") {
        let cancel = activeCapture?.stop()
        activeCapture = nil
        lease?.invalidate(); lease = nil; task?.cancel(); task = nil; deadlineTask?.cancel(); deadlineTask = nil; schedule.stop()
        if let cancel { Task { await cancel() } }
        running = false; status = reason; observations = []
    }
    func start(configuration: ExplainCollectorConfiguration, current: @escaping @MainActor () -> Bool, capture: @escaping Capture) {
        stop()
        guard configuration.valid, current() else { status = "Stopped — current source and connected owner are required"; return }
        let lease = ExplainCollectorLease(); self.lease = lease
        schedule.start(at: now()); running = true; status = "Collecting estimated plans"
        deadlineTask = Task { [weak self] in
            do { try await self?.sleep(Double(configuration.maximumRuntimeSeconds)) } catch { return }
            guard let self, self.lease === lease, self.running else { return }
            self.stop("Stopped — runtime bound reached")
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.store.pruneCollected(configuration: configuration, now: .now, lease: lease)
                while !Task.isCancelled, self.running {
                    guard current() else { self.stop("Stopped — source, profile, policy or owner changed"); return }
                    guard let token = self.schedule.reserve(at: self.now(), configuration: configuration) else { self.stop("Stopped — runtime or capture bound reached"); return }
                    let captureLease = ExplainCollectorCaptureLease()
                    self.activeCapture = captureLease
                    let artifact = try await capture(captureLease)
                    if self.activeCapture === captureLease { self.activeCapture = nil }
                    guard !Task.isCancelled, current(), token == self.schedule.generation, self.running else { return }
                    guard let startedAt = self.schedule.startedAt, self.now() - startedAt < Double(configuration.maximumRuntimeSeconds) else { self.stop("Stopped — runtime bound reached"); return }
                    try await self.publishCapture(artifact, configuration, lease)
                    guard !Task.isCancelled, current(), token == self.schedule.generation, self.running else { return }
                    let retained = try await self.store.list()
                    guard !Task.isCancelled, current(), token == self.schedule.generation, self.running else { return }
                    self.captures = retained
                    _ = self.schedule.finish(token, at: self.now(), configuration: configuration)
                    if self.schedule.startedAt == nil { self.stop("Stopped — capture or runtime bound reached"); return }
                    self.status = "Collected \(self.schedule.captures) · next in \(configuration.intervalSeconds)s"
                    try await self.sleep(Double(configuration.intervalSeconds))
                }
            } catch {
                guard self.lease === lease else { return }
                self.stop(error is CancellationError ? "Stopped" : "Stopped — " + error.localizedDescription)
            }
        }
    }
}
