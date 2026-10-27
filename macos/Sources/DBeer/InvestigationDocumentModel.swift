import Combine
import Foundation

/// Blocks own independent, process-local SQL documents. Stable block IDs are
/// persistence identities only and are never reused as session/editor IDs.
@MainActor
final class InvestigationDocumentModel: ObservableObject, Identifiable {
    let id: UUID
    let createdAt: Date
    @Published var title: String {
        didSet { if !title.utf8.elementsEqual(oldValue.utf8) { changed() } }
    }
    @Published private(set) var blocks: [StoredInvestigationBlock]
    @Published var selectedBlockID: UUID?
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var isDirty = false
    @Published private(set) var isSaving = false
    @Published private(set) var error: String?
    let unavailableReason: String?
    private var updatedAt: Date
    private var savedRevision: UInt64 = 0
    private var sqlDocuments: [UUID: SQLDocument] = [:]
    private var sqlObservations: [UUID: [AnyCancellable]] = [:]
    private var snapshotModels: [UUID: ResultSnapshotDocumentModel] = [:]
    private let snapshotStore: ResultSnapshotStore
    var didChange: (@MainActor () -> Void)?

    init(stored: StoredInvestigation, snapshotStore: ResultSnapshotStore = ResultSnapshotStore()) {
        id = stored.id
        title = stored.title
        createdAt = stored.createdAt
        updatedAt = stored.updatedAt
        blocks = stored.blocks
        selectedBlockID = stored.blocks.first?.id
        unavailableReason = nil
        self.snapshotStore = snapshotStore
        for block in stored.blocks where block.kind == .sql { installSQLDocument(for: block) }
    }

    init(unavailableID: UUID, title: String, reason: String,
         snapshotStore: ResultSnapshotStore = ResultSnapshotStore()) {
        id = unavailableID
        self.title = title
        let date = Date.now
        createdAt = date
        updatedAt = date
        blocks = []
        unavailableReason = reason
        self.snapshotStore = snapshotStore
    }

    var isAvailable: Bool { unavailableReason == nil }
    var selectedBlock: StoredInvestigationBlock? { blocks.first { $0.id == selectedBlockID } }
    var selectedSQLDocument: SQLDocument? { selectedBlockID.flatMap(sqlDocument(for:)) }
    var allSQLDocuments: [SQLDocument] { blocks.compactMap { sqlDocument(for: $0.id) } }
    var childSQLDocuments: [SQLDocument] { allSQLDocuments }
    var selectedSnapshotDocument: ResultSnapshotDocumentModel? { selectedBlockID.flatMap(snapshotModel(for:)) }

    /// Read every child directly at the save boundary, including the currently
    /// edited block. No selected-block or workspace snapshot can substitute.
    var storedState: StoredInvestigation {
        var current = blocks
        for index in current.indices {
            guard let child = sqlDocuments[current[index].id], current[index].kind == .sql else { continue }
            current[index].text = child.text
            current[index].profileID = child.profileID
        }
        return StoredInvestigation(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, blocks: current)
    }

    func sqlDocument(for blockID: UUID) -> SQLDocument? {
        guard blocks.contains(where: { $0.id == blockID && $0.kind == .sql }) else { return nil }
        return sqlDocuments[blockID]
    }

    func blockID(for document: SQLDocument) -> UUID? {
        blocks.first { $0.kind == .sql && sqlDocuments[$0.id] === document }?.id
    }

    func snapshotModel(for blockID: UUID) -> ResultSnapshotDocumentModel? {
        guard let block = blocks.first(where: { $0.id == blockID && $0.kind == .snapshot }),
              let snapshotID = block.snapshotID else { return nil }
        if let existing = snapshotModels[blockID] { return existing }
        let model = ResultSnapshotDocumentModel(id: snapshotID, store: snapshotStore)
        snapshotModels[blockID] = model
        return model
    }

    func selectBlock(_ id: UUID?) {
        guard id == nil || blocks.contains(where: { $0.id == id }) else { return }
        selectedBlockID = id
    }

    @discardableResult
    func addMarkdown(text: String = "") -> UUID? { insert(StoredInvestigationBlock(kind: .markdown, text: text)) }

    @discardableResult
    func addSQL(text: String = "", profileID: UUID? = nil) -> UUID? {
        insert(StoredInvestigationBlock(kind: .sql, text: text, profileID: profileID))
    }

    @discardableResult
    func addSnapshot(id: UUID, explanation: String = "") -> UUID? {
        insert(StoredInvestigationBlock(kind: .snapshot, snapshotID: id, explanation: explanation))
    }

    func setText(_ text: String, for blockID: UUID) {
        guard isAvailable, let index = blocks.firstIndex(where: { $0.id == blockID }),
              blocks[index].kind != .snapshot, !blocks[index].text.utf8.elementsEqual(text.utf8) else { return }
        if let sql = sqlDocument(for: blockID) { sql.text = text }
        else { blocks[index].text = text; changed() }
    }

    @discardableResult
    func setProfileID(_ profileID: UUID?, for blockID: UUID) -> Bool {
        guard isAvailable, let child = sqlDocument(for: blockID), !child.isRunning,
              child.runtime == nil || child.runtime?.canEditConnection == true else { return false }
        child.profileID = profileID
        return true
    }

    func setExplanation(_ text: String, for blockID: UUID) {
        guard isAvailable, let index = blocks.firstIndex(where: { $0.id == blockID && $0.kind == .snapshot }),
              !blocks[index].explanation.utf8.elementsEqual(text.utf8) else { return }
        blocks[index].explanation = text
        changed()
    }

    func moveBlock(_ blockID: UUID, by offset: Int) {
        guard isAvailable, let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let (destination, overflow) = index.addingReportingOverflow(offset)
        guard !overflow, blocks.indices.contains(destination), destination != index else { return }
        let block = blocks.remove(at: index)
        blocks.insert(block, at: destination)
        changed()
    }

    /// The workspace must finish the child close decisions before calling this.
    /// Library deletion uses candidate publication first, so a failed save never
    /// removes the block or its stable child owner from the live document.
    func canRemoveBlockAfterLifecycle(_ blockID: UUID) -> Bool {
        guard isAvailable, blocks.contains(where: { $0.id == blockID }) else { return false }
        guard let child = sqlDocuments[blockID] else { return true }
        return !child.isRunning && (child.runtime == nil || child.runtime?.canEditConnection == true) &&
            child.grid?.isApplying != true && child.grid?.isClosing != true &&
            child.grid?.isReloading != true && child.grid?.isPreviewing != true
    }

    @discardableResult
    func removeBlockAfterLifecycle(_ blockID: UUID) -> Bool {
        guard canRemoveBlockAfterLifecycle(blockID), let index = blocks.firstIndex(where: { $0.id == blockID }) else { return false }
        blocks.remove(at: index)
        sqlDocuments.removeValue(forKey: blockID)
        sqlObservations.removeValue(forKey: blockID)
        snapshotModels.removeValue(forKey: blockID)
        if selectedBlockID == blockID {
            selectedBlockID = blocks.isEmpty ? nil : blocks[min(index, blocks.count - 1)].id
        }
        changed()
        return true
    }

    func acknowledgeSave(revision saved: UInt64, updatedAt savedDate: Date? = nil) {
        savedRevision = saved
        isDirty = revision != savedRevision
        if revision == saved, let savedDate { updatedAt = savedDate }
        error = nil
    }

    func setSaving(_ value: Bool) { isSaving = value }
    func reportSaveError(_ message: String) { error = message }
    func markNew() { changed() }

    private func insert(_ block: StoredInvestigationBlock) -> UUID? {
        guard isAvailable, block.isValid, blocks.count < InvestigationLimits.maximumBlocksPerDocument,
              blocks.reduce(0, { $0 + $1.textBytes }) + block.textBytes <= InvestigationLimits.maximumDocumentBytes else {
            error = InvestigationStoreError.invalid.localizedDescription
            return nil
        }
        blocks.append(block)
        if block.kind == .sql { installSQLDocument(for: block) }
        selectedBlockID = block.id
        changed()
        return block.id
    }

    private func installSQLDocument(for block: StoredInvestigationBlock) {
        let child = SQLDocument(title: "SQL Block", text: block.text, profileID: block.profileID)
        if block.profileID == nil {
            child.historyConnectionNotice = "This SQL block is unbound. Choose a connection before running it."
        }
        sqlDocuments[block.id] = child
        sqlObservations[block.id] = [
            child.objectWillChange.sink { [weak self, weak child] _ in
                guard let self, let child, self.sqlDocuments[block.id] === child else { return }
                self.objectWillChange.send()
            },
            child.$text.dropFirst().sink { [weak self, weak child] value in
                guard let self, let child, self.sqlDocuments[block.id] === child,
                      let index = self.blocks.firstIndex(where: { $0.id == block.id }),
                      !self.blocks[index].text.utf8.elementsEqual(value.utf8) else { return }
                self.blocks[index].text = value
                self.changed()
            },
            child.$profileID.dropFirst().sink { [weak self, weak child] value in
                guard let self, let child, self.sqlDocuments[block.id] === child,
                      let index = self.blocks.firstIndex(where: { $0.id == block.id }),
                      self.blocks[index].profileID != value else { return }
                self.blocks[index].profileID = value
                self.changed()
            }
        ]
    }

    private func changed() {
        guard isAvailable else { return }
        revision &+= 1
        isDirty = revision != savedRevision
        updatedAt = max(createdAt, .now)
        didChange?()
    }
}
