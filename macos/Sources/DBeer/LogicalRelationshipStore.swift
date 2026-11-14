import Combine
import Darwin
import Foundation

private struct StoredLogicalRelationships: Codable, Sendable {
    let version: Int
    let relationships: [LogicalRelationship]
    init(relationships: [LogicalRelationship]) { version = 1; self.relationships = relationships }
    var isValid: Bool {
        version == 1 && relationships.count <= LogicalRelationshipLimits.relationships &&
            Set(relationships.map(\.id)).count == relationships.count && relationships.allSatisfy(\.isValid)
    }
    private enum CodingKeys: String, CodingKey { case version, relationships }
    init(from decoder: any Decoder) throws {
        try logicalRelationshipKeys(decoder, allowed: ["version", "relationships"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        version = try fields.decode(Int.self, forKey: .version)
        relationships = try fields.decode([LogicalRelationship].self, forKey: .relationships)
        guard isValid else { throw LogicalRelationshipError.invalid }
    }
}

/// Reuses the reviewed inode/content-bound file publisher. Actor isolation
/// keeps actual reads, hashing, coordination and fsync off the main actor.
private actor LogicalRelationshipFile {
    let url: URL
    private var version: SQLFileVersion?
    private var loaded = false
    init(url: URL) { self.url = url.standardizedFileURL }
    func load() throws -> [LogicalRelationship] {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            guard errno == ENOENT else { throw LogicalRelationshipError.read }
            version = nil; loaded = true
            return []
        }
        do {
            let read = try SQLFileBinding.read(url, maximumBytes: LogicalRelationshipLimits.libraryBytes)
            let bytes = Data(read.text.utf8)
            try ExactJSONKeys.validate(bytes, maximumBytes: LogicalRelationshipLimits.libraryBytes)
            let snapshot = try JSONDecoder().decode(StoredLogicalRelationships.self, from: bytes)
            guard snapshot.isValid else { throw LogicalRelationshipError.read }
            version = read.version; loaded = true
            return snapshot.relationships
        } catch { throw LogicalRelationshipError.read }
    }
    func save(_ relationships: [LogicalRelationship]) throws {
        let snapshot = StoredLogicalRelationships(relationships: relationships)
        guard loaded, snapshot.isValid else { throw LogicalRelationshipError.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(snapshot)
        guard bytes.count <= LogicalRelationshipLimits.libraryBytes else { throw LogicalRelationshipError.invalid }
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw LogicalRelationshipError.write }
            defer { close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, fchmod(descriptor, 0o700) == 0 else { throw LogicalRelationshipError.write }
            let identity = SQLFileIdentity(device: UInt64(bitPattern: Int64(metadata.st_dev)), inode: UInt64(metadata.st_ino))
            let saved = try SQLFileBinding.write(String(decoding: bytes, as: UTF8.self), to: url,
                expectedVersion: version, expectedParent: identity, maximumBytes: LogicalRelationshipLimits.libraryBytes)
            version = saved.version
        } catch SQLFileBindingError.changed { throw LogicalRelationshipError.changed }
        catch { throw LogicalRelationshipError.write }
    }
}

@MainActor
final class LogicalRelationshipStore: ObservableObject {
    @Published private(set) var relationships: [LogicalRelationship] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var revision: UInt64 = 0
    private let file: LogicalRelationshipFile
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DBeer/LogicalRelationships/library.json")
    }
    init(fileURL: URL = LogicalRelationshipStore.defaultURL) { file = LogicalRelationshipFile(url: fileURL) }
    func load() async {
        guard !isLoaded, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { relationships = try await file.load(); isLoaded = true; error = nil; revision &+= 1 }
        catch { self.error = error.localizedDescription }
    }
    func reload() async {
        guard !isBusy else { return }
        isLoaded = false
        await load()
    }
    func matching(profileID: UUID, reference: TableReference) -> [LogicalRelationship] {
        relationships.filter { $0.source.matches(profileID: profileID, reference: reference) || $0.target.matches(profileID: profileID, reference: reference) }
    }
    func relationship(id: UUID) -> LogicalRelationship? { relationships.first { $0.id == id } }
    /// The editor calls this only after the user explicitly confirms a freshly
    /// validated mapping. The store itself never queries a server.
    func saveConfirmed(_ relationship: LogicalRelationship) async throws {
        guard relationship.isValid else { throw LogicalRelationshipError.invalid }
        var changed = relationships
        if let index = changed.firstIndex(where: { $0.id == relationship.id }) { changed[index] = relationship }
        else { changed.append(relationship) }
        try await publish(changed)
    }
    func delete(id: UUID) async throws {
        guard relationships.contains(where: { $0.id == id }) else { throw LogicalRelationshipError.notFound }
        try await publish(relationships.filter { $0.id != id })
    }
    private func publish(_ changed: [LogicalRelationship]) async throws {
        guard isLoaded, !isBusy else { throw LogicalRelationshipError.busy }
        guard changed.count <= LogicalRelationshipLimits.relationships else { throw LogicalRelationshipError.invalid }
        isBusy = true
        defer { isBusy = false }
        do {
            try await file.save(changed)
            relationships = changed; revision &+= 1; error = nil
        } catch { self.error = error.localizedDescription; throw error }
    }
}
