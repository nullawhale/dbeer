import Foundation
import Testing
@testable import DBeer

/// Filesystem events only. No native controls, application or windows are used.
@Suite(.serialized)
@MainActor
struct SQLFileWatcherTests {
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("build/r12-r13/watchers/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func inPlaceAndAtomicReplacementRemainObservedAtTheOriginalURL() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("query.sql")
        try Data("SELECT 1;".utf8).write(to: url)
        var changes: [URL?] = []
        let watcher = SQLFileWatcher(url: url) { changes.append($0) }
        defer { watcher.stop() }
        try Data("SELECT 2;".utf8).write(to: url)
        try await eventually { changes.count >= 1 }
        let first = changes.count
        try Data("SELECT 3;".utf8).write(to: url, options: .atomic)
        try await eventually { changes.count > first }
        let second = changes.count
        try Data("SELECT 4;".utf8).write(to: url)
        try await eventually { changes.count > second }
        #expect(changes.allSatisfy { $0 == nil } && watcher.url == url)
    }

    @Test func fileAndParentRenameReturnTheReliableNewURL() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalParent = directory.appendingPathComponent("original", isDirectory: true)
        let newParent = directory.appendingPathComponent("renamed", isDirectory: true)
        try FileManager.default.createDirectory(at: originalParent, withIntermediateDirectories: true)
        let original = originalParent.appendingPathComponent("query.sql")
        let renamed = originalParent.appendingPathComponent("renamed.sql")
        try Data("SELECT 1;".utf8).write(to: original)
        var moved: [URL] = []
        let watcher = SQLFileWatcher(url: original) { if let url = $0 { moved.append(url) } }
        defer { watcher.stop() }
        try FileManager.default.moveItem(at: original, to: renamed)
        try await eventually { moved.contains(renamed) }
        try FileManager.default.moveItem(at: originalParent, to: newParent)
        let afterParentMove = newParent.appendingPathComponent("renamed.sql")
        try await eventually { moved.contains(afterParentMove) }
        #expect(watcher.url == afterParentMove)
    }

    @Test func deletionRecreationAndStoppingDoNotLoseOrLeakObservation() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("query.sql")
        try Data("SELECT 1;".utf8).write(to: url)
        var changes = 0
        let watcher = SQLFileWatcher(url: url) { _ in changes += 1 }
        try FileManager.default.removeItem(at: url)
        try await eventually { changes > 0 }
        let removed = changes
        try Data("SELECT 2;".utf8).write(to: url)
        try await eventually { changes > removed }
        watcher.stop()
        let stopped = changes
        try Data("SELECT 3;".utf8).write(to: url)
        try await Task.sleep(for: .milliseconds(160))
        #expect(changes == stopped && watcher.url == url)
    }

    @Test func directoryChildrenAndRootRenameAreObservedWithoutReadingFiles() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("folder", isDirectory: true)
        let renamed = directory.appendingPathComponent("renamed", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var changes = 0
        var move: URL?
        let watcher = SQLFileWatcher(url: root) { changes += 1; if let url = $0 { move = url } }
        defer { watcher.stop() }
        try Data("SELECT 1;".utf8).write(to: root.appendingPathComponent("new.sql"))
        try await eventually { changes > 0 }
        try FileManager.default.moveItem(at: root, to: renamed)
        try await eventually { move == renamed }
        #expect(watcher.url == renamed)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}
