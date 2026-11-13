import Foundation

/// A captured source scalar, not an executable expression. The target adapter
/// resolves its actual column type and chooses a lossless bound parameter.
struct NativeCellFilterValue: Codable, Equatable, Sendable {
    static let capability = "nativeCellFilterV1"
    let cell: ChangeValue
    let sourceEngine: DatabaseEngine
    let sourceType: String
    let sqliteStorage: String
    var isValid: Bool {
        guard [.postgresql, .mysql, .sqlite].contains(sourceEngine), !sourceType.isEmpty,
              sourceType.utf8.count <= 16_384, !sourceType.contains("\0"),
              ["preserve", "text", "integer", "real", "blob"].contains(sqliteStorage),
              let value = cell.value, value.utf8.count <= 1_024 * 1_024 else { return false }
        switch cell.kind {
        case "text": return true
        case "binary": return Data(base64Encoded: value).map { $0.base64EncodedString() == value } == true
        case "sqliteInteger", "sqliteReal", "sqliteText", "sqliteBlob":
            guard sourceEngine == .sqlite, let storage = cell.sqliteValue, storage.valid else { return false }
            return storage.type != "real" || UInt64(storage.value, radix: 16).map { !Double(bitPattern: $0).isNaN } == true
        default: return false
        }
    }
    var displayText: String {
        let kind = cell.sqliteValue.map { "SQLite " + $0.type } ?? cell.kind
        let raw = cell.kind == "binary" || cell.kind == "sqliteBlob" ? "Base64 " + (cell.value ?? "") : String(reflecting: cell.displayText ?? "")
        let value = String(String.UnicodeScalarView(raw.unicodeScalars.prefix(512))) + (!raw.unicodeScalars.dropFirst(512).isEmpty ? "…" : "")
        let policy = sqliteStorage == "preserve" ? "captured typed value" : "SQLite bound " + sqliteStorage.uppercased()
        return "\(sourceEngine.displayName) \(kind) · \(policy) · \(value)"
    }
    /// Matches Go encoding/json string escaping, independent of JSONEncoder's
    /// different HTML/line-separator escaping policy.
    var encodedByteCount: Int {
        let empty = "{\"cell\":{\"kind\":\"\",\"value\":\"\"},\"sourceEngine\":\"\",\"sourceType\":\"\",\"sqliteStorage\":\"\"}"
        return empty.utf8.count + [cell.kind, cell.value ?? "", sourceEngine.rawValue, sourceType, sqliteStorage].reduce(0) { total, value in
            var count = 0, previous = 0
            for byte in value.utf8 {
                switch byte {
                case 8, 9, 10, 12, 13, 34, 92: count += 2
                case 0..<32, 38, 60, 62: count += 6
                default: count += 1
                }
                // U+2028/U+2029 use six-byte Go escapes instead of their
                // three-byte UTF-8 forms. Other multibyte scalars stay intact.
                if previous == 0xe280, byte == 0xa8 || byte == 0xa9 { count += 3 }
                previous = ((previous << 8) | Int(byte)) & 0xffff
            }
            return total + count
        }
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cell == rhs.cell && lhs.sourceEngine == rhs.sourceEngine &&
            Data(lhs.sourceType.utf8) == Data(rhs.sourceType.utf8) && lhs.sqliteStorage == rhs.sqliteStorage
    }
    private enum CodingKeys: String, CodingKey { case cell, sourceEngine, sourceType, sqliteStorage }
    init(cell: ChangeValue, sourceEngine: DatabaseEngine, sourceType: String, sqliteStorage: String) {
        self.cell = cell; self.sourceEngine = sourceEngine; self.sourceType = sourceType; self.sqliteStorage = sqliteStorage
    }
    init(from decoder: any Decoder) throws {
        try nativeCellFilterKeys(decoder, allowed: ["cell", "sourceEngine", "sourceType", "sqliteStorage"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try nativeCellFilterKeys(fields.superDecoder(forKey: .cell), allowed: ["kind", "value"])
        cell = try fields.decode(ChangeValue.self, forKey: .cell)
        sourceEngine = try fields.decode(DatabaseEngine.self, forKey: .sourceEngine)
        sourceType = try fields.decode(String.self, forKey: .sourceType)
        sqliteStorage = try fields.decode(String.self, forKey: .sqliteStorage)
        guard isValid else { throw BackendTransportError(.invalidMessage) }
    }
}

private func nativeCellFilterKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    struct Key: CodingKey {
        let stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    let fields = try decoder.container(keyedBy: Key.self)
    guard Set(fields.allKeys.map(\.stringValue)) == allowed,
          fields.allKeys.allSatisfy({ (try? fields.decodeNil(forKey: $0)) == false }) else { throw BackendTransportError(.invalidMessage) }
}
