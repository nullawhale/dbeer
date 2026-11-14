import Foundation
import Testing
@testable import DBeer

// Foundation/JSON only: this suite opens no application, windows or database.
struct TuningProtocolTests {
    private func fixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/tuning-v1/contract.json"))) as? [String: Any])
    }
    private func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: #require(fixture()[key])))
    }
    @Test func pairedRequestsRetainExactBindingsAndContext() throws {
        let fixture = try fixture()
        #expect(fixture["version"] as? Int == 1 && fixture["capability"] as? String == TuningInspectRequest.capability)
        let inspect = try decode(TuningInspectRequest.self, "inspectRequest")
        let validation = try decode(TuningValidationRequest.self, "validationRequest")
        let setting = try decode(TuningSettingRequest.self, "settingRequest")
        #expect(inspect.valid && validation.valid && setting.valid)
        #expect(validation.original.parameters?.first?.value == "9007199254740993")
        #expect(validation.original.parameters?.last?.value == nil)
        #expect(validation.original.context?.sessionId == "owner")
        #expect(validation.original.sql != validation.variant.sql)
        #expect(validation.original.parameters == validation.variant.parameters)
        #expect(validation.variant.context?.rangeLength == validation.variant.sql.utf16.count)
        var restored = validation
        restored.original = restored.original.portable
        restored.variant = restored.variant.portable
        #expect(!restored.valid)
        #expect(try JSONDecoder().decode(TuningValidationRequest.self, from: JSONEncoder().encode(validation)) == validation)
    }
    @Test func evidenceIsObservationAndRestorationNeedsReview() throws {
        let inspection = try decode(TuningInspection.self, "inspection")
        let validation = try decode(TuningValidation.self, "validation")
        let preview = try decode(TuningSettingPreview.self, "settingPreview")
        let setting = try decode(TuningSettingResult.self, "settingResult")
        #expect(inspection.evidenceOrigin == "suppliedCapture" && inspection.indexes.first?.edit.action == "add")
        #expect(inspection.variants.first?.validation == "unvalidated")
        #expect(validation.state == "observedEqual" && validation.scope == "sequentialCurrentSession" && validation.complete)
        #expect(preview.scope == "currentTransaction" && preview.restoreSQL == "SET LOCAL work_mem = '4096kB'")
        #expect(setting.restore.valueKiB == setting.beforeKiB && setting.restore.expectedValueKiB == setting.requestedKiB)
        var changed = setting.restore; changed.context.transactionStatus = "idle"; #expect(!changed.valid)
        changed = setting.restore; changed.name = "arbitrary_setting"; #expect(!changed.valid)
    }
    @Test func allNewContainersRejectUnknownMissingAndNullFields() throws {
        let object = try fixture()
        let decoders: [(String, (Data) throws -> Void)] = [
            ("inspectRequest", { _ = try JSONDecoder().decode(TuningInspectRequest.self, from: $0) }),
            ("validationRequest", { _ = try JSONDecoder().decode(TuningValidationRequest.self, from: $0) }),
            ("settingRequest", { _ = try JSONDecoder().decode(TuningSettingRequest.self, from: $0) }),
            ("inspection", { _ = try JSONDecoder().decode(TuningInspection.self, from: $0) }),
            ("validation", { _ = try JSONDecoder().decode(TuningValidation.self, from: $0) }),
            ("settingPreview", { _ = try JSONDecoder().decode(TuningSettingPreview.self, from: $0) }),
            ("settingResult", { _ = try JSONDecoder().decode(TuningSettingResult.self, from: $0) }),
            ("settingObservationRequest", { _ = try JSONDecoder().decode(TuningSettingObservationRequest.self, from: $0) }),
            ("settingObservation", { _ = try JSONDecoder().decode(TuningSettingObservation.self, from: $0) })
        ]
        func rejected(_ body: [String: Any], _ decode: (Data) throws -> Void, _ label: String) throws {
            let data = try JSONSerialization.data(withJSONObject: body)
            do { try decode(data); Issue.record("Accepted invalid tuning container: \(label)") } catch { }
        }
        for (key, decode) in decoders {
            let body = try #require(object[key] as? [String: Any])
            var unknown = body; unknown["unknown"] = true; try rejected(unknown, decode, key + " unknown")
            for field in body.keys {
                var missing = body; missing.removeValue(forKey: field)
                if field != "workMemKiB" { try rejected(missing, decode, key + " missing " + field) }
                var null = body; null[field] = NSNull(); try rejected(null, decode, key + " null " + field)
            }
        }
        let inspection = try #require(object["inspection"] as? [String: Any])
        for key in ["indexes", "variants"] {
            let entries = try #require(inspection[key] as? [[String: Any]])
            for entry in entries {
                let decode: (Data) throws -> Void = key == "indexes" ? { _ = try JSONDecoder().decode(TuningIndexAdvice.self, from: $0) } : { _ = try JSONDecoder().decode(TuningVariant.self, from: $0) }
                var unknown = entry; unknown["unknown"] = true; try rejected(unknown, decode, key + " unknown")
                for field in entry.keys {
                    var missing = entry; missing.removeValue(forKey: field); try rejected(missing, decode, key + " missing " + field)
                    var null = entry; null[field] = NSNull(); try rejected(null, decode, key + " null " + field)
                }
            }
        }
    }
}
