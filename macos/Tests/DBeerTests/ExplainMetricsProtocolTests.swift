import Foundation
import Testing
@testable import DBeer

struct ExplainMetricsFixture: Decodable {
    var version: Int
    var capability: String
    var results: [ExplainResult]
    struct Invalid: Decodable { var id: String; var result: ExplainResult }
    var invalidResults: [Invalid]
    static func data() throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/explain-metrics-v1/contract.json"))
    }
    static func load() throws -> Self { try JSONDecoder().decode(Self.self, from: data()) }
}
struct ExplainMetricsProtocolTests {
    @Test func sharedVersionedMetricsAndExactCounters() throws {
        let fixture = try ExplainMetricsFixture.load()
        #expect(fixture.version == 1 && fixture.capability == ExplainNodeMetrics.capability)
        for result in fixture.results {
            #expect(result.valid)
            #expect(try JSONDecoder().decode(ExplainResult.self, from: JSONEncoder().encode(result)) == result)
        }
        for invalid in fixture.invalidResults { #expect(!invalid.result.valid, "\(invalid.id)") }
        let node = try #require(fixture.results.first?.nodes.first?.advancedMetrics)
        #expect(node.counters["sharedHitBlocks"]?.value == "0")
        #expect(node.counters["sharedReadBlocks"]?.value == "9007199254740993")
        #expect(node.counters["walBytes"]?.value == "123456789012345678901234567890")
        #expect(node.counters["sharedHitBlocks"]?.basis == "inclusiveTotal")
        #expect(node.exclusiveTime.value == "0.125")
        #expect(node.rowComparison == "comparable")
        let parallel = try #require(fixture.results.last?.nodes.first?.advancedMetrics)
        #expect(parallel.exclusiveTime.value == nil && parallel.exclusiveTime.unavailableReason == "parallel")
        #expect(parallel.jit?.scope == "queryAggregate" && parallel.workers.first?.jit?.scope == "worker")
    }
    @Test func advancedContainersRejectUnknownAndNullFields() throws {
        let object = try #require(JSONSerialization.jsonObject(with: ExplainMetricsFixture.data()) as? [String: Any])
        let invalid = try #require(object["invalidDecodes"] as? [[String: Any]])
        for entry in invalid {
            let raw = try JSONSerialization.data(withJSONObject: #require(entry["result"]))
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ExplainResult.self, from: raw) }
        }
    }
    @Test func unavailableLabelsAndBasesPreserveMeaning() {
        #expect(ExplainMetric(value: "0", unit: "blocks", basis: "inclusiveTotal").label == "0 blocks · inclusive total across loops")
        #expect(ExplainMetric(unit: "ms", basis: "exclusivePerInvocation", unavailableReason: "inclusiveOnly").unavailableLabel.contains("cannot be safely partitioned"))
        #expect(ExplainMetric(unit: "ms", basis: "exclusivePerInvocation", unavailableReason: "parallel").unavailableLabel.contains("overlap"))
        #expect(ExplainMetric(value: "0", unit: "ms", basis: "exclusivePerInvocation").valid)
        #expect(!ExplainMetric(value: "0", unit: "ms", basis: "exclusivePerInvocation", unavailableReason: "notReported").valid)
    }
}
