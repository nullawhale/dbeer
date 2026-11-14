import Foundation
import Testing
@testable import DBeer

struct NativeValueTests {
    @Test func sharedNativeValuesPreserveKindsOrderAndDuplicates() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/native-result-values-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fixture["capability"] as? String == NativeValue.capability)
        #expect(fixture["format"] as? String == NativeValue.format)
        for raw in try #require(fixture["valid"] as? [[String: Any]]) {
            let encoded = try JSONSerialization.data(withJSONObject: raw)
            try ExactJSONKeys.validate(encoded, maximumBytes: NativeValue.maximumBytes)
            let value = try JSONDecoder().decode(NativeValue.self, from: encoded)
            let decoded = try JSONDecoder().decode(NativeValue.self, from: JSONEncoder().encode(value))
            #expect(value.valid && value == decoded)
        }
        for raw in try #require(fixture["invalid"] as? [[String: Any]]) {
            let encoded = try JSONSerialization.data(withJSONObject: raw)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(NativeValue.self, from: encoded) }
        }
        for raw in try #require(fixture["invalidJSON"] as? [String]) {
            #expect(throws: (any Error).self) {
                let encoded = Data(raw.utf8)
                try ExactJSONKeys.validate(encoded, maximumBytes: NativeValue.maximumBytes)
                _ = try JSONDecoder().decode(NativeValue.self, from: encoded)
            }
        }
        #expect(NativeValue(kind: "text", value: "é") != NativeValue(kind: "text", value: "e\u{0301}"))
    }

    @Test func matrixAndRecursiveBoundsAreAggregateAndEscapingAware() {
        var value = NativeValue(kind: "null")
        for _ in 0..<NativeValue.maximumDepth { value = .init(kind: "list", items: [value]) }
        #expect(value.valid)
        #expect(!NativeValue(kind: "list", items: [value]).valid)
        #expect(!NativeValue(kind: "text", value: String(repeating: "<", count: NativeValue.maximumBytes / 6)).valid)
        let row = [NativeValue(kind: "text", value: String(repeating: "x", count: NativeValue.maximumBytes / 3))]
        #expect(NativeValue.validMatrix([row, row], rows: 2, columns: 1))
        #expect(!NativeValue.validMatrix([row, row, row], rows: 3, columns: 1))
        #expect(!NativeValue.validMatrix([[.init(kind: "null")]], rows: 1, columns: 2))
        #expect(NativeValue(kind: "float32", value: "80000000").valid)
        #expect(NativeValue(kind: "float64", value: "7ff8000000000001").valid)
    }
    @Test func maximumNativeObjectDepthSurvivesOriginalFrameValidation() throws {
        var value = NativeValue(kind: "null")
        for _ in 0..<NativeValue.maximumDepth {
            value = .init(kind: "object", entries: [.init(key: .init(kind: "text", value: "key"), value: value)])
        }
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        let object: [String: Any] = ["type": "query.result", "requestId": "r", "sessionId": "s", "queryId": "q",
            "transactionStatus": "idle", "durationMs": 0, "columns": [["index": 0, "name": "v", "engine": "mongodb", "nativeType": "bson"]],
            "rows": [[NSNull()]], "nativeValues": [[payload]], "rowCount": 1, "displayedRowCount": 1, "commandTag": "SELECT", "truncated": false]
        let result = try NDJSONFramer.decode(JSONSerialization.data(withJSONObject: object))
        #expect(result.nativeValues == [[value]])
    }

}
