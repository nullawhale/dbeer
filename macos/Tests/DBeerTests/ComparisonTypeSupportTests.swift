import Foundation
import Testing
@testable import DBeer

struct ComparisonTypeSupportTests {
    struct Fixture: Decodable {
        var formatVersion: Int
        var commands: [BackendCommand]
        var responses: [BackendMessage]
        var columns: [ResultColumn]
    }
    static func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/comparison-type-support-v1.json")))
    }

    @Test func allEngineCommandsAndContextsUseTheSharedWireFormat() throws {
        let fixture = try Self.fixture()
        #expect(fixture.formatVersion == 1)
        for command in fixture.commands {
            #expect((command.schemaComparison?.valid(for: command.type) ?? command.dataComparison?.valid(for: command.type)) == true)
            #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command)) == command)
        }
        for response in fixture.responses { try response.validate() }
        #expect(try JSONDecoder().decode([ResultColumn].self, from: JSONEncoder().encode(fixture.columns)) == fixture.columns)
        #expect(fixture.columns[0].typeIdentity?.hasPrefix("pgtype-v1:") == true)
    }

    @Test func cassandraCannotClaimASnapshotOrCompleteDataEquality() throws {
        let fixture = try Self.fixture()
        var summary = try #require(fixture.responses.last?.dataComparison?.summary)
        #expect(summary.valid && !summary.comparison.complete && !summary.comparison.fullEquality)
        summary.source.partialReasons.removeAll { $0 == "nonSnapshot" }
        #expect(!summary.valid)
        summary = try #require(fixture.responses.last?.dataComparison?.summary)
        summary.source.consistency = "repeatableRead"
        #expect(!summary.valid)
        summary = try #require(fixture.responses.last?.dataComparison?.summary)
        summary.comparison.complete = true
        #expect(!summary.valid)
        summary = try #require(fixture.responses.last?.dataComparison?.summary)
        summary.source.engine = .postgresql
        #expect(!summary.valid)
    }

    @Test func mysqlExactFloatRenderingKeepsItsEngineAndConsistencyBoundary() throws {
        var context = try #require(Self.fixture().responses.last?.dataComparison?.summary?.source)
        context.engine = .mysql
        context.consistency = "repeatableReadBestEffortMetadata"
        context.rendering = "mysqlTextUTCUTF8v3"
        context.partialReasons.removeAll { $0 == "nonSnapshot" }
        #expect(context.valid)
        context.engine = .postgresql
        #expect(!context.valid)
        context.engine = .mysql
        context.consistency = "bestEffort"
        #expect(!context.valid)
    }

    @Test @MainActor func comparisonsKeepAllEngineProfilesAndRequireMatchingEngines() throws {
        var profiles = SchemaComparisonTestFixtures.profiles()
        var cassandra = profiles[0]
        cassandra.id = UUID(); cassandra.engine = .cassandra; cassandra.port = 9042
        profiles.append(cassandra)
        let schema = SchemaComparisonModel(profiles: profiles, resolve: { $0.settings(password: "") })
        let data = DataComparisonModel(profiles: profiles, resolve: { profile, _ in profile.settings(password: "") })
        schema.sourceID = cassandra.id; schema.targetID = cassandra.id
        data.sourceID = cassandra.id; data.targetID = cassandra.id
        data.sourceTable = .init(schema: "fixture", name: "items"); data.targetTable = data.sourceTable
        #expect(schema.profiles.count == profiles.count && data.profiles.count == profiles.count)
        #expect(schema.canStart && data.canDescribe)
        schema.targetID = profiles[1].id; data.targetID = profiles[1].id
        #expect(!schema.canStart && !data.canDescribe)
    }
}
