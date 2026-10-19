import SwiftUI

struct TableBrowseControls: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var workspace: ApplicationWorkspace
    private var filterColumn = SwiftUI.State(initialValue: "")
    private var filterOperator = SwiftUI.State(initialValue: "eq")
    private var filterValue = SwiftUI.State(initialValue: "")
    private var sortColumn = SwiftUI.State(initialValue: "")
    private var sortDirection = SwiftUI.State(initialValue: "asc")

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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Column", selection: filterColumn.projectedValue) {
                    Text("Choose…").tag("")
                    ForEach(columns, id: \.self) { Text($0).tag($0) }
                }.controlHover().frame(maxWidth: 190)
                Picker("Filter", selection: filterOperator.projectedValue) {
                    ForEach(operators, id: \.1) { Text($0.0).tag($0.1) }
                }.controlHover().labelsHidden().frame(width: 115)
                if !["isNull", "isNotNull"].contains(filterOperator.wrappedValue) {
                    TextField("Value", text: filterValue.projectedValue).textFieldStyle(.roundedBorder)
                        .help("Binary column values use Base64.")
                }
                Button("Add Filter") {
                    document.tableFilters.append(CatalogFilter(column: filterColumn.wrappedValue,
                        operator: filterOperator.wrappedValue,
                        value: ["isNull", "isNotNull"].contains(filterOperator.wrappedValue) ? nil : filterValue.wrappedValue))
                    document.page = 0
                    Task { await workspace.run(document) }
                }.controlHover().disabled(filterColumn.wrappedValue.isEmpty)
            }
            if !document.tableFilters.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(document.tableFilters.enumerated()), id: \.offset) { index, filter in
                            Button {
                                document.tableFilters.remove(at: index)
                                document.page = 0
                                Task { await workspace.run(document) }
                            } label: {
                                Label("\(filter.column) \(filter.operator) \(filter.value ?? "")", systemImage: "xmark.circle")
                            }.controlHover().buttonStyle(.bordered)
                        }
                    }
                }
            }
            HStack {
                Picker("Sort", selection: sortColumn.projectedValue) {
                    Text("Primary key order").tag("")
                    ForEach(columns, id: \.self) { Text($0).tag($0) }
                }.controlHover().frame(maxWidth: 200)
                Picker("Direction", selection: sortDirection.projectedValue) {
                    Text("Ascending").tag("asc")
                    Text("Descending").tag("desc")
                }.controlHover().labelsHidden().frame(width: 100)
                Button("Apply Sort") {
                    document.tableSort = sortColumn.wrappedValue.isEmpty ? [] :
                        [CatalogSort(column: sortColumn.wrappedValue, direction: sortDirection.wrappedValue)]
                    document.page = 0
                    Task { await workspace.run(document) }
                }.controlHover()
                Spacer()
                Button { document.page -= 1; Task { await workspace.run(document) } } label: {
                    Image(systemName: "chevron.left")
                }.controlHover().disabled(document.page == 0)
                Text("Page \(document.page + 1)").font(.caption).monospacedDigit().help("200 rows per page")
                Button { document.page += 1; Task { await workspace.run(document) } } label: {
                    Image(systemName: "chevron.right")
                }.controlHover().disabled((document.runtime?.result?.rows?.count ?? 0) < 200)
            }
        }
        .font(.callout).padding(10)
        .disabled(document.isRunning || (document.grid?.pendingCount ?? 0) > 0 || document.grid?.isApplying == true || document.grid?.outcomeUnknown == true)
        .overlay(alignment: .bottom) { Divider() }
    }
}
