import Foundation

/// Captured typed evidence. Map/object entry arrays retain order and duplicate keys.
struct NativeValue: Codable, Equatable, Sendable {
    static let capability = "nativeResultValuesV1"
    static let format = "nativeV1"
    static let maximumDepth = 32
    static let maximumNodes = 100_000
    static let maximumBytes = 4 * 1_024 * 1_024

    var kind: String
    var value: String? = nil
    var engine: String? = nil
    var nativeType: String? = nil
    var typeIdentity: String? = nil
    var items: [NativeValue]? = nil
    var entries: [NativeValueEntry]? = nil

    var valid: Bool { var budget = Budget(); return validate(depth: 0, budget: &budget) }

    static func validMatrix(_ matrix: [[NativeValue]]?, rows: Int, columns: Int) -> Bool {
        guard let matrix else { return true }
        guard rows >= 0, columns >= 0, columns <= 4_096, rows <= 100_000,
              matrix.count == rows, rows == 0 || columns <= maximumNodes / rows else { return false }
        var budget = Budget()
        for row in matrix {
            guard row.count == columns else { return false }
            for value in row { guard value.validate(depth: 0, budget: &budget) else { return false } }
        }
        return budget.bytes + rows * 2 + max(0, rows - 1) + matrix.reduce(0) { $0 + max(0, $1.count - 1) } + 2 <= maximumBytes
    }

    struct MatrixBudget {
        private var budget = Budget()
        private var rows = 0
        mutating func append(_ row: [NativeValue], columns: Int) -> Bool {
            guard columns >= 0, columns <= 4_096, row.count == columns, rows < 100_000 else { return false }
            var next = budget
            next.bytes += (rows == 0 ? 2 : 1) + 2 + max(0, columns - 1)
            for value in row { guard value.validate(depth: 0, budget: &next) else { return false } }
            guard next.bytes <= NativeValue.maximumBytes else { return false }
            budget = next; rows += 1
            return true
        }
    }

    static func matchesSQLite(_ native: [[NativeValue]]?, storage: [[SQLiteValue]]?) -> Bool {
        guard let native else { return true }
        guard let storage, native.count == storage.count else { return false }
        return zip(native, storage).allSatisfy { row, cells in
            row.count == cells.count && zip(row, cells).allSatisfy { value, cell in
                guard value.engine == "sqlite", value.nativeType == cell.type else { return false }
                switch cell.type {
                case "null": return value.kind == "null"
                case "integer": return value.kind == "integer" && value.value == cell.value
                case "real": return value.kind == "float64" && value.value == cell.value
                case "blob": return value.kind == "binary" && value.value == cell.value
                case "text":
                    guard let bytes = Data(base64Encoded: cell.value) else { return false }
                    if let text = String(data: bytes, encoding: .utf8) {
                        return value.kind == "text" && value.value.map { Data($0.utf8) == Data(text.utf8) } == true
                    }
                    return value.kind == "opaque" && value.value == cell.value
                default: return false
                }
            }
        }
    }

    private struct Budget { var nodes = 0; var bytes = 0 }

    private func validate(depth: Int, budget: inout Budget) -> Bool {
        // A work stack keeps valid depth-32 trees within Swift task stacks in debug builds.
        var pending: [(NativeValue, Int)] = [(self, depth)]
        while let (value, level) = pending.popLast() {
            guard value.validateNode(depth: level, budget: &budget) else { return false }
            if let items = value.items {
                guard items.count <= Self.maximumNodes - budget.nodes - pending.count else { return false }
                for item in items.reversed() { pending.append((item, level + 1)) }
            }
            if let entries = value.entries {
                guard entries.count <= (Self.maximumNodes - budget.nodes - pending.count) / 2 else { return false }
                for entry in entries.reversed() {
                    pending.append((entry.value, level + 1))
                    pending.append((entry.key, level + 1))
                }
            }
        }
        return true
    }

    private func validateNode(depth: Int, budget: inout Budget) -> Bool {
        budget.nodes += 1
        budget.bytes += 9 + Self.stringWireBytes(kind)
        for (name, text) in [("engine", engine), ("nativeType", nativeType), ("typeIdentity", typeIdentity)] {
            if let text {
                guard !text.isEmpty, text.utf8.count <= 65_536, !text.contains("\0") else { return false }
                budget.bytes += name.utf8.count + 4 + Self.stringWireBytes(text)
            }
        }
        guard depth <= Self.maximumDepth, budget.nodes <= Self.maximumNodes,
              budget.bytes <= Self.maximumBytes,
              engine == nil || ["postgresql", "mysql", "sqlite", "mongodb", "cassandra"].contains(engine!) else { return false }
        if let value {
            budget.bytes += 9 + Self.stringWireBytes(value)
            guard budget.bytes <= Self.maximumBytes else { return false }
        }
        let scalar = value != nil && items == nil && entries == nil
        switch kind {
        case "null": return value == nil && items == nil && entries == nil
        case "text": return scalar
        case "native": return scalar && engine != nil && nativeType != nil
        case "integer":
            return scalar && value!.utf8.count <= 65_536 && Self.number(value!, decimal: false)
        case "decimal":
            return scalar && value!.utf8.count <= 65_536 && Self.number(value!, decimal: true)
        case "boolean": return scalar && ["true", "false"].contains(value!)
        case "float32", "float64":
            guard scalar, value!.utf8.count == (kind == "float32" ? 8 : 16) else { return false }
            return value!.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        case "binary", "opaque":
            guard scalar, kind != "opaque" || (engine != nil && nativeType != nil) else { return false }
            return Data(base64Encoded: value!).map { $0.base64EncodedString() == value! } == true
        case "list", "tuple", "set":
            guard value == nil, let items, entries == nil else { return false }
            budget.bytes += 11 + max(0, items.count - 1)
            return budget.bytes <= Self.maximumBytes
        case "map", "object":
            guard value == nil, items == nil, let entries else { return false }
            budget.bytes += 13 + max(0, entries.count - 1) + entries.count * 17
            guard kind != "object" || entries.allSatisfy({ $0.key.kind == "text" }) else { return false }
            return budget.bytes <= Self.maximumBytes
        default: return false
        }
    }

    private static func number(_ text: String, decimal: Bool) -> Bool {
        let bytes = Array(text.utf8)
        var index = bytes.first == 45 ? 1 : 0
        func digits() -> Bool {
            let start = index
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            return index > start
        }
        guard digits() else { return false }
        if decimal, index < bytes.count, bytes[index] == 46 {
            index += 1
            guard digits() else { return false }
        }
        if decimal, index < bytes.count, bytes[index] == 69 || bytes[index] == 101 {
            index += 1
            if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
            guard digits() else { return false }
        }
        return index == bytes.count
    }

    private static func stringWireBytes(_ text: String) -> Int {
        var count = 2
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 8, 9, 10, 12, 13, 34, 92: count += 2
            case 0..<32, 38, 60, 62, 0x2028, 0x2029: count += 6
            case 0..<0x80: count += 1
            case 0..<0x800: count += 2
            case 0..<0x10000: count += 3
            default: count += 4
            }
        }
        return count
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        func exact(_ a: String?, _ b: String?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (a?, b?): return Data(a.utf8) == Data(b.utf8)
            default: return false
            }
        }
        return lhs.kind == rhs.kind && exact(lhs.value, rhs.value) && exact(lhs.engine, rhs.engine) &&
            exact(lhs.nativeType, rhs.nativeType) && exact(lhs.typeIdentity, rhs.typeIdentity) && lhs.items == rhs.items && lhs.entries == rhs.entries
    }

    private enum CodingKeys: String, CodingKey { case kind, value, engine, nativeType, typeIdentity, items, entries }
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(kind: String, value: String? = nil, engine: String? = nil, nativeType: String? = nil,
         typeIdentity: String? = nil, items: [NativeValue]? = nil, entries: [NativeValueEntry]? = nil) {
        self.kind = kind; self.value = value; self.engine = engine; self.nativeType = nativeType
        self.typeIdentity = typeIdentity; self.items = items; self.entries = entries
    }

    init(from decoder: any Decoder) throws {
        guard decoder.codingPath.filter({ ["items", "entries"].contains($0.stringValue) }).count <= Self.maximumDepth else { throw BackendTransportError(.invalidMessage) }
        let object = try decoder.container(keyedBy: Key.self)
        let allowed: Set<String> = ["kind", "value", "engine", "nativeType", "typeIdentity", "items", "entries"]
        guard Set(object.allKeys.map(\.stringValue)).isSubset(of: allowed), object.allKeys.allSatisfy({ (try? object.decodeNil(forKey: $0)) == false }) else { throw BackendTransportError(.invalidMessage) }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        kind = try fields.decode(String.self, forKey: .kind)
        value = try fields.decodeIfPresent(String.self, forKey: .value)
        engine = try fields.decodeIfPresent(String.self, forKey: .engine)
        nativeType = try fields.decodeIfPresent(String.self, forKey: .nativeType)
        typeIdentity = try fields.decodeIfPresent(String.self, forKey: .typeIdentity)
        items = try fields.decodeIfPresent([NativeValue].self, forKey: .items)
        entries = try fields.decodeIfPresent([NativeValueEntry].self, forKey: .entries)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct NativeValueEntry: Codable, Equatable, Sendable {
    var key: NativeValue
    var value: NativeValue

    private enum CodingKeys: String, CodingKey { case key, value }
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(key: NativeValue, value: NativeValue) { self.key = key; self.value = value }
    init(from decoder: any Decoder) throws {
        let object = try decoder.container(keyedBy: Key.self)
        guard Set(object.allKeys.map(\.stringValue)) == ["key", "value"] else { throw BackendTransportError(.invalidMessage) }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        key = try fields.decode(NativeValue.self, forKey: .key)
        value = try fields.decode(NativeValue.self, forKey: .value)
    }
}
