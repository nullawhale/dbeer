import SwiftUI

struct GridRowDetailsView: View {
    @ObservedObject var grid: GridDraft
    let canEdit: Bool
    let edit: (ResultGridCell) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Row Details").font(.headline)
                Spacer()
                ControlIconButton(systemName: "xmark", action: close)
                    .help("Close row details").accessibilityLabel("Close row details")
                    .accessibilityIdentifier("gridCloseRowDetails")
            }.padding(12)
            Divider()
            if grid.selectedRows.count == 1, let row = grid.selectedRows.first, grid.rows.indices.contains(row) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Row \(row + 1)").font(.caption).appSecondaryText()
                        ForEach(grid.columns.indices, id: \.self) { column in
                            GridInspectorField(grid: grid, rowID: grid.rows[row].id, column: column,
                                canEdit: canEdit, edit: edit)
                        }
                    }.padding(12)
                }.id(grid.rows[row].id)
            } else {
                Text(grid.selectedRows.isEmpty ? "Select a row to view its fields." : "\(grid.selectedRows.count) rows selected")
                    .font(.callout).appSecondaryText().padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(AppPalette.panel)
        .accessibilityElement(children: .contain).accessibilityIdentifier("gridRowInspector")
    }
}

private struct GridInspectorField: View {
    @ObservedObject var grid: GridDraft
    let rowID: UUID
    let column: Int
    let canEdit: Bool
    let edit: (ResultGridCell) -> Void

    @FocusState private var isTextFocused: Bool

    private var row: Int? { grid.rows.firstIndex { $0.id == rowID } }
    private var value: ChangeValue { row.flatMap { grid.value(row: $0, column: column) } ?? .null }
    private var policy: GridColumnEditing { GridColumnEditing(column: grid.columns[column], metadata: grid.metadata[column]) }
    private var isEditable: Bool {
        canEdit && policy.isEditable && row.map { !grid.rows[$0].isDeleted } == true
    }
    private var text: Binding<String> {
        Binding(get: { value.value ?? "" }, set: { newValue in
            guard newValue != (value.value ?? "") else { return }
            set(ChangeValue(kind: policy.isBinary ? "binary" : "text", value: newValue))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(grid.columns[column].name).font(.callout.weight(.medium)).textSelection(.enabled)
                Spacer(minLength: 4)
                Text(policy.nativeType).font(.caption2).appSecondaryText().lineLimit(1)
            }
            if policy.isBinary {
                HStack {
                    Text(value.kind == "null" ? "NULL" : value.kind == "default" ? "DEFAULT" : "Binary · Base64")
                        .font(.system(.caption, design: .monospaced)).appSecondaryText()
                    Spacer()
                    Button("Edit…") { openEditor() }.controlHover().disabled(!isEditable)
                }
            } else if policy.usesMultilineEditor(for: .null) {
                TextEditor(text: text)
                    .font(.system(.callout, design: .monospaced)).frame(minHeight: 90, maxHeight: 180)
                    .focused($isTextFocused).focusEffectDisabled()
                    .overlay(alignment: .topLeading) {
                        if value.kind == "null" || value.kind == "default" {
                            Text(value.kind == "null" ? "NULL" : "DEFAULT")
                                .font(.system(.callout, design: .monospaced)).appSecondaryText()
                                .padding(4).allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isTextFocused ? AppPalette.accent : AppPalette.border,
                                lineWidth: isTextFocused ? 2 : 1).allowsHitTesting(false)
                    }
                    .disabled(!isEditable).accessibilityIdentifier("gridInspectorValue-\(column)")
            } else {
                TextField(value.kind == "null" ? "NULL" : value.kind == "default" ? "DEFAULT" : "Value", text: text)
                    .textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced))
                    .disabled(!isEditable).accessibilityIdentifier("gridInspectorValue-\(column)")
            }
            if isEditable {
                HStack {
                    Menu("Set Value") {
                        if policy.allowsNull { Button("NULL") { set(.null) } }
                        if policy.allowsDefault { Button("DEFAULT") { set(.default) } }
                        if policy.allowsEmptyString { Button("Empty String") { set(ChangeValue(kind: "text", value: "")) } }
                        Divider()
                        Button("Edit Value…", action: openEditor)
                    }.controlHover().fixedSize().accessibilityIdentifier("gridInspectorKind-\(column)")
                    Spacer()
                    if value.kind == "null" || value.kind == "default" {
                        Text(value.kind == "null" ? "SQL NULL" : "DEFAULT").font(.caption2).appSecondaryText()
                    }
                }
            } else if let reason = grid.metadata[column]["editReason"], !reason.isEmpty {
                Text(reason).font(.caption2).appSecondaryText()
            }
        }
    }

    private func set(_ value: ChangeValue) {
        guard isEditable, let row else { return }
        grid.set(value, row: row, column: column)
    }

    private func openEditor() {
        guard let row else { return }
        edit(ResultGridCell(row: row, column: column))
    }
}
