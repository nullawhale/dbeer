import Foundation

struct SQLiteRelationshipPair: Codable, Equatable, Sendable {
    let source: String
    let target: String
    let position: Int
    let value: SQLiteValue
    static func == (lhs: Self, rhs: Self) -> Bool {
        Data(lhs.source.utf8) == Data(rhs.source.utf8) && Data(lhs.target.utf8) == Data(rhs.target.utf8) && lhs.position == rhs.position && lhs.value == rhs.value
    }
    private enum CodingKeys: String, CodingKey { case source, target, position, value }
    init(source: String, target: String, position: Int, value: SQLiteValue) {
        self.source = source; self.target = target; self.position = position; self.value = value
    }
    init(from decoder: any Decoder) throws {
        try relationshipScopeKeys(decoder, allowed: ["source", "target", "position", "value"], required: true)
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        source = try fields.decode(String.self, forKey: .source)
        target = try fields.decode(String.self, forKey: .target)
        position = try fields.decode(Int.self, forKey: .position)
        let storage = try fields.superDecoder(forKey: .value)
        try relationshipScopeKeys(storage, allowed: ["type", "value"], required: false)
        value = try SQLiteValue(from: storage)
    }
}

/// A declared relationship restriction preserves SQLite parent-key comparison
/// semantics. It remains separate from ordinary child-column filters.
struct SQLiteRelationshipScope: Codable, Equatable, Sendable {
    static let capability = "sqliteRelationshipBrowseV1"
    let child: CatalogRelationTarget
    let parent: CatalogRelationTarget
    let name: String
    let columns: [SQLiteRelationshipPair]
    var isValid: Bool {
        child.valid && parent.valid && child.schema == "main" && parent.schema == "main" && validBrowseName(name) &&
        (1...32).contains(columns.count) && columns.map(\.position) == Array(1...columns.count) &&
        Set(columns.map { Data($0.source.utf8) }).count == columns.count && Set(columns.map { Data($0.target.utf8) }).count == columns.count &&
        columns.allSatisfy { pair in
            validBrowseName(pair.source) && validBrowseName(pair.target) && pair.value.valid && pair.value.type != "null" &&
            pair.value.value.utf8.count <= 1_024 * 1_024 &&
            (pair.value.type != "real" || UInt64(pair.value.value, radix: 16).map { !Double(bitPattern: $0).isNaN } == true)
        } && columns.reduce(0, { $0 + $1.value.value.utf8.count }) <= 4 * 1_024 * 1_024
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.child == rhs.child && lhs.parent == rhs.parent && Data(lhs.name.utf8) == Data(rhs.name.utf8) && lhs.columns == rhs.columns
    }
    var parentKeyDescription: String {
        columns.map { pair in
            let shown: String
            switch pair.value.type {
            case "text": shown = String(reflecting: pair.value.displayText ?? "")
            case "blob": shown = "Base64 " + pair.value.value
            default: shown = pair.value.displayText ?? ""
            }
            let preview = String(shown.prefix(256)) + (shown.count > 256 ? "…" : "")
            return pair.source + " ← " + pair.target + " = " + preview
        }.joined(separator: ", ")
    }
    func matches(_ reference: TableReference) -> Bool {
        reference.kind == "table" && child == .init(schema: reference.schema, name: reference.name)
    }
    init(child: CatalogRelationTarget, parent: CatalogRelationTarget, name: String, columns: [SQLiteRelationshipPair]) {
        self.child = child; self.parent = parent; self.name = name; self.columns = columns
    }
    init(relationship: DiscoveredTableRelationship, filters: [CatalogFilter]) throws {
        child = .init(schema: relationship.source.schema, name: relationship.source.name)
        parent = .init(schema: relationship.key.target.schema, name: relationship.key.target.name)
        name = relationship.key.name
        guard filters.count == relationship.key.columns.count else { throw TableNavigationFailure("The parent key mapping changed.") }
        columns = try zip(relationship.key.columns, filters).map { pair, filter in
            guard Data(pair.source.utf8) == Data(filter.column.utf8), let value = filter.sqliteValue else {
                throw TableNavigationFailure("The authoritative SQLite parent-key values are unavailable. Reload the parent row.")
            }
            return .init(source: pair.source, target: pair.target, position: pair.position, value: value)
        }
        guard isValid else { throw TableNavigationFailure("The SQLite relationship restriction is invalid or too large.") }
    }
    private enum CodingKeys: String, CodingKey { case child, parent, name, columns }
    init(from decoder: any Decoder) throws {
        try relationshipScopeKeys(decoder, allowed: ["child", "parent", "name", "columns"], required: true)
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        child = try fields.decode(CatalogRelationTarget.self, forKey: .child)
        parent = try fields.decode(CatalogRelationTarget.self, forKey: .parent)
        name = try fields.decode(String.self, forKey: .name)
        columns = try fields.decode([SQLiteRelationshipPair].self, forKey: .columns)
        guard isValid else { throw BackendTransportError(.invalidMessage) }
    }
}

private struct RelationshipScopeCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func relationshipScopeKeys(_ decoder: any Decoder, allowed: Set<String>, required: Bool) throws {
    let fields = try decoder.container(keyedBy: RelationshipScopeCodingKey.self)
    let names = Set(fields.allKeys.map(\.stringValue))
    guard (required ? names == allowed : names.isSubset(of: allowed)),
          fields.allKeys.allSatisfy({ (try? fields.decodeNil(forKey: $0)) == false }) else { throw BackendTransportError(.invalidMessage) }
}
