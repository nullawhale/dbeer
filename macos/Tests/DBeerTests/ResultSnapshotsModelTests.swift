import Foundation
import Testing
@testable import DBeer

/// Local models and private test artifacts only. No windows, desktop access,
/// Keychain, helper process or database connection is created.
@MainActor
struct ResultSnapshotsModelTests {
    private func directory() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/r16/model-\(UUID().uuidString)")
    }

    private func capture() -> ResultSnapshotCapture {
        ResultSnapshotCapture(title: "Result fixture", sql: "SELECT fixture;", engine: .postgresql,
            columns: [ResultColumn(index: 0, name: "value", nativeType: "text")],
            rows: [[nil], [""], ["NULL"]], profileName: "Synthetic profile", truncated: true)
    }

    @Test func creationIsLazyAndManagementDoesNotConnect() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ResultSnapshotsModel(store: ResultSnapshotStore(rootURL: root))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), resultSnapshots: model)
        #expect(workspace.resultSnapshots === model)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(model.snapshots.isEmpty && model.quotaBytes == 1_073_741_824)
        #expect(workspace.documents.isEmpty && workspace.services.isEmpty)
        await model.refresh()
        #expect(model.error == nil && !model.isBusy && model.usedBytes == 0)
        #expect(workspace.documents.isEmpty && workspace.services.isEmpty)
    }

    @Test func explicitRefreshListsSavedSizesAndQuotaChangesPersistWithoutEviction() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResultSnapshotStore(rootURL: root)
        let summary = try await store.save(capture())
        let model = ResultSnapshotsModel(store: store)
        #expect(model.snapshots.isEmpty)
        await model.refresh()
        #expect(model.error == nil && model.snapshots.map(\.id) == [summary.id])
        #expect(model.usedBytes >= summary.byteCount && summary.rowCount == 3 && summary.truncated)
        let previousUsage = model.usedBytes
        #expect(!(await model.updateQuotaBytes(1)))
        #expect(model.error != nil && model.usedBytes == previousUsage && model.snapshots.count == 1)
        #expect(try await store.load(id: summary.id).rows == [[nil], [""], ["NULL"]])
        #expect(await model.updateQuotaBytes(2 * ResultSnapshotsModel.bytesPerMiB))
        let restored = ResultSnapshotsModel(store: ResultSnapshotStore(rootURL: root))
        await restored.refresh()
        #expect(restored.error == nil && restored.quotaBytes == 2 * ResultSnapshotsModel.bytesPerMiB)
        #expect(restored.snapshots.map(\.id) == [summary.id])
    }

    @Test func deletionRequiresAReviewedRequestAndRechecksInvestigationReferences() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResultSnapshotStore(rootURL: root)
        let summary = try await store.save(capture())
        let firstDocument = UUID()
        var references: Set<UUID> = [firstDocument]
        let model = ResultSnapshotsModel(store: store, investigationReferences: { _ in references })
        #expect(model.requestDeletion(summary.id) == nil)
        await model.refresh()
        let request = try #require(model.requestDeletion(summary.id))
        #expect(request.investigationIDs == [firstDocument])
        #expect(try await store.list().count == 1)
        references.insert(UUID())
        #expect(!(await model.deleteConfirmed(request)))
        #expect(model.error?.contains("new investigation references") == true)
        #expect(try await store.list().count == 1)
        let reviewed = try #require(model.requestDeletion(summary.id))
        #expect(await model.deleteConfirmed(reviewed))
        #expect(model.error == nil && model.snapshots.isEmpty && model.usedBytes == 0)
        #expect(try await store.list().isEmpty)
    }

    @Test func quotaInputPreservesTheOneGiBDefaultAndRejectsOverflow() {
        #expect(ResultSnapshotsModel.quotaBytes(fromMiB: "1024") == ResultSnapshotStore.defaultQuotaBytes)
        #expect(ResultSnapshotsModel.quotaBytes(fromMiB: " 2 \n") == 2_097_152)
        for value in ["", "0", "-1", "1.5", "1 GiB", "9223372036854775807"] {
            #expect(ResultSnapshotsModel.quotaBytes(fromMiB: value) == nil)
        }
    }

    @Test func unavailableArtifactsCanBeDeletedWithoutHidingOrRemovingIntactSnapshots() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResultSnapshotStore(rootURL: root)
        let intact = try await store.save(capture())
        let damaged = try await store.save(capture())
        let manifest = root.appendingPathComponent(damaged.id.uuidString.lowercased())
            .appendingPathComponent("manifest.json")
        try Data("{ damaged fixture".utf8).write(to: manifest)
        let model = ResultSnapshotsModel(store: store)
        await model.refresh()
        #expect(model.error == nil && model.snapshots.count == 2)
        #expect(model.snapshots.first { $0.id == intact.id }?.isAvailable == true)
        let unavailable = try #require(model.snapshots.first { $0.id == damaged.id })
        #expect(!unavailable.isAvailable && unavailable.byteCount > 0)
        let request = try #require(model.requestDeletion(damaged.id))
        #expect(await model.deleteConfirmed(request))
        #expect(model.error == nil && model.snapshots.map(\.id) == [intact.id])
        #expect(try await store.load(id: intact.id).rows == [[nil], [""], ["NULL"]])
        #expect(model.usedBytes == intact.byteCount)
    }
}
