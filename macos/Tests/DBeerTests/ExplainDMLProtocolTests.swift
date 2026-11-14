import Foundation
import Testing
@testable import DBeer

struct ExplainDMLProtocolTests {
    private func fixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/explain-dml-v1/contract.json"))) as? [String: Any])
    }
    @Test func sharedContractRetainsExactValuesAndOutcomeFacts() throws {
        let fixture = try fixture()
        #expect(fixture["version"] as? Int == 1 && fixture["capability"] as? String == "explainDMLV1")
        for raw in try #require(fixture["commands"] as? [[String: Any]]) {
            let command = try JSONDecoder().decode(BackendCommand.self, from: JSONSerialization.data(withJSONObject: raw))
            let request = try #require(command.explain)
            #expect(request.valid)
            #expect(try JSONDecoder().decode(ExplainRequest.self, from: JSONEncoder().encode(request)) == request)
            if request.mode == .analyze {
                #expect(request.parameters?.first?.value == "NULL 🍺")
                #expect(request.parameters?[1].value == "9007199254740993")
                #expect(request.parameters?[2].value == "")
                #expect(request.parameters?[3].value == nil)
                #expect(request.parameters?[4].value == "9007199254740993.125")
                #expect(request.portable.context == nil && request.portable.writeIntent == nil)
                #expect(request.portable.parameters == request.parameters)
            }
        }
        for raw in try #require(fixture["outcomes"] as? [[String: Any]]) {
            let result = try JSONDecoder().decode(ExplainDMLResult.self, from: JSONSerialization.data(withJSONObject: raw))
            #expect(result.valid(engine: .postgresql, mode: result.execution == "estimated" ? .plan : .analyze))
            #expect(try JSONDecoder().decode(ExplainDMLResult.self, from: JSONEncoder().encode(result)) == result)
        }
        for raw in try #require(fixture["mysqlOutcomes"] as? [[String: Any]]) {
            let result = try JSONDecoder().decode(ExplainDMLResult.self, from: JSONSerialization.data(withJSONObject: raw))
            #expect(result.valid(engine: .mysql, mode: .analyze))
            #expect(result.execution == "completed" && result.targetExecution == "suppressed" && result.persistence == "notExecuted")
        }
        for raw in try #require(fixture["supports"] as? [[String: Any]]) {
            let support = try JSONDecoder().decode(ExplainDMLSupport.self, from: JSONSerialization.data(withJSONObject: #require(raw["dml"])))
            let engineName = try #require(raw["engine"] as? String)
            let engine = try #require(DatabaseEngine(rawValue: engineName))
            #expect(support.valid(engine: engine))
        }
    }
    @Test func authorityRejectsNullUnknownFieldsAndStaleConditions() throws {
        let fixture = try fixture()
        for item in try #require(fixture["invalidCommands"] as? [[String: Any]]) {
            let raw = try JSONSerialization.data(withJSONObject: #require(item["command"]))
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(BackendCommand.self, from: raw) }
        }
        for raw in [#"{"statement":"insert","dataModifyingCTE":false,"mysqlMultiTable":false,"extra":null}"#,
                    #"{"statement":"insert","dataModifyingCTE":null,"mysqlMultiTable":false}"#] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ExplainDMLTarget.self, from: Data(raw.utf8)) }
        }
        for raw in [#"{"estimated":true,"analyze":["insert"]}"#,
                    #"{"estimated":true,"analyze":["insert"],"analyzeTargetExecution":null}"#] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ExplainDMLSupport.self, from: Data(raw.utf8)) }
        }
        var suppressed = try #require((fixture["mysqlOutcomes"] as? [[String: Any]])?.first)
        suppressed.removeValue(forKey: "targetExecution")
        let missingTarget = try JSONSerialization.data(withJSONObject: suppressed)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ExplainDMLResult.self, from: missingTarget) }
        suppressed["targetExecution"] = NSNull()
        let nullTarget = try JSONSerialization.data(withJSONObject: suppressed)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ExplainDMLResult.self, from: nullTarget) }
        #expect(!ExplainDMLSupport(analyze: ["insert"], analyzeTargetExecution: "executes").valid(engine: .mysql))
        #expect(!ExplainDMLTarget(statement: "select").valid(engine: .postgresql))
        #expect(!ExplainDMLTarget(statement: "select", dataModifyingCTE: true).valid(engine: .sqlite))
        #expect(!ExplainDMLTarget(statement: "insert", mysqlMultiTable: true).valid(engine: .mysql))
        let pending = ExplainDMLResult(target: .init(statement: "update"), execution: "completed", persistence: "committed", transactionBefore: "idle", transactionAfter: "transaction", affectedRowsUnavailableReason: "notReported", targetExecution: "executed")
        #expect(!pending.valid(engine: .postgresql, mode: .analyze))
    }
}
