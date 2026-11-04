import Foundation
import Testing
@testable import DBeer

/// Protocol and model coverage only; no windows, file panels or utilities run.
@MainActor
struct DatabaseToolsTests {
    private func profile(readonly: Bool = false) -> SavedConnection {
        SavedConnection(name: "Tools fixture", settings: .init(host: "fixture.invalid", port: 5432,
            database: "fixture_db", user: "reader", password: "", sslMode: "disable",
            policy: .init(environment: .development, readOnly: readonly)))
    }
    private func configured(_ profile: SavedConnection, backend: DatabaseToolsFakeBackend,
                            authorize: @escaping @MainActor (SavedConnection, DatabaseToolsReply) async -> Bool = { _, _ in true },
                            current: @escaping @MainActor (SavedConnection) -> Bool = { _ in true }) -> DatabaseToolsModel {
        let model = DatabaseToolsModel(profiles: [profile], resolve: { profile, _ in profile.settings(password: "") },
            authorize: authorize, bindingIsCurrent: current, factory: { backend })
        model.path = "/fixture/database.sql"; model.toolPath = "/fixture/pg_dump"
        return model
    }

    @Test func requestsAndRepliesRejectMixedOrUnboundedPayloads() {
        let settings = profile().settings(password: "")
        var request = DatabaseToolsRequest(connection: settings, operation: "dump", format: "sql", path: "/fixture/dump.sql", toolPath: "/fixture/pg_dump")
        #expect(request.valid(for: "dbtools.preview"))
        request.jobId = "unrelated-job"
        #expect(!request.valid(for: "dbtools.preview"))
        request = .init(planId: "plan", approvalToken: "approval", confirmed: true)
        #expect(request.valid(for: "dbtools.start"))
        #expect(!request.valid(for: "dbtools.status"))
        request = .init(jobId: "job", confirmed: false)
        #expect(!request.valid(for: "dbtools.status"))
        var reply = DatabaseToolsFakeBackend.reply(state: .completed)
        #expect(reply.valid(for: "dbtools.status.result"))
        reply.outputPublished = true; reply.operation = "restore"
        #expect(!reply.valid(for: "dbtools.status.result"))
        reply = DatabaseToolsFakeBackend.reply(state: .running)
        reply.bytesProcessed = 5; reply.totalBytes = 4
        #expect(!reply.valid(for: "dbtools.status.result"))
        reply = DatabaseToolsFakeBackend.reply(state: .running)
        reply.warnings = Array(repeating: "Limited", count: 17)
        #expect(!reply.valid(for: "dbtools.status.result"))
    }

    @Test func sharedGoFixtureRepliesAgreeWithNativeValidation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/database-tools-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for item in try #require(fixture["validCommands"] as? [[String: Any]]) {
            let command = try JSONDecoder().decode(BackendCommand.self, from: JSONSerialization.data(withJSONObject: item))
            #expect(command.databaseTools?.valid(for: command.type) == true)
        }
        for item in try #require(fixture["validReplies"] as? [[String: Any]]) {
            try JSONDecoder().decode(BackendMessage.self, from: JSONSerialization.data(withJSONObject: item)).validate()
        }
        for item in try #require(fixture["invalidReplies"] as? [[String: Any]]) {
            let bytes = try JSONSerialization.data(withJSONObject: item)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(BackendMessage.self, from: bytes).validate() }
        }
    }

    @Test func readonlyProfilesAllowDumpButNeverPrepareRestore() async {
        let backend = DatabaseToolsFakeBackend()
        let model = configured(profile(readonly: true), backend: backend)
        #expect(model.canPreview)
        model.operation = .restore
        #expect(!model.canPreview && !model.canStart)
        await model.prepare()
        #expect(await backend.operations().isEmpty)
        await model.close()
    }

    @Test func inputChangesInvalidatePreviewAndRequireASecondReview() async {
        let backend = DatabaseToolsFakeBackend()
        let model = configured(profile(), backend: backend)
        await model.prepare()
        #expect(model.canStart && model.preview?.database == "fixture_db")
        model.path = "/fixture/other.sql"
        #expect(!model.canStart && model.preview == nil)
        await model.start()
        #expect(await backend.operations() == ["preview"])
        await model.close()
    }

    @Test func restoreAlwaysConfirmsAndLateInputEditCannotStartIt() async {
        let gate = DatabaseToolsTestGate<Bool>()
        let backend = DatabaseToolsFakeBackend(operation: "restore")
        let model = configured(profile(), backend: backend, authorize: { _, _ in await gate.wait() })
        model.operation = .restore; model.toolPath = "/fixture/psql"
        await model.prepare()
        #expect(model.canStart)
        let starting = Task { await model.start() }
        await gate.waitUntilWaiting()
        model.database = "different_target"
        gate.release(true)
        await starting.value
        #expect(await backend.operations() == ["preview"])
        #expect(model.preview == nil && !model.canStart && model.error != nil)
        await model.close()
    }

    @Test func failedStartMakesRestoreOutcomeUncertainAndBlocksRetry() async {
        let backend = DatabaseToolsFakeBackend(operation: "restore", failStart: true)
        let model = configured(profile(), backend: backend)
        model.operation = .restore; model.toolPath = "/fixture/psql"
        await model.prepare(); await model.start()
        #expect(model.result?.state == .outcomeUnknown && model.requiresOutcomeReview)
        #expect(!model.canPreview && !model.canStart && !model.canConfigure)
        #expect(await backend.operations().filter { $0 == "start" }.count == 1)
        await model.start()
        #expect(await backend.operations().filter { $0 == "start" }.count == 1)
        await model.close()
    }

    @Test func completedDumpReportsOnlyPublishedOutput() async {
        let backend = DatabaseToolsFakeBackend(immediateCompletion: true)
        let model = configured(profile(), backend: backend)
        await model.prepare(); await model.start()
        #expect(model.result?.state == .completed && model.result?.outputPublished == true)
        #expect(!model.isBusy && !model.canStart && !model.canPreview)
        await model.reset()
        #expect(model.result == nil && model.preview == nil && model.canPreview)
        await model.close()
    }

    @Test func preparedStateIsNeverRestoredOrExecutedByConstruction() async {
        let backend = DatabaseToolsFakeBackend()
        let model = configured(profile(), backend: backend)
        #expect(model.preview == nil && model.result == nil && !model.isBusy)
        #expect(await backend.operations().isEmpty)
        await model.close()
        #expect(await backend.operations().isEmpty)
    }
}

private actor DatabaseToolsFakeBackend: DatabaseToolsBackend {
    private let operation: String
    private let failStart: Bool
    private let immediateCompletion: Bool
    private var recorded: [String] = []
    init(operation: String = "dump", failStart: Bool = false, immediateCompletion: Bool = false) {
        self.operation = operation; self.failStart = failStart; self.immediateCompletion = immediateCompletion
    }
    nonisolated static func reply(state: DatabaseToolsState, operation: String = "dump") -> DatabaseToolsReply {
        DatabaseToolsReply(planId: state == .prepared ? "plan" : nil, approvalToken: state == .prepared ? "approval" : nil,
            jobId: state == .prepared ? nil : "job", state: state, phase: state == .prepared ? "ready" : state == .running ? "starting" : state.rawValue,
            engine: .postgresql, operation: operation, format: "sql", database: "fixture_db", path: "/fixture/database.sql",
            toolName: operation == "dump" ? "pg_dump" : "psql", toolVersion: "17.0", serverVersion: "17.0",
            requiresConfirmation: operation == "restore", outputPublished: operation == "dump" && state == .completed, warnings: [])
    }
    func operations() -> [String] { recorded }
    func preview(_ request: DatabaseToolsRequest) async throws -> DatabaseToolsReply {
        recorded.append("preview")
        return Self.reply(state: .prepared, operation: operation)
    }
    func request(_ operation: String, _ request: DatabaseToolsRequest) async throws -> DatabaseToolsReply {
        recorded.append(operation)
        if operation == "start" {
            if failStart { throw BackendTransportError(.unexpectedEOF) }
            return Self.reply(state: immediateCompletion ? .completed : .running, operation: self.operation)
        }
        if operation == "close" {
            return DatabaseToolsReply(planId: request.planId, jobId: request.jobId, state: .closed, phase: "closed",
                requiresConfirmation: false, outputPublished: false, warnings: [])
        }
        return Self.reply(state: .cancelled, operation: self.operation)
    }
    func shutdown() async {}
}

@MainActor
private final class DatabaseToolsTestGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for waiter in waiting { waiter.resume() }
            waiting.removeAll()
        }
    }
    func waitUntilWaiting() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release(_ value: Value) {
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}
