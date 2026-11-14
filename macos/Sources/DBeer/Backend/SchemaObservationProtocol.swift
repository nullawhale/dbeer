import Foundation

struct SchemaObservationTable: Codable, Sendable, Equatable, Hashable {
    let schema: String
    let name: String
    var valid: Bool { ERTableID.validName(schema) && ERTableID.validName(name) }
    static func == (lhs: Self, rhs: Self) -> Bool { Data(lhs.schema.utf8) == Data(rhs.schema.utf8) && Data(lhs.name.utf8) == Data(rhs.name.utf8) }
    func hash(into hasher: inout Hasher) { hasher.combine(Data(schema.utf8)); hasher.combine(Data(name.utf8)) }
}

struct SchemaObservationRequest: Codable, Sendable, Equatable {
    let action: String
    let tables: [SchemaObservationTable]
    var valid: Bool {
        ["poll", "previewInstall", "previewRemove"].contains(action) && tables.count <= 100 &&
        (action == "poll" ? !tables.isEmpty : tables.isEmpty) && tables.allSatisfy(\.valid) && Set(tables).count == tables.count
    }
}

extension BackendCommand {
    var validSchemaObservationCommand: Bool {
        guard type == "monitor.schema", schemaObservation?.valid == true,
              sessionId.map(BackendMessage.validID) == true, queryId.map(BackendMessage.validID) == true,
              let data = try? JSONEncoder().encode(self),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return Set(fields.keys) == ["type", "requestId", "sessionId", "queryId", "schemaObservation"]
    }
}

struct SchemaObservation: Codable, Sendable, Equatable {
    let engine: DatabaseEngine
    let action: String
    let tables: [SchemaObservationTable]
    let mode: String
    let revision: String
    let observedAt: String
    let installed: Bool
    let canInstall: Bool
    let canRemove: Bool
    let complete: Bool
    let notices: [String]
    var sql: String?

    var valid: Bool {
        guard [.postgresql, .mysql, .mariadb].contains(engine), SchemaObservationRequest(action: action, tables: tables).valid,
              observedAt.utf8.count <= 40, observedAt.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil,
              SessionMonitorSnapshot.date(observedAt) != nil,
              notices.count <= 16, notices.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 && !$0.contains("\0") }),
              complete || !notices.isEmpty,
              sql.map({ !$0.isEmpty && $0.utf8.count <= 16_384 && !$0.contains("\0") }) ?? true else { return false }
        if action != "poll" { return engine == .postgresql && mode == "notifications" && revision.isEmpty && sql != nil }
        guard sql == nil else { return false }
        if engine == .postgresql { return mode == "notifications" && UInt64(revision).map { String($0) == revision } == true }
        guard mode == "fingerprint", !installed, !canInstall, !canRemove else { return false }
        return complete ? revision.utf8.count == 64 && revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) : revision.isEmpty
    }

}

private struct SchemaObservationCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func schemaObservationKeys(_ decoder: Decoder, required: Set<String>, optional: Set<String> = []) throws {
    let values = try decoder.container(keyedBy: SchemaObservationCodingKey.self)
    let keys = Set(values.allKeys.map(\.stringValue))
    guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw BackendTransportError(.invalidMessage) }
    for key in values.allKeys where try values.decodeNil(forKey: key) { throw BackendTransportError(.invalidMessage) }
}

extension SchemaObservationTable {
    init(from decoder: Decoder) throws {
        try schemaObservationKeys(decoder, required: ["schema", "name"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(String.self, forKey: .schema); name = try values.decode(String.self, forKey: .name)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}
extension SchemaObservationRequest {
    init(from decoder: Decoder) throws {
        try schemaObservationKeys(decoder, required: ["action", "tables"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        action = try values.decode(String.self, forKey: .action); tables = try values.decode([SchemaObservationTable].self, forKey: .tables)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}
extension SchemaObservation {
    init(from decoder: Decoder) throws {
        try schemaObservationKeys(decoder, required: ["engine", "action", "tables", "mode", "revision", "observedAt", "installed", "canInstall", "canRemove", "complete", "notices"], optional: ["sql"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        engine = try values.decode(DatabaseEngine.self, forKey: .engine)
        action = try values.decode(String.self, forKey: .action); tables = try values.decode([SchemaObservationTable].self, forKey: .tables)
        mode = try values.decode(String.self, forKey: .mode); revision = try values.decode(String.self, forKey: .revision)
        observedAt = try values.decode(String.self, forKey: .observedAt)
        installed = try values.decode(Bool.self, forKey: .installed); canInstall = try values.decode(Bool.self, forKey: .canInstall)
        canRemove = try values.decode(Bool.self, forKey: .canRemove); complete = try values.decode(Bool.self, forKey: .complete)
        notices = try values.decode([String].self, forKey: .notices); sql = try values.decodeIfPresent(String.self, forKey: .sql)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}
