import Foundation
import Testing
@testable import DBeer

/// Exercises the bundled language helper and metadata boundary without AppKit
/// views, database connections, or desktop interaction.
@MainActor
struct CQLLanguageServiceTests {
    private struct Fixture: Decodable {
        struct Signature: Decodable {
            let text: String; let parameter: String; let returnType: String; let offsetUTF16: Int?
        }
        let version: Int
        let keyspace: String
        let catalogRecords: [[String: String]]
        let signatures: [Signature]
    }

    @Test func sharedCQLMetadataReachesBundledLanguageServer() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            repository.appendingPathComponent("protocol/fixtures/cql-language-v1.json")))
        #expect(fixture.version == 1)
        let profileID = UUID(), documentID = UUID()
        var catalog = SQLCompletionCatalog()
        catalog.record(fixture.catalogRecords, request: CatalogRequest(kind: "completion"), profileID: profileID)
        var context = catalog.context(profileID: profileID)
        context.keyspace = fixture.keyspace
        #expect(context.catalog.count == fixture.catalogRecords.count)
        #expect(context.catalog.first { $0.name == "events" }?.partitionKeys == ["tenant"])
        #expect(context.catalog.first { $0.schema == "demo" && $0.name == "combine" }?.signatures.count == 2)
        let language = SQLLanguageService(helperURL:
            repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core"))
        for check in fixture.signatures {
            language.update(documentID: documentID, text: check.text, engine: .cassandra, context: context)
            let help = try #require(await language.signatureHelp(documentID: documentID,
                offset: check.offsetUTF16 ?? check.text.utf16.count))
            let signature = help.signatures[help.activeSignature]
            let range = try #require(signature.activeParameterRange)
            #expect((signature.label as NSString).substring(with: range) == check.parameter)
            #expect(signature.label.hasSuffix(" → " + check.returnType))
        }
        language.close(documentID: documentID)
        await language.shutdown()
    }
}
