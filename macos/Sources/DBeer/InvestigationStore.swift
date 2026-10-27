import Darwin
import Foundation

enum InvestigationStoreError: LocalizedError, Equatable {
    case read, write, invalid, notFound, notLoaded

    var errorDescription: String? {
        switch self {
        case .read: "The investigation library could not be read. Existing investigations have been left unchanged."
        case .write: "The investigation could not be saved. Existing investigations have been left unchanged."
        case .invalid: "The investigation is invalid or exceeds the local library limits."
        case .notFound: "This investigation is no longer available in the local library."
        case .notLoaded: "The investigation library is unavailable. Snapshot references cannot be checked."
        }
    }
}

/// Generous text limits keep decoding and whole-library publication bounded.
/// Result rows, connection settings and live execution state never enter this format.
enum InvestigationLimits {
    static let maximumDocuments = 4_096
    static let maximumBlocksPerDocument = 4_096
    static let maximumTitleBytes = 16 * 1_024
    static let maximumBlockBytes = 16 * 1_024 * 1_024
    static let maximumDocumentBytes = 64 * 1_024 * 1_024
    static let maximumLibraryBytes = 256 * 1_024 * 1_024
}

enum InvestigationBlockKind: String, Codable, Sendable { case markdown, sql, snapshot }

struct StoredInvestigationBlock: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: InvestigationBlockKind
    var text: String
    var profileID: UUID?
    var snapshotID: UUID?
    var explanation: String

    init(id: UUID = UUID(), kind: InvestigationBlockKind, text: String = "", profileID: UUID? = nil,
         snapshotID: UUID? = nil, explanation: String = "") {
        self.id = id
        self.kind = kind
        self.text = text
        self.profileID = profileID
        self.snapshotID = snapshotID
        self.explanation = explanation
    }

    var textBytes: Int { text.utf8.count + explanation.utf8.count }
    var isValid: Bool {
        guard textBytes <= InvestigationLimits.maximumBlockBytes else { return false }
        switch kind {
        case .markdown: return profileID == nil && snapshotID == nil && explanation.isEmpty
        case .sql: return snapshotID == nil && explanation.isEmpty
        case .snapshot: return snapshotID != nil && profileID == nil && text.isEmpty
        }
    }

    private enum CodingKeys: String, CodingKey { case id, kind, text, profileID, snapshotID, explanation }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(InvestigationBlockKind.self, forKey: .kind)
        text = ""
        profileID = nil
        snapshotID = nil
        explanation = ""
        switch kind {
        case .markdown:
            try requireInvestigationKeys(decoder, allowed: ["id", "kind", "text"])
            text = try values.decode(String.self, forKey: .text)
        case .sql:
            try requireInvestigationKeys(decoder, allowed: ["id", "kind", "text", "profileID"])
            text = try values.decode(String.self, forKey: .text)
            profileID = try values.decodeIfPresent(UUID.self, forKey: .profileID)
        case .snapshot:
            try requireInvestigationKeys(decoder, allowed: ["id", "kind", "snapshotID", "explanation"])
            snapshotID = try values.decode(UUID.self, forKey: .snapshotID)
            explanation = try values.decode(String.self, forKey: .explanation)
        }
        guard isValid else { throw InvestigationStoreError.read }
    }

    func encode(to encoder: Encoder) throws {
        guard isValid else { throw InvestigationStoreError.invalid }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        switch kind {
        case .markdown: try values.encode(text, forKey: .text)
        case .sql:
            try values.encode(text, forKey: .text)
            try values.encodeIfPresent(profileID, forKey: .profileID)
        case .snapshot:
            try values.encode(snapshotID, forKey: .snapshotID)
            try values.encode(explanation, forKey: .explanation)
        }
    }
}

struct StoredInvestigation: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var blocks: [StoredInvestigationBlock]

    init(id: UUID = UUID(), title: String = "Investigation", createdAt: Date = .now,
         updatedAt: Date? = nil, blocks: [StoredInvestigationBlock] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.blocks = blocks
    }

    var textBytes: Int { title.utf8.count + blocks.reduce(0, { $0 + $1.textBytes }) }
    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !title.contains("\0") &&
        title.utf8.count <= InvestigationLimits.maximumTitleBytes &&
        createdAt.timeIntervalSince1970.isFinite && updatedAt.timeIntervalSince1970.isFinite &&
        updatedAt >= createdAt && blocks.count <= InvestigationLimits.maximumBlocksPerDocument &&
        Set(blocks.map(\.id)).count == blocks.count && blocks.allSatisfy(\.isValid) &&
        blocks.reduce(0, { $0 + $1.textBytes }) <= InvestigationLimits.maximumDocumentBytes
    }

    private enum CodingKeys: String, CodingKey { case id, title, createdAt, updatedAt, blocks }

    init(from decoder: Decoder) throws {
        try requireInvestigationKeys(decoder, allowed: ["id", "title", "createdAt", "updatedAt", "blocks"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        blocks = try values.decode([StoredInvestigationBlock].self, forKey: .blocks)
        guard isValid else { throw InvestigationStoreError.read }
    }
}

struct StoredInvestigations: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int
    var documents: [StoredInvestigation]

    init(version: Int = Self.currentVersion, documents: [StoredInvestigation] = []) {
        self.version = version
        self.documents = documents
    }

    var isValid: Bool {
        version == Self.currentVersion && documents.count <= InvestigationLimits.maximumDocuments &&
        Set(documents.map(\.id)).count == documents.count && documents.allSatisfy(\.isValid) &&
        documents.reduce(0, { $0 + $1.textBytes }) <= InvestigationLimits.maximumLibraryBytes
    }

    private enum CodingKeys: String, CodingKey { case version, documents }

    init(from decoder: Decoder) throws {
        try requireInvestigationKeys(decoder, allowed: ["version", "documents"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw InvestigationStoreError.read }
        documents = try values.decode([StoredInvestigation].self, forKey: .documents)
        guard isValid else { throw InvestigationStoreError.read }
    }
}

private struct InvestigationCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireInvestigationKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: InvestigationCodingKey.self)
    guard Set(values.allKeys.map(\.stringValue)).isSubset(of: allowed) else { throw InvestigationStoreError.read }
}

protocol InvestigationStore: Sendable {
    func load() async throws -> StoredInvestigations
    func save(_ value: StoredInvestigations) async throws
}

actor MemoryInvestigationStore: InvestigationStore {
    private var snapshot: StoredInvestigations
    init(snapshot: StoredInvestigations = StoredInvestigations()) { self.snapshot = snapshot }
    func load() throws -> StoredInvestigations {
        guard snapshot.isValid else { throw InvestigationStoreError.read }
        return snapshot
    }
    func save(_ value: StoredInvestigations) throws {
        guard value.isValid else { throw InvestigationStoreError.invalid }
        snapshot = value
    }
}

enum InvestigationWriteStage: CaseIterable, Equatable, Sendable {
    case temporaryCreated, written, synchronized, verified, publication
}

/// A single private library publishes all records in one atomic rename. A lock
/// also fences separate actors or app processes using the same local library.
actor FileInvestigationStore: InvestigationStore {
    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DBeer/Investigations/library.json")
    }

    let fileURL: URL
    private let writeInterceptor: (@Sendable (InvestigationWriteStage) throws -> Void)?

    init(fileURL: URL = FileInvestigationStore.defaultFileURL,
         writeInterceptor: (@Sendable (InvestigationWriteStage) throws -> Void)? = nil) {
        self.fileURL = fileURL.standardizedFileURL
        self.writeInterceptor = writeInterceptor
    }

    func load() throws -> StoredInvestigations {
        do {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                // A broken symlink or unreadable existing node must not be
                // mistaken for an absent, safely replaceable library.
                var metadata = stat()
                guard lstat(fileURL.path, &metadata) != 0, errno == ENOENT else { throw InvestigationStoreError.read }
                if FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path) {
                    try cleanupInterruptedTemporaries()
                }
                return StoredInvestigations()
            }
            let value = try decode(readExisting())
            try cleanupInterruptedTemporaries()
            return value
        } catch { throw InvestigationStoreError.read }
    }

    func save(_ value: StoredInvestigations) throws {
        do {
            guard value.isValid else { throw InvestigationStoreError.invalid }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(value)
            guard data.count <= InvestigationLimits.maximumLibraryBytes else { throw InvestigationStoreError.invalid }
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directoryFD >= 0 else { throw InvestigationStoreError.write }
            defer { close(directoryFD) }
            guard fchmod(directoryFD, 0o700) == 0 else { throw InvestigationStoreError.write }
            let lockURL = directory.appendingPathComponent(".library.lock")
            let lockFD = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard lockFD >= 0 else { throw InvestigationStoreError.write }
            defer { flock(lockFD, LOCK_UN); close(lockFD) }
            var lockMetadata = stat()
            guard fstat(lockFD, &lockMetadata) == 0, lockMetadata.st_mode & S_IFMT == S_IFREG,
                  fchmod(lockFD, 0o600) == 0, flock(lockFD, LOCK_EX) == 0 else { throw InvestigationStoreError.write }
            var metadata = stat()
            if lstat(fileURL.path, &metadata) == 0 { _ = try decode(readExisting()) }
            else if errno != ENOENT { throw InvestigationStoreError.write }
            try removeInterruptedTemporaries(in: directory)
            try write(data, directory: directory, directoryFD: directoryFD)
        } catch let error as InvestigationStoreError where error == .invalid { throw error }
        catch { throw InvestigationStoreError.write }
    }

    private func readExisting() throws -> Data {
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw InvestigationStoreError.read }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= InvestigationLimits.maximumLibraryBytes else {
            throw InvestigationStoreError.read
        }
        let data = try handle.read(upToCount: InvestigationLimits.maximumLibraryBytes + 1) ?? Data()
        guard data.count <= InvestigationLimits.maximumLibraryBytes else { throw InvestigationStoreError.read }
        return data
    }

    private func decode(_ data: Data) throws -> StoredInvestigations {
        guard data.count <= InvestigationLimits.maximumLibraryBytes else { throw InvestigationStoreError.read }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = try decoder.decode(StoredInvestigations.self, from: data)
        guard value.isValid else { throw InvestigationStoreError.read }
        return value
    }

    private func removeInterruptedTemporaries(in directory: URL) throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix(".investigation-") && url.pathExtension == "tmp" {
            // Never follow interrupted files or interpret their contents.
            guard unlink(url.path) == 0 || errno == ENOENT else { throw InvestigationStoreError.write }
        }
    }

    private func cleanupInterruptedTemporaries() throws {
        let directory = fileURL.deletingLastPathComponent()
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw InvestigationStoreError.read }
        defer { close(directoryFD) }
        let lockURL = directory.appendingPathComponent(".library.lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw InvestigationStoreError.read }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              fchmod(descriptor, 0o600) == 0, flock(descriptor, LOCK_EX) == 0 else { throw InvestigationStoreError.read }
        try removeInterruptedTemporaries(in: directory)
    }

    private func write(_ data: Data, directory: URL, directoryFD: Int32) throws {
        let temporary = directory.appendingPathComponent(".investigation-\(UUID().uuidString).tmp")
        defer { unlink(temporary.path) }
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw InvestigationStoreError.write }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try writeInterceptor?(.temporaryCreated)
        try handle.write(contentsOf: data)
        try writeInterceptor?(.written)
        try handle.synchronize()
        try writeInterceptor?(.synchronized)
        try handle.close()
        guard try Data(contentsOf: temporary) == data else { throw InvestigationStoreError.write }
        try writeInterceptor?(.verified)
        // Verify that directory synchronization is supported before publication;
        // all throwing stages occur while the previous library is still intact.
        guard fsync(directoryFD) == 0 else { throw InvestigationStoreError.write }
        try writeInterceptor?(.publication)
        guard rename(temporary.path, fileURL.path) == 0 else { throw InvestigationStoreError.write }
        // Publication is the commit point. A subsequent directory-sync failure
        // cannot truthfully be reported as an unchanged failed write.
        _ = fsync(directoryFD)
    }
}
