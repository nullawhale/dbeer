import Foundation
import Testing
@testable import DBeer

/// Pure schedule checks plus private temporary artifact storage; no app, workspace,
/// helper, credentials, database, real clock sleeps, presenters or windows.
struct ExplainCollectorTests {
    @Test func schedulerBoundsNoOverlapAndRetiredGenerations() throws {
        var config = ExplainCollectorConfiguration(); config.maximumCaptures = 2
        var schedule = ExplainCollectorSchedule()
        let beforeStart = schedule.reserve(at: 0, configuration: config)
        #expect(beforeStart == nil)
        schedule.start(at: 0)
        let firstReservation = schedule.reserve(at: 0, configuration: config)
        let first = try #require(firstReservation)
        let overlapping = schedule.reserve(at: 1, configuration: config)
        #expect(overlapping == nil)
        let firstCompleted = schedule.finish(first, at: 3, configuration: config)
        #expect(firstCompleted)
        let beforeInterval = schedule.reserve(at: 62, configuration: config)
        #expect(beforeInterval == nil)
        let secondReservation = schedule.reserve(at: 63, configuration: config)
        let second = try #require(secondReservation)
        let secondCompleted = schedule.finish(second, at: 64, configuration: config)
        #expect(secondCompleted)
        let stoppedAtLimit = schedule.startedAt == nil && schedule.reserve(at: 200, configuration: config) == nil
        #expect(stoppedAtLimit)
        schedule.start(at: 300)
        let staleReservation = schedule.reserve(at: 300, configuration: config)
        let stale = try #require(staleReservation)
        schedule.stop()
        schedule.start(at: 301)
        let staleCompleted = schedule.finish(stale, at: 302, configuration: config)
        #expect(!staleCompleted)
        config.maximumRuntimeSeconds = 30
        schedule.start(at: 0)
        let afterDeadline = schedule.reserve(at: 30, configuration: config)
        #expect(afterDeadline == nil)
        config.intervalSeconds = 0
        let invalidBoundsRefused = !config.valid && schedule.reserve(at: 0, configuration: config) == nil
        #expect(invalidBoundsRefused)
    }
    @Test func invalidatedLeaseCannotPublishAndStoragePrunesCountBytesAndAge() async throws {
        let root = TuningNativeFixture.root.appendingPathComponent("build/f7-native-test/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlanArtifactStore(rootURL: root)
        var configuration = ExplainCollectorConfiguration(); configuration.maximumCaptures = 2
        let retired = ExplainCollectorLease(); retired.invalidate()
        let original = try TuningNativeFixture.artifact()
        do { _ = try await store.saveCollected(original, configuration: configuration, now: .now, lease: retired); Issue.record("Retired callback stored evidence") } catch is CancellationError {} catch { throw error }
        #expect(try await store.list().isEmpty)
        let lease = ExplainCollectorLease()
        for index in 0..<3 {
            var artifact = original; artifact.id = UUID(); artifact.capturedAt = Date(timeIntervalSince1970: Double(1_000 + index))
            _ = try await store.saveCollected(artifact, configuration: configuration, now: Date(timeIntervalSince1970: 1_003), lease: lease)
        }
        #expect(try await store.list().count == 2)
        try await store.pruneCollected(configuration: configuration, now: Date(timeIntervalSince1970: 9_000_000), lease: lease)
        #expect(try await store.list().isEmpty)
        configuration.maximumStorageBytes = 1_048_576
        var oversized = original; oversized.result.raw = String(repeating: "x", count: 1_048_576)
        do { _ = try await store.saveCollected(oversized, configuration: configuration, now: .now, lease: lease); Issue.record("Over-budget capture published") } catch PlanArtifactError.quota {} catch { throw error }
        #expect(try await store.list().isEmpty)
    }
    @Test @MainActor func restoredControllerNeverStartsOrInvokesCapture() throws {
        let root = TuningNativeFixture.root.appendingPathComponent("build/f7-native-test/unused-" + UUID().uuidString)
        let controller = ExplainCollector(store: PlanArtifactStore(rootURL: root), now: { 0 }, sleep: { _ in throw CancellationError() })
        #expect(!controller.running && controller.captures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        controller.stop("Stopped explicitly")
        #expect(!controller.running)
    }
}

@MainActor
private final class CollectorCompletionGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<PlanArtifact, Never>?
    func capture() async -> PlanArtifact {
        await withCheckedContinuation { continuation in
            completion = continuation; started = true; startWaiter?.resume(); startWaiter = nil
        }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }
    func finish(_ artifact: PlanArtifact) { completion?.resume(returning: artifact); completion = nil }
}

extension ExplainCollectorTests {
    @Test @MainActor func lateCaptureAfterStopCannotPublishOrRestart() async throws {
        let root = TuningNativeFixture.root.appendingPathComponent("build/f7-native-test/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlanArtifactStore(rootURL: root)
        let gate = CollectorCompletionGate()
        let controller = ExplainCollector(store: store, now: { 0 }, sleep: { _ in throw CancellationError() })
        controller.start(configuration: .init(), current: { true }) { _ in await gate.capture() }
        await gate.waitUntilStarted()
        controller.stop("Stopped by source edit")
        gate.finish(try TuningNativeFixture.artifact())
        for _ in 0..<5 { await Task.yield() }
        #expect(!controller.running && controller.captures.isEmpty)
        #expect(try await store.list().isEmpty)
    }
}

@MainActor
private final class CollectorPhaseGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; entered = true; waiter?.resume(); waiter = nil
        }
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { waiter = $0 } } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class CollectorTestOwner {
    var activeQuery: String?
    var cancelled: [String] = []
    var grantUsed = false
    func cancel(_ queryID: String) { if activeQuery == queryID { cancelled.append(queryID) } }
}

extension ExplainCollectorTests {
    @Test @MainActor func queuedStopOwnsOnlyItsCaptureAndExplicitStopCancelsThatCapture() async throws {
        let owner = CollectorTestOwner(), independent = CollectorTestOwner()
        owner.activeQuery = "capture"; independent.activeQuery = "independent"
        let completed = ExplainCollectorCaptureLease()
        #expect(completed.bind(queryID: "capture") { owner.cancel($0) })
        let queued = try #require(completed.stop())
        completed.finishQuery("capture")
        owner.activeQuery = "foreground"
        await queued()
        #expect(owner.cancelled.isEmpty && owner.activeQuery == "foreground")
        let running = ExplainCollectorCaptureLease()
        owner.activeQuery = "next-capture"
        #expect(running.bind(queryID: "next-capture") { owner.cancel($0) })
        let explicit = try #require(running.stop()); await explicit()
        #expect(owner.cancelled == ["next-capture"])
        #expect(independent.activeQuery == "independent" && independent.cancelled.isEmpty)
        #expect(!completed.bind(queryID: "late-capture") { owner.cancel($0) })
    }

    @Test @MainActor func stoppedAssessmentCannotExecuteLateGrantOrCancelNewForeground() async throws {
        let root = TuningNativeFixture.root.appendingPathComponent("build/f7-native-test/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CollectorPhaseGate(), owner = CollectorTestOwner(), independent = CollectorTestOwner()
        independent.activeQuery = "independent"
        let store = PlanArtifactStore(rootURL: root)
        let controller = ExplainCollector(store: store, now: { 0 }, sleep: { _ in throw CancellationError() })
        controller.start(configuration: .init(), current: { true }) { capture in
            await gate.hold() // A pending fresh assessment owns no execution-query cancellation.
            guard capture.isActive else { throw CancellationError() }
            owner.grantUsed = true
            return try TuningNativeFixture.artifact()
        }
        await gate.waitUntilEntered()
        controller.stop("Stopped while assessment was pending")
        owner.activeQuery = "new-foreground"
        gate.release()
        for _ in 0..<5 { await Task.yield() }
        #expect(!owner.grantUsed && owner.cancelled.isEmpty && owner.activeQuery == "new-foreground")
        #expect(independent.cancelled.isEmpty && independent.activeQuery == "independent")
        let retained = try await store.list()
        #expect(!controller.running && retained.isEmpty)
    }

    @Test @MainActor func stoppedStoragePhaseCannotCancelNewForegroundOrPublishLateEvidence() async throws {
        let root = TuningNativeFixture.root.appendingPathComponent("build/f7-native-test/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CollectorPhaseGate(), owner = CollectorTestOwner(), independent = CollectorTestOwner()
        independent.activeQuery = "independent"
        let store = PlanArtifactStore(rootURL: root)
        let controller = ExplainCollector(store: store, now: { 0 }, sleep: { _ in throw CancellationError() },
            publishCapture: { artifact, configuration, lease in
                await gate.hold()
                _ = try await store.saveCollected(artifact, configuration: configuration, now: .now, lease: lease)
            })
        controller.start(configuration: .init(), current: { true }) { capture in
            owner.activeQuery = "capture"
            #expect(capture.bind(queryID: "capture") { owner.cancel($0) })
            capture.finishQuery("capture"); owner.activeQuery = nil
            return try TuningNativeFixture.artifact()
        }
        await gate.waitUntilEntered()
        controller.stop("Stopped while storing completed evidence")
        owner.activeQuery = "new-foreground"
        gate.release()
        for _ in 0..<5 { await Task.yield() }
        #expect(owner.cancelled.isEmpty && owner.activeQuery == "new-foreground")
        #expect(independent.cancelled.isEmpty && independent.activeQuery == "independent")
        let retained = try await store.list()
        #expect(!controller.running && retained.isEmpty)
    }
}

extension ExplainCollectorTests {
    @Test func dispatchAdmissionLinearizesBeforeWriteWithoutHoldingItsLock() throws {
        let queued = ExplainCollectorAdmission()
        try queued.whileWaiting {} // Registered/enqueued, but the writer has not admitted it yet.
        queued.cancel()
        #expect(!queued.beginDispatch())
        #expect(throws: CancellationError.self) { try queued.whileWaiting {} }
        let dispatched = ExplainCollectorAdmission()
        #expect(dispatched.beginDispatch())
        // Stop returns after dispatch admission; the normal exact pending-query
        // cancellation path now owns the attempted write and its outcome.
        dispatched.cancel()
        #expect(!dispatched.beginDispatch())
    }
}
