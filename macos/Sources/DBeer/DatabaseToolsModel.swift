import Combine
import Foundation

protocol DatabaseToolsBackend: Sendable {
    func preview(_ request: DatabaseToolsRequest) async throws -> DatabaseToolsReply
    func request(_ operation: String, _ request: DatabaseToolsRequest) async throws -> DatabaseToolsReply
    func shutdown() async
}

actor DatabaseToolsHelperBackend: DatabaseToolsBackend {
    private let client: BackendClient
    private let ownerID = UUID()
    private let scratchURL: URL
    private var started = false
    private var closed = false
    private var startup: Task<Void, Error>?
    private var shutdownTask: Task<Void, Never>?

    init(executableURL: URL = BackendClient.bundledExecutableURL(), arguments: [String] = [],
         scratchParentURL: URL = FileManager.default.temporaryDirectory) {
        let scratch = scratchParentURL.appendingPathComponent("dbeer-database-tools-owner-\(UUID())", isDirectory: true)
        scratchURL = scratch
        client = BackendClient(executableURL: executableURL, arguments: arguments,
            environment: ["DBEER_DATABASE_TOOLS_ROOT": scratch.path])
    }
    func preview(_ request: DatabaseToolsRequest) async throws -> DatabaseToolsReply {
        guard !closed else { throw CancellationError() }
        if !started {
            if startup == nil {
                try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                startup = Task { try await client.start() }
            }
            try await startup?.value
            started = true
        }
        guard !closed else { throw CancellationError() }
        guard await client.supportsDatabaseTools() else { throw BackendRequestError.invalidCommand }
        if let settings = request.connection, settings.ssh != nil {
            try await SSHConnectionReview.prepare(settings, client: client, ownerID: ownerID)
            try Task.checkCancellation()
        }
        return try await self.request("preview", request)
    }
    func request(_ operation: String, _ request: DatabaseToolsRequest) async throws -> DatabaseToolsReply {
        guard !closed else { throw CancellationError() }
        let message = try await client.request(.databaseTools(operation, request))
        guard let reply = message.databaseTools, reply.valid(for: "dbtools.\(operation).result") else {
            throw BackendTransportError(.invalidMessage)
        }
        return reply
    }
    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closed = true
        let task = Task { await self.finishShutdown() }
        shutdownTask = task
        await task.value
    }
    private func finishShutdown() async {
        await SSHConnectionReview.cancel(ownerID: ownerID)
        _ = try? await startup?.value
        _ = await client.shutdown()
        // The helper has exited. Remove private input
        // copies even if a forced helper exit prevented Go's deferred cleanup.
        try? FileManager.default.removeItem(at: scratchURL)
    }
}

/// Runtime operation state is deliberately excluded from workspace persistence.
@MainActor
final class DatabaseToolsModel: ObservableObject, Identifiable {
    let id = UUID()
    let profiles: [SavedConnection]
    @Published var profileID: UUID? { didSet { if oldValue != profileID { database = selectedProfile?.database ?? ""; normalizeFormat(); invalidatePreview() } } }
    @Published var database = "" { didSet { invalidatePreview() } }
    @Published var operation: DatabaseToolsOperation = .dump { didSet { invalidatePreview() } }
    @Published var format: DatabaseToolsFormat = .sql { didSet { invalidatePreview() } }
    @Published var path = "" { didSet { invalidatePreview() } }
    @Published var toolPath = "" { didSet { invalidatePreview() } }
    @Published private(set) var preview: DatabaseToolsReply?
    @Published private(set) var result: DatabaseToolsReply?
    @Published private(set) var error: String?
    @Published private(set) var isPreparing = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var isClosing = false
    @Published private(set) var capturedProfile: SavedConnection?
    @Published private(set) var capturedDatabase: String?
    @Published private(set) var capturedOperation: DatabaseToolsOperation?

    private let resolve: @MainActor (SavedConnection, UUID) async throws -> ConnectionSettings
    private let authorize: @MainActor (SavedConnection, DatabaseToolsReply) async -> Bool
    private let bindingIsCurrent: @MainActor (SavedConnection) -> Bool
    private let factory: @MainActor () -> any DatabaseToolsBackend
    private let cancelPreparation: @MainActor (SavedConnection, UUID) -> Void
    private var backend: (any DatabaseToolsBackend)?
    private var jobID: String?
    private var planID: String?
    private var preparedBinding: Data?
    private var generation = UUID()
    private var preparation: Task<DatabaseToolsReply, Error>?
    private var polling: Task<Void, Never>?
    private var closingTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var attempt: UUID?
    private var executedPreview: DatabaseToolsReply?

    init(profiles: [SavedConnection], initialProfileID: UUID? = nil,
         resolve: @escaping @MainActor (SavedConnection, UUID) async throws -> ConnectionSettings,
         authorize: @escaping @MainActor (SavedConnection, DatabaseToolsReply) async -> Bool,
         bindingIsCurrent: @escaping @MainActor (SavedConnection) -> Bool = { _ in true },
         factory: @escaping @MainActor () -> any DatabaseToolsBackend = { DatabaseToolsHelperBackend() },
         cancelPreparation: @escaping @MainActor (SavedConnection, UUID) -> Void = { _, _ in }) {
        self.profiles = profiles.filter { [.postgresql, .mysql].contains($0.engine) }
        self.resolve = resolve; self.authorize = authorize; self.bindingIsCurrent = bindingIsCurrent
        self.factory = factory; self.cancelPreparation = cancelPreparation
        profileID = self.profiles.first { $0.id == initialProfileID }?.id ?? self.profiles.first?.id
        database = self.profiles.first { $0.id == profileID }?.database ?? ""
    }

    var selectedProfile: SavedConnection? { profiles.first { $0.id == profileID } }
    var formats: [DatabaseToolsFormat] { selectedProfile?.engine == .mysql ? [.sql] : DatabaseToolsFormat.allCases }
    var expectedToolName: String {
        if selectedProfile?.engine == .mysql { return operation == .dump ? "mysqldump" : "mysql" }
        return operation == .dump ? "pg_dump" : format == .sql ? "psql" : "pg_restore"
    }
    var isRunning: Bool { isStarting || result?.state.isWorking == true }
    var isBusy: Bool { isPreparing || isRunning || isStopping }
    var canConfigure: Bool { !isBusy && !isClosing && result == nil }
    var requiresOutcomeReview: Bool { result?.state.isUncertain == true }
    var canPreview: Bool {
        guard canConfigure, let profile = selectedProfile, bindingIsCurrent(profile) else { return false }
        return DatabaseToolsRequest.text(database, maximum: 1_024, required: true) &&
            DatabaseToolsRequest.absolutePath(path) && DatabaseToolsRequest.absolutePath(toolPath) &&
            (operation != .restore || !profile.policy.readOnly) && formats.contains(format)
    }
    var canStart: Bool { canPreview && preview != nil && preparedBinding == inputBinding && backend != nil }
    var progress: Double? {
        guard let processed = result?.bytesProcessed, let total = result?.totalBytes, total > 0 else { return nil }
        return min(1, max(0, Double(processed) / Double(total)))
    }

    private struct InputBinding: Encodable {
        var profile: SavedConnection; var database: String; var operation: DatabaseToolsOperation
        var format: DatabaseToolsFormat; var path: String; var toolPath: String
    }
    private var inputBinding: Data? {
        guard let profile = selectedProfile else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(InputBinding(profile: profile, database: database, operation: operation, format: format, path: path, toolPath: toolPath))
    }
    private func normalizeFormat() { if selectedProfile?.engine == .mysql { format = .sql } }
    private func invalidatePreview() {
        preview = nil; preparedBinding = nil
    }

    func prepare() async {
        guard canPreview, let profile = selectedProfile, let binding = inputBinding else { return }
        let token = UUID(); generation = token; attempt = token
        isPreparing = true; error = nil; invalidatePreview()
        defer { if generation == token { isPreparing = false; preparation = nil } }
        if let backend { await retire(backend, plan: planID, job: jobID) }
        guard generation == token, !isClosing else { return }
        let service = factory(); backend = service; planID = nil; jobID = nil
        let op = operation, format = format, path = path, utility = toolPath, database = database
        let task = Task { @MainActor in
            var settings = try await self.resolve(profile, token)
            try Task.checkCancellation()
            guard self.bindingIsCurrent(profile), self.inputBinding == binding else { throw CancellationError() }
            settings.database = database
            let request = DatabaseToolsRequest(connection: settings, operation: op.rawValue, format: format.rawValue, path: path, toolPath: utility)
            guard request.valid(for: "dbtools.preview") else { throw BackendRequestError.invalidCommand }
            return try await service.preview(request)
        }
        preparation = task
        do {
            let reply = try await task.value
            guard generation == token, !isClosing, inputBinding == binding, bindingIsCurrent(profile) else {
                await retire(service, plan: reply.planId, job: nil); return
            }
            guard reply.valid(for: "dbtools.preview.result"), reply.engine == profile.engine,
                  reply.operation == op.rawValue, reply.format == format.rawValue,
                  reply.database?.utf8.elementsEqual(database.utf8) == true,
                  reply.path?.utf8.elementsEqual(path.utf8) == true else { throw BackendTransportError(.invalidMessage) }
            preview = reply; preparedBinding = binding; planID = reply.planId
        } catch {
            if generation == token, !isClosing { self.error = error is CancellationError ? "Preparation stopped." : "Preparation failed. Check the selected database, file, utility and connection settings." }
            await retire(service, plan: nil, job: nil)
            if generation == token { backend = nil; planID = nil }
        }
    }

    func start() async {
        guard canStart, let preview, let profile = selectedProfile, let service = backend,
              let binding = preparedBinding, let plan = preview.planId, let approval = preview.approvalToken else { return }
        isStarting = true; error = nil
        let token = generation
        defer { if generation == token { isStarting = false } }
        if operation == .restore {
            guard await authorize(profile, preview) else { return }
        }
        guard generation == token, !isClosing, bindingIsCurrent(profile), inputBinding == binding else {
            invalidatePreview(); error = "The operation changed during confirmation. Preview it again."; return
        }
        capturedProfile = profile; capturedDatabase = database; capturedOperation = operation
        executedPreview = preview
        do {
            let reply = try await service.request("start", .init(planId: plan, approvalToken: approval, confirmed: operation == .restore ? true : nil))
            guard generation == token, !isClosing else { return }
            guard reply.valid(for: "dbtools.start.result"), matchesExecution(reply), let job = reply.jobId else { throw BackendTransportError(.invalidMessage) }
            jobID = job; planID = nil; result = reply; invalidatePreview()
            isStarting = false
            if reply.state.isWorking { polling = Task { [weak self] in await self?.poll(service, job: job, token: token) } }
        } catch {
            guard generation == token, !isClosing else { return }
            // A restore could have begun before a terminal reply was lost.
            if error is BackendRequestError || error is BackendRemoteError {
                self.error = "The operation did not start. Preview it again to check the current utility, file and connection."
            } else if capturedOperation == .restore {
                result = uncertainResult("The restore could not be observed. The destination may have changed. Inspect it before starting another restore.")
            } else { self.error = "The dump could not start or its outcome could not be observed. Inspect the selected output before retrying." }
            await retire(service, plan: plan, job: nil); backend = nil; planID = nil; invalidatePreview()
        }
    }

    private func poll(_ service: any DatabaseToolsBackend, job: String, token: UUID) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let reply = try await service.request("status", .init(jobId: job))
                guard generation == token, !isClosing else { return }
                guard reply.valid(for: "dbtools.status.result"), reply.jobId == job, matchesExecution(reply) else { throw BackendTransportError(.invalidMessage) }
                result = reply
                if !reply.state.isWorking { return }
            } catch is CancellationError { return }
            catch {
                guard generation == token, !isClosing else { return }
                result = capturedOperation == .restore ? uncertainResult("The restore connection ended. The destination may have changed; inspect it before starting another restore.") :
                    DatabaseToolsReply(jobId: job, state: .failed, message: "The dump connection ended. Inspect the selected file before retrying.", requiresConfirmation: false, outputPublished: false, warnings: [])
                await retire(service, plan: nil, job: job); backend = nil; jobID = nil; return
            }
        }
    }

    private func uncertainResult(_ message: String) -> DatabaseToolsReply {
        DatabaseToolsReply(jobId: jobID, state: .outcomeUnknown, operation: "restore", message: message,
            requiresConfirmation: true, outputPublished: false, warnings: [])
    }

    private func matchesExecution(_ reply: DatabaseToolsReply) -> Bool {
        guard let expected = executedPreview else { return false }
        func same(_ left: String?, _ right: String?) -> Bool { left.map { Data($0.utf8) } == right.map { Data($0.utf8) } }
        return reply.engine == expected.engine && same(reply.operation, expected.operation) && same(reply.format, expected.format) &&
            same(reply.database, expected.database) && same(reply.path, expected.path) && same(reply.toolName, expected.toolName) &&
            same(reply.toolVersion, expected.toolVersion) && same(reply.serverVersion, expected.serverVersion)
    }

    func stop() async {
        if let stopTask { await stopTask.value; return }
        let task = Task { @MainActor in await self.performStop() }
        stopTask = task; await task.value; stopTask = nil
    }
    private func performStop() async {
        guard isBusy, !isClosing else { return }
        isStopping = true
        defer { isStopping = false }
        if isPreparing {
            generation = UUID(); preparation?.cancel()
            if let profile = selectedProfile, let attempt { cancelPreparation(profile, attempt) }
            if let backend { await retire(backend, plan: planID, job: jobID) }
            _ = try? await preparation?.value
            preparation = nil; backend = nil; planID = nil; isPreparing = false; invalidatePreview(); error = "Preparation stopped."
            return
        }
        if isStarting, jobID == nil {
            generation = UUID(); isStarting = false
            if capturedOperation == .restore {
                result = uncertainResult("The restore was stopped before its start response arrived. The destination may have changed.")
            } else { error = "Operation stopped. Inspect the selected output before retrying." }
            if let backend { await retire(backend, plan: planID, job: nil) }
            backend = nil; planID = nil; invalidatePreview()
            return
        }
        guard let service = backend, let job = jobID else { return }
        do {
            let reply = try await service.request("cancel", .init(jobId: job))
            guard reply.valid(for: "dbtools.cancel.result"), reply.jobId == job, matchesExecution(reply) else { throw BackendTransportError(.invalidMessage) }
            result = reply
        } catch {
            result = capturedOperation == .restore ? uncertainResult("Restore cancellation could not be confirmed. The destination may have changed.") :
                DatabaseToolsReply(jobId: job, state: .failed, message: "Dump cancellation could not be confirmed. Inspect the output file.", requiresConfirmation: false, outputPublished: false, warnings: [])
            await retire(service, plan: nil, job: job); backend = nil; jobID = nil
        }
    }

    func reset() async {
        guard !isBusy, !isClosing else { return }
        generation = UUID(); polling?.cancel(); polling = nil
        if let backend { await retire(backend, plan: planID, job: jobID) }
        backend = nil; planID = nil; jobID = nil; result = nil; error = nil; invalidatePreview()
        capturedProfile = nil; capturedDatabase = nil; capturedOperation = nil
        executedPreview = nil
    }
    func close() async {
        if let closingTask { await closingTask.value; return }
        let task = Task { @MainActor in await self.performClose() }
        closingTask = task; await task.value
    }
    private func performClose() async {
        isClosing = true; generation = UUID(); polling?.cancel(); preparation?.cancel()
        if let profile = selectedProfile, let attempt { cancelPreparation(profile, attempt) }
        if let backend { await retire(backend, plan: planID, job: jobID) }
        _ = try? await preparation?.value
        preparation = nil; polling = nil; backend = nil; planID = nil; jobID = nil
        isPreparing = false; isStarting = false; isStopping = false
    }
    private func retire(_ service: any DatabaseToolsBackend, plan: String?, job: String?) async {
        let deadline = Task { do { try await Task.sleep(for: .seconds(1)) } catch { return }; await service.shutdown() }
        if let job { _ = try? await service.request("cancel", .init(jobId: job)); _ = try? await service.request("close", .init(jobId: job)) }
        else if let plan { _ = try? await service.request("close", .init(planId: plan)) }
        deadline.cancel(); await service.shutdown()
    }
}
