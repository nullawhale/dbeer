import CryptoKit
import Darwin
import Foundation

enum ResultSnapshotError: LocalizedError, Equatable {
    case invalid, unavailable, corrupt, write, quotaExceeded, invalidQuota, notFound, referenceConfirmationRequired

    var errorDescription: String? {
        switch self {
        case .invalid: "The loaded result is invalid and could not be saved as a snapshot."
        case .unavailable: "The snapshot folder is unavailable. Existing snapshots were left unchanged."
        case .corrupt: "The snapshot is incomplete, damaged, or uses an unsupported format."
        case .write: "The snapshot could not be saved. Existing snapshots were left unchanged."
        case .quotaExceeded: "The snapshot quota would be exceeded. Increase the quota or explicitly delete snapshots."
        case .invalidQuota: "Choose a positive snapshot quota that is at least the current stored size."
        case .notFound: "This snapshot is no longer available."
        case .referenceConfirmationRequired: "This snapshot is referenced by an investigation. Confirm deletion explicitly."
        }
    }
}

/// Values use the same positional, optional-string representation as JSON
/// export: NULL never becomes text, and exact numerics never pass through Double.
struct ResultSnapshotCapture: Sendable {
    var title: String
    var sql: String
    var engine: DatabaseEngine
    var columns: [ResultColumn]
    var rows: [[String?]]
    var capturedAt: Date
    var profileID: UUID?
    var profileName: String?
    var environment: ConnectionEnvironment
    var outcome: SQLHistoryOutcome
    var truncated: Bool
    var partial: Bool
    var sourceRowCount: Int64?
    var commandTag: String

    init(title: String, sql: String, engine: DatabaseEngine, columns: [ResultColumn], rows: [[String?]],
         capturedAt: Date = Date(), profileID: UUID? = nil, profileName: String? = nil,
         environment: ConnectionEnvironment = .unspecified, outcome: SQLHistoryOutcome = .succeeded,
         truncated: Bool = false, partial: Bool = false, sourceRowCount: Int64? = nil, commandTag: String = "") {
        self.title = title; self.sql = sql; self.engine = engine; self.columns = columns; self.rows = rows
        self.capturedAt = capturedAt; self.profileID = profileID; self.profileName = profileName
        self.environment = environment; self.outcome = outcome; self.truncated = truncated
        self.partial = partial; self.sourceRowCount = sourceRowCount; self.commandTag = commandTag
    }
}

struct ResultSnapshotManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int
    var id: UUID
    var title: String
    /// Seconds since the Unix epoch, independent of Foundation's reference date.
    var capturedAt: Date
    var engine: DatabaseEngine
    var sql: String
    var profileID: UUID?
    var profileName: String?
    var environment: ConnectionEnvironment
    var outcome: SQLHistoryOutcome
    var columns: [ResultColumn]
    var rowCount: Int
    var sourceRowCount: Int64?
    var truncated: Bool
    var partial: Bool
    var commandTag: String
    var rowsBytes: Int64
    var rowsSHA256: String

    var isComplete: Bool {
        !truncated && !partial && outcome == .succeeded &&
        (sourceRowCount == nil || sourceRowCount == Int64(rowCount))
    }
}

struct ResultSnapshotSummary: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var capturedAt: Date
    var engine: DatabaseEngine
    var rowCount: Int
    var byteCount: Int64
    var truncated: Bool
    var partial: Bool
    var profileName: String?
    var isAvailable = true
}

struct ResultSnapshotArtifact: Sendable {
    var manifest: ResultSnapshotManifest
    var rows: [[String?]]
    var offset: Int
    var hasMore: Bool
}

struct ResultSnapshotUsage: Equatable, Sendable {
    var usedBytes: Int64
    var quotaBytes: Int64
    var snapshotCount: Int
}

enum ResultSnapshotWriteStage: Sendable { case row(Int), manifest, publication, settings }

/// Each artifact is an immutable UUID directory containing a small manifest and
/// rows.jsonl. Publication is one directory rename after fsync and a real-byte
/// quota check. A file lock serializes separate actors/processes using one root.
actor ResultSnapshotStore {
    static let defaultQuotaBytes: Int64 = 1_024 * 1_024 * 1_024
    static let minQuotaBytes: Int64 = 1
    static let maximumPageSize = 10_000
    static let maximumRowBytes = 16 * 1_024 * 1_024
    static let maximumManifestBytes = 16 * 1_024 * 1_024
    static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DBeer/Snapshots", isDirectory: true)
    }

    let rootURL: URL
    private var quotaBytes: Int64
    private let writeInterceptor: (@Sendable (ResultSnapshotWriteStage) throws -> Void)?
    private struct Settings: Codable { let version: Int; let quotaBytes: Int64 }

    init(rootURL: URL = ResultSnapshotStore.defaultRootURL, quotaBytes: Int64 = ResultSnapshotStore.defaultQuotaBytes,
         writeInterceptor: (@Sendable (ResultSnapshotWriteStage) throws -> Void)? = nil) {
        self.rootURL = rootURL.standardizedFileURL
        self.quotaBytes = quotaBytes
        self.writeInterceptor = writeInterceptor
    }

    func list() throws -> [ResultSnapshotSummary] {
        try withRoot { root in try summaries(root).sorted { $0.capturedAt > $1.capturedAt } }
    }

    func usage() throws -> ResultSnapshotUsage {
        try withRoot { root in
            let items = try summaries(root)
            return ResultSnapshotUsage(usedBytes: try storedBytes(root), quotaBytes: quotaBytes, snapshotCount: items.count)
        }
    }

    func setQuotaBytes(_ proposed: Int64) throws {
        try withRoot { root in
            guard proposed >= Self.minQuotaBytes, proposed >= (try storedBytes(root)) else { throw ResultSnapshotError.invalidQuota }
            do {
                try writeInterceptor?(.settings)
                let bytes = try Self.encoder().encode(Settings(version: 1, quotaBytes: proposed))
                let temporary = ".settings-\(UUID().uuidString.lowercased()).tmp"
                defer { unlinkat(root, temporary, 0) }
                try writeFile(root, name: temporary, data: bytes)
                guard renameat(root, temporary, root, "settings.json") == 0 else { throw ResultSnapshotError.write }
                _ = fsync(root)
                quotaBytes = proposed
            } catch let error as ResultSnapshotError { throw error }
            catch { throw ResultSnapshotError.write }
        }
    }

    func cleanup() throws {
        try withRoot { root in try cleanIncomplete(root) }
    }

    func save(_ capture: ResultSnapshotCapture) throws -> ResultSnapshotSummary {
        try Self.validate(capture)
        return try withRoot { root in
            try cleanIncomplete(root)
            let id = UUID()
            let name = id.uuidString.lowercased()
            let stagingName = ".partial-" + name
            guard mkdirat(root, stagingName, 0o700) == 0 else { throw ResultSnapshotError.write }
            let staging = openat(root, stagingName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard staging >= 0 else { throw ResultSnapshotError.write }
            defer { close(staging); try? removeArtifact(root, name: stagingName) }
            do {
                let descriptor = openat(staging, "rows.jsonl", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
                guard descriptor >= 0 else { throw ResultSnapshotError.write }
                let rows = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? rows.close() }
                var digest = SHA256()
                var rowsBytes: Int64 = 0
                let encoder = Self.encoder()
                let existingBytes = try storedBytes(root, excluding: stagingName)
                for (index, row) in capture.rows.enumerated() {
                    try Task.checkCancellation()
                    try writeInterceptor?(.row(index))
                    var bytes = try encoder.encode(row)
                    guard bytes.count <= Self.maximumRowBytes else { throw ResultSnapshotError.invalid }
                    bytes.append(10)
                    try rows.write(contentsOf: bytes)
                    digest.update(data: bytes)
                    rowsBytes += Int64(bytes.count)
                    guard rowsBytes <= quotaBytes - min(existingBytes, quotaBytes) else { throw ResultSnapshotError.quotaExceeded }
                }
                try rows.synchronize()
                try rows.close()
                let manifest = ResultSnapshotManifest(version: ResultSnapshotManifest.currentVersion, id: id, title: capture.title,
                    capturedAt: capture.capturedAt, engine: capture.engine, sql: capture.sql, profileID: capture.profileID,
                    profileName: capture.profileName, environment: capture.environment, outcome: capture.outcome,
                    columns: capture.columns, rowCount: capture.rows.count, sourceRowCount: capture.sourceRowCount,
                    truncated: capture.truncated,
                    partial: capture.partial || (capture.sourceRowCount.map { $0 > Int64(capture.rows.count) } ?? false),
                    commandTag: capture.commandTag,
                    rowsBytes: rowsBytes, rowsSHA256: Self.hex(digest.finalize()))
                try writeInterceptor?(.manifest)
                let metadata = try encoder.encode(manifest)
                guard metadata.count <= Self.maximumManifestBytes else { throw ResultSnapshotError.invalid }
                try writeFile(staging, name: "manifest.json", data: metadata)
                let actualBytes = try artifactBytes(staging)
                guard actualBytes == rowsBytes + Int64(metadata.count), existingBytes <= quotaBytes,
                      actualBytes <= quotaBytes - existingBytes else { throw ResultSnapshotError.quotaExceeded }
                try Task.checkCancellation()
                try writeInterceptor?(.publication)
                guard fsync(staging) == 0, renameat(root, stagingName, root, name) == 0 else { throw ResultSnapshotError.write }
                _ = fsync(root)
                return Self.summary(manifest, byteCount: actualBytes)
            } catch let error as ResultSnapshotError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch { throw ResultSnapshotError.write }
        }
    }

    func manifest(id: UUID) throws -> ResultSnapshotManifest {
        try withRoot { root in try readManifest(root, id: id).0 }
    }

    /// Reads one bounded presentation page while streaming and validating the
    /// whole immutable artifact. No caller needs to decode a 1 GiB JSON object.
    func load(id: UUID, offset: Int = 0, limit: Int = 200) throws -> ResultSnapshotArtifact {
        guard offset >= 0, (1...Self.maximumPageSize).contains(limit) else { throw ResultSnapshotError.invalid }
        return try withRoot { root in
            let (manifest, _) = try readManifest(root, id: id)
            let directory = try openArtifact(root, name: id.uuidString.lowercased())
            defer { close(directory) }
            let rowsFD = try regularFile(directory, name: "rows.jsonl")
            let handle = FileHandle(fileDescriptor: rowsFD, closeOnDealloc: true)
            defer { try? handle.close() }
            var pending = Data()
            var digest = SHA256()
            var byteCount: Int64 = 0
            var rowCount = 0
            var page: [[String?]] = []
            do {
                while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                    try Task.checkCancellation()
                    byteCount += Int64(chunk.count)
                    guard byteCount <= manifest.rowsBytes else { throw ResultSnapshotError.corrupt }
                    digest.update(data: chunk)
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = pending.prefix(upTo: newline)
                        guard !line.isEmpty, line.count <= Self.maximumRowBytes,
                              let row = try? JSONDecoder().decode([String?].self, from: line),
                              Self.validRow(row, columns: manifest.columns) else { throw ResultSnapshotError.corrupt }
                        if rowCount >= offset, page.count < limit { page.append(row) }
                        rowCount += 1
                        guard rowCount <= manifest.rowCount else { throw ResultSnapshotError.corrupt }
                        pending.removeSubrange(...newline)
                    }
                    guard pending.count <= Self.maximumRowBytes else { throw ResultSnapshotError.corrupt }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { throw ResultSnapshotError.corrupt }
            guard pending.isEmpty, rowCount == manifest.rowCount, byteCount == manifest.rowsBytes,
                  Self.hex(digest.finalize()) == manifest.rowsSHA256 else { throw ResultSnapshotError.corrupt }
            return ResultSnapshotArtifact(manifest: manifest, rows: page, offset: offset,
                hasMore: offset < rowCount && page.count < rowCount - offset)
        }
    }

    func delete(id: UUID, referencedBy: [UUID] = [], confirmation: Bool = false) throws {
        guard referencedBy.isEmpty || confirmation else { throw ResultSnapshotError.referenceConfirmationRequired }
        try withRoot { root in
            let name = id.uuidString.lowercased()
            var metadata = stat()
            guard fstatat(root, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw ResultSnapshotError.notFound }
            if metadata.st_mode & S_IFMT != S_IFDIR {
                guard unlinkat(root, name, 0) == 0 else { throw ResultSnapshotError.write }
                return
            }
            // Move out of the visible namespace before removal, making a crash
            // during deletion indistinguishable from an interrupted temporary.
            let temporary = ".partial-" + UUID().uuidString.lowercased()
            guard renameat(root, id.uuidString.lowercased(), root, temporary) == 0 else { throw ResultSnapshotError.write }
            try removeArtifact(root, name: temporary)
            _ = fsync(root)
        }
    }

    private func withRoot<T>(_ body: (Int32) throws -> T) throws -> T {
        guard rootURL.isFileURL, rootURL.path != "/", !rootURL.path.contains("\0"), quotaBytes >= Self.minQuotaBytes else { throw ResultSnapshotError.unavailable }
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw ResultSnapshotError.unavailable }
        let root = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { throw ResultSnapshotError.unavailable }
        defer { close(root) }
        var attributes = stat()
        guard fstat(root, &attributes) == 0, attributes.st_uid == geteuid(), fchmod(root, 0o700) == 0 else { throw ResultSnapshotError.unavailable }
        let lock = openat(root, ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ResultSnapshotError.unavailable }
        defer { close(lock) }
        var lockInformation = stat()
        guard fstat(lock, &lockInformation) == 0, lockInformation.st_mode & S_IFMT == S_IFREG,
              lockInformation.st_nlink == 1, lockInformation.st_uid == geteuid(),
              fchmod(lock, 0o600) == 0, flock(lock, LOCK_EX) == 0 else { throw ResultSnapshotError.unavailable }
        defer { flock(lock, LOCK_UN) }
        try readSettings(root)
        return try body(root)
    }

    private func readSettings(_ root: Int32) throws {
        var information = stat()
        if fstatat(root, "settings.json", &information, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ResultSnapshotError.unavailable }
            return
        }
        let descriptor = try regularFile(root, name: "settings.json")
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        guard information.st_size <= 4096,
              let bytes = try? file.readToEnd(), let settings = try? JSONDecoder().decode(Settings.self, from: bytes),
              settings.version == 1, settings.quotaBytes >= Self.minQuotaBytes else { throw ResultSnapshotError.corrupt }
        quotaBytes = settings.quotaBytes
    }

    private func names(_ directory: Int32) throws -> [String] {
        // Opening "." gives enumeration its own offset while retaining the
        // pinned directory inode if a parent is renamed during this operation.
        let copyFD = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard copyFD >= 0 else { throw ResultSnapshotError.unavailable }
        guard let copy = fdopendir(copyFD) else { close(copyFD); throw ResultSnapshotError.unavailable }
        defer { closedir(copy) }
        var result: [String] = []
        while let entry = readdir(copy) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result
    }

    private func summaries(_ root: Int32) throws -> [ResultSnapshotSummary] {
        try names(root).compactMap { name in
            guard let id = UUID(uuidString: name), id.uuidString.lowercased() == name else { return nil }
            do {
                let (manifest, size) = try readManifest(root, id: id)
                return Self.summary(manifest, byteCount: size)
            } catch {
                var metadata = stat()
                guard fstatat(root, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw ResultSnapshotError.corrupt }
                return ResultSnapshotSummary(id: id, title: "Unavailable snapshot",
                    capturedAt: Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec)),
                    engine: .postgresql, rowCount: 0, byteCount: try entryBytes(root, name: name),
                    truncated: true, partial: true, profileName: nil, isAvailable: false)
            }
        }
    }

    private func storedBytes(_ root: Int32, excluding: String? = nil) throws -> Int64 {
        var bytes: Int64 = 0
        for name in try names(root) where name != excluding {
            if let id = UUID(uuidString: name), id.uuidString.lowercased() == name {
                let size = try entryBytes(root, name: name)
                guard size <= Int64.max - bytes else { throw ResultSnapshotError.corrupt }
                bytes += size
            } else if name.hasPrefix(".partial-") {
                let size = try entryBytes(root, name: name)
                guard size <= Int64.max - bytes else { throw ResultSnapshotError.corrupt }
                bytes += size
            } else if name != ".lock" && name != "settings.json" && !Self.isSettingsTemporary(name) {
                throw ResultSnapshotError.corrupt
            }
        }
        return bytes
    }

    private func readManifest(_ root: Int32, id: UUID) throws -> (ResultSnapshotManifest, Int64) {
        let directory = try openArtifact(root, name: id.uuidString.lowercased())
        defer { close(directory) }
        let descriptor = try regularFile(directory, name: "manifest.json")
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0, info.st_size <= Self.maximumManifestBytes,
              let data = try? file.readToEnd(), data.count <= Self.maximumManifestBytes,
              let manifest = try? Self.decoder().decode(ResultSnapshotManifest.self, from: data), manifest.id == id,
              manifest.version == ResultSnapshotManifest.currentVersion,
              manifest.rowsBytes >= 0, manifest.rowCount >= 0, Self.validDigest(manifest.rowsSHA256),
              Self.validMetadata(manifest),
              try fileSize(directory, name: "rows.jsonl") == manifest.rowsBytes else { throw ResultSnapshotError.corrupt }
        return (manifest, try artifactBytes(directory))
    }

    private func artifactBytes(_ directory: Int32, allowIncomplete: Bool = false) throws -> Int64 {
        let entries = try names(directory)
        guard entries.allSatisfy({ $0 == "manifest.json" || $0 == "rows.jsonl" }),
              allowIncomplete || Set(entries) == ["manifest.json", "rows.jsonl"] else { throw ResultSnapshotError.corrupt }
        var bytes: Int64 = 0
        for name in entries {
            let size = try fileSize(directory, name: name)
            guard size <= Int64.max - bytes else { throw ResultSnapshotError.corrupt }
            bytes += size
        }
        return bytes
    }

    /// Damaged artifacts still consume quota and remain explicitly removable.
    /// Inspect links themselves; never read or traverse their destination.
    private func entryBytes(_ directory: Int32, name: String) throws -> Int64 {
        var metadata = stat()
        guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_size >= 0 else { throw ResultSnapshotError.corrupt }
        if metadata.st_mode & S_IFMT != S_IFDIR { return metadata.st_size }
        let child = try openArtifact(directory, name: name)
        defer { close(child) }
        return try directoryBytes(child)
    }

    private func directoryBytes(_ directory: Int32, depth: Int = 0) throws -> Int64 {
        guard depth <= 32 else { throw ResultSnapshotError.corrupt }
        var bytes: Int64 = 0
        for name in try names(directory) {
            var metadata = stat()
            guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                  metadata.st_size >= 0 else { throw ResultSnapshotError.corrupt }
            let size: Int64
            if metadata.st_mode & S_IFMT == S_IFDIR {
                let child = try openArtifact(directory, name: name)
                defer { close(child) }
                size = try directoryBytes(child, depth: depth + 1)
            } else { size = metadata.st_size }
            guard size <= Int64.max - bytes else { throw ResultSnapshotError.corrupt }
            bytes += size
        }
        return bytes
    }

    private func openArtifact(_ root: Int32, name: String) throws -> Int32 {
        let descriptor = openat(root, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw errno == ENOENT ? ResultSnapshotError.notFound : ResultSnapshotError.corrupt }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == geteuid() else { close(descriptor); throw ResultSnapshotError.corrupt }
        return descriptor
    }

    private func regularFile(_ directory: Int32, name: String) throws -> Int32 {
        let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ResultSnapshotError.corrupt }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1, metadata.st_uid == geteuid(), metadata.st_size >= 0 else {
            close(descriptor); throw ResultSnapshotError.corrupt
        }
        return descriptor
    }

    private func fileSize(_ directory: Int32, name: String) throws -> Int64 {
        let descriptor = try regularFile(directory, name: name)
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw ResultSnapshotError.corrupt }
        return information.st_size
    }

    private func writeFile(_ directory: Int32, name: String, data: Data) throws {
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ResultSnapshotError.write }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func cleanIncomplete(_ root: Int32) throws {
        for name in try names(root) {
            if name.hasPrefix(".partial-"), let id = UUID(uuidString: String(name.dropFirst(9))),
               name == ".partial-" + id.uuidString.lowercased() {
                try removeArtifact(root, name: name)
            } else if Self.isSettingsTemporary(name) {
                guard unlinkat(root, name, 0) == 0 else { throw ResultSnapshotError.write }
            }
        }
    }

    private func removeArtifact(_ root: Int32, name: String, depth: Int = 0) throws {
        guard depth <= 32 else { throw ResultSnapshotError.corrupt }
        var metadata = stat()
        if fstatat(root, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT { return }
        if metadata.st_mode & S_IFMT != S_IFDIR {
            guard unlinkat(root, name, 0) == 0 else { throw ResultSnapshotError.write }
            return
        }
        let directory = openat(root, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if directory < 0, errno == ENOENT { return }
        guard directory >= 0 else { throw ResultSnapshotError.corrupt }
        defer { close(directory) }
        for entry in try names(directory) {
            var metadata = stat()
            guard fstatat(directory, entry, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw ResultSnapshotError.corrupt }
            if metadata.st_mode & S_IFMT == S_IFDIR { try removeArtifact(directory, name: entry, depth: depth + 1) }
            else { guard unlinkat(directory, entry, 0) == 0 else { throw ResultSnapshotError.write } }
        }
        guard unlinkat(root, name, AT_REMOVEDIR) == 0 else { throw ResultSnapshotError.write }
    }

    private static func isSettingsTemporary(_ name: String) -> Bool {
        guard name.hasPrefix(".settings-"), name.hasSuffix(".tmp"),
              let id = UUID(uuidString: String(name.dropFirst(10).dropLast(4))) else { return false }
        return name == ".settings-" + id.uuidString.lowercased() + ".tmp"
    }

    private static func validate(_ capture: ResultSnapshotCapture) throws {
        guard !capture.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, capture.title.utf8.count <= 4096,
              capture.sql.utf8.count <= maximumManifestBytes / 2, capture.capturedAt.timeIntervalSince1970.isFinite,
              (capture.profileName?.utf8.count ?? 0) <= 4096, capture.commandTag.utf8.count <= 4096,
              capture.sourceRowCount.map({ $0 >= Int64(capture.rows.count) }) ?? true,
              validColumns(capture.columns), capture.rows.allSatisfy({ validRow($0, columns: capture.columns) }) else { throw ResultSnapshotError.invalid }
    }

    private static func validMetadata(_ manifest: ResultSnapshotManifest) -> Bool {
        !manifest.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && manifest.title.utf8.count <= 4096 &&
        manifest.sql.utf8.count <= maximumManifestBytes / 2 && manifest.capturedAt.timeIntervalSince1970.isFinite &&
        (manifest.profileName?.utf8.count ?? 0) <= 4096 && manifest.commandTag.utf8.count <= 4096 &&
        (manifest.sourceRowCount.map { $0 >= Int64(manifest.rowCount) } ?? true) && validColumns(manifest.columns)
    }

    private static func validColumns(_ columns: [ResultColumn]) -> Bool {
        columns.count <= 65_536 && columns.enumerated().allSatisfy {
            $0.offset == $0.element.index && ($0.element.encoding == nil || $0.element.encoding == "base64") &&
            $0.element.name.utf8.count <= 65_536 && $0.element.nativeType.utf8.count <= 65_536
        }
    }

    private static func validRow(_ row: [String?], columns: [ResultColumn]) -> Bool {
        row.count == columns.count && zip(row, columns).allSatisfy { value, column in
            column.encoding != "base64" || value == nil || Data(base64Encoded: value!) != nil
        }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func summary(_ manifest: ResultSnapshotManifest, byteCount: Int64) -> ResultSnapshotSummary {
        ResultSnapshotSummary(id: manifest.id, title: manifest.title, capturedAt: manifest.capturedAt,
            engine: manifest.engine, rowCount: manifest.rowCount, byteCount: byteCount,
            truncated: manifest.truncated,
            partial: manifest.partial || (manifest.sourceRowCount.map { $0 > Int64(manifest.rowCount) } ?? false),
            profileName: manifest.profileName)
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
