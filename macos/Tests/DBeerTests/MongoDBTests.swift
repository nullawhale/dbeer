import Foundation
import Testing
@testable import DBeer

/// Pure protocol/model and helper-language coverage; no windows or desktop use.
struct MongoDBTests {
    @Test func settingsAndPortableProfilesPreserveTopologyWithoutSecrets() throws {
        let settings = ConnectionSettings(host: "localhost", port: 27017, database: "", user: "", password: "", sslMode: "verify-full",
            engine: .mongodb, mongodb: MongoDBSettings(authSource: "admin", replicaSet: "rs0"))
        #expect(settings.hasValidNativeFields)
        #expect(try JSONDecoder().decode(ConnectionSettings.self, from: JSONEncoder().encode(settings)) == settings)
        let saved = SavedConnection(name: "Documents", settings: settings)
        #expect(saved.settings(password: "").mongodb == settings.mongodb)
        let data = try ProfileTransfer.encode([saved])
        let imported = try #require(ProfileTransfer.preview(data).first?.profile)
        #expect(imported.mongodb == settings.mongodb && imported.id != saved.id)
        #expect(imported.settings(password: "").hasValidNativeFields)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let profiles = try #require(object["profiles"] as? [[String: Any]])
        #expect(profiles[0]["password"] == nil && profiles[0]["passwordCommand"] == nil)
    }

    @Test func validationRejectsUnverifiedTLSAndUnsafeTopology() {
        var settings = ConnectionSettings(host: "localhost", port: 27017, database: "", user: "", password: "", sslMode: "require", engine: .mongodb)
        #expect(!settings.hasValidNativeFields)
        settings.sslMode = "disable"
        #expect(settings.hasValidNativeFields)
        settings.host = "mongodb://user:secret@host"
        #expect(!settings.hasValidNativeFields)
        #expect(DatabaseEngine.mongodb.defaultPort == 27017)
        #expect(DatabaseEngine.availableCases.contains(.mongodb))
        #expect(SQLScriptParser.keywords(for: .mongodb).isEmpty)
    }

    @Test func JSONScriptsPreserveSemicolonsAndLiteralSQLWords() {
        let text = #"{"collection":"items","find":{"name":"a;b; SELECT 1;","n":{"$numberLong":"9007199254740993"}}}"#
        let parsed = SQLScriptParser.parse(text, engine: .mongodb)
        #expect(parsed.statements.count == 1 && parsed.statements[0].sql == text)
        #expect(parsed.diagnostics.isEmpty && !parsed.tokens.isEmpty)
        #expect(parsed.statement(atUTF16: 50)?.sql == text)
    }

    @Test func BSONFixtureRemainsLosslessInNativeInspector() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/mongodb-bson-v1.json"))
        let text = try #require(String(data: data, encoding: .utf8))
        let value = InspectedValue(row: 0, column: 0, name: "document", nativeType: "BSON document", value: ChangeValue(kind: "text", value: text))
        let content = try ValueInspectorProcessing.prepare(value)
        let formatted = try #require(content.formatted)
        #expect(formatted.contains("9007199254740993") && formatted.contains("12345678901234567890.12345678901234"))
        #expect(formatted.contains("$numberDecimal") && formatted.contains("$binary") && formatted.contains("$timestamp"))
        #expect(value.description == "BSON · Canonical Extended JSON")
        #expect(value.text == text)
    }

    @MainActor @Test func connectionDraftRestoresMongoDBAuthenticationAndSeedHosts() throws {
        var draft = ConnectionDraft(connection: nil)
        draft.selectEngine(.mongodb)
        draft.name = "Documents"
        draft.host = "one.example, two.example"
        draft.mongoAuthSource = "accounts"
        draft.mongoReplicaSet = "rs0"
        let settings = try #require(draft.settings)
        #expect(settings.port == 27017 && settings.contactPoints == ["one.example", "two.example"])
        #expect(settings.mongodb?.authSource == "accounts" && settings.mongodb?.replicaSet == "rs0")
        let saved = SavedConnection(name: "Documents", settings: settings)
        #expect(ConnectionDraft(connection: saved).settings == settings)
    }

    @MainActor @Test func helperLSPCompletesJSONAndBSONTypes() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let service = SQLLanguageService(helperURL: repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core"))
        let id = UUID()
        let text = #"{"collection":"orders","find":{"price":{"$numberDec"#
        service.update(documentID: id, text: text, engine: .mongodb, context: .empty)
        let items = await service.completion(documentID: id, offset: text.utf16.count)
        #expect(items.contains { $0.label == "$numberDecimal" && $0.replacement.contains("0.00") })
        #expect(!items.contains { $0.label == "SELECT" })
        await service.shutdown()
    }
}
