import Foundation

/// Ordered entries preserve byte-distinct identifiers that a Swift String map
/// would merge. Legacy maps remain display data, never logical JOIN evidence.
struct CatalogColumnTypeEntry: Codable, Equatable, Sendable {
    let name: String
    let nativeType: String
    var comparison: CatalogColumnComparison? = nil
    static let capability = "catalogColumnTypesV1"
    init(name: String, nativeType: String, comparison: CatalogColumnComparison? = nil) {
        self.name = name; self.nativeType = nativeType; self.comparison = comparison
    }
    private enum CodingKeys: String, CodingKey { case name, nativeType, comparison }
    init(from decoder: any Decoder) throws {
        try catalogColumnTypeKeys(decoder, allowed: ["name", "nativeType", "comparison"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name); nativeType = try values.decode(String.self, forKey: .nativeType)
        comparison = try values.decodeIfPresent(CatalogColumnComparison.self, forKey: .comparison)
        guard isValid else { throw LogicalRelationshipError.invalid }
    }
    var isValid: Bool {
        ERTableID.validName(name) && !nativeType.isEmpty && nativeType.utf8.count <= 4_096 && !nativeType.contains("\0") &&
            (comparison?.isValid ?? true)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        Data(lhs.name.utf8) == Data(rhs.name.utf8) && Data(lhs.nativeType.utf8) == Data(rhs.nativeType.utf8) && lhs.comparison == rhs.comparison
    }
    static func parse(_ text: String?, columns: [String]) -> [Self] {
        guard let text, text.utf8.count <= LogicalRelationshipLimits.metadataBytes else { return [] }
        let data = Data(text.utf8)
        guard (try? ExactJSONKeys.validate(data, maximumBytes: LogicalRelationshipLimits.metadataBytes)) != nil,
              let values = try? JSONDecoder().decode([Self].self, from: data), values.count <= 2_000,
              values.allSatisfy(\.isValid), Set(values.map { Data($0.name.utf8) }).count == values.count,
              values.allSatisfy({ entry in columns.filter { Data($0.utf8) == Data(entry.name.utf8) }.count == 1 }) else { return [] }
        return values
    }
}

struct CatalogColumnComparison: Codable, Equatable, Sendable {
    let kind: String
    let baseType: String
    var charset = ""
    var collationSchema = ""
    var collationName = ""
    var collationIdentity = ""
    var isValid: Bool {
        ["text", "native", "unknown"].contains(kind) && !baseType.isEmpty &&
            [baseType, charset, collationSchema, collationName, collationIdentity].allSatisfy { $0.utf8.count <= 4_096 && !$0.contains("\0") }
    }
    private enum CodingKeys: String, CodingKey { case kind, baseType, charset, collationSchema, collationName, collationIdentity }
    init(kind: String, baseType: String, charset: String = "", collationSchema: String = "", collationName: String = "", collationIdentity: String = "") {
        self.kind = kind; self.baseType = baseType; self.charset = charset
        self.collationSchema = collationSchema; self.collationName = collationName; self.collationIdentity = collationIdentity
    }
    init(from decoder: any Decoder) throws {
        try catalogColumnTypeKeys(decoder, allowed: ["kind", "baseType", "charset", "collationSchema", "collationName", "collationIdentity"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind); baseType = try values.decode(String.self, forKey: .baseType)
        charset = try values.decodeIfPresent(String.self, forKey: .charset) ?? ""
        collationSchema = try values.decodeIfPresent(String.self, forKey: .collationSchema) ?? ""
        collationName = try values.decodeIfPresent(String.self, forKey: .collationName) ?? ""
        collationIdentity = try values.decodeIfPresent(String.self, forKey: .collationIdentity) ?? ""
        guard isValid else { throw LogicalRelationshipError.invalid }
    }
    static func parse(_ text: String?) -> Self? {
        guard let text else { return nil }; let data = Data(text.utf8)
        guard (try? ExactJSONKeys.validate(data, maximumBytes: 32_768)) != nil else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        [lhs.kind, lhs.baseType, lhs.charset, lhs.collationSchema, lhs.collationName, lhs.collationIdentity].map { Data($0.utf8) } ==
            [rhs.kind, rhs.baseType, rhs.charset, rhs.collationSchema, rhs.collationName, rhs.collationIdentity].map { Data($0.utf8) }
    }
}

private func catalogColumnTypeKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    struct Key: CodingKey {
        let stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    let fields = try decoder.container(keyedBy: Key.self)
    guard fields.allKeys.allSatisfy({ allowed.contains($0.stringValue) && (try? fields.decodeNil(forKey: $0)) == false }) else {
        throw LogicalRelationshipError.invalid
    }
}
