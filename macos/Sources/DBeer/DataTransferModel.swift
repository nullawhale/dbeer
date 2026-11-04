import Combine
import Foundation

enum DataTransferError: LocalizedError {
    case contextChanged, noRows, mapping
    var errorDescription: String? {
        switch self {
        case .contextChanged: "The connection changed. Review the transfer again."
        case .noRows: "Choose a valid nonempty input file."
        case .mapping: "Review valid source and destination column mappings."
        }
    }
}

protocol DataTransferBackend: Sendable {
    func begin(_ operation: String, _ request: DataTransferRequest) async throws -> DataTransferReply
    func request(_ operation: String, _ request: DataTransferRequest) async throws -> DataTransferReply
    func shutdown() async
}

actor DataTransferHelperBackend: DataTransferBackend {
    private let client: BackendClient
    private let owner = UUID()
    private let scratch: URL
    private var started = false
    private var closed = false
    init(executableURL: URL = BackendClient.bundledExecutableURL(), arguments: [String] = []) {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-transfer-\(UUID())")
        client = BackendClient(executableURL: executableURL, arguments: arguments,
            environment: ["DBEER_TRANSFER_ROOT": scratch.path])
    }
    func begin(_ operation: String, _ request: DataTransferRequest) async throws -> DataTransferReply {
        guard !closed else { throw CancellationError() }
        if !started {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try await client.start(); started = true
        }
        guard await client.supportsDataTransfer() else { throw BackendRequestError.invalidCommand }
        for settings in request.transportConnections where settings.ssh != nil {
            try Task.checkCancellation()
            try await SSHConnectionReview.prepare(settings, client: client, ownerID: owner)
        }
        return try await self.request(operation, request)
    }
    func request(_ operation: String, _ request: DataTransferRequest) async throws -> DataTransferReply {
        guard !closed else { throw CancellationError() }
        let reply = try await client.request(.dataTransfer(operation, request))
        guard let transfer = reply.transfer, transfer.valid else { throw BackendTransportError(.invalidMessage, outcomeUnknown: operation == "apply") }
        return transfer
    }
    func shutdown() async {
        closed = true
        await SSHConnectionReview.cancel(ownerID: owner)
        _ = await client.shutdown()
        try? FileManager.default.removeItem(at: scratch)
    }
}

@MainActor
final class DataTransferModel: ObservableObject, Identifiable {
    let id = UUID()
    let profiles: [SavedConnection]
    let presets: TransferMappingPresetStore
    @Published var mode = "csv" { didSet { invalidateSource() } }
    @Published var sourceID: UUID? { didSet { invalidateSource() } }
    @Published var targetID: UUID? { didSet { invalidate() } }
    @Published var sourceSchema = "public" { didSet { invalidateSource() } }
    @Published var sourceTable = "" { didSet { invalidateSource() } }
    @Published var targetSchema = "public" { didSet { invalidate() } }
    @Published var targetTable = "" { didSet { invalidate() } }
    @Published var options = DelimitedImportOptions() { didSet { invalidate(); parsed = nil; columns = [] } }
    @Published var columns: [DataTransferColumn] = [] { didSet { invalidate() } }
    @Published private(set) var fileName: String?
    @Published private(set) var parsed: DelimitedImportDocument?
    @Published private(set) var reply: DataTransferReply?
    @Published private(set) var isBusy = false
    @Published private(set) var closing = false
    @Published private(set) var error: String?
    private var fileData: Data?
    private var sourceHeaders: [String] = []
    private var sourceDigest: String?
    private var jobID: String?
    private var revision: UInt64 = 0
    private var reviewedRevision: UInt64?
    private var backend: (any DataTransferBackend)?
    private var task: Task<Void, Never>?
    private var applying = false
    private var uncertain = false
    private let resolve: @MainActor (SavedConnection, UUID) async throws -> ConnectionSettings
    private let current: @MainActor (SavedConnection) -> Bool
    private let authorize: @MainActor (SavedConnection, DataTransferReply) async -> Bool
    private let factory: @MainActor () -> any DataTransferBackend
    private let cancelPreparation: @MainActor (SavedConnection, UUID) -> Void
    private var preparation: (UUID, [SavedConnection])?
    private let changed: @MainActor (SavedConnection) -> Void

    init(profiles: [SavedConnection], resolve: @escaping @MainActor (SavedConnection, UUID) async throws -> ConnectionSettings,
         current: @escaping @MainActor (SavedConnection) -> Bool,
         authorize: @escaping @MainActor (SavedConnection, DataTransferReply) async -> Bool,
         factory: @escaping @MainActor () -> any DataTransferBackend = { DataTransferHelperBackend() },
         cancelPreparation: @escaping @MainActor (SavedConnection, UUID) -> Void = { _, _ in },
         presets: TransferMappingPresetStore? = nil, changed: @escaping @MainActor (SavedConnection) -> Void = { _ in }) {
        self.profiles = profiles.filter { [.postgresql, .mysql].contains($0.engine) }
        self.resolve = resolve; self.current = current; self.authorize = authorize; self.factory = factory; self.changed = changed
        self.cancelPreparation = cancelPreparation
        self.presets = presets ?? TransferMappingPresetStore()
    }
    var sourceProfile: SavedConnection? { profiles.first { $0.id == sourceID } }
    var targetProfile: SavedConnection? { profiles.first { $0.id == targetID } }
    var canEdit: Bool { !isBusy && !closing && !uncertain && reply?.state != "completed" }
    var canDescribe: Bool { canEdit && targetProfile != nil && !targetTable.isEmpty && (mode == "csv" ? fileData != nil : sourceProfile != nil && !sourceTable.isEmpty) }
    var canPreview: Bool { canDescribe && !columns.isEmpty && columns.allSatisfy(\.valid) }
    var canApply: Bool { canEdit && reply?.state == "ready" && reviewedRevision == revision && targetProfile?.policy.readOnly == false }
    var headers: [String] { mode == "csv" ? parsed?.headers ?? [] : sourceHeaders }
    var hasUnknownOutcome: Bool { uncertain }
    private func invalidate() { revision &+= 1; reviewedRevision = nil }
    private func invalidateSource() { invalidate(); sourceDigest = nil; sourceHeaders = []; columns = [] }

    func loadCSV(_ data: Data, name: String) async {
        guard canEdit else { return }
        invalidate(); fileData = data; fileName = name; parsed = nil; columns = []
        await parseCSV()
    }
    func parseCSV() async {
        guard !isBusy, let fileData else { return }
        let token = revision, options = options
        isBusy = true; defer { isBusy = false }
        do {
            let document = try await Task.detached { try DelimitedTextImport.parse(data: fileData, options: options) }.value
            guard token == revision, !closing else { return }
            parsed = document; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func input() async throws -> DataTransferRequest {
        guard let target = targetProfile, current(target) else { throw DataTransferError.contextChanged }
        let token = revision, attempt = UUID()
        preparation = (attempt, [target, mode == "table" ? sourceProfile : nil].compactMap { $0 })
        defer { preparation = nil }
        let destination = try await resolve(target, attempt)
        try Task.checkCancellation()
        guard current(target), token == revision, !closing else { throw CancellationError() }
        var request = DataTransferRequest(mode: mode, target: .init(connection: destination, schema: targetSchema, table: targetTable))
        if mode == "table" {
            guard let source = sourceProfile, current(source) else { throw DataTransferError.contextChanged }
            let settings = try await resolve(source, attempt)
            try Task.checkCancellation()
            guard current(source), current(target), token == revision else { throw CancellationError() }
            request.source = .init(connection: settings, schema: sourceSchema, table: sourceTable)
        } else {
            guard let parsed else { throw DataTransferError.noRows }
            let binary = Set(columns.filter { $0.type == "binary" }.map(\.sourceIndex))
            request.headers = parsed.headers
            request.rows = try parsed.rows.map { row in
                try row.fields.enumerated().map { try $0.element.value(options: options, binary: binary.contains($0.offset)) }
            }
        }
        return request
    }
    func describe() async { await run("describe") }
    func preview() async { await run("preview") }
    private func run(_ operation: String) async {
        guard operation == "describe" ? canDescribe : canPreview else { return }
        if mode == "csv", parsed == nil { await parseCSV() }
        guard !isBusy else { return }
        isBusy = true; error = nil; reviewedRevision = nil
        let token = revision
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                if let jobID, let backend { _ = try? await backend.request("close", .init(jobId: jobID)) }
                jobID = nil
                var request = try await input()
                if operation == "preview" { request.columns = columns; request.sourceDigest = mode == "table" ? sourceDigest : nil }
                guard request.valid(for: "transfer." + operation), token == revision else { throw DataTransferError.mapping }
                if backend == nil { backend = factory() }
                guard let backend else { return }
                let started = try await backend.begin(operation, request)
                jobID = started.jobId
                let final = try await observe(started, backend: backend)
                guard !closing, token == revision else { return }
                reply = final
                if operation == "describe", final.state == "described" {
                    sourceHeaders = final.columns?.map(\.name) ?? []
                    columns = final.columns ?? []
                    sourceDigest = final.sourceDigest
                }
                if final.state == "ready" { reviewedRevision = revision }
                if final.state == "failed" { error = final.message ?? "The transfer could not be prepared." }
            } catch let failure { if !self.closing { self.error = failure.localizedDescription } }
        }
        task = work; await work.value; task = nil
    }
    private func observe(_ initial: DataTransferReply, backend: any DataTransferBackend) async throws -> DataTransferReply {
        var latest = initial
        while ["pending", "running"].contains(latest.state) {
            reply = latest
            try await Task.sleep(for: .milliseconds(150))
            latest = try await backend.request("status", .init(jobId: latest.jobId))
            guard latest.valid, latest.jobId == initial.jobId else { throw BackendTransportError(.invalidMessage, outcomeUnknown: applying) }
        }
        return latest
    }
    func apply() async {
        guard canApply, let reviewed = reply, let target = targetProfile, let digest = reviewed.planDigest, let backend else { return }
        let token = revision
        isBusy = true
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performApply(reviewed, target: target, digest: digest, backend: backend, token: token)
        }
        task = work; await work.value; task = nil
    }
    private func performApply(_ reviewed: DataTransferReply, target: SavedConnection, digest: String, backend: any DataTransferBackend, token: UInt64) async {
        defer { isBusy = false; applying = false }
        guard await authorize(target, reviewed), token == revision, current(target), !closing else { return }
        applying = true; error = nil
        do {
            let started = try await backend.request("apply", .init(jobId: reviewed.jobId, planDigest: digest, confirmed: true))
            let final = try await observe(started, backend: backend)
            reply = final; uncertain = final.outcomeUnknown
            reviewedRevision = nil
            if final.state == "completed" || final.tableCreated { changed(target) }
        } catch {
            uncertain = true
            self.error = "The transfer response was lost. Inspect the destination before attempting another transfer."
        }
    }
    func stop() async {
        guard !closing else { return }
        cancelCredentials()
        reviewedRevision = nil
        if let jobID, let backend { _ = try? await backend.request("cancel", .init(jobId: jobID)) }
        else { task?.cancel(); await backend?.shutdown(); backend = nil }
    }
    func close() async {
        guard !closing else { await task?.value; return }
        closing = true; reviewedRevision = nil
        await stopOwnedJob()
        await task?.value
        await backend?.shutdown(); backend = nil
        fileData = nil; parsed = nil
    }
    private func stopOwnedJob() async {
        cancelCredentials()
        if let jobID, let backend { _ = try? await backend.request("cancel", .init(jobId: jobID)) }
        task?.cancel()
    }
    private func cancelCredentials() {
        if let (attempt, profiles) = preparation {
            for profile in profiles { cancelPreparation(profile, attempt) }
        }
    }
    func saveMapping(name: String) async {
        guard canEdit, let profile = targetProfile, !columns.isEmpty else { return }
        let mapped = headers.indices.map { index -> TransferMappingPreset.Column in
            let column = columns.first { $0.sourceIndex == index }
            return .init(sourceIndex: index, targetName: column?.name, type: column?.type, nullable: column?.nullable, precision: column?.precision, scale: column?.scale)
        }
        do { try await presets.save(.init(name: name, engine: profile.engine, purpose: mode == "csv" ? "create" : "table", headers: headers, columns: mapped, fileOptions: .init(options))) }
        catch { self.error = error.localizedDescription }
    }
    func useMapping(_ preset: TransferMappingPreset) async {
        guard canEdit, preset.valid else { return }
        if mode == "csv", let readOptions = preset.fileOptions.options, readOptions != options {
            options = readOptions
            await parseCSV()
        }
        guard canEdit, let profile = targetProfile,
              preset.matches(headers: headers, engine: profile.engine, purpose: mode == "csv" ? "create" : "table") else {
            error = "The saved mapping does not match this source and destination engine."
            return
        }
        columns = preset.columns.compactMap { saved in
            guard let name = saved.targetName, let type = saved.type, let nullable = saved.nullable else { return nil }
            return .init(sourceIndex: saved.sourceIndex, name: name, type: type, nullable: nullable, precision: saved.precision, scale: saved.scale)
        }
    }
}
