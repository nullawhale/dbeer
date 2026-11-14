import Foundation
import Testing
@testable import DBeer

@Suite struct TableStructureMigrationProtocolTests {
    private struct Fixture: Decodable { var valid: [Command]; var invalid: [String]; var portable: StructureMigrationDraft; var validReplies: [Reply]; var invalidReplies: [String] }
    private struct Reply: Decodable { var type: String; var structure: StructureReply }
    private struct Command: Decodable { var type: String; var structure: StructureRequest }
    @Test func strictSharedContractAndPortableIntent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/table-structure-migrations-v1.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        #expect(fixture.valid.count == 6)
        for command in fixture.valid { #expect(command.structure.migration?.valid(for: command.type) == true) }
        for raw in fixture.invalid {
            let data = Data(raw.utf8)
            var accepted = false
            do {
                _ = try GPUIProductBuildIdentity.optionalFromFrame(data, maximumFrameBytes: BackendProtocol.maxFrameBytes)
                let command = try JSONDecoder().decode(Command.self, from: data)
                accepted = command.structure.migration?.valid(for: command.type) == true
            } catch {}
            #expect(!accepted)
        }
        #expect(fixture.portable.valid)
        var byteExact = fixture.portable
        byteExact.objects[0].target.table = "caf\u{00E9}"
        var decomposed = byteExact.objects[0]
        decomposed.id = "separate"
        decomposed.target.table = "cafe\u{0301}"
        byteExact.objects.append(decomposed)
        #expect(byteExact.valid)

        let encoded = try JSONEncoder().encode(fixture.portable)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["version", "objects", "repairs"])
        for key in ["authorization", "planId", "fingerprint", "password", "connection"] { #expect(object[key] == nil) }
    }
    @Test func sharedRepliesBindExpectedStructuresAndRetainedEvidence() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/table-structure-migrations-v1.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        #expect(fixture.validReplies.count == 6)
        for reply in fixture.validReplies { #expect(reply.structure.valid(for: reply.type)) }
        for raw in fixture.invalidReplies {
            if let reply = try? JSONDecoder().decode(Reply.self, from: Data(raw.utf8)) {
                #expect(!reply.structure.valid(for: reply.type))
            }
        }
    }
    @Test func absentStepConsequencesRemainOptionalAndExplicitNullIsRejected() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/table-structure-migrations-v1.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let original = try #require(fixture.validReplies.first { $0.type == "structure.migration.preview.result" }?.structure.migration?.plan)
        var plan = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var steps = try #require(plan["steps"] as? [[String: Any]])
        steps[0].removeValue(forKey: "consequences"); plan["steps"] = steps
        let omitted = try JSONDecoder().decode(StructureMigrationPlan.self, from: JSONSerialization.data(withJSONObject: plan))
        #expect(omitted.valid && omitted.steps[0].consequences == nil)
        steps[0]["consequences"] = NSNull(); plan["steps"] = steps
        let explicitNull = try JSONSerialization.data(withJSONObject: plan)
        #expect(steps[0]["consequences"] is NSNull)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(StructureMigrationPlan.self, from: explicitNull) }
    }
    @Test func rejectsUnknownNullAndExecutionAuthority() throws {
        for raw in [#"{"version":1,"objects":[],"repairs":[],"authorization":"grant"}"#, #"{"version":1,"objects":[],"repairs":null}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(StructureMigrationDraft.self, from: Data(raw.utf8)) }
        }
        let hidden = #"{"migration":{"apply":{"planId":"p","digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","executionId":"e"},"sql":"hidden"}}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(StructureRequest.self, from: Data(hidden.utf8)) }
    }
}
