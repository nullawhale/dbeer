import Combine
import Foundation

/// Local immutable artifacts only; this owner never requests status or opens a connection.
@MainActor
final class SavedEvidenceModel: ObservableObject {
    let store: PlanArtifactStore
    @Published private(set) var artifacts: [SavedEvidenceSummary] = []
    @Published private(set) var links: [EvidenceSnapshotLink] = []
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var isBusy = false {
        didSet {
            if !isBusy { let waiters = idleWaiters; idleWaiters = []; for waiter in waiters { waiter.resume() } }
        }
    }
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var investigationReferences: @MainActor (UUID) async throws -> Set<UUID> = { _ in throw InvestigationStoreError.notLoaded }
    init(store: PlanArtifactStore) { self.store = store }
    func waitForPendingWork() async { if isBusy { await withCheckedContinuation { idleWaiters.append($0) } } }

    func refresh() async {
        guard !isBusy else { return }; isBusy = true; defer { isBusy = false }
        do { try await reload(); error = nil } catch { report(error) }
    }
    @discardableResult func save(_ value: SavedEvidenceArtifact) async -> SavedEvidenceArtifact? {
        guard !isBusy else { return nil }; isBusy = true; defer { isBusy = false }
        do {
            let saved = try await store.saveEvidence(value)
            acknowledge(saved); notice = "Evidence saved to the local library."
            do { try await reload(); error = nil }
            catch { self.error = "Evidence was saved, but the local library could not be refreshed." }
            return saved
        } catch { report(error); return nil }
    }
    @discardableResult func importFile(_ url: URL) async -> Bool {
        guard !isBusy else { return false }; isBusy = true; defer { isBusy = false }
        do {
            let value = try await store.importEvidence(from: url); acknowledge(value)
            do { try await reload(); error = nil }
            catch { self.error = "Evidence was imported, but the local library could not be refreshed." }
            return true
        } catch { report(error); return false }
    }
    @discardableResult func exportFile(_ reference: SavedEvidenceReference, to url: URL,
                                      reviewedVersion: SQLFileVersion?, parent: SQLFileIdentity) async -> Bool {
        guard !isBusy else { return false }; isBusy = true; defer { isBusy = false }
        do {
            let value = try await store.loadEvidence(reference.id, kind: reference.kind)
            _ = try SQLFileBinding.write(value.encoded(), to: url, expectedVersion: reviewedVersion,
                expectedParent: parent, maximumBytes: SavedEvidenceArtifact.maximumBytes)
            error = nil; return true
        } catch { report(error); return false }
    }
    @discardableResult func delete(_ id: UUID) async -> Bool {
        guard !isBusy else { return false }; isBusy = true; defer { isBusy = false }
        do {
            let references = try await investigationReferences(id)
            try await store.deleteEvidence(id: id, investigationIDs: references)
            artifacts.removeAll { $0.id == id }; revision &+= 1
            do { try await reload(); error = nil }
            catch { self.error = "Evidence was deleted, but the local library could not be refreshed." }
            return true
        } catch { report(error); return false }
    }
    @discardableResult func attach(_ reference: SavedEvidenceReference, snapshotID: UUID,
                                   snapshotStore: ResultSnapshotStore) async -> Bool {
        guard !isBusy else { return false }; isBusy = true; defer { isBusy = false }
        do {
            _ = try await snapshotStore.manifest(id: snapshotID)
            try await store.attachEvidence(reference, snapshotID: snapshotID)
            do { _ = try await snapshotStore.manifest(id: snapshotID) }
            catch { try await store.detachEvidence(reference, snapshotID: snapshotID); throw error }
            try await reload(); error = nil; return true
        } catch { report(error); return false }
    }
    @discardableResult func detach(_ reference: SavedEvidenceReference, snapshotID: UUID) async -> Bool {
        guard !isBusy else { return false }; isBusy = true; defer { isBusy = false }
        do { try await store.detachEvidence(reference, snapshotID: snapshotID); try await reload(); error = nil; return true }
        catch { report(error); return false }
    }
    func snapshotDeleted(_ id: UUID) async {
        do { try await store.removeSnapshotLinks(id); try await reload() }
        catch { self.error = "The snapshot was deleted, but its evidence links could not be refreshed. Remove retained links before deleting evidence." }
    }
    func captureFailed() { notice = nil; error = "No valid retained evidence is available to save." }
    private func acknowledge(_ value: SavedEvidenceArtifact) {
        artifacts.removeAll { $0.id == value.id }; artifacts.append(.init(value)); revision &+= 1
    }
    private func reload() async throws {
        artifacts = try await store.listEvidence(); links = try await store.evidenceLinks(); revision &+= 1
    }
    private func report(_ error: Error) {
        notice = nil
        if (error as? PlanArtifactError) == .referenced { self.error = "This evidence is referenced by a snapshot or investigation. Remove its links before deleting it." }
        else if (error as? PlanArtifactError) == .quota { self.error = "The shared saved-evidence quota is full. Delete unneeded artifacts explicitly." }
        else if let file = error as? SQLFileBindingError, file.recoveryURL != nil { self.error = file.localizedDescription }
        else { self.error = "The saved evidence could not be updated. Existing files were left unchanged." }
    }
}

enum SavedEvidenceLink {
    static func url(_ reference: SavedEvidenceReference) -> URL {
        URL(string: "dbeer-evidence://" + reference.id.uuidString.lowercased() + "/" + reference.kind.rawValue)!
    }
    static func reference(from url: URL) -> SavedEvidenceReference? {
        guard url.scheme == "dbeer-evidence", url.query == nil, url.fragment == nil, url.user == nil,
              url.password == nil, url.port == nil, let host = url.host, let id = UUID(uuidString: host),
              host == id.uuidString.lowercased(), let kind = SavedEvidenceKind(rawValue: String(url.path.dropFirst())) else { return nil }
        let value = SavedEvidenceReference(kind: kind, id: id)
        return url.absoluteString == Self.url(value).absoluteString ? value : nil
    }
    static func markdown(_ reference: SavedEvidenceReference, title: String) -> String {
        let escaped = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return "[\(escaped)](\(url(reference).absoluteString))"
    }
    static func references(in text: String) -> Set<SavedEvidenceReference> {
        guard let rendered = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full)) else { return [] }
        return Set(rendered.runs.compactMap { $0.link.flatMap(reference(from:)) })
    }
}
