import SwiftUI

/// The editor changes a local configuration. Only Apply starts a new read.
struct TableBrowseControls: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject private var presets: TableBrowsePresetStore
    private var selectedPresetID = SwiftUI.State<UUID?>(initialValue: nil)
    private var presetName = SwiftUI.State<String>(initialValue: "")
    private var operationError = SwiftUI.State<String?>(initialValue: nil)
    private var selectionScope = SwiftUI.State<PresetSelectionScope?>(initialValue: nil)

    private struct PresetSelectionScope: Equatable {
        var documentID: UUID
        var profileID: UUID?
        var table: TableReference?
    }
    private var presetScope: PresetSelectionScope {
        PresetSelectionScope(documentID: document.id, profileID: document.profileID, table: document.table)
    }

    init(document: SQLDocument, workspace: ApplicationWorkspace) {
        self.document = document
        self.workspace = workspace
        presets = workspace.tableBrowsePresets
    }

    private var isCassandra: Bool { TableBrowseNavigation.isCassandra(document: document, workspace: workspace) }
    private var engine: DatabaseEngine? {
        document.runtime?.engine ?? workspace.library.savedConnections.first { $0.id == document.profileID }?.engine
    }
    private var columns: [String] { document.tableColumns.compactMap { $0["name"] } }
    private var filterColumns: [String] {
        guard isCassandra else { return columns }
        return document.tableColumns.filter {
            CassandraBrowseRules.isSupportedFilterType($0) &&
                ((Int($0["partitionKeyPosition"] ?? "0") ?? 0) > 0 || CassandraBrowseRules.isClustering($0) || $0["indexed"] == "true")
        }.compactMap { $0["name"] }
    }
    private var sortColumns: [String] {
        isCassandra ? document.tableColumns.filter(CassandraBrowseRules.isClustering).compactMap { $0["name"] } : columns
    }
    private var configuration: TableBrowseConfiguration { document.browseDraftConfiguration }
    private var canNavigate: Bool { TableBrowseNavigation.isEnabled(document: document, workspace: workspace) }
    private var validationError: String? {
        TableBrowseNavigation.validationError(configuration: configuration, document: document, workspace: workspace)
    }
    private var availablePresets: [TableBrowsePreset] {
        guard let profileID = document.profileID, let table = document.table else { return [] }
        return presets.matching(profileID: profileID, table: table)
    }
    private var selectedPreset: TableBrowsePreset? { availablePresets.first { $0.id == selectedPresetID.wrappedValue } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Filter and Sort").font(.headline)
                if let expression = configuration.filterExpression {
                    expressionEditor(expression, path: [])
                    if expression.kind == "condition" {
                        Button("Add Condition") { addCondition(path: []) }
                            .controlHover().disabled(filterColumns.isEmpty || conditionCount >= 32)
                            .accessibilityIdentifier("tableFilterAddCondition-root")
                    }
                } else {
                    Text("No filters").appSecondaryText()
                    Button("Add Condition") { addCondition(path: []) }
                        .controlHover().disabled(filterColumns.isEmpty)
                        .accessibilityIdentifier("tableAddFilter")
                }
                HStack {
                    Button("Clear Filters") { change { $0.filterExpression = nil } }
                        .controlHover().disabled(configuration.filterExpression == nil)
                        .accessibilityIdentifier("tableBrowseClearFilters")
                    Spacer()
                    Text("Changes apply together.").font(.caption).appSecondaryText()
                }
                if isCassandra {
                    Text("Cassandra supports AND conditions only. Partition keys require equality; clustering conditions and sorting require the complete partition key and an ordered key prefix. Indexed equality is supported. DBeer never adds ALLOW FILTERING.")
                        .font(.caption).appSecondaryText().fixedSize(horizontal: false, vertical: true)
                } else if engine == .mongodb {
                    Text("Fields are sampled. Values use JSON or Extended JSON; quote strings. IS NULL matches BSON null; IS NOT NULL excludes missing fields.")
                        .font(.caption).appSecondaryText().fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                sortEditor
                Divider()
                presetEditor
                if let message = operationError.wrappedValue ?? presets.error {
                    Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if let validationError {
                    Text(validationError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("tableBrowseValidation")
                }
                Divider()
                HStack {
                    Button("Reset") { TableBrowseNavigation.resetDraft(document: document) }
                        .controlHover().disabled(!document.hasPendingBrowseChanges)
                        .accessibilityIdentifier("tableBrowseReset")
                    Spacer()
                    if document.hasPendingBrowseChanges { Text("Not applied").font(.caption).appSecondaryText() }
                    Button("Apply") { TableBrowseNavigation.apply(document: document, workspace: workspace) }
                        .controlHover().disabled(validationError != nil)
                        .accessibilityIdentifier("tableBrowseApply")
                }
            }
            .font(.callout).padding(16)
            .disabled(!canNavigate)
        }
        .frame(width: 560).frame(maxHeight: 650)
        .task { await presets.load() }
        .onAppear { updateSelectionScope(presetScope) }
        .onChange(of: presetScope) { _, scope in updateSelectionScope(scope) }
    }

    private var sortEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sort Rows").font(.headline)
            if configuration.sort.isEmpty {
                Text(engine == .mongodb ? "Default order (_id)" : "Default table order")
                    .font(.caption).appSecondaryText()
            }
            ForEach(Array(configuration.sort.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 6) {
                    Text("\(index + 1)").font(.caption).appSecondaryText().frame(width: 16)
                    Picker("Sort column", selection: sortBinding(index, \.column)) {
                        if !sortColumns.contains(item.column) { Text("Unavailable: \(item.column)").tag(item.column) }
                        ForEach(sortColumns.filter { name in name == item.column || !configuration.sort.contains { $0.column == name } }, id: \.self) {
                            Text($0).tag($0)
                        }
                    }.labelsHidden().controlHover().accessibilityLabel("Sort column \(index + 1)")
                        .accessibilityIdentifier("tableSortColumn-\(index)")
                    Picker("Direction", selection: sortBinding(index, \.direction)) {
                        Text("Ascending").tag("asc")
                        Text("Descending").tag("desc")
                    }.labelsHidden().controlHover().frame(width: 110).accessibilityLabel("Sort direction \(index + 1)")
                        .accessibilityIdentifier("tableSortDirection-\(index)")
                    ControlIconButton(systemName: "arrow.up") { moveSort(index, offset: -1) }
                        .disabled(index == 0).accessibilityLabel("Move sort \(index + 1) up")
                        .accessibilityIdentifier("tableSortUp-\(index)")
                    ControlIconButton(systemName: "arrow.down") { moveSort(index, offset: 1) }
                        .disabled(index == configuration.sort.count - 1).accessibilityLabel("Move sort \(index + 1) down")
                        .accessibilityIdentifier("tableSortDown-\(index)")
                    ControlIconButton(systemName: "xmark") {
                        change { if $0.sort.indices.contains(index) { $0.sort.remove(at: index) } }
                    }
                        .accessibilityLabel("Remove sort \(index + 1)")
                        .accessibilityIdentifier("tableSortRemove-\(index)")
                }
            }
            Button("Add Sort") {
                guard let name = sortColumns.first(where: { name in !configuration.sort.contains { $0.column == name } }) else { return }
                change { $0.sort.append(CatalogSort(column: name, direction: "asc")) }
            }.controlHover()
                .disabled(configuration.sort.count >= (isCassandra ? 1 : 32) || !sortColumns.contains { name in !configuration.sort.contains { $0.column == name } })
                .accessibilityIdentifier("tableAddSort")
        }
    }

    private var presetEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved Views").font(.headline)
            Picker("Saved view", selection: Binding(get: { selectedPresetID.wrappedValue }, set: { id in
                selectedPresetID.wrappedValue = id
                loadSelectedPreset()
            })) {
                Text("Choose…").tag(UUID?.none)
                ForEach(availablePresets) { Text($0.name).tag(Optional($0.id)) }
            }.controlHover().accessibilityIdentifier("tableBrowsePreset")
            Button("Load Selected", action: loadSelectedPreset).controlHover().disabled(selectedPreset == nil)
                .accessibilityIdentifier("tableBrowseLoadPreset")
            TextField("View name", text: presetName.projectedValue).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("tableBrowsePresetName")
            HStack {
                Button("Save New") {
                    guard let profileID = document.profileID, let table = document.table else { return }
                    let name = presetName.wrappedValue, configuration = configuration, scope = presetScope
                    perform {
                        let saved = try await presets.saveNew(name: name, profileID: profileID, table: table, configuration: configuration)
                        guard selectionScope.wrappedValue == scope, presetScope == scope else { return }
                        // Selection after saving never reloads the captured draft:
                        // the user may have continued editing while publication ran.
                        selectedPresetID.wrappedValue = saved.id
                    }
                }.controlHover().disabled(validationError != nil || !TableBrowsePreset.validName(presetName.wrappedValue))
                    .accessibilityIdentifier("tableBrowseSavePreset")
                Button("Update Selected") {
                    guard let id = selectedPreset?.id else { return }
                    let configuration = configuration
                    perform { try await presets.update(id: id, configuration: configuration) }
                }.controlHover().disabled(selectedPreset == nil || validationError != nil)
                    .accessibilityIdentifier("tableBrowseUpdatePreset")
                Button("Rename") {
                    guard let id = selectedPreset?.id else { return }
                    let name = presetName.wrappedValue
                    perform { try await presets.rename(id: id, name: name) }
                }.controlHover().disabled(selectedPreset == nil || !TableBrowsePreset.validName(presetName.wrappedValue))
                    .accessibilityIdentifier("tableBrowseRenamePreset")
                Button("Delete") {
                    guard let id = selectedPreset?.id else { return }
                    let scope = presetScope
                    perform {
                        try await presets.delete(id: id)
                        guard selectionScope.wrappedValue == scope, presetScope == scope else { return }
                        if selectedPresetID.wrappedValue == id { selectedPresetID.wrappedValue = nil }
                    }
                }.controlHover().disabled(selectedPreset == nil)
                    .accessibilityIdentifier("tableBrowseDeletePreset")
            }
            Text("Selecting a view fills this draft. Apply reads the table.")
                .font(.caption).appSecondaryText()
        }.disabled(presets.isBusy || !presets.isLoaded)
    }

    /// AnyView bounds the recursive view type while the configuration retains
    /// every explicit group. Paths address draft nodes, never table rows.
    private func expressionEditor(_ node: CatalogFilterExpression, path: [Int]) -> AnyView {
        if let condition = node.condition, node.kind == "condition" {
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Picker("Filter column", selection: conditionBinding(path, \.column)) {
                        if !filterColumns.contains(condition.column) { Text("Unavailable: \(condition.column)").tag(condition.column) }
                        ForEach(filterColumns, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().controlHover().accessibilityLabel("Filter column")
                        .accessibilityIdentifier("tableFilterColumn-\(pathID(path))")
                    Picker("Operator", selection: conditionBinding(path, \.operator)) {
                        if !operators(for: condition.column).contains(where: { $0.1 == condition.operator }) {
                            Text("Unavailable: \(condition.operator)").tag(condition.operator)
                        }
                        ForEach(operators(for: condition.column), id: \.1) { Text($0.0).tag($0.1) }
                    }.labelsHidden().controlHover().frame(width: 115).accessibilityLabel("Filter operator")
                        .accessibilityIdentifier("tableFilterOperator-\(pathID(path))")
                    ControlIconButton(systemName: "xmark") { removeNode(path) }.accessibilityLabel("Remove condition")
                        .accessibilityIdentifier("tableFilterRemove-\(pathID(path))")
                }
                if !["isNull", "isNotNull"].contains(condition.operator) {
                    TextField(engine == .mongodb ? "JSON or Extended JSON value" : "Value", text: valueBinding(path))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Filter value")
                        .accessibilityIdentifier("tableFilterValue-\(pathID(path))")
                        .help(engine == .mongodb ? "Quote string values, for example \"hello\"." : "Binary column values use Base64.")
                }
            }.padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6)))
        }
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Match", selection: groupBinding(path)) {
                    Text("All (AND)").tag("and")
                    if !isCassandra { Text("Any (OR)").tag("or") }
                    else if node.kind == "or" { Text("OR unavailable for Cassandra").tag("or") }
                }.controlHover().labelsHidden().accessibilityLabel("Condition group")
                    .accessibilityIdentifier("tableFilterGroup-\(pathID(path))")
                Spacer()
                ControlIconButton(systemName: "xmark") { removeNode(path) }.accessibilityLabel("Remove group")
                    .accessibilityIdentifier("tableFilterRemoveGroup-\(pathID(path))")
            }
            ForEach(Array((node.children ?? []).enumerated()), id: \.offset) { index, child in
                expressionEditor(child, path: path + [index])
            }
            HStack {
                Button("Add Condition") { addCondition(path: path) }.controlHover().disabled(filterColumns.isEmpty || conditionCount >= 32)
                    .accessibilityIdentifier("tableFilterAddCondition-\(pathID(path))")
                Button("Add Group") { addGroup(path: path) }.controlHover().disabled(filterColumns.isEmpty || path.count >= 2 || conditionCount >= 32)
                    .accessibilityIdentifier("tableFilterAddGroup-\(pathID(path))")
            }
        }.padding(8).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary)))
    }

    private func pathID(_ path: [Int]) -> String { path.isEmpty ? "root" : path.map(String.init).joined(separator: "-") }

    private var conditionCount: Int {
        func count(_ expression: CatalogFilterExpression) -> Int {
            expression.kind == "condition" ? 1 : (expression.children ?? []).reduce(0) { $0 + count($1) }
        }
        return configuration.filterExpression.map(count) ?? 0
    }

    private func operators(for column: String) -> [(String, String)] {
        if isCassandra {
            let metadata = document.tableColumns.first { $0["name"] == column } ?? [:]
            return CassandraBrowseRules.isClustering(metadata) ? [("=", "eq"), ("<", "lt"), ("≤", "lte"), (">", "gt"), ("≥", "gte")] : [("=", "eq")]
        }
        return [("=", "eq"), ("≠", "ne"), ("<", "lt"), ("≤", "lte"), (">", "gt"), ("≥", "gte"), ("Contains", "contains"), ("IS NULL", "isNull"), ("IS NOT NULL", "isNotNull")]
    }

    private func change(_ edit: (inout TableBrowseConfiguration) -> Void) {
        guard canNavigate else { return }
        var changed = configuration
        edit(&changed)
        document.browseDraftConfiguration = changed
        operationError.wrappedValue = nil
    }

    private func editNode(_ path: [Int], edit: (inout CatalogFilterExpression) -> Void) {
        func update(_ node: inout CatalogFilterExpression, remaining: ArraySlice<Int>) {
            guard let index = remaining.first else { edit(&node); return }
            guard var children = node.children, children.indices.contains(index) else { return }
            update(&children[index], remaining: remaining.dropFirst())
            node.children = children
        }
        change {
            guard var expression = $0.filterExpression else { return }
            update(&expression, remaining: path[...])
            $0.filterExpression = expression
        }
    }

    private func node(at path: [Int]) -> CatalogFilterExpression? {
        var result = configuration.filterExpression
        for index in path {
            guard let children = result?.children, children.indices.contains(index) else { return nil }
            result = children[index]
        }
        return result
    }

    private func addCondition(path: [Int]) {
        guard let name = filterColumns.first else { return }
        let condition = CatalogFilterExpression.predicate(CatalogFilter(column: name, operator: "eq", value: ""))
        guard configuration.filterExpression != nil else {
            change { $0.filterExpression = .group("and", [condition]) }
            return
        }
        editNode(path) {
            if $0.kind == "condition" { $0 = .group("and", [$0, condition]) }
            else { $0.children = ($0.children ?? []) + [condition] }
        }
    }

    private func addGroup(path: [Int]) {
        guard let name = filterColumns.first else { return }
        let group = CatalogFilterExpression.group("and", [.predicate(CatalogFilter(column: name, operator: "eq", value: ""))])
        editNode(path) { $0.children = ($0.children ?? []) + [group] }
    }

    private func removeNode(_ path: [Int]) {
        guard let index = path.last else { change { $0.filterExpression = nil }; return }
        editNode(Array(path.dropLast())) {
            guard $0.children?.indices.contains(index) == true else { return }
            $0.children?.remove(at: index)
        }
        // Removing the last condition removes that empty group, recursively.
        if node(at: Array(path.dropLast()))?.children?.isEmpty == true { removeNode(Array(path.dropLast())) }
    }

    private func conditionBinding(_ path: [Int], _ field: WritableKeyPath<CatalogFilter, String>) -> Binding<String> {
        Binding(get: { node(at: path)?.condition?[keyPath: field] ?? "" }, set: { value in
            editNode(path) {
                guard var condition = $0.condition else { return }
                condition[keyPath: field] = value
                if field == \.operator {
                    condition.value = ["isNull", "isNotNull"].contains(value) ? nil : (condition.value ?? "")
                } else if field == \.column, !operators(for: value).contains(where: { $0.1 == condition.operator }) {
                    condition.operator = "eq"; condition.value = condition.value ?? ""
                }
                $0.condition = condition
            }
        })
    }

    private func valueBinding(_ path: [Int]) -> Binding<String> {
        Binding(get: { node(at: path)?.condition?.value ?? "" }, set: { value in editNode(path) { $0.condition?.value = value } })
    }
    private func groupBinding(_ path: [Int]) -> Binding<String> {
        Binding(get: { node(at: path)?.kind ?? "and" }, set: { value in editNode(path) { $0.kind = value } })
    }
    private func sortBinding(_ index: Int, _ field: WritableKeyPath<CatalogSort, String>) -> Binding<String> {
        Binding(get: { configuration.sort.indices.contains(index) ? configuration.sort[index][keyPath: field] : "" }, set: { value in
            change { if $0.sort.indices.contains(index) { $0.sort[index][keyPath: field] = value } }
        })
    }
    private func moveSort(_ index: Int, offset: Int) {
        change {
            let destination = index + offset
            guard $0.sort.indices.contains(index), $0.sort.indices.contains(destination) else { return }
            $0.sort.swapAt(index, destination)
        }
    }
    private func updateSelectionScope(_ scope: PresetSelectionScope) {
        guard selectionScope.wrappedValue != scope else { return }
        selectionScope.wrappedValue = scope
        selectedPresetID.wrappedValue = nil
        presetName.wrappedValue = ""
        operationError.wrappedValue = nil
    }

    private func loadSelectedPreset() {
        guard canNavigate, let preset = selectedPreset else { return }
        document.browseDraftConfiguration = preset.configuration
        presetName.wrappedValue = preset.name
        operationError.wrappedValue = nil
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        let scope = presetScope
        operationError.wrappedValue = nil
        Task {
            do { try await action() }
            catch {
                guard selectionScope.wrappedValue == scope, presetScope == scope else { return }
                operationError.wrappedValue = error.localizedDescription
            }
        }
    }
}

/// Sorting, paging and filtering must never replace a pending or uncertain draft.
@MainActor
enum TableBrowseNavigation {
    static func isEnabled(document: SQLDocument, workspace: ApplicationWorkspace) -> Bool {
        !document.isRunning && !document.isApplyingBrowse && !document.isNavigatingTable && !workspace.isClosing && document.grid?.isClosing != true &&
            document.grid?.hasInlineDraft != true &&
            (document.grid?.pendingCount ?? 0) == 0 && document.grid?.isApplying != true &&
            document.grid?.isReloading != true && document.grid?.isPreviewing != true &&
            document.grid?.outcomeUnknown != true
    }

    @discardableResult
    static func nextPage(document: SQLDocument, workspace: ApplicationWorkspace) -> Task<Void, Never>? {
        guard isEnabled(document: document, workspace: workspace), !document.hasPendingBrowseChanges else { return nil }
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
        updateDraftSort(column: column, document: document, workspace: workspace)
    }

    static func updateDraftSort(column: String, document: SQLDocument, workspace: ApplicationWorkspace) {
        guard document.table != nil, isEnabled(document: document, workspace: workspace), validBrowseName(column) else { return }
        var draft = document.browseDraftConfiguration
        if let index = draft.sort.firstIndex(where: { $0.column == column }) {
            if draft.sort[index].direction == "asc" { draft.sort[index].direction = "desc" }
            else { draft.sort.remove(at: index) }
        } else {
            guard draft.sort.count < 32 else { return }
            if isCassandra(document: document, workspace: workspace) {
                draft.sort = [CatalogSort(column: column, direction: "asc")]
            } else {
                draft.sort.append(CatalogSort(column: column, direction: "asc"))
            }
        }
        if isCassandra(document: document, workspace: workspace),
           !CassandraBrowseRules.hasValidSort(document, configuration: draft) { return }
        document.browseDraftConfiguration = draft
    }

    static func resetDraft(document: SQLDocument) { document.tableBrowseDraft = nil }

    static func validationError(configuration: TableBrowseConfiguration, document: SQLDocument,
                                workspace: ApplicationWorkspace) -> String? {
        guard configuration.isValid else {
            return "Choose valid conditions and unique sort columns. Use at most 32 conditions, 4 levels and 32 sort columns."
        }
        let required = (configuration.filterExpression?.columns ?? []).union(configuration.sort.map(\.column))
        if !document.tableColumns.isEmpty {
            let missing = required.subtracting(document.tableColumns.compactMap { $0["name"] })
            if !missing.isEmpty {
                return "Some fields are unavailable: " + missing.sorted().joined(separator: ", ") + ". Edit the saved view or refresh the table metadata."
            }
        }
        if isCassandra(document: document, workspace: workspace),
           !CassandraBrowseRules.canApplyFilters(document, configuration: configuration) {
            return "Cassandra requires AND conditions with a complete partition key and an ordered clustering-key prefix, or one indexed equality. Sorting supports one eligible clustering column. No ALLOW FILTERING is added."
        }
        return nil
    }

    @discardableResult
    static func apply(document: SQLDocument, workspace: ApplicationWorkspace) -> Task<Void, Never>? {
        guard document.table != nil, isEnabled(document: document, workspace: workspace) else { return nil }
        let configuration = document.browseDraftConfiguration
        if let error = validationError(configuration: configuration, document: document, workspace: workspace) {
            document.tableNavigationError = error
            return nil
        }
        document.tableFilterExpression = configuration.filterExpression
        document.tableSort = configuration.sort
        document.tableBrowseDraft = nil
        document.tableNavigationError = nil
        document.resetTablePaging()
        // Reserve synchronously so repeated Apply cannot enqueue another read.
        document.isApplyingBrowse = true
        return Task {
            defer { document.isApplyingBrowse = false }
            await workspace.run(document)
        }
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

    static func hasFullPartitionKey(_ document: SQLDocument, configuration: TableBrowseConfiguration? = nil) -> Bool {
        let keys = document.tableColumns.filter { (Int($0["partitionKeyPosition"] ?? "0") ?? 0) > 0 }
        return !keys.isEmpty && keys.allSatisfy { column in
            let filters = ((configuration ?? document.browseConfiguration).filterExpression?.flattenedConjunction ?? []).filter { $0.column == column["name"] }
            return isSupportedFilterType(column) && filters.count == 1 && filters[0].operator == "eq"
        }
    }

    static func canFilter(_ column: [String: String], in document: SQLDocument, configuration: TableBrowseConfiguration? = nil) -> Bool {
        guard isSupportedFilterType(column) else { return false }
        if (Int(column["partitionKeyPosition"] ?? "0") ?? 0) > 0 || column["indexed"] == "true" { return true }
        guard hasFullPartitionKey(document, configuration: configuration), isClustering(column) else { return false }
        let position = Int(column["clusteringPosition"] ?? "0") ?? 0
        return precedingClusteringKeysEqual(position, in: document, configuration: configuration)
    }

    static func canSort(_ name: String, in document: SQLDocument, configuration: TableBrowseConfiguration? = nil) -> Bool {
        guard hasFullPartitionKey(document, configuration: configuration), let column = document.tableColumns.first(where: { $0["name"] == name }),
              isClustering(column) else { return false }
        return precedingClusteringKeysEqual(Int(column["clusteringPosition"] ?? "0") ?? 0, in: document, configuration: configuration)
    }

    static func hasValidSort(_ document: SQLDocument, configuration: TableBrowseConfiguration? = nil) -> Bool {
        let sort = (configuration ?? document.browseConfiguration).sort
        return sort.count <= 1 && sort.allSatisfy {
            ["asc", "desc"].contains($0.direction) && canSort($0.column, in: document, configuration: configuration)
        }
    }

    static func canApplyFilters(_ document: SQLDocument, configuration: TableBrowseConfiguration? = nil) -> Bool {
        let configuration = configuration ?? document.browseConfiguration
        guard configuration.isValid else { return false }
        let filters: [CatalogFilter]
        if let expression = configuration.filterExpression {
            guard let conjunction = expression.flattenedConjunction else { return false }
            filters = conjunction
        } else { filters = [] }
        guard filters.count <= 32, hasValidSort(document, configuration: configuration), filters.allSatisfy({ filter in
            filter.value != nil && ["eq", "lt", "lte", "gt", "gte"].contains(filter.operator) &&
                document.tableColumns.contains { $0["name"] == filter.column && isSupportedFilterType($0) }
        }) else { return false }
        if filters.isEmpty { return true }
        if !hasFullPartitionKey(document, configuration: configuration) {
            return filters.count == 1 && filters[0].operator == "eq" && configuration.sort.isEmpty &&
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

    private static func precedingClusteringKeysEqual(_ position: Int, in document: SQLDocument, configuration: TableBrowseConfiguration? = nil) -> Bool {
        document.tableColumns.filter {
            let prior = Int($0["clusteringPosition"] ?? "0") ?? 0
            return prior > 0 && prior < position
        }.allSatisfy { prior in
            let filters = ((configuration ?? document.browseConfiguration).filterExpression?.flattenedConjunction ?? []).filter { $0.column == prior["name"] }
            return filters.count == 1 && filters[0].operator == "eq"
        }
    }
}
