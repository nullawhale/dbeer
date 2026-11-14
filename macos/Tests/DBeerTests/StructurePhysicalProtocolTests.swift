import Foundation
import Testing
@testable import DBeer

@Suite struct StructurePhysicalProtocolTests {
    private struct Command: Decodable {
        var type: String
        var structure: StructureRequest

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        private enum CodingKeys: String, CodingKey { case type, requestId, sessionId, queryId, structure, authorization }
        init(from decoder: any Decoder) throws {
            let all = try decoder.container(keyedBy: Key.self)
            let allowed: Set<String> = ["type", "requestId", "sessionId", "queryId", "structure", "authorization"]
            guard Set(all.allKeys.map(\.stringValue)).isSubset(of: allowed) else { throw BackendTransportError(.invalidMessage) }
            for key in all.allKeys { if try all.decodeNil(forKey: key) { throw BackendTransportError(.invalidMessage) } }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            structure = try c.decode(StructureRequest.self, forKey: .structure)
            for key in [CodingKeys.requestId, .sessionId, .queryId] {
                guard BackendMessage.validID(try c.decode(String.self, forKey: key)) else { throw BackendTransportError(.invalidMessage) }
            }
            if let authorization = try c.decodeIfPresent(String.self, forKey: .authorization) {
                guard type == "structure.physical.apply", BackendMessage.validID(authorization) else { throw BackendTransportError(.invalidMessage) }
            }
        }
    }
    private struct Reply: Decodable { var type: String; var structure: StructureReply }
    private struct Fixture: Decodable { var valid: [Command]; var invalid: [String]; var validReplies: [Reply]; var invalidReplies: [String]; var portable: StructurePhysicalDraft }
    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/table-structure-physical-v1.json")))
    }
    @Test func strictSharedIntentAndReplies() throws {
        let f = try fixture()
        for (index, command) in f.valid.enumerated() { #expect(command.structure.valid(for: command.type), "Valid physical command fixture \(index)") }
        for (index, raw) in f.invalid.enumerated() {
            var admitted = false
            if let command = try? JSONDecoder().decode(Command.self, from: Data(raw.utf8)) { admitted = command.structure.valid(for: command.type) }
            #expect(!admitted, "Invalid physical command fixture \(index) was admitted")
        }
        for (index, reply) in f.validReplies.enumerated() { #expect(reply.structure.valid(for: reply.type), "Valid physical reply fixture \(index)") }
        for (index, raw) in f.invalidReplies.enumerated() {
            if let reply = try? JSONDecoder().decode(Reply.self, from: Data(raw.utf8)) { #expect(!reply.structure.valid(for: reply.type), "Invalid physical reply fixture \(index) was admitted") }
        }
    }
    @Test func portableDraftExcludesEvidenceAndExecutionAuthority() throws {
        var draft = try fixture().portable
        #expect(draft.valid)
        let encoded = try JSONEncoder().encode(draft)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["version", "target", "intent"])
        for key in ["authorization", "planId", "digest", "fingerprint", "password", "connection"] { #expect(object[key] == nil) }
        draft.version = 2
        #expect(!draft.valid)
        let null = #"{"version":1,"target":{"schema":"app","table":"p","create":false},"intent":null}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(StructurePhysicalDraft.self, from: Data(null.utf8)) }
    }
    @Test func exactValueKindsAndIndependentVersion() throws {
        let empty = StructurePhysicalValue(kind: "text", value: "")
        let textNull = StructurePhysicalValue(kind: "text", value: "NULL")
        let sqlNull = StructurePhysicalValue(kind: "null")
        let exact = StructurePhysicalValue(kind: "integer", value: "90071992547409931234567890")
        let valuesAreValid = [empty, textNull, sqlNull, exact].allSatisfy(\.valid)
        #expect(valuesAreValid)
        #expect(empty != textNull && textNull != sqlNull)
        #expect(!StructurePhysicalValue(kind: "integer", value: "01").valid)
        var draft = try fixture().portable
        draft.target.table = "caf\u{00E9}"
        var decomposed = draft; decomposed.target.table = "cafe\u{0301}"
        #expect(draft != decomposed)
        let ordinary = StructureDraft(columns: [StructureColumn(name: "x", type: StructureDataType(kind: "integer"), nullable: true, default: StructureDefault(kind: "none"))])
        #expect(ordinary.valid && ordinary.authoringVersion == nil)
    }
}
