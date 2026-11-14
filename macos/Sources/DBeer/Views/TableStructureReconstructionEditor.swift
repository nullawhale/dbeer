import SwiftUI

struct TableStructureReconstructionEditor: View {
    @ObservedObject var model: TableStructureEditorModel
    private var enabled: Bool { model.reconstructionAvailable && !model.isBusy && !model.closing && !model.invalidated && model.outcome == nil }
    private var backfills: [StructureBackfill] { model.draft.backfills ?? [] }
    var body: some View {
        GroupBox("Backfill and Physical Layout") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Use a separate draft for backfill, physical column order or reconstruction. Remove unrelated column changes, keys, indexes, table rename or deletion before Preview. The complete SQL and preservation limits are reviewed before Apply. MySQL backfill must also be reviewed separately from physical order or reconstruction.")
                    .font(.caption).appSecondaryText()
                Button("Append Required Column With Backfill") {
                    guard enabled, model.reconstructionColumnNames.count < 128 else { return }
                    model.draft.columns.append(.init(name: "", type: .init(kind: "integer"), nullable: false, default: .init(kind: "none")))
                    model.draft.backfills = backfills + [.init(column: "", expression: "")]
                    model.draft.allowDestructive = nil
                }.controlHover().disabled(!enabled || model.reconstructionColumnNames.count >= 128)
                ForEach(backfills.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            StructureExactNamePicker(title: "Required new column", placeholder: "Choose appended column", names: model.draft.columns.map(\.name),
                                selection: Binding(get: { backfills.indices.contains(i) ? backfills[i].column : "" }, set: {
                                    guard enabled, backfills.indices.contains(i) else { return }
                                    model.draft.backfills?[i].column = $0; model.draft.allowDestructive = nil
                                }))
                            ControlIconButton(systemName: "minus.circle") {
                                guard enabled, backfills.indices.contains(i) else { return }
                                var retained = backfills; retained.remove(at: i)
                                model.draft.backfills = retained.isEmpty ? nil : retained
                                model.draft.allowDestructive = nil
                            }.help("Remove this backfill intent").accessibilityLabel("Remove backfill")
                        }
                        TextField("Exact backfill expression", text: Binding(get: { backfills.indices.contains(i) ? backfills[i].expression : "" }, set: {
                            guard enabled, backfills.indices.contains(i) else { return }
                            model.draft.backfills?[i].expression = $0; model.draft.allowDestructive = nil
                        })).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        Text("The column must be NOT NULL, builtin and ordinary, with no default, generation or identity. Preview shows the exact UPDATE or copy SELECT expression; it never evaluates this expression.")
                            .font(.caption).appSecondaryText()
                    }
                }
                Toggle("Request physical column order", isOn: Binding(get: { model.draft.columnOrder != nil }, set: {
                    guard enabled else { return }
                    model.draft.columnOrder = $0 ? model.reconstructionColumnNames : nil; model.draft.allowDestructive = nil
                })).controlHover()
                if let order = model.draft.columnOrder {
                    ForEach(order.indices, id: \.self) { i in
                        HStack {
                            Text("\(i + 1). " + order[i]).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            ControlIconButton(systemName: "arrow.up") { model.moveReconstructionColumn(at: i, by: -1) }.disabled(i == 0).accessibilityLabel("Move column up")
                            ControlIconButton(systemName: "arrow.down") { model.moveReconstructionColumn(at: i, by: 1) }.disabled(i + 1 == order.count).accessibilityLabel("Move column down")
                        }
                    }
                    if !model.hasExactReconstructionOrder {
                        Text("Column order must include every loaded and appended column exactly once. Update the list after changing appended columns.").font(.caption).foregroundStyle(.orange)
                    }
                    Button("Use Loaded and Appended Column Order") {
                        guard enabled else { return }
                        model.draft.columnOrder = model.reconstructionColumnNames; model.draft.allowDestructive = nil
                    }.controlHover()
                }
                Toggle("Explicitly reconstruct table", isOn: Binding(get: { model.draft.reconstruct == true }, set: {
                    guard enabled else { return }
                    model.draft.reconstruct = $0 ? true : nil; model.draft.allowDestructive = nil
                })).controlHover()
                Text("Physical changes can rewrite stored data, lock the table and affect dependents. Preview blocks layouts whose data, constraints, indexes or dependent objects cannot be proven preserved. Partial or unknown outcomes retain this intent and require explicit reconciliation; no step is retried automatically.")
                    .font(.caption).appSecondaryText()
                if !model.reconstructionAvailable {
                    Text("Backfill and layout intent is retained. Reconnect with a helper supporting table reconstruction before Preview.").font(.caption).foregroundStyle(.orange)
                }
            }.disabled(!enabled)
        }
    }
}
