import Foundation
import Testing
@testable import DBeer

@MainActor
struct NativeFilterRequestTests {
    private struct Fixture: Decodable {
        struct Budget: Decodable { let representation: String; let copies: Int; let payloadBytes: Int; let escaped: Bool; let valid: Bool }
        let validCatalogJSON: [String]
        let invalidCatalogJSON: [String]
        let aggregateBudgets: [Budget]
    }
    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/native-cell-filter-v1.json")))
    }
    @Test func wholeNativeCatalogRejectsMalformedIdentifierEscapesWithoutReplacingThem() throws {
        let fixture = try fixture()
        for raw in fixture.invalidCatalogJSON {
            #expect(throws: (any Error).self) {
                let bytes = Data(raw.utf8)
                try ExactJSONKeys.validate(bytes, maximumBytes: BackendProtocol.maxFrameBytes)
                _ = try JSONDecoder().decode(CatalogRequest.self, from: bytes)
            }
        }
        for raw in fixture.validCatalogJSON {
            let bytes = Data(raw.utf8)
            try ExactJSONKeys.validate(bytes, maximumBytes: BackendProtocol.maxFrameBytes)
            let request = try JSONDecoder().decode(CatalogRequest.self, from: bytes)
            let roundTrip = try JSONDecoder().decode(CatalogRequest.self, from: JSONEncoder().encode(request))
            #expect(request.filters?.first?.nativeValue != nil)
            #expect(Data((request.filters?.first?.column ?? "").utf8) == Data((roundTrip.filters?.first?.column ?? "").utf8))
        }
    }
    @Test func legacyListsAndExpressionTreesShareWholeNativeOperandBudget() throws {
        for budget in try fixture().aggregateBudgets {
            let value = String(repeating: budget.escaped ? "\0" : "x", count: budget.payloadBytes)
            let filter = CatalogFilter(column: "v", operator: "eq", nativeValue: .init(cell: .init(kind: "text", value: value),
                sourceEngine: .postgresql, sourceType: "text", sqliteStorage: "text"))
            let filters = Array(repeating: filter, count: budget.copies)
            let expression = CatalogFilterExpression.group("and", filters.map(CatalogFilterExpression.predicate))
            let request = CatalogRequest(kind: "browse", schema: "main", object: "typed", objectKind: "table",
                filters: budget.representation == "filters" ? filters : nil,
                filterExpression: budget.representation == "filterExpression" ? expression : nil)
            let encoded = try JSONEncoder().encode(request)
            let accepted = (try? JSONDecoder().decode(CatalogRequest.self, from: encoded)) != nil
            #expect(accepted == budget.valid)
            #expect(expression.isValid == budget.valid)
        }
    }
    @Test func nativeResultFramingRejectsLoneSurrogatesAndPreservesValidScalarIdentities() throws {
        func frame(_ name: String) -> Data {
            Data((#"{"type":"query.result","requestId":"r","sessionId":"s","queryId":"q","transactionStatus":"idle","durationMs":0,"columns":[{"index":0,"name":"# + name + #", "engine":"postgresql","nativeType":"text"}],"rows":[],"rowCount":0,"displayedRowCount":0,"commandTag":"SELECT","truncated":false}"#).utf8)
        }
        for name in [#""\ud800""#, #""\udc00""#, #""prefix\ud800tail""#] {
            #expect(throws: BackendTransportError.self) { _ = try NDJSONFramer.decode(frame(name)) }
        }
        for (raw, expected) in [(#""\ud83d\ude00""#, "😀"), (#""\\ud800""#, #"\ud800"#), (#""�""#, "�"), (#""e\u0301""#, "e\u{0301}")] {
            let result = try NDJSONFramer.decode(frame(raw))
            let column = try #require(result.columns?.first)
            #expect(Data(column.name.utf8) == Data(expected.utf8))
        }
    }
}
