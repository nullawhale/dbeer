import Foundation
import Testing
@testable import DBeer

/// Pure main-actor models; no windows, application activation or helper calls.
@MainActor
struct InvestigationDocumentTests {
    @Test func reorderingAndSelectionKeepChildObjectsButRestoringCreatesFreshRuntimeIDs() throws {
        let profile = UUID()
        let first = StoredInvestigationBlock(kind: .sql, text: "BEGIN; SELECT 'first';", profileID: profile)
        let markdown = StoredInvestigationBlock(kind: .markdown, text: "# Notes\r\n")
        let second = StoredInvestigationBlock(kind: .sql, text: "SELECT 'second';", profileID: profile)
        let record = StoredInvestigation(title: "Independent blocks", blocks: [first, markdown, second])
        let model = InvestigationDocumentModel(stored: record)
        let firstChild = try #require(model.sqlDocument(for: first.id))
        let secondChild = try #require(model.sqlDocument(for: second.id))
        #expect(firstChild !== secondChild && firstChild.id != secondChild.id)
        #expect(firstChild.id != first.id && secondChild.id != second.id)
        #expect(firstChild.runtime == nil && secondChild.runtime == nil)
        #expect(firstChild.profileID == profile && secondChild.profileID == profile)
        model.moveBlock(second.id, by: -2)
        model.selectBlock(second.id)
        #expect(model.blocks.map(\.id) == [second.id, first.id, markdown.id])
        #expect(model.selectedSQLDocument === secondChild)
        #expect(model.sqlDocument(for: first.id) === firstChild && model.sqlDocument(for: second.id) === secondChild)
        #expect(model.blockID(for: firstChild) == first.id)
        let impostor = SQLDocument(id: firstChild.id, text: firstChild.text, profileID: profile)
        #expect(model.blockID(for: impostor) == nil)
        let restored = InvestigationDocumentModel(stored: model.storedState)
        #expect(restored.blocks.map(\.id) == model.blocks.map(\.id))
        #expect(restored.sqlDocument(for: first.id)?.id != firstChild.id)
        #expect(restored.allSQLDocuments.allSatisfy { $0.runtime == nil && !$0.isRunning && $0.executions.isEmpty })
    }

    @Test func completeSourceSnapshotIncludesAllChildChangesAndExplicitUnboundProfiles() throws {
        let missingProfile = UUID()
        let model = InvestigationDocumentModel(stored: StoredInvestigation(title: "Source"))
        let markdown = try #require(model.addMarkdown(text: "# Original"))
        let bound = try #require(model.addSQL(text: "SELECT 1;", profileID: missingProfile))
        let unbound = try #require(model.addSQL(text: "SELECT 2;", profileID: nil))
        model.selectBlock(markdown)
        model.setText("# e\u{301} final\r\n🐋", for: markdown)
        let boundChild = try #require(model.sqlDocument(for: bound))
        let unboundChild = try #require(model.sqlDocument(for: unbound))
        boundChild.text = "BEGIN;\r\nSELECT '', NULL, 'NULL', 9007199254740993;"
        unboundChild.text = "SELECT 'edited while not selected';"
        let current = model.storedState
        #expect(current.blocks[0].text.utf8.elementsEqual("# e\u{301} final\r\n🐋".utf8))
        #expect(current.blocks[1].text == boundChild.text && current.blocks[1].profileID == missingProfile)
        #expect(current.blocks[2].text == unboundChild.text && current.blocks[2].profileID == nil)
        #expect(boundChild.fileURL == nil && boundChild.fileDocument == nil && boundChild.runtime == nil)
        #expect(unboundChild.historyConnectionNotice?.contains("unbound") == true)
        #expect(model.isDirty)
        let saved = model.revision
        model.acknowledgeSave(revision: saved)
        #expect(!model.isDirty)
        boundChild.text += "\r\nSELECT 'newer';"
        model.acknowledgeSave(revision: saved)
        #expect(model.isDirty && model.revision > saved)
    }

    @Test func lifecycleGuardCannotDropOrRebindARunningSQLChild() throws {
        let model = InvestigationDocumentModel(stored: StoredInvestigation(title: "Lifecycle"))
        let block = try #require(model.addSQL(text: "SELECT 'running';", profileID: UUID()))
        let child = try #require(model.sqlDocument(for: block))
        let originalProfile = child.profileID
        child.isRunning = true
        #expect(!model.removeBlockAfterLifecycle(block))
        #expect(!model.setProfileID(UUID(), for: block))
        #expect(model.sqlDocument(for: block) === child && child.profileID == originalProfile)
        child.isRunning = false
        #expect(model.setProfileID(nil, for: block))
        #expect(model.storedState.blocks[0].profileID == nil)
        #expect(model.removeBlockAfterLifecycle(block))
        #expect(model.blocks.isEmpty && model.selectedBlockID == nil && model.blockID(for: child) == nil)
    }

    @Test func childPresentationAndBusyChangesDoNotDirtySavedSource() throws {
        let model = InvestigationDocumentModel(stored: StoredInvestigation(title: "Content revisions"))
        let block = try #require(model.addSQL(text: "SELECT 'source';", profileID: UUID()))
        let child = try #require(model.sqlDocument(for: block))
        let revision = model.revision
        model.acknowledgeSave(revision: revision)
        child.isRunning = true
        child.selection = NSRange(location: 2, length: 3)
        child.localError = "A local presentation message"
        child.selectedExecution = 1
        child.tableResult = BackendMessage(type: "query.result", requestId: UUID().uuidString,
            rows: [["9007199254740993", nil]])
        child.title = "Transient child label"
        child.isRunning = false
        #expect(model.revision == revision && !model.isDirty)
        child.text += "\r\nSELECT 'edited source';"
        #expect(model.revision > revision && model.isDirty)
        model.acknowledgeSave(revision: model.revision)
        let afterText = model.revision
        child.profileID = nil
        #expect(model.revision > afterText && model.isDirty)
    }

    @Test func missingSnapshotKeepsExplanationAndStablePagedModel() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/r18/missing-snapshot/\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = InvestigationDocumentModel(stored: StoredInvestigation(title: "Missing artifact"),
            snapshotStore: ResultSnapshotStore(rootURL: directory))
        let artifact = UUID()
        let block = try #require(model.addSnapshot(id: artifact, explanation: "The artifact was intentionally removed."))
        let offline = try #require(model.snapshotModel(for: block))
        model.selectBlock(block)
        #expect(model.selectedSnapshotDocument === offline)
        #expect(model.snapshotModel(for: block) === offline)
        await offline.load()
        #expect(!offline.isAvailable && offline.error?.contains("no longer available") == true)
        #expect(model.storedState.blocks[0].snapshotID == artifact)
        #expect(model.storedState.blocks[0].explanation == "The artifact was intentionally removed.")
        model.setExplanation("Still explained after failure.", for: block)
        #expect(model.storedState.blocks[0].explanation == "Still explained after failure.")
        #expect(model.selectedSQLDocument == nil && model.allSQLDocuments.isEmpty)
    }

    @Test func unavailableReferenceNeverCreatesEditableContentOrSQLChildren() {
        let id = UUID()
        let model = InvestigationDocumentModel(unavailableID: id, title: "Unavailable", reason: "The local library could not be read.")
        #expect(model.id == id && !model.isAvailable && model.unavailableReason != nil)
        #expect(model.addSQL(text: "SELECT 'must not replace';") == nil)
        #expect(model.addMarkdown(text: "must not replace") == nil)
        #expect(model.addSnapshot(id: UUID()) == nil)
        #expect(model.blocks.isEmpty && model.allSQLDocuments.isEmpty && !model.isDirty)
    }
}
