import Foundation
import Testing
@testable import DBeer

struct TableStructureAuthoringContractTests {
    @Test func versionedAuthoringFixturePreservesLegacyAdmission() throws {
        struct Fixture: Decodable { var valid: [BackendCommand]; var invalid: [String]; var responses: [BackendMessage]; var invalidResponses: [String] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/table-structure-authoring-v2.json")))
        for command in fixture.valid {
            #expect(command.structure?.valid(for: command.type) == true)
            #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command)) == command)
        }
        for response in fixture.responses { try response.validate() }
        for raw in fixture.invalidResponses {
            var accepted = false
            do { let response = try JSONDecoder().decode(BackendMessage.self, from: Data(raw.utf8)); try response.validate(); accepted = true } catch {}
            #expect(!accepted)
        }
        for raw in fixture.invalid {
            var accepted = false
            do {
                let data = Data(raw.utf8)
                _ = try GPUIProductBuildIdentity.optionalFromFrame(data, maximumFrameBytes: BackendProtocol.maxFrameBytes)
                let command = try JSONDecoder().decode(BackendCommand.self, from: data)
                accepted = command.structure?.valid(for: command.type) == true
            } catch {}
            #expect(!accepted)
        }
    }
}
