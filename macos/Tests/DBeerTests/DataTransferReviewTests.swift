import Foundation
import Testing
@testable import DBeer

/// Headless review regressions. No database, window or external utility runs.
@MainActor
struct DataTransferReviewTests {
    private func profile() -> SavedConnection {
        SavedConnection(name: "Review fixture", settings: .init(host: "fixture.invalid", port: 5432,
            database: "fixture", user: "reader", password: "", sslMode: "disable"))
    }
    private func ready(_ backend: TransferReviewBackend,
                       authorize: @escaping @MainActor (SavedConnection, DataTransferReply) async -> Bool = { _, _ in true },
                       current: @escaping @MainActor (SavedConnection) -> Bool = { _ in true }) async -> DataTransferModel {
        let profile = profile()
        let model = DataTransferModel(profiles: [profile], resolve: { profile, _ in profile.settings(password: "") },
            current: current, authorize: authorize, factory: { backend })
        model.targetID = profile.id; model.targetTable = "review_destination"
        await model.loadCSV(Data("id\n1\n2\n".utf8), name: "review.csv")
        await model.describe(); await model.preview()
        return model
    }

    @Test func stopDuringApprovalCannotSendApplyAfterTheApprovalReturns() async {
        let backend = TransferReviewBackend(), approval = ReviewGate<Bool>()
        let model = await ready(backend, authorize: { _, _ in await approval.wait() })
        #expect(model.canApply)
        let applying = Task { await model.apply() }
        await approval.waitUntilWaiting()
        await model.stop()
        await approval.release(true)
        await applying.value
        #expect(await backend.count("apply") == 0)
        #expect(!model.hasUnknownOutcome && !model.canApply)
        await model.close()
    }

    @Test func closeDuringApprovalNeverDispatchesAWrite() async {
        let backend = TransferReviewBackend(), approval = ReviewGate<Bool>()
        let model = await ready(backend, authorize: { _, _ in await approval.wait() })
        let applying = Task { await model.apply() }
        await approval.waitUntilWaiting()
        let closing = Task { await model.close() }
        while !model.closing { await Task.yield() }
        await approval.release(true)
        await applying.value; await closing.value
        #expect(await backend.count("apply") == 0 && !model.isBusy)
        #expect(await backend.wasShutdown())
    }

    @Test func exactInputEditAndInvalidatedProfileEachInvalidatePendingApproval() async {
        let composed = "caf\u{00e9}", decomposed = "cafe\u{0301}"
        for profileChanges in [false, true] {
            let backend = TransferReviewBackend(), approval = ReviewGate<Bool>(), validity = ReviewProfileValidity()
            let model = await ready(backend, authorize: { _, _ in await approval.wait() }, current: { _ in validity.current })
            model.targetTable = composed
            await model.preview()
            #expect(model.canApply)
            let applying = Task { await model.apply() }
            await approval.waitUntilWaiting()
            if profileChanges { validity.current = false }
            else { model.targetTable = decomposed }
            await approval.release(true)
            await applying.value
            #expect(await backend.count("apply") == 0)
            await model.close()
        }
    }

    @Test func stopWhileResolvingCredentialsDoesNotCreateAHelperJob() async {
        let profile = profile(), backend = TransferReviewBackend(), credential = ReviewGate<Void>()
        let model = DataTransferModel(profiles: [profile], resolve: { profile, _ in
            await credential.wait(); return profile.settings(password: "")
        }, current: { _ in true }, authorize: { _, _ in true }, factory: { backend })
        model.targetID = profile.id; model.targetTable = "review_destination"
        await model.loadCSV(Data("id\n1\n".utf8), name: "review.csv")
        let preparing = Task { await model.describe() }
        await credential.waitUntilWaiting()
        await model.stop()
        await credential.release(())
        await preparing.value
        #expect(await backend.count("describe") == 0)
        #expect(!model.isBusy && !model.canApply)
        await model.close()
    }

    @Test func remoteFailureAfterAcceptedApplyIsUncertainAndInvalidatesTargetViews() async {
        let backend = TransferReviewBackend(failStatusAfterApply: true), validity = ReviewProfileValidity()
        let profile = profile()
        let model = DataTransferModel(profiles: [profile], resolve: { profile, _ in profile.settings(password: "") },
            current: { _ in true }, authorize: { _, _ in true }, factory: { backend }, changed: { _ in validity.changes += 1 })
        model.targetID = profile.id; model.targetTable = "review_destination"
        await model.loadCSV(Data("id\n1\n2\n".utf8), name: "review.csv")
        await model.describe(); await model.preview(); await model.apply()
        #expect(model.hasUnknownOutcome && !model.canApply && !model.canEdit)
        #expect(validity.changes == 1 && model.error?.contains("Inspect") == true)
        #expect(await backend.count("apply") == 1)
        await model.close()
    }

    @Test func preflightRemoteApplyRejectionDoesNotInventAnUncertainWrite() async {
        let backend = TransferReviewBackend(rejectApply: true)
        let model = await ready(backend)
        await model.apply()
        #expect(!model.hasUnknownOutcome && !model.canApply && model.canPreview)
        #expect(model.error?.contains("did not start") == true)
        await model.close()
    }

    @Test func concurrentPresetWritersKeepOneWinnerAndCanRecoverAfterReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-presets-review-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json")
        let first = TransferMappingPresetStore(url: url), second = TransferMappingPresetStore(url: url)
        await first.load(); await second.load()
        let a = TransferMappingPreset(name: "Review A", engine: .postgresql, purpose: "append", headers: ["id"],
            columns: [.init(sourceIndex: 0, targetName: "id")], fileOptions: .init(.init()))
        let b = TransferMappingPreset(name: "Review B", engine: .postgresql, purpose: "append", headers: ["id"],
            columns: [.init(sourceIndex: 0, targetName: "id")], fileOptions: .init(.init()))
        func save(_ preset: TransferMappingPreset, in store: TransferMappingPresetStore) async -> Bool {
            do { try await store.save(preset); return true } catch { return false }
        }
        async let savedA = save(a, in: first)
        async let savedB = save(b, in: second)
        let outcomes = await (savedA, savedB)
        #expect(outcomes.0 != outcomes.1)
        let observed = TransferMappingPresetStore(url: url)
        await observed.load()
        #expect(observed.loaded && observed.presets.count == 1)
        let retrying = outcomes.0 ? second : first
        await retrying.load()
        try await retrying.save(outcomes.0 ? b : a)
        await observed.load()
        #expect(Set(observed.presets.map(\.name)) == ["Review A", "Review B"])
    }
}

@MainActor
struct DatabaseToolsReviewTests {
    @Test func canonicallyEquivalentFileAndDatabaseEditsRequireNewRestoreApproval() async {
        let composed = "caf\u{00e9}", decomposed = "cafe\u{0301}"
        for field in ["path", "database", "tool"] {
            let profile = SavedConnection(name: "Tools review", settings: .init(host: "fixture.invalid", port: 5432,
                database: composed, user: "reader", password: "", sslMode: "disable"))
            let backend = ToolsReviewBackend(), approval = ReviewGate<Bool>()
            let model = DatabaseToolsModel(profiles: [profile], resolve: { profile, _ in profile.settings(password: "") },
                authorize: { _, _ in await approval.wait() }, factory: { backend })
            model.operation = .restore
            model.path = "/fixture/\(composed).sql"; model.toolPath = "/fixture/\(composed)/psql"
            await model.prepare()
            #expect(model.canStart)
            let starting = Task { await model.start() }
            await approval.waitUntilWaiting()
            switch field {
            case "path": model.path = "/fixture/\(decomposed).sql"
            case "database": model.database = decomposed
            default: model.toolPath = "/fixture/\(decomposed)/psql"
            }
            await approval.release(true)
            await starting.value
            #expect(await backend.startCount() == 0)
            #expect(!model.canStart && model.preview == nil && !model.requiresOutcomeReview)
            await model.close()
        }
    }

    @Test func wrongSummaryInStartReplyCannotReportACompletedRestore() async {
        let profile = SavedConnection(name: "Tools review", settings: .init(host: "fixture.invalid", port: 5432,
            database: "fixture", user: "reader", password: "", sslMode: "disable"))
        let backend = ToolsReviewBackend(changeResultTarget: true)
        let model = DatabaseToolsModel(profiles: [profile], resolve: { profile, _ in profile.settings(password: "") },
            authorize: { _, _ in true }, factory: { backend })
        model.operation = .restore; model.path = "/fixture/review.sql"; model.toolPath = "/fixture/psql"
        await model.prepare(); await model.start()
        #expect(model.result?.state == .outcomeUnknown && model.requiresOutcomeReview)
        #expect(!model.canStart && !model.canPreview)
        await model.close()
    }
}

private actor TransferReviewBackend: DataTransferBackend {
    private var operations: [String] = []
    private var didShutdown = false
    private let failStatusAfterApply: Bool
    private let rejectApply: Bool
    init(failStatusAfterApply: Bool = false, rejectApply: Bool = false) {
        self.failStatusAfterApply = failStatusAfterApply; self.rejectApply = rejectApply
    }
    func begin(_ operation: String, _ request: DataTransferRequest) async throws -> DataTransferReply { try await self.request(operation, request) }
    func request(_ operation: String, _ request: DataTransferRequest) async throws -> DataTransferReply {
        operations.append(operation)
        if operation == "status" && failStatusAfterApply || operation == "apply" && rejectApply {
            throw BackendRemoteError(reply: BackendMessage(type: "error", requestId: "review-error", category: "protocol",
                message: "The retained job is unavailable.", connected: false, outcomeUnknown: false))
        }
        let state = operation == "describe" ? "described" : operation == "preview" ? "ready" : operation == "apply" ? (failStatusAfterApply ? "running" : "completed") : operation == "cancel" ? "cancelled" : "closed"
        return DataTransferReply(jobId: "review-job", state: state, phase: "review",
            columns: [.init(sourceIndex: 0, name: "id", type: "integer", nullable: false)],
            sql: operation == "preview" ? "CREATE TABLE reviewed (id BIGINT)" : nil,
            planDigest: operation == "preview" ? String(repeating: "a", count: 64) : nil,
            rowsRead: 2, rowsWritten: operation == "apply" ? 2 : 0, notices: [], tableCreated: operation == "apply", outcomeUnknown: false)
    }
    func shutdown() async { didShutdown = true }
    func count(_ operation: String) -> Int { operations.filter { $0 == operation }.count }
    func wasShutdown() -> Bool { didShutdown }
}

private actor ToolsReviewBackend: DatabaseToolsBackend {
    private let changeResultTarget: Bool
    private var prepared: DatabaseToolsReply?
    private var starts = 0
    init(changeResultTarget: Bool = false) { self.changeResultTarget = changeResultTarget }
    func preview(_ request: DatabaseToolsRequest) async throws -> DatabaseToolsReply {
        let reply = DatabaseToolsReply(planId: "review-plan", approvalToken: "review-approval", state: .prepared, phase: "ready",
            engine: .postgresql, operation: "restore", format: "sql", database: request.connection?.database, path: request.path,
            toolName: "psql", toolVersion: "17.0", serverVersion: "17.0", requiresConfirmation: true, outputPublished: false, warnings: [])
        prepared = reply
        return reply
    }
    func request(_ operation: String, _ request: DatabaseToolsRequest) async throws -> DatabaseToolsReply {
        if operation == "close" {
            return .init(planId: request.planId, jobId: request.jobId, state: .closed, phase: "closed", requiresConfirmation: false, outputPublished: false, warnings: [])
        }
        guard operation == "start", var reply = prepared else { throw BackendRequestError.invalidCommand }
        starts += 1
        reply.planId = nil; reply.approvalToken = nil; reply.jobId = "review-job"; reply.state = .completed; reply.phase = "completed"
        if changeResultTarget { reply.database = "unreviewed_target" }
        return reply
    }
    func shutdown() async {}
    func startCount() -> Int { starts }
}

@MainActor private final class ReviewProfileValidity { var current = true; var changes = 0 }

private actor ReviewGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }
    func waitUntilWaiting() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release(_ value: Value) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}
