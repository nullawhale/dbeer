import Darwin
import Foundation

/// Explicit user artifacts retain only the SQL and evidence from the original
/// Explain operation. Runtime ownership and connection settings are excluded.
struct PlanArtifact: Codable, Equatable, Sendable, Identifiable {
    static let currentVersion = 1
    static let maximumBytes = 16 * 1_024 * 1_024
    var version = Self.currentVersion
    var id: UUID
    var title: String
    var capturedAt: Date
    var profileName: String?
    var environment: ConnectionEnvironment? = nil
    var sourceWasStale: Bool? = nil
    var request: ExplainRequest
    var result: ExplainResult
    var baselineName: String?

    var valid: Bool {
        version == Self.currentVersion && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        title.utf8.count <= 16_384 && !title.contains("\0") && capturedAt.timeIntervalSince1970.isFinite &&
        (profileName?.utf8.count ?? 0) <= 16_384 && profileName?.contains("\0") != true && (baselineName?.utf8.count ?? 0) <= 16_384 &&
        baselineName?.contains("\0") != true && request.valid && result.valid && exactTopology && request.mode == result.mode
    }

    private var exactTopology: Bool {
        let indexed = Dictionary(uniqueKeysWithValues: result.nodes.map { (Data($0.id.utf8), $0) })
        var seen = Set<Data>()
        var pending = result.roots.map { (Data($0.utf8), 1) }
        while let (id, depth) = pending.popLast() {
            guard depth <= 128, let node = indexed[id], seen.insert(id).inserted else { return false }
            pending.append(contentsOf: node.children.map { (Data($0.utf8), depth + 1) })
        }
        return seen.count == result.nodes.count
    }


    var displayPlan: ExplainPlanModel {
        var plan = ExplainPlanModel(request: request, sourceText: request.sql,
            sourceRange: NSRange(location: 0, length: (request.sql as NSString).length), profileID: UUID())
        plan.result = result
        plan.status = "Saved \(capturedAt.formatted(date: .abbreviated, time: .shortened))" + (sourceWasStale == true ? " · earlier query or connection at save" : "")
        return plan
    }

    func encoded() throws -> String {
        guard valid else { throw PlanArtifactError.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.maximumBytes, let text = String(data: bytes, encoding: .utf8) else {
            throw PlanArtifactError.invalid
        }
        return text
    }

    static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= maximumBytes else { throw PlanArtifactError.invalid }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let artifact = try decoder.decode(Self.self, from: Data(text.utf8))
        guard artifact.valid else { throw PlanArtifactError.invalid }
        return artifact
    }
}

struct PlanArtifactSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let capturedAt: Date
    let profileName: String?
    let engine: DatabaseEngine
    let mode: ExplainMode
    let complete: Bool
    let baselineName: String?
    var isAvailable = true
    init(_ artifact: PlanArtifact) {
        id = artifact.id; title = artifact.title; capturedAt = artifact.capturedAt
        profileName = artifact.profileName; engine = artifact.result.support.engine
        mode = artifact.request.mode; complete = artifact.result.complete; baselineName = artifact.baselineName
    }
    init(unavailableID: UUID) {
        id = unavailableID; title = "Unavailable execution plan"; capturedAt = .distantPast
        profileName = nil; engine = .postgresql; mode = .plan; complete = false; baselineName = nil
        isAvailable = false
    }
}

enum PlanArtifactError: LocalizedError, Equatable {
    case invalid, unavailable, changed, quota, referenced
    var errorDescription: String? {
        switch self {
        case .invalid: "The saved execution plan is invalid, damaged, or exceeds the supported limits."
        case .unavailable: "Execution plan storage is unavailable. Existing artifacts have been kept."
        case .changed: "The execution plan changed on disk. Refresh before trying again."
        case .quota: "The execution plan storage limit has been reached. Delete an unneeded plan explicitly."
        case .referenced: "This execution plan is referenced by a snapshot or investigation. Remove those links before deleting it."
        }
    }
}

struct PlanSnapshotLink: Codable, Equatable, Hashable, Sendable {
    var snapshotID: UUID
    var planID: UUID
}

struct EvidenceSnapshotLink: Codable, Equatable, Hashable, Sendable {
    var snapshotID: UUID
    var evidence: SavedEvidenceReference
}

private struct PlanSnapshotLinks: Codable {
    var version = 1
    var links: [PlanSnapshotLink] = []
    var evidenceLinks: [EvidenceSnapshotLink] = []
    var valid: Bool {
        (version == 1 && evidenceLinks.isEmpty || version == 2) && links.count + evidenceLinks.count <= 16_384 &&
            Set(links).count == links.count && Set(evidenceLinks).count == evidenceLinks.count
    }
    private enum CodingKeys: String, CodingKey { case version, links, evidenceLinks }
    init() {}
    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        version = try fields.decode(Int.self, forKey: .version)
        links = try fields.decode([PlanSnapshotLink].self, forKey: .links)
        evidenceLinks = try fields.decodeIfPresent([EvidenceSnapshotLink].self, forKey: .evidenceLinks) ?? []
        guard valid, version == 2 || !fields.contains(.evidenceLinks) else { throw PlanArtifactError.invalid }
    }
    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(version, forKey: .version); try fields.encode(links, forKey: .links)
        if version == 2 { try fields.encode(evidenceLinks, forKey: .evidenceLinks) }
    }
}

/// Files are independently published through the existing inode/content guarded
/// file boundary. A private lock serializes inventory, metadata and attachment
/// updates across actors/processes. Raw and normalized evidence is immutable.
actor PlanArtifactStore {
    static let maximumArtifacts = 4_096
    static let quotaBytes = 256 * 1_024 * 1_024
    static var defaultRootURL: URL {
        ResultSnapshotStore.defaultRootURL.deletingLastPathComponent().appendingPathComponent("ExecutionPlans", isDirectory: true)
    }
    let rootURL: URL
    private var lockedRootIdentity: SQLFileIdentity?
    init(rootURL: URL = PlanArtifactStore.defaultRootURL) { self.rootURL = rootURL.standardizedFileURL }










    func removeSnapshotLinks(_ id: UUID) throws {
        try withRoot {
            var value = try readLinks()
            guard value.links.contains(where: { $0.snapshotID == id }) || value.evidenceLinks.contains(where: { $0.snapshotID == id }) else { return }
            value.links.removeAll { $0.snapshotID == id }
            value.evidenceLinks.removeAll { $0.snapshotID == id }
            try writeLinks(value)
        }
    }

    private func deleteReviewedFile(_ url: URL) throws {
        let originalVersion = try SQLFileBinding.version(of: url, maximumBytes: PlanArtifact.maximumBytes, expectedParent: lockedRootIdentity)
        let directory = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw PlanArtifactError.unavailable }
        defer { close(directory) }
        var actual = stat()
        guard fstat(directory, &actual) == 0,
              lockedRootIdentity == SQLFileIdentity(device: UInt64(bitPattern: Int64(actual.st_dev)), inode: UInt64(actual.st_ino)) else { throw PlanArtifactError.changed }
        // Move the exact reviewed file aside before unlinking it. A racing
        // external replacement is retained under its original pathname.
        let name = url.lastPathComponent
        let temporary = ".delete-\(UUID().uuidString)"
        guard renameatx_np(directory, name, directory, temporary, UInt32(RENAME_EXCL)) == 0 else { throw PlanArtifactError.changed }
        let temporaryURL = rootURL.appendingPathComponent(temporary)
        guard let retained = try? SQLFileBinding.version(of: temporaryURL, maximumBytes: PlanArtifact.maximumBytes, expectedParent: lockedRootIdentity), retained == originalVersion else {
            guard renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0 else { throw SQLFileBindingError.recovery(temporaryURL) }
            throw PlanArtifactError.changed
        }
        guard unlinkat(directory, temporary, 0) == 0 else {
            guard renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0 else { throw SQLFileBindingError.recovery(temporaryURL) }
            throw PlanArtifactError.unavailable
        }
        _ = fsync(directory)
    }

    private func file(_ id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString.lowercased() + ".dbeerplan") }
    private var linksURL: URL { rootURL.appendingPathComponent("attachments.json") }

    private func read(_ id: UUID) throws -> (artifact: PlanArtifact, version: SQLFileVersion, byteCount: Int) {
        let loaded = try SQLFileBinding.read(file(id), maximumBytes: PlanArtifact.maximumBytes, expectedParent: lockedRootIdentity)
        let artifact = try PlanArtifact.decode(loaded.text)
        guard artifact.id == id else { throw PlanArtifactError.invalid }
        return (artifact, loaded.version, loaded.text.utf8.count)
    }

    private func artifactFiles() throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil).filter { url in
            guard url.pathExtension == "dbeerplan", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return false }
            return url.lastPathComponent == file(id).lastPathComponent
        }
        guard files.count <= Self.maximumArtifacts else { throw PlanArtifactError.quota }
        return files
    }

    private func inventory() throws -> [PlanArtifactSummary] {
        try artifactFiles().map { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw PlanArtifactError.invalid }
            return (try? read(id).artifact).map(PlanArtifactSummary.init) ?? PlanArtifactSummary(unavailableID: id)
        }
    }

    private func readLinks() throws -> PlanSnapshotLinks {
        var info = stat()
        guard lstat(linksURL.path, &info) == 0 else {
            guard errno == ENOENT else { throw PlanArtifactError.unavailable }
            return PlanSnapshotLinks()
        }
        let loaded = try SQLFileBinding.read(linksURL, maximumBytes: 2 * 1_024 * 1_024, expectedParent: lockedRootIdentity)
        let data = Data(loaded.text.utf8)
        try ExactJSONKeys.validate(data, maximumBytes: 2 * 1_024 * 1_024)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "links", "evidenceLinks"]),
              !object.values.contains(where: { $0 is NSNull }) else { throw PlanArtifactError.invalid }
        let value = try JSONDecoder().decode(PlanSnapshotLinks.self, from: data)
        guard value.valid else { throw PlanArtifactError.invalid }
        return value
    }

    private func writeLinks(_ value: PlanSnapshotLinks) throws {
        guard value.valid else { throw PlanArtifactError.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(value), as: UTF8.self)
        guard text.utf8.count <= 2 * 1_024 * 1_024 else { throw PlanArtifactError.quota }
        var info = stat()
        let previous: SQLFileVersion?
        if lstat(linksURL.path, &info) == 0 { previous = try SQLFileBinding.read(linksURL, maximumBytes: 2 * 1_024 * 1_024, expectedParent: lockedRootIdentity).version }
        else { guard errno == ENOENT else { throw PlanArtifactError.unavailable }; previous = nil }
        _ = try SQLFileBinding.write(text, to: linksURL, expectedVersion: previous, expectedParent: lockedRootIdentity, maximumBytes: 2 * 1_024 * 1_024)
    }

    private func withRoot<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw PlanArtifactError.unavailable }
        defer { close(directory) }
        var metadata = stat()
        guard fstat(directory, &metadata) == 0, metadata.st_uid == geteuid(), fchmod(directory, 0o700) == 0 else { throw PlanArtifactError.unavailable }
        let identity = SQLFileIdentity(device: UInt64(bitPattern: Int64(metadata.st_dev)), inode: UInt64(metadata.st_ino))
        let lock = openat(directory, ".library.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw PlanArtifactError.unavailable }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard fstat(lock, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
              metadata.st_nlink == 1, fchmod(lock, 0o600) == 0, flock(lock, LOCK_EX) == 0 else { throw PlanArtifactError.unavailable }
        var actual = stat()
        guard lstat(rootURL.path, &actual) == 0, UInt64(bitPattern: Int64(actual.st_dev)) == identity.device, UInt64(actual.st_ino) == identity.inode else { throw PlanArtifactError.unavailable }
        lockedRootIdentity = identity
        defer { lockedRootIdentity = nil }
        return try operation()
    }
}

/// Only this exact local scheme and UUID authority constitute artifact links.
/// Arbitrary web URLs and partial text matches never become dependencies.
enum PlanArtifactReference {
    static func url(_ id: UUID) -> URL { URL(string: "dbeer-plan://" + id.uuidString.lowercased())! }
    static func id(from url: URL) -> UUID? {
        guard url.scheme == "dbeer-plan", url.path.isEmpty, url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host, let id = UUID(uuidString: host), host == id.uuidString.lowercased() else { return nil }
        return id
    }
    static func markdown(id: UUID, title: String) -> String {
        let escaped = title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return "[\(escaped)](\(url(id).absoluteString))"
    }
    static func ids(in text: String) -> Set<UUID> {
        guard let rendered = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full)) else { return [] }
        return Set(rendered.runs.compactMap { $0.link.flatMap(id(from:)) })
    }
}

extension PlanArtifactStore {
    private func evidenceFile(_ id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString.lowercased() + ".dbeerevidence") }
    private func evidenceFiles() throws -> [URL] {
        let values = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil).filter { url in
            url.pathExtension == "dbeerevidence" && UUID(uuidString: url.deletingPathExtension().lastPathComponent).map {
                url.lastPathComponent == evidenceFile($0).lastPathComponent
            } == true
        }
        guard values.count <= Self.maximumArtifacts else { throw PlanArtifactError.quota }
        return values
    }
    private func allArtifactFiles() throws -> [URL] {
        let values = try artifactFiles() + evidenceFiles()
        guard values.count <= Self.maximumArtifacts else { throw PlanArtifactError.quota }
        return values
    }
    private func readEvidence(_ id: UUID) throws -> SavedEvidenceArtifact {
        let loaded = try SQLFileBinding.read(evidenceFile(id), maximumBytes: SavedEvidenceArtifact.maximumBytes, expectedParent: lockedRootIdentity)
        let artifact = try SavedEvidenceArtifact.decode(loaded.text)
        guard artifact.id == id else { throw PlanArtifactError.invalid }
        return artifact
    }
    func listEvidence() throws -> [SavedEvidenceSummary] {
        try withRoot { try evidenceFiles().map { file in
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { throw PlanArtifactError.invalid }
            return (try? readEvidence(id)).map(SavedEvidenceSummary.init) ?? SavedEvidenceSummary(unavailable: id)
        }.sorted { $0.savedAt > $1.savedAt } }
    }
    func loadEvidence(_ id: UUID, kind: SavedEvidenceKind? = nil) throws -> SavedEvidenceArtifact {
        try withRoot {
            let value = try readEvidence(id)
            guard kind == nil || kind == value.kind else { throw PlanArtifactError.invalid }
            return value
        }
    }
    func saveEvidence(_ artifact: SavedEvidenceArtifact) throws -> SavedEvidenceArtifact {
        try withRoot {
            let files = try allArtifactFiles()
            guard files.count < Self.maximumArtifacts else { throw PlanArtifactError.quota }
            let text = try artifact.encoded()
            let used = try files.reduce(0) { sum, url in
                sum + (try SQLFileBinding.read(url, maximumBytes: PlanArtifact.maximumBytes, expectedParent: lockedRootIdentity)).text.utf8.count
            }
            guard used <= Self.quotaBytes - text.utf8.count else { throw PlanArtifactError.quota }
            _ = try SQLFileBinding.write(text, to: evidenceFile(artifact.id), expectedVersion: nil,
                expectedParent: lockedRootIdentity, maximumBytes: SavedEvidenceArtifact.maximumBytes)
            return artifact
        }
    }
    func importEvidence(from url: URL) throws -> SavedEvidenceArtifact {
        let loaded = try SQLFileBinding.read(url, maximumBytes: SavedEvidenceArtifact.maximumBytes)
        var value = try SavedEvidenceArtifact.decode(loaded.text); value.id = UUID()
        return try saveEvidence(value)
    }
    func deleteEvidence(id: UUID, investigationIDs: Set<UUID>) throws {
        try withRoot {
            guard investigationIDs.isEmpty, !(try readLinks()).evidenceLinks.contains(where: { $0.evidence.id == id }) else { throw PlanArtifactError.referenced }
            try deleteReviewedFile(evidenceFile(id))
        }
    }
    func evidenceLinks(snapshotID: UUID? = nil) throws -> [EvidenceSnapshotLink] {
        try withRoot { try readLinks().evidenceLinks.filter { snapshotID == nil || $0.snapshotID == snapshotID } }
    }
    func attachEvidence(_ reference: SavedEvidenceReference, snapshotID: UUID) throws {
        try withRoot {
            guard try readEvidence(reference.id).kind == reference.kind else { throw PlanArtifactError.invalid }
            var value = try readLinks()
            let link = EvidenceSnapshotLink(snapshotID: snapshotID, evidence: reference)
            guard !value.evidenceLinks.contains(link) else { return }
            value.version = 2; value.evidenceLinks.append(link); try writeLinks(value)
        }
    }
    func detachEvidence(_ reference: SavedEvidenceReference, snapshotID: UUID) throws {
        try withRoot {
            var value = try readLinks()
            value.evidenceLinks.removeAll { $0.snapshotID == snapshotID && $0.evidence == reference }
            try writeLinks(value)
        }
    }
}
