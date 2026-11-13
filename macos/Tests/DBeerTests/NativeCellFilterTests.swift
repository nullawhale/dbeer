import Foundation
import Testing
@testable import DBeer

@MainActor
struct NativeCellFilterTests {
    private func operand(_ text: String, kind: String = "text", source: DatabaseEngine = .postgresql, type: String = "text", storage: String = "text") -> NativeCellFilterValue {
        .init(cell: .init(kind: kind, value: text), sourceEngine: source, sourceType: type, sqliteStorage: storage)
    }
    @Test func sharedNativeConditionsAgreeWithGoWithoutNormalizingInput() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/native-cell-filter-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fixture["capability"] as? String == NativeCellFilterValue.capability)
        for raw in try #require(fixture["valid"] as? [[String: Any]]) {
            let encoded = try JSONSerialization.data(withJSONObject: raw)
            try ExactJSONKeys.validate(encoded, maximumBytes: 2 * 1_024 * 1_024)
            let filter = try JSONDecoder().decode(CatalogFilter.self, from: encoded)
            let roundTrip = try JSONDecoder().decode(CatalogFilter.self, from: JSONEncoder().encode(filter))
            #expect(filter.isValid && roundTrip == filter)
        }
        for raw in try #require(fixture["invalid"] as? [[String: Any]]) {
            let encoded = try JSONSerialization.data(withJSONObject: raw)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(CatalogFilter.self, from: encoded) }
        }
        for raw in try #require(fixture["invalidJSON"] as? [String]) {
            #expect(throws: (any Error).self) {
                let encoded = Data(raw.utf8)
                try ExactJSONKeys.validate(encoded, maximumBytes: 2 * 1_024 * 1_024)
                _ = try JSONDecoder().decode(CatalogFilter.self, from: encoded)
            }
        }
    }





    @Test func encodedBudgetUsesGoEscapingAndRejectsWholeOversizedTrees() throws {
        let special = operand("<>&\u{2028}\u{2029}\"\\\n\0é")
        // Go JSON escapes HTML/control/line separators and retains UTF-8 é.
        let canonical = "{\"cell\":{\"kind\":\"text\",\"value\":\"\\u003c\\u003e\\u0026\\u2028\\u2029\\\"\\\\\\n\\u0000é\"},\"sourceEngine\":\"postgresql\",\"sourceType\":\"text\",\"sqliteStorage\":\"text\"}"
        #expect(special.encodedByteCount == canonical.utf8.count)
        let large = CatalogFilter(column: "v", operator: "eq", nativeValue: operand(String(repeating: "x", count: 1_024 * 1_024)))
        #expect(CatalogFilterExpression.group("and", Array(repeating: .predicate(large), count: 3)).isValid)
        #expect(!CatalogFilterExpression.group("and", Array(repeating: .predicate(large), count: 4)).isValid)
        let escaped = CatalogFilter(column: "v", operator: "eq", nativeValue: operand(String(repeating: "\0", count: 1_024 * 1_024)))
        #expect(escaped.isValid && !CatalogFilterExpression.predicate(escaped).isValid)
    }

    @Test func versionedRestorationRetainsTypedIntentAndUnloadedRemovalNeverReads() async throws {
        let filter = CatalogFilter(column: "key", operator: "eq", nativeValue: operand("NULL"))
        let legacy = CatalogFilter(column: "other", operator: "eq", value: "keep")
        let stored = StoredSQLDocument(title: "Target", text: "Table data", profileID: UUID(), kind: .table,
            table: .init(reference: .init(schema: "public", name: "target", kind: "table"), filterExpression: .conjunction([filter, legacy])))
        let bytes = try JSONEncoder().encode(SQLWorkspaceSnapshot(documents: [stored]))
        let restored = try JSONDecoder().decode(SQLWorkspaceSnapshot.self, from: bytes)
        let document = SQLDocument(restoring: try #require(restored.documents.first))
        #expect(restored.version == SQLWorkspaceSnapshot.currentVersion && document.runtime == nil && document.grid == nil && document.tableFilters == [filter, legacy])
        var legacy14 = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any]); legacy14["version"] = 14
        let legacy14Bytes = try JSONSerialization.data(withJSONObject: legacy14)
        let legacy14Read = try JSONDecoder().decode(SQLWorkspaceSnapshot.self, from: legacy14Bytes)
        let legacyDocument = SQLDocument(restoring: try #require(legacy14Read.documents.first))
        #expect(legacy14Read.version == 14 && legacyDocument.runtime == nil && legacyDocument.grid == nil && legacyDocument.tableFilters == [filter, legacy])
        var old = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any]); old["version"] = 13
        let oldBytes = try JSONSerialization.data(withJSONObject: old)
        #expect(throws: SQLDocumentStoreError.self) { try JSONDecoder().decode(SQLWorkspaceSnapshot.self, from: oldBytes) }
        #expect(document.removeUnloadedNativeKeyConditions())
        #expect(document.tableFilters == [legacy] && document.runtime == nil && document.grid == nil && document.tableNeedsExplicitLoad)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-key-presets-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.json")
        let presets = TableBrowsePresetStore(fileURL: file); await presets.load()
        _ = try await presets.saveNew(name: "Typed", profileID: UUID(), table: .init(schema: "public", name: "target", kind: "table"),
            configuration: .init(filterExpression: .conjunction([filter])))
        var contents = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(contents["version"] as? Int == 3)
        contents["version"] = 2
        try JSONSerialization.data(withJSONObject: contents).write(to: file)
        let oldPresets = TableBrowsePresetStore(fileURL: file); await oldPresets.load()
        #expect(!oldPresets.isLoaded && oldPresets.error != nil)
    }
}
