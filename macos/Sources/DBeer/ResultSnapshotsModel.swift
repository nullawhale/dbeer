import Combine
import Foundation

/// Snapshot management owns local artifacts only. Refreshing or deleting this
/// list never creates a database session or replays a captured statement.
@MainActor
final class ResultSnapshotsModel: ObservableObject {
    private final class DocumentReference {
        weak var model: ResultSnapshotDocumentModel?
        init(_ model: ResultSnapshotDocumentModel) { self.model = model }
    }

    struct DeletionRequest: Identifiable {
        let snapshot: ResultSnapshotSummary
        let investigationIDs: Set<UUID>
        var id: UUID { snapshot.id }
    }

    static let bytesPerMiB: Int64 = 1_048_576
    let store: ResultSnapshotStore
    @Published private(set) var snapshots: [ResultSnapshotSummary] = []
    @Published private(set) var usedBytes: Int64 = 0
    @Published private(set) var quotaBytes = ResultSnapshotStore.defaultQuotaBytes
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    private var displayedDocuments: [ObjectIdentifier: DocumentReference] = [:]

    /// R18 supplies the current document references here. Recheck at deletion
    /// time so references created after the alert cannot be deleted implicitly.
    var investigationReferences: @MainActor (UUID) throws -> Set<UUID>

    init(store: ResultSnapshotStore = ResultSnapshotStore(),
         investigationReferences: @escaping @MainActor (UUID) throws -> Set<UUID> = { _ in [] }) {
        self.store = store
        self.investigationReferences = investigationReferences
    }

    /// Keep weak registrations after a block unmounts, so explicit deletion
    /// invalidates its cache without making presentation own document lifetime.
    func trackDocument(_ model: ResultSnapshotDocumentModel) {
        guard model.usesStore(store) else { return }
        displayedDocuments = displayedDocuments.filter { $0.value.model != nil }
        displayedDocuments[ObjectIdentifier(model)] = DocumentReference(model)
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            try await store.cleanup()
            try await reload()
        } catch { report(error) }
    }

    @discardableResult
    func save(_ capture: ResultSnapshotCapture) async -> ResultSnapshotSummary? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            let saved = try await store.save(capture)
            try await reload()
            return saved
        } catch { report(error); return nil }
    }

    @discardableResult
    func updateQuotaBytes(_ value: Int64) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            try await store.setQuotaBytes(value)
            try await reload()
            return true
        } catch { report(error); return false }
    }

    func requestDeletion(_ id: UUID) -> DeletionRequest? {
        guard !isBusy, let snapshot = snapshots.first(where: { $0.id == id }) else { return nil }
        do {
            let references = try investigationReferences(id)
            error = nil
            return DeletionRequest(snapshot: snapshot, investigationIDs: references)
        } catch {
            reportReferenceLookupFailure()
            return nil
        }
    }

    @discardableResult
    func deleteConfirmed(_ request: DeletionRequest) async -> Bool {
        guard !isBusy else { return false }
        let references: Set<UUID>
        do { references = try investigationReferences(request.id) }
        catch { reportReferenceLookupFailure(); return false }
        guard references.isSubset(of: request.investigationIDs) else {
            error = "This snapshot has new investigation references. Review deletion again."
            return false
        }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            try await store.delete(id: request.id, referencedBy: Array(references), confirmation: true)
            for model in trackedDocuments where model.snapshotID == request.id { model.invalidateArtifact(.notFound) }
            try await reload()
            return true
        } catch { report(error); return false }
    }

    static func quotaBytes(fromMiB text: String) -> Int64? {
        guard let value = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return nil }
        let (bytes, overflow) = value.multipliedReportingOverflow(by: bytesPerMiB)
        return overflow ? nil : bytes
    }

    static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    private func reload() async throws {
        let listed = try await store.list()
        let usage = try await store.usage()
        snapshots = listed
        usedBytes = usage.usedBytes
        quotaBytes = usage.quotaBytes
        let inventory = Dictionary(uniqueKeysWithValues: listed.map { ($0.id, $0) })
        for model in trackedDocuments {
            if let summary = inventory[model.snapshotID] {
                if !summary.isAvailable { model.invalidateArtifact(.corrupt) }
            } else { model.invalidateArtifact(.notFound) }
        }
    }

    private var trackedDocuments: [ResultSnapshotDocumentModel] {
        displayedDocuments = displayedDocuments.filter { $0.value.model != nil }
        return displayedDocuments.values.compactMap(\.model)
    }

    private func report(_ error: Error) {
        self.error = error is ResultSnapshotError ? error.localizedDescription : "Result snapshots could not be updated."
    }

    private func reportReferenceLookupFailure() {
        error = "Investigation references could not be checked. Resolve the local investigation library error before deleting snapshots."
    }
}
