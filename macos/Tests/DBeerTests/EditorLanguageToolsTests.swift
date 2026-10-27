import Foundation
import Testing
@testable import DBeer

struct EditorPositionIndexTests {
    @Test func indexedRangesMatchNativeUTF16Positions() throws {
        let text = "🌍\r\nSELECT (\n1\n);\rSELECT 2;"
        let index = SQLEditorPositionIndex(text)
        for start in 0...text.utf16.count {
            for end in start...text.utf16.count {
                guard let a = SQLLSPPosition.position(offset: start, in: text),
                      let b = SQLLSPPosition.position(offset: end, in: text) else { continue }
                let value = SQLLSPJSON.object(["start": a, "end": b])
                #expect(index.range(value) == SQLLSPPosition.range(value, in: text))
            }
        }
        #expect(index.range(.object(["start": .object(["line": .int(0), "character": .int(1)]),
                                     "end": .object(["line": .int(0), "character": .int(2)])])) == nil)
    }
}

@MainActor
struct EditorLanguageToolsTests {
    private struct Fixture: Decodable {
        struct FormatCase: Decodable { let engine: String; let source: String; let expected: String }
        struct RejectedCase: Decodable { let engine: String; let source: String }
        let version: Int
        let formatCases: [FormatCase]
        let rejectedCases: [RejectedCase]
        struct ColumnTypeCase: Decodable {
            struct Relation: Decodable {
                let schema: String
                let name: String
                let kind: String
                let columns: [String]
                let columnTypes: [String: String]
            }
            let engine: String
            let source: String
            let caretText: String
            let expectedType: String
            let catalog: [Relation]
        }
        let columnTypeCases: [ColumnTypeCase]
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func sharedFourLanguageFixturesPassThroughRealBundledHelper() async throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            repository.appendingPathComponent("protocol/fixtures/editor-tools-v1.json")))
        #expect(fixture.version == 1)
        let executable = repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path))
        let service = SQLLanguageService(helperURL: executable)
        let id = UUID()
        func engine(_ name: String) -> DatabaseEngine {
            switch name { case "mysql": .mysql; case "cassandra": .cassandra; case "mongodb": .mongodb; default: .postgresql }
        }
        for value in fixture.formatCases {
            service.update(documentID: id, text: value.source, engine: engine(value.engine), context: .empty)
            let result = try #require(await service.format(documentID: id))
            #expect(result.error == nil)
            #expect(result.edits.count == 1)
            #expect(result.edits.first?.text == value.expected)
            service.update(documentID: id, text: value.expected, engine: engine(value.engine), context: .empty)
            let again = try #require(await service.format(documentID: id))
            #expect(again.error == nil)
            #expect(again.edits.isEmpty)
            let analysis = try #require(await service.editorAnalysis(documentID: id))
            #expect(!analysis.symbols.isEmpty)
        }
        for value in fixture.rejectedCases {
            service.update(documentID: id, text: value.source, engine: engine(value.engine), context: .empty)
            let result = try #require(await service.format(documentID: id))
            #expect(result.error != nil)
            #expect(result.edits.isEmpty)
        }
        service.close(documentID: id)
        #expect(await service.format(documentID: id) == nil)
        await service.shutdown()
    }

    @Test func aliasesAndCatalogDefinitionsKeepOriginalRanges() async throws {
        let service = SQLLanguageService(helperURL: repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core"))
        let id = UUID()
        let text = "SELECT '🌍';\r\nSELECT u.id FROM users u;"
        let context = SQLCompletionContext(profileID: UUID(), catalog: [
            SQLCompletionRelation(schema: "public", name: "users", kind: "table", columns: ["id"])
        ])
        service.update(documentID: id, text: text, engine: .postgresql, context: context)
        let caret = (text as NSString).range(of: "u.id").location
        let analysis = try #require(await service.editorAnalysis(documentID: id, offset: caret))
        #expect(analysis.references.count == 2)
        #expect(analysis.references.first == NSRange(location: caret, length: 1))
        #expect(analysis.definitions.count == 1)
        #expect(analysis.definitions.first?.detail?.contains("public.users") == true)
        #expect(analysis.definitions.first?.range == NSRange(location: (text as NSString).range(of: "u;").location, length: 1))
        await service.shutdown()
    }
    @Test func loadedNativeTypesReachEditorInformationForEveryLanguage() async throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            repository.appendingPathComponent("protocol/fixtures/editor-tools-v1.json")))
        #expect(fixture.columnTypeCases.count == 4)
        let service = SQLLanguageService(helperURL: repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core"))
        let id = UUID(), profile = UUID()
        for value in fixture.columnTypeCases {
            var catalog = SQLCompletionCatalog()
            let records = try value.catalog.map { relation in
                ["schema": relation.schema, "name": relation.name, "kind": relation.kind,
                 "columns": String(decoding: try JSONEncoder().encode(relation.columns), as: UTF8.self),
                 "columnTypes": String(decoding: try JSONEncoder().encode(relation.columnTypes), as: UTF8.self)]
            }
            catalog.record(records, request: CatalogRequest(kind: "completion"), profileID: profile)
            let context = catalog.context(profileID: profile)
            let relation = try #require(context.catalog.first)
            #expect(relation.columnTypes[value.caretText] == value.expectedType)
            let payload = try #require(SQLLanguageService.boundedCatalog(context.catalog).first)
            #expect(payload["columnTypes"]?[value.caretText]?.string == value.expectedType)
            let engine: DatabaseEngine = switch value.engine {
            case "mysql": .mysql
            case "cassandra": .cassandra
            case "mongodb": .mongodb
            default: .postgresql
            }
            service.update(documentID: id, text: value.source, engine: engine, context: context)
            let caret = (value.source as NSString).range(of: value.caretText).location + 1
            let result = try #require(await service.editorAnalysis(documentID: id, offset: caret))
            #expect(result.definitions.count == 1)
            #expect(result.definitions.first?.detail?.contains(value.expectedType) == true)
            if engine == .mongodb { #expect(result.definitions.first?.detail?.contains("Samples are not a schema") == true) }
        }
        await service.shutdown()
    }

}
