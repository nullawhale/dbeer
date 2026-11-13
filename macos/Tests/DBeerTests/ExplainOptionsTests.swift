import Foundation
import Testing
@testable import DBeer

/// Pure model/protocol/artifact checks. No application, workspace or views.
struct ExplainOptionsTests {
    private func support(_ engine: DatabaseEngine = .postgresql) -> ExplainSupport {
        if engine == .postgresql {
            return .init(engine: .postgresql, serverVersion: "17.6", format: "json", modes: [.plan, .analyze],
                options: .init(postgresql: .init(plan: ["buffers", "settings", "memory"],
                    analyze: ["buffers", "wal", "settings", "memory", "serialize", "timing"])))
        }
        return .init(engine: .mysql, serverVersion: "8.4.0", format: "tree", modes: [.plan, .analyze],
            options: .init(mysql: .init(plan: ["tree", "json"], analyze: ["tree", "json"], jsonAnalyzeRequiresVersion2: true)))
    }

    @Test func sharedOptionsContractRoundTripsAndRejectsEveryMalformedCommand() throws {
        struct Contract: Decodable { let version: Int; let capability: String; let commands: [BackendCommand] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/explain-options-v1/contract.json"))
        let contract = try JSONDecoder().decode(Contract.self, from: data)
        #expect(contract.version == 1 && contract.capability == ExplainOptionsAdmission.capability)
        #expect(!contract.commands.isEmpty)
        for command in contract.commands {
            #expect(command.explain?.valid == true && command.explain?.options != nil)
            #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command)) == command)
        }
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let invalid = try #require(object["invalidCommands"] as? [[String: Any]])
        #expect(!invalid.isEmpty)
        for entry in invalid {
            let invalidCommand = try #require(entry["command"])
            let command = try JSONSerialization.data(withJSONObject: invalidCommand)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(BackendCommand.self, from: command) }
        }
    }

    @Test func closedOptionUnionRejectsUnknownEngineFieldsAndNulls() throws {
        for invalid in [#"{}"#, #"{"postgresql":{},"mysql":{"format":"json"}}"#, #"{"sqlite":{}}"#,
                        #"{"postgresql":{"buffers":null}}"#, #"{"postgresql":{"timing":"false"}}"#,
                        #"{"postgresql":{"verbose":true}}"#, #"{"mysql":{"format":"text"}}"#,
                        #"{"mysql":{"format":"json","authorization":"injected"}}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(ExplainOptions.self, from: Data(invalid.utf8)) }
        }
        for invalid in [#"{"postgresql":{"plan":[],"analyze":[],"future":true}}"#,
                        #"{"postgresql":{"plan":[],"analyze":[]},"future":true}"#,
                        #"{"mysql":{"plan":["json"],"analyze":[],"jsonAnalyzeRequiresVersion2":false,"retry":true}}"#,
                        #"{"postgresql":null}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(ExplainOptionSupport.self, from: Data(invalid.utf8)) }
        }
        let options = ExplainOptions(postgresql: .init(buffers: false, wal: true, settings: true, memory: true, serialize: .binary, timing: false))
        #expect(try JSONDecoder().decode(ExplainOptions.self, from: JSONEncoder().encode(options)) == options)
        #expect(options.summary.contains("BUFFERS OFF") && options.summary.contains("TIMING OFF") && options.summary.contains("SERIALIZE BINARY"))
    }

    @Test func capabilitiesAndModeComeFromTheExactConnectedEngine() {
        let pg = support()
        #expect(ExplainOptionsAdmission.validOwner(support: pg, engine: .postgresql, capabilities: ["explainOptionsV1"], helperSupports: true))
        #expect(!ExplainOptionsAdmission.validOwner(support: pg, engine: .postgresql, capabilities: [], helperSupports: true))
        #expect(!ExplainOptionsAdmission.validOwner(support: pg, engine: .postgresql, capabilities: ["explainOptionsV1"], helperSupports: false))
        #expect(!ExplainOptionsAdmission.validOwner(support: pg, engine: .mysql, capabilities: ["explainOptionsV1"], helperSupports: true))
        var legacy = pg
        legacy.options = nil
        #expect(!ExplainOptionsAdmission.validOwner(support: legacy, engine: .postgresql, capabilities: ["explainOptionsV1"], helperSupports: true))
        for engine in [DatabaseEngine.sqlite, .mongodb, .cassandra] {
            #expect(!ExplainOptions(postgresql: .init()).valid(engine: engine))
            #expect(!ExplainOptions(mysql: .init(format: .json)).valid(engine: engine))
        }
        #expect(ExplainOptionsAdmission.accepts(.init(postgresql: .init(buffers: true, settings: false, memory: true)), support: pg, mode: .plan))
        for options in [PostgresExplainOptions(wal: false), .init(timing: true), .init(serialize: ExplainSerialize.none)] {
            #expect(!ExplainOptionsAdmission.accepts(.init(postgresql: options), support: pg, mode: .plan))
            #expect(ExplainOptionsAdmission.accepts(.init(postgresql: options), support: pg, mode: .analyze))
        }
        var oldPG = pg
        oldPG.options?.postgresql?.plan = ["buffers", "settings"]
        oldPG.options?.postgresql?.analyze = ["buffers", "wal", "settings", "timing"]
        let memory = ExplainOptions(postgresql: .init(memory: false))
        let serialize = ExplainOptions(postgresql: .init(serialize: .text))
        let otherEngine = ExplainOptions(mysql: .init(format: .json))
        let memoryAllowed: Bool = ExplainOptionsAdmission.accepts(memory, support: oldPG, mode: .plan)
        let serializeAllowed: Bool = ExplainOptionsAdmission.accepts(serialize, support: oldPG, mode: .analyze)
        let otherEngineAllowed: Bool = ExplainOptionsAdmission.accepts(otherEngine, support: pg, mode: .plan)
        #expect(memoryAllowed == false)
        #expect(serializeAllowed == false)
        #expect(otherEngineAllowed == false)
        #expect(oldPG.options?.accepts(options: memory, mode: .plan, engine: .postgresql) == false)
        #expect(oldPG.options?.accepts(options: serialize, mode: .analyze, engine: .postgresql) == false)
        #expect(pg.options?.accepts(options: otherEngine, mode: .plan, engine: .postgresql) == false)
        var invalidOwner = pg
        invalidOwner.format = "unsupported"
        let invalidOwnerAllowed = ExplainOptionsAdmission.accepts(.init(postgresql: .init(buffers: true)), support: invalidOwner, mode: .plan)
        #expect(invalidOwnerAllowed == false)
    }

    @Test func mysqlFormatsAndUnavailableAnalyzeStayExplicit() {
        var mysql = support(.mysql)
        for format in MySQLExplainFormat.allCases {
            #expect(ExplainOptionsAdmission.accepts(.init(mysql: .init(format: format)), support: mysql, mode: .plan))
            #expect(ExplainOptionsAdmission.accepts(.init(mysql: .init(format: format)), support: mysql, mode: .analyze))
        }
        mysql.serverVersion = "5.7.44"; mysql.format = "json"; mysql.modes = [.plan]
        mysql.options = .init(mysql: .init(plan: ["json"], analyze: [], jsonAnalyzeRequiresVersion2: false))
        mysql.analyzeUnavailableReason = "MySQL 5.7 supports estimated JSON plans; Analyze requires MySQL 8.0.18 or later."
        #expect(mysql.valid && mysql.analyzeUnavailableReason?.contains("5.7") == true)
        #expect(ExplainOptionsAdmission.accepts(.init(mysql: .init(format: .json)), support: mysql, mode: .plan))
        let tree = ExplainOptions(mysql: .init(format: .tree))
        let automatic = ExplainOptions(mysql: .init(format: .auto))
        let treeAllowed: Bool = ExplainOptionsAdmission.accepts(tree, support: mysql, mode: .plan)
        let analyzeAllowed: Bool = ExplainOptionsAdmission.accepts(automatic, support: mysql, mode: .analyze)
        #expect(treeAllowed == false)
        #expect(analyzeAllowed == false)
        #expect(mysql.options?.accepts(options: tree, mode: .plan, engine: .mysql) == false)
        #expect(mysql.options?.accepts(options: automatic, mode: .analyze, engine: .mysql) == false)
    }

    @Test func observedMySQLFormatCannotMisrepresentAnalyzeOrTheSelectedFormat() {
        let mysql = support(.mysql)
        let json = ExplainOptions(mysql: .init(format: .json))
        let tree = ExplainOptions(mysql: .init(format: .tree))
        #expect(validExplainSelection(support: mysql, options: json, mode: .plan, format: "jsonV1", status: "tree"))
        #expect(validExplainSelection(support: mysql, options: json, mode: .analyze, format: "jsonV2", status: "tree"))
        #expect(!validExplainSelection(support: mysql, options: json, mode: .analyze, format: "jsonV1", status: "tree"))
        #expect(!validExplainSelection(support: mysql, options: json, mode: .analyze, format: "tree", status: "tree"))
        #expect(!validExplainSelection(support: mysql, options: tree, mode: .analyze, format: "jsonV2", status: "tree"))
        #expect(!validExplainSelection(support: mysql, options: json, mode: .analyze, format: "json", status: "tree"))
        #expect(validExplainSelection(support: mysql, options: json, mode: .analyze, format: "json", status: "rawOnly"))
        #expect(!validExplainSelection(support: mysql, options: json, mode: .plan, format: nil, status: "rawOnly"))
    }

    private func model(options: ExplainOptions? = nil) throws -> ExplainPlanModel {
        // The shared PostgreSQL Analyze sample is deliberately raw-only. Use
        // its nonempty estimated tree for synthetic artifact-node coverage.
        var result = try #require(ExplainFixture.load().results.first { $0.support.engine == .postgresql && $0.status == "tree" && !$0.nodes.isEmpty })
        result.mode = .analyze
        for index in result.nodes.indices { result.nodes[index].execution = "executed" }
        if let options { result.support = support(); result.options = options; result.format = "json" }
        let sql = "SELECT :p"
        let request = ExplainRequest(sql: sql, mode: .analyze,
            parameters: [.init(name: "p", type: .decimal, value: "9007199254740993.1200")],
            context: .init(documentId: "private-source", targetDocumentId: "private-target", rangeLocation: 42,
                rangeLength: sql.utf16.count, profileId: "private-profile", sessionId: "private-session", transactionStatus: "transaction"), options: options)
        var model = ExplainPlanModel(request: request, sourceText: "unrelated private editor", sourceRange: NSRange(location: 42, length: sql.utf16.count), profileID: UUID())
        model.result = result
        model.sourceEvidence = .init(rangeLocation: 42, rangeLength: sql.utf16.count, transactionStatus: "transaction")
        return model
    }

    @Test func versionFourSavesExactOptionsAndReadsAllPreviousEnvelopesOffline() throws {
        let options = ExplainOptions(postgresql: .init(buffers: false, wal: true, settings: true, memory: true, serialize: .text, timing: false))
        var plan = try model(options: options)
        var result = try #require(plan.result)
        let nodeIndex = try #require(result.nodes.indices.first)
        result.nodes[nodeIndex].metrics["totalTime"] = .init(unit: "ms", basis: "perInvocation", unavailableReason: "disabled")
        plan.result = result
        let artifact = try PlanArtifact.capture(plan, title: "Options evidence")
        let encoded = try artifact.encoded()
        let restored = try PlanArtifact.decode(encoded)
        #expect(restored.version == 4 && restored.request.options == options && restored.result.options == options && restored.result.format == "json")
        #expect(restored.request.parameters == plan.request.parameters && restored.request.context == nil && restored.source == plan.sourceEvidence)
        #expect(restored.displayPlan.sessionID == nil && restored.displayPlan.profile == nil && restored.displayPlan.sourceDocumentID == nil)
        let restoredNode = try #require(restored.result.nodes.first)
        #expect(restoredNode.metrics["totalTime"]?.label.contains("disabled") == true)
        #expect(!encoded.contains("private-") && !encoded.contains("unrelated private editor") && !encoded.contains("authorization"))
        var legacy = try PlanArtifact.capture(model(), title: "Legacy evidence")
        legacy.source = nil; legacy.request.parameters = nil
        for version in 1...4 {
            legacy.version = version
            #expect(try PlanArtifact.decode(legacy.encoded()).version == version)
        }
    }

    @Test func olderEnvelopesRejectEveryNewOptionFieldAndDisabledOrUnknownEvidence() throws {
        var legacy = try PlanArtifact.capture(model(), title: "Legacy")
        legacy.source = nil; legacy.request.parameters = nil
        let base = try #require(JSONSerialization.jsonObject(with: Data(legacy.encoded().utf8)) as? [String: Any])
        for version in 1...3 {
            for field in ["requestOptions", "resultOptions", "resultFormat", "supportOptions", "analyzeReason", "disabled", "unknown", "mysqlJSON", "notices", "nullNotices"] {
                var object = base
                object["version"] = version
                var request = try #require(object["request"] as? [String: Any])
                var result = try #require(object["result"] as? [String: Any])
                var support = try #require(result["support"] as? [String: Any])
                if field == "requestOptions" { request["options"] = ["postgresql": [:]] }
                if field == "resultOptions" { result["options"] = ["postgresql": [:]] }
                if field == "resultFormat" { result["format"] = "json" }
                if field == "supportOptions" { support["options"] = ["postgresql": ["plan": [], "analyze": []]] }
                if field == "analyzeReason" { support["analyzeUnavailableReason"] = NSNull() }
                if field == "notices" { support["notices"] = ["Captured server limitation"] }
                if field == "nullNotices" { support["notices"] = NSNull() }
                if field == "mysqlJSON" { support["engine"] = "mysql"; support["format"] = "json"; support.removeValue(forKey: "planKinds") }
                if field == "disabled" { result["metrics"] = ["time": ["unit": "ms", "basis": "total", "unavailableReason": "disabled"]] }
                if field == "unknown" {
                    var nodes = try #require(result["nodes"] as? [[String: Any]])
                    let nodeIndex = try #require(nodes.indices.first)
                    nodes[nodeIndex]["execution"] = "unknown"; result["nodes"] = nodes
                }
                result["support"] = support; object["result"] = result; object["request"] = request
                let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                #expect(throws: (any Error).self) { try PlanArtifact.decode(text) }
            }
        }
    }

    @Test func serverNoticesAreBoundedAndRemainOfflineEvidenceWithDefaultOptions() throws {
        let notices = ["MySQL 8.0.18 Analyze skips SELECT-list expressions; fixed in 8.0.19.",
            "MySQL Analyze cancellation with KILL QUERY requires 8.0.20 or later."]
        var mysql = support(.mysql)
        mysql.serverVersion = "8.0.18"
        mysql.options?.mysql?.analyze = ["tree"]
        mysql.options?.mysql?.jsonAnalyzeRequiresVersion2 = false
        mysql.notices = notices
        #expect(mysql.valid)
        for invalid in [Array(repeating: "notice", count: 9), [""], [String(repeating: "x", count: 4097)]] {
            var changed = mysql; changed.notices = invalid
            #expect(!changed.valid)
        }
        let sqlite = ExplainSupport(engine: .sqlite, serverVersion: "3.46", format: "queryPlan", modes: [.plan], notices: notices)
        #expect(!sqlite.valid)
        let sql = "SELECT 1"
        var plan = ExplainPlanModel(request: .init(sql: sql, mode: .analyze), sourceText: sql,
            sourceRange: NSRange(location: 0, length: sql.utf16.count), profileID: UUID())
        plan.result = .init(support: mysql, mode: .analyze, status: "rawOnly", raw: "Captured original TREE output",
            complete: true, diagnostic: "Fixture raw evidence", roots: [], nodes: [], metrics: [:], format: "tree")
        let artifact = try PlanArtifact.capture(plan, title: "Older server evidence")
        let restored = try PlanArtifact.decode(artifact.encoded())
        #expect(restored.version == 4 && restored.request.options == nil && restored.result.options == nil)
        #expect(restored.result.support.notices == notices && restored.displayPlan.result?.support.notices == notices)
        #expect(restored.displayPlan.sessionID == nil && restored.displayPlan.profile == nil)
        var oldEnvelope = artifact
        oldEnvelope.result.format = nil; oldEnvelope.result.support.options = nil
        for version in 1...3 {
            oldEnvelope.version = version
            #expect(!oldEnvelope.valid)
        }
    }

    @Test func artifactCannotClaimDifferentOptionsAndComparisonKeepsMeasurementConditions() throws {
        let before = try PlanArtifact.capture(model(options: .init(postgresql: .init(timing: false))), title: "Before")
        var after = before
        after.request.options?.postgresql?.timing = true
        #expect(!after.valid)
        after.result.options = after.request.options
        #expect(after.valid)
        #expect(!PlanComparison(before: before, after: after).metricsComparable)
        #expect(PlanComparison(before: before, after: before).metricsComparable)
    }
}
