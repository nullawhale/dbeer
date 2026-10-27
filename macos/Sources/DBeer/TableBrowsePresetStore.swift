import Combine
import Darwin
import Foundation

enum TableBrowsePresetError: LocalizedError, Equatable {
    case read, write, invalid, duplicateName, notFound, busy, changed

    var errorDescription: String? {
        switch self {
        case .read: "Saved table views could not be read. The existing file has been left unchanged."
        case .write: "The table view could not be saved. Previous saved views have been left unchanged."
        case .invalid: "Choose a nonempty name and valid filters and sorting within the saved-view limits."
        case .duplicateName: "A saved view with this name already exists for this table. Choose another name or update that view explicitly."
        case .notFound: "This saved table view is no longer available."
        case .busy: "Saved table views are still loading or saving."
        case .changed: "Saved table views changed in another application window or process. Reopen the application before changing this library."
        }
    }
}

struct TableBrowsePreset: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var profileID: UUID
    var table: TableReference
    var configuration: TableBrowseConfiguration

    var isValid: Bool {
        Self.validName(name) && configuration.isValid &&
            [table.schema, table.name].allSatisfy { !$0.isEmpty && $0.utf8.count <= 1_024 && !$0.contains("\0") } &&
            ["table", "view"].contains(table.kind)
    }

    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 1_024 && !name.contains("\0")
    }

    private enum CodingKeys: String, CodingKey { case id, name, profileID, table, configuration }
    init(id: UUID = UUID(), name: String, profileID: UUID, table: TableReference, configuration: TableBrowseConfiguration) {
        self.id = id; self.name = name; self.profileID = profileID; self.table = table; self.configuration = configuration
    }
    init(from decoder: Decoder) throws {
        try requirePresetKeys(decoder, allowed: ["id", "name", "profileID", "table", "configuration"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        profileID = try values.decode(UUID.self, forKey: .profileID)
        let reference = try values.superDecoder(forKey: .table)
        try requirePresetKeys(reference, allowed: ["schema", "name", "kind"])
        table = try TableReference(from: reference)
        let configurationDecoder = try values.superDecoder(forKey: .configuration)
        try requirePresetKeys(configurationDecoder, allowed: ["filterExpression", "sort"])
        let configurationValues = try configurationDecoder.container(keyedBy: PresetCodingKey.self)
        let sortKey = PresetCodingKey(stringValue: "sort")!
        var sorting = try configurationValues.nestedUnkeyedContainer(forKey: sortKey)
        while !sorting.isAtEnd { try requirePresetKeys(sorting.superDecoder(), allowed: ["column", "direction"]) }
        configuration = try values.decode(TableBrowseConfiguration.self, forKey: .configuration)
        guard isValid else { throw TableBrowsePresetError.read }
    }
}

private struct StoredTableBrowsePresets: Codable, Sendable {
    var version = 1
    var presets: [TableBrowsePreset] = []
    var isValid: Bool {
        version == 1 && presets.count <= 256 && Set(presets.map(\.id)).count == presets.count &&
            presets.allSatisfy(\.isValid) && presets.enumerated().allSatisfy { index, preset in
                !presets.prefix(index).contains { $0.profileID == preset.profileID && $0.table == preset.table && presetNameKey($0.name) == presetNameKey(preset.name) }
            }
    }
    private enum CodingKeys: String, CodingKey { case version, presets }
    init(presets: [TableBrowsePreset] = []) { self.presets = presets }
    init(from decoder: Decoder) throws {
        try requirePresetKeys(decoder, allowed: ["version", "presets"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        presets = try values.decode([TableBrowsePreset].self, forKey: .presets)
        guard isValid else { throw TableBrowsePresetError.read }
    }
}

private func presetNameKey(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
}

private struct PresetCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requirePresetKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: PresetCodingKey.self)
    guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw TableBrowsePresetError.read }
}

/// Disk work stays off the main actor. Publication uses a private temporary file
/// and rename, so an interrupted write cannot replace a complete library.
private actor TableBrowsePresetFile {
    let fileURL: URL
    static let maximumBytes = 64 * 1_024 * 1_024
    init(fileURL: URL) { self.fileURL = fileURL.standardizedFileURL }

    func load() throws -> StoredTableBrowsePresets {
        var metadata = stat()
        guard lstat(fileURL.path, &metadata) == 0 else {
            guard errno == ENOENT else { throw TableBrowsePresetError.read }
            return StoredTableBrowsePresets()
        }
        return try decode(readExisting())
    }

    func save(_ snapshot: StoredTableBrowsePresets, expected: [TableBrowsePreset]) throws {
        guard snapshot.isValid else { throw TableBrowsePresetError.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumBytes else { throw TableBrowsePresetError.invalid }
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".table-view-\(UUID()).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directoryFD >= 0 else { throw TableBrowsePresetError.write }
            defer { close(directoryFD) }
            guard fchmod(directoryFD, 0o700) == 0 else { throw TableBrowsePresetError.write }
            let lockURL = directory.appendingPathComponent(".library.lock")
            let lockFD = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard lockFD >= 0 else { throw TableBrowsePresetError.write }
            defer { flock(lockFD, LOCK_UN); close(lockFD) }
            var lockMetadata = stat()
            guard fstat(lockFD, &lockMetadata) == 0, lockMetadata.st_mode & S_IFMT == S_IFREG,
                  fchmod(lockFD, 0o600) == 0, flock(lockFD, LOCK_EX) == 0 else { throw TableBrowsePresetError.write }
            // Never overwrite an unreadable, malformed, future-version, or
            // concurrently changed library with this instance's stale snapshot.
            var existing = stat()
            if lstat(fileURL.path, &existing) == 0 {
                guard try decode(readExisting()).presets == expected else { throw TableBrowsePresetError.changed }
            } else {
                guard errno == ENOENT else { throw TableBrowsePresetError.write }
                guard expected.isEmpty else { throw TableBrowsePresetError.changed }
            }
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw TableBrowsePresetError.write }
            defer { unlink(temporary.path) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, fileURL.path) == 0 else { throw TableBrowsePresetError.write }
            _ = fsync(directoryFD)
        } catch let error as TableBrowsePresetError where error == .invalid || error == .changed { throw error }
        catch { throw TableBrowsePresetError.write }
    }

    private func readExisting() throws -> Data {
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw TableBrowsePresetError.read }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= Self.maximumBytes else { throw TableBrowsePresetError.read }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw TableBrowsePresetError.read }
        return data
    }

    private func decode(_ data: Data) throws -> StoredTableBrowsePresets {
        do { return try JSONDecoder().decode(StoredTableBrowsePresets.self, from: data) }
        catch { throw TableBrowsePresetError.read }
    }
}

@MainActor
final class TableBrowsePresetStore: ObservableObject {
    @Published private(set) var presets: [TableBrowsePreset] = []
    @Published private(set) var error: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isLoaded = false
    private let file: TableBrowsePresetFile

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DBeer/TableViews/library.json")
    }
    init(fileURL: URL = TableBrowsePresetStore.defaultFileURL) { file = TableBrowsePresetFile(fileURL: fileURL) }

    func load() async {
        guard !isLoaded, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            presets = try await file.load().presets
            isLoaded = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func matching(profileID: UUID, table: TableReference) -> [TableBrowsePreset] {
        presets.filter { $0.profileID == profileID && $0.table == table }.sorted { presetNameKey($0.name) < presetNameKey($1.name) }
    }

    @discardableResult
    func saveNew(name: String, profileID: UUID, table: TableReference, configuration: TableBrowseConfiguration) async throws -> TableBrowsePreset {
        let preset = TableBrowsePreset(name: name.trimmingCharacters(in: .whitespacesAndNewlines), profileID: profileID, table: table, configuration: configuration)
        guard preset.isValid else { throw TableBrowsePresetError.invalid }
        guard !matching(profileID: profileID, table: table).contains(where: { presetNameKey($0.name) == presetNameKey(preset.name) }) else {
            throw TableBrowsePresetError.duplicateName
        }
        try await publish(presets + [preset])
        return preset
    }

    func update(id: UUID, configuration: TableBrowseConfiguration) async throws {
        guard configuration.isValid else { throw TableBrowsePresetError.invalid }
        guard let index = presets.firstIndex(where: { $0.id == id }) else { throw TableBrowsePresetError.notFound }
        var changed = presets
        changed[index].configuration = configuration
        try await publish(changed)
    }

    func rename(id: UUID, name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TableBrowsePreset.validName(name) else { throw TableBrowsePresetError.invalid }
        guard let index = presets.firstIndex(where: { $0.id == id }) else { throw TableBrowsePresetError.notFound }
        let original = presets[index]
        guard !matching(profileID: original.profileID, table: original.table).contains(where: { $0.id != id && presetNameKey($0.name) == presetNameKey(name) }) else {
            throw TableBrowsePresetError.duplicateName
        }
        var changed = presets
        changed[index].name = name
        try await publish(changed)
    }

    func delete(id: UUID) async throws {
        guard presets.contains(where: { $0.id == id }) else { throw TableBrowsePresetError.notFound }
        try await publish(presets.filter { $0.id != id })
    }

    private func publish(_ changed: [TableBrowsePreset]) async throws {
        guard isLoaded, !isBusy else { throw TableBrowsePresetError.busy }
        isBusy = true
        defer { isBusy = false }
        do {
            try await file.save(StoredTableBrowsePresets(presets: changed), expected: presets)
            presets = changed
            error = nil
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }
}
