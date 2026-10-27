import Foundation

/// Metadata from explicitly connected profiles. This cache has no database
/// client and cannot open a restored connection.
struct SQLCompletionCatalog {
    private var profiles: [UUID: [SQLCompletionRelation]] = [:]
    private static let limit = 10_000

    func context(profileID: UUID?) -> SQLCompletionContext {
        SQLCompletionContext(profileID: profileID, catalog: profileID.flatMap { profiles[$0] } ?? [])
    }

    private func decodeNames(_ text: String?) -> [String] {
        guard let text else { return [] }
        return Array(((try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []).prefix(2_000))
    }

    private func columnTypes(_ text: String?, columns: [String]) -> [String: String] {
        guard let text, let values = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) else { return [:] }
        return columns.prefix(2_000).reduce(into: [:]) { result, name in
            if let value = values[name], !value.isEmpty, value.utf8.count <= 4_096, name.utf8.count <= 1_024 { result[name] = value }
        }
    }

    private func orderedKeys(_ records: [[String: String]], key: String) -> [String] {
        records.filter { (Int($0[key] ?? "0") ?? 0) > 0 }
            .sorted { (Int($0[key] ?? "0") ?? 0) < (Int($1[key] ?? "0") ?? 0) }.compactMap { $0["name"] }
    }

    mutating func remove(profileID: UUID) { profiles[profileID] = nil }

    mutating func record(_ records: [[String: String]], request: CatalogRequest, profileID: UUID) {
        var relations = profiles[profileID] ?? []
        switch request.kind {
        case "completion":
            relations = records.prefix(Self.limit).compactMap { record in
                guard let schema = record["schema"], let name = record["name"],
                      let kind = record["kind"], ["table", "view", "function", "type"].contains(kind) else { return nil }
                let columns = record["columns"].flatMap { value in
                    try? JSONDecoder().decode([String].self, from: Data(value.utf8))
                } ?? []
                let keys = record["foreignKeys"].flatMap { value in
                    try? JSONDecoder().decode([SQLCompletionForeignKey].self, from: Data(value.utf8))
                } ?? []
                let signatures = record["signatures"].flatMap { value in
                    try? JSONDecoder().decode([SQLFunctionSignature].self, from: Data(value.utf8))
                } ?? []
                return SQLCompletionRelation(schema: schema, name: name, kind: kind, columns: Array(columns.prefix(2_000)),
                    foreignKeys: Array(keys.prefix(64)), signatures: Array(signatures.prefix(32)),
                    partitionKeys: decodeNames(record["partitionKeys"]), clusteringColumns: decodeNames(record["clusteringColumns"]),
                    staticColumns: decodeNames(record["staticColumns"]),
                    columnTypes: columnTypes(record["columnTypes"], columns: columns))
            }
        case "schemas":
            let names = Set(records.compactMap { $0["name"] })
            relations.removeAll { !names.contains($0.schema) }
        case "objects", "search":
            if request.kind == "objects", let schema = request.schema, let kind = request.objectKind {
                let names = Set(records.compactMap { $0["name"] })
                relations.removeAll { $0.schema == schema && $0.kind == kind && !names.contains($0.name) }
            }
            for record in records.prefix(Self.limit) {
                guard let name = record["name"], let schema = record["schema"] ?? request.schema,
                      let kind = record["kind"] ?? request.objectKind,
                      ["table", "view", "function", "type"].contains(kind) else { continue }
                if !relations.contains(where: { $0.schema == schema && $0.name == name && $0.kind == kind }),
                   relations.count < Self.limit {
                    relations.append(SQLCompletionRelation(schema: schema, name: name, kind: kind))
                }
            }
        case "columns":
            guard let schema = request.schema, let name = request.object,
                  let kind = request.objectKind, ["table", "view"].contains(kind) else { return }
            let relation = SQLCompletionRelation(schema: schema, name: name, kind: kind,
                columns: Array(records.prefix(2_000).compactMap { $0["name"] }),
                partitionKeys: orderedKeys(records, key: "partitionKeyPosition"),
                clusteringColumns: orderedKeys(records, key: "clusteringPosition"),
                staticColumns: records.filter { $0["static"] == "true" }.compactMap { $0["name"] },
                columnTypes: records.prefix(2_000).reduce(into: [:]) { result, record in
                    if let name = record["name"], let type = record["nativeType"],
                       !type.isEmpty, name.utf8.count <= 1_024, type.utf8.count <= 4_096 { result[name] = type }
                })
            if let index = relations.firstIndex(where: { $0.schema == schema && $0.name == name && $0.kind == kind }) {
                var updated = relation
                updated.foreignKeys = relations[index].foreignKeys
                updated.signatures = relations[index].signatures
                relations[index] = updated
            } else if relations.count < Self.limit { relations.append(relation) }
        default: return
        }
        profiles[profileID] = relations.sorted {
            ($0.schema, $0.name, $0.kind) < ($1.schema, $1.name, $1.kind)
        }
    }
}
