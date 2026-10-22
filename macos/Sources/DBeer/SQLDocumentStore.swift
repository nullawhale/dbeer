import Darwin
import Foundation

enum StoredWorkspaceDocumentKind: String, Codable, Sendable { case sql, table }

struct StoredTableDocument: Codable, Equatable, Sendable {
    var reference: TableReference
    var page: Int
    var filters: [CatalogFilter]
    var sort: [CatalogSort]

    init(reference: TableReference, page: Int = 0, filters: [CatalogFilter] = [], sort: [CatalogSort] = []) {
        self.reference = reference
        self.page = page
        self.filters = filters
        self.sort = sort
    }

    var isValid: Bool {
        func validName(_ name: String) -> Bool { !name.isEmpty && name.utf8.count <= 1_024 && !name.contains("\0") }
        guard validName(reference.schema), validName(reference.name), ["table", "view"].contains(reference.kind),
              (0...1_000_000).contains(page), filters.count <= 32, sort.count <= 32,
              sort.allSatisfy({ validName($0.column) && ["asc", "desc"].contains($0.direction) }) else { return false }
        return filters.allSatisfy { filter in
            guard validName(filter.column) else { return false }
            switch filter.operator {
            case "eq", "ne", "lt", "lte", "gt", "gte", "contains":
                return filter.value.map { $0.utf8.count <= 1_024 * 1_024 && !$0.contains("\0") } == true
            case "isNull", "isNotNull": return filter.value == nil
            default: return false
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case reference, page, filters, sort }

    init(from decoder: Decoder) throws {
        try requireWorkspaceKeys(decoder, allowed: ["reference", "page", "filters", "sort"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let referenceDecoder = try values.superDecoder(forKey: .reference)
        try requireWorkspaceKeys(referenceDecoder, allowed: ["schema", "name", "kind"])
        reference = try TableReference(from: referenceDecoder)
        page = try values.decode(Int.self, forKey: .page)
        filters = try values.decode([CatalogFilter].self, forKey: .filters)
        sort = try values.decode([CatalogSort].self, forKey: .sort)
        // Reject unknown operational fields rather than silently dropping them
        // before the next autosave of a newer document format.
        var filterValues = try values.nestedUnkeyedContainer(forKey: .filters)
        while !filterValues.isAtEnd {
            try requireWorkspaceKeys(filterValues.superDecoder(), allowed: ["column", "operator", "value"])
        }
        var sortValues = try values.nestedUnkeyedContainer(forKey: .sort)
        while !sortValues.isAtEnd { try requireWorkspaceKeys(sortValues.superDecoder(), allowed: ["column", "direction"]) }
    }
}

struct StoredSQLDocument: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var text: String
    var profileID: UUID?
    var kind: StoredWorkspaceDocumentKind
    var table: StoredTableDocument?
    var fileURL: URL?
    var fileContentSHA256: String?
    var fileDocumentID: UUID?
    var fileRecoveryURL: URL?

    init(id: UUID = UUID(), title: String, text: String, profileID: UUID? = nil,
         kind: StoredWorkspaceDocumentKind = .sql, table: StoredTableDocument? = nil,
         fileURL: URL? = nil, fileContentSHA256: String? = nil, fileDocumentID: UUID? = nil, fileRecoveryURL: URL? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.profileID = profileID
        self.kind = kind
        self.table = table
        self.fileURL = fileURL
        self.fileContentSHA256 = fileContentSHA256
        self.fileDocumentID = fileURL.map { _ in fileDocumentID ?? id }
        self.fileRecoveryURL = fileRecoveryURL
    }

    var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch kind {
        case .sql:
            guard table == nil else { return false }
        case .table:
            guard table?.isValid == true, fileURL == nil, fileContentSHA256 == nil, fileDocumentID == nil,
                  fileRecoveryURL == nil else { return false }
        }
        guard fileDocumentID == nil || fileURL != nil else { return false }
        if let fileRecoveryURL {
            guard SQLFileBinding.isLocalFile(fileRecoveryURL), fileRecoveryURL.path.utf8.count <= 4_096 else { return false }
        }
        if let fileURL {
            guard fileURL.isFileURL, fileURL.path.hasPrefix("/"), fileURL.path.utf8.count <= 4_096,
                  fileURL.path != "/", !fileURL.hasDirectoryPath, !fileURL.lastPathComponent.isEmpty,
                  !fileURL.path.contains("\0"), fileURL.host?.isEmpty != false || fileURL.host?.lowercased() == "localhost",
                  fileURL.user == nil, fileURL.password == nil, fileURL.port == nil,
                  fileURL.query == nil, fileURL.fragment == nil else { return false }
        }
        if let digest = fileContentSHA256 {
            guard fileURL != nil, digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, text, profileID, kind, table, fileURL, fileContentSHA256, fileDocumentID, fileRecoveryURL
    }

    init(from decoder: Decoder) throws {
        try requireWorkspaceKeys(decoder, allowed: ["id", "title", "text", "profileID", "kind", "table", "fileURL", "fileContentSHA256", "fileDocumentID", "fileRecoveryURL"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        text = try values.decode(String.self, forKey: .text)
        profileID = try values.decodeIfPresent(UUID.self, forKey: .profileID)
        kind = try values.decode(StoredWorkspaceDocumentKind.self, forKey: .kind)
        table = try values.decodeIfPresent(StoredTableDocument.self, forKey: .table)
        fileURL = try values.decodeIfPresent(URL.self, forKey: .fileURL)
        fileContentSHA256 = try values.decodeIfPresent(String.self, forKey: .fileContentSHA256)
        fileDocumentID = try values.decodeIfPresent(UUID.self, forKey: .fileDocumentID) ?? fileURL.map { _ in id }
        fileRecoveryURL = try values.decodeIfPresent(URL.self, forKey: .fileRecoveryURL)
    }
}

private struct LegacyStoredSQLDocument: Decodable {
    let document: StoredSQLDocument

    private enum CodingKeys: String, CodingKey { case id, title, text, profileID }

    init(from decoder: Decoder) throws {
        try requireWorkspaceKeys(decoder, allowed: ["id", "title", "text", "profileID"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        document = StoredSQLDocument(id: try values.decode(UUID.self, forKey: .id),
            title: try values.decode(String.self, forKey: .title), text: try values.decode(String.self, forKey: .text),
            profileID: try values.decodeIfPresent(UUID.self, forKey: .profileID))
    }
}

private struct WorkspaceCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireWorkspaceKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: WorkspaceCodingKey.self)
    guard Set(values.allKeys.map(\.stringValue)).isSubset(of: allowed) else { throw SQLDocumentStoreError.read }
}

/// Contains documents and history only. Sessions, results and passwords never
/// enter the format; restoring the snapshot cannot reconnect or execute SQL.
struct SQLWorkspaceSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 5
    static let historyLimit = 1_000
    static let historyRetention: TimeInterval = 30 * 24 * 60 * 60

    private(set) var version: Int
    var documents: [StoredSQLDocument]
    var selectedDocumentID: UUID?
    var history: [SQLHistoryEntry]
    var historyEnabled: Bool
    var historySettings: SQLHistoryRetentionSettings
    var sqlFolders: [SQLFolderAttachment]

    init(documents: [StoredSQLDocument] = [], selectedDocumentID: UUID? = nil,
         history: [SQLHistoryEntry] = [], historyEnabled: Bool = true,
         historySettings: SQLHistoryRetentionSettings = .default, sqlFolders: [SQLFolderAttachment] = []) {
        version = Self.currentVersion
        self.documents = documents
        self.selectedDocumentID = selectedDocumentID
        self.history = history
        self.historyEnabled = historyEnabled
        self.historySettings = historySettings
        self.sqlFolders = sqlFolders
    }

    private enum CodingKeys: String, CodingKey { case version, documents, selectedDocumentID, history, historyEnabled, historySettings, sqlFolders }

    init(from decoder: Decoder) throws {
        try requireWorkspaceKeys(decoder, allowed: ["version", "documents", "selectedDocumentID", "history", "historyEnabled", "historySettings", "sqlFolders"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = values.contains(.version) ? try values.decode(Int.self, forKey: .version) : 0
        guard (0...Self.currentVersion).contains(version) else { throw SQLDocumentStoreError.read }
        if version < 5, values.contains(.sqlFolders) { throw SQLDocumentStoreError.read }
        sqlFolders = version >= 5 ? try values.decode([SQLFolderAttachment].self, forKey: .sqlFolders) : []
        documents = version < 4
            ? try values.decode([LegacyStoredSQLDocument].self, forKey: .documents).map(\.document)
            : try values.decode([StoredSQLDocument].self, forKey: .documents)
        selectedDocumentID = try values.decodeIfPresent(UUID.self, forKey: .selectedDocumentID)
        if version < 4, let selectedDocumentID, !documents.contains(where: { $0.id == selectedDocumentID }) {
            // Old snapshots omitted table tabs but could still name one as
            // selected. Preserve the available SQL drafts during migration.
            self.selectedDocumentID = documents.first?.id
        }
        history = try values.decodeIfPresent([SQLHistoryEntry].self, forKey: .history) ?? []
        if version < 2 {
            // Legacy status strings never established typed outcomes or timing,
            // even if one happens to match a new enum's spelling.
            history = history.map { SQLHistoryEntry(id: $0.id, date: $0.date, documentID: $0.documentID,
                profileID: $0.profileID, sql: $0.sql, outcome: $0.legacyOutcome ?? $0.outcome.rawValue) }
        }
        historyEnabled = try values.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? true
        if version < 3 { historySettings = .default }
        else { historySettings = try values.decode(SQLHistoryRetentionSettings.self, forKey: .historySettings) }
        if version < 3 {
            history = history.map { entry in
                var migrated = entry
                migrated.isFavorite = false
                return migrated
            }
        }
    }

    mutating func record(_ entry: SQLHistoryEntry, now: Date = .now) {
        guard historyEnabled else { return }
        history.append(entry)
        trimHistory(now: now)
    }

    mutating func trimHistory(now: Date = .now) {
        guard historySettings.isValid else { return }
        let oldest = now.addingTimeInterval(-historySettings.retentionInterval)
        // Stable tie breaking preserves the order of commands in a script.
        // Favorites consume neither the age allowance nor the ordinary entry limit.
        var ordinaryCount = 0
        history = Array(history.enumerated().filter { $0.element.isFavorite || $0.element.date >= oldest }
            .sorted { lhs, rhs in lhs.element.date == rhs.element.date ? lhs.offset > rhs.offset : lhs.element.date > rhs.element.date }
            .filter { indexed in
                if indexed.element.isFavorite { return true }
                guard ordinaryCount < historySettings.maxEntries else { return false }
                ordinaryCount += 1
                return true
            }.map(\.element).reversed())
    }

    mutating func clearHistory(includeFavorites: Bool = false) {
        history.removeAll { includeFavorites || !$0.isFavorite }
    }
    mutating func clearDocuments() { documents.removeAll(); selectedDocumentID = nil }

    fileprivate func current(now: Date = .now) -> SQLWorkspaceSnapshot {
        var result = SQLWorkspaceSnapshot(documents: documents, selectedDocumentID: selectedDocumentID,
            history: history, historyEnabled: historyEnabled, historySettings: historySettings, sqlFolders: sqlFolders)
        result.trimHistory(now: now)
        return result
    }
}

enum SQLDocumentStoreError: LocalizedError {
    case read, write

    var errorDescription: String? {
        switch self {
        case .read: "SQL drafts and history could not be read. The existing file has been left unchanged."
        case .write: "SQL drafts and history could not be saved."
        }
    }
}

protocol SQLDocumentStore: Sendable {
    func load() async throws -> SQLWorkspaceSnapshot
    func save(_ snapshot: SQLWorkspaceSnapshot) async throws
}

actor MemorySQLDocumentStore: SQLDocumentStore {
    private var snapshot: SQLWorkspaceSnapshot
    init(snapshot: SQLWorkspaceSnapshot = SQLWorkspaceSnapshot()) { self.snapshot = snapshot }
    func load() -> SQLWorkspaceSnapshot { snapshot.current() }
    func save(_ snapshot: SQLWorkspaceSnapshot) { self.snapshot = snapshot.current() }
}

actor FileSQLDocumentStore: SQLDocumentStore {
    let fileURL: URL

    init(fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
         .appendingPathComponent("DBeer/workspace.json")) {
        self.fileURL = fileURL
    }

    func load() throws -> SQLWorkspaceSnapshot {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return SQLWorkspaceSnapshot() }
        catch { throw SQLDocumentStoreError.read }
        do {
            let snapshot = try decode(data)
            let current = snapshot.current()
            if snapshot.version < SQLWorkspaceSnapshot.currentVersion {
                try backup(data, version: snapshot.version)
                try write(current)
            }
            return current
        } catch { throw SQLDocumentStoreError.read }
    }

    func save(_ snapshot: SQLWorkspaceSnapshot) throws {
        do {
            try validate(snapshot)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                let original = try decode(data)
                if original.version < SQLWorkspaceSnapshot.currentVersion { try backup(data, version: original.version) }
            }
            try write(snapshot.current())
        } catch { throw SQLDocumentStoreError.write }
    }

    private func decode(_ data: Data) throws -> SQLWorkspaceSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(SQLWorkspaceSnapshot.self, from: data)
        try validate(snapshot)
        return snapshot
    }

    private func validate(_ snapshot: SQLWorkspaceSnapshot) throws {
        guard Set(snapshot.documents.map(\.id)).count == snapshot.documents.count,
              Set(snapshot.history.map(\.id)).count == snapshot.history.count,
              snapshot.historySettings.isValid,
              snapshot.documents.allSatisfy(\.isValid),
              snapshot.selectedDocumentID.map({ id in snapshot.documents.contains { $0.id == id } }) != false,
              snapshot.history.allSatisfy(\.isValid) else { throw SQLDocumentStoreError.read }
        guard snapshot.sqlFolders.count <= 32, Set(snapshot.sqlFolders.map(\.id)).count == snapshot.sqlFolders.count,
              Set(snapshot.sqlFolders.map { $0.url.standardizedFileURL }).count == snapshot.sqlFolders.count,
              snapshot.sqlFolders.allSatisfy(\.isValid) else { throw SQLDocumentStoreError.read }
        var files: [UUID: StoredSQLDocument] = [:]
        for document in snapshot.documents {
            guard let id = document.fileDocumentID else { continue }
            if let previous = files[id] {
                guard previous.fileURL == document.fileURL, previous.fileContentSHA256 == document.fileContentSHA256,
                      previous.fileRecoveryURL == document.fileRecoveryURL,
                      previous.text.utf8.elementsEqual(document.text.utf8) else { throw SQLDocumentStoreError.read }
            } else { files[id] = document }
        }
    }

    private func backup(_ data: Data, version: Int) throws {
        // Create the private file before writing any SQL or history bytes.
        let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".workspace-backup-\(UUID()).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SQLDocumentStoreError.write }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard try Data(contentsOf: temporary) == data else { throw SQLDocumentStoreError.write }
            // Publishing a hard link is atomic and never replaces another
            // backup, even if a destination appears after it was inspected.
            for attempt in 0..<8 {
                let suffix = attempt == 0 ? "v\(version).backup" : "v\(version)-\(UUID()).backup"
                let destination = fileURL.appendingPathExtension(suffix)
                if link(temporary.path, destination.path) == 0 { return }
                guard errno == EEXIST else { throw SQLDocumentStoreError.write }
            }
            throw SQLDocumentStoreError.write
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func write(_ snapshot: SQLWorkspaceSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".workspace-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(snapshot)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, fileURL.path) == 0 else { throw SQLDocumentStoreError.write }
    }
}
