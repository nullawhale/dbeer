import Foundation
import Testing
@testable import DBeer

/// Typed state, fixtures and isolated files only; no native windows or desktop input.
struct TableBrowseModelsTests {
    private func predicate(_ name: String = "id", value: String = "") -> CatalogFilterExpression {
        .predicate(.init(column: name, operator: "eq", value: value))
    }

    @Test func sharedSwiftGoRequestFixturesAgree() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("protocol/fixtures/browse-filter-tree-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fixture["capability"] as? String == "browseFilterTreeV1")
        for raw in try #require(fixture["validCatalogRequests"] as? [[String: Any]]) {
            let encoded = try JSONSerialization.data(withJSONObject: raw)
            let request = try JSONDecoder().decode(CatalogRequest.self, from: encoded)
            #expect(try JSONDecoder().decode(CatalogRequest.self, from: JSONEncoder().encode(request)) == request)
        }
        for raw in try #require(fixture["invalidCatalogRequests"] as? [[String: Any]]) {
            let encoded = try JSONSerialization.data(withJSONObject: raw)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(CatalogRequest.self, from: encoded) }
        }
    }

    @Test func expressionBudgetsAndTypedOperandsAreEnforced() throws {
        let maximum = CatalogFilterExpression.group("and", (0..<32).map { predicate("c\($0)") })
        #expect(maximum.isValid && maximum.conditionCount == 32)
        #expect(!CatalogFilterExpression.group("and", (0..<33).map { predicate("c\($0)") }).isValid)
        let depth4 = CatalogFilterExpression.group("and", [.group("or", [.group("and", [predicate()])])])
        #expect(depth4.isValid)
        let depth5 = CatalogFilterExpression.group("and", [depth4])
        #expect(!depth5.isValid)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CatalogFilterExpression.self, from: JSONEncoder().encode(depth5)) }
        #expect(!CatalogFilterExpression.group("or", []).isValid)
        #expect(CatalogFilterExpression.group("or", [predicate()]).flattenedConjunction == nil)
        #expect(CatalogFilterExpression.group("and", [predicate(value: "NULL"), .group("and", [predicate("binary", value: "AP+A")])]).flattenedConjunction?.map(\.value) == ["NULL", "AP+A"])
        #expect(!CatalogFilterExpression.predicate(.init(column: "id", operator: "eq", value: nil)).isValid)
        #expect(!CatalogFilterExpression.predicate(.init(column: "id", operator: "isNull", value: "")).isValid)
        #expect(!TableBrowseConfiguration(sort: [.init(column: "id", direction: "asc"), .init(column: "id", direction: "desc")]).isValid)
    }

    @Test @MainActor func groupedRestoreAndHistoryRetainExpressionButNoDraftOrConnection() throws {
        let profile = UUID()
        let expression = CatalogFilterExpression.group("or", [predicate(value: "9007199254740993"), predicate("note", value: "NULL")])
        let stored = StoredSQLDocument(title: "Orders", text: "Table data", profileID: profile, kind: .table,
            table: .init(reference: .init(schema: "public", name: "orders", kind: "table"), page: 3,
                         filterExpression: expression, sort: [.init(column: "id", direction: "desc")]))
        let restored = SQLDocument(restoring: stored)
        #expect(restored.tableFilterExpression == expression && restored.storedState == stored)
        #expect(restored.runtime == nil && restored.grid == nil && restored.tableNeedsExplicitLoad)
        #expect(restored.tableBrowseDraft == nil && restored.page == 3)
        let location = try #require(TableViewLocation(restored))
        #expect(location.filterExpression == expression && location.filters.isEmpty)
        restored.browseDraftConfiguration = .init(filterExpression: predicate("note", value: "local"))
        #expect(restored.hasPendingBrowseChanges && restored.storedState == stored)
        #expect(SQLDocument(restoring: restored.storedState).tableBrowseDraft == nil)
    }

    @Test func version10MigrationPreservesExactBackupAndConvertsLegacyAND() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/table-browse/migration/\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let filters = [CatalogFilter(column: "note", operator: "eq", value: ""), .init(column: "id", operator: "eq", value: "9007199254740993")]
        let document = StoredSQLDocument(title: "Orders", text: "Table data", profileID: UUID(), kind: .table,
            table: .init(reference: .init(schema: "public", name: "orders", kind: "table"), filters: filters))
        var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SQLWorkspaceSnapshot(documents: [document]))) as? [String: Any])
        raw["version"] = 10
        var documents = try #require(raw["documents"] as? [[String: Any]])
        var table = try #require(documents[0]["table"] as? [String: Any])
        table.removeValue(forKey: "filterExpression")
        table["filters"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(filters))
        documents[0]["table"] = table
        raw["documents"] = documents
        let bytes = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        try bytes.write(to: url)
        let migrated = try await FileSQLDocumentStore(fileURL: url).load()
        #expect(migrated.version == 11 && migrated.documents == [document])
        #expect(try Data(contentsOf: url.appendingPathExtension("v10.backup")) == bytes)
        // New operational expressions must not masquerade as the older format.
        table.removeValue(forKey: "filters")
        table["filterExpression"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(predicate()))
        documents[0]["table"] = table
        raw["documents"] = documents
        let mislabeled = try JSONSerialization.data(withJSONObject: raw)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SQLWorkspaceSnapshot.self, from: mislabeled) }
    }
}
