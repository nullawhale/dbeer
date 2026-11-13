import Combine
import Foundation

actor SchemaBundleHelperBackend: SchemaComparisonBackend {
    private let client: BackendClient
    private let owner: UUID
    init(owner: UUID, client: BackendClient = BackendClient()) { self.owner = owner; self.client = client }
    func start(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        try await client.start()
        guard let settings = request.source?.connection else { throw BackendRequestError.invalidCommand }
        try Task.checkCancellation()
        try await SSHConnectionReview.prepare(settings, client: client, ownerID: owner, reviewID: "schema-bundle:" + owner.uuidString)
        return try await self.request("start", request)
    }
    func request(_ operation: String, _ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        let reply = try await client.request(.compareSchema("bundle." + operation, request))
        guard let response = reply.schemaComparison else { throw BackendTransportError(.invalidMessage) }
        return response
    }
    func shutdown() async { await SSHConnectionReview.cancel(ownerID: owner); _ = await client.shutdown() }
}

@MainActor
final class SchemaBundleModel: ObservableObject, Identifiable {
    let id = UUID()
    let profile: SavedConnection
    @Published var schemas: [String]
    @Published private(set) var phase = ResultComparisonState.closed
    @Published private(set) var hasStarted = false
    @Published private(set) var summary: SchemaBundleSummary?
    @Published private(set) var error: String?
    @Published private(set) var isExporting = false
    @Published private(set) var exported = false
    @Published private(set) var transferredBytes: Int64 = 0
    private let resolve: @MainActor (SavedConnection, UUID) async throws -> ConnectionSettings
    private let current: @MainActor () -> Bool
    private let startAllowed: @MainActor () -> Bool
    private let factory: @MainActor (UUID) -> any SchemaComparisonBackend
    private var backend: (any SchemaComparisonBackend)?
    private var jobID: String?
    private var generation = UUID()
    private var poll: Task<Void, Never>?
    private var attempt = UUID()
    private var publicationCancellation: SchemaBundlePublicationCancellation?

    init(profile: SavedConnection, resolve: @escaping @MainActor (SavedConnection, UUID) async throws -> ConnectionSettings,
         current: @escaping @MainActor () -> Bool = { true }, startAllowed: @escaping @MainActor () -> Bool = { true },
         factory: @escaping @MainActor (UUID) -> any SchemaComparisonBackend = { SchemaBundleHelperBackend(owner: $0) }) {
        self.profile = profile; self.resolve = resolve; self.current = current; self.startAllowed = startAllowed; self.factory = factory
        schemas = [profile.engine == .postgresql ? "public" : profile.engine == .sqlite ? "main" : profile.database]
    }
    var isWorking: Bool { hasStarted && phase.isWorking }
    var canStart: Bool { !hasStarted && startAllowed() && current() && SchemaBundleManifest.schemasValid(schemas, engine: profile.engine.rawValue) }
    var canExport: Bool { phase == .completed && summary != nil && !isExporting && current() }
    func start() async {
        guard canStart else { return }
        let selected = schemas
        hasStarted = true; phase = .pending; error = nil; exported = false
        generation = UUID(); let token = generation
        attempt = UUID(); let service = factory(attempt); backend = service
        do {
            var settings = try await resolve(profile, attempt)
            try requireCurrent(token)
            settings.policy.readOnly = true; settings.sessionPurpose = nil
            let request = SchemaComparisonRequest(source: .init(connection: settings), schemas: selected)
            guard request.valid(for: "schema.bundle.start") else { throw BackendRequestError.invalidCommand }
            let response = try await service.start(request)
            try requireCurrent(token)
            guard response.valid(for: "schema.bundle.start.result") else { throw BackendTransportError(.invalidMessage) }
            jobID = response.jobId; phase = response.state
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(150))
                        guard let self, let job = self.jobID else { return }
                        try self.requireCurrent(token)
                        let response = try await service.request("status", .init(jobId: job))
                        try self.requireCurrent(token)
                        guard response.jobId == job, response.valid(for: "schema.bundle.status.result") else { throw BackendTransportError(.invalidMessage) }
                        self.phase = response.state
                        if response.state == .completed {
                            guard let summary = response.bundleSummary, summary.engine == self.profile.engine.rawValue,
                                  Set(summary.schemas.map { Data($0.utf8) }) == Set(selected.map { Data($0.utf8) }) else { throw BackendTransportError(.invalidMessage) }
                            self.summary = summary; return
                        }
                        if !response.state.isWorking { self.error = response.message; return }
                    } catch is CancellationError {
                        guard let self, self.generation == token else { return }
                        self.phase = .cancelled; self.error = "The source profile changed. Open a new schema export from the current profile."
                        await service.shutdown(); return
                    } catch {
                        guard let self, self.generation == token else { return }
                        self.phase = .failed; self.error = "Schema capture could not be completed. Check metadata permissions."
                        await service.shutdown(); return
                    }
                }
            }
        } catch {
            guard generation == token else { await service.shutdown(); return }
            phase = .failed; self.error = current() ? "Schema capture could not start. Check the connection and metadata permissions." : "The source profile changed. Open a new schema export from the current profile."
            await service.shutdown()
        }
    }
    func export(to destination: URL, publicationHook: ((SchemaBundlePublicationStage) throws -> Void)? = nil, verificationHook: SchemaBundleVerificationHook? = nil) async {
        guard canExport, let backend, let jobID, let summary else { return }
        let token = generation
        let cancellation = SchemaBundlePublicationCancellation()
        publicationCancellation = cancellation
        var publication: SchemaBundleDirectory?
        isExporting = true; exported = false; error = nil; transferredBytes = 0
        defer {
            if generation == token { isExporting = false }
            if publicationCancellation === cancellation { publicationCancellation = nil }
        }
        do {
            // Capture parent/staging ownership before the first suspension.
            let output = try SchemaBundleDirectory(destination: destination)
            publication = output
            let manifestData = try await download(summary.manifest, backend: backend, job: jobID, token: token, publication: output, retain: true)
            let manifest = try SchemaBundleManifest.parse(manifestData, summary: summary)
            for file in [manifest.capture] + manifest.objects.map(\.file) {
                _ = try await download(file, backend: backend, job: jobID, token: token, publication: output, retain: false)
            }
            try requireCurrent(token)
            try await output.publish(expectedFiles: [summary.manifest, manifest.capture] + manifest.objects.map(\.file), cancellation: cancellation,
                isCurrent: { self.generation == token && self.current() }, hook: publicationHook, verificationHook: verificationHook,
                didCommit: { self.exported = true; self.isExporting = false })
        } catch is CancellationError {
            if generation == token { self.error = "Export stopped because its source context changed." }
        } catch {
            if generation == token { self.error = (error as? SchemaBundleFailure)?.errorDescription ?? "The schema bundle could not be exported." }
        }
        if let publication { await publication.finishOwnership() }
    }
    private func download(_ file: SchemaBundleFile, backend: any SchemaComparisonBackend, job: String, token: UUID,
                          publication: SchemaBundleDirectory, retain: Bool) async throws -> Data {
        guard file.valid, !retain || file.bytes <= SchemaBundleManifest.maximumManifestBytes else { throw SchemaBundleFailure.invalid }
        try publication.begin(file)
        var offset: Int64 = 0, retained = Data()
        repeat {
            try requireCurrent(token)
            let response = try await backend.request("export", .init(jobId: job, offset: offset, maxBytes: 65_536, valueRef: file.id))
            try requireCurrent(token)
            guard response.jobId == job, response.valid(for: "schema.bundle.export.result"), let chunk = response.export,
                  chunk.valueRef == file.id, chunk.sha256 == file.sha256, chunk.totalBytes == file.bytes, chunk.offset == offset,
                  let bytes = chunk.data, bytes.count <= 65_536 else { throw BackendTransportError(.invalidMessage) }
            try publication.append(bytes, to: file)
            offset = chunk.nextOffset; transferredBytes += Int64(bytes.count)
            guard transferredBytes <= SchemaBundleManifest.maximumBytes else { throw SchemaBundleFailure.invalid }
            if retain { retained.append(bytes) }
            if !chunk.hasMore { break }
        } while true
        try publication.finish(file)
        return retained
    }
    func stop() async {
        guard isWorking || isExporting else { return }
        publicationCancellation?.cancel()
        generation = UUID(); poll?.cancel(); phase = .cancelled; isExporting = false
        await retire(operation: "cancel")
    }
    func close() async {
        publicationCancellation?.cancel()
        generation = UUID(); poll?.cancel(); phase = .closed; isExporting = false
        await retire(operation: "close")
    }
    func reset() async { await close(); hasStarted = false; summary = nil; error = nil; exported = false; transferredBytes = 0 }
    private func retire(operation: String) async {
        SSHConnectionReview.cancel(ownerID: attempt)
        SSHConnectionReview.cancel(profileId: "schema-bundle:" + attempt.uuidString)
        SSHConnectionReview.cancel(profileId: DataComparisonCredentials.promptID(profile.id, attempt))
        let service = backend; let job = jobID; backend = nil; jobID = nil
        if let service { if let job { _ = try? await service.request(operation, .init(jobId: job)) }; await service.shutdown() }
    }
    private func requireCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token, current() else { throw CancellationError() }
    }
}
