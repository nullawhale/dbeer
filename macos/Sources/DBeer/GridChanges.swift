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
    var storageToken: String?
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
    var originalStorageToken: String?
    var isInserted: Bool { original == nil }
}

/// The immutable table content is shared across selection and focus updates.
/// Its identity changes only after the underlying draft rows change.
final class GridPresentation {
    let rows: [[String?]]
    let valueKinds: [[String]]
    let deletedRows: IndexSet
    let modifiedCells: Set<ResultGridCell>
    let pendingCount: Int

    init(rows source: [GridRow], columnCount: Int) {
        var rows: [[String?]] = []
        var valueKinds: [[String]] = []
        var deletedRows = IndexSet()
        var modifiedCells = Set<ResultGridCell>()
        var pendingCount = 0
        rows.reserveCapacity(source.count)
        valueKinds.reserveCapacity(source.count)
        for (index, row) in source.enumerated() {
            rows.append(row.values.map { value in
                value.kind == "null" ? nil : (value.kind == "default" ? "<DEFAULT>" : value.value ?? "")
            })
            valueKinds.append(row.values.map(\.kind))
            if row.isDeleted { deletedRows.insert(index) }
            if row.isInserted || row.isDeleted || !row.assignments.isEmpty { pendingCount += 1 }
            if row.isInserted {
                for column in 0..<columnCount { modifiedCells.insert(ResultGridCell(row: index, column: column)) }
            } else {
                for column in row.assignments.keys { modifiedCells.insert(ResultGridCell(row: index, column: column)) }
            }
        }
        self.rows = rows
        self.valueKinds = valueKinds
        self.deletedRows = deletedRows
        self.modifiedCells = modifiedCells
        self.pendingCount = pendingCount
    }
}

@MainActor
final class GridDraft: ObservableObject {
    let reference: TableReference
    let columns: [ResultColumn]
    let metadata: [[String: String]]
    let querySource: SQLResultSource?
    let querySessionID: String?
    @Published var resultIsStale = false
    let partitionMarkers: [GridPartitionMarker?]?
    @Published var rows: [GridRow] {
        didSet { cachedPresentation = nil }
    }
    @Published var selectedRows: IndexSet = []
    @Published var hasInlineDraft = false
    @Published var isApplying = false
    @Published var isPreviewing = false
    @Published var isReloading = false
    @Published var isClosing = false
    @Published var outcomeUnknown = false
    @Published var error: String?
    @Published var notice: String?
    @Published var preview: BackendMessage?
    var policyReadOnly = false
    var supportsEditing = true
    var applySessionID: String?
    var applyQueryID: String?
    var cancelRequested = false
    // The native grid installs a weak coordinator callback for in-progress cell edits.
    var commitEditing: (() -> Void)?
    private var cachedPresentation: GridPresentation?

    init(reference: TableReference, result: BackendMessage, metadata: [[String: String]], querySource: SQLResultSource? = nil) {
        self.querySource = querySource
        querySessionID = querySource == nil ? nil : result.sessionId
        self.reference = reference
        let loadedColumns = result.columns ?? []
        columns = loadedColumns
        let byName = Dictionary(metadata.compactMap { record in record["name"].map { ($0, record) } }, uniquingKeysWith: { _, last in last })
        let alignedMetadata = querySource.map { source in source.columns.map {
            ["name": $0.name, "nativeType": $0.nativeType, "primaryKey": String($0.primaryKey),
             "editable": $0.editable ? "true" : "false", "generated": $0.generated ? "generated" : "", "nullable": "true"]
        } } ?? columns.map { byName[$0.name] ?? [:] }
        self.metadata = alignedMetadata
        let loadedRows = (result.rows ?? []).enumerated().map { rowIndex, row in
            let values = row.enumerated().map { index, value -> ChangeValue in
                guard let value else { return .null }
                return ChangeValue(kind: loadedColumns.indices.contains(index) && loadedColumns[index].encoding == "base64" ? "binary" : "text", value: value)
            }
            return GridRow(original: values, values: values, originalStorageToken: result.storageTokens.flatMap { $0.indices.contains(rowIndex) ? $0[rowIndex] : nil })
        }
        rows = loadedRows
        partitionMarkers = GridPartitions.markers(columns: loadedColumns, metadata: alignedMetadata, rows: loadedRows)
    }

    var editableColumns: IndexSet {
        IndexSet(metadata.indices.filter { metadata[$0]["editable"] == "true" })
    }

    var isCassandra: Bool { columns.first?.engine == .cassandra }
    var supportsRowInsertionAndDeletion: Bool { !isCassandra && querySource == nil }
    var editingNotice: String? {
        guard isCassandra, supportsEditing else { return nil }
        return "Apply saves all pending rows atomically within one partition. If any original value changed, no rows are saved. Rows from different partitions cannot be applied together. A timeout can leave the whole batch outcome unknown. Updated cells use the table's default TTL; existing cell TTLs are not preserved."
    }

    var readOnlyReason: String? {
        if resultIsStale { return "This result is stale. Discard pending changes and run the query explicitly to load current data." }
        if let reason = querySource?.readOnlyReason, !reason.isEmpty { return reason }
        if !supportsEditing { return "Grid editing is not supported by this database engine." }
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
    var presentation: GridPresentation {
        if let cachedPresentation { return cachedPresentation }
        let presentation = GridPresentation(rows: rows, columnCount: columns.count)
        cachedPresentation = presentation
        return presentation
    }
    var pendingCount: Int { presentation.pendingCount }
    var displayedRows: [[String?]] { presentation.rows }
    var valueKinds: [[String]] { presentation.valueKinds }
    var deletedRows: IndexSet { presentation.deletedRows }
    var modifiedCells: Set<ResultGridCell> { presentation.modifiedCells }
    var partitionStatus: GridPartitionStatus? {
        guard let partitionMarkers else { return nil }
        let pending = rows.indices.filter { rows[$0].isInserted || rows[$0].isDeleted || !rows[$0].assignments.isEmpty }
        guard !pending.isEmpty else { return nil }
        var groups: [Int: GridPartitionMarker] = [:]
        for row in pending {
            guard partitionMarkers.indices.contains(row), let marker = partitionMarkers[row] else { return .unavailable }
            groups[marker.number] = marker
        }
        if groups.count == 1, let marker = groups.values.first { return .single(marker) }
        return .multiple(groups.count)
    }
    var canApply: Bool { canEdit && partitionStatus?.allowsApply != false }

    func value(row: Int, column: Int) -> ChangeValue? {
        guard rows.indices.contains(row), rows[row].values.indices.contains(column) else { return nil }
        return rows[row].values[column]
    }

    func set(_ value: ChangeValue, row: Int, column: Int) {
        guard canEdit, rows.indices.contains(row), rows[row].values.indices.contains(column),
              editableColumns.contains(column), !rows[row].isDeleted else { return }
        if isCassandra {
            guard value.kind != "default" else { return }
        }
        error = nil
        rows[row].values[column] = value
        if rows[row].original?[column] == value { rows[row].assignments[column] = nil }
        else { rows[row].assignments[column] = value }
        preview = nil
        notice = nil
    }

    func insert() {
        guard canEdit, supportsRowInsertionAndDeletion else { return }
        rows.append(GridRow(original: nil, values: columns.map { _ in .default }))
        selectedRows = IndexSet(integer: rows.count - 1)
        preview = nil
    }

    func deleteSelected() {
        guard canEdit, supportsRowInsertionAndDeletion else { return }
        for row in selectedRows.sorted(by: >) where rows.indices.contains(row) {
            if rows[row].isInserted { rows.remove(at: row) }
            else { rows[row].isDeleted = true }
        }
        selectedRows = []
        preview = nil
    }

    func discardAfterSuccessfulApply() {
        rows = rows.map { row in GridRow(original: row.values, values: row.values, originalStorageToken: nil) }
        selectedRows = []
        error = nil
        preview = nil
    }

    func discard() {
        guard !isApplying, !isReloading, !isClosing else { return }
        rows = rows.compactMap { row in row.original.map { GridRow(original: $0, values: $0, originalStorageToken: row.originalStorageToken) } }
        selectedRows = []
        error = nil
        preview = nil
    }

    func request() -> ChangesRequest {
        let order = columns.indices.sorted { (querySource?.columns[$0].tableIndex ?? $0) < (querySource?.columns[$1].tableIndex ?? $1) }
        func name(_ index: Int) -> String { querySource?.columns[index].name ?? columns[index].name }
        return ChangesRequest(schema: reference.schema, table: reference.name,
            columns: order.map { index in
                ChangeColumn(name: name(index), engine: columns[index].engine, nativeType: metadata[index]["nativeType"] ?? columns[index].nativeType)
            }, changes: rows.compactMap { row in
                if row.isInserted {
                    return RowChange(kind: "insert", values: row.assignments.keys.sorted().map {
                        ColumnAssignment(column: name($0), value: row.assignments[$0]!)
                    })
                }
                let original = row.original.map { original in order.map { original[$0] } }
                if row.isDeleted { return RowChange(kind: "delete", original: original, storageToken: row.originalStorageToken) }
                guard !row.assignments.isEmpty else { return nil }
                return RowChange(kind: "update", original: original, values: row.assignments.keys.sorted().map {
                    ColumnAssignment(column: name($0), value: row.assignments[$0]!)
                }, storageToken: row.originalStorageToken)
            })
    }
}
