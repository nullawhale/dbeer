import Foundation
import Testing
@testable import DBeer

/// Foundation fixture models only, with no runtime or UI construction.
struct TuningBaselineTests {
    private func measured() throws -> PlanArtifact {
        let data = try Data(contentsOf: TuningNativeFixture.root.appendingPathComponent("protocol/fixtures/explain-metrics-v1/contract.json"))
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let results = try #require(fields["results"] as? [[String: Any]])
        let result = try JSONDecoder().decode(ExplainResult.self, from: JSONSerialization.data(withJSONObject: results[0]))
        var plan = ExplainPlanModel(request: .init(sql: "SELECT id FROM public.items", mode: .analyze),
            sourceText: "SELECT id FROM public.items", sourceRange: NSRange(location: 0, length: 27), profileID: UUID())
        plan.result = result
        plan.sourceEvidence = .init(rangeLocation: 0, rangeLength: plan.request.sql.utf16.count, transactionStatus: "idle")
        return try PlanArtifact.capture(plan, title: "Measured fixture")
    }
    @Test func exactScopeAndDefinitionAreRequiredBeforeMetricComparison() throws {
        let before = try measured()
        var after = before; after.id = UUID()
        var comparison = PlanComparison(before: before, after: after)
        #expect(comparison.metricsComparable)
        let originalMatch = try #require(comparison.matches.first)
        #expect(comparison.metricComparisonReason(originalMatch) == nil)
        after.request.sql += " "
        #expect(!PlanComparison(before: before, after: after).metricsComparable)
        after = before; after.request.parameters = [.init(name: "exact", type: .decimal, value: "9007199254740993.125")]
        #expect(!PlanComparison(before: before, after: after).metricsComparable)
        after = before; after.result.support.serverVersion += ".different"
        #expect(!PlanComparison(before: before, after: after).metricsComparable)
        after = before; after.result.complete = false
        #expect(!PlanComparison(before: before, after: after).metricsComparable)
        after = before; after.result.nodes[0].metrics["loops"]?.value = "2"
        comparison = PlanComparison(before: before, after: after)
        let loopMatch = try #require(comparison.matches.first)
        #expect(comparison.metricComparisonReason(loopMatch)?.contains("loop counts") == true)
        after = before; after.result.nodes[0].advancedMetrics?.executionScope = "parallel"
        comparison = PlanComparison(before: before, after: after)
        let parallelMatch = try #require(comparison.matches.first)
        #expect(comparison.metricComparisonReason(parallelMatch)?.contains("parallel") == true)
        after = before; after.result.nodes[0].advancedMetrics?.rowComparison = "partialInput"
        comparison = PlanComparison(before: before, after: after)
        let partialMatch = try #require(comparison.matches.first)
        #expect(comparison.metricComparisonReason(partialMatch)?.contains("partial input") == true)
        let pair = PlanComparison.metricPairs(before: ["time": .init(value: "0", unit: "ms", basis: "perInvocation")], after: ["time": .init(value: "0", unit: "ms", basis: "inclusiveTotal")])
        #expect(pair.first?.sameDefinition == false)
    }
    @Test func absentOrUnknownTransactionScopeNeverMakesMetricsComparable() throws {
        let before = try measured()
        for scope in [nil, "unknown", ""] as [String?] {
            var after = before; after.source?.transactionStatus = scope
            #expect(!PlanComparison(before: before, after: after).metricsComparable)
            #expect(!PlanComparison(before: after, after: after).metricsComparable)
        }
        var absent = before; absent.source = nil
        #expect(!PlanComparison(before: absent, after: absent).metricsComparable)
        #expect(!PlanComparison(before: before, after: absent).metricsComparable)
        #expect(PlanComparison(before: before, after: before).metricsComparable)
    }

    @Test func structuralAncestrySeparatesDifferentParentsAndDuplicatePathsStayAmbiguous() throws {
        var before = try TuningNativeFixture.artifact()
        let leaf = before.result.nodes[0]
        var second = leaf; second.id = "other-leaf"
        let a = ExplainNode(id: "a", children: [leaf.id], operation: "Parent A", details: [:], execution: "estimated", metrics: [:])
        let b = ExplainNode(id: "b", children: [second.id], operation: "Parent B", details: [:], execution: "estimated", metrics: [:])
        before.result.roots = ["a", "b"]; before.result.nodes = [a, leaf, b, second]
        #expect(before.valid)
        var comparison = PlanComparison(before: before, after: before)
        #expect(comparison.matches.count == 4 && comparison.matches.allSatisfy { !$0.isAmbiguous })
        var duplicate = leaf; duplicate.id = "duplicate"
        before.result.nodes[0].children.append(duplicate.id); before.result.nodes.append(duplicate)
        comparison = PlanComparison(before: before, after: before)
        let containsAmbiguousPath = comparison.matches.contains(where: \.isAmbiguous)
        #expect(containsAmbiguousPath)
        #expect(comparison.matches.filter(\.isAmbiguous).allSatisfy { comparison.metricComparisonReason($0) != nil })
    }
}
