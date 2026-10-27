import SwiftUI

struct InsertCopyView: View {
    @ObservedObject var workspace: ApplicationWorkspace
    let selection: InsertCopySelection
    @Environment(\.dismiss) private var dismiss
    private var engine: SwiftUI.State<DatabaseEngine>
    private var schema: SwiftUI.State<String>
    private var table: SwiftUI.State<String>
    private var columnNames: SwiftUI.State<[String]>
    private var isCopying = SwiftUI.State(initialValue: false)
    private var error = SwiftUI.State<String?>(initialValue: nil)

    init(workspace: ApplicationWorkspace, selection: InsertCopySelection) {
        self.workspace = workspace
        self.selection = selection
        engine = SwiftUI.State(initialValue: selection.engine)
        schema = SwiftUI.State(initialValue: selection.schema)
        table = SwiftUI.State(initialValue: selection.table)
        columnNames = SwiftUI.State(initialValue: selection.payload.columns.map(\.name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy as SQL INSERT").font(.title2)
            Text("Choose the destination for \(selection.payload.values.count) selected rows. This copies SQL without connecting or executing it.")
                .font(.callout).appSecondaryText()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                SwiftUI.GridRow {
                    Text("Dialect")
                    Picker("Dialect", selection: engine.projectedValue) {
                        Text("PostgreSQL").tag(DatabaseEngine.postgresql)
                        Text("MySQL").tag(DatabaseEngine.mysql)
                    }.labelsHidden().controlHover().accessibilityIdentifier("insertCopyDialect")
                }
                SwiftUI.GridRow {
                    Text("Schema / database")
                    TextField("Optional", text: schema.projectedValue).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Target schema or database").accessibilityIdentifier("insertCopySchema")
                }
                SwiftUI.GridRow {
                    Text("Table")
                    TextField("Target table", text: table.projectedValue).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Target table").accessibilityIdentifier("insertCopyTable")
                }
            }.disabled(isCopying.wrappedValue)
            Text("Target columns").font(.headline)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(selection.payload.columns.indices, id: \.self) { index in
                        HStack {
                            Text("\(index + 1). \(selection.payload.columns[index].name)")
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right").accessibilityHidden(true)
                            TextField("Target column", text: Binding(
                                get: { columnNames.wrappedValue[index] },
                                set: { columnNames.wrappedValue[index] = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Target column \(index + 1)")
                        }
                    }
                }.padding(.trailing, 8)
            }.frame(minHeight: 70, maxHeight: 200).disabled(isCopying.wrappedValue)
            Text("Target column names must be unique. Text and exact numbers are copied as string literals; the destination table determines their types. NULL, DEFAULT and binary data retain their meaning.")
                .font(.caption).appSecondaryText()
            if let message = error.wrappedValue {
                Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .accessibilityIdentifier("insertCopyError")
            } else if request == nil {
                Text("Enter a target table and unique column names. Copy at most 1,000 rows, 100,000 cells and 8 MiB at once.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Cancel") { dismiss() }.controlHover().keyboardShortcut(.cancelAction)
                    .disabled(isCopying.wrappedValue)
                Spacer()
                if isCopying.wrappedValue { ProgressView().controlSize(.small) }
                Button("Copy INSERT", action: copy).controlHover().buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(request == nil || isCopying.wrappedValue)
                    .accessibilityIdentifier("insertCopyConfirm")
            }
        }
        .padding(20).frame(width: 580)
        .tint(AppPalette.accent).focusEffectDisabled().interactiveDismissDisabled(isCopying.wrappedValue)
    }

    private var request: InsertFormatRequest? {
        try? selection.request(engine: engine.wrappedValue, schema: schema.wrappedValue,
            table: table.wrappedValue, columnNames: columnNames.wrappedValue)
    }

    private func copy() {
        guard let request, !isCopying.wrappedValue else { return }
        isCopying.wrappedValue = true
        error.wrappedValue = nil
        let publisher = ResultCopyPublication.shared
        let ticket = publisher.capture(changeCount: selection.pasteboard.changeCount)
        Task {
            defer { isCopying.wrappedValue = false }
            do {
                let sql = try await workspace.formatInsertCopy(request)
                guard workspace.insertCopySelection?.id == selection.id, !workspace.isClosing else { return }
                let payload = selection.payload
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try PreparedResultCopy(payload: payload, format: .sqlInsert, includesHeaders: false, insertSQL: sql)
                }.value
                guard workspace.insertCopySelection?.id == selection.id, !workspace.isClosing else { return }
                guard publisher.publish(prepared, to: selection.pasteboard, ticket: ticket) else {
                    error.wrappedValue = "The clipboard changed while preparing SQL. Choose Copy INSERT again."
                    return
                }
                dismiss()
            } catch {
                self.error.wrappedValue = error.localizedDescription
            }
        }
    }
}
