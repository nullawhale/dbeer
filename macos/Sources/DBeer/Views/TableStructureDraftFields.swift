import SwiftUI

struct TableStructureDraftFields: View {
    @ObservedObject var model: TableStructureEditorModel
    var allowCrossDatabase = false
    private var canEdit: Bool { !model.isBusy && !model.closing && !model.invalidated && model.baseline != nil && model.outcome == nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let support = model.baseline?.advanced { TableStructureAdvancedKindDetails(support: support) }
            if !model.create && (model.destructiveAvailable || model.draft.dropTable) {
                Toggle("Drop table and all its stored data", isOn: Binding(get: { model.draft.dropTable }, set: {
                    model.draft.dropTable = $0; model.draft.allowDestructive = nil
                })).controlHover().disabled(!model.destructiveAvailable || model.baseline?.advanced != nil)
                if model.draft.dropTable {
                    Text("Table deletion must be the only operation in this draft. Other authored edits are retained; remove them or turn off Drop table before Preview. Dependencies and data-loss consequences are reviewed before Apply.").font(.caption).foregroundStyle(.orange)
                }
            }
            Group {
            if !model.create && model.authoringAvailable && model.permitsAdvanced("renameTable") {
                Toggle("Rename table", isOn: Binding(get: { model.draft.renameTable != nil }, set: { model.draft.renameTable = $0 ? "" : nil })).controlHover()
                if model.draft.renameTable != nil {
                    TextField("Exact resulting table name", text: Binding(get: { model.draft.renameTable ?? "" }, set: { model.draft.renameTable = $0 })).textFieldStyle(.roundedBorder)
                    Text("The reviewed target and execution history keep the original table name. Reconciliation can read the resulting table explicitly.").font(.caption).appSecondaryText()
                }
            }
            ForEach(model.draft.columns.indices, id: \.self) { i in
                TableStructureNewColumnEditor(column: columnBinding(i), number: i + 1, engine: model.profile.engine,
                    create: model.create, authoringAvailable: model.authoringAvailable, canRemove: !model.create || model.draft.columns.count > 1) {
                    guard canEdit, model.draft.columns.indices.contains(i) else { return }
                    let removed = model.draft.columns.remove(at: i)
                    let fills = (model.draft.backfills ?? []).filter { !StructureTarget.sameIdentifier($0.column, removed.name) }
                    model.draft.backfills = fills.isEmpty ? nil : fills
                    model.draft.columnOrder = model.draft.columnOrder?.filter { !StructureTarget.sameIdentifier($0, removed.name) }
                    if model.draft.destructive { model.draft.allowDestructive = nil }
                }
            }
            if model.create {
                Button("Add Column") {
                    guard canEdit, model.draft.columns.count < 128 else { return }
                    model.draft.columns.append(TableStructureEditorModel.emptyColumn)
                }.controlHover().disabled(!canEdit || model.draft.columns.count >= 128)
            }
            TableStructureIntentEditors(model: model, allowCrossDatabase: allowCrossDatabase)
            if !model.create && model.permitsAdvanced("reconstruction") { TableStructureReconstructionEditor(model: model) }
            }.disabled(model.draft.dropTable)
            if model.draft.dropTable {
                Toggle("Include table deletion in Preview", isOn: Binding(get: { model.draft.allowDestructive == true }, set: { model.draft.allowDestructive = $0 })).controlHover()
            }
        }.disabled(!canEdit)
    }
    private func columnBinding(_ i: Int) -> Binding<StructureColumn> {
        Binding(get: { model.draft.columns.indices.contains(i) ? model.draft.columns[i] : TableStructureEditorModel.emptyColumn }, set: {
            guard canEdit, model.draft.columns.indices.contains(i) else { return }
            let oldName = model.draft.columns[i].name
            model.draft.columns[i] = $0
            let newName = $0.name
            model.draft.backfills = model.draft.backfills?.map { fill in
                var updated = fill
                if StructureTarget.sameIdentifier(fill.column, oldName) { updated.column = newName }
                return updated
            }
            model.draft.columnOrder = model.draft.columnOrder?.map { StructureTarget.sameIdentifier($0, oldName) ? newName : $0 }
            if model.draft.destructive { model.draft.allowDestructive = nil }
        })
    }
}
