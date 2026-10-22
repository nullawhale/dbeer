import Combine
import Foundation

protocol DataComparisonBackend: Sendable {
    func begin(_ operation: String, _ request: DataComparisonRequest) async throws -> DataComparisonResponse
    func request(_ operation: String, _ request: DataComparisonRequest) async throws -> DataComparisonResponse
    func shutdown() async
}
actor DataComparisonHelperBackend: DataComparisonBackend {
    private let client: BackendClient
    private let ownerID = UUID()
    private let scratchURL: URL
    private var closed = false
    init(executableURL: URL = BackendClient.bundledExecutableURL(), arguments: [String] = [],
         scratchParentURL: URL = FileManager.default.temporaryDirectory) {
        let scratch = scratchParentURL.appendingPathComponent("dbeer-data-owner-\(UUID().uuidString)", isDirectory: true)
        scratchURL = scratch
        client = BackendClient(executableURL: executableURL, arguments: arguments,
            environment: ["DBEER_DATA_COMPARISON_ROOT": scratch.path])
    }
    func begin(_ operation: String, _ request: DataComparisonRequest) async throws -> DataComparisonResponse {
        guard !closed else { throw CancellationError() }
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try await client.start()
        guard !closed else { throw CancellationError() }
        for settings in [request.source?.connection, request.target?.connection].compactMap({ $0 }) where settings.ssh != nil {
            var trusted = false
            for _ in 0..<17 {
                try Task.checkCancellation()
                try await SSHConnectionReview.prepare(settings, client: client, ownerID: ownerID)
                // A shared first-trust review belongs to its original helper;
                // verify this helper's own route instead of reusing its token.
                let ownProbe = try await client.request(.sshProbe(settings))
                if ownProbe.ssh?.status == "trusted" { trusted = true; break }
            }
            guard trusted else { throw BackendTransportError(.invalidMessage) }
        }
        return try await self.request(operation, request)
    }
    func request(_ operation: String, _ request: DataComparisonRequest) async throws -> DataComparisonResponse {
        guard !closed else { throw CancellationError() }
        let reply = try await client.request(.compareData(operation, request))
        guard let response = reply.dataComparison else { throw BackendTransportError(.invalidMessage) }
        return response
    }
    func shutdown() async {
        closed = true
        await SSHConnectionReview.cancel(ownerID: ownerID)
        _ = await client.shutdown()
        // The child has exited, including forced shutdown. Remove its private
        // captures even when Go could not run deferred cleanup.
        try? FileManager.default.removeItem(at: scratchURL)
    }
}

@MainActor
final class DataComparisonModel: ObservableObject, Identifiable {
    struct Mapping: Identifiable { var source: String; var target: String?; var key = false; var id: String { source } }
    let id = UUID()
    let profiles: [SavedConnection]
    @Published var sourceID: UUID?
    @Published var targetID: UUID?
    @Published var sourceTable = DataComparisonTable(schema: "public", name: "")
    @Published var targetTable = DataComparisonTable(schema: "public", name: "")
    @Published var sourceLimit = 10_000
    @Published var targetLimit = 10_000
    @Published var sourceFilters: [DataComparisonFilter] = []
    @Published var targetFilters: [DataComparisonFilter] = []
    @Published var originals = "allColumns"
    @Published var mappings: [Mapping] = []
    @Published private(set) var descriptors: DataComparisonDescriptors?
    @Published private(set) var summary: DataComparisonSummary?
    @Published private(set) var page: ResultComparisonPage?
    @Published private(set) var selectedRow: ResultComparisonRow?
    @Published private(set) var valueChunk: ResultComparisonValueChunk?
    @Published private(set) var selectedValue: ResultComparisonValuePreview?
    @Published private(set) var valueTitle = ""
    @Published private(set) var valueEncoding: String?
    @Published private(set) var capturedSourceFilters: [DataComparisonFilter] = []
    @Published private(set) var capturedTargetFilters: [DataComparisonFilter] = []
    @Published private(set) var phase = ResultComparisonState.closed
    @Published private(set) var operation = ""
    @Published private(set) var error: String?
    @Published private(set) var isLoadingPage = false
    @Published private(set) var isLoadingValue = false
    @Published private(set) var isStopping = false
    @Published private(set) var sourceProfile: SavedConnection?
    @Published private(set) var targetProfile: SavedConnection?
    private let resolve: @MainActor (SavedConnection, UUID) async throws -> ConnectionSettings
    private let factory: @MainActor () -> any DataComparisonBackend
    @Published private var backend: (any DataComparisonBackend)?
    private var jobID: String?
    private var generation = UUID()
    private var pageGeneration = UUID()
    private var valueGeneration = UUID()
    private var poll: Task<Void, Never>?
    private var preparation: Task<DataComparisonResponse, Error>?
    private var stopTask: Task<Void, Never>?
    private var loadedBinding: Data?
    private var pageOffsets: [Int64] = [0]
    private var cellOffsets: [Int] = [0]
    private var valueOffsets: [Int64] = [0]
    private(set) var capturedMappings: [DataComparisonMapping] = []

    init(profiles: [SavedConnection], resolve: @escaping @MainActor (SavedConnection, UUID) async throws -> ConnectionSettings,
         factory: @escaping @MainActor () -> any DataComparisonBackend = { DataComparisonHelperBackend() }) {
        self.profiles = profiles.filter { $0.engine != .cassandra }; self.resolve = resolve; self.factory = factory
    }
    var isWorking: Bool { phase.isWorking }
    var canDescribe: Bool {
        !isWorking && !isStopping && backend == nil && summary == nil && sourceTable.valid && targetTable.valid &&
        profiles.contains { $0.id == sourceID } && profiles.contains { $0.id == targetID } &&
        profiles.first { $0.id == sourceID }?.engine == profiles.first { $0.id == targetID }?.engine
    }
    private var binding: Data? {
        struct Binding: Encodable { var source: UUID?; var target: UUID?; var sourceTable: DataComparisonTable; var targetTable: DataComparisonTable }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(Binding(source: sourceID, target: targetID, sourceTable: sourceTable, targetTable: targetTable))
    }
    var metadataMatches: Bool { descriptors != nil && loadedBinding == binding }
    var requestedMappings: [DataComparisonMapping] { mappings.compactMap { row in row.target.map { .init(source: row.source, target: $0, key: row.key) } } }
    var canCompare: Bool {
        guard canDescribe, metadataMatches, let descriptors, (1...100_000).contains(sourceLimit), (1...100_000).contains(targetLimit),
              sourceFilters.count <= 32, targetFilters.count <= 32, sourceFilters.allSatisfy(\.valid), targetFilters.allSatisfy(\.valid) else { return false }
        let values = requestedMappings
        return !values.isEmpty && (1...32).contains(values.filter(\.key).count) &&
            Set(values.map { Data($0.target.utf8) }).count == values.count &&
            values.allSatisfy { item in descriptors.target.columns.contains { $0.name.utf8.elementsEqual(item.target.utf8) } } &&
            ["allColumns", "selectedColumns"].contains(originals)
    }
    func readMetadata() async { guard canDescribe else { return }; await begin(describe: true) }
    func compare() async { guard canCompare else { return }; await begin(describe: false) }
    private func begin(describe: Bool) async {
        guard let source = profiles.first(where: { $0.id == sourceID }), let target = profiles.first(where: { $0.id == targetID }) else { return }
        let tableA = sourceTable, tableB = targetTable, identity = binding
        let descriptor = descriptors, columns = requestedMappings, full = originals
        let filtersA = sourceFilters, filtersB = targetFilters, limitA = sourceLimit, limitB = targetLimit
        generation = UUID(); let token = generation
        poll?.cancel(); clearOutput(); phase = .pending; operation = describe ? "describe" : "start"
        sourceProfile = source; targetProfile = target; capturedMappings = columns
        capturedSourceFilters = filtersA; capturedTargetFilters = filtersB
        let service = factory(); backend = service
        let resolve = resolve
        let preparing = Task { @MainActor in
            let a = try await resolve(source, token); try Task.checkCancellation()
            let b = try await resolve(target, token); try Task.checkCancellation()
            let request = DataComparisonRequest(source: .init(connection: a, table: tableA, descriptorDigest: describe ? nil : descriptor?.source.digest,
                filters: describe ? nil : filtersA, readLimit: describe ? nil : limitA), target: .init(connection: b, table: tableB,
                descriptorDigest: describe ? nil : descriptor?.target.digest, filters: describe ? nil : filtersB, readLimit: describe ? nil : limitB),
                columns: describe ? nil : columns, originals: describe ? nil : full)
            guard request.valid(for: describe ? "data.describe" : "data.start") else { throw BackendRequestError.invalidCommand }
            return try await service.begin(describe ? "describe" : "start", request)
        }
        preparation = preparing
        do {
            let reply = try await preparing.value
            guard generation == token else { await service.shutdown(); return }
            guard reply.valid(for: describe ? "data.describe.result" : "data.start.result") else { throw BackendTransportError(.invalidMessage) }
            jobID = reply.jobId; phase = reply.state
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(150))
                        guard let self, self.generation == token, let job = self.jobID else { return }
                        let reply = try await service.request("status", .init(jobId: job))
                        guard self.generation == token else { return }
                        guard reply.jobId == job, reply.valid(for: "data.status.result") else { throw BackendTransportError(.invalidMessage) }
                        if reply.state == .completed {
                            if describe {
                                guard let value = reply.descriptors, self.sameTable(value.source.table, tableA), self.sameTable(value.target.table, tableB),
                                      value.source.engine == source.engine else { throw BackendTransportError(.invalidMessage) }
                                self.descriptors = value; self.loadedBinding = identity
                                self.mappings = value.source.columns.map { column in Mapping(source: column.name,
                                    target: value.target.columns.first { $0.name.utf8.elementsEqual(column.name.utf8) }?.name) }
                                await self.retire(service, job: job)
                                guard self.generation == token else { return }
                                self.backend = nil; self.jobID = nil; self.phase = .completed
                            } else {
                                guard let value = reply.summary, value.source.descriptorDigest == descriptor?.source.digest,
                                      value.target.descriptorDigest == descriptor?.target.digest, value.source.readLimit == limitA, value.target.readLimit == limitB,
                                      self.sameTable(value.source.table, tableA), self.sameTable(value.target.table, tableB),
                                      value.source.fullOriginals == (full == "allColumns"), value.target.fullOriginals == (full == "allColumns"),
                                      value.mappedColumns == columns.count, value.source.engine == source.engine else { throw BackendTransportError(.invalidMessage) }
                                self.summary = value; self.phase = .completed; await self.loadPage(offset: 0)
                            }
                            return
                        }
                        self.phase = reply.state
                        if !reply.state.isWorking {
                            self.error = reply.message ?? "Data comparison did not complete."
                            await self.retire(service, job: job)
                            guard self.generation == token else { return }
                            self.backend = nil; self.jobID = nil
                            return
                        }
                    } catch is CancellationError { return }
                    catch {
                        guard let self, self.generation == token else { return }
                        self.phase = .failed; self.error = "Data comparison could not be completed."
                        await self.retire(service, job: self.jobID)
                        guard self.generation == token else { return }
                        self.backend = nil; self.jobID = nil
                        return
                    }
                }
            }
        } catch {
            guard generation == token else { return }
            phase = .failed; self.error = "The operation could not start. Check both connections and table access."
            await retire(service, job: jobID)
            guard generation == token else { return }
            backend = nil; jobID = nil
        }
    }
    private func sameTable(_ lhs: DataComparisonTable, _ rhs: DataComparisonTable) -> Bool { lhs.schema.utf8.elementsEqual(rhs.schema.utf8) && lhs.name.utf8.elementsEqual(rhs.name.utf8) }
    private func retire(_ service: any DataComparisonBackend, job: String?) async {
        let deadline = Task { do { try await Task.sleep(for: .milliseconds(400)) } catch { return }; await service.shutdown() }
        if let job { _ = try? await service.request("cancel", .init(jobId: job)); _ = try? await service.request("close", .init(jobId: job)) }
        deadline.cancel(); await service.shutdown()
    }
    func stop() async {
        if let stopTask { await stopTask.value; return }
        let task = Task { await performStop() }
        stopTask = task
        await task.value
        stopTask = nil
    }
    private func performStop() async {
        guard !isStopping else { return }; isStopping = true
        let previous = generation; generation = UUID(); pageGeneration = UUID(); valueGeneration = UUID()
        poll?.cancel(); preparation?.cancel()
        for profile in [sourceProfile, targetProfile].compactMap({ $0 }) { SSHConnectionReview.cancel(profileId: DataComparisonCredentials.promptID(profile.id, previous)) }
        let service = backend, job = jobID; backend = nil; jobID = nil
        phase = .cancelled; isLoadingPage = false; isLoadingValue = false
        if let service { await retire(service, job: job) }; isStopping = false
    }
    func close() async { await stop(); clearOutput(); phase = .closed }
    func reset() async { await close(); operation = ""; phase = .closed }
    private func clearOutput() { summary = nil; page = nil; selectedRow = nil; selectedValue = nil; valueChunk = nil; error = nil; pageOffsets = [0]; cellOffsets = [0]; valueOffsets = [0] }
    func loadPage(offset: Int64) async {
        guard let backend, let jobID, summary != nil else { return }
        let token = generation; pageGeneration = UUID(); let pageToken = pageGeneration
        isLoadingPage = true; defer { if pageGeneration == pageToken { isLoadingPage = false } }
        do {
            let reply = try await backend.request("page", .init(jobId: jobID, offset: offset))
            guard generation == token, pageGeneration == pageToken else { return }
            guard reply.jobId == jobID, reply.valid(for: "data.page.result"), let page = reply.page, page.offset == offset,
                  page.rows.allSatisfy({ $0.totalCells == capturedMappings.count && $0.cellOffset == 0 }) else { throw BackendTransportError(.invalidMessage) }
            self.page = page; selectedRow = page.rows.first; cellOffsets = [0]; selectedValue = nil; valueChunk = nil
        } catch { if generation == token { self.error = "The result page could not be read." } }
    }
    var canPrevious: Bool { !isLoadingPage && pageOffsets.count > 1 }
    var canNext: Bool { !isLoadingPage && page?.hasMore == true }
    func nextPage() async { guard canNext, let page else { return }; pageOffsets.append(page.nextOffset); await loadPage(offset: page.nextOffset) }
    func previousPage() async { guard canPrevious else { return }; pageOffsets.removeLast(); await loadPage(offset: pageOffsets.last ?? 0) }
    func selectRow(_ row: ResultComparisonRow) { selectedRow = row; cellOffsets = [row.cellOffset]; valueGeneration = UUID(); selectedValue = nil; valueChunk = nil }
    func cells(next: Bool) async {
        guard let row = selectedRow, let backend, let jobID, !isLoadingPage else { return }
        if next { guard row.cellsTruncated else { return }; cellOffsets.append(row.nextCellOffset) }
        else { guard cellOffsets.count > 1 else { return }; cellOffsets.removeLast() }
        let offset = cellOffsets.last ?? 0; let token = generation
        isLoadingPage = true; defer { if generation == token { isLoadingPage = false } }
        do {
            let reply = try await backend.request("page", .init(jobId: jobID, offset: row.index, limit: 1, cellOffset: offset))
            guard generation == token, selectedRow?.index == row.index else { return }
            guard reply.jobId == jobID, reply.valid(for: "data.page.result"), let result = reply.page?.rows.first,
                  result.index == row.index, result.cellOffset == offset, result.totalCells == capturedMappings.count else { throw BackendTransportError(.invalidMessage) }
            selectedRow = result
        } catch { if generation == token { self.error = "The mapped columns could not be read." } }
    }
    var canPreviousCells: Bool { cellOffsets.count > 1 && !isLoadingPage }
    func inspect(_ preview: ResultComparisonValuePreview, title: String, encoding: String? = nil) async {
        selectedValue = preview; valueTitle = title; valueEncoding = encoding; valueOffsets = [0]; await loadValue(offset: 0)
    }
    func value(next: Bool) async {
        guard !isLoadingValue, let chunk = valueChunk else { return }
        if next { guard chunk.hasMore else { return }; valueOffsets.append(max(chunk.offset + 1, chunk.nextOffset - 3)) }
        else { guard valueOffsets.count > 1 else { return }; valueOffsets.removeLast() }
        await loadValue(offset: valueOffsets.last ?? 0)
    }
    var canPreviousValue: Bool { valueOffsets.count > 1 && !isLoadingValue }
    var valueText: ResultComparisonModel.TextWindow? { valueChunk?.data.flatMap(ResultComparisonModel.textWindow) }
    private func loadValue(offset: Int64) async {
        guard let backend, let jobID, let selectedValue else { return }
        let token = generation; valueGeneration = UUID(); let valueToken = valueGeneration
        isLoadingValue = true; defer { if valueGeneration == valueToken { isLoadingValue = false } }
        do {
            let reply = try await backend.request("value", .init(jobId: jobID, offset: offset, valueRef: selectedValue.valueRef))
            guard generation == token, valueGeneration == valueToken else { return }
            guard reply.jobId == jobID, reply.valid(for: "data.value.result"), let chunk = reply.value, chunk.valueRef == selectedValue.valueRef,
                  chunk.offset == offset, chunk.totalBytes == selectedValue.totalBytes, chunk.isNull == selectedValue.isNull else { throw BackendTransportError(.invalidMessage) }
            valueChunk = chunk
        } catch { if generation == token, valueGeneration == valueToken { self.error = "The exact value chunk could not be read." } }
    }
}

@MainActor
enum DataComparisonCredentials {
    static func promptID(_ profile: UUID, _ attempt: UUID) -> String { "data:\(profile):\(attempt)" }
    static func settings(_ profile: SavedConnection, store: any ConnectionCredentialStore, attempt: UUID) async throws -> ConnectionSettings {
        try Task.checkCancellation()
        let password = profile.passwordCommand == nil ? try await store.password(for: profile.id) ?? "" : ""
        try Task.checkCancellation(); var settings = profile.settings(password: password)
        if var ssh = settings.ssh {
            if ssh.authMethod == .password {
                ssh.password = try await store.secret(for: profile.id, purpose: .sshPassword); try Task.checkCancellation()
                if ssh.password == nil { ssh.password = try await SSHConnectionReview.requestSecret(passphrase: false, profileId: promptID(profile.id, attempt), configuration: ssh.configuration) }
            } else if ssh.authMethod == .privateKey {
                ssh.passphrase = try await store.secret(for: profile.id, purpose: .sshPassphrase); try Task.checkCancellation()
                if ssh.passphrase == nil { ssh.passphrase = try await SSHConnectionReview.requestSecret(passphrase: true, profileId: promptID(profile.id, attempt), configuration: ssh.configuration) }
            }
            settings.ssh = ssh
        }
        return settings
    }
}
