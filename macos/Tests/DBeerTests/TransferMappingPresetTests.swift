import Foundation
import Testing
@testable import DBeer

@MainActor
struct TransferMappingPresetTests {
    private func preset() -> TransferMappingPreset {
        .init(name: "Weekly import", engine: .postgresql, purpose: "append", headers: ["id", "note"],
            columns: [.init(sourceIndex: 0, targetName: "id"), .init(sourceIndex: 1, targetName: "description")],
            fileOptions: .init(.init(delimiter: .tab, hasHeader: true, nullMarker: "\\N", emptyFieldsAreNull: false)))
    }
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-mapping-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("library.json")
    }
    @Test func mappingLibraryRoundtripsSettingsWithoutSourceData() async throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = TransferMappingPresetStore(url: url)
        await store.load()
        let mapping = preset()
        try await store.save(mapping)
        let restored = TransferMappingPresetStore(url: url)
        await restored.load()
        #expect(restored.loaded && restored.presets == [mapping])
        #expect(restored.presets[0].fileOptions.options?.delimiter == .tab)
        let data = try Data(contentsOf: url)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let item = try #require((object["presets"] as? [[String: Any]])?.first)
        #expect(Set(item.keys) == ["id", "name", "engine", "purpose", "headers", "columns", "fileOptions"])
        try await restored.delete(mapping.id)
        #expect(restored.presets.isEmpty)
    }
    @Test func malformedFutureAndConcurrentLibrariesArePreserved() async throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = TransferMappingPresetStore(url: url), second = TransferMappingPresetStore(url: url)
        await first.load(); await second.load()
        try await first.save(preset())
        let saved = try Data(contentsOf: url)
        await #expect(throws: TransferPresetError.self) { try await second.save(preset()) }
        #expect(try Data(contentsOf: url) == saved)
        let future = Data("{\"version\":999,\"presets\":[]}".utf8)
        try future.write(to: url)
        await first.load()
        #expect(!first.loaded && first.error != nil)
        await #expect(throws: TransferPresetError.self) { try await first.save(preset()) }
        #expect(try Data(contentsOf: url) == future)
    }
    @Test func templateMatchingUsesExactHeadersAndUniqueSourcePositions() {
        var mapping = preset()
        mapping.headers = ["caf\u{00e9}", "id"]
        #expect(mapping.valid)
        #expect(!mapping.matches(headers: ["cafe\u{0301}", "id"], engine: .postgresql, purpose: "append"))
        #expect(!mapping.matches(headers: mapping.headers, engine: .mysql, purpose: "append"))
        mapping.columns[1].sourceIndex = 0
        #expect(!mapping.valid)
    }
}
