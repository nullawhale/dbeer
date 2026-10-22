import Combine
import Foundation

protocol ResultComparisonBackend: Sendable {
    func start(_ request: ResultComparisonRequest) async throws -> ResultComparisonResponse
    func request(_ operation: String, _ request: ResultComparisonRequest) async throws -> ResultComparisonResponse
    func shutdown() async
}

/// One explicitly requested offline comparison owns one helper. It never joins
/// the SQL workspace's helpers or creates a database connection.
actor ResultComparisonHelperBackend: ResultComparisonBackend {
    private let client: BackendClient
    init(client: BackendClient = BackendClient()) { self.client = client }

    func start(_ request: ResultComparisonRequest) async throws -> ResultComparisonResponse {
        try await client.start()
        return try await self.request("start", request)
    }

    func request(_ operation: String, _ request: ResultComparisonRequest) async throws -> ResultComparisonResponse {
        let reply = try await client.request(.compare(operation, request))
        guard let response = reply.comparison else { throw BackendTransportError(.invalidMessage) }
        return response
    }

    func shutdown() async { _ = await client.shutdown() }
}

@MainActor
final class ResultComparisonModel: ObservableObject {
    enum Phase: Equatable { case idle, starting, running, completed, cancelled, failed, closed }
    struct Mapping: Identifiable, Equatable {
        var left: Int
        var right: Int?
        var key = false
        var id: Int { left }
    }
    struct SelectedValue: Equatable {
        var preview: ResultComparisonValuePreview
        var title: String
        var encoding: String?
    }
    struct TextWindow: Equatable {
        var text: String
        var leadingBytes: Int
        var trailingBytes: Int
    }

    let snapshots: [ResultSnapshotSummary]
    private let store: ResultSnapshotStore
    private let backendFactory: @MainActor () -> any ResultComparisonBackend
    private let pollDelay: Duration
    private var backend: (any ResultComparisonBackend)?
    private var jobID: String?
    private var pollTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var valueGeneration: UInt64 = 0
    private var valueOffsets: [Int64] = [0]
    private var pageOffsets: [Int64] = [0]
    private var cellOffsets: [Int] = [0]
    private var activeMappings: [ResultComparisonColumnMapping] = []

    @Published private(set) var leftID: UUID?
    @Published private(set) var rightID: UUID?
    @Published private(set) var leftManifest: ResultSnapshotManifest?
    @Published private(set) var rightManifest: ResultSnapshotManifest?
    @Published private(set) var mode: ResultComparisonMode?
    @Published private(set) var mappings: [Mapping] = []
    @Published private(set) var phase = Phase.idle
    @Published private(set) var isLoadingConfiguration = false
    @Published private(set) var isLoadingPage = false
    @Published private(set) var isLoadingCells = false
    @Published private(set) var isLoadingValue = false
    @Published private(set) var isStopping = false
    @Published private(set) var error: String?
    @Published private(set) var summary: ResultComparisonSummary?
    @Published private(set) var page: ResultComparisonPage?
    @Published private(set) var selectedRow: ResultComparisonRow?
    @Published private(set) var selectedValue: SelectedValue?
    @Published private(set) var valueChunk: ResultComparisonValueChunk?
    @Published private(set) var valueError: String?

    init(store: ResultSnapshotStore, snapshots: [ResultSnapshotSummary],
         pollDelay: Duration = .milliseconds(150),
         backendFactory: @escaping @MainActor () -> any ResultComparisonBackend = { ResultComparisonHelperBackend() }) {
        self.store = store
        self.snapshots = snapshots.filter(\.isAvailable)
        self.pollDelay = pollDelay
        self.backendFactory = backendFactory
    }

    var isWorking: Bool { phase == .starting || phase == .running }
    var canConfigure: Bool { !isWorking && !isStopping && summary == nil && phase != .closed }
    var canStart: Bool { canConfigure && !isLoadingConfiguration && configurationProblem == nil }
    var canLoadPrevious: Bool { !isLoadingPage && pageOffsets.count > 1 }
    var canLoadNext: Bool { !isLoadingPage && page?.hasMore == true }
    var canLoadPreviousCells: Bool { !isLoadingCells && cellOffsets.count > 1 }
    var canLoadNextCells: Bool { !isLoadingCells && selectedRow?.cellsTruncated == true }
    var canLoadPreviousValue: Bool { !isLoadingValue && valueOffsets.count > 1 }
    var canLoadNextValue: Bool { !isLoadingValue && valueChunk?.hasMore == true }
    var requestedColumns: [ResultComparisonColumnMapping] {
        mappings.compactMap { mapping in mapping.right.map {
            ResultComparisonColumnMapping(left: mapping.left, right: $0, key: mode == .key && mapping.key ? true : nil)
        } }
    }
    var excludedLeft: [ResultColumn] { leftManifest?.columns.filter { column in !requestedColumns.contains { $0.left == column.index } } ?? [] }
    var excludedRight: [ResultColumn] { rightManifest?.columns.filter { column in !requestedColumns.contains { $0.right == column.index } } ?? [] }

    var configurationProblem: String? {
        guard leftID != nil && rightID != nil else { return "Select a left and a right saved snapshot." }
        guard leftManifest != nil && rightManifest != nil else { return "Read both snapshot manifests before comparing." }
        guard let mode else { return "Choose selected keys or explicitly choose saved row order." }
        let columns = requestedColumns
        guard !columns.isEmpty else { return "Map at least one column." }
        guard Set(columns.map(\.right)).count == columns.count else { return "Each right column can be mapped only once." }
        if mode == .key, !columns.contains(where: { $0.key == true }) { return "Select at least one mapped key column." }
        return nil
    }

    func configure(left: UUID?, right: UUID?) async {
        guard canConfigure else { return }
        generation &+= 1
        let token = generation
        leftID = left; rightID = right
        leftManifest = nil; rightManifest = nil; mappings = []; mode = nil
        error = nil; isLoadingConfiguration = true
        defer { if generation == token { isLoadingConfiguration = false } }
        do {
            let leftValue: ResultSnapshotManifest?
            if let left { leftValue = try await store.manifest(id: left) } else { leftValue = nil }
            guard generation == token else { return }
            let rightValue: ResultSnapshotManifest?
            if let right { rightValue = try await store.manifest(id: right) } else { rightValue = nil }
            guard generation == token else { return }
            leftManifest = leftValue; rightManifest = rightValue
            if let leftValue, let rightValue {
                mappings = leftValue.columns.map { Mapping(left: $0.index,
                    right: rightValue.columns.indices.contains($0.index) ? $0.index : nil) }
            }
        } catch {
            guard generation == token else { return }
            self.error = safeError(error)
        }
    }

    func setMode(_ value: ResultComparisonMode?) {
        guard canConfigure else { return }
        mode = value
        if value == .rowOrder { mappings = mappings.map { var copy = $0; copy.key = false; return copy } }
    }

    func setMapping(left: Int, right: Int?) {
        guard canConfigure, let index = mappings.firstIndex(where: { $0.left == left }),
              right == nil || rightManifest?.columns.indices.contains(right!) == true else { return }
        mappings[index].right = right
        if right == nil { mappings[index].key = false }
    }

    func setKey(left: Int, selected: Bool) {
        guard canConfigure, mode == .key, let index = mappings.firstIndex(where: { $0.left == left }),
              mappings[index].right != nil else { return }
        mappings[index].key = selected
    }

    func start() async {
        guard canStart, let leftID, let rightID, let mode else { return }
        generation &+= 1
        let token = generation
        clearOutput()
        activeMappings = requestedColumns
        phase = .starting
        let service = backendFactory()
        backend = service
        do {
            let reply = try await service.start(ResultComparisonRequest(left: .init(id: leftID), right: .init(id: rightID),
                mode: mode, columns: activeMappings))
            guard generation == token else { await dispose(service, job: reply.jobId); return }
            jobID = reply.jobId
            try await acceptStatus(reply, token: token)
            if isWorking { schedulePoll(token) }
        } catch { await fail(error, token: token) }
    }

    /// Exposed separately from the timer to keep lifecycle tests deterministic.
    func pollNow() async {
        guard isWorking, !isStopping, let backend, let jobID else { return }
        let token = generation
        do { try await acceptStatus(try await backend.request("status", .init(jobId: jobID)), token: token) }
        catch { await fail(error, token: token) }
    }

    func stop() async {
        guard isWorking, !isStopping else { return }
        generation &+= 1
        let token = generation
        pollTask?.cancel(); pollTask = nil
        isStopping = true
        let service = backend
        let job = jobID
        backend = nil; jobID = nil
        if let service { await dispose(service, job: job) }
        guard generation == token else { return }
        isStopping = false; phase = .cancelled
        error = nil
    }

    func reset() async {
        guard !isWorking, !isStopping, phase != .closed else { return }
        generation &+= 1
        let token = generation
        let service = backend; let job = jobID
        backend = nil; jobID = nil
        clearOutput(); phase = .idle
        if let service { await dispose(service, job: job) }
        guard generation == token else { return }
    }

    func close() async {
        generation &+= 1
        pollTask?.cancel(); pollTask = nil
        let service = backend; let job = jobID
        backend = nil; jobID = nil
        clearOutput(); phase = .closed; isStopping = false; isLoadingConfiguration = false
        if let service { await dispose(service, job: job) }
    }

    func loadNextPage() async {
        guard canLoadNext, let next = page?.nextOffset else { return }
        if await loadPage(offset: next) { pageOffsets.append(next) }
    }
    func loadPreviousPage() async {
        guard canLoadPrevious else { return }
        let previous = pageOffsets[pageOffsets.count - 2]
        if await loadPage(offset: previous) { pageOffsets.removeLast() }
    }

    func selectRow(_ row: ResultComparisonRow?) {
        selectedRow = row
        cellOffsets = [row?.cellOffset ?? 0]
        clearValue()
    }

    func loadNextCells() async {
        guard canLoadNextCells, let next = selectedRow?.nextCellOffset else { return }
        if await loadCells(offset: next) { cellOffsets.append(next) }
    }
    func loadPreviousCells() async {
        guard canLoadPreviousCells else { return }
        let previous = cellOffsets[cellOffsets.count - 2]
        if await loadCells(offset: previous) { cellOffsets.removeLast() }
    }

    func inspect(_ preview: ResultComparisonValuePreview, title: String, encoding: String?) async {
        clearValue()
        selectedValue = SelectedValue(preview: preview, title: title, encoding: encoding)
        _ = await loadValue(offset: 0)
    }
    func loadNextValue() async {
        guard canLoadNextValue, let next = valueChunk?.nextOffset else { return }
        if await loadValue(offset: next) { valueOffsets.append(next) }
    }
    func loadPreviousValue() async {
        guard canLoadPreviousValue else { return }
        let previous = valueOffsets[valueOffsets.count - 2]
        if await loadValue(offset: previous) { valueOffsets.removeLast() }
    }

    var valueTextWindow: TextWindow? { valueChunk?.data.flatMap(Self.textWindow) }

    /// Adjacent value chunks overlap by three bytes. Trim only incomplete edge
    /// scalars, so bounded text windows remain readable and every scalar can be
    /// read on a neighboring page. Base64 always exposes the exact chunk bytes.
    static func textWindow(_ bytes: Data) -> TextWindow? {
        for leading in 0...min(3, bytes.count) {
            for trailing in 0...min(3, bytes.count - leading) {
                let slice = bytes.dropFirst(leading).dropLast(trailing)
                if let text = String(data: slice, encoding: .utf8) {
                    return TextWindow(text: text, leadingBytes: leading, trailingBytes: trailing)
                }
            }
        }
        return nil
    }

    func column(mapping: Int, left: Bool) -> ResultColumn? {
        let columns = activeMappings.isEmpty ? requestedColumns : activeMappings
        guard columns.indices.contains(mapping) else { return nil }
        let index = left ? columns[mapping].left : columns[mapping].right
        return (left ? leftManifest : rightManifest)?.columns.first { $0.index == index }
    }

    private func acceptStatus(_ reply: ResultComparisonResponse, token: UInt64) async throws {
        guard generation == token else { return }
        switch reply.state {
        case .pending, .running: phase = .running
        case .completed:
            guard let summary = reply.summary,
                  !summary.complete || leftManifest?.isComplete == true && rightManifest?.isComplete == true else {
                throw BackendTransportError(.invalidMessage)
            }
            self.summary = summary; phase = .completed
            pollTask?.cancel(); pollTask = nil
            _ = await loadPage(offset: 0)
        case .cancelled: phase = .cancelled
        case .failed: throw ComparisonFailure(message: reply.message ?? "The snapshots could not be compared.")
        case .closed: throw BackendTransportError(.invalidMessage)
        }
    }

    private func schedulePoll(_ token: UInt64) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, generation == token, isWorking, !Task.isCancelled {
                do { try await Task.sleep(for: pollDelay) } catch { return }
                guard generation == token, !Task.isCancelled else { return }
                await pollNow()
            }
        }
    }

    @discardableResult
    private func loadPage(offset: Int64) async -> Bool {
        guard phase == .completed, !isLoadingPage, let backend, let jobID else { return false }
        let token = generation
        isLoadingPage = true
        defer { if generation == token { isLoadingPage = false } }
        do {
            let reply = try await backend.request("page", .init(jobId: jobID, offset: offset, limit: 100, maxBytes: 262_144))
            guard generation == token else { return false }
            guard let page = reply.page, validMappings(page) else { throw BackendTransportError(.invalidMessage) }
            self.page = page; selectRow(page.rows.first); error = nil
            return true
        } catch {
            guard generation == token else { return false }
            self.error = safeError(error)
            return false
        }
    }

    private func loadCells(offset: Int) async -> Bool {
        guard phase == .completed, !isLoadingCells, let selectedRow, let backend, let jobID else { return false }
        let token = generation
        isLoadingCells = true
        defer { if generation == token { isLoadingCells = false } }
        do {
            let reply = try await backend.request("page", .init(jobId: jobID, offset: selectedRow.index,
                limit: 1, maxBytes: 262_144, cellOffset: offset))
            guard generation == token, self.selectedRow?.index == selectedRow.index else { return false }
            guard let page = reply.page, validMappings(page), let row = page.rows.first else {
                throw BackendTransportError(.invalidMessage)
            }
            self.selectedRow = row; clearValue(); error = nil
            return true
        } catch {
            guard generation == token else { return false }
            self.error = safeError(error)
            return false
        }
    }

    private func loadValue(offset: Int64) async -> Bool {
        guard phase == .completed, !isLoadingValue, let selectedValue, let backend, let jobID else { return false }
        let token = generation; let valueToken = valueGeneration
        isLoadingValue = true; valueError = nil
        defer { if generation == token, valueGeneration == valueToken { isLoadingValue = false } }
        do {
            let reply = try await backend.request("value", .init(jobId: jobID, offset: max(0, offset - 3),
                maxBytes: offset == 0 ? 65_536 : 65_539, valueRef: selectedValue.preview.valueRef))
            guard generation == token, valueGeneration == valueToken else { return false }
            guard let value = reply.value, value.isNull == selectedValue.preview.isNull,
                  value.totalBytes == selectedValue.preview.totalBytes,
                  !value.hasMore || value.nextOffset > offset else { throw BackendTransportError(.invalidMessage) }
            valueChunk = value
            return true
        } catch {
            guard generation == token, valueGeneration == valueToken else { return false }
            valueError = safeError(error)
            return false
        }
    }

    private func validMappings(_ page: ResultComparisonPage) -> Bool {
        page.rows.allSatisfy { $0.totalCells == activeMappings.count && $0.cells.allSatisfy { activeMappings.indices.contains($0.mapping) } }
    }

    private func fail(_ failure: Error, token: UInt64) async {
        guard generation == token else { return }
        pollTask?.cancel(); pollTask = nil
        let service = backend; let job = jobID
        backend = nil; jobID = nil
        clearOutput(); phase = .failed; error = safeError(failure)
        if let service { await dispose(service, job: job) }
    }

    private func clearOutput() {
        summary = nil; page = nil; selectedRow = nil; error = nil
        isLoadingPage = false; isLoadingCells = false
        pageOffsets = [0]; cellOffsets = [0]
        clearValue()
    }
    private func clearValue() {
        valueGeneration &+= 1
        selectedValue = nil; valueChunk = nil; valueError = nil
        isLoadingValue = false; valueOffsets = [0]
    }
    private func dispose(_ service: any ResultComparisonBackend, job: String?) async {
        if let job {
            let cleanup = Task {
                _ = try? await service.request("cancel", .init(jobId: job))
                _ = try? await service.request("close", .init(jobId: job))
            }
            // Shutdown has its own bounded process deadline. Start it even if
            // a broken helper never answers the ordinary cancel/close command.
            let deadline = Task {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                await service.shutdown()
            }
            await cleanup.value
            deadline.cancel()
        }
        await service.shutdown()
    }
    private func safeError(_ error: Error) -> String {
        if error is BackendTransportError || error is BackendRemoteError || error is ResultSnapshotError || error is ComparisonFailure {
            return error.localizedDescription
        }
        return "The saved snapshots could not be compared. Close this comparison and try again."
    }
    private struct ComparisonFailure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}
