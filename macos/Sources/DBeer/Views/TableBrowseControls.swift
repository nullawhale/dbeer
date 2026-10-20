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

    private var columns: [String] { document.tableColumns.compactMap { $0["name"] } }
    private var operators: [(String, String)] {
        [("=", "eq"), ("≠", "ne"), ("<", "lt"), ("≤", "lte"), (">", "gt"), ("≥", "gte"),
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
                            reload()
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
        document.tableFilters.append(CatalogFilter(column: filterColumn.wrappedValue,
            operator: filterOperator.wrappedValue,
            value: ["isNull", "isNotNull"].contains(filterOperator.wrappedValue) ? nil : filterValue.wrappedValue))
        reload()
    }

    private func reload() {
        document.page = 0
        Task { await workspace.run(document) }
    }
}

/// Sorting, paging and filtering must never replace a pending or uncertain draft.
@MainActor
enum TableBrowseNavigation {
    static func isEnabled(document: SQLDocument, workspace: ApplicationWorkspace) -> Bool {
        !document.isRunning && !workspace.isClosing && document.grid?.isClosing != true &&
            document.grid?.hasInlineDraft != true &&
            (document.grid?.pendingCount ?? 0) == 0 && document.grid?.isApplying != true &&
            document.grid?.isReloading != true && document.grid?.isPreviewing != true &&
            document.grid?.outcomeUnknown != true
    }

    static func sort(column: String, document: SQLDocument, workspace: ApplicationWorkspace) {
        guard isEnabled(document: document, workspace: workspace) else { return }
        if let current = document.tableSort.first, current.column == column {
            document.tableSort = current.direction == "asc" ? [CatalogSort(column: column, direction: "desc")] : []
        } else {
            document.tableSort = [CatalogSort(column: column, direction: "asc")]
        }
        document.page = 0
        Task { await workspace.run(document) }
    }
}
