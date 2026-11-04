import Combine
import Darwin
import Foundation

/// Repeatable mappings contain metadata and parser settings, never file bytes,
/// file locations, connection settings, passwords or imported values.
struct TransferMappingPreset: Codable, Identifiable, Equatable, Sendable {
    struct Column: Codable, Equatable, Sendable {
        var sourceIndex: Int
        var targetName: String?
        var type: String?
        var nullable: Bool?
        var precision: Int?
        var scale: Int?
    }
    struct FileOptions: Codable, Equatable, Sendable {
        var delimiter: String
        var hasHeader: Bool
        var nullMarker: String?
        var emptyFieldsAreNull: Bool

        init(_ options: DelimitedImportOptions) {
            delimiter = options.delimiter.rawValue; hasHeader = options.hasHeader
            nullMarker = options.nullMarker; emptyFieldsAreNull = options.emptyFieldsAreNull
        }
        var options: DelimitedImportOptions? {
            guard let delimiter = DelimitedImportDelimiter(rawValue: delimiter) else { return nil }
            return DelimitedImportOptions(delimiter: delimiter, hasHeader: hasHeader,
                nullMarker: nullMarker, emptyFieldsAreNull: emptyFieldsAreNull)
        }
    }
    var id = UUID()
    var name: String
    var engine: DatabaseEngine
    var purpose: String
    var headers: [String]
    var columns: [Column]
    var fileOptions: FileOptions

    var valid: Bool {
        [.postgresql, .mysql, .sqlite].contains(engine) && ["append", "create", "table"].contains(purpose) &&
        Self.nameValid(name) && !headers.isEmpty && headers.count <= 256 && headers.allSatisfy(Self.fieldValid) &&
        columns.count == headers.count && Set(columns.map(\.sourceIndex)) == Set(headers.indices) &&
        columns.allSatisfy { column in
            (column.targetName.map(Self.nameValid) ?? true) && (column.type.map(Self.fieldValid) ?? true) &&
            (column.precision.map { (0...1_000).contains($0) } ?? true) &&
            (column.scale.map { (0...1_000).contains($0) } ?? true)
        } && Set(columns.compactMap(\.targetName).map { Data($0.utf8) }).count == columns.compactMap(\.targetName).count &&
        fileOptions.options != nil && (fileOptions.nullMarker.map(Self.fieldValid) ?? true)
    }
    func matches(headers: [String], engine: DatabaseEngine, purpose: String) -> Bool {
        self.engine == engine && self.purpose == purpose && self.headers.map { Data($0.utf8) } == headers.map { Data($0.utf8) }
    }
    private static func fieldValid(_ value: String) -> Bool { value.utf8.count <= 1_024 && !value.contains("\0") }
    private static func nameValid(_ value: String) -> Bool { fieldValid(value) && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum TransferPresetError: LocalizedError {
    case invalid, unavailable, changed
    var errorDescription: String? {
        switch self {
        case .invalid: "Choose a unique mapping name and valid column settings."
        case .unavailable: "Saved mappings could not be read or written. The existing library was left unchanged."
        case .changed: "Saved mappings changed in another window or process. Reload the mapping library before saving."
        }
    }
}

private struct StoredTransferPresets: Codable {
    var version = 1
    var presets: [TransferMappingPreset]
    var valid: Bool {
        version == 1 && presets.count <= 256 && presets.allSatisfy(\.valid) &&
        Set(presets.map(\.id)).count == presets.count &&
        Set(presets.map { Data($0.name.utf8) }).count == presets.count
    }
}

private actor TransferPresetFile {
    let url: URL
    static let limit = 4 * 1_024 * 1_024
    init(url: URL) { self.url = url.standardizedFileURL }

    func read() throws -> (Data?, [TransferMappingPreset]) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            guard errno == ENOENT else { throw TransferPresetError.unavailable }
            return (nil, [])
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= Self.limit else { throw TransferPresetError.unavailable }
        let data = try handle.read(upToCount: Self.limit + 1) ?? Data()
        guard data.count <= Self.limit, let stored = try? JSONDecoder().decode(StoredTransferPresets.self, from: data), stored.valid else { throw TransferPresetError.unavailable }
        return (data, stored.presets)
    }

    func write(_ presets: [TransferMappingPreset], expected: Data?) throws -> Data {
        let stored = StoredTransferPresets(presets: presets)
        guard stored.valid else { throw TransferPresetError.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(stored)
        guard data.count <= Self.limit else { throw TransferPresetError.invalid }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw TransferPresetError.unavailable }
        defer { close(directoryFD) }
        let lock = openat(directoryFD, ".mappings.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw TransferPresetError.unavailable }
        defer { flock(lock, LOCK_UN); close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, flock(lock, LOCK_EX) == 0 else { throw TransferPresetError.unavailable }
        guard try read().0 == expected else { throw TransferPresetError.changed }
        let temporary = ".mapping-\(UUID()).tmp"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw TransferPresetError.unavailable }
        defer { unlinkat(directoryFD, temporary, 0) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard renameat(directoryFD, temporary, directoryFD, url.lastPathComponent) == 0 else { throw TransferPresetError.unavailable }
        _ = fsync(directoryFD)
        return data
    }
}

@MainActor
final class TransferMappingPresetStore: ObservableObject {
    @Published private(set) var presets: [TransferMappingPreset] = []
    @Published private(set) var error: String?
    @Published private(set) var isBusy = false
    @Published private(set) var loaded = false
    private let file: TransferPresetFile
    private var revision: Data?
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DBeer/TransferMappings/library.json")) {
        file = TransferPresetFile(url: url)
    }
    func load() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let result = try await file.read()
            revision = result.0; presets = result.1; loaded = true; error = nil
        } catch { loaded = false; self.error = error.localizedDescription }
    }
    func save(_ preset: TransferMappingPreset) async throws {
        guard loaded, !isBusy, preset.valid else { throw TransferPresetError.invalid }
        guard !presets.contains(where: { $0.id != preset.id && Data($0.name.utf8) == Data(preset.name.utf8) }) else { throw TransferPresetError.invalid }
        let changed = presets.filter { $0.id != preset.id } + [preset]
        try await publish(changed)
    }
    func delete(_ id: UUID) async throws { try await publish(presets.filter { $0.id != id }) }
    private func publish(_ changed: [TransferMappingPreset]) async throws {
        guard loaded, !isBusy else { throw TransferPresetError.unavailable }
        isBusy = true; defer { isBusy = false }
        do { revision = try await file.write(changed, expected: revision); presets = changed; error = nil }
        catch { self.error = error.localizedDescription; throw error }
    }
}
