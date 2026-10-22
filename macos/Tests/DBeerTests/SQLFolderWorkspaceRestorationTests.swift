import Foundation
import Testing
@testable import DBeer

/// Delayed local persistence and directory models only. No windows, native
/// choosers, application activation or database/helper processes are used.
@Suite(.serialized)
@MainActor
struct SQLFolderWorkspaceRestorationTests {
    @MainActor private final class Counter { var helperStarts = 0 }

    private final class Directory {
        let url: URL

        init() throws {
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            url = repository.appendingPathComponent("build/r12-r13/folder-restoration/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func folder(_ name: String) throws -> URL {
            let folder = url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private actor DelayedStore: SQLDocumentStore {
        private var snapshot: SQLWorkspaceSnapshot
        private var loadContinuation: CheckedContinuation<Void, Never>?
        private var released = false
        private var started = false
        private var writes: [SQLWorkspaceSnapshot] = []

        init(snapshot: SQLWorkspaceSnapshot) { self.snapshot = snapshot }

        func load() async -> SQLWorkspaceSnapshot {
            let saved = snapshot
            started = true
            if !released { await withCheckedContinuation { loadContinuation = $0 } }
            return saved
        }

        func save(_ snapshot: SQLWorkspaceSnapshot) {
            writes.append(snapshot)
            self.snapshot = snapshot
        }

        func hasStarted() -> Bool { started }
        func savedSnapshots() -> [SQLWorkspaceSnapshot] { writes }
        func storedSnapshot() -> SQLWorkspaceSnapshot { snapshot }

        func release() {
            released = true
            loadContinuation?.resume()
            loadContinuation = nil
        }
    }

    private func workspace(store: DelayedStore, counter: Counter) -> ApplicationWorkspace {
        ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store,
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), automaticallyWatchFiles: false,
            closeDecision: { _ in .rollback },
            helperFactory: { counter.helperStarts += 1; return BackendClient() })
    }

    @Test func attachmentsAddedDuringLoadMergeAndAutosaveWithoutLocalDocuments() async throws {
        let directory = try Directory()
        let saved = SQLFolderAttachment(url: try directory.folder("saved"))
        let store = DelayedStore(snapshot: SQLWorkspaceSnapshot(sqlFolders: [saved]))
        let counter = Counter()
        let workspace = workspace(store: store, counter: counter)
        let restoration = Task { await workspace.restoreSavedWorkspace() }
        defer {
            Task {
                await store.release()
                await restoration.value
                await workspace.shutdown()
            }
        }
        try await eventually { await store.hasStarted() }
        let local = try await workspace.sqlFolders.attach(directory.folder("attached-during-load"))
        #expect(workspace.documents.isEmpty)
        #expect(await store.savedSnapshots().isEmpty)
        await store.release()
        await restoration.value

        #expect(workspace.error == nil && workspace.documents.isEmpty)
        #expect(workspace.sqlFolders.attachments == [saved, local])
        #expect(workspace.sqlFolders.roots.allSatisfy { $0.children == nil && !$0.isLoading })
        // This assertion deliberately precedes flush/shutdown: the merge must
        // schedule its own save even though no document changed after loading.
        try await eventually { !(await store.savedSnapshots()).isEmpty }
        let written = try #require(await store.savedSnapshots().last)
        #expect(written.documents.isEmpty && written.sqlFolders == [saved, local])
        #expect(counter.helperStarts == 0)
        await workspace.shutdown()
        #expect(await store.storedSnapshot().sqlFolders == [saved, local])
        #expect(counter.helperStarts == 0)
    }

    @Test func attachmentOverflowDuringLoadPreservesSavedSnapshotThroughFlushAndShutdown() async throws {
        let directory = try Directory()
        let savedFolders = (0..<32).map {
            SQLFolderAttachment(url: directory.url.appendingPathComponent("saved-\($0)"))
        }
        let draft = StoredSQLDocument(title: "Preserved draft", text: "SELECT 'e\u{301}';\r\n")
        let saved = SQLWorkspaceSnapshot(documents: [draft], selectedDocumentID: draft.id, sqlFolders: savedFolders)
        let store = DelayedStore(snapshot: saved)
        let counter = Counter()
        let workspace = workspace(store: store, counter: counter)
        let restoration = Task { await workspace.restoreSavedWorkspace() }
        defer {
            Task {
                await store.release()
                await restoration.value
                await workspace.shutdown()
            }
        }
        try await eventually { await store.hasStarted() }
        let local = try await workspace.sqlFolders.attach(directory.folder("attached-during-load"))
        await store.release()
        await restoration.value

        #expect(workspace.error != nil)
        #expect(workspace.sqlFolders.attachments == [local] && workspace.documents.isEmpty)
        #expect(await store.savedSnapshots().isEmpty)
        // Ordinary document changes and explicit flush must remain unable to
        // replace a snapshot whose restoration failed.
        _ = workspace.newDocument(text: "SELECT 'new local draft';\r\n")
        await workspace.flushDocuments()
        #expect(await store.savedSnapshots().isEmpty)
        #expect(await store.storedSnapshot() == saved)
        await workspace.shutdown()
        #expect(await store.savedSnapshots().isEmpty)
        let preserved = await store.storedSnapshot()
        #expect(preserved == saved)
        #expect(preserved.documents.first?.text.utf8.elementsEqual(draft.text.utf8) == true)
        #expect(counter.helperStarts == 0)
    }

    private func eventually(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await predicate())
    }
}
