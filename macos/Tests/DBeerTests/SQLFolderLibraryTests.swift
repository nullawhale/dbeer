import Foundation
import Testing
@testable import DBeer

/// Local directories, model state and filesystem notifications only. No native
/// controls, windows, application activation or clipboard are used.
@Suite(.serialized)
@MainActor
struct SQLFolderLibraryTests {
    private final class Fixture {
        let container: URL
        let root: URL

        init() throws {
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            container = repository.appendingPathComponent("build/r12-r13/folders/\(UUID().uuidString)")
            root = container.appendingPathComponent("queries")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        @discardableResult func file(_ relative: String, text: String = "SELECT 'fixture';\n", under root: URL? = nil) throws -> URL {
            let url = (root ?? self.root).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }

        deinit { try? FileManager.default.removeItem(at: container) }
    }

    @Test func attachmentsAreValidatedDeduplicatedAndRestoredWithoutDiskReads() async throws {
        let fixture = try Fixture()
        let library = SQLFolderLibrary(automaticallyRefresh: false)
        defer { library.shutdown() }
        let first = try await library.attach(fixture.root)
        #expect(try await library.attach(fixture.root) == first)
        #expect(library.attachments == [first] && library.roots.count == 1)
        #expect(library.roots[0].children == nil && !library.roots[0].isLoading)
        let file = try fixture.file("query.sql")
        let link = fixture.container.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        for url in [file, link, fixture.container.appendingPathComponent("absent"), URL(string: "https://example.invalid/queries")!] {
            await #expect(throws: SQLFolderError.self) { try await library.attach(url) }
        }
        let missing = SQLFolderAttachment(url: fixture.container.appendingPathComponent("not-created"))
        #expect(library.restore([missing]))
        #expect(library.attachments == [missing] && library.roots[0].children == nil && library.roots[0].error == nil)
        #expect(!FileManager.default.fileExists(atPath: missing.url.path))
        #expect(!library.restore([missing, missing]))
        #expect(library.attachments == [missing])
        let decoded = try JSONDecoder().decode(SQLFolderAttachment.self, from: JSONEncoder().encode(first))
        #expect(decoded == first)
        let future = Data("{\"id\":\"\(first.id)\",\"url\":\"\(first.url.absoluteString)\",\"future\":true}".utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SQLFolderAttachment.self, from: future) }
    }

    @Test func lazyTreeOnlyLoadsDirectSQLFilesAndRetainsExpandedNodesAcrossRefresh() async throws {
        let fixture = try Fixture()
        _ = try fixture.file("report.SQL")
        _ = try fixture.file("readme.txt")
        _ = try fixture.file("nested/one.sql")
        _ = try fixture.file("nested/deeper/two.sql")
        for name in [".git", "build", ".build", "target", "node_modules", "dist"] { _ = try fixture.file(name + "/hidden.sql") }
        let outside = fixture.container.appendingPathComponent("outside")
        _ = try fixture.file("outside.sql", under: outside)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("outside-link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("linked.sql"), withDestinationURL: outside.appendingPathComponent("outside.sql"))
        let library = SQLFolderLibrary(automaticallyRefresh: false)
        defer { library.shutdown() }
        _ = try await library.attach(fixture.root)
        let root = try #require(library.roots.first)
        #expect(root.children == nil)
        await library.loadChildren(root)
        #expect(root.children?.map(\.name) == ["nested", "report.SQL"])
        let nested = try #require(root.children?.first { $0.name == "nested" })
        #expect(nested.children == nil)
        nested.isExpanded = true
        await library.loadChildren(nested)
        #expect(nested.children?.map(\.name) == ["deeper", "one.sql"])
        #expect(nested.children?.first?.children == nil)
        _ = try fixture.file("nested/added.sql")
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("report.SQL"))
        await library.refresh()
        #expect(root.children?.map(\.name) == ["nested"])
        #expect(root.children?.first === nested && nested.isExpanded)
        #expect(nested.children?.map(\.name) == ["deeper", "added.sql", "one.sql"])
        #expect(nested.children?.first?.children == nil)
    }

    @Test func missingFolderKeepsCachedPathsAndRefreshUsesReplacementDirectory() async throws {
        let fixture = try Fixture()
        _ = try fixture.file("old.sql")
        let library = SQLFolderLibrary(automaticallyRefresh: false)
        defer { library.shutdown() }
        _ = try await library.attach(fixture.root)
        let root = try #require(library.roots.first)
        await library.loadChildren(root)
        try FileManager.default.removeItem(at: fixture.root)
        await library.refresh()
        #expect(root.error != nil && root.children?.map(\.name) == ["old.sql"])
        _ = try fixture.file("checkout/new.sql")
        await library.refresh()
        #expect(root.error == nil && root.children?.map(\.name) == ["checkout"])
        #expect(root.children?.first?.children == nil)
    }

    @Test func watcherFollowsAttachedRootRenameAndRefreshesDeleteAndRecreation() async throws {
        let fixture = try Fixture()
        _ = try fixture.file("one.sql")
        let library = SQLFolderLibrary(pollInterval: .seconds(60))
        defer { library.shutdown() }
        let attachment = try await library.attach(fixture.root)
        let root = try #require(library.roots.first)
        root.isExpanded = true
        await library.loadChildren(root)
        let renamed = fixture.container.appendingPathComponent("renamed-queries")
        try FileManager.default.moveItem(at: fixture.root, to: renamed)
        try await eventually { library.attachments.first?.url.path == renamed.path }
        let movedRoot = try #require(library.roots.first)
        try await eventually { movedRoot.children?.first?.url.path == renamed.appendingPathComponent("one.sql").path }
        #expect(library.attachments.first?.id == attachment.id && movedRoot.isExpanded)
        try FileManager.default.removeItem(at: renamed)
        try await eventually { movedRoot.error != nil }
        _ = try fixture.file("recreated.sql", under: renamed)
        try await eventually { movedRoot.error == nil && movedRoot.children?.map(\.name) == ["recreated.sql"] }
    }

    private actor SearchGate {
        private var started: Set<String> = []
        private var continuations: [String: CheckedContinuation<SQLFolderSearchBatch, Never>] = [:]

        func wait(_ query: String) async -> SQLFolderSearchBatch {
            started.insert(query)
            return await withCheckedContinuation { continuations[query] = $0 }
        }
        func hasStarted(_ query: String) -> Bool { started.contains(query) }
        func release(_ query: String, batch: SQLFolderSearchBatch) { continuations.removeValue(forKey: query)?.resume(returning: batch) }
    }

    @Test func newerSearchOwnsPublicationEvenWhenOldWorkerIgnoresCancellation() async throws {
        let fixture = try Fixture()
        let gate = SearchGate()
        let library = SQLFolderLibrary(automaticallyRefresh: false, searchWorker: { _, query, _, _ in await gate.wait(query) })
        defer { library.shutdown() }
        let attachment = try await library.attach(fixture.root)
        let old = library.updateSearch(query: "old")
        try await eventually { await gate.hasStarted("old") }
        let fresh = library.updateSearch(query: "new", mode: .contents)
        try await eventually { await gate.hasStarted("new") }
        let match = SQLFolderSearchMatch(attachmentID: attachment.id, url: fixture.root.appendingPathComponent("new.sql"),
            relativePath: "new.sql", lineNumber: 2, preview: "-- new match")
        await gate.release("new", batch: SQLFolderSearchBatch(matches: [match]))
        await fresh.value
        #expect(library.searchResults == [match] && !library.isSearching)
        await gate.release("old", batch: SQLFolderSearchBatch(matches: []))
        await old.value
        #expect(library.searchResults == [match] && !library.isSearching)
    }

    @Test(arguments: [false, true])
    func detachOrShutdownPreventsPendingSearchDelivery(shutdown: Bool) async throws {
        let fixture = try Fixture()
        let gate = SearchGate()
        let library = SQLFolderLibrary(automaticallyRefresh: false, searchWorker: { _, query, _, _ in await gate.wait(query) })
        defer { library.shutdown() }
        let attachment = try await library.attach(fixture.root)
        let search = library.updateSearch(query: "pending")
        try await eventually { await gate.hasStarted("pending") }
        if shutdown { library.shutdown() } else { library.detach(attachment.id); library.cancelSearch() }
        let match = SQLFolderSearchMatch(attachmentID: attachment.id, url: fixture.root.appendingPathComponent("old.sql"),
            relativePath: "old.sql", lineNumber: nil, preview: nil)
        await gate.release("pending", batch: SQLFolderSearchBatch(matches: [match]))
        await search.value
        #expect(library.searchResults.isEmpty && !library.isSearching)
    }

    private func eventually(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await predicate())
    }
}
