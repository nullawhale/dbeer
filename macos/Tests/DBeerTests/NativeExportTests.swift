import Foundation
import Testing
@testable import DBeer

struct NativeExportTests {
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/" + name))
    }

    @Test func typedAndLegacySharedExportsRoundTripWithoutDisplayAuthority() throws {
        let legacy = try ResultExport.decodeJSON(fixture("export.json"))
        #expect(legacy.count == 2 && legacy[0].nativeValues == nil)
        let data = try fixture("export-native-v2.json")
        let imported = try ResultExport.decodeJSON(data)
        let set = try #require(imported.first)
        let entries = try #require(set.nativeValues?.first?.first?.entries)
        #expect(entries.count == 2 && entries[0].key == entries[1].key)
        #expect(entries[0].value.value == "9007199254740993")
        #expect(entries[1].value.value == "NULL")
        #expect(set.rows[0][0] == "formatted object")
        #expect(set.nativeValues?[0][1].value == "AP8=")
        let roundTrip = try ResultExport.decodeJSON(ResultExport.json(imported))
        #expect(roundTrip[0].nativeValues == set.nativeValues && roundTrip[0].rows == set.rows)
        let oldSQLite = ExportResultSet(columns: [ResultColumn(index: 0, name: "v", engine: .sqlite)], rows: [["display"]],
            sqliteValues: [[SQLiteValue(type: "integer", value: "1")]])
        #expect(try ResultExport.decodeJSON(ResultExport.json([oldSQLite]))[0].sqliteValues == oldSQLite.sqliteValues)
    }

    @Test func typedImportRejectsMalformedVersionUnicodeAndPairing() throws {
        let source = String(decoding: try fixture("export-native-v2.json"), as: UTF8.self)
        for text in [source.replacingOccurrences(of: "\"version\":2", with: "\"version\":1"),
                     source.replacingOccurrences(of: "\"nativeV1\"", with: "\"other\""),
                     source.replacingOccurrences(of: "\"AP8=\"}]", with: "\"AP8=\"},{\"kind\":\"null\"}]"),
                     source.replacingOccurrences(of: "formatted object", with: "\\ud800"),
                     source.replacingOccurrences(of: "\"version\":2", with: "\"version\":2,\"version\":2")] {
            #expect(throws: ResultExportError.self) { try ResultExport.decodeJSON(Data(text.utf8)) }
        }
        let mismatch = ExportResultSet(columns: [ResultColumn(index: 0, name: "v", engine: .sqlite)], rows: [["1"]],
            sqliteValues: [[SQLiteValue(type: "integer", value: "1")]],
            nativeValues: [[NativeValue(kind: "integer", value: "2", engine: "sqlite", nativeType: "integer")]])
        #expect(throws: ResultExportError.self) { try ResultExport.json([mismatch]) }
    }

    @MainActor @Test func explicitImportCreatesOfflineSnapshotsWithUnknownExecutionContext() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-native-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("import.json")
        try fixture("export-native-v2.json").write(to: file)
        let store = ResultSnapshotStore(rootURL: directory.appendingPathComponent("snapshots"))
        let model = ResultSnapshotsModel(store: store)
        let summaries = await model.importResultJSON(file)
        let summary = try #require(summaries.first)
        #expect(model.error == nil && model.snapshots.count == 1)
        let saved = try await store.load(id: summary.id)
        #expect(saved.manifest.outcome == .unknown && saved.manifest.partial)
        #expect(saved.manifest.profileID == nil && saved.manifest.profileName == nil)
        #expect(saved.nativeValues == (try ResultExport.decodeJSON(fixture("export-native-v2.json")))[0].nativeValues)
    }
    @Test func reviewedPublicationRejectsChangedFilesWithoutOverwritingThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-export-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("result.json")
        try Data("reviewed".utf8).write(to: file)
        let reviewed = try SQLFileBinding.reviewedVersion(at: file)
        try Data("external change".utf8).write(to: file)
        #expect(throws: ResultExportError.self) {
            try ResultExport.write(Data("export".utf8), to: file, expectedVersion: reviewed)
        }
        #expect(try Data(contentsOf: file) == Data("external change".utf8))
    }

    @Test func completeExportBeyondSnapshotBudgetGetsALimitError() throws {
        let cell: [String: Any] = ["kind": "text", "value": String(repeating: "x", count: 1_500_000)]
        let row: [String: Any] = ["values": ["display"], "nativeValues": [cell]]
        let document: [String: Any] = ["version": 2, "nativeValuesFormat": "nativeV1", "resultSets": [
            ["metadata": ["columns": [["index": 0, "name": "value", "engine": "postgresql", "nativeType": "text"]],
                "commandTag": "SELECT", "rowCount": 3, "displayedRowCount": 3, "truncated": false], "rows": [row, row, row]]]]
        let data = try JSONSerialization.data(withJSONObject: document)
        do { _ = try ResultExport.decodeJSON(data); Issue.record("Oversized snapshot evidence was imported") }
        catch ResultExportError.nativeImportLimit {}
        catch { Issue.record("A valid complete export was misclassified as damaged") }
    }

}
