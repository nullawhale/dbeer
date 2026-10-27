import Foundation
import Testing
@testable import DBeer

/// Native consumer of the exact same synthetic PostgreSQL type wire fixture as
/// Go. Decode/round-trip only; no process, UI, or database is involved.
struct PostgresTypeContractFixturesTests {
    private struct Fixture: Decodable {
        let version: Int
        let commands: [BackendCommand]
        let responses: [BackendMessage]
    }
    private func fixture() throws -> Fixture {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: repository.appendingPathComponent("protocol/fixtures/types-v5.json")))
    }

    @Test func allOperationVariantsRoundTripWithEmptyLabelPresence() throws {
        let data = try fixture()
        #expect(data.version == BackendProtocol.version)
        for command in data.commands {
            #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command)) == command)
        }
        let add = try #require(data.commands.first { $0.requestId == "types-add-empty" }?.catalog)
        #expect(add.identity == "16384" && add.typeChange?.operation == "addEnumValue")
        #expect(add.typeChange?.value == "" && add.typeChange?.oldValue == nil && add.typeChange?.newName == nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(add)) as? [String: Any])
        let fields = try #require(encoded["typeChange"] as? [String: Any])
        #expect(fields["value"] as? String == "" && fields["oldValue"] == nil && fields["newName"] == nil)
        let rename = try #require(data.commands.first { $0.requestId == "types-rename-value" }?.catalog?.typeChange)
        #expect(rename.operation == "renameEnumValue" && rename.oldValue == "" && rename.value == "quote'\\Ω")
        let typeRename = try #require(data.commands.first { $0.requestId == "types-rename" }?.catalog?.typeChange)
        #expect(typeRename.newName == "renamed \"猫" && typeRename.oldValue == nil && typeRename.value == nil)
    }

    @Test func fixedShapesPreserveServerOrderIncompleteZeroRowsAndDependencySubobjects() throws {
        let data = try fixture()
        for response in data.responses { try response.validate() }
        func reply(_ id: String) throws -> BackendMessage { try #require(data.responses.first { $0.requestId == id }) }
        let command = try #require(data.commands.first { $0.requestId == "types-details" })
        let request = try #require(command.catalog)
        let reference = PostgresTypeReference(profileID: UUID(), serviceSessionID: "types-session", serviceGeneration: UUID(),
            engine: .postgresql, database: "fixture", schema: try #require(request.schema), name: try #require(request.object),
            objectKind: "enum", localOID: "16384", settingsRevision: UUID(), policy: ExecutionPolicy(readOnly: true))
        let objects = try PostgresTypeCatalog.decodeObjects(reply("types-enums"))
        #expect(objects.first?.typeKind == "enum" && objects.first?.identity == reference.localOID)
        let details = try PostgresTypeCatalog.decodeDetails(reply("types-details"), reference: reference)
        #expect(details.definitionStatus == .complete && details.renameSupported && details.addEnumValueSupported)
        let values = try PostgresTypeCatalog.decodeEnumValues(reply("types-values"))
        #expect(values.map(\.label) == ["z", "", "a"] && values[1].sortOrder == "1.5")
        let empty = try reply("types-values-empty")
        let partial = try reply("types-values-partial")
        #expect(try PostgresTypeCatalog.decodeEnumValues(empty).isEmpty && empty.truncated == false)
        #expect(try PostgresTypeCatalog.decodeEnumValues(partial).isEmpty && partial.truncated == true && partial.rowCount == 1001)
        let dependencies = try PostgresTypeCatalog.decodeDependencies(reply("types-dependencies"))
        #expect(dependencies[0].objectSubID == "2" && dependencies[0].objectName == nil)
        #expect(dependencies[1].direction == "outgoing" && dependencies[1].objectSchema == nil)
        #expect(try PostgresTypeCatalog.decodeDependencies(reply("types-dependencies-empty")).isEmpty)
        let add = TypeChange(operation: "addEnumValue", value: "")
        let previewReply = try reply("types-add-empty")
        let preview = try PostgresTypeCatalog.decodePreview(previewReply, change: add)
        #expect(preview.sql.hasSuffix("ADD VALUE E'';") && previewReply.sql == nil)
        #expect(preview.warnings?.contains("not OID-bound") == true)
    }
}
