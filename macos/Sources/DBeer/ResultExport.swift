import Darwin
import Foundation

struct ExportResultSet: Sendable {
    var columns: [ResultColumn]
    var rows: [[String?]]
    var commandTag: String
    var rowCount: Int64
    var displayedRowCount: Int
    var truncated: Bool

    init(columns: [ResultColumn], rows: [[String?]], commandTag: String = "",
         rowCount: Int64? = nil, truncated: Bool = false) {
        self.columns = columns
        self.rows = rows
        self.commandTag = commandTag
        self.rowCount = rowCount ?? Int64(rows.count)
        displayedRowCount = rows.count
        self.truncated = truncated
    }

    init(_ message: BackendMessage) {
        self.init(columns: message.columns ?? [], rows: message.rows ?? [], commandTag: message.commandTag ?? "",
            rowCount: message.rowCount, truncated: message.truncated == true)
    }
}

enum ResultExportError: LocalizedError {
    case nullMarker, nullCollision, malformed, write

    var errorDescription: String? {
        switch self {
        case .nullMarker: "Choose a nonempty NULL marker."
        case .nullCollision: "The NULL marker also occurs in a value. Choose a different marker before exporting."
        case .malformed: "The loaded result is invalid and could not be exported."
        case .write: "The export file could not be saved. The previous file has been left unchanged."
        }
    }
}

/// Loaded-result export never owns a database connection or executes SQL.
enum ResultExport {
    private struct Document: Encodable {
        let version = 1
        let resultSets: [Result]
    }

    private struct Result: Encodable {
        let metadata: Metadata
        let rows: [[String?]]
    }

    private struct Metadata: Encodable {
        let columns: [ResultColumn]
        let commandTag: String
        let rowCount: Int64
        let displayedRowCount: Int
        let truncated: Bool
    }

    static func json(_ sets: [ExportResultSet]) throws -> Data {
        for set in sets { try validate(set) }
        let document = Document(resultSets: sets.map { set in
            Result(metadata: Metadata(columns: set.columns, commandTag: set.commandTag,
                rowCount: set.rowCount, displayedRowCount: set.displayedRowCount, truncated: set.truncated), rows: set.rows)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    static func csv(_ set: ExportResultSet, nullMarker: String) throws -> Data {
        try validate(set)
        guard !nullMarker.isEmpty else { throw ResultExportError.nullMarker }
        guard !set.rows.contains(where: { row in row.contains { $0 == nullMarker } }) else {
            throw ResultExportError.nullCollision
        }
        var lines = [set.columns.map { csvField($0.name) }.joined(separator: ",")]
        lines.append(contentsOf: set.rows.map { row in row.map { csvField($0 ?? nullMarker) }.joined(separator: ",") })
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func write(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".dbeer-export-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { throw ResultExportError.write }
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard rename(temporary.path, destination.path) == 0 else { throw ResultExportError.write }
        } catch { throw ResultExportError.write }
    }

    private static func csvField(_ text: String) -> String {
        text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" })
            ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }

    private static func validate(_ set: ExportResultSet) throws {
        guard set.columns.enumerated().allSatisfy({ $0.offset == $0.element.index }),
              set.rows.allSatisfy({ $0.count == set.columns.count }),
              set.displayedRowCount == set.rows.count, set.rowCount >= 0 else { throw ResultExportError.malformed }
    }
}
