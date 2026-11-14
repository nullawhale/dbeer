import Foundation
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct LogicalRelationshipJOINTests {
    private func profile(_ engine: DatabaseEngine = .postgresql) -> SavedConnection {
        SavedConnection(name: "Fixture", settings: .init(host: "fixture.invalid", port: engine.defaultPort, database: "fixture", user: "fixture", password: "", sslMode: "disable", engine: engine))
    }
    private func fixture(_ engine: DatabaseEngine = .postgresql, sourceName: String = "customer_id", targetName: String = "id", type: String = "bigint", comparison: CatalogColumnComparison? = .init(kind: "native", baseType: "pg_catalog.int8")) -> (SavedConnection, LogicalRelationship, SQLCompletionContext) {
        let profile = profile(engine), schema = engine == .sqlite ? "main" : "public"
        let source = LogicalRelationshipEndpoint(profile: profile, reference: .init(schema: schema, name: "orders", kind: "table"))
        let target = LogicalRelationshipEndpoint(profile: profile, reference: .init(schema: schema, name: "customers", kind: "table"))
        let link = LogicalRelationship(name: "A confirmed local mapping", source: source, target: target,
            columns: [.init(source: sourceName, target: targetName, sourceType: type, targetType: type)])
        let context = SQLCompletionContext(profileID: profile.id, catalog: [
            .init(schema: schema, name: "orders", kind: "table", columns: [sourceName], columnTypeEntries: [.init(name: sourceName, nativeType: type, comparison: comparison)]),
            .init(schema: schema, name: "customers", kind: "table", columns: [targetName], columnTypeEntries: [.init(name: targetName, nativeType: type, comparison: comparison)])
        ])
        return (profile, link, context)
    }
    @Test func confirmedCompositeMappingsMergeWithoutBecomingServerConstraints() throws {
        var (profile, link, context) = fixture()
        link.columns.append(.init(source: "tenant", target: "tenant_id", sourceType: "bigint", targetType: "bigint"))
        context.catalog[0].columns.append("tenant"); context.catalog[1].columns.append("tenant_id")
        context.catalog[0].columnTypeEntries.append(.init(name: "tenant", nativeType: "bigint", comparison: .init(kind: "native", baseType: "pg_catalog.int8")))
        context.catalog[1].columnTypeEntries.append(.init(name: "tenant_id", nativeType: "bigint", comparison: .init(kind: "native", baseType: "pg_catalog.int8")))
        let merged = LogicalRelationshipJOIN.merge(context, relationships: [link], profile: profile, enabled: true)
        let key = try #require(merged.catalog[0].foreignKeys.first)
        #expect(key.origin == "logical" && key.columns.map(\.source) == ["customer_id", "tenant"])
        #expect(key.columns.map(\.target) == ["id", "tenant_id"])
        #expect(context.catalog[0].foreignKeys.isEmpty)
        #expect(LogicalRelationshipJOIN.merge(context, relationships: [link], profile: profile, enabled: false) == context)
        profile.host = "changed.invalid"
        #expect(LogicalRelationshipJOIN.merge(context, relationships: [link], profile: profile, enabled: true) == context)
    }
    @Test func crossProfileMissingStaleAndUnknownMetadataNeverGenerateJoins() {
        let (profile, link, context) = fixture()
        var cross = link
        cross.target = .init(profile: self.profile(), reference: link.target.reference)
        #expect(LogicalRelationshipJOIN.merge(context, relationships: [cross], profile: profile, enabled: true) == context)
        var stale = context; stale.catalog[0].columnTypeEntries = [.init(name: "customer_id", nativeType: "numeric", comparison: .init(kind: "native", baseType: "pg_catalog.numeric"))]
        #expect(LogicalRelationshipJOIN.merge(stale, relationships: [link], profile: profile, enabled: true) == stale)
        var legacy = context; legacy.catalog[0].columnTypeEntries = []; legacy.catalog[0].columnTypes = ["customer_id": "bigint"]
        #expect(LogicalRelationshipJOIN.merge(legacy, relationships: [link], profile: profile, enabled: true) == legacy)
        var unknown = context; unknown.catalog[0].columnTypeEntries[0] = .init(name: "customer_id", nativeType: "bigint", comparison: .init(kind: "unknown", baseType: "pg_catalog.int8"))
        #expect(LogicalRelationshipJOIN.unavailableReason(link, context: unknown, profile: profile)?.contains("unproven") == true)
    }
    @Test func textJoinsRequireActualCompatibleCollationAndCharsetFacts() {
        for engine in [DatabaseEngine.postgresql, .mysql] {
            let fact = engine == .postgresql
                ? CatalogColumnComparison(kind: "text", baseType: "pg_catalog.text", charset: "UTF8", collationSchema: "pg_catalog", collationName: "C", collationIdentity: "950")
                : CatalogColumnComparison(kind: "text", baseType: "varchar", charset: "utf8mb4", collationName: "utf8mb4_bin", collationIdentity: "46")
            let (profile, link, context) = fixture(engine, type: engine == .postgresql ? "text" : "varchar(20)", comparison: fact)
            #expect(LogicalRelationshipJOIN.unavailableReason(link, context: context, profile: profile) == nil)
            var changed = context; var other = fact; other.collationIdentity = "another"
            changed.catalog[1].columnTypeEntries[0].comparison = other
            #expect(LogicalRelationshipJOIN.unavailableReason(link, context: changed, profile: profile)?.contains("collation") == true)
            other = fact; other.charset = "latin1"; changed.catalog[1].columnTypeEntries[0].comparison = other
            #expect(LogicalRelationshipJOIN.unavailableReason(link, context: changed, profile: profile)?.contains("character set") == true)
        }
    }
    @Test func canonicallyEquivalentNamesStayDistinctThroughCatalogFrameAndLanguagePayload() throws {
        let (profile, link, context) = fixture(sourceName: "é", targetName: "e\u{0301}")
        #expect(LogicalRelationshipJOIN.unavailableReason(link, context: context, profile: profile) == nil)
        var wrong = context; wrong.catalog[0].columnTypeEntries[0] = .init(name: "e\u{0301}", nativeType: "bigint", comparison: .init(kind: "native", baseType: "pg_catalog.int8"))
        #expect(LogicalRelationshipJOIN.unavailableReason(link, context: wrong, profile: profile) != nil)
        let raw = Data("{\"type\":\"query.result\",\"catalog\":{\"é\":1,\"e\\u0301\":2}}".utf8)
        #expect(try GPUIProductBuildIdentity.optionalFromFrame(raw, maximumFrameBytes: 4_096) == nil)
        let duplicate = Data("{\"type\":\"query.result\",\"catalog\":{\"é\":1,\"\\u00e9\":2}}".utf8)
        #expect(throws: (any Error).self) { _ = try GPUIProductBuildIdentity.optionalFromFrame(duplicate, maximumFrameBytes: 4_096) }
        var relation = context.catalog[0]
        relation.columns = ["é", "e\u{0301}"]
        relation.columnTypeEntries = [.init(name: "é", nativeType: "text"), .init(name: "e\u{0301}", nativeType: "bigint")]
        let payload = try #require(SQLLanguageService.boundedCatalog([relation]).first)
        let values = try #require(payload["columnTypeEntries"]?.array)
        #expect(values.count == 2 && values[0]["name"]?.string.map { Data($0.utf8) } == Data("é".utf8))
        #expect(values[1]["name"]?.string.map { Data($0.utf8) } == Data("e\u{0301}".utf8))
        #expect(payload["columnTypes"] == .object([:]))
    }
    @Test func sharedExactColumnTypeFixturesAndMalformedSurrogatesAgreeWithGo() throws {
        struct Fixture: Decodable { let capability: String; let valid: [[CatalogColumnTypeEntry]]; let invalidJSON: [String] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/catalog-column-types-v1.json")))
        #expect(fixture.capability == CatalogColumnTypeEntry.capability)
        for entries in fixture.valid {
            let raw = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
            #expect(CatalogColumnTypeEntry.parse(raw, columns: entries.map(\.name)) == entries)
        }
        for raw in fixture.invalidJSON {
            #expect(CatalogColumnTypeEntry.parse(raw, columns: ["x", "y", "é", "e\u{0301}"]).isEmpty)
        }
        for raw in [#"{"field":"\ud800"}"#, #"{"field":"\udfff"}"#, #"{"field":"\ud800\u0041"}"#] {
            #expect(throws: (any Error).self) { try ExactJSONKeys.validate(Data(raw.utf8), maximumBytes: 1_024) }
        }
        try ExactJSONKeys.validate(Data(#"{"field":"\ud83d\ude00","é":1,"e\u0301":2}"#.utf8), maximumBytes: 1_024)
    }
    @Test func confirmedSQLiteJoinCompletesThroughRealBundledLanguageHelper() async throws {
        let (profile, link, context) = fixture(.sqlite, type: "ANY", comparison: .init(kind: "unknown", baseType: "any"))
        let merged = LogicalRelationshipJOIN.merge(context, relationships: [link], profile: profile, enabled: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = ProcessInfo.processInfo.environment["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let language = SQLLanguageService(helperURL: executable)
        let id = UUID(), text = "SELECT * FROM main.orders o JOIN main.customers c ON "
        language.update(documentID: id, text: text, engine: .sqlite, context: merged)
        let completions = await language.completion(documentID: id, offset: text.utf16.count)
        #expect(completions.contains { $0.kind == 15 && $0.replacement == #""c"."id" = +"o"."customer_id""# && $0.detail?.contains("Local confirmed relationship") == true })
        await language.shutdown()
    }
}
