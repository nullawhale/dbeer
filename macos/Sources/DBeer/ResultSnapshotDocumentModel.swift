import Combine
import Foundation

/// An offline document reads an immutable local artifact one bounded page at a
/// time. It owns neither a helper nor a connection, and never replays its SQL.
@MainActor
final class ResultSnapshotDocumentModel: ObservableObject {
    static let defaultPageSize = 200

    let snapshotID: UUID
    let pageSize: Int
    private let store: ResultSnapshotStore
    private var readGeneration: UInt64 = 0
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    @Published private(set) var manifest: ResultSnapshotManifest?
    @Published private(set) var result: BackendMessage?
    @Published private(set) var pageIndex = 0
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    init(id: UUID, store: ResultSnapshotStore, pageSize: Int = ResultSnapshotDocumentModel.defaultPageSize) {
        precondition((1...ResultSnapshotStore.maximumPageSize).contains(pageSize))
        snapshotID = id
        self.store = store
        self.pageSize = pageSize
    }

    var pageCount: Int {
        guard let count = manifest?.rowCount, count > 0 else { return 1 }
        return 1 + (count - 1) / pageSize
    }

    var pageOffset: Int { pageIndex * pageSize }
    var isAvailable: Bool { result != nil && error == nil && !isLoading }
    var canLoadPrevious: Bool { !isLoading && isAvailable && pageIndex > 0 }
    var canLoadNext: Bool { !isLoading && isAvailable && pageIndex + 1 < pageCount }

    func load() async { await loadPage(0) }

    /// Revisiting a cached block verifies its current page against local disk.
    /// Remove the old rows immediately, including when an earlier read is
    /// finishing, without changing the user's page or readable provenance.
    func revalidateCurrentPage() async {
        readGeneration &+= 1
        result = nil
        error = nil
        if isLoading {
            await withCheckedContinuation { readWaiters.append($0) }
        }
        await loadPage(pageIndex)
    }

    func usesStore(_ candidate: ResultSnapshotStore) -> Bool { store === candidate }

    /// A confirmed deletion must invalidate hidden blocks too. The generation
    /// fence prevents an earlier local read from publishing its now-stale rows.
    func invalidateArtifact(_ reason: ResultSnapshotError) {
        readGeneration &+= 1
        result = nil
        error = reason.localizedDescription
    }

    func loadPage(_ index: Int) async {
        guard !isLoading, index >= 0 else { return }
        // An invalid navigation request cannot clear a successfully loaded
        // page or overflow the offset arithmetic.
        if manifest != nil, index >= pageCount { return }
        let (offset, overflow) = index.multipliedReportingOverflow(by: pageSize)
        guard !overflow else { return }
        isLoading = true
        error = nil
        let generation = readGeneration
        defer {
            isLoading = false
            let waiters = readWaiters
            readWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        do {
            let metadata = try await store.manifest(id: snapshotID)
            guard generation == readGeneration else { return }
            // Artifact IDs are immutable. A changed manifest must not make a
            // previously loaded page appear valid under different metadata.
            if let manifest, manifest != metadata { throw ResultSnapshotError.corrupt }
            manifest = metadata
            guard index < pageCount else { return }
            let artifact = try await store.load(id: snapshotID, offset: offset, limit: pageSize)
            guard generation == readGeneration else { return }
            guard artifact.manifest == metadata else { throw ResultSnapshotError.corrupt }
            manifest = artifact.manifest
            pageIndex = index
            result = Self.displayResult(artifact)
        } catch {
            guard generation == readGeneration else { return }
            // Keep readable provenance when only the rows are damaged. No
            // stale page may appear to be an available immutable snapshot.
            result = nil
            self.error = error is ResultSnapshotError ? error.localizedDescription
                : error is CancellationError ? "Loading the snapshot was cancelled."
                : "This snapshot could not be read from local storage."
        }
    }

    private static func displayResult(_ artifact: ResultSnapshotArtifact) -> BackendMessage {
        let metadata = artifact.manifest
        // This is a local presentation value, not a helper protocol reply.
        // Session and query IDs stay absent so it cannot look connected.
        return BackendMessage(type: "snapshot.result", requestId: metadata.id.uuidString,
            engine: metadata.engine, columns: metadata.columns, rows: artifact.rows,
            commandTag: metadata.commandTag,
            rowCount: metadata.sourceRowCount ?? Int64(metadata.rowCount),
            displayedRowCount: artifact.rows.count, truncated: metadata.truncated,
            displayNotice: metadata.isComplete ? nil : "This snapshot contains a partial or truncated result.")
    }
}
