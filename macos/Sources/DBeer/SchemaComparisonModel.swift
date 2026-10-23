import Combine
import CryptoKit
import Foundation

protocol SchemaComparisonBackend: Sendable {
    func start(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse
    func request(_ operation: String, _ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse
    func shutdown() async
}
actor SchemaComparisonHelperBackend: SchemaComparisonBackend {
    private let client: BackendClient
    init(client: BackendClient = BackendClient()) { self.client = client }
    func start(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        try await client.start()
        for settings in [request.source?.connection, request.target?.connection].compactMap({ $0 }) {
            try Task.checkCancellation()
            try await SSHConnectionReview.prepare(settings, client: client)
        }
        return try await self.request("start", request)
    }
    func request(_ operation: String, _ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        let reply = try await client.request(.compareSchema(operation, request))
        guard let response = reply.schemaComparison else { throw BackendTransportError(.invalidMessage) }
        return response
    }
    func shutdown() async { _ = await client.shutdown() }
}

@MainActor
final class SchemaComparisonModel: ObservableObject, Identifiable {
    let id = UUID()
    let profiles: [SavedConnection]
    @Published var sourceID: UUID?
    @Published var targetID: UUID?
    @Published var mappings = SchemaMappings()
    @Published private(set) var phase = ResultComparisonState.closed
    @Published private(set) var hasStarted = false
    @Published private(set) var sourceProfile: SavedConnection?
    @Published private(set) var targetProfile: SavedConnection?
    @Published private(set) var summary: SchemaComparisonSummary?
    @Published private(set) var page: SchemaComparisonPage?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isExporting = false
    @Published private(set) var valueText: String?
    @Published private(set) var valueHasMore = false
    @Published private(set) var valueOffset: Int64 = 0
    @Published private(set) var valueNextOffset: Int64 = 0
    @Published private(set) var valueTotalBytes: Int64 = 0
    @Published private(set) var valueBoundaryBytes = 0
    @Published private(set) var exportComplete = false
    @Published private(set) var selectedDifference: SchemaDifference?
    @Published private(set) var diff: ComparisonTextDiff?
    @Published private(set) var isLoadingDiff = false
    @Published private(set) var diffError: String?
    private let resolve: @MainActor (SavedConnection) async throws -> ConnectionSettings
    private let factory: @MainActor () -> any SchemaComparisonBackend
    private var backend: (any SchemaComparisonBackend)?
    private var jobID: String?
    private var generation = UUID()
    private var pageGeneration = UUID()
    private var valueGeneration = UUID()
    private var diffGeneration = UUID()
    private var poll: Task<Void, Never>?
    private var offsets: [Int64] = [0]
    private var selectedPreview: SchemaValuePreview?
    private var valueOffsets: [Int64] = [0]

    init(profiles: [SavedConnection], resolve: @escaping @MainActor (SavedConnection) async throws -> ConnectionSettings,
         factory: @escaping @MainActor () -> any SchemaComparisonBackend = { SchemaComparisonHelperBackend() }) {
        self.profiles = profiles.filter { $0.engine != .cassandra }; self.resolve = resolve; self.factory = factory
    }
    var isWorking: Bool { hasStarted && phase.isWorking }
    var canStart: Bool {
        !hasStarted && mappings.valid && profiles.contains { $0.id == sourceID } && profiles.contains { $0.id == targetID } &&
        profiles.first { $0.id == sourceID }?.engine == profiles.first { $0.id == targetID }?.engine
    }
    var canPrevious: Bool { !isLoading && offsets.count > 1 }
    var canNext: Bool { !isLoading && page?.hasMore == true }
    func start() async {
        guard canStart, let source = profiles.first(where: { $0.id == sourceID }), let target = profiles.first(where: { $0.id == targetID }) else { return }
        let mapping = mappings
        generation = UUID(); let token = generation
        sourceProfile = source; targetProfile = target; hasStarted = true; phase = .pending; error = nil
        let service = factory(); backend = service
        do {
            let sourceSettings = try await resolve(source)
            guard generation == token else { return }
            let targetSettings = try await resolve(target)
            guard generation == token else { return }
            let request = SchemaComparisonRequest(source: .init(connection: sourceSettings), target: .init(connection: targetSettings), mappings: mapping)
            guard request.valid(for: "schema.start") else { throw BackendRequestError.invalidCommand }
            let reply = try await service.start(request)
            guard generation == token else { await service.shutdown(); return }
            guard reply.valid(for: "schema.start.result") else { throw BackendTransportError(.invalidMessage) }
            jobID = reply.jobId; phase = reply.state
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(150))
                        guard let self, self.generation == token, let job = self.jobID else { return }
                        let status = try await service.request("status", .init(jobId: job))
                        guard self.generation == token else { return }
                        guard status.jobId == job, status.valid(for: "schema.status.result") else { throw BackendTransportError(.invalidMessage) }
                        self.phase = status.state
                        if status.state == .completed {
                            guard status.summary?.engine == source.engine.rawValue, status.summary?.mappings == mapping else { throw BackendTransportError(.invalidMessage) }
                            self.summary = status.summary
                            await self.loadPage(collection: "differences"); return
                        }
                        if !status.state.isWorking { self.error = status.message; return }
                    } catch is CancellationError { return }
                    catch { guard let self, self.generation == token else { return }; self.phase = .failed; self.error = "Schema comparison could not be completed."; await service.shutdown(); return }
                }
            }
        } catch {
            guard generation == token else { return }
            phase = .failed; self.error = "Schema comparison could not start. Check both connections and metadata permissions."
            await service.shutdown()
        }
    }
    func stop() async {
        guard isWorking else { return }
        generation = UUID(); poll?.cancel(); phase = .cancelled
        cancelReviews()
        if let backend { if let jobID { _ = try? await backend.request("cancel", .init(jobId: jobID)) }; await backend.shutdown() }
    }
    func close() async {
        generation = UUID(); pageGeneration = UUID(); valueGeneration = UUID(); clearDiff(); poll?.cancel(); phase = .closed
        cancelReviews(); isLoading = false
        if let backend { if let jobID { _ = try? await backend.request("close", .init(jobId: jobID)) }; await backend.shutdown() }
        backend = nil; page = nil; valueText = nil
    }
    private func cancelReviews() {
        for profile in [sourceProfile, targetProfile].compactMap({ $0 }) where profile.ssh != nil { SSHConnectionReview.cancel(profileId: profile.id.uuidString) }
    }
    func reset() async { await close(); hasStarted = false; summary = nil; error = nil; offsets = [0]; exportComplete = false; sourceProfile = nil; targetProfile = nil }
    func loadPage(collection: String, offset: Int64 = 0) async {
        guard phase == .completed, let backend, let jobID else { return }
        let token = generation; pageGeneration = UUID(); let pageToken = pageGeneration
        isLoading = true; error = nil; clearDiff()
        defer { if pageGeneration == pageToken { isLoading = false } }
        do {
            let response = try await backend.request("page", .init(jobId: jobID, collection: collection, offset: offset))
            guard generation == token, pageGeneration == pageToken else { return }
            guard response.jobId == jobID, response.valid(for: "schema.page.result"), let result = response.page,
                  result.collection == collection, result.offset == offset else { throw BackendTransportError(.invalidMessage) }
            if page?.collection != collection { offsets = [0] }; page = result
        } catch { if generation == token, pageGeneration == pageToken { self.error = "The report page could not be read." } }
    }
    func nextPage() async { guard canNext, let page else { return }; offsets.append(page.nextOffset); await loadPage(collection: page.collection, offset: page.nextOffset) }
    func previousPage() async { guard canPrevious, let page else { return }; offsets.removeLast(); await loadPage(collection: page.collection, offset: offsets.last ?? 0) }
    private func clearValue() {
        valueGeneration = UUID(); selectedPreview = nil; valueText = nil; valueHasMore = false
        valueOffsets = [0]; valueOffset = 0; valueNextOffset = 0; valueTotalBytes = 0; valueBoundaryBytes = 0
    }
    private func clearDiff() {
        clearValue(); diffGeneration = UUID(); selectedDifference = nil; diff = nil; diffError = nil; isLoadingDiff = false
    }
    func inspectDifference(_ difference: SchemaDifference) async {
        guard phase == .completed, let backend, let jobID, page?.differences.contains(difference) == true else { return }
        if selectedDifference != difference { clearValue() }
        diffGeneration = UUID(); let requestToken = diffGeneration; let token = generation
        selectedDifference = difference; diff = nil; diffError = nil; isLoadingDiff = true
        defer { if diffGeneration == requestToken { isLoadingDiff = false } }
        do {
            let response = try await backend.request("diff", .init(jobId: jobID, offset: difference.index))
            guard !Task.isCancelled, generation == token, diffGeneration == requestToken else { return }
            guard response.jobId == jobID, response.valid(for: "schema.diff.result"), response.offset == difference.index, let result = response.diff else { throw BackendTransportError(.invalidMessage) }
            diff = result
        } catch {
            if !Task.isCancelled, generation == token, diffGeneration == requestToken { diffError = "The difference could not be read." }
        }
    }
    func inspect(_ preview: SchemaValuePreview) async {
        selectedPreview = preview; valueOffsets = [0]
        await loadValue(preview, offset: 0)
    }
    func nextValue() async {
        guard valueHasMore, let selectedPreview else { return }
        let offset = max(valueOffset + 1, valueNextOffset - 3)
        valueOffsets.append(offset)
        await loadValue(selectedPreview, offset: offset)
    }
    func previousValue() async {
        guard valueOffsets.count > 1, let selectedPreview else { return }
        valueOffsets.removeLast()
        await loadValue(selectedPreview, offset: valueOffsets.last ?? 0)
    }
    var canPreviousValue: Bool { valueOffsets.count > 1 }
    private func loadValue(_ preview: SchemaValuePreview, offset: Int64) async {
        guard let backend, let jobID, phase == .completed else { return }
        valueGeneration = UUID(); let valueToken = valueGeneration; let token = generation
        do {
            let response = try await backend.request("value", .init(jobId: jobID, offset: offset, maxBytes: 65_536, valueRef: preview.valueRef))
            guard generation == token, valueGeneration == valueToken else { return }
            guard response.jobId == jobID, response.valid(for: "schema.value.result"), let chunk = response.value,
                  chunk.offset == offset, chunk.valueRef == preview.valueRef, chunk.totalBytes == preview.totalBytes,
                  let data = chunk.data, data.count <= 65_536 else { throw BackendTransportError(.invalidMessage) }
            let window = ResultComparisonModel.textWindow(data)
            guard let window else { throw BackendTransportError(.invalidMessage) }
            valueText = window.text; valueHasMore = chunk.hasMore
            valueOffset = offset; valueNextOffset = chunk.nextOffset; valueTotalBytes = chunk.totalBytes
            valueBoundaryBytes = window.leadingBytes + window.trailingBytes
        } catch { if generation == token, valueGeneration == valueToken { self.error = "The property value could not be read." } }
    }
    func export(to destination: URL) async {
        guard let backend, let jobID, phase == .completed, !isExporting else { return }
        isExporting = true; exportComplete = false; error = nil
        let token = generation; defer { isExporting = false }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".dbeer-schema-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: temporary); defer { try? handle.close() }
            var offset: Int64 = 0; var total: Int64?; var digest: String?; var hash = SHA256()
            repeat {
                try Task.checkCancellation()
                let response = try await backend.request("export", .init(jobId: jobID, offset: offset))
                guard generation == token else { throw CancellationError() }
                guard response.jobId == jobID, response.valid(for: "schema.export.result"), let chunk = response.export,
                      chunk.offset == offset, chunk.totalBytes == (total ?? chunk.totalBytes), chunk.sha256 == (digest ?? chunk.sha256),
                      let data = chunk.data else { throw BackendTransportError(.invalidMessage) }
                total = chunk.totalBytes; digest = chunk.sha256; offset = chunk.nextOffset
                try handle.write(contentsOf: data); hash.update(data: data)
                if !chunk.hasMore { break }
            } while true
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else { throw BackendTransportError(.invalidMessage) }
            try handle.synchronize(); try handle.close()
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: destination) }; exportComplete = true
        } catch is CancellationError { return }
        catch { if generation == token { self.error = "The report could not be exported. The destination was left unchanged." } }
    }
}

@MainActor
enum SchemaComparisonCredentials {
    static func settings(_ profile: SavedConnection, store: any ConnectionCredentialStore) async throws -> ConnectionSettings {
        let secret = profile.passwordCommand == nil ? try await store.password(for: profile.id) ?? "" : ""
        var settings = profile.settings(password: secret)
        if var ssh = settings.ssh {
            if ssh.authMethod == .password {
                ssh.password = try await store.secret(for: profile.id, purpose: .sshPassword)
                if ssh.password == nil { ssh.password = try await SSHConnectionReview.requestSecret(passphrase: false, profileId: profile.id.uuidString, configuration: ssh.configuration) }
            } else if ssh.authMethod == .privateKey {
                ssh.passphrase = try await store.secret(for: profile.id, purpose: .sshPassphrase)
                if ssh.passphrase == nil { ssh.passphrase = try await SSHConnectionReview.requestSecret(passphrase: true, profileId: profile.id.uuidString, configuration: ssh.configuration) }
            }
            settings.ssh = ssh
        }
        return settings
    }
}
