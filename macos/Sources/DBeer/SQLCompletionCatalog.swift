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

    private func columnTypeEntries(_ record: [String: String], columns: [String]) -> [CatalogColumnTypeEntry] {
        if record["columnTypeEntries"] != nil { return CatalogColumnTypeEntry.parse(record["columnTypeEntries"], columns: columns) }
        guard let text = record["columnTypes"],
              let entries = try? ExactJSONKeys.stringEntries(Data(text.utf8), maximumBytes: LogicalRelationshipLimits.metadataBytes, maximumEntries: 2_000) else { return [] }
        return entries.compactMap { entry in
            let value = CatalogColumnTypeEntry(name: entry.key, nativeType: entry.value)
            return value.isValid && columns.filter { Data($0.utf8) == Data(entry.key.utf8) }.count == 1 ? value : nil
        }
    }
    private func displayTypes(_ entries: [CatalogColumnTypeEntry]) -> [String: String] {
        guard Set(entries.map(\.name)).count == entries.count else { return [:] }
        return Dictionary(entries.map { ($0.name, $0.nativeType) }, uniquingKeysWith: { first, _ in first })
    }
    private func exact(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }

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
                let entries = columnTypeEntries(record, columns: columns)
                return SQLCompletionRelation(schema: schema, name: name, kind: kind, columns: Array(columns.prefix(2_000)),
                    foreignKeys: Array(keys.prefix(64)), signatures: Array(signatures.prefix(32)),
                    partitionKeys: decodeNames(record["partitionKeys"]), clusteringColumns: decodeNames(record["clusteringColumns"]),
                    staticColumns: decodeNames(record["staticColumns"]),
                    columnTypes: displayTypes(entries), columnTypeEntries: entries)
            }
        case "schemas":
            let names = Set(records.compactMap { $0["name"].map { Data($0.utf8) } })
            relations.removeAll { !names.contains(Data($0.schema.utf8)) }
        case "objects", "search":
            if request.kind == "objects", let schema = request.schema, let kind = request.objectKind {
                let names = Set(records.compactMap { $0["name"].map { Data($0.utf8) } })
                relations.removeAll { exact($0.schema, schema) && $0.kind == kind && !names.contains(Data($0.name.utf8)) }
            }
            for record in records.prefix(Self.limit) {
                guard let name = record["name"], let schema = record["schema"] ?? request.schema,
                      let kind = record["kind"] ?? request.objectKind,
                      ["table", "view", "function", "type"].contains(kind) else { continue }
                if !relations.contains(where: { exact($0.schema, schema) && exact($0.name, name) && $0.kind == kind }),
                   relations.count < Self.limit {
                    relations.append(SQLCompletionRelation(schema: schema, name: name, kind: kind))
                }
            }
        case "columns":
            guard let schema = request.schema, let name = request.object,
                  let kind = request.objectKind, ["table", "view"].contains(kind) else { return }
            let entries: [CatalogColumnTypeEntry] = records.prefix(2_000).compactMap { record in
                guard let name = record["name"], let type = record["nativeType"] else { return nil }
                let entry = CatalogColumnTypeEntry(name: name, nativeType: type, comparison: CatalogColumnComparison.parse(record["comparison"]))
                return entry.isValid ? entry : nil
            }
            let relation = SQLCompletionRelation(schema: schema, name: name, kind: kind,
                columns: Array(records.prefix(2_000).compactMap { $0["name"] }),
                partitionKeys: orderedKeys(records, key: "partitionKeyPosition"),
                clusteringColumns: orderedKeys(records, key: "clusteringPosition"),
                staticColumns: records.filter { $0["static"] == "true" }.compactMap { $0["name"] },
                columnTypes: displayTypes(entries), columnTypeEntries: entries)

            if let index = relations.firstIndex(where: { exact($0.schema, schema) && exact($0.name, name) && $0.kind == kind }) {
                var updated = relation
                updated.foreignKeys = relations[index].foreignKeys
                updated.signatures = relations[index].signatures
                relations[index] = updated
            } else if relations.count < Self.limit { relations.append(relation) }
        default: return
        }
        profiles[profileID] = relations.sorted {
            Data(($0.schema + "\0" + $0.name + "\0" + $0.kind).utf8).lexicographicallyPrecedes(Data(($1.schema + "\0" + $1.name + "\0" + $1.kind).utf8))
        }
    }
}
