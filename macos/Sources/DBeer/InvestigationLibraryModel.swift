import Combine
import Foundation

/// Durable investigation ownership is independent of workspace tabs. Saved
/// records survive tab closure, and their references remain protected until a
/// successful whole-library publication replaces them.
@MainActor
final class InvestigationLibraryModel: ObservableObject {
    @Published private(set) var documents: [StoredInvestigation] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var error: String?
    private let store: any InvestigationStore
    private let snapshotStore: ResultSnapshotStore
    private let autosaveDelay: Duration?
    private var persisted: [StoredInvestigation] = []
    private var order: [UUID] = []
    private var models: [UUID: InvestigationDocumentModel] = [:]
    private var autosaves: [UUID: Task<Void, Never>] = [:]
    private var restoreTask: Task<Void, Never>?
    private var saveTask: Task<Bool, Never>?
    private var saveToken: UUID?

    init(store: any InvestigationStore = FileInvestigationStore(),
         snapshotStore: ResultSnapshotStore = ResultSnapshotStore(), autosaveDelay: Duration? = .milliseconds(400)) {
        self.store = store
        self.snapshotStore = snapshotStore
        self.autosaveDelay = autosaveDelay
    }

    func restore() async {
        guard !isLoaded else { return }
        if let restoreTask { await restoreTask.value; return }
        let task = Task { @MainActor [self] in
            isLoading = true
            defer { isLoading = false }
            do {
                let saved = try await store.load()
                guard saved.isValid else { throw InvestigationStoreError.read }
                persisted = saved.documents
                order = saved.documents.map(\.id)
                isLoaded = true
                error = nil
                refreshDocuments()
            } catch {
                self.error = InvestigationStoreError.read.localizedDescription
            }
        }
        restoreTask = task
        await task.value
        restoreTask = nil
    }

    @discardableResult
    func create(title: String = "Investigation") -> InvestigationDocumentModel? {
        guard isLoaded, !isLoading, order.count < InvestigationLimits.maximumDocuments else {
            error = InvestigationStoreError.notLoaded.localizedDescription
            return nil
        }
        let stored = StoredInvestigation(title: title)
        guard stored.isValid else { error = InvestigationStoreError.invalid.localizedDescription; return nil }
        let model = makeModel(stored)
        models[model.id] = model
        order.append(model.id)
        model.markNew()
        refreshDocuments()
        return model
    }

    /// Returns one live mutable owner for an investigation identity. A missing
    /// reference throws; it never creates or saves an empty replacement.
    func openDocument(id: UUID) throws -> InvestigationDocumentModel {
        guard isLoaded, !isLoading else { throw InvestigationStoreError.notLoaded }
        if let model = models[id] { return model }
        guard let stored = persisted.first(where: { $0.id == id }) else { throw InvestigationStoreError.notFound }
        let model = makeModel(stored)
        models[id] = model
        return model
    }

    func document(id: UUID) -> InvestigationDocumentModel? { models[id] }

    /// Closing a saved parent releases all transient child identities. Reopen
    /// reconstructs fresh disconnected children from the durable block IDs.
    @discardableResult
    func releaseDocument(_ id: UUID) -> Bool {
        guard let model = models[id] else { return true }
        guard !model.isDirty, !model.isSaving,
              model.allSQLDocuments.allSatisfy({ !$0.isRunning && ($0.runtime == nil || $0.runtime?.canEditConnection == true) }) else {
            return false
        }
        autosaves.removeValue(forKey: id)?.cancel()
        model.didChange = nil
        models.removeValue(forKey: id)
        refreshDocuments()
        return true
    }

    func referencingInvestigations(snapshotID: UUID) throws -> Set<UUID> {
        guard isLoaded, !isLoading else { throw InvestigationStoreError.notLoaded }
        var references = Set(persisted.filter { record in
            record.blocks.contains { $0.kind == .snapshot && $0.snapshotID == snapshotID }
        }.map(\.id))
        for model in models.values where model.storedState.blocks.contains(where: {
            $0.kind == .snapshot && $0.snapshotID == snapshotID
        }) { references.insert(model.id) }
        return references
    }

    @discardableResult
    func saveInvestigation(_ id: UUID) async -> Bool {
        guard isLoaded, models[id]?.isAvailable == true else {
            error = InvestigationStoreError.notLoaded.localizedDescription
            return false
        }
        autosaves.removeValue(forKey: id)?.cancel()
        return await enqueue { [weak self] in await self?.saveCurrent(requiredIDs: [id]) ?? false }
    }

    /// Commit a complete document with the block omitted before removing its
    /// live owner. Runtime lifecycle decisions must have completed first.
    @discardableResult
    func saveRemovingBlock(in id: UUID, blockID: UUID) async -> Bool {
        guard isLoaded, let model = models[id], model.isAvailable,
              model.canRemoveBlockAfterLifecycle(blockID) else { return false }
        autosaves.removeValue(forKey: id)?.cancel()
        return await enqueue { [weak self] in
            guard let self else { return false }
            return await self.saveCurrent(requiredIDs: [id], removal: (id, blockID))
        }
    }

    @discardableResult
    func flush() async -> Bool {
        // Unavailable reference tabs have no editable model to flush. Closing
        // or quitting must not create a replacement for an unreadable library.
        guard isLoaded else { return models.values.allSatisfy { !$0.isAvailable || !$0.isDirty } }
        for task in autosaves.values { task.cancel() }
        autosaves.removeAll()
        return await enqueue { [weak self] in
            guard let self else { return false }
            return await self.saveCurrent(requiredIDs: Set(self.models.keys))
        }
    }

    private func makeModel(_ stored: StoredInvestigation) -> InvestigationDocumentModel {
        let model = InvestigationDocumentModel(stored: stored, snapshotStore: snapshotStore)
        model.didChange = { [weak self, weak model] in
            guard let self, let model else { return }
            self.refreshDocuments()
            self.scheduleSave(model.id)
        }
        return model
    }

    private func refreshDocuments() {
        documents = order.compactMap { id in models[id]?.storedState ?? persisted.first { $0.id == id } }
    }

    private func scheduleSave(_ id: UUID) {
        guard let autosaveDelay else { return }
        autosaves[id]?.cancel()
        autosaves[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: autosaveDelay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.autosaves[id] = nil
            _ = await self.saveInvestigation(id)
        }
    }

    /// Queue at the library level rather than relying on a reentrant store
    /// actor. Every write starts from the preceding write's acknowledged state.
    private func enqueue(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
        let predecessor = saveTask
        let token = UUID()
        let task = Task { @MainActor in
            if let predecessor { _ = await predecessor.value }
            return await operation()
        }
        saveToken = token
        saveTask = task
        let result = await task.value
        if saveToken == token { saveTask = nil; saveToken = nil }
        return result
    }

    private func saveCurrent(requiredIDs: Set<UUID>, removal: (documentID: UUID, blockID: UUID)? = nil) async -> Bool {
        isSaving = true
        defer {
            isSaving = false
            for model in models.values { model.setSaving(false) }
        }
        while true {
            if let removal, models[removal.documentID]?.canRemoveBlockAfterLifecycle(removal.blockID) != true { return false }
            let revisions = models.mapValues(\.revision)
            var records = order.compactMap { id in models[id]?.storedState ?? persisted.first { $0.id == id } }
            if let removal {
                guard let index = records.firstIndex(where: { $0.id == removal.documentID }),
                      records[index].blocks.contains(where: { $0.id == removal.blockID }) else { return false }
                records[index].blocks.removeAll { $0.id == removal.blockID }
                records[index].updatedAt = max(records[index].createdAt, .now)
            }
            let snapshot = StoredInvestigations(documents: records)
            for model in models.values { model.setSaving(true) }
            do {
                guard snapshot.isValid else { throw InvestigationStoreError.invalid }
                try await store.save(snapshot)
                persisted = snapshot.documents
                error = nil
                for (id, revision) in revisions where id != removal?.documentID {
                    models[id]?.acknowledgeSave(revision: revision)
                }
                if let removal, let model = models[removal.documentID] {
                    // An edit during publication requires another complete
                    // candidate. It cannot be acknowledged by an older write.
                    if model.revision != revisions[removal.documentID] { refreshDocuments(); continue }
                    guard model.removeBlockAfterLifecycle(removal.blockID) else {
                        // Lifecycle ownership changed while the store awaited.
                        // Restore the persisted record before reporting failure.
                        model.markNew()
                        _ = await saveCurrent(requiredIDs: [removal.documentID])
                        model.reportSaveError("The SQL block became active before deletion completed.")
                        return false
                    }
                    autosaves.removeValue(forKey: removal.documentID)?.cancel()
                    model.acknowledgeSave(revision: model.revision,
                        updatedAt: records.first(where: { $0.id == removal.documentID })?.updatedAt)
                }
                refreshDocuments()
                if requiredIDs.contains(where: { models[$0]?.isDirty == true }) { continue }
                return true
            } catch {
                let message = error is InvestigationStoreError ? error.localizedDescription
                    : InvestigationStoreError.write.localizedDescription
                self.error = message
                for id in requiredIDs { models[id]?.reportSaveError(message) }
                refreshDocuments()
                return false
            }
        }
    }
}
