import Foundation
import Testing
@testable import DBeer

/// Only value types, protocol decoding and in-memory artifact serialization.
/// No workspace, defaults, credentials, application, view or presenter.
struct ExplainMetricsTests {
    private func contract() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/explain-metrics-v1/contract.json"))) as? [String: Any])
    }
    private func serial() throws -> ExplainResult {
        let results = try #require(contract()["results"] as? [[String: Any]])
        return try JSONDecoder().decode(ExplainResult.self, from: JSONSerialization.data(withJSONObject: #require(results.first)))
    }
    private func makeArtifact(_ result: ExplainResult) throws -> PlanArtifact {
        let sql = "SELECT 1"
        let request = ExplainRequest(sql: sql, mode: result.mode,
            context: .init(documentId: "private-source", targetDocumentId: "private-target", rangeLocation: 0,
                rangeLength: sql.utf16.count, profileId: "private-profile", sessionId: "private-session", transactionStatus: "idle"))
        var plan = ExplainPlanModel(request: request, sourceText: "private editor content", sourceRange: NSRange(location: 0, length: sql.utf16.count), profileID: UUID())
        plan.result = result
        return try PlanArtifact.capture(plan, title: "Advanced plan evidence")
    }

    @Test func sharedMetricContractPreservesExactValuesAndRejectsInvalidEvidence() throws {
        let object = try contract()
        #expect(object["version"] as? Int == 1 && object["capability"] as? String == ExplainNodeMetrics.capability)
        let results = try #require(object["results"] as? [[String: Any]])
        #expect(!results.isEmpty)
        for object in results {
            let result = try JSONDecoder().decode(ExplainResult.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(result.valid && result.advancedMetrics?.version == 1)
            #expect(try JSONDecoder().decode(ExplainResult.self, from: JSONEncoder().encode(result)) == result)
        }
        for object in try #require(object["invalidResults"] as? [[String: Any]]) {
            let data = try JSONSerialization.data(withJSONObject: #require(object["result"]))
            if let result = try? JSONDecoder().decode(ExplainResult.self, from: data) { #expect(!result.valid) }
        }
        for object in try #require(object["invalidDecodes"] as? [[String: Any]]) {
            let data = try JSONSerialization.data(withJSONObject: #require(object["result"]))
            #expect(throws: (any Error).self) { try JSONDecoder().decode(ExplainResult.self, from: data) }
        }
        let node = try #require(serial().nodes.first)
        #expect(node.advancedMetrics?.counters["sharedReadBlocks"]?.value == "9007199254740993")
        #expect(ExplainMetricPresentation.label(try #require(node.advancedMetrics?.counters["walBytes"])).contains("123456789012345678901234567890"))
        #expect(ExplainMetricPresentation.title("deformTime").contains("included in generation"))
        #expect(ExplainMetricPresentation.title("generationTime").contains("includes deform"))
    }

    @Test func rowDiscrepanciesRequireComparableScopeAndNeverDivideByZero() throws {
        var node = try #require(serial().nodes.first)
        node.metrics["estimatedRows"]?.value = "10"
        node.metrics["actualRows"]?.value = "2"
        #expect(ExplainMetricPresentation.rowBadge(node) == "Overestimated ≈5×")
        node.metrics["actualRows"]?.value = "40"
        #expect(ExplainMetricPresentation.rowBadge(node) == "Underestimated ≈4×")
        node.metrics["estimatedRows"]?.value = "0"
        #expect(ExplainMetricPresentation.rowBadge(node) == "Zero estimate; actual rows reported")
        node.metrics["actualRows"]?.value = "0"
        #expect(ExplainMetricPresentation.rowBadge(node) == "Estimate matched")
        node.metrics["estimatedRows"]?.value = "10"
        #expect(ExplainMetricPresentation.rowBadge(node) == "No actual rows; positive estimate")
        for scope in ["partialInput", "parallel", "logical", "notExecuted", "notCollected", "notReported", "unknownScope"] {
            node.advancedMetrics?.rowComparison = scope
            #expect(ExplainMetricPresentation.rowBadge(node) == nil)
            #expect(!ExplainMetricPresentation.rowComparison(node).hasPrefix("Comparable"))
        }
        node.advancedMetrics?.rowComparison = "partialInput"
        #expect(ExplainMetricPresentation.rowComparison(node).contains("LIMIT"))
        node.advancedMetrics = nil
        #expect(ExplainMetricPresentation.rowBadge(node) == nil && ExplainMetricPresentation.rowComparison(node).contains("no row-scope evidence"))
    }

    @Test func finiteGeometryKeepsZeroMissingDisabledAndHugeExactNumbersDistinct() {
        func makeMetric(_ value: String) -> ExplainMetric { .init(value: value, unit: "ms", basis: "perInvocation") }
        for value in ["1e309", "12345678901234567890123456789012345678901234567890", "0.000000000000000000000000001", "1e-999999"] {
            let metric = makeMetric(value)
            let magnitude = ExplainPlanLayout.magnitude(metric)
            #expect(magnitude?.isFinite == true)
            let width = ExplainPlanLayout.fraction(metric, maximumMagnitude: magnitude)
            #expect(width == 1)
            #expect(ExplainMetricPresentation.label(metric).hasPrefix(value + " "))
        }
        #expect(ExplainPlanLayout.fraction(makeMetric("0e+20"), maximumMagnitude: 3) == 0)
        #expect(ExplainPlanLayout.fraction(nil, maximumMagnitude: 3) == nil)
        let disabled = ExplainMetric(unit: "ms", basis: "perInvocation", unavailableReason: "disabled")
        #expect(ExplainPlanLayout.fraction(disabled, maximumMagnitude: 3) == nil)
        #expect(ExplainMetricPresentation.label(disabled).contains("disabled"))
        let small = ExplainPlanLayout.fraction(makeMetric("1e-999999"), maximumMagnitude: 999999)
        #expect(small.map { $0.isFinite && $0 > 0 && $0 <= 1 } == true)
        #expect(ExplainPlanLayout.fraction(makeMetric("100"), maximumMagnitude: 3) == 0.1)
    }

    @Test func graphLayoutRetainsStructuralEdgesAndBoundsLargePlans() throws {
        var result = try serial()
        var root = try #require(result.nodes.first)
        root.id = "root"; root.children = ["left", "right"]; root.advancedMetrics = nil
        var left = root; left.id = "left"; left.children = ["leaf"]
        var right = root; right.id = "right"; right.children = []
        var leaf = root; leaf.id = "leaf"; leaf.children = []
        result.roots = ["root"]; result.nodes = [root, left, right, leaf]; result.advancedMetrics = nil
        let layout = ExplainPlanLayout(result)
        #expect(layout.rows.map(\.id) == ["root", "left", "leaf", "right"])
        #expect(layout.rows.map(\.depth) == [0, 1, 2, 1])
        #expect(layout.edges.count == 3 && !layout.limited)
        #expect(layout.rows.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        root.children = (1..<10_000).map { "node-\($0)" }
        result.nodes = [root] + root.children.map { id in var child = leaf; child.id = id; return child }
        let bounded = ExplainPlanLayout(result)
        #expect(bounded.rows.count == 500 && bounded.totalCount == 10_000 && bounded.limited)
        #expect(bounded.edges.count == 499 && bounded.height <= 36_012 && bounded.width <= 492)
        #expect(bounded.limitLabel.contains("10000") && bounded.limitLabel.contains("Tree"))
        #expect(ExplainPlanLayout(result, limit: -1).rows.isEmpty)
    }

    @Test func flameLanesUseOneDeclaredBasisWithoutMultiplyingLoopsOrInferringExclusiveTime() throws {
        var node = try #require(serial().nodes.first)
        let inclusive = try #require(ExplainFlameBasis.inclusiveTime.metric(node))
        #expect(inclusive.value == "0.125" && node.metrics["loops"]?.value == "3")
        #expect(ExplainFlameBasis.exclusiveTime.metric(node)?.value == "0.125")
        node.advancedMetrics?.exclusiveTime = .init(unit: "ms", basis: "exclusivePerInvocation", unavailableReason: "inclusiveOnly")
        #expect(ExplainFlameBasis.exclusiveTime.metric(node)?.value == nil)
        #expect(ExplainMetricPresentation.label(try #require(ExplainFlameBasis.exclusiveTime.metric(node))).contains("cannot be derived"))
        node.metrics["totalTime"] = .init(unit: "ms", basis: "perInvocation", unavailableReason: "disabled")
        node.metrics["totalCost"] = .init(value: "2", unit: "cost", basis: "inclusive")
        #expect(ExplainFlameBasis.inclusiveTime.metric(node)?.unavailableReason == "disabled")
        #expect(ExplainFlameBasis.estimatedCost.metric(node)?.value == "2")
        node.metrics["totalTime"] = .init(value: "9", unit: "ms", basis: "total")
        #expect(ExplainFlameBasis.inclusiveTime.metric(node) == nil)
        #expect(ExplainFlameBasis.inclusiveTime.explanation.contains("not a timeline"))
        #expect(ExplainFlameBasis.estimatedCost.explanation.contains("not elapsed time"))
    }

    @Test func sqliteStructureNeedsNoInventedRowsCostsOrTiming() {
        let node = ExplainNode(id: "eqp", children: [], operation: "SCAN items", details: ["id": "2", "parent": "0", "aux": "0"], execution: "estimated", metrics: [:])
        let result = ExplainResult(support: .init(engine: .sqlite, serverVersion: "3.46", format: "queryPlan", modes: [.plan]), mode: .plan,
            status: "tree", raw: "2|0|0|SCAN items", complete: true, roots: ["eqp"], nodes: [node], metrics: [:])
        #expect(result.valid && ExplainPlanLayout(result).rows.count == 1)
        for basis in ExplainFlameBasis.allCases { #expect(basis.metric(node) == nil) }
        #expect(ExplainMetricPresentation.rowBadge(node) == nil)
    }

    @Test func versionFiveArtifactIsPortableAndEveryOldHeaderRejectsAdvancedPresenceIncludingNull() throws {
        let artifact = try makeArtifact(serial())
        let text = try artifact.encoded()
        let restored = try PlanArtifact.decode(text)
        #expect(restored.version == PlanArtifact.currentVersion && restored.result == artifact.result && restored.request.context == nil)
        #expect(!text.contains("private-") && !text.contains("private editor") && !text.contains("authorization"))
        #expect(restored.displayPlan.sessionID == nil && restored.displayPlan.sourceDocumentID == nil && restored.displayPlan.targetDocumentID == nil && restored.displayPlan.profile == nil)
        let original = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let originalResult = try #require(original["result"] as? [String: Any])
        let originalNodes = try #require(originalResult["nodes"] as? [[String: Any]])
        let originalAdvanced = try #require(originalNodes.first?["advancedMetrics"])
        for version in 1...4 {
            var old = artifact
            old.version = version
            #expect(!old.valid)
            old.result.advancedMetrics = nil
            for index in old.result.nodes.indices { old.result.nodes[index].advancedMetrics = nil }
            #expect(try PlanArtifact.decode(old.encoded()).version == version)
            for placement in ["result", "node"] {
                for null in [false, true] {
                    var object = original
                    object["version"] = version
                    var result = try #require(object["result"] as? [String: Any])
                    var nodes = try #require(result["nodes"] as? [[String: Any]])
                    result.removeValue(forKey: "advancedMetrics")
                    for index in nodes.indices { nodes[index].removeValue(forKey: "advancedMetrics") }
                    if placement == "result" { result["advancedMetrics"] = null ? NSNull() : ["version": 1] as Any }
                    else { nodes[0]["advancedMetrics"] = null ? NSNull() : originalAdvanced }
                    result["nodes"] = nodes; object["result"] = result
                    let invalid = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                    #expect(throws: (any Error).self) { try PlanArtifact.decode(invalid) }
                }
            }
        }
    }

    @Test func metricAdmissionRequiresBothCapabilitiesAndExactSQLServerOwner() throws {
        let support = try serial().support
        #expect(ExplainMetricsAdmission.validOwner(support: support, engine: .postgresql, capabilities: [ExplainNodeMetrics.capability], helperSupports: true))
        #expect(!ExplainMetricsAdmission.validOwner(support: support, engine: .postgresql, capabilities: [], helperSupports: true))
        #expect(!ExplainMetricsAdmission.validOwner(support: support, engine: .postgresql, capabilities: [ExplainNodeMetrics.capability], helperSupports: false))
        #expect(!ExplainMetricsAdmission.validOwner(support: support, engine: .mysql, capabilities: [ExplainNodeMetrics.capability], helperSupports: true))
        #expect(!ExplainMetricsAdmission.validOwner(support: nil, engine: .postgresql, capabilities: [ExplainNodeMetrics.capability], helperSupports: true))
        let sqlite = ExplainSupport(engine: .sqlite, serverVersion: "3.46", format: "queryPlan", modes: [.plan])
        #expect(!ExplainMetricsAdmission.validOwner(support: sqlite, engine: .sqlite, capabilities: [ExplainNodeMetrics.capability], helperSupports: true))
    }
}
