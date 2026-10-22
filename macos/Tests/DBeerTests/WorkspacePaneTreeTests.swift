import Foundation
import Testing
@testable import DBeer

/// Value-model and workspace tests only; no windows, desktop input or servers.
@Suite(.serialized)
@MainActor
struct WorkspacePaneTreeTests {
    private func workspace(store: any SQLDocumentStore = MemorySQLDocumentStore()) async -> ApplicationWorkspace {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store,
            automaticallyWatchFiles: false, closeDecision: { _ in .discard })
        await workspace.restoreSavedWorkspace()
        return workspace
    }

    @Test(arguments: WorkspaceSplitDirection.allCases)
    func everyDirectionCreatesAFreshTabWithoutChangingTheSource(direction: WorkspaceSplitDirection) async throws {
        let workspace = await workspace()
        let first = workspace.newDocument(text: "SELECT 'first';")
        let chosen = workspace.newDocument(profileID: UUID(), text: "SELECT 'chosen';")
        chosen.selection = NSRange(location: 3, length: 4)
        let state = chosen.storedState
        let destination = try #require(workspace.splitDocument(chosen.id, direction: direction))
        let created = try #require(workspace.selectedDocument)
        guard case .split(_, let axis, _, let before, let after) = workspace.paneLayout.root else {
            Issue.record("Expected a split root"); return
        }
        #expect(axis == direction.axis)
        #expect(before == .pane(direction.insertsFirst ? destination : .left))
        #expect(after == .pane(direction.insertsFirst ? .left : destination))
        #expect(created !== chosen && workspace.activePaneID == destination)
        #expect(created.profileID == chosen.profileID && created.text == "SELECT 1;")
        #expect(created.isSQLDocument && created.runtime == nil && created.grid == nil && created.executions.isEmpty)
        #expect(workspace.documents(in: .left).map(\.id) == [first.id, chosen.id])
        #expect(workspace.selectedDocument(in: .left) === chosen)
        #expect(chosen.storedState == state && chosen.selection == NSRange(location: 3, length: 4))
        #expect(workspace.documents.count == 3 && workspace.closedTabs.isEmpty)
        #expect(workspace.paneLayout.isValid(documentIDs: workspace.documents.map(\.id)))
        await workspace.shutdown()
    }

    @Test func unsplitCurrentPreservesOtherSplitsSessionsAndIndependentDividerPositions() async throws {
        let workspace = await workspace()
        let left = workspace.newDocument()
        let rightPane = try #require(workspace.splitDocument(left.id, direction: .right))
        let right = try #require(workspace.selectedDocument)
        let bottomPane = try #require(workspace.splitDocument(right.id, direction: .down))
        let bottom = try #require(workspace.selectedDocument)
        let splits = workspace.paneLayout.root.splitIDs
        try #require(splits.count == 2)
        workspace.setSplitFraction(0.65, for: splits[0])
        workspace.setSplitFraction(0.35, for: splits[1])
        let runtime = WorkspaceModel(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore())
        bottom.attach(runtime)
        bottom.isRunning = true
        workspace.unsplitPane(bottomPane)
        #expect(workspace.paneLayout.paneIDs == [.left, rightPane])
        #expect(workspace.paneLayout.root.splitIDs == [splits[0]])
        #expect(workspace.paneLayout.root.fraction == 0.65)
        #expect(workspace.documents(in: rightPane).map(\.id) == [right.id, bottom.id])
        #expect(workspace.selectedDocument === bottom && bottom.runtime === runtime && bottom.isRunning)
        #expect(workspace.selectedDocument(in: .left) === left)
        workspace.mergePanes()
        #expect(!workspace.paneLayout.isSplit && workspace.paneLayout.paneIDs == [.left])
        #expect(workspace.documents(in: .left).map(\.id) == [left.id, right.id, bottom.id])
        #expect(workspace.selectedDocument === bottom && bottom.runtime === runtime)
        #expect(workspace.closedTabs.isEmpty)
        bottom.isRunning = false
        await workspace.shutdown()
    }

    @Test(arguments: WorkspaceSplitDirection.allCases, [false, true])
    func closingTheLastTabCollapsesEitherSideAndKeepsOneFinalPane(direction: WorkspaceSplitDirection, closeSource: Bool) async throws {
        let store = MemorySQLDocumentStore()
        let workspace = await workspace(store: store)
        let source = workspace.newDocument()
        let destination = try #require(workspace.splitDocument(source.id, direction: direction))
        let created = try #require(workspace.selectedDocument)
        let closing = closeSource ? source : created
        let survivor = closeSource ? created : source
        let survivingPane: WorkspacePaneID = closeSource ? destination : .left
        workspace.selectedDocumentID = closing.id
        await workspace.closeDocument(closing)
        #expect(workspace.paneLayout.paneIDs == [survivingPane] && !workspace.paneLayout.isSplit)
        #expect(workspace.activePaneID == survivingPane && workspace.selectedDocument === survivor)
        #expect(workspace.closedTabs.last?.state.id == closing.id)
        await workspace.flushDocuments()
        let saved = await store.load()
        #expect(saved.paneLayout == workspace.paneLayout && saved.documents.map(\.id) == [survivor.id])
        #expect(saved.selectedDocumentID == survivor.id)
        await workspace.closeDocument(survivor)
        #expect(workspace.documents.isEmpty && workspace.selectedDocumentID == nil)
        #expect(workspace.paneLayout.paneIDs == [survivingPane] && !workspace.paneLayout.isSplit)
        #expect(workspace.paneLayout.isValid(documentIDs: []))
        await workspace.shutdown()
    }

    @Test func closingAnInactiveNestedPanesLastTabPreservesTheOtherSelectionAndDivider() async throws {
        let workspace = await workspace()
        let left = workspace.newDocument()
        let rightPane = try #require(workspace.splitDocument(left.id, direction: .right))
        let right = try #require(workspace.selectedDocument)
        let bottomPane = try #require(workspace.splitDocument(right.id, direction: .down))
        let bottom = try #require(workspace.selectedDocument)
        let extra = workspace.newDocument()
        let rootSplit = try #require(workspace.paneLayout.root.splitIDs.first)
        workspace.setSplitFraction(0.63, for: rootSplit)
        await workspace.closeDocument(extra)
        #expect(workspace.paneLayout.paneIDs.count == 3 && workspace.selectedDocument === bottom)
        workspace.selectDocument(left.id, in: .left)
        await workspace.closeDocument(bottom)
        #expect(workspace.paneLayout.paneIDs == [.left, rightPane])
        #expect(!workspace.paneLayout.paneIDs.contains(bottomPane))
        #expect(workspace.paneLayout.root.splitIDs == [rootSplit] && workspace.paneLayout.root.fraction == 0.63)
        #expect(workspace.activePaneID == .left && workspace.selectedDocument === left)
        #expect(workspace.selectedDocument(in: rightPane) === right)
        #expect(workspace.paneLayout.isValid(documentIDs: workspace.documents.map(\.id)))
        await workspace.shutdown()
    }

    @Test func delayedOpensAndClosedTabsUseALivePaneAfterTheirOriginalPaneIsRemoved() async throws {
        let workspace = await workspace()
        let first = workspace.newDocument()
        let pane = try #require(workspace.splitDocument(first.id, direction: .up))
        let other = try #require(workspace.selectedDocument)
        let context = workspace.capturePaneSelection()
        await workspace.closeDocument(other)
        #expect(!workspace.paneLayout.paneIDs.contains(pane))
        workspace.selectDocument(first.id, in: .left)
        let delayed = SQLDocument(title: "Delayed", text: "SELECT 'delayed';")
        workspace.addDocument(delayed, context: context)
        #expect(workspace.pane(containing: delayed.id) == .left && workspace.selectedDocument === first)
        let reopened = try #require(workspace.reopenClosedTab())
        #expect(workspace.pane(containing: reopened.id) == .left && workspace.selectedDocument === reopened)
        #expect(!workspace.paneLayout.isSplit && reopened.runtime == nil)
        #expect(workspace.paneLayout.isValid(documentIDs: workspace.documents.map(\.id)))
        await workspace.shutdown()
    }

    @Test func unsplittingAnInactivePaneIntoAnEmptySiblingKeepsTheActiveSelection() async throws {
        let workspace = await workspace()
        let active = workspace.newDocument()
        let emptySibling = try #require(workspace.splitDocument(active.id, direction: .right))
        let moved = try #require(workspace.selectedDocument)
        let source = try #require(workspace.splitDocument(moved.id, direction: .down))
        let created = try #require(workspace.selectedDocument)
        workspace.moveDocument(moved.id, to: .left)
        workspace.selectDocument(active.id, in: .left)
        workspace.unsplitPane(source)
        #expect(workspace.selectedDocument === active && workspace.activePaneID == .left)
        #expect(workspace.selectedDocument(in: emptySibling) === created)
        #expect(workspace.paneLayout.isValid(documentIDs: workspace.documents.map(\.id)))
        await workspace.shutdown()
    }

    @Test func mixedDirectionTreesRoundTripAndRestoreEveryTabDisconnected() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/pane-tree/\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSQLDocumentStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let workspace = await workspace(store: store)
        let original = workspace.newDocument()
        for direction in WorkspaceSplitDirection.allCases {
            let tab = try #require(workspace.selectedDocument)
            try #require(workspace.splitDocument(tab.id, direction: direction) != nil)
        }
        for (index, id) in workspace.paneLayout.root.splitIDs.enumerated() {
            workspace.setSplitFraction(0.3 + Double(index) * 0.1, for: id)
        }
        await workspace.flushDocuments()
        let expected = workspace.paneLayout
        let restored = await self.workspace(store: store)
        #expect(restored.paneLayout == expected && restored.documents.count == 5)
        #expect(restored.documents.allSatisfy { $0.runtime == nil && $0.grid == nil && !$0.isRunning })
        #expect(restored.paneLayout.pane(containing: original.id) == .left)
        await restored.clearRestoredDocuments()
        #expect(restored.documents.isEmpty && restored.paneLayout.isValid(documentIDs: []))
        #expect(restored.paneLayout.paneIDs.count == 1 && !restored.paneLayout.isSplit)
        await restored.shutdown()
        await workspace.shutdown()
    }

    @Test(arguments: [8, 9])
    func legacyLayoutsMigrateWithAnExactPrivateBackup(version: Int) async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/pane-migration/\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = StoredSQLDocument(title: "Retained", text: "SELECT 'retained';")
        let snapshot = SQLWorkspaceSnapshot(documents: [document], paneLayout: WorkspacePaneLayout(
            right: WorkspacePaneState(documentIDs: [document.id], selectedDocumentID: document.id), activePaneID: .right, splitFraction: 0.7))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any])
        object["version"] = version
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let url = directory.appendingPathComponent("workspace.json")
        try bytes.write(to: url)
        let restored = try await FileSQLDocumentStore(fileURL: url).load()
        #expect(restored == snapshot)
        let backup = url.appendingPathExtension("v\(version).backup")
        #expect(try Data(contentsOf: backup) == bytes)
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func malformedTreesAndNewTreeFieldsInOlderVersionsAreRejectedWithoutReplacingBytes() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/pane-invalid/\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let valid = try #require(JSONSerialization.jsonObject(with: encoder.encode(SQLWorkspaceSnapshot())) as? [String: Any])
        let layout = try #require(valid["paneLayout"] as? [String: Any])
        let duplicateLeaf: [String: Any] = ["splitID": UUID().uuidString, "axis": "horizontal", "fraction": 0.5,
            "first": ["paneID": "left"], "second": ["paneID": "left"]]
        var cases: [[String: Any]] = []
        for tree in [NSNull(), ["paneID": "missing"], duplicateLeaf,
                     duplicateLeaf.merging(["fraction": 0.99, "second": ["paneID": "right"]]) { _, new in new },
                     ["paneID": "left", "sessionId": "forbidden"]] as [Any] {
            cases.append(valid.merging(["paneLayout": layout.merging(["tree": tree]) { _, new in new }]) { _, new in new })
        }
        for version in [8, 9] {
            cases.append(valid.merging(["version": version,
                "paneLayout": layout.merging(["tree": ["paneID": "left"]]) { _, new in new }]) { _, new in new })
        }
        let url = directory.appendingPathComponent("workspace.json")
        let store = FileSQLDocumentStore(fileURL: url)
        for malformed in cases {
            let bytes = try JSONSerialization.data(withJSONObject: malformed)
            try bytes.write(to: url)
            await #expect(throws: SQLDocumentStoreError.self) { _ = try await store.load() }
            await #expect(throws: SQLDocumentStoreError.self) { try await store.save(SQLWorkspaceSnapshot()) }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }
}
