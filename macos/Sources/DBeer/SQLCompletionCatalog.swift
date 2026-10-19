import Foundation

/// Metadata from explicitly connected profiles. This cache has no database
/// client and cannot open a restored connection.
struct SQLCompletionCatalog {
    private var profiles: [UUID: [SQLCompletionRelation]] = [:]
    private static let limit = 10_000

    func context(profileID: UUID?) -> SQLCompletionContext {
        SQLCompletionContext(profileID: profileID, catalog: profileID.flatMap { profiles[$0] } ?? [])
    }

    mutating func remove(profileID: UUID) { profiles[profileID] = nil }

    mutating func record(_ records: [[String: String]], request: CatalogRequest, profileID: UUID) {
        var relations = profiles[profileID] ?? []
        switch request.kind {
        case "completion":
            relations = records.prefix(Self.limit).compactMap { record in
                guard let schema = record["schema"], let name = record["name"],
                      let kind = record["kind"], ["table", "view", "function"].contains(kind) else { return nil }
                let columns = record["columns"].flatMap { value in
                    try? JSONDecoder().decode([String].self, from: Data(value.utf8))
                } ?? []
                return SQLCompletionRelation(schema: schema, name: name, kind: kind, columns: Array(columns.prefix(2_000)))
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
                      ["table", "view", "function"].contains(kind) else { continue }
                if !relations.contains(where: { $0.schema == schema && $0.name == name && $0.kind == kind }),
                   relations.count < Self.limit {
                    relations.append(SQLCompletionRelation(schema: schema, name: name, kind: kind))
                }
            }
        case "columns":
            guard let schema = request.schema, let name = request.object,
                  let kind = request.objectKind, ["table", "view"].contains(kind) else { return }
            let relation = SQLCompletionRelation(schema: schema, name: name, kind: kind,
                columns: Array(records.prefix(2_000).compactMap { $0["name"] }))
            if let index = relations.firstIndex(where: { $0.schema == schema && $0.name == name && $0.kind == kind }) {
                relations[index] = relation
            } else if relations.count < Self.limit { relations.append(relation) }
        default: return
        }
        profiles[profileID] = relations.sorted {
            ($0.schema, $0.name, $0.kind) < ($1.schema, $1.name, $1.kind)
        }
    }
}
