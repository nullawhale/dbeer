import Foundation

struct TableReference: Codable, Equatable, Sendable {
    let schema: String
    let name: String
    let kind: String
}

@MainActor
final class CatalogNode: ObservableObject, Identifiable {
    enum Kind { case schema, group, object, detailGroup, detail }
    let id = UUID()
    let profileID: UUID
    let name: String
    let kind: Kind
    let schema: String
    let object: String
    let objectKind: String
    let engine: DatabaseEngine?
    let identity: String?
    /// PostgreSQL's connection-local type handle is independent of parent kinds.
    let localOID: String?
    let typeKind: String?
    let typeOrigin: PostgresTypeCatalogOrigin?
    let parentObjectKind: String?
    let detail: String?
    @Published var children: [CatalogNode]?
    @Published var isExpanded = false
    @Published var isLoading = false
    @Published var error: String?

    init(profileID: UUID, name: String, kind: Kind, schema: String,
         object: String = "", objectKind: String = "", identity: String? = nil, detail: String? = nil,
         engine: DatabaseEngine? = nil, localOID: String? = nil, typeKind: String? = nil,
         parentObjectKind: String? = nil, typeOrigin: PostgresTypeCatalogOrigin? = nil) {
        self.profileID = profileID
        self.name = name
        self.kind = kind
        self.schema = schema
        self.object = object
        self.objectKind = objectKind
        self.engine = engine
        self.identity = identity
        self.localOID = localOID
        self.typeKind = typeKind
        self.typeOrigin = typeOrigin
        self.parentObjectKind = parentObjectKind
        self.detail = detail
    }

    var isExpandable: Bool {
        kind == .schema || kind == .group || kind == .detailGroup ||
            (kind == .object && !isPostgresType && ["table", "view", "type"].contains(objectKind))
    }

    var isPostgresType: Bool { engine == .postgresql && ["enum", "type"].contains(objectKind) }

    var symbol: String {
        switch kind {
        case .schema: "cylinder.split.1x2"
        case .group, .detailGroup: "folder"
        case .detail: "list.bullet"
        case .object:
            switch objectKind {
            case "table": "tablecells"
            case "view": "eye"
            case "function", "procedure": "function"
            case "trigger": "bolt"
            case "enum": "list.number"
            case "type": "curlybraces"
            default: "doc.text"
            }
        }
    }
}

struct CatalogInspection: Identifiable {
    let id = UUID()
    let title: String
    var structure: BackendMessage?
    var definition: String?
    var error: String?
    var isLoading = true
}

extension BackendMessage {
    /// Catalog responses have fixed, unique column names; ordinary SQL results
    /// continue to use ordered arrays, including duplicate column names.
    var catalogRecords: [[String: String]] {
        guard let columns else { return [] }
        return (rows ?? []).map { row in
            Dictionary(columns.enumerated().compactMap { index, column in
                guard index < row.count, let value = row[index] else { return nil }
                return (column.name, value)
            }, uniquingKeysWith: { _, last in last })
        }
    }
}
