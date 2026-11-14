import Darwin
import Foundation

struct ExportResultSet: Sendable {
    var columns: [ResultColumn]
    var rows: [[String?]]
    var sqliteValues: [[SQLiteValue]]?
    var nativeValues: [[NativeValue]]?
    var commandTag: String
    var rowCount: Int64
    var displayedRowCount: Int
    var truncated: Bool

    init(columns: [ResultColumn], rows: [[String?]], commandTag: String = "",
         rowCount: Int64? = nil, truncated: Bool = false, sqliteValues: [[SQLiteValue]]? = nil, nativeValues: [[NativeValue]]? = nil) {
        self.sqliteValues = sqliteValues
        self.nativeValues = nativeValues
        self.columns = columns
        self.rows = rows
        self.commandTag = commandTag
        self.rowCount = rowCount ?? Int64(rows.count)
        displayedRowCount = rows.count
        self.truncated = truncated
    }

    init(_ message: BackendMessage) {
        self.init(columns: message.columns ?? [], rows: message.rows ?? [], commandTag: message.commandTag ?? "",
            rowCount: message.rowCount, truncated: message.truncated == true, sqliteValues: message.sqliteValues, nativeValues: message.nativeValues)
    }
}

enum ResultExportError: LocalizedError {
    case nullMarker, nullCollision, malformed, write, read, nativeImportLimit

    var errorDescription: String? {
        switch self {
        case .nullMarker: "Choose a nonempty NULL marker."
        case .nullCollision: "The NULL marker also occurs in a value. Choose a different marker before exporting."
        case .malformed: "The result has invalid or unsupported data."
        case .read: "Choose a local DBeer result JSON file no larger than 64 MiB."
        case .nativeImportLimit: "This result exceeds the local snapshot limit of 100,000 native values or 4 MiB of native evidence. The complete export file has been kept."
        case .write: "The export file could not be saved. The previous file has been left unchanged."
        }
    }
}

/// Loaded-result export never owns a database connection or executes SQL.
enum ResultExport {
    static let maximumImportBytes = 64 * 1_024 * 1_024

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private struct Document: Codable {
        let version: Int
        let nativeValuesFormat: String?
        let resultSets: [Result]
        private enum CodingKeys: String, CodingKey { case version, nativeValuesFormat, resultSets }
        init(version: Int, resultSets: [Result]) {
            self.version = version; nativeValuesFormat = version == 2 ? NativeValue.format : nil; self.resultSets = resultSets
        }
        init(from decoder: any Decoder) throws {
            try ResultExport.keys(decoder, allowed: ["version", "nativeValuesFormat", "resultSets"])
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            version = try fields.decode(Int.self, forKey: .version)
            nativeValuesFormat = try fields.decodeIfPresent(String.self, forKey: .nativeValuesFormat)
            guard version == 1 && !fields.contains(.nativeValuesFormat) ||
                  version == 2 && nativeValuesFormat == NativeValue.format else { throw ResultExportError.malformed }
            resultSets = try fields.decode([Result].self, forKey: .resultSets)
            guard resultSets.count <= 1_024 else { throw ResultExportError.malformed }
        }
    }

    private struct Row: Codable {
        var values: [String?]
        var nativeValues: [NativeValue]?
        var sqliteValues: [SQLiteValue]?
        var enveloped = false
        private enum CodingKeys: String, CodingKey { case values, nativeValues, sqliteValues }
        init(values: [String?], nativeValues: [NativeValue]?, sqliteValues: [SQLiteValue]?) {
            self.values = values; self.nativeValues = nativeValues; self.sqliteValues = sqliteValues; enveloped = nativeValues != nil
        }
        init(from decoder: any Decoder) throws {
            if let list = try? decoder.singleValueContainer(), let values = try? list.decode([String?].self) {
                self.values = values; return
            }
            if let list = try? decoder.singleValueContainer(), let typed = try? list.decode([SQLiteValue].self) {
                values = typed.map(\.displayText); sqliteValues = typed; return
            }
            try ResultExport.keys(decoder, allowed: ["values", "nativeValues", "sqliteValues"])
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            values = try fields.decode([String?].self, forKey: .values)
            nativeValues = try fields.decode([NativeValue].self, forKey: .nativeValues)
            sqliteValues = try fields.decodeIfPresent([SQLiteValue].self, forKey: .sqliteValues)
            enveloped = true
        }
        func encode(to encoder: any Encoder) throws {
            if nativeValues == nil {
                var value = encoder.singleValueContainer(); try value.encode(values)
            } else {
                var fields = encoder.container(keyedBy: CodingKeys.self)
                try fields.encode(values, forKey: .values)
                try fields.encode(nativeValues, forKey: .nativeValues)
                try fields.encodeIfPresent(sqliteValues, forKey: .sqliteValues)
            }
        }
    }

    private struct Result: Codable {
        let metadata: Metadata
        let rows: [Row]
        let sqliteValues: [[SQLiteValue]]?
        private enum CodingKeys: String, CodingKey { case metadata, rows, sqliteValues }
        init(_ set: ExportResultSet) {
            metadata = Metadata(columns: set.columns, commandTag: set.commandTag, rowCount: set.rowCount,
                displayedRowCount: set.displayedRowCount, truncated: set.truncated)
            rows = set.rows.indices.map { Row(values: set.rows[$0], nativeValues: set.nativeValues?[$0],
                sqliteValues: set.nativeValues == nil ? nil : set.sqliteValues?[$0]) }
            sqliteValues = set.nativeValues == nil ? set.sqliteValues : nil
        }
        init(from decoder: any Decoder) throws {
            try ResultExport.keys(decoder, allowed: ["metadata", "rows", "sqliteValues"])
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            metadata = try fields.decode(Metadata.self, forKey: .metadata)
            rows = try fields.decode([Row].self, forKey: .rows)
            sqliteValues = try fields.decodeIfPresent([[SQLiteValue]].self, forKey: .sqliteValues)
        }
    }

    private struct Metadata: Codable {
        let columns: [ResultColumn]
        let commandTag: String
        let rowCount: Int64
        let displayedRowCount: Int
        let truncated: Bool
        private enum CodingKeys: String, CodingKey { case columns, commandTag, rowCount, displayedRowCount, truncated }
        init(columns: [ResultColumn], commandTag: String, rowCount: Int64, displayedRowCount: Int, truncated: Bool) {
            self.columns = columns; self.commandTag = commandTag; self.rowCount = rowCount
            self.displayedRowCount = displayedRowCount; self.truncated = truncated
        }
        init(from decoder: any Decoder) throws {
            try ResultExport.keys(decoder, allowed: ["columns", "commandTag", "rowCount", "displayedRowCount", "truncated"])
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            columns = try fields.decode([ResultColumn].self, forKey: .columns)
            commandTag = try fields.decode(String.self, forKey: .commandTag)
            rowCount = try fields.decode(Int64.self, forKey: .rowCount)
            displayedRowCount = try fields.decode(Int.self, forKey: .displayedRowCount)
            truncated = try fields.decode(Bool.self, forKey: .truncated)
        }
    }

    private static func keys(_ decoder: any Decoder, allowed: Set<String>) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        guard Set(fields.allKeys.map(\.stringValue)).isSubset(of: allowed),
              try fields.allKeys.allSatisfy({ try !fields.decodeNil(forKey: $0) }) else { throw ResultExportError.malformed }
    }

    static func json(_ sets: [ExportResultSet]) throws -> Data {
        for set in sets { try validate(set) }
        let typed = sets.contains { $0.nativeValues != nil }
        guard !typed || sets.allSatisfy({ $0.nativeValues != nil }) else { throw ResultExportError.malformed }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Document(version: typed ? 2 : 1, resultSets: sets.map(Result.init)))
    }

    /// Import is local and carries no connection, credentials, grants or SQL execution.
    static func readJSON(_ file: URL) throws -> [ExportResultSet] {
        do {
            let loaded = try SQLFileBinding.read(file, maximumBytes: maximumImportBytes)
            return try decodeJSON(Data(loaded.text.utf8))
        } catch let error as ResultExportError { throw error }
        catch { throw ResultExportError.read }
    }

    static func decodeJSON(_ data: Data) throws -> [ExportResultSet] {
        do {
            try ExactJSONKeys.validate(data, maximumBytes: maximumImportBytes, maximumDepth: 128)
            let document = try JSONDecoder().decode(Document.self, from: data)
            return try document.resultSets.map { source in
                let typed = document.version == 2
                guard source.rows.allSatisfy({ $0.enveloped == typed }), !typed || source.sqliteValues == nil else { throw ResultExportError.malformed }
                let storage = source.rows.compactMap(\.sqliteValues)
                guard storage.isEmpty || storage.count == source.rows.count,
                      source.sqliteValues == nil || storage.isEmpty else { throw ResultExportError.malformed }
                let sqlite: [[SQLiteValue]]? = source.sqliteValues ?? (storage.isEmpty ? nil : storage)
                let metadata = source.metadata
                if typed {
                    guard source.rows.allSatisfy({ $0.values.count == metadata.columns.count && $0.nativeValues?.count == metadata.columns.count }) else { throw ResultExportError.malformed }
                    guard NativeValue.validMatrix(source.rows.map { $0.nativeValues! }, rows: source.rows.count, columns: metadata.columns.count) else { throw ResultExportError.nativeImportLimit }
                }
                var set = ExportResultSet(columns: metadata.columns, rows: source.rows.map(\.values),
                    commandTag: metadata.commandTag, rowCount: metadata.rowCount, truncated: metadata.truncated,
                    sqliteValues: sqlite, nativeValues: typed ? source.rows.map { $0.nativeValues! } : nil)
                if source.rows.isEmpty, metadata.columns.contains(where: { $0.engine == .sqlite }) { set.sqliteValues = [] }
                guard metadata.displayedRowCount == set.rows.count else { throw ResultExportError.malformed }
                try validate(set)
                return set
            }
        } catch let error as ResultExportError { throw error }
        catch { throw ResultExportError.malformed }
    }

    static func csv(_ set: ExportResultSet, nullMarker: String) throws -> Data {
        try validate(set)
        if let values = set.sqliteValues, values.joined().contains(where: {
            $0.type == "text" && Data(base64Encoded: $0.value).flatMap { String(data: $0, encoding: .utf8) } == nil
        }) { throw ResultExportError.malformed }
        guard !nullMarker.isEmpty else { throw ResultExportError.nullMarker }
        guard !set.rows.contains(where: { row in row.contains { $0 == nullMarker } }) else {
            throw ResultExportError.nullCollision
        }
        var lines = [set.columns.map { csvField($0.name) }.joined(separator: ",")]
        lines.append(contentsOf: set.rows.map { row in row.map { csvField($0 ?? nullMarker) }.joined(separator: ",") })
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func write(_ data: Data, to destination: URL, expectedVersion: SQLFileVersion? = nil, expectedParent: SQLFileIdentity? = nil) throws {
        do {
            let text = String(decoding: data, as: UTF8.self)
            guard Data(text.utf8) == data else { throw ResultExportError.malformed }
            _ = try SQLFileBinding.write(text, to: destination, expectedVersion: expectedVersion, expectedParent: expectedParent)
        } catch let error as SQLFileBindingError {
            if case .recovery = error { throw error }
            throw ResultExportError.write
        } catch { throw ResultExportError.write }
    }

    private static func csvField(_ text: String) -> String {
        text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" })
            ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }

    private static func validate(_ set: ExportResultSet) throws {
        guard (!set.columns.contains(where: { $0.engine == .sqlite }) || set.sqliteValues != nil),
              SQLiteValue.validMatrix(set.sqliteValues, rows: set.rows.count, columns: set.columns.count),
              NativeValue.validMatrix(set.nativeValues, rows: set.rows.count, columns: set.columns.count),
              (!set.columns.contains(where: { $0.engine == .sqlite }) || NativeValue.matchesSQLite(set.nativeValues, storage: set.sqliteValues)),
              set.columns.count <= 4_096, set.rows.count <= 100_000,
              set.columns.allSatisfy({ $0.encoding == nil || $0.encoding == "base64" }),
              set.columns.enumerated().allSatisfy({ $0.offset == $0.element.index }),
              set.rows.allSatisfy({ $0.count == set.columns.count }),
              set.displayedRowCount == set.rows.count, set.rowCount >= 0 else { throw ResultExportError.malformed }
    }
}
