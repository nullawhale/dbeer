import Foundation
import Testing
@testable import DBeer

@Suite("Captured full export contract")
struct RunToFileContractTests {
    @Test func additiveFixturePreservesSQLAndPublicationDistinction() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/run-to-file-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let request = try JSONDecoder().decode(ExportRequest.self, from: JSONSerialization.data(withJSONObject: try #require(fixture["export"])))
        #expect(request.destination?.exists == true)
        #expect(request.destination?.sha256.count == 64)
        for key in ["progress", "sqlCompletedPublicationFailed", "sqlCompletedPublicationUnknown"] {
            let message = try JSONDecoder().decode(BackendMessage.self, from: JSONSerialization.data(withJSONObject: try #require(fixture[key])))
            try message.validate()
            if key != "progress" { #expect(message.sqlCompleted == true); #expect(message.outcomeUnknown == false) }
        }
        var invalid = try #require(fixture["sqlCompletedPublicationFailed"] as? [String: Any])
        invalid["outcomeUnknown"] = true
        let message = try JSONDecoder().decode(BackendMessage.self, from: JSONSerialization.data(withJSONObject: invalid))
        #expect(throws: BackendTransportError.self) { try message.validate() }
        invalid.removeValue(forKey: "sqlCompleted"); invalid.removeValue(forKey: "exportPublication"); invalid["outcomeUnknown"] = false
        let legacy = try JSONDecoder().decode(BackendMessage.self, from: JSONSerialization.data(withJSONObject: invalid))
        try legacy.validate(); #expect(legacy.sqlCompleted == nil)
    }
}
