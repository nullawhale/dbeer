import Foundation
import Testing
@testable import DBeer

private actor ProfileInvestigationStore: InvestigationStore {
    var snapshot = StoredInvestigations()
    var failure = false
    var unreadable = false
    var saves = 0
    func failNext() { failure = true }
    func denyRead() { unreadable = true }
    func load() throws -> StoredInvestigations {
        if unreadable { throw InvestigationStoreError.read }
        return snapshot
    }
    func save(_ value: StoredInvestigations) throws {
        saves += 1
        if failure { failure = false; throw InvestigationStoreError.write }
        snapshot = value
    }
}

/// Local model/persistence only. Attaching a frozen report never creates a DB session.
@MainActor
struct GridProfileAttachmentTests {
    private func report() throws -> GridProfileReport {
        let payload = try ResultCopy.selection(columns: [.init(index: 0, name: "n", typeOid: 1700, nativeType: "numeric")],
            rows: [["9007199254740993.000000000000000001"], [nil]], rowIndices: [0, 1], columnIndices: [0])
        return try GridDataProfiler.profile(.init(payload: payload, scope: .init(title: "Loaded fixture", notice: "Only captured rows", partial: true,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000))))
    }
    @Test func attachNewReportAndRestoreRenderedScopeWithNoConnections() async throws {
        let store = ProfileInvestigationStore()
        let actualLibrary = InvestigationLibraryModel(store: store, autosaveDelay: nil)
        let captured = try report(), attachment = GridProfileAttachment(report: captured, library: actualLibrary)
        #expect(await attachment.save(to: nil))
        let id = try #require(attachment.pendingDocumentID)
        let saved = try #require((await store.snapshot).documents.first)
        #expect(saved.id == id && saved.blocks.count == 1 && saved.blocks[0].kind == .markdown)
        #expect(saved.blocks[0].text == captured.markdown && saved.blocks[0].text.contains("Only captured rows"))
        let restored = InvestigationLibraryModel(store: store, autosaveDelay: nil)
        await restored.restore()
        let opened = try restored.openDocument(id: id)
        #expect(opened.allSQLDocuments.isEmpty && opened.blocks.count == 1 && !opened.isDirty)
    }
    @Test func failedSaveRetryUsesSameUnsavedDocumentAndSingleMarkdownBlock() async throws {
        let store = ProfileInvestigationStore()
        let actualLibrary = InvestigationLibraryModel(store: store, autosaveDelay: nil)
        let attachment = GridProfileAttachment(report: try report(), library: actualLibrary)
        await store.failNext()
        #expect(!(await attachment.save(to: nil)))
        let id = try #require(attachment.pendingDocumentID)
        let draft = try #require(actualLibrary.document(id: id))
        #expect(draft.isDirty && draft.blocks.count == 1)
        #expect(await attachment.save(to: nil))
        #expect(attachment.pendingDocumentID == id && draft.blocks.count == 1 && !draft.isDirty)
        #expect((await store.snapshot).documents.count == 1)
    }
    @Test func attachToSavedOrUnsavedInvestigationAndLockRetryTarget() async throws {
        let store = ProfileInvestigationStore(), library = InvestigationLibraryModel(store: store, autosaveDelay: nil)
        await library.restore()
        let existing = try #require(library.create(title: "Existing draft"))
        _ = existing.addMarkdown(text: "Existing content")
        let first = GridProfileAttachment(report: try report(), library: library)
        await store.failNext()
        #expect(!(await first.save(to: existing.id)))
        #expect(existing.blocks.count == 2)
        #expect(!(await first.save(to: nil)))
        #expect(first.error?.contains("prepared Investigation") == true)
        #expect(await first.save(to: existing.id))
        let second = GridProfileAttachment(report: try report(), library: library)
        #expect(await second.save(to: existing.id))
        let saved = await store.snapshot
        #expect(existing.blocks.count == 3 && saved.documents.count == 1)
    }
    @Test func unavailableLibraryAndClosedOwnerNeverCreateReplacement() async throws {
        let store = ProfileInvestigationStore()
        await store.denyRead()
        let library = InvestigationLibraryModel(store: store, autosaveDelay: nil)
        let attachment = GridProfileAttachment(report: try report(), library: library)
        #expect(!(await attachment.save(to: UUID())))
        let deniedSaves = await store.saves
        #expect(attachment.pendingDocumentID == nil && deniedSaves == 0)
        let readableStore = ProfileInvestigationStore(), readable = InvestigationLibraryModel(store: readableStore, autosaveDelay: nil)
        var active = true
        let guarded = GridProfileAttachment(report: try report(), library: readable, mayAttach: { active })
        active = false
        #expect(!(await guarded.save(to: nil)))
        let ownerSaves = await readableStore.saves
        #expect(!readable.isLoaded && ownerSaves == 0)
    }
    @Test func renderedReportEscapesNativeContentAndShowsFractionAndTruncation() throws {
        let payload = try ResultCopy.selection(columns: [.init(index: 0, name: "<script>|[link]", nativeType: "text")],
            rows: [["[fake](dbeer-plan://00000000-0000-0000-0000-000000000000)"], [String(repeating: "x", count: 1000)]], rowIndices: [0, 1], columnIndices: [0])
        let report = try GridDataProfiler.profile(.init(payload: payload,
            scope: .init(title: "<source>", notice: "[scope](fake)", partial: true)))
        let markdown = report.markdown
        #expect(!markdown.contains("<script>") && !markdown.contains("[fake]") && !markdown.contains("[scope]"))
        #expect(markdown.contains("&lt;source&gt;") && markdown.contains("1000 bytes") && markdown.contains("Coverage is partial"))
        #expect(PlanArtifactReference.ids(in: markdown).isEmpty)
    }
}
