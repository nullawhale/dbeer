import Darwin
import Foundation

struct StoredSQLDocument: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var text: String
    var profileID: UUID?

    init(id: UUID = UUID(), title: String, text: String, profileID: UUID? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.profileID = profileID
    }
}

struct SQLHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var date: Date
    var documentID: UUID?
    var profileID: UUID?
    var sql: String
    var outcome: String

    init(id: UUID = UUID(), date: Date = .now, documentID: UUID? = nil, profileID: UUID? = nil,
         sql: String, outcome: String) {
        self.id = id
        self.date = date
        self.documentID = documentID
        self.profileID = profileID
        self.sql = sql
        self.outcome = outcome
    }
}

/// Contains documents and history only. Sessions, results and passwords never
/// enter the format; restoring the snapshot cannot reconnect or execute SQL.
struct SQLWorkspaceSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let historyLimit = 1_000
    static let historyRetention: TimeInterval = 30 * 24 * 60 * 60

    private(set) var version: Int
    var documents: [StoredSQLDocument]
    var selectedDocumentID: UUID?
    var history: [SQLHistoryEntry]
    var historyEnabled: Bool

    init(documents: [StoredSQLDocument] = [], selectedDocumentID: UUID? = nil,
         history: [SQLHistoryEntry] = [], historyEnabled: Bool = true) {
        version = Self.currentVersion
        self.documents = documents
        self.selectedDocumentID = selectedDocumentID
        self.history = history
        self.historyEnabled = historyEnabled
    }

    private enum CodingKeys: String, CodingKey { case version, documents, selectedDocumentID, history, historyEnabled }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 0
        guard version == 0 || version == Self.currentVersion else { throw SQLDocumentStoreError.read }
        documents = try values.decode([StoredSQLDocument].self, forKey: .documents)
        selectedDocumentID = try values.decodeIfPresent(UUID.self, forKey: .selectedDocumentID)
        history = try values.decodeIfPresent([SQLHistoryEntry].self, forKey: .history) ?? []
        historyEnabled = try values.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? true
    }

    mutating func record(_ entry: SQLHistoryEntry, now: Date = .now) {
        guard historyEnabled else { return }
        history.append(entry)
        trimHistory(now: now)
    }

    mutating func trimHistory(now: Date = .now) {
        let oldest = now.addingTimeInterval(-Self.historyRetention)
        // Stable tie breaking preserves the order of commands in a script.
        history = Array(history.enumerated().filter { $0.element.date >= oldest }
            .sorted { lhs, rhs in lhs.element.date == rhs.element.date ? lhs.offset > rhs.offset : lhs.element.date > rhs.element.date }
            .prefix(Self.historyLimit).map(\.element).reversed())
    }

    mutating func clearHistory() { history.removeAll() }
    mutating func clearDocuments() { documents.removeAll(); selectedDocumentID = nil }

    fileprivate func current(now: Date = .now) -> SQLWorkspaceSnapshot {
        var result = SQLWorkspaceSnapshot(documents: documents, selectedDocumentID: selectedDocumentID,
            history: history, historyEnabled: historyEnabled)
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
                try backup(version: snapshot.version)
                try write(current)
            }
            return current
        } catch { throw SQLDocumentStoreError.read }
    }

    func save(_ snapshot: SQLWorkspaceSnapshot) throws {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let original = try decode(Data(contentsOf: fileURL))
                if original.version < SQLWorkspaceSnapshot.currentVersion { try backup(version: original.version) }
            }
            try validate(snapshot)
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
              snapshot.documents.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              snapshot.history.allSatisfy({ $0.date.timeIntervalSince1970.isFinite }) else { throw SQLDocumentStoreError.read }
    }

    private func backup(version: Int) throws {
        var destination = fileURL.appendingPathExtension("v\(version).backup")
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = fileURL.appendingPathExtension("v\(version)-\(UUID().uuidString).backup")
        }
        try FileManager.default.copyItem(at: fileURL, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
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
