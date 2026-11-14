import Foundation
import Testing
@testable import DBeer

/// Value/model checks only. No app, helper process, panels or native views.
struct MariaDBNativeTests {
    @Test func pairedGoFixtureKeepsNativeEngineValuesAndExecutingDML() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/mariadb-engine-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fixture["version"] as? Int == 1 && fixture["engine"] as? String == "mariadb" && fixture["defaultPort"] as? Int == 3306)
        func decode<T: Decodable>(_ type: T.Type, _ raw: Any) throws -> T {
            try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: raw))
        }
        for raw in try #require(fixture["connections"] as? [[String: Any]]) {
            let connection = try decode(ConnectionSettings.self, raw)
            #expect(connection.engine == .mariadb && connection.port == 3306)
            #expect(["structure", "import", "monitor"].contains(connection.sessionPurpose ?? ""))
        }
        for raw in try #require(fixture["nativeValues"] as? [[String: Any]]) {
            let value = try decode(NativeValue.self, raw)
            #expect(value.valid && value.engine == "mariadb")
            let roundTrip = try JSONDecoder().decode(NativeValue.self, from: JSONEncoder().encode(value))
            #expect(roundTrip == value)
        }
        for raw in try #require(fixture["invalidNativeValues"] as? [[String: Any]]) {
            #expect(throws: (any Error).self) { try decode(NativeValue.self, raw) }
        }
        let rawSupport = try #require(fixture["explainSupport"])
        let support = try decode(ExplainSupport.self, rawSupport)
        #expect(support.valid && support.engine == .mariadb && support.options == nil)
        for raw in try #require(fixture["dmlOutcomes"] as? [[String: Any]]) {
            let outcome = try decode(ExplainDMLResult.self, raw)
            #expect(outcome.valid(engine: .mariadb, mode: .analyze) && outcome.targetExecution == "executed")
        }
        let rawMetrics = try #require(fixture["metrics"])
        let metrics = try decode([String: ExplainMetric].self, rawMetrics)
        #expect(metrics["actualRows"]?.basis == "perInvocation" && metrics["loops"]?.basis == "total")
        #expect(metrics["totalTime"]?.basis == "inclusiveTotal" && metrics["exclusiveTime"]?.unavailableReason == "inclusiveOnly")
        let observed = try decode(MariaDBOptimizerObservation.self, #require(fixture["optimizerObservation"]))
        let variant = try decode(MariaDBOptimizerVariant.self, #require(fixture["optimizerVariant"]))
        #expect(observed.valid && variant.valid && observed.nativeSwitch == variant.expectedNativeSwitch && observed.indexConditionPushdown != variant.indexConditionPushdown)
        let nodeMetrics = try decode(ExplainNodeMetrics.self, #require(fixture["nodeMetrics"]))
        let nativeNode = ExplainNode(id: "native", children: [], operation: "Table access ALL on owned", details: [:], execution: "executed", metrics: [:])
        #expect(nodeMetrics.valid(engine: .mariadb, node: nativeNode, mode: .analyze))
        #expect(nodeMetrics.counters["mariaDBPagesAccessed"]?.value == "9007199254740993" && nodeMetrics.counters["mariaDBPagesReadTime"]?.value == "1.2300")
    }

    private func settings() -> ConnectionSettings {
        .init(host: "fixture.invalid", port: 3306, database: "fixture", user: "reader",
              password: "fixture-secret", sslMode: "verify-full", engine: .mariadb)
    }

    @MainActor @Test func profilesAndURLsKeepDistinctEngineIdentityWithoutPortableSecrets() throws {
        #expect(DatabaseEngine.mariadb.defaultPort == 3306)
        #expect(DatabaseEngine.mariadb.displayName == "MariaDB")
        let sequence = CatalogNode(profileID: UUID(), name: "native_counter", kind: .object,
            schema: "fixture", object: "native_counter", objectKind: "sequence", engine: .mariadb)
        #expect(!sequence.isExpandable && !sequence.isPostgresType && sequence.symbol == "list.number")
        let parsed = try ConnectionURL.parse("jdbc:mariadb://reader:p%40ss@fixture.invalid/fixture?sslMode=verify-full")
        #expect(parsed.engine == .mariadb && parsed.port == 3306 && parsed.password == "p@ss")
        let formatted = try #require(ConnectionURL.format(engine: .mariadb, host: parsed.host, port: "3306",
            database: parsed.database, user: "reader", sslMode: "verify-full", sslRootCert: ""))
        #expect(formatted.hasPrefix("mariadb://") && formatted.contains("sslMode=verify-full") && !formatted.contains("p%40ss"))
        #expect(try ConnectionURL.parse("mariadb://fixture.invalid/db?sslMode=trust").sslMode == "require")
        #expect(throws: ConnectionURL.Failure.unsupportedOption) { try ConnectionURL.parse("mariadb://fixture.invalid/db?serverSslCert=classpath:ca.pem") }
        #expect(try ConnectionURL.parse(formatted).engine == .mariadb)
        let original = SavedConnection(name: "MariaDB", settings: settings())
        var other = settings(); other.engine = .mysql
        #expect(!original.matches(other))
        var edit = ConnectionDraft(connection: original)
        #expect(throws: ConnectionURL.Failure.engineMismatch) { try edit.applyConnectionURL("mysql://reader@fixture.invalid/fixture") }
        #expect(edit.engine == .mariadb)
        let encoded = try ProfileTransfer.encode([original])
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("mariadb") && !text.contains("fixture-secret") && !text.contains(original.id.uuidString))
        let restored = try #require(ProfileTransfer.preview(encoded).first)
        #expect(restored.profile.engine == .mariadb && restored.id != original.id)
        #expect(restored.profile.settings(password: "").password.isEmpty)
    }

    @Test func mariaDBLexicalRulesKeepDelimiterRangesAndQuotedText() throws {
        let source = "DELIMITER $$\nCREATE PROCEDURE `p`() BEGIN SELECT 'a;b',`x`; END$$\nDELIMITER ;\n# comment\nSELECT 2;"
        let parsed = SQLScriptParser.parse(source, engine: .mariadb)
        #expect(parsed.diagnostics.isEmpty && parsed.statements.count == 2)
        #expect(parsed.statements[0].sql.contains("'a;b'") && !parsed.statements[0].sql.contains("DELIMITER"))
        #expect(parsed.statements[1].sql.contains("SELECT 2"))
        #expect(SQLScriptParser.parse("SELECT 1--2; SELECT 3", engine: .mariadb).statements.count == 2)
        let exact = "{ \"a\":1, \"a\":2, \"n\":9007199254740993 }"
        let native = NativeValue(kind: "text", value: exact, engine: "mariadb", nativeType: "LONGTEXT")
        #expect(native.valid)
        let decoded = try JSONDecoder().decode(NativeValue.self, from: JSONEncoder().encode(native))
        #expect(decoded.value == exact)
    }

    private func support() -> ExplainSupport {
        .init(engine: .mariadb, serverVersion: "10.11.9-MariaDB", format: "json", modes: [.plan, .analyze],
              unavailableReason: nil, dml: .init(estimatedForms: ["update", "delete"], analyze: ["update", "delete"], analyzeTargetExecution: "executes"))
    }

    @Test func optimizerVariantBindsExactNativeStateAndOneUseOwner() throws {
        let observed = MariaDBOptimizerObservation(indexConditionPushdown: true,
            nativeSwitch: "index_merge=on,index_condition_pushdown=on,future_native_flag=off")
        #expect(observed.valid)
        let setting = MariaDBOptimizerVariant(expectedNativeSwitch: observed.nativeSwitch, indexConditionPushdown: false)
        #expect(setting.valid)
        #expect(!MariaDBOptimizerVariant(expectedNativeSwitch: observed.nativeSwitch, indexConditionPushdown: true).valid)
        for native in ["", "index_condition_pushdown=unknown", "index_condition_pushdown=on,index_condition_pushdown=off", "index_condition_pushdown=on\0", "index_condition_pushdown=on\n", "garbage,index_condition_pushdown=on", "index_condition_pushdown=on,empty=", ",index_condition_pushdown=on"] {
            #expect(MariaDBOptimizerObservation.observedValue(native) == nil)
        }
        let sql = "SELECT n FROM `fixture`.`owned` WHERE n=1"
        let context = ExplainContext(documentId: "source", targetDocumentId: "target", rangeLocation: 0,
            rangeLength: sql.utf16.count, profileId: "profile", sessionId: "owner", transactionStatus: "idle")
        let source = ExplainRequest(sql: sql, mode: .plan, context: context)
        let request = TuningValidationRequest(version: 1, original: source, variant: source,
            target: .init(schema: "fixture", table: "owned", create: false), metadataFingerprint: String(repeating: "a", count: 64),
            maxRows: 100, maxBytes: 4_096, timeoutMs: 1_000, comparison: "multiset", mariaDBOptimizer: setting)
        #expect(request.valid)
        #expect(TuningTransportAdmission.optimizerSQL(setting, sql: sql) == "SET STATEMENT optimizer_switch='index_condition_pushdown=off' FOR\n" + sql)
        var changed = request; changed.variant.sql += " "
        #expect(!changed.valid)
        changed = request; changed.mariaDBOptimizer = nil
        #expect(!changed.valid)
        let operation = OperationRequest(type: "tuning.validate", tuningValidation: request)
        try TuningTransportAdmission.validateOperation(operation, session: "owner", owner: support(), transaction: .idle)
        var otherEngine = support(); otherEngine.engine = .mysql
        #expect(throws: (any Error).self) {
            try TuningTransportAdmission.validateOperation(operation, session: "owner", owner: otherEngine, transaction: .idle)
        }
        var ledger = TuningGrantLedger()
        ledger.record("grant", session: "owner", operation: operation)
        var altered = operation
        altered.tuningValidation?.mariaDBOptimizer?.expectedNativeSwitch += ",new_native_flag=on"
        let alteredGrantAccepted = ledger.consume("grant", session: "owner", operation: altered)
        #expect(!alteredGrantAccepted)
        let consumedGrantAccepted = ledger.consume("grant", session: "owner", operation: operation)
        #expect(!consumedGrantAccepted)
        ledger.record("next", session: "owner", operation: operation)
        let exactGrantAccepted = ledger.consume("next", session: "owner", operation: operation)
        #expect(exactGrantAccepted)
        let replayedGrantAccepted = ledger.consume("next", session: "owner", operation: operation)
        #expect(!replayedGrantAccepted)
        let encoded = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(TuningValidationRequest.self, from: encoded) == request)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MariaDBOptimizerVariant.self, from: Data(#"{"expectedNativeSwitch":"index_condition_pushdown=on","indexConditionPushdown":false,"other":1}"#.utf8))
        }
    }

    @Test func nativeEngineCountersStayExactAndEngineScoped() {
        var node = ExplainNode(id: "table", children: [], operation: "Table access ALL on owned", details: [:], execution: "executed",
            metrics: ["totalTime": .init(value: "100.2500", unit: "ms", basis: "inclusiveTotal", unavailableReason: nil)])
        var advanced = ExplainNodeMetrics(executionScope: "unknown", rowComparison: "unknownScope",
            exclusiveTime: .init(value: nil, unit: "ms", basis: "exclusivePerInvocation", unavailableReason: "inclusiveOnly"),
            counters: ["mariaDBPagesAccessed": .init(value: "9007199254740993", unit: "count", basis: "total", unavailableReason: nil)])
        node.advancedMetrics = advanced
        #expect(advanced.valid(engine: .mariadb, node: node, mode: .analyze))
        #expect(!advanced.valid(engine: .postgresql, node: node, mode: .analyze))
        #expect(!advanced.valid(engine: .mysql, node: node, mode: .analyze))
        #expect(ExplainMetricPresentation.title("mariaDBPagesAccessed") == "InnoDB pages accessed")
        advanced.counters["mariaDBPagesAccessed"]?.basis = "inclusiveTotal"
        #expect(!advanced.valid(engine: .mariadb, node: node, mode: .analyze))
        advanced.counters = ["sharedHitBlocks": .init(value: "1", unit: "blocks", basis: "inclusiveTotal", unavailableReason: nil)]
        #expect(!advanced.valid(engine: .mariadb, node: node, mode: .analyze))
    }

    @Test func nativeExplainDoesNotInheritMySQLOptionsOrSuppressedWrites() throws {
        var owner = support()
        #expect(owner.valid)
        let update = ExplainDMLTarget(statement: "update")
        #expect(ExplainDMLAdmission.accepts(update, support: owner, mode: .plan))
        #expect(ExplainDMLAdmission.accepts(update, support: owner, mode: .analyze))
        #expect(!ExplainDMLAdmission.accepts(.init(statement: "insert"), support: owner, mode: .plan))
        owner.options = .init(mysql: .init(plan: ["json"], analyze: ["json"], jsonAnalyzeRequiresVersion2: true))
        #expect(!owner.valid)
        owner = support(); owner.dml?.estimatedForms = nil
        #expect(!owner.valid)
        owner = support(); owner.dml?.analyzeTargetExecution = "suppresses"
        #expect(!owner.valid)
        var result = ExplainDMLResult(target: update, execution: "completed", persistence: "committed",
            transactionBefore: "idle", transactionAfter: "idle", affectedRowsUnavailableReason: "notReported", targetExecution: "executed")
        #expect(result.valid(engine: .mariadb, mode: .analyze))
        result.persistence = "transactionPending"; result.transactionBefore = "transaction"; result.transactionAfter = "transaction"
        #expect(result.valid(engine: .mariadb, mode: .analyze))
        result.targetExecution = "suppressed"; result.persistence = "notExecuted"
        #expect(!result.valid(engine: .mariadb, mode: .analyze))
        let missingForms = Data(#"{"estimated":true,"analyze":["update"],"analyzeTargetExecution":"executes"}"#.utf8)
        let decoded = try JSONDecoder().decode(ExplainDMLSupport.self, from: missingForms)
        #expect(!decoded.valid(engine: .mariadb))
    }

    @Test func inclusiveTimingIsNeverMultipliedByLoopsAndRemainsPortableEvidence() throws {
        let total = ExplainMetric(value: "100", unit: "ms", basis: "inclusiveTotal", unavailableReason: nil)
        let scan = ExplainNode(id: "scan", children: [], operation: "Table access ALL on t", details: [:], execution: "executed",
            metrics: ["totalTime": total, "loops": .init(value: "4", unit: "count", basis: "total", unavailableReason: nil)])
        let root = ExplainNode(id: "root", children: [scan.id], operation: "query_block", details: [:], execution: "executed", metrics: [:])
        let result = ExplainResult(support: support(), mode: .analyze, status: "tree", raw: "{}", complete: true, diagnostic: nil,
            roots: [root.id], nodes: [root, scan], metrics: [:], format: "json")
        #expect(result.valid)
        #expect(ExplainRanking(result).entries.first?.score == Decimal(100))
        #expect(ExplainRanking(result).basis.contains("total"))
        #expect(ExplainFlameBasis.inclusiveTime.metric(scan) == total)
        #expect(ExplainFlameBasis.exclusiveTime.metric(scan) == nil)
        let artifact = PlanArtifact(id: UUID(), title: "MariaDB", capturedAt: Date(), request: .init(sql: "SELECT 1", mode: .analyze), result: result)
        #expect(artifact.valid)
        let restored = try JSONDecoder().decode(PlanArtifact.self, from: JSONEncoder().encode(artifact))
        #expect(restored.result.support.engine == .mariadb && restored.result.nodes[1].metrics["totalTime"] == total)
    }

    @Test func nativeKindAndNumericAlgorithmBoundsStayEngineSpecific() {
        let operations = StructureAdvancedKindSupport.operationKinds.map { StructureAdvancedKindOperation(kind: $0, available: false, reason: "Needs this native operation's proof.") }
        let aria = StructureAdvancedKindSupport(kinds: ["mariaDBAria"], scope: "table", familyCount: 1, nontransactional: true, operations: operations)
        #expect(aria.valid(engine: "mariadb") && !aria.valid(engine: "mysql"))
        let mysql = StructureAdvancedKindSupport(kinds: ["myISAM"], scope: "table", familyCount: 1, nontransactional: true, operations: operations)
        #expect(mysql.valid(engine: "mysql") && !mysql.valid(engine: "mariadb"))
        let wrong = StructureAdvancedKindSupport(kinds: ["mariaDBAria"], scope: "table", familyCount: 1, nontransactional: false, operations: operations)
        #expect(!wrong.valid(engine: "mariadb"))
        let draft = StructureDraft(columns: [.init(name: "n", type: .init(kind: "numeric", precision: 65, scale: 38), nullable: true, default: .init(kind: "none"))])
        #expect(draft.valid(for: .mariadb) && !draft.valid(for: .mysql) && !draft.valid(for: .postgresql))
        let physical = StructurePhysicalDraft(version: 1, target: .init(schema: "fixture", table: "t", create: false),
            intent: .init(kind: "storageEngine", engine: "Aria", algorithm: "NOCOPY", lock: "SHARED"))
        #expect(physical.valid(for: .mariadb) && !physical.valid(for: .mysql))
        #expect(TuningTransportAdmission.validOwner(support: support(), engine: .mariadb, capabilities: [TuningInspectRequest.capability], helperSupports: true))
        var early = support(); early.serverVersion = "10.11.8-MariaDB"
        #expect(!TuningTransportAdmission.validOwner(support: early, engine: .mariadb, capabilities: [TuningInspectRequest.capability], helperSupports: true))
        #expect(!TuningTransportAdmission.validOwner(support: support(), engine: .mariadb, capabilities: [], helperSupports: true))
    }

    @Test func utilitiesRequireNativeNamesAndKeepRestoreUncertainty() {
        let request = DatabaseToolsRequest(connection: settings(), operation: "dump", format: "sql", path: "/fixture/dump.sql", toolPath: "/fixture/mariadb-dump")
        #expect(request.valid(for: "dbtools.preview"))
        var reply = DatabaseToolsReply(jobId: "job", state: .outcomeUnknown, phase: "outcomeUnknown", engine: .mariadb,
            operation: "restore", format: "sql", database: "fixture", path: "/fixture/dump.sql", toolName: "mariadb",
            toolVersion: "11.4.3-MariaDB", serverVersion: "11.4.3-MariaDB", requiresConfirmation: true, outputPublished: false, warnings: [])
        #expect(reply.valid(for: "dbtools.status.result"))
        reply.toolName = "mysql"
        #expect(!reply.valid(for: "dbtools.status.result"))
    }
}
