import Foundation

/// Qualified identities are profile/database scoped. A local OID is a request
/// precondition on one service session, never a cross-server type identity.
struct PostgresTypeQualifiedIdentity: Equatable, Sendable {
    let profileID: UUID
    let engine: DatabaseEngine
    let database: String
    let schema: String
    let name: String
    let category: String
}

struct PostgresTypeCatalogOrigin: Equatable, Sendable {
    let serviceSessionID: String
    let serviceGeneration: UUID
    let settingsRevision: UUID
}

struct PostgresTypeReference: Equatable, Sendable {
    let profileID: UUID
    let serviceSessionID: String
    let serviceGeneration: UUID
    let engine: DatabaseEngine
    let database: String
    let schema: String
    let name: String
    let objectKind: String
    let localOID: String
    /// An opaque revision of saved settings and policy; contains no credentials,
    /// provider output, private keys, or password-command arguments.
    let settingsRevision: UUID
    let policy: ExecutionPolicy

    var qualifiedIdentity: PostgresTypeQualifiedIdentity {
        .init(profileID: profileID, engine: engine, database: database,
              schema: schema, name: name, category: objectKind)
    }

    func request(_ kind: String, change: TypeChange? = nil) -> CatalogRequest {
        CatalogRequest(kind: kind, schema: schema, object: name,
                       objectKind: objectKind, identity: localOID, typeChange: change)
    }

    var valid: Bool {
        engine == .postgresql && ["enum", "type"].contains(objectKind) &&
            PostgresTypeCatalog.validOID(localOID) && !schema.isEmpty && !name.isEmpty &&
            schema.utf8.count <= 63 && name.utf8.count <= 63 &&
            !schema.contains("\0") && !name.contains("\0") && !serviceSessionID.isEmpty
    }
}

enum PostgresTypeDefinitionStatus: String, Sendable { case complete, partial, unavailable }

struct PostgresTypeDetails: Equatable, Sendable {
    let typeKind: String
    let owner: String?
    let definition: String?
    let definitionStatus: PostgresTypeDefinitionStatus
    let details: String?
    let renameSupported: Bool
    let addEnumValueSupported: Bool
    let renameEnumValueSupported: Bool
    let operationLimitations: String?
    let permissionHint: String?

    func supports(_ operation: String) -> Bool {
        switch operation {
        case "renameType": renameSupported
        case "addEnumValue": addEnumValueSupported
        case "renameEnumValue": renameEnumValueSupported
        default: false
        }
    }
}

struct PostgresEnumValue: Identifiable, Equatable, Sendable {
    let label: String
    let position: Int
    let sortOrder: String
    var id: Int { position }
}

struct PostgresTypeDependency: Identifiable, Equatable, Sendable {
    let direction: String
    let objectKind: String
    let objectSchema: String?
    let objectName: String?
    let objectIdentity: String
    let dependencyClass: String
    let classID: String
    let objectID: String
    let objectSubID: String
    let referencedClassID: String
    let referencedObjectID: String
    let referencedObjectSubID: String
    var id: String {
        [direction, classID, objectID, objectSubID, referencedClassID,
         referencedObjectID, referencedObjectSubID, dependencyClass].joined(separator: ":")
    }
}

struct PostgresTypeDDLPreview: Equatable, Sendable {
    let sql: String
    let warnings: String?
    let change: TypeChange
}

struct PostgresCatalogObject: Sendable {
    let name: String
    let kind: String
    let schema: String
    let identity: String?
    let typeKind: String?
}

/// The lifecycle belongs to one inspector, profile revision and service session.
/// Task cancellation only stops queued work. Submitted work is explicitly
/// cancelled by its correlated catalog query ID through ApplicationWorkspace.
@MainActor
final class PostgresTypeCatalogRequest {
    let queryID = UUID().uuidString
    var task: Task<BackendMessage, Error>?
    var submitted = false
    var finished = false
    var cancelled = false
}

@MainActor
final class PostgresTypeInspectionModel: ObservableObject, Identifiable {
    let id = UUID()
    let reference: PostgresTypeReference
    let profileName: String
    let destination: ApplicationWorkspace.PaneSelectionContext
    var title: String { reference.schema + "." + reference.name }
    var destinationPane: WorkspacePaneID { destination.pane }
    @Published var details: PostgresTypeDetails?
    @Published var enumValues: [PostgresEnumValue]?
    @Published var dependencies: [PostgresTypeDependency]?
    @Published var enumValuesComplete = false
    @Published var dependenciesComplete = false
    @Published var metadataError: String?
    @Published var enumValuesError: String?
    @Published var dependenciesError: String?
    @Published var isLoading = false
    @Published var preview: PostgresTypeDDLPreview?
    @Published var previewError: String?
    @Published var isPreparingPreview = false
    @Published var cancellationNotice: String?
    @Published var invalidationReason: String?
    private(set) var generation: UInt64 = 0
    var activeRequest: PostgresTypeCatalogRequest?

    init(reference: PostgresTypeReference, profileName: String,
         destination: ApplicationWorkspace.PaneSelectionContext) {
        self.reference = reference
        self.profileName = profileName
        self.destination = destination
    }

    @discardableResult func advanceGeneration() -> UInt64 {
        generation &+= 1
        preview = nil
        previewError = nil
        isPreparingPreview = false
        return generation
    }

    var canOpenSQLDraft: Bool {
        preview != nil && !isPreparingPreview && !isLoading && invalidationReason == nil
    }
}

struct PostgresTypeCatalogFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    static var malformed: Self { .init(message: "Type metadata was incomplete or invalid. Refresh the inspector and try again.") }
}

enum PostgresTypeCatalog {
    static let detailColumns = ["name", "kind", "schema", "identity", "typeKind", "owner", "definition", "definitionStatus",
        "details", "renameSupported", "addEnumValueSupported", "renameEnumValueSupported", "operationLimitations", "permissionHint"]
    static let valueColumns = ["label", "position", "sortOrder"]
    static let dependencyColumns = ["direction", "objectKind", "objectSchema", "objectName", "objectIdentity", "dependencyClass",
        "classID", "objectID", "objectSubID", "referencedClassID", "referencedObjectID", "referencedObjectSubID"]
    static let previewColumns = ["sql", "warnings"]
    static let objectColumns = ["name", "kind", "schema", "identity", "typeKind"]

    static func sameBytes(_ first: String, _ second: String) -> Bool { first.utf8.elementsEqual(second.utf8) }
    static func validOID(_ text: String) -> Bool {
        guard let value = UInt32(text), value > 0 else { return false }
        return String(value) == text
    }
    private static func validSubID(_ text: String) -> Bool {
        guard let value = Int32(text), value >= 0 else { return false }
        return String(value) == text
    }

    static func fixedRows(_ reply: BackendMessage, columns: [String], requireComplete: Bool = false) throws -> [[String?]] {
        guard reply.type == "query.result", let actual = reply.columns, let rows = reply.rows,
              actual.map(\.name) == columns,
              actual.enumerated().allSatisfy({ $0.offset == $0.element.index && $0.element.encoding == nil && $0.element.engine == .postgresql }),
              rows.allSatisfy({ $0.count == columns.count }), let truncated = reply.truncated,
              reply.displayedRowCount == rows.count, let rowCount = reply.rowCount, rowCount >= Int64(rows.count),
              truncated || rowCount == Int64(rows.count), reply.streamed != true,
              !requireComplete || !truncated else { throw PostgresTypeCatalogFailure.malformed }
        return rows
    }

    static func decodeDetails(_ reply: BackendMessage, reference: PostgresTypeReference) throws -> PostgresTypeDetails {
        let rows = try fixedRows(reply, columns: detailColumns, requireComplete: true)
        guard rows.count == 1 else { throw PostgresTypeCatalogFailure.malformed }
        let row = rows[0]
        guard let name = row[0], sameBytes(name, reference.name), row[1] == reference.objectKind,
              let schema = row[2], sameBytes(schema, reference.schema), row[3] == reference.localOID,
              let kind = row[4], ["enum", "domain", "composite", "range", "multirange", "base"].contains(kind),
              (reference.objectKind == "enum") == (kind == "enum"), row[5] != nil,
              let rawStatus = row[7], let status = PostgresTypeDefinitionStatus(rawValue: rawStatus),
              validDefinition(row[6], status: status), row[8] != nil,
              let rename = flag(row[9]), let add = flag(row[10]), let renameValue = flag(row[11]),
              row[12] != nil, row[13] != nil,
              kind == "enum" || (!add && !renameValue) else { throw PostgresTypeCatalogFailure.malformed }
        return .init(typeKind: kind, owner: row[5], definition: row[6], definitionStatus: status,
            details: row[8], renameSupported: rename, addEnumValueSupported: add,
            renameEnumValueSupported: renameValue, operationLimitations: row[12], permissionHint: row[13])
    }

    private static func validDefinition(_ definition: String?, status: PostgresTypeDefinitionStatus) -> Bool {
        switch status {
        case .complete: definition?.isEmpty == false
        case .partial: definition == nil || definition?.isEmpty == false
        case .unavailable: definition == nil
        }
    }

    static func decodeObjects(_ reply: BackendMessage) throws -> [PostgresCatalogObject] {
        try fixedRows(reply, columns: objectColumns).map { row in
            guard let name = row[0], !name.isEmpty, let kind = row[1],
                  ["table", "view", "function", "procedure", "trigger", "enum", "type"].contains(kind),
                  let schema = row[2], !schema.isEmpty else { throw PostgresTypeCatalogFailure.malformed }
            if ["enum", "type"].contains(kind) {
                guard let oid = row[3], validOID(oid), let category = row[4],
                      ["enum", "domain", "composite", "range", "multirange", "base"].contains(category),
                      (kind == "enum") == (category == "enum") else { throw PostgresTypeCatalogFailure.malformed }
            } else if row[4] != nil { throw PostgresTypeCatalogFailure.malformed }
            return PostgresCatalogObject(name: name, kind: kind, schema: schema, identity: row[3], typeKind: row[4])
        }
    }

    static func decodeEnumValues(_ reply: BackendMessage) throws -> [PostgresEnumValue] {
        let rows = try fixedRows(reply, columns: valueColumns)
        var labels = Set<Data>()
        return try rows.enumerated().map { index, row in
            guard let label = row[0], label.utf8.count <= 63, !label.contains("\0"), let position = row[1], Int(position) == index + 1,
                  position == String(index + 1), let order = row[2], !order.isEmpty,
                  order.range(of: #"^-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
                  labels.insert(Data(label.utf8)).inserted else { throw PostgresTypeCatalogFailure.malformed }
            return .init(label: label, position: index + 1, sortOrder: order)
        }
    }

    static func decodeDependencies(_ reply: BackendMessage) throws -> [PostgresTypeDependency] {
        let rows = try fixedRows(reply, columns: dependencyColumns)
        var identities = Set<String>()
        return try rows.map { row in
            guard let direction = row[0], ["incoming", "outgoing"].contains(direction),
                  let kind = row[1], !kind.isEmpty, let identity = row[4], !identity.isEmpty,
                  let dependencyClass = row[5], !dependencyClass.isEmpty,
                  let classID = row[6], validOID(classID), let objectID = row[7], validOID(objectID),
                  let objectSubID = row[8], validSubID(objectSubID), let referencedClassID = row[9], validOID(referencedClassID),
                  let referencedObjectID = row[10], validOID(referencedObjectID),
                  let referencedObjectSubID = row[11], validSubID(referencedObjectSubID) else {
                throw PostgresTypeCatalogFailure.malformed
            }
            let result = PostgresTypeDependency(direction: direction, objectKind: kind, objectSchema: row[2],
                objectName: row[3], objectIdentity: identity, dependencyClass: dependencyClass,
                classID: classID, objectID: objectID, objectSubID: objectSubID,
                referencedClassID: referencedClassID, referencedObjectID: referencedObjectID,
                referencedObjectSubID: referencedObjectSubID)
            guard identities.insert(result.id).inserted else { throw PostgresTypeCatalogFailure.malformed }
            return result
        }
    }

    static func decodePreview(_ reply: BackendMessage, change: TypeChange) throws -> PostgresTypeDDLPreview {
        let rows = try fixedRows(reply, columns: previewColumns, requireComplete: true)
        guard rows.count == 1, let sql = rows[0][0], !sql.isEmpty, !sql.contains("\0"),
              let warnings = rows[0][1], reply.sql == nil else { throw PostgresTypeCatalogFailure.malformed }
        return .init(sql: sql, warnings: warnings, change: change)
    }

    static func validateChange(_ change: TypeChange, details: PostgresTypeDetails,
                               values: [PostgresEnumValue]?, valuesComplete: Bool) throws {
        guard details.supports(change.operation) else {
            throw PostgresTypeCatalogFailure(message: "This operation is unavailable for the selected type. Review its operation limitations.")
        }
        func valid(_ text: String?, empty: Bool) -> Bool {
            guard let text else { return false }
            return (empty || !text.isEmpty) && text.utf8.count <= 63 && !text.contains("\0")
        }
        switch change.operation {
        case "renameType":
            guard valid(change.newName, empty: false), change.oldValue == nil, change.value == nil else {
                throw PostgresTypeCatalogFailure(message: "Enter one type name of 1–63 UTF-8 bytes without NUL characters.")
            }
        case "addEnumValue":
            guard valid(change.value, empty: true), change.newName == nil, change.oldValue == nil else {
                throw PostgresTypeCatalogFailure(message: "Enter an enum label of at most 63 UTF-8 bytes without NUL characters. An empty label is valid.")
            }
        case "renameEnumValue":
            guard valid(change.oldValue, empty: true), valid(change.value, empty: true), change.newName == nil,
                  valuesComplete, values?.contains(where: { sameBytes($0.label, change.oldValue!) }) == true else {
                throw PostgresTypeCatalogFailure(message: "Refresh enum values and select an existing label. Labels may be empty and must fit in 63 UTF-8 bytes without NUL characters.")
            }
        default: throw PostgresTypeCatalogFailure.malformed
        }
    }

    private static func flag(_ value: String?) -> Bool? {
        switch value { case "true": true; case "false": false; default: nil }
    }
}
