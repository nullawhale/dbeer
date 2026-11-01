import Foundation
import Testing
@testable import DBeer

struct ExplainFixture: Decodable {
    var version: Int
    var commands: [BackendCommand]
    var results: [ExplainResult]
    struct Invalid: Decodable { var id: String; var result: ExplainResult }
    var invalidResults: [Invalid]
    static func load() throws -> Self {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/explain-v1/contract.json")))
    }
}
struct ExplainProtocolTests {
    @Test func sharedContractAndValidation() throws {
        let fixtures = try ExplainFixture.load()
        #expect(fixtures.version == 1)
        for result in fixtures.results { #expect(result.valid) }
        for invalid in fixtures.invalidResults { #expect(!invalid.result.valid, "\(invalid.id)") }
        for command in fixtures.commands where command.type == "explain.run" {
            #expect(command.explain?.valid == true)
            #expect(command.terminalType == "explain.result")
            let data = try JSONEncoder().encode(command)
            #expect(try JSONDecoder().decode(BackendCommand.self, from: data) == command)
        }
        let result = fixtures.results[0]
        let message = BackendMessage(type: "explain.result", requestId: "r", sessionId: "s", queryId: "q",
            transactionStatus: .idle, durationMs: 1, sqlCompleted: true, explain: result)
        try message.validate()
        var invalid = message
        invalid.columns = []
        #expect(throws: BackendTransportError.self) { try invalid.validate() }
        invalid = message
        invalid.sqlCompleted = false
        #expect(throws: BackendTransportError.self) { try invalid.validate() }
    }
}
struct ExplainPlanModelTests {
    @Test func rankingUsesComparableInclusiveWorkAndPreservesPrecision() throws {
        var result = try ExplainFixture.load().results[1]
        var child = result.nodes[1]
        child.execution = "executed"
        child.metrics["totalTime"] = ExplainMetric(value: "0.5", unit: "ms", basis: "perInvocation")
        child.metrics["loops"] = ExplainMetric(value: "100", unit: "count", basis: "total")
        result.nodes[1] = child
        let ranking = ExplainRanking(result)
        #expect(ranking.entries.map(\.id) == ["1"])
        #expect(ranking.entries.first?.score == Decimal(50))
        #expect(ranking.basis.contains("not wall time"))
        result.nodes[1].metrics["totalTime"] = nil
        #expect(ExplainRanking(result).basis.contains("estimated cost"))
        #expect(ExplainMetric.validDecimal("9007199254740993.125"))
        #expect(!ExplainMetric.validDecimal("1\n"))
        #expect(!ExplainMetric.validDecimal("NaN"))
        #expect(ExplainMetric(value: String(repeating: "9", count: 60), unit: "cost", basis: "inclusive").decimal == nil)
    }
    @Test func sourceBindingAndOneStatementRequirement() throws {
        let source = "SELECT '🍺'; SELECT 2;"
        let selection = NSRange(location: 0, length: source.utf16.count)
        let multiple = try #require(SQLExecutionFragment.resolve(text: source, selection: selection, engine: .postgresql))
        #expect(throws: ExecutionPolicyError.self) { try ExplainPlanModel.request(fragment: multiple, mode: .plan) }
        let one = try #require(SQLExecutionFragment.resolve(text: source, selection: NSRange(location: 0, length: 0), engine: .postgresql))
        let request = try ExplainPlanModel.request(fragment: one, mode: .analyze)
        #expect(request.sql == "SELECT '🍺'")
        for sql in ["DELETE FROM sample", "EXPLAIN SELECT 1", "(SELECT 1)"] {
            let fragment = try #require(SQLExecutionFragment.resolve(text: sql, selection: NSRange(location: 0, length: 0), engine: .postgresql))
            #expect(throws: ExecutionPolicyError.self) { try ExplainPlanModel.request(fragment: fragment, mode: .plan) }
        }
        let profile = UUID()
        let plan = ExplainPlanModel(request: request, sourceText: source, sourceRange: one.range, profileID: profile)
        #expect(!plan.isStale(text: source, profileID: profile))
        #expect(plan.isStale(text: source + " ", profileID: profile))
        #expect(plan.isStale(text: source, profileID: UUID()))
    }
}
