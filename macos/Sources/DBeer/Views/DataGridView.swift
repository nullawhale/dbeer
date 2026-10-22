import AppKit
import SwiftUI

struct DataGridView: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject var grid: GridDraft
    let result: BackendMessage?
    private var editing = SwiftUI.State<GridCellEdit?>(initialValue: nil)
    private var showingColumns = SwiftUI.State(initialValue: false)
    private var showingRowDetails = SwiftUI.State(initialValue: false)

    init(document: SQLDocument, workspace: ApplicationWorkspace, grid: GridDraft, result: BackendMessage? = nil) {
        self.document = document
        self.workspace = workspace
        self.grid = grid
        self.result = result
    }

    private var canNavigate: Bool { TableBrowseNavigation.isEnabled(document: document, workspace: workspace) }
    private var canFollowRelationship: Bool {
        workspace.canStartOperation(document) && !workspace.isClosing && document.canNavigateTable
    }
    private var selectedRelationshipRowID: UUID? {
        guard grid.selectedRows.count == 1, let row = grid.selectedRows.first,
              grid.rows.indices.contains(row) else { return nil }
        return grid.rows[row].id
    }
    private var usesCursors: Bool { document.runtime?.usesCursorPagination == true }
    private var canEdit: Bool { grid.canEdit && !document.isRunning && !document.isNavigatingTable && !workspace.isClosing }
    private var canPreview: Bool {
        (grid.pendingCount > 0 || grid.hasInlineDraft) && !grid.isApplying && !grid.isPreviewing && !document.isRunning &&
            !document.isNavigatingTable && !grid.isReloading && !grid.isClosing && !workspace.isClosing && !grid.outcomeUnknown
    }

    var body: some View {
        VStack(spacing: 0) {
            if let reason = grid.readOnlyReason {
                Text("Read only: \(reason)").font(.caption).appSecondaryText().padding(8)
            } else if let notice = grid.editingNotice {
                Text(notice).font(.caption).appSecondaryText().padding(8)
            }
            if grid.isApplying { ProgressView("Applying changes…").controlSize(.small).padding(8) }
            if grid.outcomeUnknown {
                HStack {
                    Text("Write outcome unknown. Verify data before making further changes.").foregroundStyle(.orange)
                    Button("Review Data in New Tab") { Task { await workspace.reviewGridData(document) } }
                        .controlHover().disabled(document.isNavigatingTable)
                }.font(.callout).padding(8)
            }
            if let error = grid.error { Text(error).foregroundStyle(.orange).textSelection(.enabled).padding(8) }
            if let notice = grid.notice { Text(notice).appSecondaryText().padding(8) }
            if let error = document.foreignKeysError {
                HStack(alignment: .top, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("Retry Foreign Keys") { Task { await workspace.loadForeignKeys(document) } }
                        .controlHover().disabled(!canFollowRelationship || document.isLoadingForeignKeys)
                }
                .font(.caption).padding(8)
                .accessibilityIdentifier("foreignKeysError")
            }
            HSplitView {
                table.frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                if showingRowDetails.wrappedValue {
                    GridRowDetailsView(grid: grid, canEdit: canEdit, edit: openEditor,
                        close: { showingRowDetails.wrappedValue = false })
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
                }
            }
            Divider()
            changesToolbar
            Divider()
            navigationToolbar
        }
        .onDisappear { grid.commitEditing?() }
        .sheet(item: editing.projectedValue) { edit in
            GridCellEditor(edit: edit) { value in
                // Resolve the stable row identity: inserted/deleted rows may change ordinals.
                if let row = grid.rows.firstIndex(where: { $0.id == edit.rowID }) {
                    grid.set(value, row: row, column: edit.cell.column)
                }
                editing.wrappedValue = nil
            } cancel: { editing.wrappedValue = nil }
        }
        .sheet(isPresented: Binding(get: { grid.preview != nil }, set: { if !$0 { grid.preview = nil } })) {
            GridSQLPreviewView(result: grid.preview, editingNotice: grid.editingNotice) { grid.preview = nil }
        }
    }

    private var table: some View {
        let presentation = grid.presentation
        var view = ResultTableView(columns: grid.columns, rows: presentation.rows)
        view.editableColumns = canEdit ? grid.editableColumns : []
        view.modifiedCells = presentation.modifiedCells
        view.deletedRows = presentation.deletedRows
        view.valueKinds = presentation.valueKinds
        view.selectedRows = grid.selectedRows
        view.onInlineDraftChanged = { grid.hasInlineDraft = $0 }
        view.dataIdentity = presentation
        view.partitionMarkers = grid.partitionMarkers
        view.onCoordinatorReady = { [weak grid] coordinator in
            grid?.commitEditing = { [weak coordinator] in coordinator?.finishInlineEdit() }
        }
        if canEdit {
            view.onEditCell = openEditor
            view.onCommitCell = { cell, text in
                grid.set(ChangeValue(kind: "text", value: text), row: cell.row, column: cell.column)
            }
            if grid.supportsRowInsertionAndDeletion {
                view.onDeleteRows = { finishEditing(); grid.deleteSelected() }
            }
            view.onSetCellValue = { cell, value in grid.set(value, row: cell.row, column: cell.column) }
            let policies = grid.columns.indices.map { GridColumnEditing(column: grid.columns[$0], metadata: grid.metadata[$0]) }
            view.canSetNullColumns = IndexSet(policies.indices.filter { policies[$0].allowsNull })
            view.canSetDefaultColumns = IndexSet(policies.indices.filter { policies[$0].allowsDefault })
            view.canSetEmptyColumns = IndexSet(policies.indices.filter { policies[$0].allowsEmptyString })
        }
        view.onSelectedRows = { selected in if grid.selectedRows != selected { grid.selectedRows = selected } }
        view.onShowRowDetails = { showingRowDetails.wrappedValue = true }
        view.onToggleRowDetails = { showingRowDetails.wrappedValue.toggle() }
        view.sortColumn = document.tableSort.first?.column
        view.sortAscending = document.tableSort.first?.direction != "desc"
        if canNavigate {
            view.onSortColumn = { index in
                TableBrowseNavigation.sort(column: grid.columns[index].name, document: document, workspace: workspace)
            }
        }
        view.documentID = document.id
        view.copySettings = workspace.copySettings
        view.copyAllowed = !document.isRunning && !document.isNavigatingTable && !workspace.isClosing && !grid.isApplying && !grid.isReloading && !grid.isClosing
        view.onCopyError = { workspace.reportCopyError($0) }
        view.onSQLInsertCopy = { payload, pasteboard in
            workspace.beginInsertCopy(payload, document: document, pasteboard: pasteboard)
        }
        view.commandHandler = { workspace.commands.handleKeyEvent($0, documentID: document.id) }
        return view
    }

    private var navigationToolbar: some View {
        HStack(spacing: 6) {
            if grid.supportsEditing && grid.supportsRowInsertionAndDeletion {
                Button("Insert Row") { finishEditing(); grid.insert() }.controlHover().disabled(!canEdit)
                    .accessibilityIdentifier("gridInsertRow")
                Button("Delete Selected") { finishEditing(); grid.deleteSelected() }.controlHover()
                    .disabled(!canEdit || grid.selectedRows.isEmpty).accessibilityIdentifier("gridDeleteRows")
            }
            Button("Columns…") { showingColumns.wrappedValue = true }.controlHover()
                .accessibilityIdentifier("gridColumns")
                .popover(isPresented: showingColumns.projectedValue) { columnDetails }
            relatedRowsMenu
            Spacer(minLength: 4)
            if !usesCursors {
                ControlIconButton(systemName: "chevron.left") {
                    guard canNavigate, document.page > 0 else { return }
                    document.page -= 1
                    Task { await workspace.run(document) }
                }.disabled(!canNavigate || document.page == 0)
                    .help("Previous page").accessibilityLabel("Previous page").accessibilityIdentifier("tablePreviousPage")
            }
            Text("Page \(document.page + 1)").font(.caption).monospacedDigit().fixedSize()
                .help("200 rows per page").accessibilityIdentifier("tablePage")
            ControlIconButton(systemName: "chevron.right") {
                TableBrowseNavigation.nextPage(document: document, workspace: workspace)
            }.disabled(!canNavigate || (usesCursors ? document.tableNextCursor == nil : grid.rows.count < 200))
                .help("Next page").accessibilityLabel("Next page").accessibilityIdentifier("tableNextPage")
        }
        .font(.callout).controlSize(.small).padding(.horizontal, 10).padding(.vertical, 7)
        .accessibilityElement(children: .contain).accessibilityIdentifier("gridNavigationToolbar")
    }

    private var relatedRowsMenu: some View {
        Menu("Related Rows") {
            if document.isLoadingForeignKeys {
                Text("Loading foreign keys…")
            } else if let error = document.foreignKeysError {
                Text(error)
            } else if document.tableForeignKeys.isEmpty {
                Text("No foreign keys")
            } else if let rowID = selectedRelationshipRowID {
                ForEach(document.tableForeignKeys) { key in
                    Menu(key.displayLabel) {
                        Button("Open Related Rows") {
                            Task { await workspace.followForeignKey(key, rowID: rowID, in: document) }
                        }
                        Button("Open Related Rows in New Tab") {
                            Task { await workspace.followForeignKey(key, rowID: rowID, in: document, inNewTab: true) }
                        }
                    }
                }
            } else {
                Text("Select one row to follow a foreign key")
            }
            Divider()
            Button(document.foreignKeysError == nil ? "Refresh Foreign Keys" : "Retry Foreign Keys") {
                Task { await workspace.loadForeignKeys(document) }
            }.disabled(document.isLoadingForeignKeys)
        }
        .fixedSize().controlHover()
        .disabled(!canFollowRelationship)
        .help("Follow a selected row's foreign key in this view or an independent tab")
        .accessibilityIdentifier("gridRelatedRows")
    }

    private var changesToolbar: some View {
        HStack(spacing: 6) {
            Text("\(grid.selectedRows.count) of \(grid.rows.count) selected")
                .font(.caption).monospacedDigit().fixedSize().appSecondaryText()
                .accessibilityIdentifier("gridSelectionSummary")
            Menu("Export") {
                if let result {
                    Button("JSON…") { workspace.exportLoaded(ExportResultSet(result), title: document.title, format: "json") }
                    Button("CSV…") { workspace.exportLoaded(ExportResultSet(result), title: document.title, format: "csv") }
                }
            }.fixedSize().controlHover().help("Export loaded rows")
                .disabled(result == nil || grid.pendingCount > 0 || grid.hasInlineDraft || grid.isApplying || grid.outcomeUnknown || document.isRunning || document.isNavigatingTable)
                .accessibilityIdentifier("gridExport")
            Spacer(minLength: 4)
            if grid.pendingCount > 0 {
                Text("\(grid.pendingCount) pending").font(.caption).monospacedDigit().fixedSize().appSecondaryText()
            } else if grid.hasInlineDraft {
                Text("Editing").font(.caption).appSecondaryText()
            } else if let duration = result?.durationMs {
                Text(String(format: "%.1f ms", duration)).font(.caption).fixedSize().appSecondaryText()
            }
            if let status = grid.partitionStatus {
                Label {
                    Text(status.label).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: status.allowsApply ? "checkmark" : "exclamationmark.triangle")
                        .foregroundStyle(status.allowsApply ? Color.green : Color.orange)
                }
                    .font(.caption).fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background((status.allowsApply ? Color.green : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke((status.allowsApply ? Color.green : Color.orange).opacity(0.6)))
                    .help(status.help).accessibilityElement(children: .ignore)
                    .accessibilityLabel(status.label).accessibilityHint(status.help)
                    .accessibilityIdentifier("gridPartitionStatus")
            }
            if canPreview {
                Button("Preview SQL") { finishEditing(); Task { await workspace.previewGrid(document) } }.controlHover()
                    .accessibilityIdentifier("gridPreviewSQL")
            }
            if grid.supportsEditing {
                Button("Discard") { finishEditing(); Task { await workspace.discardGrid(document) } }.controlHover()
                    .disabled((grid.pendingCount == 0 && !grid.hasInlineDraft) || grid.isApplying || grid.isReloading || document.isRunning || document.isNavigatingTable || grid.isClosing || workspace.isClosing)
                    .accessibilityIdentifier("gridDiscard")
                Button("Apply") { finishEditing(); Task { await workspace.applyGrid(document) } }.controlHover()
                    .buttonStyle(.borderedProminent).disabled((grid.pendingCount == 0 && !grid.hasInlineDraft) || !canEdit || (!grid.hasInlineDraft && !grid.canApply))
                    .help(grid.partitionStatus?.help ?? "Apply pending changes")
                    .accessibilityIdentifier("gridApply")
            }
        }
        .font(.callout).controlSize(.small).padding(.horizontal, 10).padding(.vertical, 7)
        .accessibilityElement(children: .contain).accessibilityIdentifier("gridChangesToolbar")
    }

    private func finishEditing() { grid.commitEditing?() }

    private func openEditor(_ cell: ResultGridCell) {
        guard canEdit, grid.rows.indices.contains(cell.row), grid.columns.indices.contains(cell.column),
              let value = grid.value(row: cell.row, column: cell.column) else { return }
        editing.wrappedValue = GridCellEdit(cell: cell, rowID: grid.rows[cell.row].id,
            value: value, column: grid.columns[cell.column], metadata: grid.metadata[cell.column])
    }

    private var columnDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Columns").font(.headline)
                ForEach(grid.columns.indices, id: \.self) { index in
                    columnDetailsRow(at: index)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }.frame(width: 380, height: 360)
    }

    private func columnDetailsRow(at index: Int) -> some View {
        let column: ResultColumn = grid.columns[index]
        let metadata: [String: String] = grid.metadata[index]
        let nativeType: String = metadata["nativeType"] ?? column.nativeType
        let editReason: String = columnEditReason(at: index, metadata: metadata)
        return VStack(alignment: .leading, spacing: 3) {
            Text(column.name).font(.callout.bold())
            Text(nativeType)
                .font(.system(.caption, design: .monospaced)).appSecondaryText()
            Text(editReason)
                .font(.caption).appSecondaryText().textSelection(.enabled)
        }
    }

    private func columnEditReason(at index: Int, metadata: [String: String]) -> String {
        if grid.editableColumns.contains(index) { return "Editable" }
        if let generated = metadata["generated"], !generated.isEmpty {
            return "Computed column: " + generated
        }
        if let reason = metadata["editReason"], !reason.isEmpty { return reason }
        return grid.readOnlyReason ?? "Read only"
    }
}

private struct GridCellEdit: Identifiable {
    let id = UUID()
    let cell: ResultGridCell
    let rowID: UUID
    let value: ChangeValue
    let column: ResultColumn
    let metadata: [String: String]
}

private struct GridCellEditor: View {
    let edit: GridCellEdit
    let save: (ChangeValue) -> Void
    let cancel: () -> Void
    private var kind: SwiftUI.State<String>
    private var text: SwiftUI.State<String>
    private var error = SwiftUI.State<String?>(initialValue: nil)
    @FocusState private var isTextFocused: Bool

    init(edit: GridCellEdit, save: @escaping (ChangeValue) -> Void, cancel: @escaping () -> Void) {
        self.edit = edit
        self.save = save
        self.cancel = cancel
        kind = SwiftUI.State(initialValue: ["null", "default"].contains(edit.value.kind) ? edit.value.kind : "value")
        text = SwiftUI.State(initialValue: edit.value.value ?? "")
    }

    private var policy: GridColumnEditing { GridColumnEditing(column: edit.column, metadata: edit.metadata) }
    private var choices: [ControlSegmentPicker<String>.Choice] {
        var result: [ControlSegmentPicker<String>.Choice] = [.init("Value", value: "value")]
        if policy.allowsNull { result.append(.init("NULL", value: "null")) }
        if policy.allowsDefault { result.append(.init("DEFAULT", value: "default")) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit \(edit.column.name)").font(.title2)
            Text("Row \(edit.cell.row + 1) · \(policy.nativeType)").font(.caption).appSecondaryText()
            ControlSegmentPicker("Value", selection: kind.projectedValue, choices: choices)
            if kind.wrappedValue == "value" {
                if policy.usesMultilineEditor(for: edit.value) {
                    TextEditor(text: text.projectedValue).font(.system(.body, design: .monospaced)).frame(minHeight: 150)
                        .focused($isTextFocused).focusEffectDisabled()
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(isTextFocused ? AppPalette.accent : AppPalette.border,
                                    lineWidth: isTextFocused ? 2 : 1).allowsHitTesting(false)
                        }
                } else {
                    TextField("Value", text: text.projectedValue).textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced)).focused($isTextFocused)
                }
                if policy.allowsEmptyString {
                    HStack {
                        Button("Empty String") { text.wrappedValue = "" }.controlHover()
                        Text("An empty string is distinct from NULL and DEFAULT.").font(.caption).appSecondaryText()
                    }
                }
                if policy.isBinary { Text("Enter binary data as Base64.").font(.caption).appSecondaryText() }
            } else {
                Text(kind.wrappedValue == "null" ? "Store SQL NULL." : "Let the server use this column's default value.")
                    .appSecondaryText().frame(minHeight: 60)
            }
            if let error = error.wrappedValue { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("Cancel", action: cancel).controlHover().keyboardShortcut(.cancelAction)
                Spacer()
                Button("Stage Change") {
                    if kind.wrappedValue != "value" { save(ChangeValue(kind: kind.wrappedValue)); return }
                    if policy.isBinary, Data(base64Encoded: text.wrappedValue) == nil {
                        error.wrappedValue = "Enter valid Base64 for a binary value."
                        return
                    }
                    save(ChangeValue(kind: policy.isBinary ? "binary" : "text", value: text.wrappedValue))
                }.controlHover().buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("stageGridCellChange")
            }
        }.padding(20).frame(width: policy.usesMultilineEditor(for: edit.value) ? 620 : 440)
            .tint(AppPalette.accent).focusEffectDisabled()
    }
}

private struct GridSQLPreviewView: View {
    let result: BackendMessage?
    let editingNotice: String?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Apply SQL Preview").font(.title2)
                Spacer()
                Button("Done", action: close).controlHover().keyboardShortcut(.cancelAction)
            }
            Text(editingNotice ?? "Values are bound as parameters. Apply locks and verifies the original rows in a separate transaction.")
                .font(.callout).appSecondaryText()
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array((result?.catalogRecords ?? []).enumerated()), id: \.offset) { _, record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record["operation"] ?? "").font(.headline)
                            Text(record["sql"] ?? "").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Text(record["parameters"] ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).appSecondaryText()
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }.padding(20).frame(width: 820, height: 560)
            .tint(AppPalette.accent).focusEffectDisabled()
    }
}
