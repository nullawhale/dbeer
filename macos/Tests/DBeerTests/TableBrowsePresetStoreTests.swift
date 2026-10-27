import Darwin
import Foundation
import Testing
@testable import DBeer

/// Private local-file tests only. No windows, helper, or database connections.
@MainActor
struct TableBrowsePresetStoreTests {
    private let table = TableReference(schema: "public", name: "orders", kind: "table")
    private func directory() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/table-browse/presets/\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func configuration() -> TableBrowseConfiguration {
        TableBrowseConfiguration(filterExpression: .group("or", [
            .predicate(CatalogFilter(column: "amount", operator: "gte", value: "9007199254740993.00001")),
            .group("and", [.predicate(CatalogFilter(column: "label", operator: "eq", value: "")),
                .predicate(CatalogFilter(column: "other", operator: "isNull", value: nil))])
        ]), sort: [CatalogSort(column: "amount", direction: "desc"), CatalogSort(column: "id", direction: "asc")])
    }

    @Test func namesScopesCRUDAndExactValuesRoundTripPrivately() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("views/library.json")
        let profileID = UUID(), otherProfile = UUID()
        let store = TableBrowsePresetStore(fileURL: url)
        #expect(!store.isLoaded && !FileManager.default.fileExists(atPath: url.path))
        await store.load()
        let original = try await store.saveNew(name: "  Exact values  ", profileID: profileID, table: table, configuration: configuration())
        #expect(original.name == "Exact values")
        let another = try await store.saveNew(name: "Exact values", profileID: otherProfile, table: table, configuration: .init())
        let otherTable = TableReference(schema: table.schema, name: "other", kind: "table")
        _ = try await store.saveNew(name: "Exact values", profileID: profileID, table: otherTable, configuration: .init())
        #expect(store.matching(profileID: profileID, table: table) == [original])
        await #expect(throws: TableBrowsePresetError.duplicateName) {
            try await store.saveNew(name: "EXACT VALUES", profileID: profileID, table: table, configuration: .init())
        }
        try await store.rename(id: original.id, name: "Renamed")
        let changed = TableBrowseConfiguration(filterExpression: .predicate(.init(column: "bytes", operator: "eq", value: "AAEC/w==")))
        try await store.update(id: original.id, configuration: changed)
        try await store.delete(id: another.id)
        let reopened = TableBrowsePresetStore(fileURL: url)
        await reopened.load()
        #expect(reopened.isLoaded && reopened.error == nil)
        #expect(reopened.presets == store.presets)
        #expect(reopened.matching(profileID: profileID, table: table).first?.configuration == changed)
        #expect(reopened.matching(profileID: otherProfile, table: table).isEmpty)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)).contains { $0.hasSuffix(".tmp") })
    }

    @Test func explicitUpdateAndRenameNeverOverwriteAnotherNamedView() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json")
        let store = TableBrowsePresetStore(fileURL: url)
        await store.load()
        let profileID = UUID()
        let first = try await store.saveNew(name: "First", profileID: profileID, table: table, configuration: configuration())
        let second = try await store.saveNew(name: "Second", profileID: profileID, table: table, configuration: .init())
        let original = try Data(contentsOf: url)
        await #expect(throws: TableBrowsePresetError.duplicateName) { try await store.rename(id: second.id, name: "first") }
        await #expect(throws: TableBrowsePresetError.invalid) { try await store.rename(id: first.id, name: " \n ") }
        await #expect(throws: TableBrowsePresetError.notFound) { try await store.delete(id: UUID()) }
        #expect(try Data(contentsOf: url) == original)
        #expect(store.presets == [first, second])
    }

    @Test func failedPublicationPreservesMemoryAndMalformedExistingBytes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json")
        let store = TableBrowsePresetStore(fileURL: url)
        await store.load()
        let original = try await store.saveNew(name: "Original", profileID: UUID(), table: table, configuration: configuration())
        let malformed = Data("{\"version\":99,\"presets\":[]}".utf8)
        try malformed.write(to: url)
        await #expect(throws: TableBrowsePresetError.write) { try await store.rename(id: original.id, name: "Changed") }
        #expect(store.presets == [original])
        #expect(try Data(contentsOf: url) == malformed)
        let reopened = TableBrowsePresetStore(fileURL: url)
        await reopened.load()
        #expect(!reopened.isLoaded && reopened.error != nil && reopened.presets.isEmpty)
        await #expect(throws: TableBrowsePresetError.busy) {
            try await reopened.saveNew(name: "Replacement", profileID: UUID(), table: table, configuration: .init())
        }
        #expect(try Data(contentsOf: url) == malformed)
    }

    @Test func symlinksCannotSupplyOrReceivePresetLibraryBytes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.json"), link = root.appendingPathComponent("library.json")
        let targetBytes = Data("{\"version\":1,\"presets\":[]}".utf8)
        try targetBytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = TableBrowsePresetStore(fileURL: link)
        await store.load()
        #expect(!store.isLoaded && store.error != nil)
        #expect(try Data(contentsOf: target) == targetBytes)
    }

    @Test func staleLibraryInstanceCannotOverwriteAnotherProcessChanges() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json")
        let first = TableBrowsePresetStore(fileURL: url), second = TableBrowsePresetStore(fileURL: url)
        await first.load()
        await second.load()
        let preset = try await first.saveNew(name: "First", profileID: UUID(), table: table, configuration: .init())
        let bytes = try Data(contentsOf: url)
        await #expect(throws: TableBrowsePresetError.changed) {
            try await second.saveNew(name: "Stale", profileID: UUID(), table: table, configuration: .init())
        }
        #expect(second.presets.isEmpty)
        #expect(try Data(contentsOf: url) == bytes)
        let read = TableBrowsePresetStore(fileURL: url)
        await read.load()
        #expect(read.presets == [preset])
    }

    @Test func originalTypedConfigurationSurvivesSeparateStoreRead() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json")
        let first = TableBrowsePresetStore(fileURL: url)
        await first.load()
        let preset = try await first.saveNew(name: "Typed", profileID: UUID(), table: table, configuration: configuration())
        let second = TableBrowsePresetStore(fileURL: url)
        await second.load()
        #expect(second.presets.first == preset)
        #expect(second.presets.first?.configuration == configuration())
    }
}
