import Foundation

struct TableForeignKeyColumn: Equatable, Sendable {
    let source: String
    let target: String
    let position: Int
}

/// Column pairs are ordered by their position in the database constraint.
struct TableForeignKey: Identifiable, Equatable, Sendable {
    let name: String
    let target: TableReference
    let columns: [TableForeignKeyColumn]

    var id: String { [name, target.schema, target.name].map { Data($0.utf8).base64EncodedString() }.joined(separator: ":") }
    var displayLabel: String { name + " → " + target.schema + "." + target.name }

    static func parse(_ result: BackendMessage) throws -> [Self] {
        let records = result.catalogRecords
        guard result.truncated != true, (result.rowCount ?? Int64(records.count)) <= Int64(records.count),
              records.count <= 32_000 else {
            throw TableNavigationFailure("Foreign-key metadata is incomplete. Reload the metadata before following related rows.")
        }
        if !records.isEmpty {
            let names = (result.columns ?? []).map(\.name)
            guard Set(names).count == names.count,
                  Set(["name", "targetSchema", "targetTable", "sourceColumn", "targetColumn", "position"]).isSubset(of: Set(names)) else {
                throw TableNavigationFailure("The foreign-key metadata columns are incomplete or ambiguous.")
            }
        }
        var keys: [Data: Self] = [:]
        for record in records {
            guard let name = record["name"], validName(name),
                  let schema = record["targetSchema"], validName(schema),
                  let table = record["targetTable"], validName(table),
                  let source = record["sourceColumn"], validName(source),
                  let target = record["targetColumn"], validName(target),
                  let rawPosition = record["position"], let position = Int(rawPosition), (1...32).contains(position) else {
                throw TableNavigationFailure("The foreign-key metadata is malformed. Reload the metadata before following related rows.")
            }
            let reference = TableReference(schema: schema, name: table, kind: "table")
            let pair = TableForeignKeyColumn(source: source, target: target, position: position)
            if let existing = keys[Data(name.utf8)] {
                guard Data(existing.target.schema.utf8) == Data(reference.schema.utf8),
                      Data(existing.target.name.utf8) == Data(reference.name.utf8) else {
                    throw TableNavigationFailure("A foreign key has inconsistent target metadata.")
                }
                keys[Data(name.utf8)] = Self(name: name, target: reference, columns: existing.columns + [pair])
            } else { keys[Data(name.utf8)] = Self(name: name, target: reference, columns: [pair]) }
        }
        guard keys.count <= 1_000 else { throw TableNavigationFailure("Too many foreign keys were returned. Narrow the metadata request and retry.") }
        return try keys.values.sorted { Data($0.name.utf8).lexicographicallyPrecedes(Data($1.name.utf8)) }.map { key in
            let ordered = key.columns.sorted { $0.position < $1.position }
            let result = Self(name: key.name, target: key.target, columns: ordered)
            guard result.isValid else { throw TableNavigationFailure("A foreign key has incomplete or duplicate column mappings.") }
            return result
        }
    }

    func sameMapping(as other: Self) -> Bool {
        Data(name.utf8) == Data(other.name.utf8) && Data(target.schema.utf8) == Data(other.target.schema.utf8) &&
            Data(target.name.utf8) == Data(other.target.name.utf8) && target.kind == other.target.kind &&
            columns.count == other.columns.count && zip(columns, other.columns).allSatisfy { pair in
                pair.0.position == pair.1.position && Data(pair.0.source.utf8) == Data(pair.1.source.utf8) && Data(pair.0.target.utf8) == Data(pair.1.target.utf8)
            }
    }

    var isValid: Bool {
        Self.validName(name) && Self.validName(target.schema) && Self.validName(target.name) && target.kind == "table" &&
            !columns.isEmpty && columns.count <= 32 && columns.map(\.position) == Array(1...columns.count) &&
            columns.allSatisfy { Self.validName($0.source) && Self.validName($0.target) } &&
            Set(columns.map { Data($0.source.utf8) }).count == columns.count && Set(columns.map { Data($0.target.utf8) }).count == columns.count
    }

    /// A composite key always becomes one equality filter per mapped column.
    /// Values retain their transport representation, including exact numbers
    /// and Base64 binary. SQL NULL never identifies a related row.
    func filters(sourceColumns: [ResultColumn], values: [ChangeValue]) throws -> [CatalogFilter] {
        guard isValid else { throw TableNavigationFailure("The foreign-key column mapping is invalid.") }
        return try columns.map { pair in
            let matches = sourceColumns.indices.filter { Data(sourceColumns[$0].name.utf8) == Data(pair.source.utf8) }
            guard matches.count == 1, let index = matches.first, values.indices.contains(index) else {
                throw TableNavigationFailure("The source row does not contain an unambiguous value for every foreign-key column. Reload the table.")
            }
            let value = values[index]
            if let storage = value.sqliteValue {
                guard storage.type != "null" else { throw TableNavigationFailure("This row has a NULL key value and does not identify related rows.") }
                let filter = CatalogFilter(column: pair.target, operator: "eq", sqliteValue: storage)
                guard filter.isValid else { throw TableNavigationFailure("This SQLite key value cannot be represented by the table filter.") }
                return filter
            }
            switch value.kind {
            case "null": throw TableNavigationFailure("This row has a NULL foreign-key value and does not identify a related row.")
            case "default": throw TableNavigationFailure("A DEFAULT foreign-key value is not known yet. Apply the changes and reload the row before following it.")
            case "text", "binary":
                guard let text = value.value, text.utf8.count <= 1_024 * 1_024, !text.contains("\0"),
                      value.kind != "binary" || Data(base64Encoded: text) != nil else {
                    throw TableNavigationFailure("The foreign-key value cannot be represented by the table filter. Use SQL to inspect this relationship.")
                }
                return CatalogFilter(column: pair.target, operator: "eq", value: text)
            default: throw TableNavigationFailure("The foreign-key value has an unsupported representation.")
            }
        }
    }

    private static func validName(_ name: String) -> Bool { !name.isEmpty && name.utf8.count <= 1_024 && !name.contains("\0") }
}

/// Navigation contains context only. Each document retains its own runtime;
/// result rows, cursors and pending edits cannot enter the history.
struct TableViewLocation: Equatable, Sendable {
    let reference: TableReference
    let profileID: UUID
    let title: String
    let page: Int
    let relationshipScope: SQLiteRelationshipScope?
    let filterExpression: CatalogFilterExpression?
    var filters: [CatalogFilter] { filterExpression?.flattenedConjunction ?? [] }
    let sort: [CatalogSort]

    @MainActor init?(_ document: SQLDocument) {
        guard let reference = document.table, let profileID = document.profileID else { return nil }
        self.reference = reference
        self.profileID = profileID
        title = document.title
        page = document.page
        relationshipScope = document.tableRelationshipScope
        filterExpression = document.tableFilterExpression
        sort = document.tableSort
    }

    init(reference: TableReference, profileID: UUID, title: String? = nil,
         page: Int = 0, filters: [CatalogFilter] = [], sort: [CatalogSort] = [], relationshipScope: SQLiteRelationshipScope? = nil) {
        self.reference = reference
        self.profileID = profileID
        self.title = title ?? reference.name
        self.page = page
        self.relationshipScope = relationshipScope
        self.filterExpression = .conjunction(filters)
        self.sort = sort
    }
}

struct TableNavigationFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
