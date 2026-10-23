import Foundation
import Testing
@testable import DBeer

/// Shared adapter output and helper diff ranges, without creating native views.
enum SchemaSQLDiffTestFixtures {
    struct Fixture: Decodable {
        struct Case: Decodable {
            var name: String
            var engine: DatabaseEngine
            var sourceSQL: String
            var targetSQL: String
            var expected: ComparisonTextDiff
        }
        var formatVersion: Int
        var cases: [Case]
    }
    static func wire() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/schema-sql-diff-v1.json")))
    }
    static func diff() throws -> ComparisonTextDiff { try wire().cases[0].expected }
}

struct SchemaSQLDiffTests {
    @Test func adapterSQLAndHighlightRangesSurviveTheSharedWireFormat() throws {
        let fixture = try SchemaSQLDiffTestFixtures.wire()
        #expect(fixture.formatVersion == 1)
        #expect(Set(fixture.cases.map(\.engine)) == [.postgresql, .mysql])
        for item in fixture.cases {
            #expect(item.expected.valid)
            let source = item.expected.lines.compactMap(\.source).map(\.text).joined(separator: "\n")
            let target = item.expected.lines.compactMap(\.target).map(\.text).joined(separator: "\n")
            #expect(source == item.sourceSQL)
            #expect(target == item.targetSQL)
            #expect(source.contains("CREATE TABLE") && target.contains("CREATE TABLE"))
            #expect(!source.contains("\"state\":") && !target.contains("\"state\":"))
            #expect(item.expected.lines.contains { $0.kind != .equal })
            for line in item.expected.lines {
                for value in [line.source, line.target].compactMap({ $0 }) {
                    for highlight in value.highlights {
                        #expect(highlight.cocoaRange(in: value.text) != nil)
                    }
                }
            }
            let message = BackendMessage(type: "schema.diff.result", requestId: "sql-diff",
                schemaComparison: .init(jobId: "schema-job", state: .completed, diff: item.expected, offset: 0))
            try message.validate()
            #expect(try JSONDecoder().decode(BackendMessage.self, from: JSONEncoder().encode(message)) == message)
        }
    }
}
