import Foundation
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct TableBrowseNavigationTests {
    private enum BlockedState: String, CaseIterable {
        case dirty, applying, reloading, previewing, unknownCommit, gridClosing, documentRunning
    }

    private func workspace(
        closeDecision: @escaping @MainActor (WorkspaceCloseIssue) async -> WorkspaceCloseDecision = { _ in .cancel }
    ) -> ApplicationWorkspace {
        ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: closeDecision)
    }

    private func table(in workspace: ApplicationWorkspace) -> (SQLDocument, GridDraft) {
        // No profile is assigned: scheduled reloads return before opening a
        // helper or database session, while exercising the real sort action.
        let document = workspace.newDocument()
        let reference = TableReference(schema: "public", name: "fixture", kind: "table")
        document.table = reference
        let columns = [ResultColumn(index: 0, name: "id", nativeType: "int4"),
            ResultColumn(index: 1, name: "label", nativeType: "text")]
        let grid = GridDraft(reference: reference,
            result: BackendMessage(type: "query.result", requestId: "fixture", columns: columns, rows: [["1", "original"]]),
            metadata: [["name": "id", "primaryKey": "1", "editable": "true"],
                ["name": "label", "editable": "true"]])
        document.attachGrid(grid)
        return (document, grid)
    }

    @Test func headerSortCyclesAscendingDescendingAndPrimaryKeyOrder() async {
        let workspace = workspace()
        let (document, _) = table(in: workspace)
        #expect(TableBrowseNavigation.isEnabled(document: document, workspace: workspace))
        for expected in [[CatalogSort(column: "label", direction: "asc")],
                         [CatalogSort(column: "label", direction: "desc")], []] {
            document.page = 4
            TableBrowseNavigation.sort(column: "label", document: document, workspace: workspace)
            #expect(document.tableSort == expected)
            #expect(document.page == 0)
            await Task.yield()
        }
        #expect(document.runtime == nil && !document.isRunning)
        // Shutdown suppresses any remaining unstructured reload task before it
        // could start an operation, and awaits workspace cleanup.
        await workspace.shutdown()
    }

    @Test func choosingAnotherColumnStartsAscendingOnTheFirstPage() async {
        let workspace = workspace()
        let (document, _) = table(in: workspace)
        document.tableSort = [CatalogSort(column: "id", direction: "desc")]
        document.page = 9
        TableBrowseNavigation.sort(column: "label", document: document, workspace: workspace)
        #expect(document.tableSort == [CatalogSort(column: "label", direction: "asc")])
        #expect(document.page == 0)
        await workspace.shutdown()
    }

    @Test(arguments: BlockedState.allCases)
    private func blockedDraftCannotChangeSortOrPage(_ state: BlockedState) async {
        let workspace = workspace()
        let (document, grid) = table(in: workspace)
        let sort = [CatalogSort(column: "id", direction: "desc")]
        document.tableSort = sort
        document.page = 3
        switch state {
        case .dirty: grid.set(ChangeValue(kind: "text", value: "pending"), row: 0, column: 1)
        case .applying: grid.isApplying = true
        case .reloading: grid.isReloading = true
        case .previewing: grid.isPreviewing = true
        case .unknownCommit: grid.outcomeUnknown = true
        case .gridClosing: grid.isClosing = true
        case .documentRunning: document.isRunning = true
        }
        #expect(!TableBrowseNavigation.isEnabled(document: document, workspace: workspace))
        TableBrowseNavigation.sort(column: "id", document: document, workspace: workspace)
        TableBrowseNavigation.sort(column: "label", document: document, workspace: workspace)
        #expect(document.tableSort == sort)
        #expect(document.page == 3)
        #expect(document.runtime == nil)
        await workspace.shutdown()
    }

    @MainActor
    private final class CloseGate {
        var entered = false
        private var released = false
        private var continuation: CheckedContinuation<WorkspaceCloseDecision, Never>?

        func wait() async -> WorkspaceCloseDecision {
            entered = true
            if released { return .cancel }
            return await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume(returning: .cancel)
            continuation = nil
        }
    }

    @Test func closingAnotherDocumentStillPreventsNavigationWorkspaceWide() async {
        let gate = CloseGate()
        let workspace = workspace(closeDecision: { _ in await gate.wait() })
        let (document, grid) = table(in: workspace)
        let (closingDocument, closingGrid) = table(in: workspace)
        closingGrid.insert()
        document.tableSort = [CatalogSort(column: "id", direction: "asc")]
        document.page = 2
        let closing = Task { await workspace.prepareToClose(.document(closingDocument.id)) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.entered, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(gate.entered && workspace.isClosing)
        #expect(!grid.isClosing && grid.pendingCount == 0)
        #expect(!TableBrowseNavigation.isEnabled(document: document, workspace: workspace))
        TableBrowseNavigation.sort(column: "label", document: document, workspace: workspace)
        #expect(document.tableSort == [CatalogSort(column: "id", direction: "asc")])
        #expect(document.page == 2)
        gate.release()
        #expect(!(await closing.value))
        #expect(!workspace.isClosing)
        await workspace.shutdown()
    }

    @Test func readonlyTablesCanStillBeSorted() async {
        let workspace = workspace()
        let (document, grid) = table(in: workspace)
        grid.policyReadOnly = true
        #expect(!grid.canEdit)
        #expect(TableBrowseNavigation.isEnabled(document: document, workspace: workspace))
        TableBrowseNavigation.sort(column: "label", document: document, workspace: workspace)
        #expect(document.tableSort == [CatalogSort(column: "label", direction: "asc")])
        #expect(grid.pendingCount == 0)
        await workspace.shutdown()
    }
}
