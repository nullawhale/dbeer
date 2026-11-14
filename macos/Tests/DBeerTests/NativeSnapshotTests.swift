import Foundation
import Testing
@testable import DBeer

@Suite(.serialized)
struct NativeSnapshotTests {
    @Test func typedSnapshotRetainsOrderKindsAndDisconnectedProjection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResultSnapshotStore(rootURL: root)
        let native = NativeValue(kind: "object", entries: [
            .init(key: .init(kind: "text", value: "e\u{301}"), value: .init(kind: "integer", value: "9007199254740993")),
            .init(key: .init(kind: "text", value: "e\u{301}"), value: .init(kind: "binary", value: "AP8="))
        ])
        let columns = [ResultColumn(index: 0, name: "document", engine: .mongodb, nativeType: "bson", typeIdentity: "bson-v1")]
        let capture = ResultSnapshotCapture(title: "Native evidence", sql: "", engine: .mongodb,
            columns: columns, rows: [["presentation only"]], nativeValues: [[native]])
        let saved = try await store.save(capture)
        let artifact = try await store.load(id: saved.id)
        #expect(artifact.manifest.version == 3)
        #expect(artifact.manifest.nativeValuesFormat == NativeValue.format)
        #expect(artifact.rows == [["presentation only"]])
        #expect(artifact.nativeValues == [[native]])
        let result = await MainActor.run { ResultSnapshotDocumentModel(id: saved.id, store: store) }
        await result.load()
        let loaded = await result.result
        #expect(loaded?.nativeValues == [[native]])
        #expect(loaded?.rows == [["presentation only"]])
    }

    @Test func nativeSnapshotRejectsWrongShapeBeforePublishingAndRetainsLegacyRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResultSnapshotStore(rootURL: root)
        let columns = [ResultColumn(index: 0, name: "value", nativeType: "text")]
        var capture = ResultSnapshotCapture(title: "Legacy evidence", sql: "", engine: .postgresql, columns: columns, rows: [["NULL"], [nil]])
        capture.nativeValues = [[.init(kind: "text", value: "NULL")]]
        do { _ = try await store.save(capture); Issue.record("wrong native matrix was persisted") }
        catch { #expect(error as? ResultSnapshotError == .invalid) }
        let inventory = try await store.list()
        #expect(inventory.isEmpty)
        capture.nativeValues = nil
        let saved = try await store.save(capture)
        let loaded = try await store.load(id: saved.id)
        #expect(loaded.rows == capture.rows && loaded.nativeValues == nil)
        #expect(loaded.manifest.version == ResultSnapshotManifest.currentVersion)
    }
    @Test func sqliteNativeSnapshotsRequireTheSameStorageClass() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResultSnapshotStore(rootURL: root)
        let columns = [ResultColumn(index: 0, name: "value", engine: .sqlite, nativeType: "dynamic")]
        var capture = ResultSnapshotCapture(title: "SQLite evidence", sql: "", engine: .sqlite, columns: columns,
            rows: [["42"]], sqliteValues: [[.init(type: "text", value: "NDI=")]],
            nativeValues: [[.init(kind: "integer", value: "42", engine: "sqlite", nativeType: "integer")]])
        do { _ = try await store.save(capture); Issue.record("contradictory storage classes were persisted") }
        catch { #expect(error as? ResultSnapshotError == .invalid) }
        capture.nativeValues = [[.init(kind: "text", value: "42", engine: "sqlite", nativeType: "text")]]
        let saved = try await store.save(capture)
        let loaded = try await store.load(id: saved.id)
        #expect(loaded.nativeValues == capture.nativeValues && loaded.sqliteValues == capture.sqliteValues)
    }

}
