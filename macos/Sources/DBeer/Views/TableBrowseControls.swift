import SwiftUI

/// The filter editor is opened beside the connection picker above the table.
struct TableBrowseControls: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var workspace: ApplicationWorkspace
    private var filterColumn = SwiftUI.State(initialValue: "")
    private var filterOperator = SwiftUI.State(initialValue: "eq")
    private var filterValue = SwiftUI.State(initialValue: "")

    init(document: SQLDocument, workspace: ApplicationWorkspace) {
        self.document = document
        self.workspace = workspace
    }

    private var isCassandra: Bool { TableBrowseNavigation.isCassandra(document: document, workspace: workspace) }
    private var columns: [String] {
        document.tableColumns.filter { !isCassandra || CassandraBrowseRules.canFilter($0, in: document) }.compactMap { $0["name"] }
    }
    private var operators: [(String, String)] {
        if isCassandra {
            let metadata = document.tableColumns.first { $0["name"] == filterColumn.wrappedValue } ?? [:]
            return CassandraBrowseRules.isClustering(metadata) ? [("=", "eq"), ("<", "lt"), ("≤", "lte"), (">", "gt"), ("≥", "gte")] : [("=", "eq")]
        }
        return [("=", "eq"), ("≠", "ne"), ("<", "lt"), ("≤", "lte"), (">", "gt"), ("≥", "gte"),
         ("Contains", "contains"), ("IS NULL", "isNull"), ("IS NOT NULL", "isNotNull")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filter Rows").font(.headline)
            HStack(spacing: 8) {
                Picker("Column", selection: filterColumn.projectedValue) {
                    Text("Choose…").tag("")
                    ForEach(columns, id: \.self) { Text($0).tag($0) }
                }.controlHover().labelsHidden().accessibilityLabel("Filter column")
                Picker("Filter", selection: filterOperator.projectedValue) {
                    ForEach(operators, id: \.1) { Text($0.0).tag($0.1) }
                }.controlHover().labelsHidden().accessibilityLabel("Filter operator").frame(width: 115)
            }
            if !["isNull", "isNotNull"].contains(filterOperator.wrappedValue) {
                TextField("Value", text: filterValue.projectedValue).textFieldStyle(.roundedBorder)
                    .help("Binary column values use Base64.")
                    .onSubmit(addFilter)
            }
            HStack {
                Spacer()
                Button("Add Filter", action: addFilter).controlHover()
                    .disabled(filterColumn.wrappedValue.isEmpty)
            }
            if isCassandra {
                Text("Partition keys require equality. Clustering filters and sorting require the full partition key. Indexed columns support equality. Generated filters support scalar values; use CQL for tuple, UDT, collection, or vector keys. DBeer never adds ALLOW FILTERING.")
                    .font(.caption).appSecondaryText()
                Button("Apply Filters", action: reload).controlHover()
                    .disabled(!CassandraBrowseRules.canApplyFilters(document))
                    .accessibilityIdentifier("applyCassandraFilters")
            }
            if !document.tableFilters.isEmpty {
                Divider()
                ForEach(Array(document.tableFilters.enumerated()), id: \.offset) { index, filter in
                    HStack {
                        Text("\(filter.column) \(filter.operator) \(filter.value ?? "")")
                            .lineLimit(2).textSelection(.enabled)
                        Spacer()
                        ControlIconButton(systemName: "xmark") {
                            guard canNavigate else { return }
                            document.tableFilters.remove(at: index)
                            if !isCassandra { reload() }
                        }.help("Remove filter").accessibilityLabel("Remove filter")
                    }
                }
            }
        }
        .font(.callout).padding(16).frame(width: 380)
        .disabled(!canNavigate)
    }

    private var canNavigate: Bool { TableBrowseNavigation.isEnabled(document: document, workspace: workspace) }

    private func addFilter() {
        guard canNavigate, !filterColumn.wrappedValue.isEmpty else { return }
        if isCassandra, !operators.contains(where: { $0.1 == filterOperator.wrappedValue }) { filterOperator.wrappedValue = "eq" }
        if isCassandra { document.tableFilters.removeAll { $0.column == filterColumn.wrappedValue && $0.operator == filterOperator.wrappedValue } }
        document.tableFilters.append(CatalogFilter(column: filterColumn.wrappedValue,
            operator: filterOperator.wrappedValue,
            value: ["isNull", "isNotNull"].contains(filterOperator.wrappedValue) ? nil : filterValue.wrappedValue))
        if !isCassandra { reload() }
    }

    private func reload() {
        document.resetTablePaging()
        Task { await workspace.run(document) }
    }
}

/// Sorting, paging and filtering must never replace a pending or uncertain draft.
@MainActor
enum TableBrowseNavigation {
    static func isEnabled(document: SQLDocument, workspace: ApplicationWorkspace) -> Bool {
        !document.isRunning && !document.isNavigatingTable && !workspace.isClosing && document.grid?.isClosing != true &&
            document.grid?.hasInlineDraft != true &&
            (document.grid?.pendingCount ?? 0) == 0 && document.grid?.isApplying != true &&
            document.grid?.isReloading != true && document.grid?.isPreviewing != true &&
            document.grid?.outcomeUnknown != true
    }

    @discardableResult
    static func nextPage(document: SQLDocument, workspace: ApplicationWorkspace) -> Task<Void, Never>? {
        guard isEnabled(document: document, workspace: workspace) else { return nil }
        if document.runtime?.usesCursorPagination == true {
            guard let cursor = document.tableNextCursor else { return nil }
            document.tableCursor = cursor
            document.tableNextCursor = nil
        } else if (document.grid?.rows.count ?? 0) < 200 { return nil }
        document.page += 1
        return Task { await workspace.run(document) }
    }

    static func isCassandra(document: SQLDocument, workspace: ApplicationWorkspace) -> Bool {
        document.runtime?.engine == .cassandra || workspace.library.savedConnections.first { $0.id == document.profileID }?.engine == .cassandra
    }

    static func sort(column: String, document: SQLDocument, workspace: ApplicationWorkspace) {
        guard isEnabled(document: document, workspace: workspace),
              !isCassandra(document: document, workspace: workspace) ||
                (CassandraBrowseRules.canApplyFilters(document) && CassandraBrowseRules.canSort(column, in: document)) else { return }
        if let current = document.tableSort.first, current.column == column {
            document.tableSort = current.direction == "asc" ? [CatalogSort(column: column, direction: "desc")] : []
        } else {
            document.tableSort = [CatalogSort(column: column, direction: "asc")]
        }
        document.page = 0
        Task { await workspace.run(document) }
    }
}

/// Mirrors the helper's safe generated-CQL subset; the helper validates again.
@MainActor
enum CassandraBrowseRules {
    private static let scalarFilterTypes: Set<String> = ["ascii", "text", "varchar", "int", "bigint", "smallint", "tinyint", "counter", "uuid", "timeuuid", "inet", "date", "duration", "blob", "boolean", "varint", "decimal", "float", "double", "timestamp", "time"]

    static func isSupportedFilterType(_ column: [String: String]) -> Bool {
        guard let nativeType = column["nativeType"] else { return false }
        return scalarFilterTypes.contains(nativeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func isClustering(_ column: [String: String]) -> Bool { (Int(column["clusteringPosition"] ?? "0") ?? 0) > 0 }

    static func hasFullPartitionKey(_ document: SQLDocument) -> Bool {
        let keys = document.tableColumns.filter { (Int($0["partitionKeyPosition"] ?? "0") ?? 0) > 0 }
        return !keys.isEmpty && keys.allSatisfy { column in
            let filters = document.tableFilters.filter { $0.column == column["name"] }
            return isSupportedFilterType(column) && filters.count == 1 && filters[0].operator == "eq"
        }
    }

    static func canFilter(_ column: [String: String], in document: SQLDocument) -> Bool {
        guard isSupportedFilterType(column) else { return false }
        if (Int(column["partitionKeyPosition"] ?? "0") ?? 0) > 0 || column["indexed"] == "true" { return true }
        guard hasFullPartitionKey(document), isClustering(column) else { return false }
        let position = Int(column["clusteringPosition"] ?? "0") ?? 0
        return precedingClusteringKeysEqual(position, in: document)
    }

    static func canSort(_ name: String, in document: SQLDocument) -> Bool {
        guard hasFullPartitionKey(document), let column = document.tableColumns.first(where: { $0["name"] == name }),
              isClustering(column) else { return false }
        return precedingClusteringKeysEqual(Int(column["clusteringPosition"] ?? "0") ?? 0, in: document)
    }

    static func hasValidSort(_ document: SQLDocument) -> Bool {
        document.tableSort.count <= 1 && document.tableSort.allSatisfy {
            ["asc", "desc"].contains($0.direction) && canSort($0.column, in: document)
        }
    }

    static func canApplyFilters(_ document: SQLDocument) -> Bool {
        let filters = document.tableFilters
        guard filters.count <= 32, hasValidSort(document), filters.allSatisfy({ filter in
            filter.value != nil && ["eq", "lt", "lte", "gt", "gte"].contains(filter.operator) &&
                document.tableColumns.contains { $0["name"] == filter.column && isSupportedFilterType($0) }
        }) else { return false }
        if filters.isEmpty { return true }
        if !hasFullPartitionKey(document) {
            return filters.count == 1 && filters[0].operator == "eq" && document.tableSort.isEmpty &&
                document.tableColumns.contains { $0["name"] == filters[0].column && $0["indexed"] == "true" }
        }
        guard filters.allSatisfy({ filter in
            document.tableColumns.contains { $0["name"] == filter.column &&
                ((Int($0["partitionKeyPosition"] ?? "0") ?? 0) > 0 || isClustering($0)) }
        }) else { return false }
        let clustering = document.tableColumns.filter(isClustering).sorted {
            (Int($0["clusteringPosition"] ?? "0") ?? 0) < (Int($1["clusteringPosition"] ?? "0") ?? 0)
        }
        var ended = false
        var rangeSeen = false
        for column in clustering {
            let conditions = filters.filter { $0.column == column["name"] }
            if conditions.isEmpty { ended = true; continue }
            guard !ended, !rangeSeen else { return false }
            if conditions.count == 1, conditions[0].operator == "eq" { continue }
            let lower = conditions.filter { ["gt", "gte"].contains($0.operator) }.count
            let upper = conditions.filter { ["lt", "lte"].contains($0.operator) }.count
            guard lower <= 1, upper <= 1, lower + upper == conditions.count else { return false }
            rangeSeen = true
        }
        return true
    }

    private static func precedingClusteringKeysEqual(_ position: Int, in document: SQLDocument) -> Bool {
        document.tableColumns.filter {
            let prior = Int($0["clusteringPosition"] ?? "0") ?? 0
            return prior > 0 && prior < position
        }.allSatisfy { prior in
            let filters = document.tableFilters.filter { $0.column == prior["name"] }
            return filters.count == 1 && filters[0].operator == "eq"
        }
    }
}
