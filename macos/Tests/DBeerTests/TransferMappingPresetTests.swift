import Darwin
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

    @Test func invalidOrEmptyMappingsCannotEnterTheLibrary() {
        var mapping = preset()
        mapping.columns = [.init(sourceIndex: 0), .init(sourceIndex: 1)]
        #expect(!mapping.valid)
        mapping.columns[0].targetName = "id"
        mapping.columns[0].type = "integer"
        #expect(!mapping.valid)
        mapping.purpose = "create"
        mapping.columns[0].nullable = false
        #expect(mapping.valid)
        mapping.columns[1].precision = 10
        #expect(!mapping.valid)
    }

    @Test func unknownMetadataAtEveryLevelLeavesTheLibraryUnchanged() async throws {
        let url = try location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = TransferMappingPresetStore(url: url)
        await store.load(); try await store.save(preset())
        let original = try Data(contentsOf: url)
        for level in ["root", "preset", "column", "options"] {
            var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var items = try #require(object["presets"] as? [[String: Any]])
            switch level {
            case "root": object["futureSetting"] = true
            case "preset": items[0]["futureSetting"] = true
            case "column":
                var columns = try #require(items[0]["columns"] as? [[String: Any]])
                columns[0]["futureSetting"] = true; items[0]["columns"] = columns
            default:
                var options = try #require(items[0]["fileOptions"] as? [String: Any])
                options["futureSetting"] = true; items[0]["fileOptions"] = options
            }
            object["presets"] = items
            let future = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try future.write(to: url)
            await store.load()
            #expect(!store.loaded)
            await #expect(throws: TransferPresetError.self) { try await store.save(preset()) }
            #expect(try Data(contentsOf: url) == future)
        }
    }

    @Test func symbolicLinkReplacementCannotOverwriteAnotherFile() async throws {
        let url = try location(), other = url.deletingLastPathComponent().appendingPathComponent("unrelated.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = TransferMappingPresetStore(url: url)
        await store.load(); try await store.save(preset())
        var metadata = stat()
        #expect(lstat(url.path, &metadata) == 0 && metadata.st_mode & 0o777 == 0o600)
        let original = try Data(contentsOf: url)
        try original.write(to: other)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
        await #expect(throws: TransferPresetError.self) { try await store.delete(store.presets[0].id) }
        #expect(try Data(contentsOf: other) == original)
        await store.load()
        #expect(!store.loaded)
    }
}
