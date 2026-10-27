import Combine
import Foundation

enum SQLLibraryScope: Equatable, Sendable, Codable {
    case allConnections
    case profile(UUID)
    case group(UUID)

    private enum Kind: String, Codable { case allConnections, profile, group }
    private enum CodingKeys: String, CodingKey { case kind, profileID, groupID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .allConnections:
            try requireSQLLibraryKeys(decoder, exactly: ["kind"])
            self = .allConnections
        case .profile:
            try requireSQLLibraryKeys(decoder, exactly: ["kind", "profileID"])
            self = .profile(try values.decode(UUID.self, forKey: .profileID))
        case .group:
            try requireSQLLibraryKeys(decoder, exactly: ["kind", "groupID"])
            self = .group(try values.decode(UUID.self, forKey: .groupID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allConnections: try values.encode(Kind.allConnections, forKey: .kind)
        case .profile(let id):
            try values.encode(Kind.profile, forKey: .kind)
            try values.encode(id, forKey: .profileID)
        case .group(let id):
            try values.encode(Kind.group, forKey: .kind)
            try values.encode(id, forKey: .groupID)
        }
    }
}

struct SQLProfileGroup: Identifiable, Equatable, Sendable, Codable {
    var id: UUID
    var name: String
    var profileIDs: [UUID]

    init(id: UUID = UUID(), name: String, profileIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.profileIDs = profileIDs
    }

    var isValid: Bool {
        validSQLLibraryLabel(name, maximumBytes: 256) && profileIDs.count <= 1_024 &&
            Set(profileIDs).count == profileIDs.count
    }

    private enum CodingKeys: String, CodingKey { case id, name, profileIDs }

    init(from decoder: Decoder) throws {
        try requireSQLLibraryKeys(decoder, exactly: ["id", "name", "profileIDs"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        profileIDs = try values.decode([UUID].self, forKey: .profileIDs)
        guard isValid else { throw SQLLibraryError.invalidGroup }
    }
}

/// The file remains the only source of SQL. This record contains local metadata
/// and opaque profile identities, never copied SQL or connection settings.
struct SQLLibraryEntry: Identifiable, Equatable, Sendable, Codable {
    var id: UUID
    var fileURL: URL
    var folder: String
    var tags: [String]
    var scope: SQLLibraryScope

    init(id: UUID = UUID(), fileURL: URL, folder: String = "", tags: [String] = [],
         scope: SQLLibraryScope = .allConnections) {
        self.id = id
        self.fileURL = fileURL.standardizedFileURL
        self.folder = folder
        self.tags = tags
        self.scope = scope
    }

    var isValid: Bool {
        guard SQLFileBinding.isLocalFile(fileURL), !fileURL.hasDirectoryPath,
              fileURL.path.utf8.count <= 4_096, fileURL.pathExtension.lowercased() == "sql",
              fileURL == fileURL.standardizedFileURL,
              folder.utf8.count <= 1_024, folder == normalizedSQLLibraryFolder(folder),
              tags.count <= 32, tags.allSatisfy({ validSQLLibraryLabel($0, maximumBytes: 128) }),
              Set(tags.map(sqlLibraryKey)).count == tags.count else { return false }
        let parts = folder.split(separator: "/")
        return parts.count <= 16 && parts.allSatisfy {
            $0 != "." && $0 != ".." && validSQLLibraryLabel(String($0), maximumBytes: 256)
        }
    }

    private enum CodingKeys: String, CodingKey { case id, fileURL, folder, tags, scope }

    init(from decoder: Decoder) throws {
        try requireSQLLibraryKeys(decoder, exactly: ["id", "fileURL", "folder", "tags", "scope"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        fileURL = try values.decode(URL.self, forKey: .fileURL)
        folder = try values.decode(String.self, forKey: .folder)
        tags = try values.decode([String].self, forKey: .tags)
        scope = try values.decode(SQLLibraryScope.self, forKey: .scope)
        guard isValid else { throw SQLLibraryError.invalidEntry }
    }
}

struct SQLLibrarySnapshot: Equatable, Sendable, Codable {
    var entries: [SQLLibraryEntry]
    var groups: [SQLProfileGroup]

    init(entries: [SQLLibraryEntry] = [], groups: [SQLProfileGroup] = []) {
        self.entries = entries
        self.groups = groups
    }

    var isValid: Bool {
        entries.count <= 5_000 && groups.count <= 256 && entries.allSatisfy(\.isValid) && groups.allSatisfy(\.isValid) &&
            Set(entries.map(\.id)).count == entries.count && Set(entries.map(\.fileURL)).count == entries.count &&
            Set(groups.map(\.id)).count == groups.count && Set(groups.map { sqlLibraryKey($0.name) }).count == groups.count
    }

    private enum CodingKeys: String, CodingKey { case entries, groups }

    init(from decoder: Decoder) throws {
        try requireSQLLibraryKeys(decoder, exactly: ["entries", "groups"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decode([SQLLibraryEntry].self, forKey: .entries)
        groups = try values.decode([SQLProfileGroup].self, forKey: .groups)
        guard isValid else { throw SQLLibraryError.invalidSnapshot }
    }
}

enum SQLLibraryError: LocalizedError {
    case invalidEntry, invalidGroup, invalidSnapshot, duplicateFile, duplicateGroupName, missingEntry, missingGroup

    var errorDescription: String? {
        switch self {
        case .invalidEntry: "Choose a local .sql file and valid folder and tags for the SQL library."
        case .invalidGroup: "Enter a group name and unique connection references within the group limits."
        case .invalidSnapshot: "The SQL library metadata is invalid or exceeds its limits. Existing metadata has been kept."
        case .duplicateFile: "This SQL file already has a library entry. Edit its existing metadata."
        case .duplicateGroupName: "A connection group with this name already exists."
        case .missingEntry: "This SQL library entry is no longer available."
        case .missingGroup: "This connection group is no longer available."
        }
    }
}

/// Local metadata only. Reading, observing and saving SQL use SQLFileDocument;
/// each SQL view separately chooses a concrete connection before execution.
@MainActor
final class SQLLibrary: ObservableObject {
    @Published private(set) var snapshot: SQLLibrarySnapshot
    @Published private(set) var error: String?

    init(snapshot: SQLLibrarySnapshot = SQLLibrarySnapshot()) {
        self.snapshot = snapshot.isValid ? snapshot : SQLLibrarySnapshot()
        error = snapshot.isValid ? nil : SQLLibraryError.invalidSnapshot.localizedDescription
    }

    @discardableResult
    func restore(_ saved: SQLLibrarySnapshot) -> Bool {
        guard saved.isValid else {
            error = SQLLibraryError.invalidSnapshot.localizedDescription
            return false
        }
        snapshot = saved
        error = nil
        return true
    }

    func entry(at url: URL) -> SQLLibraryEntry? { snapshot.entries.first { $0.fileURL == url.standardizedFileURL } }
    func entry(id: UUID) -> SQLLibraryEntry? { snapshot.entries.first { $0.id == id } }

    func allows(entry: SQLLibraryEntry, profileID: UUID) -> Bool {
        guard let current = self.entry(id: entry.id), current.fileURL == entry.fileURL else { return false }
        return switch current.scope {
        case .allConnections: true
        case .profile(let id): id == profileID
        case .group(let id): snapshot.groups.first { $0.id == id }?.profileIDs.contains(profileID) == true
        }
    }

    func filteredEntries(query: String = "", profileID: UUID? = nil, folder: String? = nil, tag: String? = nil) -> [SQLLibraryEntry] {
        let search = sqlLibraryKey(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let folder = folder.map { sqlLibraryKey(normalizedSQLLibraryFolder($0)) }
        let tag = tag.map(sqlLibraryKey)
        return snapshot.entries.filter { entry in
            if let profileID, !allows(entry: entry, profileID: profileID) { return false }
            if let folder, sqlLibraryKey(entry.folder) != folder { return false }
            if let tag, !entry.tags.contains(where: { sqlLibraryKey($0) == tag }) { return false }
            return search.isEmpty || [entry.fileURL.lastPathComponent, entry.fileURL.path, entry.folder]
                .joined(separator: " ").appending(" " + entry.tags.joined(separator: " "))
                .precomposedStringWithCanonicalMapping.lowercased().contains(search)
        }.sorted {
            let first = sqlLibraryKey($0.folder + "/" + $0.fileURL.lastPathComponent)
            let second = sqlLibraryKey($1.folder + "/" + $1.fileURL.lastPathComponent)
            return first == second ? $0.fileURL.path < $1.fileURL.path : first < second
        }
    }

    @discardableResult
    func upsertEntry(id: UUID? = nil, fileURL: URL, folder: String = "", tags: [String] = [],
                     scope: SQLLibraryScope = .allConnections) throws -> SQLLibraryEntry {
        do {
            if let id, !snapshot.entries.contains(where: { $0.id == id }) { throw SQLLibraryError.missingEntry }
            var seen: Set<String> = []
            let tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert(sqlLibraryKey($0)).inserted }
            let entry = SQLLibraryEntry(id: id ?? UUID(), fileURL: fileURL,
                folder: normalizedSQLLibraryFolder(folder), tags: tags, scope: scope)
            guard entry.isValid else { throw SQLLibraryError.invalidEntry }
            guard !snapshot.entries.contains(where: { $0.id != entry.id && $0.fileURL == entry.fileURL }) else {
                throw SQLLibraryError.duplicateFile
            }
            var updated = snapshot
            if let index = updated.entries.firstIndex(where: { $0.id == entry.id }) { updated.entries[index] = entry }
            else { updated.entries.append(entry) }
            try commit(updated)
            return entry
        } catch { self.error = error.localizedDescription; throw error }
    }

    func removeEntry(_ id: UUID) {
        var updated = snapshot
        updated.entries.removeAll { $0.id == id }
        snapshot = updated
        error = nil
    }

    @discardableResult
    func upsertGroup(id: UUID? = nil, name: String, profileIDs: [UUID]) throws -> SQLProfileGroup {
        do {
            if let id, !snapshot.groups.contains(where: { $0.id == id }) { throw SQLLibraryError.missingGroup }
            var seen: Set<UUID> = []
            let group = SQLProfileGroup(id: id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                profileIDs: profileIDs.filter { seen.insert($0).inserted })
            guard group.isValid else { throw SQLLibraryError.invalidGroup }
            guard !snapshot.groups.contains(where: { $0.id != group.id && sqlLibraryKey($0.name) == sqlLibraryKey(group.name) }) else {
                throw SQLLibraryError.duplicateGroupName
            }
            var updated = snapshot
            if let index = updated.groups.firstIndex(where: { $0.id == group.id }) { updated.groups[index] = group }
            else { updated.groups.append(group) }
            try commit(updated)
            return group
        } catch { self.error = error.localizedDescription; throw error }
    }

    func removeGroup(_ id: UUID) {
        var updated = snapshot
        updated.groups.removeAll { $0.id == id }
        // Keep scoped entries attached to the absent identity. They cannot
        // become globally executable merely because a group was removed.
        snapshot = updated
        error = nil
    }

    private func commit(_ updated: SQLLibrarySnapshot) throws {
        guard updated.isValid else { throw SQLLibraryError.invalidSnapshot }
        snapshot = updated
        error = nil
    }
}

private func sqlLibraryKey(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }

private func validSQLLibraryLabel(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) })
}

private func normalizedSQLLibraryFolder(_ value: String) -> String {
    value.split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }.joined(separator: "/")
}

private struct SQLLibraryCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireSQLLibraryKeys(_ decoder: Decoder, exactly allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: SQLLibraryCodingKey.self)
    guard Set(values.allKeys.map(\.stringValue)) == allowed else { throw SQLLibraryError.invalidSnapshot }
}
