import Foundation
import Testing
@testable import DBeer

private struct EngineDiagnosticFixture: Decodable {
    struct Entry: Decodable { var name: String; var request: ExplainRequest; var result: ExplainResult }
    var version: Int
    var capability: String
    var fixtures: [Entry]
    static func load() throws -> Self {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/engine-diagnostics-v1/contract.json")))
    }
}

/// Pure parser/DTO/artifact tests: no workspace, AppKit, session start or UI.
struct ExplainEngineDiagnosticTests {
    @Test func sharedContractKeepsEngineModelsAndExactMeasurementMeaning() throws {
        let contract = try EngineDiagnosticFixture.load()
        #expect(contract.version == 1 && contract.capability == "engineDiagnosticsV1")
        for fixture in contract.fixtures {
            #expect(fixture.request.valid && fixture.result.valid)
            #expect(fixture.result.nodes.isEmpty && fixture.result.roots.isEmpty && fixture.result.metrics.isEmpty)
            #expect(ExplainRanking(fixture.result).entries.isEmpty)
            #expect(try JSONDecoder().decode(ExplainResult.self, from: JSONEncoder().encode(fixture.result)) == fixture.result)
        }
        let mongo = try #require(contract.fixtures.first?.result.engineDiagnostic?.mongodb)
        #expect(mongo.metrics["nReturned"]?.value == "9007199254740993")
        #expect(mongo.metrics["totalKeysExamined"]?.value == "0")
        #expect(mongo.metrics["totalDocsExamined"]?.value == nil)
        #expect(mongo.metrics["totalDocsExamined"]?.label.contains("Unavailable") == true)
        #expect(mongo.stages.last?.metrics["executionTimeMillisEstimate"]?.basis == "stageEstimate")
        let trace = try #require(contract.fixtures.last?.result.engineDiagnostic?.cassandra)
        #expect(trace.scope == "firstServerPage" && trace.pageSize == 200 && trace.collectionConsistency == "ONE")
        #expect(trace.hasMorePages && trace.collectionStatus == "partial")
        #expect(trace.traceSessions.first?.events.first?.sourceElapsed.value == nil)
        #expect(trace.traceSessions.first?.duration.label.contains("coordinator") == true)
    }

    @Test func closedUnionRejectsUnknownTagInjectedPayloadAndEngineOrModeMismatch() throws {
        for json in [#"{"kind":"future","mongodb":{}}"#, #"{"kind":"mongodbExplain","mongodb":{},"cassandra":{}}"#,
                     #"{"kind":"cassandraTrace","cassandra":null}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(EngineDiagnostic.self, from: Data(json.utf8)) }
        }
        let fixtures = try EngineDiagnosticFixture.load().fixtures
        let diagnostic = try #require(fixtures[0].result.engineDiagnostic)
        let encoded = try JSONEncoder().encode(diagnostic)
        var union = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        union["cassandra"] = ["scope": "firstServerPage"]
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(EngineDiagnostic.self, from: JSONSerialization.data(withJSONObject: union))
        }
        union.removeValue(forKey: "cassandra")
        union["authorization"] = "injected"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(EngineDiagnostic.self, from: JSONSerialization.data(withJSONObject: union))
        }
        var result = fixtures[0].result
        result.support.engine = .postgresql
        #expect(!result.valid)
        result = fixtures[0].result
        result.engineDiagnostic?.kind = "cassandraTrace"
        #expect(!result.valid)
        result = fixtures[0].result
        result.nodes = try ExplainFixture.load().results[0].nodes
        #expect(!result.valid)
        result = fixtures[1].result
        result.mode = .plan
        #expect(!result.valid)
        result = fixtures[1].result
        result.complete = true
        #expect(!result.valid)
    }

    @Test func plannerAbsenceAndPerSourceClocksStayDistinctFromZero() throws {
        var result = try EngineDiagnosticFixture.load().fixtures[0].result
        result.mode = .plan
        result.engineDiagnostic?.mongodb?.verbosity = "queryPlanner"
        result.engineDiagnostic?.mongodb?.metrics["nReturned"] = .init(unit: "documents", basis: "total", unavailableReason: "notCollected")
        #expect(result.valid)
        #expect(result.engineDiagnostic?.mongodb?.metrics["nReturned"]?.label.contains("not collected") == true)
        let zero = DiagnosticMetric(value: "0", unit: "us", basis: "sourceElapsed")
        let missing = DiagnosticMetric(unit: "us", basis: "sourceElapsed", unavailableReason: "notReported")
        #expect(zero.valid && missing.valid && zero != missing)
        #expect(zero.label.contains("0 us") && zero.label.contains("this source node"))
        #expect(!DiagnosticMetric(value: "0", unit: "cost", basis: "inclusive").valid)
    }

    @Test func mongoDiagnosticAdmissionKeepsRawValuesAndRejectsWritesOrExecutableOperators() throws {
        let valid = [#"{"collection":"items","find":{"n":{"$numberLong":"9007199254740993"}},"limit":1}"#,
                     #"{"database":"fixture","collection":"items","aggregate":[{"$match":{"pipeline":[{"$out":"literal data"}]}},{"$lookup":{"from":"other","pipeline":[{"$match":{}}],"as":"matches"}}]}"#]
        for text in valid {
            #expect(MongoDBScript.validDiagnostic(text))
            let fragment = try #require(SQLExecutionFragment.resolve(text: text, selection: NSRange(location: 0, length: text.utf16.count), engine: .mongodb))
            #expect(try ExplainPlanModel.request(fragment: fragment, mode: .plan, engine: .mongodb).sql == text)
        }
        for text in [#"{"collection":"items","find":{},"find":{}}"#, #"{"collection":"items","find":{"$where":"1"}}"#,
                     #"{"collection":"items","aggregate":[{"$out":"other"}]}"#,
                     #"{"collection":"items","aggregate":[{"$facet":{"nested":[{"$merge":"other"}]}}]}"#,
                     #"{"collection":"items","aggregate":[{"$lookup":{"pipeline":[{"$out":"other"}]}}]}"#,
                     #"{"collection":"items","aggregate":[{"$unknown":{}}]}"#, #"{"collection":"items","find":{},"aggregate":[]}"#,
                     #"{"collection":"items","find":{},"limit":true}"#, #"db.items.find({})"#] {
            #expect(!MongoDBScript.validDiagnostic(text))
        }
    }

    @Test func cassandraOnlyTracesSelectedReadsAndReportsEstimatedModeUnavailable() throws {
        let sql = "SELECT * FROM fixture.items"
        let fragment = try #require(SQLExecutionFragment.resolve(text: sql, selection: NSRange(location: 0, length: 0), engine: .cassandra))
        #expect(try ExplainPlanModel.request(fragment: fragment, mode: .analyze, engine: .cassandra).sql == sql)
        #expect(throws: ExecutionPolicyError.self) { try ExplainPlanModel.request(fragment: fragment, mode: .plan, engine: .cassandra) }
        let write = try #require(SQLExecutionFragment.resolve(text: "DELETE FROM fixture.items", selection: NSRange(location: 0, length: 0), engine: .cassandra))
        #expect(throws: ExecutionPolicyError.self) { try ExplainPlanModel.request(fragment: write, mode: .analyze, engine: .cassandra) }
        #expect(ExplainMode.plan.title(engine: .cassandra).contains("Unavailable"))
        #expect(ExplainMode.analyze.commandTitle(engine: .mongodb) == "Execution Statistics…")
    }

    @Test func unsupportedContextNeedsNegotiatedActualNoSQLPhysicalOwner() throws {
        let support = try EngineDiagnosticFixture.load().fixtures[0].result.support
        func admits(_ support: ExplainSupport?, _ caps: Set<String>, _ hello: Bool, _ transaction: TransactionStatus?, _ parameters: [QueryParameterBinding]? = nil) -> Bool {
            ExplainDiagnosticAdmission.validOwner(support: support, capabilities: caps, helperSupports: hello, transaction: transaction, parameters: parameters, planKind: nil)
        }
        #expect(admits(support, ["engineDiagnosticsV1"], true, .unsupported))
        #expect(!admits(support, [], true, .unsupported))
        #expect(!admits(support, ["engineDiagnosticsV1"], false, .unsupported))
        #expect(!admits(support, ["engineDiagnosticsV1"], true, .idle))
        #expect(!admits(support, ["engineDiagnosticsV1"], true, nil))
        #expect(!admits(support, ["engineDiagnosticsV1"], true, .unsupported, []))
        var relational = support
        relational.engine = .postgresql
        #expect(!admits(relational, ["engineDiagnosticsV1"], true, .unsupported))
    }

    @Test func portableVersionThreeKeepsDiagnosticsAndStripsExecutionOwnership() throws {
        for fixture in try EngineDiagnosticFixture.load().fixtures {
            var request = fixture.request
            request.context = .init(documentId: "private-source", targetDocumentId: "private-target", rangeLocation: 0,
                rangeLength: request.sql.utf16.count, profileId: "private-profile", sessionId: "private-session", transactionStatus: "unsupported")
            var plan = ExplainPlanModel(request: request, sourceText: "unrelated live editor", sourceRange: NSRange(location: 0, length: request.sql.utf16.count), profileID: UUID())
            plan.result = fixture.result
            plan.sourceEvidence = .init(rangeLocation: 0, rangeLength: request.sql.utf16.count, transactionStatus: "unsupported")
            let saved = try PlanArtifact.capture(plan, title: fixture.name)
            let encoded = try saved.encoded()
            let restored = try PlanArtifact.decode(encoded)
            #expect(restored.version == 3 && restored.result == fixture.result && restored.request.context == nil)
            #expect(!encoded.contains("private-") && !encoded.contains("unrelated live editor") && !encoded.contains("authorization"))
            var object = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
            for version in [1, 2, 4] {
                object["version"] = version
                let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                #expect(throws: (any Error).self) { try PlanArtifact.decode(text) }
            }
        }
    }

    @Test func relationalVersionsOneAndTwoRemainOfflineReadableAndKindsDoNotFakeTreeDiffs() throws {
        let fixtures = try EngineDiagnosticFixture.load().fixtures
        func artifact(_ result: ExplainResult, _ request: ExplainRequest) throws -> PlanArtifact {
            var plan = ExplainPlanModel(request: request, sourceText: request.sql, sourceRange: NSRange(location: 0, length: request.sql.utf16.count), profileID: UUID())
            plan.result = result
            return try PlanArtifact.capture(plan, title: "Recorded evidence")
        }
        let relational = try artifact(ExplainFixture.load().results[0], .init(sql: "SELECT 1", mode: .plan))
        for version in [1, 2, 3] {
            var legacy = relational
            legacy.version = version
            #expect(try PlanArtifact.decode(legacy.encoded()).version == version)
        }
        let mongo = try artifact(fixtures[0].result, fixtures[0].request)
        let cassandra = try artifact(fixtures[1].result, fixtures[1].request)
        for other in [relational, cassandra] {
            let comparison = PlanComparison(before: mongo, after: other)
            #expect(comparison.matches.isEmpty && !comparison.metricsComparable && !comparison.shapeAvailable)
            #expect(comparison.diagnosticMessage?.contains("Different evidence kinds") == true)
        }
        #expect(PlanComparison(before: mongo, after: mongo).diagnosticMessage?.contains("shown independently") == true)
    }
}
