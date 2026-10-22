import Foundation
import Testing
@testable import DBeer

/// Known bindings use ordinary Save directly, without opening a native chooser.
@MainActor
struct WorkspaceFileBindingTests {
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("build/r09/files/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func changedBoundFileDoesNotReplaceRecoveredTextOrItsBinding() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("analysis.sql")
        try Data("SELECT 'accepted version';".utf8).write(to: url)
        let baseline = try SQLFileBinding.read(url).sha256
        let stored = StoredSQLDocument(title: "Recovered analysis", text: "SELECT 'unsaved draft';", fileURL: url,
            fileContentSHA256: baseline)
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(documents: [stored], selectedDocumentID: stored.id))
        let external = Data("SELECT 'changed while closed';".utf8)
        try external.write(to: url)
        var helperStarts = 0
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store,
            helperFactory: { helperStarts += 1; return BackendClient() })
        await workspace.restoreSavedWorkspace()
        let document = try #require(workspace.documents.first)
        #expect(document.text == stored.text && document.restoredFileBinding)
        #expect(try Data(contentsOf: url) == external)
        workspace.saveSQLFile(document)
        #expect(workspace.error != nil && document.storedState == stored)
        #expect(document.restoredFileBinding && document.runtime == nil && helperStarts == 0)
        #expect(try Data(contentsOf: url) == external)
        await workspace.flushDocuments()
        #expect(await store.load().documents == [stored])
        await workspace.shutdown()
    }

    @Test func explicitSaveOfUnchangedRecoveredFileUpdatesThePersistedFingerprint() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("analysis.sql")
        try Data("SELECT 'accepted';\r\n".utf8).write(to: url)
        let baseline = try SQLFileBinding.read(url).sha256
        let stored = StoredSQLDocument(title: "Recovered analysis", text: "SELECT 'unsaved κόσμος';\r\n", fileURL: url,
            fileContentSHA256: baseline)
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(documents: [stored], selectedDocumentID: stored.id))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store)
        await workspace.restoreSavedWorkspace()
        let document = try #require(workspace.documents.first)
        workspace.saveSQLFile(document)
        #expect(workspace.error == nil && !document.restoredFileBinding && document.runtime == nil)
        #expect(document.fileURL == url && document.title == "analysis.sql")
        let current = try SQLFileBinding.read(url)
        #expect(Data(current.text.utf8) == Data(stored.text.utf8))
        #expect(document.fileContentSHA256 == current.sha256 && current.sha256 != baseline)
        await workspace.flushDocuments()
        #expect(await store.load().documents.first == document.storedState)
        await workspace.shutdown()
    }
}
