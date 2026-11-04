import Foundation

/// Authoritative SQLite storage bytes; the grid's strings are presentation only.
struct SQLiteValue: Codable, Sendable, Equatable {
    var type: String
    var value: String = ""

    init(type: String, value: String = "") { self.type = type; self.value = value }
    private enum CodingKeys: String, CodingKey { case type, value }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
    var valid: Bool {
        switch type {
        case "null": return value.isEmpty
        case "integer": return Int64(value).map { String($0) == value } == true
        case "real": return value.count == 16 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        case "text", "blob": return Data(base64Encoded: value).map { $0.count <= 8 * 1_024 * 1_024 && $0.base64EncodedString() == value } == true
        default: return false
        }
    }
    static func validMatrix(_ values: [[Self]]?, rows: Int, columns: Int) -> Bool {
        guard let values else { return true }
        return values.count == rows && values.allSatisfy { $0.count == columns && $0.allSatisfy(\.valid) }
    }
    var changeValue: ChangeValue {
        if type == "null" { return ChangeValue(kind: "null", value: nil) }
        let suffix = type == "integer" ? "Integer" : type == "real" ? "Real" : type == "blob" ? "Blob" : "Text"
        return ChangeValue(kind: "sqlite" + suffix, value: value)
    }
}


extension SQLiteValue {
    var displayText: String? {
        switch type {
        case "null": return nil
        case "integer": return value
        case "real": return UInt64(value, radix: 16).map { String(Double(bitPattern: $0)) }
        case "text": return Data(base64Encoded: value).flatMap { String(data: $0, encoding: .utf8) } ?? "<TEXT bytes: \(value)>"
        default: return value
        }
    }
}

extension ChangeValue {
    var sqliteValue: SQLiteValue? {
        let storageType: String
        switch kind {
        case "sqliteInteger": storageType = "integer"
        case "sqliteReal": storageType = "real"
        case "sqliteText": storageType = "text"
        case "sqliteBlob": storageType = "blob"
        default: return nil
        }
        return SQLiteValue(type: storageType, value: value ?? "")
    }
    var displayText: String? {
        if let sqliteValue { return sqliteValue.displayText }
        return kind == "null" ? nil : kind == "default" ? "<DEFAULT>" : value ?? ""
    }
    var displayKind: String {
        if kind == "sqliteBlob" { return "binary" }
        return kind.hasPrefix("sqlite") ? "text" : kind
    }
}
