import Foundation
import Testing
@testable import DBeer

private actor ControlledInvestigationStore: InvestigationStore {
    var snapshot: StoredInvestigations
    private var shouldPause = false
    private var shouldFail = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var writes: [StoredInvestigations] = []
    private(set) var activeSaves = 0
    private(set) var maximumActiveSaves = 0

    init(snapshot: StoredInvestigations = StoredInvestigations()) { self.snapshot = snapshot }
    func load() -> StoredInvestigations { snapshot }
    func pauseNextSave() { shouldPause = true }
    func failNextSave() { shouldFail = true }
    func waitUntilPaused() async {
        if blocked != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resumeSave() { blocked?.resume(); blocked = nil }

    func save(_ value: StoredInvestigations) async throws {
        activeSaves += 1
        maximumActiveSaves = max(maximumActiveSaves, activeSaves)
        defer { activeSaves -= 1 }
        writes.append(value)
        if shouldPause {
            shouldPause = false
            await withCheckedContinuation { continuation in
                blocked = continuation
                for waiter in waiters { waiter.resume() }
                waiters.removeAll()
            }
        }
        if shouldFail { shouldFail = false; throw InvestigationStoreError.write }
        snapshot = value
    }
}

private actor UnreadableInvestigationStore: InvestigationStore {
    private(set) var saveCount = 0
    func load() throws -> StoredInvestigations { throw InvestigationStoreError.read }
    func save(_ value: StoredInvestigations) { saveCount += 1 }
}

/// Model and private local-file coverage only. No windows or helper activity.
@MainActor
struct InvestigationLibraryModelTests {
    private func directory() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let result = repository.appendingPathComponent("build/r18/investigation-library/\(UUID())")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    @Test func untouchedNewInvestigationStaysUnsavedUntilDurableAndFlushPersistsIt() async throws {
        let store = ControlledInvestigationStore()
        let library = InvestigationLibraryModel(store: store, autosaveDelay: nil)
        await library.restore()
        let model = try #require(library.create(title: "Untouched new investigation"))
        #expect(model.blocks.isEmpty && model.isDirty && model.revision > 0)
        #expect(!library.releaseDocument(model.id))
        await store.failNextSave()
        #expect(!(await library.saveInvestigation(model.id)))
        #expect(model.isDirty && !library.releaseDocument(model.id))
        #expect(await store.snapshot.documents.isEmpty)
        #expect(await library.flush())
        #expect(!model.isDirty && library.releaseDocument(model.id))
        let reopenedLibrary = InvestigationLibraryModel(store: store, autosaveDelay: nil)
        await reopenedLibrary.restore()
        let reopened = try reopenedLibrary.openDocument(id: model.id)
        #expect(reopened.title == "Untouched new investigation" && reopened.blocks.isEmpty && !reopened.isDirty)
    }

    @Test func manualSaveWaitsForCompleteLatestSourceAndSerializesOverlappingRequests() async throws {
        let store = ControlledInvestigationStore()
        let library = InvestigationLibraryModel(store: store, autosaveDelay: nil)
        await library.restore()
        let model = try #require(library.create(title: "Manual save"))
        let markdown = try #require(model.addMarkdown(text: "Old Markdown"))
        let firstSQL = try #require(model.addSQL(text: "SELECT 'old first';", profileID: UUID()))
        let secondSQL = try #require(model.addSQL(text: "SELECT 'old second';", profileID: nil))
        await store.pauseNextSave()
        let firstSave = Task { @MainActor in await library.saveInvestigation(model.id) }
        await store.waitUntilPaused()
        let capturedRevision = model.revision
        model.setText("# Complete current Markdown\r\ne\u{301} 🐋", for: markdown)
        model.sqlDocument(for: firstSQL)?.text = "BEGIN;\r\nSELECT 9007199254740993;"
        model.sqlDocument(for: secondSQL)?.text = "SELECT '', NULL, 'NULL';"
        model.sqlDocument(for: secondSQL)?.profileID = UUID()
        model.acknowledgeSave(revision: capturedRevision)
        #expect(model.isDirty)
        let secondSave = Task { @MainActor in await library.saveInvestigation(model.id) }
        await Task.yield()
        #expect(await store.writes.count == 1)
        await store.resumeSave()
        #expect(await firstSave.value)
        #expect(await secondSave.value)
        #expect(!model.isDirty && !model.isSaving && !library.isSaving)
        #expect(await store.maximumActiveSaves == 1)
        let saved = await store.snapshot
        #expect(saved.documents == [model.storedState])
        #expect(saved.documents[0].blocks[0].text.utf8.elementsEqual("# Complete current Markdown\r\ne\u{301} 🐋".utf8))
        #expect(saved.documents[0].blocks[1].text == "BEGIN;\r\nSELECT 9007199254740993;")
        #expect(saved.documents[0].blocks[2].text == "SELECT '', NULL, 'NULL';")
        #expect(saved.documents[0].blocks[2].profileID != nil)
    }

    @Test func closedAndClearedWorkspaceReferencesDoNotDeleteTheDurableLibrary() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Investigations/library.json")
        let library = InvestigationLibraryModel(store: FileInvestigationStore(fileURL: url), autosaveDelay: nil)
        await library.restore()
        let model = try #require(library.create(title: "Durable after close"))
        let sql = try #require(model.addSQL(text: "SELECT 'durable exact source';", profileID: UUID()))
        let childID = try #require(model.sqlDocument(for: sql)?.id)
        let snapshotID = UUID()
        _ = model.addSnapshot(id: snapshotID, explanation: "Retain this reference with no open tab.")
        #expect(await library.saveInvestigation(model.id))
        let reference = StoredSQLDocument(title: model.title, text: "", kind: .investigation, investigationID: model.id)
        var workspace = SQLWorkspaceSnapshot(documents: [reference], selectedDocumentID: reference.id)
        let closed = ClosedWorkspaceTab(state: reference, originalIndex: 0)
        #expect(library.releaseDocument(model.id))
        #expect(library.document(id: model.id) == nil)
        workspace.clearDocuments()
        #expect(workspace.documents.isEmpty && closed.state.investigationID == model.id)
        #expect(try library.referencingInvestigations(snapshotID: snapshotID) == [model.id])
        let reopened = try library.openDocument(id: model.id)
        #expect(reopened !== model && reopened.blocks.map(\.id) == model.blocks.map(\.id))
        #expect(reopened.sqlDocument(for: sql)?.id != childID && reopened.sqlDocument(for: sql)?.runtime == nil)
        let restarted = InvestigationLibraryModel(store: FileInvestigationStore(fileURL: url), autosaveDelay: nil)
        await restarted.restore()
        #expect(restarted.isLoaded && restarted.documents.count == 1)
        #expect(try restarted.referencingInvestigations(snapshotID: snapshotID) == [model.id])
        let restored = try restarted.openDocument(id: model.id)
        #expect(restored.id == reopened.id && restored.title == reopened.title && restored.blocks == reopened.blocks)
        #expect(abs(restored.createdAt.timeIntervalSince(reopened.createdAt)) < 0.001)
    }

    @Test func persistedAndUnsavedDraftReferencesRemainAUnionUntilSuccessfulSave() async throws {
        let originalSnapshot = UUID()
        let newSnapshot = UUID()
        let block = StoredInvestigationBlock(kind: .snapshot, snapshotID: originalSnapshot, explanation: "original")
        let saved = StoredInvestigation(title: "References", blocks: [block])
        let store = ControlledInvestigationStore(snapshot: StoredInvestigations(documents: [saved]))
        let library = InvestigationLibraryModel(store: store, autosaveDelay: nil)
        await library.restore()
        let model = try library.openDocument(id: saved.id)
        _ = model.addSnapshot(id: newSnapshot, explanation: "new unsaved draft")
        #expect(model.removeBlockAfterLifecycle(block.id))
        #expect(try library.referencingInvestigations(snapshotID: originalSnapshot) == [saved.id])
        #expect(try library.referencingInvestigations(snapshotID: newSnapshot) == [saved.id])
        await store.failNextSave()
        #expect(!(await library.saveInvestigation(saved.id)))
        #expect(try library.referencingInvestigations(snapshotID: originalSnapshot) == [saved.id])
        #expect(try library.referencingInvestigations(snapshotID: newSnapshot) == [saved.id])
        #expect(!library.releaseDocument(saved.id))
        #expect(await library.saveInvestigation(saved.id))
        #expect(try library.referencingInvestigations(snapshotID: originalSnapshot).isEmpty)
        #expect(try library.referencingInvestigations(snapshotID: newSnapshot) == [saved.id])
        #expect(library.releaseDocument(saved.id))
        #expect(try library.referencingInvestigations(snapshotID: newSnapshot) == [saved.id])
    }

    @Test func failedLibraryLookupThrowsAndCannotCreateSaveOrEraseReferences() async throws {
        let store = UnreadableInvestigationStore()
        let library = InvestigationLibraryModel(store: store, autosaveDelay: nil)
        #expect(throws: InvestigationStoreError.self) { _ = try library.referencingInvestigations(snapshotID: UUID()) }
        await library.restore()
        #expect(!library.isLoaded && library.error != nil)
        #expect(throws: InvestigationStoreError.self) { _ = try library.referencingInvestigations(snapshotID: UUID()) }
        #expect(throws: InvestigationStoreError.self) { _ = try library.openDocument(id: UUID()) }
        #expect(library.create() == nil)
        #expect(await library.flush())
        #expect(!(await library.saveInvestigation(UUID())))
        #expect(await store.saveCount == 0)
    }

    @Test func missingInvestigationCannotBeOpenedAsAnEmptyReplacement() async throws {
        let store = ControlledInvestigationStore()
        let library = InvestigationLibraryModel(store: store, autosaveDelay: nil)
        await library.restore()
        let absent = UUID()
        #expect(throws: InvestigationStoreError.self) { _ = try library.openDocument(id: absent) }
        #expect(library.document(id: absent) == nil && library.documents.isEmpty)
        #expect(await store.writes.isEmpty)
    }

    @Test func failedBlockDeletionRetainsTheExactLiveChildAndSuccessfulDeletionPublishesFirst() async throws {
        let store = ControlledInvestigationStore()
        let library = InvestigationLibraryModel(store: store, autosaveDelay: nil)
        await library.restore()
        let model = try #require(library.create(title: "Delete block"))
        let block = try #require(model.addSQL(text: "BEGIN; SELECT 'retain on failure';", profileID: UUID()))
        let child = try #require(model.sqlDocument(for: block))
        #expect(await library.saveInvestigation(model.id))
        await store.failNextSave()
        #expect(!(await library.saveRemovingBlock(in: model.id, blockID: block)))
        #expect(model.sqlDocument(for: block) === child && model.blocks.count == 1)
        #expect(await store.snapshot.documents[0].blocks.count == 1)
        await store.pauseNextSave()
        let deletion = Task { @MainActor in await library.saveRemovingBlock(in: model.id, blockID: block) }
        await store.waitUntilPaused()
        #expect(model.sqlDocument(for: block) === child)
        #expect(await store.snapshot.documents[0].blocks.count == 1)
        await store.resumeSave()
        #expect(await deletion.value)
        #expect(model.blocks.isEmpty && model.blockID(for: child) == nil && !model.isDirty)
        #expect(await store.snapshot.documents[0].blocks.isEmpty)
    }
}
