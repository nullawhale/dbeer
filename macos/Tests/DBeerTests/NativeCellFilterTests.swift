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

    @Test func originalScalarKindsAndLargeDecimalsRemainUnchangedInOrderedMappings() throws {
        let source = SavedConnection(name: "Source", settings: .init(host: "example.invalid", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable"))
        let target = SavedConnection(name: "Target", settings: .init(host: "example.invalid", port: 3306, database: "fixture", user: "fixture", password: "", sslMode: "disable", engine: .mysql))
        let sourceEndpoint = LogicalRelationshipEndpoint(profile: source, reference: .init(schema: "public", name: "source", kind: "table"))
        let targetEndpoint = LogicalRelationshipEndpoint(profile: target, reference: .init(schema: "fixture", name: "target", kind: "table"))
        let names = ["n", "b", "empty", "textNull", "unicode"]
        let types = ["numeric(40,18)", "bytea", "text", "text", "text"], oids: [UInt32] = [1700, 17, 25, 25, 25]
        let columns = names.enumerated().map { ResultColumn(index: $0.offset, name: $0.element, typeOid: oids[$0.offset], nativeType: $0.offset == 0 ? "numeric" : types[$0.offset]) }
        let values: [ChangeValue] = [.init(kind: "text", value: "9007199254740993.000000000000000001"),
            .init(kind: "binary", value: "AP8="), .init(kind: "text", value: ""), .init(kind: "text", value: "NULL"), .init(kind: "text", value: "e\u{0301}")]
        let relationship = LogicalRelationship(name: "Exact composite", source: sourceEndpoint, target: targetEndpoint,
            columns: names.indices.map { .init(source: names[$0], target: "to_" + names[$0], sourceType: types[$0], targetType: "text") })
        let filters = try LogicalRelationshipNavigation.filters(relationship, sourceColumns: columns, sourceDeclarations: types, values: values)
        #expect(filters.map(\.column) == names.map { "to_" + $0 })
        #expect(filters.compactMap(\.nativeValue).map(\.cell) == values)
        #expect(filters.allSatisfy { $0.value == nil && $0.sqliteValue == nil })
        var unresolved = columns
        unresolved[0] = .init(index: 0, name: names[0], typeIdentity: "unresolved:source-scalar")
        #expect(throws: LogicalRelationshipError.self) {
            try LogicalRelationshipNavigation.filters(relationship, sourceColumns: unresolved, sourceDeclarations: types, values: values)
        }
        for invalid in [ChangeValue.null, .default] {
            var replaced = values; replaced[2] = invalid
            #expect(throws: (any Error).self) { try LogicalRelationshipNavigation.filters(relationship, sourceColumns: columns, sourceDeclarations: types, values: replaced) }
        }
    }

    @Test func capturedDeclarationsAndPostgresOIDsPreventNumericRelabelling() throws {
        let settings = ConnectionSettings(host: "fixture.invalid", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable")
        let profile = SavedConnection(name: "Fixture", settings: settings)
        let endpoint = LogicalRelationshipEndpoint(profile: profile, reference: .init(schema: "public", name: "source", kind: "table"))
        let link = LogicalRelationship(name: "Revalidated", source: endpoint, target: endpoint,
            columns: [.init(source: "value", target: "value", sourceType: "real", targetType: "real")])
        let values = [ChangeValue(kind: "text", value: "0.1")]
        #expect(throws: LogicalRelationshipError.self) {
            try LogicalRelationshipNavigation.filters(link, sourceColumns: [.init(index: 0, name: "value", typeOid: 1700, nativeType: "numeric")], sourceDeclarations: ["numeric"], values: values)
        }
        #expect(throws: LogicalRelationshipError.self) {
            try LogicalRelationshipNavigation.filters(link, sourceColumns: [.init(index: 0, name: "value", typeOid: 1700, nativeType: "numeric")], sourceDeclarations: ["real"], values: values)
        }
        let filters = try LogicalRelationshipNavigation.filters(link,
            sourceColumns: [.init(index: 0, name: "value", typeOid: 700, nativeType: "float4")], sourceDeclarations: ["real"], values: values)
        #expect(filters.first?.nativeValue?.sourceType == "real" && filters.first?.nativeValue?.cell == values.first)
    }

    @Test func resolvedArrayAndDomainIdentitiesRequireCapturedCatalogOIDBinding() throws {
        let profile = SavedConnection(name: "Fixture", settings: .init(host: "fixture.invalid", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable"))
        let endpoint = LogicalRelationshipEndpoint(profile: profile, reference: .init(schema: "public", name: "source", kind: "table"))
        let identity = "pgtype-v1:" + String(repeating: "a", count: 64)
        for (declaration, wireName, wireOID, declaredOID, baseOID, value) in [
            ("integer[]", "_int4", UInt32(1007), UInt32(1007), UInt32(1007), ChangeValue(kind: "text", value: "{1,2}")),
            ("fixture.binary_key", "bytea", UInt32(17), UInt32(20_001), UInt32(17), ChangeValue(kind: "binary", value: "AP8="))
        ] {
            let link = LogicalRelationship(name: "Resolved capture", source: endpoint, target: endpoint,
                columns: [.init(source: "value", target: "value", sourceType: declaration, targetType: declaration)])
            let column = ResultColumn(index: 0, name: "value", typeOid: wireOID, nativeType: wireName, typeIdentity: identity)
            let filters = try LogicalRelationshipNavigation.filters(link, sourceColumns: [column], sourceDeclarations: [declaration],
                sourceTypeOIDs: [declaredOID], sourceBaseTypeOIDs: [baseOID], values: [value])
            #expect(filters.first?.nativeValue?.cell == value)
            #expect(throws: LogicalRelationshipError.self) {
                try LogicalRelationshipNavigation.filters(link, sourceColumns: [column], sourceDeclarations: [declaration],
                    sourceTypeOIDs: [20_002], sourceBaseTypeOIDs: [25], values: [value])
            }
            #expect(throws: LogicalRelationshipError.self) {
                try LogicalRelationshipNavigation.filters(link, sourceColumns: [column], sourceDeclarations: [declaration], values: [value])
            }
        }
    }

    @Test func sqliteStorageAndNumericPolicyAreExplicitAndNotDeclaredForeignKeys() throws {
        let first = SavedConnection(name: "SQLite", settings: .init(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite, sqlite: .init(path: "/synthetic/source.sqlite")))
        let second = SavedConnection(name: "Server", settings: .init(host: "example.invalid", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable"))
        let a = LogicalRelationshipEndpoint(profile: first, reference: .init(schema: "main", name: "source", kind: "table"))
        let b = LogicalRelationshipEndpoint(profile: second, reference: .init(schema: "public", name: "target", kind: "table"))
        var relationship = LogicalRelationship(name: "Cross engine", source: a, target: b,
            columns: [.init(source: "v", target: "v", sourceType: "ANY", targetType: "numeric")])
        #expect(!relationship.isValid)
        relationship.columns[0].sqliteStorage = "text"
        #expect(relationship.isValid && relationship.reversed.isValid && relationship.reversed.columns[0].sqliteStorage == "text")
        let values = [ChangeValue(kind: "sqliteInteger", value: "9223372036854775807")]
        let filters = try LogicalRelationshipNavigation.filters(relationship,
            sourceColumns: [.init(index: 0, name: "v", engine: .sqlite, nativeType: "ANY")], sourceDeclarations: ["ANY"], values: values)
        #expect(filters.first?.nativeValue?.cell == values.first)
        #expect(filters.first?.nativeValue?.sqliteStorage == "preserve")
        #expect(TableBrowseConfiguration(filterExpression: .conjunction(filters)).relationshipScope == nil)
        let nativeReal = operand("3fb999999999999a", kind: "sqliteReal", source: .sqlite, type: "ANY", storage: "preserve")
        #expect(nativeReal.isValid && nativeReal.cell.value == "3fb999999999999a")
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
