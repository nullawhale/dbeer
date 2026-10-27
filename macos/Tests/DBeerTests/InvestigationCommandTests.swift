import Foundation
import Testing
@testable import DBeer

/// Injected contexts and responders verify commands without native windows or
/// pasteboards. Only the protocol fixture launches for actual block execution.
@Suite(.serialized)
@MainActor
struct InvestigationCommandTests {
    private func context(_ document: SQLDocument, focus: AppCommandFocus = .sqlEditor,
                         modal: Bool = false, foreign: Bool = false, composing: Bool = false) -> AppCommandContext {
        AppCommandContext(documentID: document.id, focus: focus, isWorkspaceWindow: !foreign,
            hasModal: modal, isComposingText: composing)
    }

    @Test func acceptedRunBlockUsesOnlyCapturedBlockAfterSelectionAndPaneChanges() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["SELECT 11;\nSELECT 12;", "SELECT 21;"])
        let first = fixture.children[0]
        let second = fixture.children[1]
        let other = fixture.workspace.newDocument(profileID: fixture.profile.id, text: "SELECT 99;", in: .right)
        let registry = AppCommandRegistry(workspace: fixture.workspace, shortcuts: fixture.workspace.commandShortcuts)
        let task = try #require(registry.perform(.runScript, context: context(fixture.parent, focus: .workspace)))
        #expect(fixture.workspace.activePaneID == .left)
        fixture.model.selectBlock(fixture.model.blockID(for: second))
        fixture.workspace.activatePane(.right)
        await task.value
        #expect(first.executions.map(\.sql) == ["SELECT 11", "SELECT 12"])
        #expect(first.executions.allSatisfy { $0.status == "Completed" })
        #expect(second.runtime == nil && other.runtime == nil)
        #expect(fixture.workspace.activePaneID == .right)
        #expect(!registry.canPerform(.runScript, context: context(first)))
        #expect(registry.canPerform(.runScript, context: context(second)))
        await fixture.workspace.shutdown()
    }

    @Test func invocationCapturesChildParentBlockPaneTextAndExplicitProfile() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["SELECT 11;\nSELECT 12;", "SELECT 21;"])
        var captured: [AppCommandInvocation] = []
        let registry = AppCommandRegistry(workspace: fixture.workspace, shortcuts: fixture.workspace.commandShortcuts) { captured.append($0) }
        let first = fixture.children[0]
        let blockID = try #require(fixture.model.blockID(for: first))
        first.selection = (first.text as NSString).range(of: "SELECT 12")
        let task = try #require(registry.perform(.runScript, context: context(first)))
        fixture.model.selectBlock(fixture.model.blockID(for: fixture.children[1]))
        fixture.workspace.moveDocument(fixture.parent.id, to: .right)
        await task.value
        let invocation = try #require(captured.first)
        #expect(invocation.documentID == first.id && invocation.parentDocumentID == fixture.parent.id)
        #expect(invocation.blockID == blockID && invocation.investigationID == fixture.model.id)
        #expect(invocation.paneID == .left && invocation.profile?.id == fixture.profile.id)
        #expect(invocation.documentText == first.text && invocation.fragment?.sourceSQL == first.text)
        #expect(invocation.fragment?.kind == .script)
        #expect(first.runtime == nil && fixture.children[1].runtime == nil)
        await fixture.workspace.shutdown()
    }

    @Test func markdownTextInputSavesParentAndNeverEnablesSQLCommands() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["SELECT 1;", "SELECT 2;"])
        let markdownID = try #require(fixture.workspace.addInvestigationMarkdown(fixture.parent, text: "# Current notes\n"))
        fixture.model.selectBlock(markdownID)
        fixture.children[0].text = "SELECT 'first draft';"
        fixture.children[1].text = "SELECT 'second draft';"
        fixture.model.title = "Saved from Markdown"
        let registry = AppCommandRegistry(workspace: fixture.workspace, shortcuts: fixture.workspace.commandShortcuts)
        let markdownContext = context(fixture.parent, focus: .textInput)
        for command: AppCommandID in [.runCurrent, .runScript, .runToJSON, .runToCSV, .stop, .copyAsJSON, .saveSQLAs] {
            #expect(!registry.canPerform(command, context: markdownContext))
        }
        #expect(registry.canPerform(.saveSQL, context: markdownContext))
        #expect(registry.canPerform(.closeTab, context: markdownContext))
        let save = try #require(registry.perform(.saveSQL, context: markdownContext))
        await save.value
        let saved = try #require(await fixture.store.load().documents.first)
        #expect(saved.title == "Saved from Markdown")
        #expect(saved.blocks.first { $0.id == markdownID }?.text == "# Current notes\n")
        #expect(saved.blocks.filter { $0.kind == .sql }.map(\.text) == fixture.children.map(\.text))
        #expect(fixture.children.allSatisfy { $0.fileDocument == nil && $0.fileURL == nil })
        await fixture.workspace.shutdown()
    }

    @Test func childSaveTargetsLibraryAndSaveAsCannotAttachBlockToSQLFile() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["SELECT 1;"])
        let child = fixture.children[0]
        child.text = "SELECT 'save child';"
        let registry = AppCommandRegistry(workspace: fixture.workspace, shortcuts: fixture.workspace.commandShortcuts)
        #expect(registry.canPerform(.saveSQL, context: context(child)))
        #expect(!registry.canPerform(.saveSQLAs, context: context(child)))
        let save = try #require(registry.perform(.saveSQL, context: context(child)))
        await save.value
        #expect(await fixture.store.load().documents[0].blocks[0].text == child.text)
        #expect(child.fileDocument == nil && child.fileURL == nil && child.sqlLibraryEntryID == nil)
        await fixture.workspace.shutdown()
    }

    @Test func staleChildNeverFallsBackToCurrentBlockOrOtherPaneAndClosedIDsStayInvalid() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["SELECT 1;", "SELECT 2;"])
        let first = fixture.children[0]
        let second = fixture.children[1]
        let registry = AppCommandRegistry(workspace: fixture.workspace, shortcuts: fixture.workspace.commandShortcuts)
        fixture.workspace.newDocument(profileID: fixture.profile.id, text: "SELECT 99;", in: .right)
        fixture.model.selectBlock(fixture.model.blockID(for: second))
        for command: AppCommandID in [.runCurrent, .runScript, .stop, .saveSQL, .closeTab, .copyAsJSON] {
            #expect(!registry.canPerform(command, context: context(first)))
            #expect(registry.perform(command, context: context(first)) == nil)
        }
        #expect(registry.canPerform(.runCurrent, context: context(second)))
        let close = try #require(registry.perform(.closeTab, context: context(second)))
        await close.value
        let reopened = try #require(fixture.workspace.reopenClosedTab())
        #expect(reopened.investigationModel?.allSQLDocuments.allSatisfy { $0.id != first.id && $0.id != second.id } == true)
        for old in [first, second] {
            #expect(!registry.canPerform(.runCurrent, context: context(old)))
            #expect(!registry.canPerform(.saveSQL, context: context(old)))
            #expect(registry.perform(.closeTab, context: context(old)) == nil)
        }
        #expect(fixture.workspace.documents.count == 2)
        #expect(fixture.workspace.selectedDocument === reopened)
        await fixture.workspace.shutdown()
    }

    @Test func explicitProfileChangeAfterAcceptanceCancelsRatherThanRetargetsExecution() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["SELECT 1;"])
        let child = fixture.children[0]
        let registry = AppCommandRegistry(workspace: fixture.workspace, shortcuts: fixture.workspace.commandShortcuts)
        let task = try #require(registry.perform(.runScript, context: context(child)))
        #expect(fixture.workspace.bindInvestigationProfile(child, profileID: nil))
        await task.value
        #expect(child.profileID == nil && child.runtime == nil && child.executions.isEmpty)
        #expect(!registry.canPerform(.runCurrent, context: context(child)))
        #expect(!fixture.workspace.bindInvestigationProfile(child, profileID: UUID()))
        #expect(child.profileID == nil)
        await fixture.workspace.shutdown()
    }

    @Test func snapshotCopyUsesSelectedOfflineEnvelopeAndCapturesBeforeSelectionChanges() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/r18/copy-command-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = ResultSnapshotsModel(store: ResultSnapshotStore(rootURL: root))
        let saved = try await snapshots.store.save(ResultSnapshotCapture(title: "Offline command fixture", sql: "SELECT local_fixture;",
            engine: .postgresql, columns: [ResultColumn(index: 0, name: "value", nativeType: "text")], rows: [["offline value"]]))
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["SELECT 1;"], resultSnapshots: snapshots)
        defer { Task { await fixture.workspace.shutdown() } }
        let blockID = try #require(fixture.workspace.addInvestigationSnapshot(fixture.parent, snapshotID: saved.id, explanation: "Offline result"))
        let snapshot = try #require(fixture.workspace.investigationSnapshotDocument(fixture.parent, blockID: blockID))
        let page = try #require(snapshot.snapshotModel)
        let responder = CopyResponder(documentID: snapshot.id)
        let registry = AppCommandRegistry(workspace: fixture.workspace, shortcuts: fixture.workspace.commandShortcuts,
            gridCopyResponderProvider: { responder })
        let copyContext = context(snapshot, focus: .grid)
        #expect(!registry.canPerform(.copyAsJSON, context: copyContext))
        await page.load()
        try #require(page.isAvailable && page.result?.rows == [["offline value"]])
        #expect(registry.canPerform(.copyAsJSON, context: copyContext))
        #expect(!registry.canPerform(.runCurrent, context: copyContext))
        let copy = try #require(registry.perform(.copyAsJSON, context: copyContext))
        responder.selection = "later selection"
        fixture.model.selectBlock(fixture.model.blockID(for: fixture.children[0]))
        await copy.value
        #expect(responder.copied == ["captured offline selection"])
        #expect(!registry.canPerform(.copyAsJSON, context: copyContext))
        #expect(fixture.workspace.investigationSnapshotDocument(fixture.parent, blockID: blockID) === snapshot)
        #expect(snapshot.runtime == nil && fixture.children[0].runtime == nil)
        fixture.model.selectBlock(blockID)
        let invalidatedCopy = try #require(registry.perform(.copyAsJSON, context: copyContext))
        page.invalidateArtifact(.notFound)
        await invalidatedCopy.value
        #expect(responder.copied == ["captured offline selection"])
        #expect(!registry.canPerform(.copyAsJSON, context: copyContext))
        await page.revalidateCurrentPage()
        try #require(page.isAvailable)
        snapshots.trackDocument(page)
        await snapshots.refresh()
        let deletion = try #require(snapshots.requestDeletion(saved.id))
        #expect(deletion.investigationIDs == [fixture.model.id])
        #expect(await snapshots.deleteConfirmed(deletion))
        #expect(!page.isAvailable && !registry.canPerform(.copyAsJSON, context: copyContext))
        #expect(registry.perform(.copyAsJSON, context: copyContext) == nil)
        await fixture.workspace.shutdown()
    }

    @Test func childContextsRetainModalForeignWindowCompositionAndTextInputGuards() async throws {
        let fixture = try await InvestigationRuntimeTestSupport.fixture(sql: ["SELECT 1;"])
        let child = fixture.children[0]
        let registry = AppCommandRegistry(workspace: fixture.workspace, shortcuts: fixture.workspace.commandShortcuts)
        for candidate in [context(child, modal: true), context(child, foreign: true), context(child, composing: true),
                          context(child, focus: .textInput)] {
            #expect(!registry.canPerform(.runScript, context: candidate))
        }
        #expect(registry.canPerform(.saveSQL, context: context(child, focus: .textInput)))
        fixture.children[0].isRunning = true
        #expect(registry.canPerform(.stop, context: context(child, focus: .textInput)))
        fixture.children[0].isRunning = false
        await fixture.workspace.shutdown()
    }

    @MainActor private final class CopyResponder: AppGridCopyCommandResponder {
        var appCommandFocus: AppCommandFocus = .grid
        let appCommandDocumentID: UUID?
        var selection = "captured offline selection"
        var copied: [String] = []
        init(documentID: UUID) { appCommandDocumentID = documentID }
        func canPerformGridCopy(_ command: AppCommandID) -> Bool { command.isGridCopyCommand }
        func captureGridCopy(_ command: AppCommandID) -> (@MainActor () async -> Void)? {
            let captured = selection
            return { [self] in copied.append(captured) }
        }
    }
}
