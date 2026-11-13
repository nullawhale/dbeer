import SwiftUI

struct ForeignKeyPickerView: View {
    @ObservedObject var model: ForeignKeyPickerModel
    let chosen: () -> Void
    let back: () -> Void
    private var selectedRow = SwiftUI.State<UUID?>(initialValue: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Related Record").font(.title2)
            Text(model.key.displayLabel).font(.callout).textSelection(.enabled)
            HStack {
                Picker("Search column", selection: Binding(get: { Data(model.searchColumn.utf8) }, set: {
                    model.searchColumn = String(decoding: $0, as: UTF8.self)
                })) {
                    ForEach(Array(model.displayOptions.enumerated()), id: \.offset) { _, name in
                        Text(name).tag(Data(name.utf8))
                    }
                }.frame(maxWidth: 240)
                TextField("Search value", text: $model.search).textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Toggle("Exact Match", isOn: $model.exactMatch).toggleStyle(.checkbox)
                Button("Search", action: search).controlHover().disabled(model.isBusy || model.metadata.isEmpty)
            }
            Text("Use Exact Match for numbers, UUIDs and Base64 binary keys.").font(.caption).appSecondaryText()
            if model.engine == .sqlite && model.exactMatch {
                Picker("SQLite storage type", selection: $model.sqliteSearchType) {
                    Text("Text").tag("text")
                    Text("Integer").tag("integer")
                    Text("Real").tag("real")
                    Text("BLOB (Base64)").tag("blob")
                }.frame(maxWidth: 300)
            }
            HStack {
                Menu("Display Columns") {
                    ForEach(Array(model.displayOptions.enumerated()), id: \.offset) { _, name in
                        let identity = Data(name.utf8)
                        Toggle(name, isOn: Binding(get: { model.displayColumns.contains(identity) }, set: { include in
                            if include { model.displayColumns.insert(identity) } else { model.displayColumns.remove(identity) }
                        })).disabled(!model.displayColumns.contains(identity) && model.displayColumns.count >= 8)
                    }
                }.controlHover()
                Text("Key values are always shown.").font(.caption).appSecondaryText()
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Stop") { Task { await model.stop() } }.controlHover()
                }
            }
            if let error = model.error {
                HStack(alignment: .top) {
                    Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    if model.metadata.isEmpty {
                        Button("Retry Metadata") { Task { await model.load() } }.controlHover().disabled(model.isBusy)
                    }
                }.font(.caption)
            }
            if let notice = model.notice { Text(notice).font(.caption).appSecondaryText().textSelection(.enabled) }
            if model.hasUnappliedSearch {
                Text("Choose Search to apply the changed search settings.").font(.caption).foregroundStyle(.orange)
            }
            List(selection: selectedRow.projectedValue) {
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.label(row, keysOnly: true)).font(.system(.callout, design: .monospaced))
                        let description = model.label(row)
                        if !description.isEmpty { Text(description).font(.callout).appSecondaryText() }
                        if let reason = model.choiceError(row) { Text(reason).font(.caption).foregroundStyle(.orange) }
                    }.tag(row.id).padding(.vertical, 3)
                }
            }.frame(minHeight: 190)
                .overlay { if !model.isBusy && model.rows.isEmpty { Text("No referenced records loaded.").appSecondaryText() } }
            if let row = model.rows.first(where: { $0.id == selectedRow.wrappedValue }) {
                GroupBox("Selected Key") {
                    ScrollView([.horizontal, .vertical]) {
                        Text(model.label(row, keysOnly: true, preview: false))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 65)
                }
            }
            HStack {
                Button("Back to Cell Editor") { Task { await model.close(); back() } }
                    .controlHover().keyboardShortcut(.cancelAction)
                Spacer()
                Button("Previous") { page(-1) }.controlHover().disabled(model.isBusy || model.hasUnappliedSearch || model.page == 0)
                Text("Page \(model.page + 1) · \(model.rows.count) loaded rows").font(.caption).monospacedDigit()
                Button("Next") { page(1) }.controlHover().disabled(model.isBusy || model.hasUnappliedSearch || !model.hasNext)
                Button("Stage Related Key") {
                    guard let row = model.rows.first(where: { $0.id == selectedRow.wrappedValue }), model.choose(row) else { return }
                    chosen()
                }.controlHover().buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.hasUnappliedSearch || selectedRow.wrappedValue == nil ||
                        model.rows.first(where: { $0.id == selectedRow.wrappedValue }).map { model.choiceError($0) != nil } != false)
            }
            Text("Selection changes the local row draft. Preview SQL and Apply save it to the database.")
                .font(.caption).appSecondaryText()
        }.padding(20).frame(width: 800, height: 640)
            .task { await model.load() }
            .onDisappear { Task { await model.close() } }
            .tint(AppPalette.accent).focusEffectDisabled()
    }

    private func search() {
        selectedRow.wrappedValue = nil
        Task { await model.searchRows() }
    }

    private func page(_ offset: Int) {
        selectedRow.wrappedValue = nil
        Task { await model.searchRows(page: model.page + offset) }
    }
}
