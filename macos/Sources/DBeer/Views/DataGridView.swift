import AppKit
import SwiftUI

struct DataGridView: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject var grid: GridDraft
    private var editing = SwiftUI.State<GridCellEdit?>(initialValue: nil)
    private var showingColumns = SwiftUI.State(initialValue: false)

    init(document: SQLDocument, workspace: ApplicationWorkspace, grid: GridDraft) {
        self.document = document
        self.workspace = workspace
        self.grid = grid
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Insert Row") { grid.insert() }.controlHover().disabled(!grid.canEdit)
                Button("Delete Selected") { grid.deleteSelected() }.controlHover().disabled(!grid.canEdit || grid.selectedRows.isEmpty)
                Button("Columns…") { showingColumns.wrappedValue = true }.controlHover()
                    .popover(isPresented: showingColumns.projectedValue) { columnDetails }
                Spacer()
                Text("\(grid.pendingCount) pending").font(.caption).foregroundStyle(.secondary)
                Button("Preview SQL") { Task { await workspace.previewGrid(document) } }.controlHover()
                    .disabled(grid.pendingCount == 0 || grid.isApplying || grid.isPreviewing || document.isRunning || grid.isClosing || workspace.isClosing)
                Button("Discard") { Task { await workspace.discardGrid(document) } }.controlHover()
                    .disabled(grid.pendingCount == 0 || grid.isApplying || document.isRunning || grid.isClosing || workspace.isClosing)
                Button("Apply") { Task { await workspace.applyGrid(document) } }.controlHover()
                    .buttonStyle(.borderedProminent)
                    .disabled(grid.pendingCount == 0 || !grid.canEdit)
            }.font(.callout).padding(10)
            if let reason = grid.readOnlyReason {
                Text("Read only: \(reason)").font(.caption).foregroundStyle(.secondary).padding(8)
            } else {
                Text("Double-click a cell to edit. Changes stay local until Apply. Use Columns for types and read-only reasons.")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            }
            if grid.isApplying { ProgressView("Applying changes…").controlSize(.small).padding(8) }
            if grid.outcomeUnknown {
                HStack {
                    Text("Commit outcome unknown. Verify data before making further changes.").foregroundStyle(.orange)
                    Button("Review Data in New Tab") { Task { await workspace.reviewGridData(document) } }.controlHover()
                }.font(.callout).padding(8)
            }
            if let error = grid.error { Text(error).foregroundStyle(.orange).textSelection(.enabled).padding(8) }
            if let notice = grid.notice { Text(notice).foregroundStyle(.secondary).padding(8) }
            Divider()
            ResultTableView(columns: grid.columns, rows: grid.displayedRows,
                editableColumns: grid.canEdit ? grid.editableColumns : [], modifiedCells: grid.modifiedCells,
                deletedRows: grid.deletedRows, valueKinds: grid.rows.map { $0.values.map(\.kind) },
                selectedRows: grid.selectedRows,
                onEditCell: grid.canEdit ? { cell in
                    if let value = grid.value(row: cell.row, column: cell.column) {
                        editing.wrappedValue = GridCellEdit(cell: cell, value: value, column: grid.columns[cell.column])
                    }
                } : nil,
                onSelectedRows: { selected in if grid.selectedRows != selected { grid.selectedRows = selected } },
                onDeleteRows: grid.canEdit ? { grid.deleteSelected() } : nil)
        }
        .sheet(item: editing.projectedValue) { edit in
            GridCellEditor(edit: edit) { value in
                grid.set(value, row: edit.cell.row, column: edit.cell.column)
                editing.wrappedValue = nil
            } cancel: { editing.wrappedValue = nil }
        }
        .sheet(isPresented: Binding(get: { grid.preview != nil }, set: { if !$0 { grid.preview = nil } })) {
            GridSQLPreviewView(result: grid.preview) { grid.preview = nil }
        }
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
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Text(editReason)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
    let value: ChangeValue
    let column: ResultColumn
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit \(edit.column.name)").font(.title2)
            Text("Row \(edit.cell.row + 1) · \(edit.column.nativeType)").font(.caption).foregroundStyle(.secondary)
            ControlSegmentPicker("Value", selection: kind.projectedValue, choices: [
                .init("Value", value: "value"),
                .init("NULL", value: "null"),
                .init("DEFAULT", value: "default"),
            ])
            if kind.wrappedValue == "value" {
                TextEditor(text: text.projectedValue).font(.system(.body, design: .monospaced)).frame(minHeight: 150)
                    .focused($isTextFocused)
                    .focusEffectDisabled()
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isTextFocused ? AppPalette.accent : Color(nsColor: .separatorColor),
                                lineWidth: isTextFocused ? 2 : 1)
                            .allowsHitTesting(false)
                    }
                HStack {
                    Button("Empty Value") { text.wrappedValue = "" }.controlHover()
                    Text(edit.column.encoding == "base64" ? "Enter binary data as Base64." : "An empty value is an empty string, distinct from NULL and DEFAULT.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(kind.wrappedValue == "null" ? "Store SQL NULL." : "Let the server use this column's default value.")
                    .foregroundStyle(.secondary).frame(minHeight: 100)
            }
            if let error = error.wrappedValue { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("Cancel", action: cancel).controlHover().keyboardShortcut(.cancelAction)
                Spacer()
                Button("Stage Change") {
                    if kind.wrappedValue != "value" { save(ChangeValue(kind: kind.wrappedValue)); return }
                    if edit.column.encoding == "base64", Data(base64Encoded: text.wrappedValue) == nil {
                        error.wrappedValue = "Enter valid Base64 for a binary value."
                        return
                    }
                    save(ChangeValue(kind: edit.column.encoding == "base64" ? "binary" : "text", value: text.wrappedValue))
                }.controlHover().buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("stageGridCellChange")
            }
        }.padding(20).frame(width: 620)
            .tint(AppPalette.accent).focusEffectDisabled()
    }
}

private struct GridSQLPreviewView: View {
    let result: BackendMessage?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Apply SQL Preview").font(.title2)
                Spacer()
                Button("Done", action: close).controlHover().keyboardShortcut(.cancelAction)
            }
            Text("Values are bound as parameters. Apply locks and verifies the original rows in a separate transaction.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array((result?.catalogRecords ?? []).enumerated()), id: \.offset) { _, record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record["operation"] ?? "").font(.headline)
                            Text(record["sql"] ?? "").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Text(record["parameters"] ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }.padding(20).frame(width: 820, height: 560)
            .tint(AppPalette.accent).focusEffectDisabled()
    }
}
