import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DBeer

/// Filesystem/model tests only. They never create a helper, database or window.
struct ResultSnapshotStoreTests {
    private enum InjectedFailure: Error { case diskFull, write, settings }

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/r16/storage-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func capture(rows: [[String?]]? = nil) -> ResultSnapshotCapture {
        ResultSnapshotCapture(title: "Exact result", sql: "SELECT fixture_values;", engine: .postgresql,
            columns: [ResultColumn(index: 0, name: "same", typeOid: 25, nativeType: "text"),
                      ResultColumn(index: 1, name: "same", typeOid: 1700, nativeType: "numeric"),
                      ResultColumn(index: 2, name: "binary", typeOid: 17, nativeType: "bytea", encoding: "base64")],
            rows: rows ?? [[nil, "9007199254740993.123456789", "AP8="], ["", "-0.000000000000000001", ""], ["NULL", "1e1000", nil]],
            capturedAt: Date(timeIntervalSince1970: 1_790_000_000.125), profileID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"),
            profileName: "Historical profile", environment: .production, outcome: .cancelled,
            truncated: true, partial: true, sourceRowCount: 30, commandTag: "SELECT")
    }

    @Test func exactValuesMetadataPrivatePermissionsAndPagedRestart() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("snapshots")
        let store = ResultSnapshotStore(rootURL: root)
        let source = capture()
        let saved = try await store.save(source)
        #expect(saved.rowCount == 3 && saved.truncated && saved.partial && saved.profileName == "Historical profile")
        let usage = try await store.usage()
        #expect(usage.snapshotCount == 1 && usage.usedBytes == saved.byteCount)
        #expect(usage.quotaBytes == 1_073_741_824)
        let restarted = ResultSnapshotStore(rootURL: root)
        let first = try await restarted.load(id: saved.id, offset: 0, limit: 2)
        #expect(first.rows == Array(source.rows.prefix(2)) && first.offset == 0 && first.hasMore)
        #expect(first.manifest.columns == source.columns && first.manifest.sql == source.sql)
        #expect(first.manifest.capturedAt == source.capturedAt && first.manifest.environment == .production)
        #expect(first.manifest.outcome == .cancelled && first.manifest.sourceRowCount == 30)
        #expect(!first.manifest.isComplete)
        let last = try await restarted.load(id: saved.id, offset: 2, limit: 2)
        #expect(last.rows == [source.rows[2]] && !last.hasMore)
        #expect(try await restarted.load(id: saved.id, offset: 100, limit: 2).rows.isEmpty)
        #expect(try await restarted.list() == [saved])
        let artifact = root.appendingPathComponent(saved.id.uuidString.lowercased())
        for folder in [root, artifact] {
            #expect((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
        for name in ["manifest.json", "rows.jsonl"] {
            #expect((try FileManager.default.attributesOfItem(atPath: artifact.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let rowBytes = try Data(contentsOf: artifact.appendingPathComponent("rows.jsonl"))
        #expect(rowBytes.last == 10)
        #expect(rowBytes.count == first.manifest.rowsBytes)
    }

    @Test func structuralTypeIdentitySurvivesSaveAndOfflineRestart() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = capture(rows: [["new", "1", "AP8="]])
        source.columns[0] = ResultColumn(index: 0, name: "mood", nativeType: "\"fixture\".\"mood\"",
            typeIdentity: "pgtype-v1:" + String(repeating: "a", count: 64))
        let saved = try await ResultSnapshotStore(rootURL: directory).save(source)
        let restarted = ResultSnapshotStore(rootURL: directory)
        let loaded = try await restarted.load(id: saved.id)
        #expect(loaded.manifest.columns == source.columns)
        #expect(loaded.manifest.columns[0].typeIdentity == source.columns[0].typeIdentity)
        #expect(loaded.rows == source.rows)
    }

    @Test func quotaCountsWrittenManifestAndRowsAndNeverEvictsExistingSnapshots() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultSnapshotStore(rootURL: directory)
        let saved = try await store.save(capture())
        try await store.setQuotaBytes(saved.byteCount)
        let before = try await store.usage()
        await #expect(throws: ResultSnapshotError.quotaExceeded) { _ = try await store.save(capture(rows: [])) }
        #expect(try await store.usage() == before)
        #expect(try await store.list() == [saved])
        #expect(try await store.load(id: saved.id).rows == capture().rows)
        await #expect(throws: ResultSnapshotError.invalidQuota) { try await store.setQuotaBytes(saved.byteCount - 1) }
        await #expect(throws: ResultSnapshotError.invalidQuota) { try await store.setQuotaBytes(0) }
        #expect(try await ResultSnapshotStore(rootURL: directory).usage().quotaBytes == saved.byteCount)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: directory.path)).contains { $0.hasPrefix(".partial-") })
    }

    @Test func emptyResultAndSharedArtifactFixtureRemainOfflineAndLossless() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultSnapshotStore(rootURL: directory)
        let empty = try await store.save(capture(rows: []))
        let restoredEmpty = try await store.load(id: empty.id)
        #expect(restoredEmpty.rows.isEmpty && restoredEmpty.manifest.columns == capture().columns)
        #expect(restoredEmpty.manifest.rowsBytes == 0 && !restoredEmpty.hasMore)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let fixture = repository.appendingPathComponent("protocol/fixtures/snapshot-v1/\(id.uuidString.lowercased())")
        try FileManager.default.copyItem(at: fixture, to: directory.appendingPathComponent(id.uuidString.lowercased()))
        let loaded = try await store.load(id: id)
        #expect(loaded.rows == capture().rows && loaded.manifest.capturedAt == capture().capturedAt)
        #expect(loaded.manifest.columns == capture().columns && loaded.manifest.sourceRowCount == 30)
        #expect(loaded.manifest.truncated && loaded.manifest.partial)
    }

    @Test func sourceCountLargerThanLoadedRowsCannotClaimACompleteResult() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultSnapshotStore(rootURL: directory)
        var source = capture()
        source.truncated = false
        source.partial = false
        source.outcome = .succeeded
        let saved = try await store.save(source)
        #expect(saved.partial && !saved.truncated)
        let loaded = try await store.load(id: saved.id)
        #expect(loaded.manifest.partial && !loaded.manifest.isComplete)
        var inconsistent = loaded.manifest
        inconsistent.partial = false
        #expect(!inconsistent.isComplete)
        #expect(try await store.list().first?.partial == true)
        source.sourceRowCount = Int64(source.rows.count - 1)
        await #expect(throws: ResultSnapshotError.invalid) { _ = try await store.save(source) }
        source.sourceRowCount = Int64(source.rows.count)
        let complete = try await store.save(source)
        #expect(!complete.partial)
        #expect(try await store.load(id: complete.id).manifest.isComplete)
    }

    @Test func writeFailuresAtEveryPublicationStagePreservePriorSnapshots() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try await ResultSnapshotStore(rootURL: directory).save(capture())
        for stage in 0..<3 {
            let store = ResultSnapshotStore(rootURL: directory, writeInterceptor: { point in
                switch (stage, point) {
                case (0, .row(1)): throw InjectedFailure.diskFull
                case (1, .manifest), (2, .publication): throw InjectedFailure.write
                default: break
                }
            })
            await #expect(throws: ResultSnapshotError.write) { _ = try await store.save(capture()) }
            #expect(try await store.list() == [original])
            #expect(try await store.load(id: original.id).rows == capture().rows)
            #expect(!(try FileManager.default.contentsOfDirectory(atPath: directory.path)).contains { $0.hasPrefix(".partial-") })
        }
        let settingsStore = ResultSnapshotStore(rootURL: directory, writeInterceptor: { point in
            if case .settings = point { throw InjectedFailure.settings }
        })
        await #expect(throws: ResultSnapshotError.write) { try await settingsStore.setQuotaBytes(10_000) }
        #expect(try await settingsStore.usage().quotaBytes == ResultSnapshotStore.defaultQuotaBytes)
        #expect(try await settingsStore.list() == [original])
    }

    @Test func interruptedTempsAreCleanedWithoutTouchingPublishedArtifactsOrForeignPaths() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultSnapshotStore(rootURL: directory)
        let original = try await store.save(capture())
        let temporary = directory.appendingPathComponent(".partial-33333333-3333-3333-3333-333333333333")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        try Data("interrupted".utf8).write(to: temporary.appendingPathComponent("rows.jsonl"))
        let settingsTemporary = directory.appendingPathComponent(".settings-33333333-3333-3333-3333-333333333333.tmp")
        try Data("interrupted".utf8).write(to: settingsTemporary)
        try await store.cleanup()
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(!FileManager.default.fileExists(atPath: settingsTemporary.path))
        #expect(try await store.list() == [original])
        #expect(try await store.load(id: original.id).rows == capture().rows)
    }

    @Test func corruptedRowsManifestsVersionsAndSymlinksNeverReturnValues() async throws {
        for kind in 0..<4 {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ResultSnapshotStore(rootURL: directory)
            let item = try await store.save(capture())
            let artifact = directory.appendingPathComponent(item.id.uuidString.lowercased())
            let rows = artifact.appendingPathComponent("rows.jsonl")
            let manifest = artifact.appendingPathComponent("manifest.json")
            switch kind {
            case 0:
                var data = try Data(contentsOf: rows)
                data[1] = data[1] == 32 ? 33 : 32
                try data.write(to: rows)
            case 1:
                var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
                json["version"] = 99
                try JSONSerialization.data(withJSONObject: json).write(to: manifest)
            case 2:
                try FileManager.default.removeItem(at: rows)
                try FileManager.default.createSymbolicLink(at: rows, withDestinationURL: manifest)
            default:
                try FileManager.default.removeItem(at: manifest)
            }
            await #expect(throws: ResultSnapshotError.corrupt) { _ = try await store.load(id: item.id) }
        }
    }

    @Test func rootsAndArtifactLinksCannotEscapeManagedStorage() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let linked = directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        await #expect(throws: ResultSnapshotError.unavailable) { _ = try await ResultSnapshotStore(rootURL: linked).save(capture()) }
        let root = directory.appendingPathComponent("root")
        let store = ResultSnapshotStore(rootURL: root)
        _ = try await store.usage()
        let id = UUID()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(id.uuidString.lowercased()), withDestinationURL: outside)
        await #expect(throws: ResultSnapshotError.corrupt) { _ = try await store.load(id: id) }
        #expect(try await store.list().first?.isAvailable == false)
        #expect(try await store.usage().usedBytes > 0)
        try await store.delete(id: id, confirmation: true)
        #expect(try await store.list().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func referencedDeletionRequiresExplicitConfirmationAndMissingReferencesStayMissing() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultSnapshotStore(rootURL: directory)
        let item = try await store.save(capture())
        await #expect(throws: ResultSnapshotError.referenceConfirmationRequired) {
            try await store.delete(id: item.id, referencedBy: [UUID()])
        }
        #expect(try await store.list() == [item])
        try await store.delete(id: item.id, referencedBy: [UUID()], confirmation: true)
        #expect(try await store.list().isEmpty)
        #expect(try await store.usage().usedBytes == 0)
        await #expect(throws: ResultSnapshotError.notFound) { _ = try await store.load(id: item.id) }
    }

    @Test func corruptArtifactsRemainListedCountedAndDeletableBesideIntactSnapshots() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultSnapshotStore(rootURL: directory)
        let intact = try await store.save(capture())
        let damaged = try await store.save(capture())
        let damagedURL = directory.appendingPathComponent(damaged.id.uuidString.lowercased())
        try Data("broken metadata".utf8).write(to: damagedURL.appendingPathComponent("manifest.json"))
        let list = try await store.list()
        #expect(list.count == 2)
        let unavailable = try #require(list.first { $0.id == damaged.id })
        #expect(!unavailable.isAvailable && unavailable.byteCount > 0)
        #expect(list.first { $0.id == intact.id } == intact)
        #expect(try await store.usage().usedBytes == intact.byteCount + unavailable.byteCount)
        #expect(try await store.load(id: intact.id).rows == capture().rows)
        try await store.delete(id: damaged.id, confirmation: true)
        #expect(try await store.list() == [intact])
        #expect(try await store.usage().usedBytes == intact.byteCount)
    }

    @Test func malformedCaptureAndCancelledPublicationCreateNoVisibleArtifact() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultSnapshotStore(rootURL: directory)
        var malformed = capture()
        malformed.rows = [["wrong-width"]]
        await #expect(throws: ResultSnapshotError.invalid) { _ = try await store.save(malformed) }
        malformed = capture()
        malformed.rows[0][2] = "not base64!"
        await #expect(throws: ResultSnapshotError.invalid) { _ = try await store.save(malformed) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.save(capture())
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await store.list().isEmpty)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: directory.path)).contains { $0.hasPrefix(".partial-") })
    }

    @Test func independentActorsSerializeQuotaAndCannotOverpublish() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ResultSnapshotStore(rootURL: directory)
        let sample = try await first.save(capture())
        try await first.delete(id: sample.id)
        // Enough for exactly one artifact; IDs have a fixed encoded length.
        try await first.setQuotaBytes(sample.byteCount)
        let second = ResultSnapshotStore(rootURL: directory)
        let value = capture()
        async let a: ResultSnapshotSummary? = try? first.save(value)
        async let b: ResultSnapshotSummary? = try? second.save(value)
        let results = await [a, b]
        #expect(results.compactMap { $0 }.count == 1)
        #expect(try await first.list().count == 1)
        #expect(try await first.usage().usedBytes <= sample.byteCount)
    }
}
