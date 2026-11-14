import Foundation
import Testing
@testable import DBeer

/// Shared synthetic fixtures only; no workspace, app, database or window dependencies.
struct TuningNativeFixture {
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    static func fields() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/tuning-v1/contract.json"))) as? [String: Any])
    }
    static func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: #require(fields()[key])))
    }
    static func artifact() throws -> PlanArtifact {
        let inspect = try decode(TuningInspectRequest.self, "inspectRequest")
        var plan = ExplainPlanModel(request: inspect.source, sourceText: inspect.source.sql,
            sourceRange: NSRange(location: 0, length: inspect.source.sql.utf16.count), profileID: UUID())
        plan.result = inspect.capture
        plan.sourceEvidence = .init(rangeLocation: 0, rangeLength: inspect.source.sql.utf16.count, transactionStatus: "idle")
        return try PlanArtifact.capture(plan, title: "Synthetic captured evidence")
    }
}

struct TuningNativeTests {
    @Test func exactOneUseGrantsBindLimitsNativeValuesAndPhysicalOwner() throws {
        let request = try TuningNativeFixture.decode(TuningValidationRequest.self, "validationRequest")
        let operation = OperationRequest(type: "tuning.validate", tuningValidation: request)
        var ledger = TuningGrantLedger()
        ledger.record("grant", session: "owner", operation: operation)
        var changed = operation; changed.tuningValidation?.maxRows -= 1
        let changedLimitsAccepted = ledger.consume("grant", session: "owner", operation: changed)
        #expect(!changedLimitsAccepted)
        let consumedChangeGrantAccepted = ledger.consume("grant", session: "owner", operation: operation)
        #expect(!consumedChangeGrantAccepted)
        ledger.record("grant", session: "owner", operation: operation)
        changed = operation; changed.tuningValidation?.variant.parameters?[0].value = "9007199254740992"
        let changedValuesAccepted = ledger.consume("grant", session: "owner", operation: changed)
        #expect(!changedValuesAccepted)
        ledger.record("grant", session: "owner", operation: operation)
        let foreignOwnerAccepted = ledger.consume("grant", session: "foreign-owner", operation: operation)
        #expect(!foreignOwnerAccepted)
        ledger.record("grant", session: "owner", operation: operation)
        let exactGrantAccepted = ledger.consume("grant", session: "owner", operation: operation)
        #expect(exactGrantAccepted)
        let replayedGrantAccepted = ledger.consume("grant", session: "owner", operation: operation)
        #expect(!replayedGrantAccepted)
        let staleAssessment = ledger.begin("owner")
        _ = ledger.begin("owner")
        ledger.record("late-assessment", session: "owner", operation: operation, assessedGeneration: staleAssessment)
        let lateAssessmentAccepted = ledger.consume("late-assessment", session: "owner", operation: operation)
        #expect(!lateAssessmentAccepted)
        ledger.record("captured-owner-grant", session: "owner", operation: operation)
        ledger.record("independent-grant", session: "independent", operation: operation)
        ledger.retire("independent")
        let capturedOwnerAccepted = ledger.consume("captured-owner-grant", session: "owner", operation: operation)
        #expect(capturedOwnerAccepted)
        ledger.record("grant", session: "owner", operation: operation); ledger.retire("owner")
        let retiredGrantAccepted = ledger.consume("grant", session: "owner", operation: operation)
        #expect(!retiredGrantAccepted)
    }
    @Test func commandFamiliesRequireExactLiveOwnerTransactionAndClosedFields() throws {
        let inspect = try TuningNativeFixture.decode(TuningInspectRequest.self, "inspectRequest")
        let owner = inspect.capture.support
        var command = BackendCommand.tuningInspect(sessionId: "owner", request: inspect)
        try TuningTransportAdmission.validateCommand(command, owner: owner, transaction: .idle)
        #expect(throws: (any Error).self) { try TuningTransportAdmission.validateCommand(command, owner: owner, transaction: .transaction) }
        command.sql = "SELECT excluded"
        #expect(throws: (any Error).self) { try TuningTransportAdmission.validateCommand(command, owner: owner, transaction: .idle) }
        let observation = try TuningNativeFixture.decode(TuningSettingObservationRequest.self, "settingObservationRequest")
        command = .tuningObserveSetting(sessionId: "owner", request: observation)
        try TuningTransportAdmission.validateCommand(command, owner: owner, transaction: .transaction)
        #expect(throws: (any Error).self) { try TuningTransportAdmission.validateCommand(command, owner: owner, transaction: .idle) }
        var mysql = owner; mysql.engine = .mysql; mysql.format = "tree"
        #expect(throws: (any Error).self) { try TuningTransportAdmission.validateCommand(command, owner: mysql, transaction: .transaction) }
        #expect(TuningTransportAdmission.validOwner(support: owner, engine: .postgresql, capabilities: [TuningInspectRequest.capability], helperSupports: true))
        #expect(!TuningTransportAdmission.validOwner(support: owner, engine: .postgresql, capabilities: [], helperSupports: true))
        #expect(!TuningTransportAdmission.validOwner(support: owner, engine: .postgresql, capabilities: [TuningInspectRequest.capability], helperSupports: false))
    }
    @Test func versionAndForkClaimsCannotInheritTuningFromABytePrefix() throws {
        let source = try TuningNativeFixture.decode(TuningInspectRequest.self, "inspectRequest")
        let caps: Set<String> = [TuningInspectRequest.capability]
        for (version, allowed) in [("13.9", false), ("14.0", true), ("17.10", true), ("unknown", false)] {
            var support = source.capture.support; support.serverVersion = version
            #expect(TuningTransportAdmission.validOwner(support: support, engine: .postgresql, capabilities: caps, helperSupports: true) == allowed)
        }
        for (version, allowed) in [("8.0.29", false), ("8.0.30", true), ("8.4.13", true), ("8.4.13-commercial-debug", true), ("8.4.13-Percona", false), ("10.11.2-MariaDB", false)] {
            var support = source.capture.support; support.engine = .mysql; support.format = "tree"; support.serverVersion = version
            #expect(TuningTransportAdmission.validOwner(support: support, engine: .mysql, capabilities: caps, helperSupports: true) == allowed)
        }
    }

    @Test func envelopesRejectMissingNullUnknownAndCrossFamilyEvidence() throws {
        let fixture = try TuningNativeFixture.fields()
        for (type, payload, value, transaction) in [("tuning.inspect.result", "tuningInspection", "inspection", "idle"),
            ("tuning.validate.result", "tuningValidation", "validation", "idle"),
            ("tuning.setting.observe.result", "tuningSettingObservation", "settingObservation", "transaction"),
            ("tuning.setting.result", "tuningSetting", "settingResult", "transaction")] {
            let valid: [String: Any] = ["type": type, "requestId": "reply", "sessionId": "owner", "queryId": "query", "transactionStatus": transaction, payload: try #require(fixture[value])]
            let reply = try NDJSONFramer.decode(JSONSerialization.data(withJSONObject: valid))
            #expect(reply.type == type)
            for key in valid.keys {
                var changed = valid; changed.removeValue(forKey: key)
                #expect(throws: (any Error).self) { _ = try NDJSONFramer.decode(JSONSerialization.data(withJSONObject: changed)) }
                changed = valid; changed[key] = NSNull()
                #expect(throws: (any Error).self) { _ = try NDJSONFramer.decode(JSONSerialization.data(withJSONObject: changed)) }
            }
            if payload == "tuningInspection" {
                var empty = valid
                var inspection = try #require(empty[payload] as? [String: Any])
                inspection["indexes"] = [Any](); inspection["variants"] = [Any](); empty[payload] = inspection
                #expect(try NDJSONFramer.decode(JSONSerialization.data(withJSONObject: empty)).tuningInspection?.indexes.isEmpty == true)
                inspection["indexes"] = NSNull(); empty[payload] = inspection
                #expect(throws: (any Error).self) { _ = try NDJSONFramer.decode(JSONSerialization.data(withJSONObject: empty)) }
            }
            var changed = valid; changed["unknown"] = true
            #expect(throws: (any Error).self) { _ = try NDJSONFramer.decode(JSONSerialization.data(withJSONObject: changed)) }
            changed = valid; changed["type"] = "query.result"
            #expect(throws: (any Error).self) { _ = try NDJSONFramer.decode(JSONSerialization.data(withJSONObject: changed)) }
        }
    }
    @Test func portableEvidenceAndCollectorConfigurationCannotRestoreAuthority() throws {
        let artifact = try TuningNativeFixture.artifact()
        let text = try artifact.encoded()
        #expect(artifact.request.context == nil && artifact.request.writeIntent == nil)
        #expect(!text.contains("sessionId") && !text.contains("authorization") && !text.contains("writeIntent"))
        let configuration = ExplainCollectorConfiguration()
        let data = try JSONEncoder().encode(configuration)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(fields.keys) == ["intervalSeconds", "maximumCaptures", "maximumRuntimeSeconds", "maximumStorageBytes", "retentionDays"])
        var injected = fields; injected["running"] = true
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(ExplainCollectorConfiguration.self, from: JSONSerialization.data(withJSONObject: injected)) }
        let stored = StoredSQLDocument(title: "Restored stopped", text: "SELECT 1", explainCollectorConfiguration: configuration)
        let restored = try JSONDecoder().decode(StoredSQLDocument.self, from: JSONEncoder().encode(stored))
        #expect(restored.explainCollectorConfiguration == configuration && restored.isValid)
    }
}
