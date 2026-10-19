import Foundation

struct ChangeValue: Codable, Equatable, Sendable {
    var kind: String
    var value: String?

    static let null = ChangeValue(kind: "null")
    static let `default` = ChangeValue(kind: "default")
}

struct ChangeColumn: Codable, Equatable, Sendable {
    var name: String
    var engine: DatabaseEngine
    var nativeType: String
}

struct ColumnAssignment: Codable, Equatable, Sendable {
    var column: String
    var value: ChangeValue
}

struct RowChange: Codable, Equatable, Sendable {
    var kind: String
    var original: [ChangeValue]?
    var values: [ColumnAssignment]?
}

struct ChangesRequest: Codable, Equatable, Sendable {
    var schema: String
    var table: String
    var columns: [ChangeColumn]
    var changes: [RowChange]
}

struct GridRow: Identifiable {
    let id = UUID()
    let original: [ChangeValue]?
    var values: [ChangeValue]
    var assignments: [Int: ChangeValue] = [:]
    var isDeleted = false
    var isInserted: Bool { original == nil }
}

@MainActor
final class GridDraft: ObservableObject {
    let reference: TableReference
    let columns: [ResultColumn]
    let metadata: [[String: String]]
    @Published var rows: [GridRow]
    @Published var selectedRows: IndexSet = []
    @Published var isApplying = false
    @Published var isPreviewing = false
    @Published var isReloading = false
    @Published var isClosing = false
    @Published var outcomeUnknown = false
    @Published var error: String?
    @Published var notice: String?
    @Published var preview: BackendMessage?
    var policyReadOnly = false
    var applySessionID: String?
    var applyQueryID: String?
    var cancelRequested = false

    init(reference: TableReference, result: BackendMessage, metadata: [[String: String]]) {
        self.reference = reference
        let loadedColumns = result.columns ?? []
        columns = loadedColumns
        let byName = Dictionary(metadata.compactMap { record in record["name"].map { ($0, record) } }, uniquingKeysWith: { _, last in last })
        self.metadata = columns.map { byName[$0.name] ?? [:] }
        rows = (result.rows ?? []).map { row in
            let values = row.enumerated().map { index, value -> ChangeValue in
                guard let value else { return .null }
                return ChangeValue(kind: loadedColumns.indices.contains(index) && loadedColumns[index].encoding == "base64" ? "binary" : "text", value: value)
            }
            return GridRow(original: values, values: values)
        }
    }

    var editableColumns: IndexSet {
        IndexSet(metadata.indices.filter { metadata[$0]["editable"] == "true" })
    }

    var readOnlyReason: String? {
        if policyReadOnly { return "Readonly is enabled for this connection." }
        if reference.kind != "table" { return "Views are read only." }
        if !metadata.contains(where: { (Int($0["primaryKey"] ?? "0") ?? 0) > 0 }) { return "This table has no primary key." }
        if editableColumns.isEmpty {
            if !metadata.isEmpty, metadata.allSatisfy({ !($0["generated"] ?? "").isEmpty }) { return nil }
            return metadata.compactMap { $0["editReason"] }.first { !$0.isEmpty } ?? "This table cannot be edited with its current types and permissions."
        }
        return nil
    }

    var canEdit: Bool { readOnlyReason == nil && !isApplying && !isReloading && !isClosing && !outcomeUnknown }
    var pendingCount: Int { rows.filter { $0.isInserted || $0.isDeleted || !$0.assignments.isEmpty }.count }
    var displayedRows: [[String?]] {
        rows.map { row in row.values.map { value in value.kind == "null" ? nil : (value.kind == "default" ? "<DEFAULT>" : value.value ?? "") } }
    }
    var deletedRows: IndexSet { IndexSet(rows.indices.filter { rows[$0].isDeleted }) }
    var modifiedCells: Set<ResultGridCell> {
        Set(rows.indices.flatMap { row in
            (rows[row].isInserted ? Array(columns.indices) : Array(rows[row].assignments.keys)).map { ResultGridCell(row: row, column: $0) }
        })
    }

    func value(row: Int, column: Int) -> ChangeValue? {
        guard rows.indices.contains(row), rows[row].values.indices.contains(column) else { return nil }
        return rows[row].values[column]
    }

    func set(_ value: ChangeValue, row: Int, column: Int) {
        guard canEdit, rows.indices.contains(row), rows[row].values.indices.contains(column),
              editableColumns.contains(column), !rows[row].isDeleted else { return }
        rows[row].values[column] = value
        if rows[row].original?[column] == value { rows[row].assignments[column] = nil }
        else { rows[row].assignments[column] = value }
        preview = nil
        notice = nil
    }

    func insert() {
        guard canEdit else { return }
        rows.append(GridRow(original: nil, values: columns.map { _ in .default }))
        selectedRows = IndexSet(integer: rows.count - 1)
        preview = nil
    }

    func deleteSelected() {
        guard canEdit else { return }
        for row in selectedRows.sorted(by: >) where rows.indices.contains(row) {
            if rows[row].isInserted { rows.remove(at: row) }
            else { rows[row].isDeleted = true }
        }
        selectedRows = []
        preview = nil
    }

    func discard() {
        guard !isApplying, !isReloading, !isClosing else { return }
        rows = rows.compactMap { row in row.original.map { GridRow(original: $0, values: $0) } }
        selectedRows = []
        error = nil
        preview = nil
    }

    func request() -> ChangesRequest {
        ChangesRequest(schema: reference.schema, table: reference.name,
            columns: columns.enumerated().map { index, column in
                ChangeColumn(name: column.name, engine: column.engine, nativeType: metadata[index]["nativeType"] ?? column.nativeType)
            }, changes: rows.compactMap { row in
                if row.isInserted {
                    return RowChange(kind: "insert", values: row.assignments.keys.sorted().map {
                        ColumnAssignment(column: columns[$0].name, value: row.assignments[$0]!)
                    })
                }
                if row.isDeleted { return RowChange(kind: "delete", original: row.original) }
                guard !row.assignments.isEmpty else { return nil }
                return RowChange(kind: "update", original: row.original, values: row.assignments.keys.sorted().map {
                    ColumnAssignment(column: columns[$0].name, value: row.assignments[$0]!)
                })
            })
    }
}
