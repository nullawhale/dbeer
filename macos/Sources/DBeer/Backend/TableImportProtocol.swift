import Foundation

struct TableImportColumn: Codable, Equatable, Sendable {
    var name: String
    var nativeType: String
    var nullable: Bool
    var hasDefault: Bool
    var generated: Bool
    var binary: Bool

    var valid: Bool { tableImportNameValid(name) && !nativeType.isEmpty && nativeType.utf8.count <= 65_536 && !nativeType.utf8.contains(0) }

    private enum CodingKeys: String, CodingKey { case name, nativeType, nullable, hasDefault, generated, binary }
    init(name: String, nativeType: String, nullable: Bool, hasDefault: Bool, generated: Bool, binary: Bool) {
        self.name = name; self.nativeType = nativeType; self.nullable = nullable
        self.hasDefault = hasDefault; self.generated = generated; self.binary = binary
    }
    init(from decoder: Decoder) throws {
        try requireTableImportKeys(decoder, required: ["name", "nativeType", "nullable", "hasDefault", "generated", "binary"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name); nativeType = try c.decode(String.self, forKey: .nativeType)
        nullable = try c.decode(Bool.self, forKey: .nullable); hasDefault = try c.decode(Bool.self, forKey: .hasDefault)
        generated = try c.decode(Bool.self, forKey: .generated); binary = try c.decode(Bool.self, forKey: .binary)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct TableImportRequest: Codable, Equatable, Sendable {
    static let maximumRows = 10_000
    static let maximumColumns = 256
    static let maximumCells = 100_000
    static let maximumValueBytes = 4 * 1_024 * 1_024
    var schema: String
    var table: String
    var fingerprint: String?
    var columns: [String]?
    var rows: [[ChangeValue]]?

    func valid(for operation: String) -> Bool {
        guard tableImportNameValid(schema), tableImportNameValid(table) else { return false }
        if operation == "import.describe" { return fingerprint == nil && columns == nil && rows == nil }
        guard ["import.preview", "import.apply"].contains(operation), tableImportFingerprintValid(fingerprint),
              let columns, !columns.isEmpty, columns.count <= Self.maximumColumns,
              columns.allSatisfy(tableImportNameValid), Set(columns.map { Data($0.utf8) }).count == columns.count,
              let rows, !rows.isEmpty, rows.count <= Self.maximumRows,
              rows.count * columns.count <= Self.maximumCells else { return false }
        var bytes = 0
        for row in rows {
            guard row.count == columns.count else { return false }
            for cell in row {
                switch cell.kind {
                case "null": guard cell.value == nil else { return false }
                case "text": guard let value = cell.value, !value.utf8.contains(0) else { return false }
                case "binary":
                    guard let value = cell.value, let decoded = Data(base64Encoded: value), decoded.base64EncodedString() == value else { return false }
                default: return false
                }
                bytes += cell.value?.utf8.count ?? 0
                guard bytes <= Self.maximumValueBytes else { return false }
            }
        }
        return true
    }

    private enum CodingKeys: String, CodingKey { case schema, table, fingerprint, columns, rows }
    init(schema: String, table: String, fingerprint: String? = nil, columns: [String]? = nil, rows: [[ChangeValue]]? = nil) {
        self.schema = schema; self.table = table; self.fingerprint = fingerprint; self.columns = columns; self.rows = rows
    }
    init(from decoder: Decoder) throws {
        try requireTableImportKeys(decoder, required: ["schema", "table"], optional: ["fingerprint", "columns", "rows"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(String.self, forKey: .schema); table = try c.decode(String.self, forKey: .table)
        fingerprint = c.contains(.fingerprint) ? try c.decode(String.self, forKey: .fingerprint) : nil
        columns = c.contains(.columns) ? try c.decode([String].self, forKey: .columns) : nil
        rows = c.contains(.rows) ? try c.decode([[ChangeValue]].self, forKey: .rows) : nil
        if c.contains(.rows) {
            var rowValues = try c.nestedUnkeyedContainer(forKey: .rows)
            while !rowValues.isAtEnd {
                var cells = try rowValues.nestedUnkeyedContainer()
                while !cells.isAtEnd {
                    let cell = try cells.superDecoder()
                    let fields = try cell.container(keyedBy: TableImportCodingKey.self)
                    let kind = try fields.decode(String.self, forKey: TableImportCodingKey(stringValue: "kind")!)
                    if kind == "null" { try requireTableImportKeys(cell, required: ["kind"]) }
                    else {
                        try requireTableImportKeys(cell, required: ["kind", "value"])
                        _ = try fields.decode(String.self, forKey: TableImportCodingKey(stringValue: "value")!)
                    }
                }
            }
        }
        guard valid(for: fingerprint == nil ? "import.describe" : "import.preview") else { throw BackendTransportError(.invalidMessage) }
    }
}

struct TableImportReply: Codable, Equatable, Sendable {
    var columns: [TableImportColumn]?
    var fingerprint: String?
    var rowCount: Int?
    var sql: String?
    var row: Int?

    func valid(for operation: String) -> Bool {
        switch operation {
        case "import.describe.result":
            guard let columns, !columns.isEmpty, columns.count <= 4_096 else { return false }
            return columns.allSatisfy(\.valid) && Set(columns.map { Data($0.name.utf8) }).count == columns.count &&
                tableImportFingerprintValid(fingerprint) && rowCount == nil && sql == nil && row == nil
        case "import.preview.result":
            return columns == nil && tableImportFingerprintValid(fingerprint) && (1...TableImportRequest.maximumRows).contains(rowCount ?? 0) &&
                sql.map { !$0.isEmpty && $0.utf8.count <= 1_048_576 && !$0.utf8.contains(0) } == true && row == nil
        case "import.apply.result":
            return columns == nil && fingerprint == nil && sql == nil && row == nil && (1...TableImportRequest.maximumRows).contains(rowCount ?? 0)
        case "error":
            return columns == nil && fingerprint == nil && rowCount == nil && sql == nil && (1...TableImportRequest.maximumRows).contains(row ?? 0)
        default: return false
        }
    }

    private enum CodingKeys: String, CodingKey { case columns, fingerprint, rowCount, sql, row }
    init(columns: [TableImportColumn]? = nil, fingerprint: String? = nil, rowCount: Int? = nil, sql: String? = nil, row: Int? = nil) {
        self.columns = columns; self.fingerprint = fingerprint; self.rowCount = rowCount; self.sql = sql; self.row = row
    }
    init(from decoder: Decoder) throws {
        try requireTableImportKeys(decoder, required: [], optional: ["columns", "fingerprint", "rowCount", "sql", "row"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        columns = c.contains(.columns) ? try c.decode([TableImportColumn].self, forKey: .columns) : nil
        fingerprint = c.contains(.fingerprint) ? try c.decode(String.self, forKey: .fingerprint) : nil
        rowCount = c.contains(.rowCount) ? try c.decode(Int.self, forKey: .rowCount) : nil
        sql = c.contains(.sql) ? try c.decode(String.self, forKey: .sql) : nil
        row = c.contains(.row) ? try c.decode(Int.self, forKey: .row) : nil
    }
}

private func tableImportNameValid(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 1_024 && !value.utf8.contains(0)
}
private func tableImportFingerprintValid(_ value: String?) -> Bool {
    value.map { $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } } == true
}
private struct TableImportCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func requireTableImportKeys(_ decoder: Decoder, required: Set<String>, optional: Set<String> = []) throws {
    let c = try decoder.container(keyedBy: TableImportCodingKey.self)
    let keys = Set(c.allKeys.map(\.stringValue))
    guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw BackendTransportError(.invalidMessage) }
}
