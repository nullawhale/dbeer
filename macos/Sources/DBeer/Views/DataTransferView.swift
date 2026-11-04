import AppKit
import Darwin
import SwiftUI

struct DataTransferView: View {
    @ObservedObject var model: DataTransferModel
    let close: () -> Void
    private var readingFileState = SwiftUI.State(initialValue: false)
    private var fileErrorState = SwiftUI.State<String?>(initialValue: nil)
    private var readingFile: Bool {
        get { readingFileState.wrappedValue }
        nonmutating set { readingFileState.wrappedValue = newValue }
    }
    private var fileError: String? {
        get { fileErrorState.wrappedValue }
        nonmutating set { fileErrorState.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transfer Data").font(.title2.weight(.semibold))
                    Text("Create a table from a file or copy a table between connections").font(.caption).appSecondaryText()
                }
                Spacer()
                if model.isBusy || readingFile { ProgressView().controlSize(.small) }
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                    .disabled(model.isBusy || readingFile).controlHover()
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    configuration
                    if model.mode == "csv" { fileOptions }
                    DataTransferPresetView(model: model, store: model.presets)
                    if let parsed = model.parsed, model.mode == "csv" { sample(parsed) }
                    if !model.columns.isEmpty { columnMapping }
                    if let reply = model.reply { result(reply) }
                    if let error = fileError ?? model.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            .textSelection(.enabled).accessibilityIdentifier("dataTransferError")
                    }
                }.padding(20)
            }
            Divider()
            HStack(spacing: 12) {
                if model.isBusy {
                    Button("Stop") { Task { await model.stop() } }.controlHover().accessibilityIdentifier("dataTransferStop")
                }
                Spacer()
                Button(model.mode == "csv" ? "Suggest Types" : "Read Source Columns") { Task { await model.describe() } }
                    .disabled(!model.canDescribe || readingFile).controlHover().accessibilityIdentifier("dataTransferDescribe")
                Button("Preview") { Task { await model.preview() } }
                    .disabled(!model.canPreview || readingFile).controlHover().accessibilityIdentifier("dataTransferPreview")
                Button("Apply…") { Task { await model.apply() } }
                    .disabled(!model.canApply || readingFile).controlHover().accessibilityIdentifier("dataTransferApply")
            }.padding(16)
        }
        .frame(minWidth: 980, idealWidth: 1_160, minHeight: 650, idealHeight: 820)
        .background(AppPalette.panel).tint(AppPalette.accent).focusEffectDisabled()
        .interactiveDismissDisabled(model.isBusy || readingFile)
        .accessibilityElement(children: .contain).accessibilityIdentifier("dataTransfer")
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Source", selection: $model.mode) {
                Text("CSV / TSV file").tag("csv")
                Text("Database table").tag("table")
            }.pickerStyle(.segmented).accessibilityIdentifier("dataTransferMode")
            HStack(alignment: .top, spacing: 20) {
                if model.mode == "table" {
                    endpoint("Source", profileID: $model.sourceID, schema: $model.sourceSchema, table: $model.sourceTable)
                    Image(systemName: "arrow.right").appSecondaryText().padding(.top, 32).accessibilityHidden(true)
                }
                endpoint("Destination", profileID: $model.targetID, schema: $model.targetSchema, table: $model.targetTable)
            }
            Text("The destination table must not already exist. Review the suggested column types before Preview and Apply.")
                .font(.caption).appSecondaryText().textSelection(.enabled)
            if model.targetProfile?.policy.readOnly == true {
                Label("The destination connection is readonly. Select a writable connection before Apply.", systemImage: "lock")
                    .foregroundStyle(.orange).font(.callout)
            }
        }.disabled(!model.canEdit || readingFile)
    }
    private func endpoint(_ title: String, profileID: Binding<UUID?>, schema: Binding<String>, table: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Picker("\(title) connection", selection: profileID) {
                Text("Choose connection").tag(UUID?.none)
                ForEach(model.profiles) { profile in
                    Text("\(profile.name) · \(profile.engine.displayName)").tag(Optional(profile.id))
                }
            }.labelsHidden().accessibilityIdentifier("dataTransfer\(title)Connection")
            HStack {
                TextField("Schema / database", text: schema)
                TextField(title == "Source" ? "Source table" : "New table name", text: table)
            }.textFieldStyle(.roundedBorder)
            if let profile = model.profiles.first(where: { $0.id == profileID.wrappedValue }) {
                Text("\(profile.endpointDescription) · \(profile.policy.label)")
                    .font(.caption).appSecondaryText().lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var fileOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Choose File…", action: chooseFile).controlHover().accessibilityIdentifier("dataTransferChooseFile")
                Text(model.fileName ?? "No file selected").font(.callout).appSecondaryText().lineLimit(1)
                Spacer()
                Button("Reparse") { Task { await model.parseCSV() } }.controlHover()
                    .disabled(model.fileName == nil).accessibilityIdentifier("dataTransferReparse")
            }
            HStack(spacing: 16) {
                Picker("Delimiter", selection: $model.options.delimiter) {
                    ForEach(DelimitedImportDelimiter.allCases, id: \.self) { delimiter in Text(delimiter.label).tag(delimiter) }
                }.frame(width: 220)
                Toggle("Header row", isOn: $model.options.hasHeader).toggleStyle(.checkbox).controlHover()
                Toggle("Unquoted empty fields are NULL", isOn: $model.options.emptyFieldsAreNull).toggleStyle(.checkbox).controlHover()
            }
            HStack {
                Toggle("Unquoted NULL marker", isOn: Binding(get: { model.options.nullMarker != nil }, set: {
                    model.options.nullMarker = $0 ? "\\N" : nil
                })).toggleStyle(.checkbox).controlHover()
                TextField("NULL marker", text: Binding(get: { model.options.nullMarker ?? "" }, set: { model.options.nullMarker = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 160).disabled(model.options.nullMarker == nil)
            }
            Text("Quoted fields remain text. Files use UTF-8 and the existing import size limits. Changing parser options requires Reparse and a new type review.")
                .font(.caption).appSecondaryText().textSelection(.enabled)
        }.disabled(!model.canEdit || readingFile)
    }
    private func sample(_ document: DelimitedImportDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File Preview · \(document.rows.count) rows · \(document.headers.count) columns").font(.headline)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 5) {
                    Text(document.headers.map { excerpt($0, limit: 128) }.joined(separator: "  │  ")).fontWeight(.semibold)
                    Divider()
                    ForEach(Array(document.rows.prefix(20).enumerated()), id: \.offset) { _, row in
                        Text(row.fields.map { field in
                            if !field.wasQuoted && (model.options.nullMarker.map { field.text.utf8.elementsEqual($0.utf8) } == true || model.options.emptyFieldsAreNull && field.text.isEmpty) { return "⟨NULL⟩" }
                            return field.text.isEmpty ? "⟨empty⟩" : excerpt(field.text)
                        }.joined(separator: "  │  "))
                    }
                }.font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(10)
            }.frame(height: 150).background(AppPalette.background, in: RoundedRectangle(cornerRadius: 6))
            Text("Showing the first 20 data rows; long fields are abbreviated. Type validation checks all supplied rows.").font(.caption).appSecondaryText()
        }
    }
    private func excerpt(_ value: String, limit: Int = 256) -> String {
        let bytes = value.utf8
        return String(decoding: bytes.prefix(limit), as: UTF8.self).replacingOccurrences(of: "\n", with: "↵") + (bytes.count > limit ? "…" : "")
    }
    private var columnMapping: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review Destination Columns").font(.headline)
            Text("Removing a column excludes it from the new table. Suggest Types / Read Source Columns restores the proposed mapping.")
                .font(.caption).appSecondaryText()
            ForEach(model.columns) { column in
                DataTransferColumnRow(model: model, sourceIndex: column.sourceIndex)
            }
        }.disabled(!model.canEdit || readingFile)
    }
    private func result(_ reply: DataTransferReply) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(resultTitle(reply)).font(.headline)
            if ["pending", "running"].contains(reply.state) { ProgressView().progressViewStyle(.linear) }
            Text("\(reply.rowsRead) rows read · \(reply.rowsWritten) rows written").font(.caption).monospacedDigit().appSecondaryText()
            if let message = reply.message { Text(message).textSelection(.enabled) }
            if reply.tableCreated {
                Label("The destination table was created.", systemImage: "tablecells").font(.callout)
            }
            if model.hasUnknownOutcome || reply.outcomeUnknown {
                Label("Inspect the destination before another transfer. The operation will not be replayed automatically.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled)
            }
            ForEach(Array(reply.notices.enumerated()), id: \.offset) { _, notice in
                Label(notice, systemImage: "info.circle").font(.callout).appSecondaryText().textSelection(.enabled)
            }
            if let diagnostics = reply.diagnostics, !diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Type Validation").font(.headline)
                    ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        Text("Row \(diagnostic.row), column \(diagnostic.column): \(diagnostic.message)")
                            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
            }
            if let sql = reply.sql, !sql.isEmpty {
                Text("SQL Preview").font(.headline)
                ScrollView([.horizontal, .vertical]) {
                    Text(sql).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 90, maxHeight: 220).padding(10)
                    .background(AppPalette.background, in: RoundedRectangle(cornerRadius: 6))
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.background, in: RoundedRectangle(cornerRadius: 8))
    }
    private func resultTitle(_ reply: DataTransferReply) -> String {
        switch reply.state {
        case "described": "Suggested Types"
        case "ready": "Preview Ready"
        case "completed": "Transfer Completed"
        case "outcomeUnknown": "Transfer Outcome Is Uncertain"
        case "failed": "Transfer Failed"
        case "cancelled": "Transfer Stopped"
        default: "Transfer · \(reply.phase)"
        }
    }
    private func chooseFile() {
        guard model.canEdit, !readingFile else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose CSV or TSV File"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        readingFile = true; fileError = nil
        Task { @MainActor in
            defer { readingFile = false }
            do {
                let data = try await Task.detached { try Self.readFile(url) }.value
                await model.loadCSV(data, name: url.lastPathComponent)
            } catch {
                fileError = "The selected file could not be read. Choose a regular UTF-8 file within the 8 MiB import limit."
            }
        }
    }
    private nonisolated static func readFile(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw TransferPresetError.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              info.st_size <= DelimitedTextImport.maximumInputBytes else { throw TransferPresetError.unavailable }
        let data = try handle.read(upToCount: DelimitedTextImport.maximumInputBytes + 1) ?? Data()
        guard data.count <= DelimitedTextImport.maximumInputBytes else { throw TransferPresetError.unavailable }
        return data
    }
}

private struct DataTransferColumnRow: View {
    @ObservedObject var model: DataTransferModel
    let sourceIndex: Int
    var body: some View {
        if let column = model.columns.first(where: { $0.sourceIndex == sourceIndex }) { row(column) }
    }
    private func binding<Value>(_ path: WritableKeyPath<DataTransferColumn, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { model.columns.first { $0.sourceIndex == sourceIndex }?[keyPath: path] ?? fallback }, set: { value in
            guard let index = model.columns.firstIndex(where: { $0.sourceIndex == sourceIndex }) else { return }
            model.columns[index][keyPath: path] = value
        })
    }
    private func row(_ column: DataTransferColumn) -> some View {
        HStack(spacing: 10) {
            Text(model.headers.indices.contains(sourceIndex) ? model.headers[sourceIndex] : "Column \(sourceIndex + 1)")
                .font(.system(.caption, design: .monospaced)).lineLimit(1).frame(width: 145, alignment: .leading)
            TextField("Destination name", text: binding(\.name, fallback: column.name)).textFieldStyle(.roundedBorder)
            Picker("Type", selection: Binding(get: { model.columns.first { $0.sourceIndex == sourceIndex }?.type ?? column.type }, set: { type in
                guard let index = model.columns.firstIndex(where: { $0.sourceIndex == sourceIndex }) else { return }
                model.columns[index].type = type
                model.columns[index].precision = type == "decimal" ? (model.columns[index].precision ?? 38) : nil
                model.columns[index].scale = type == "decimal" ? (model.columns[index].scale ?? 0) : nil
            })) {
                ForEach(DataTransferColumn.types, id: \.self) { type in
                    Text(type == "json" && model.targetProfile?.engine == .mysql ? "JSON (validated text)" : type).tag(type)
                }
            }.labelsHidden().frame(width: 130)
            if column.type == "decimal" {
                TextField("Precision", value: Binding(get: { model.columns.first { $0.sourceIndex == sourceIndex }?.precision ?? 38 }, set: { value in
                    guard let index = model.columns.firstIndex(where: { $0.sourceIndex == sourceIndex }) else { return }; model.columns[index].precision = value
                }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 65)
                TextField("Scale", value: Binding(get: { model.columns.first { $0.sourceIndex == sourceIndex }?.scale ?? 0 }, set: { value in
                    guard let index = model.columns.firstIndex(where: { $0.sourceIndex == sourceIndex }) else { return }; model.columns[index].scale = value
                }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
            }
            Toggle("NULL", isOn: binding(\.nullable, fallback: column.nullable)).toggleStyle(.checkbox).controlHover()
            Button { model.columns.removeAll { $0.sourceIndex == sourceIndex } } label: { Image(systemName: "minus.circle") }
                .help("Exclude this source column").controlHover()
        }
    }
}

private struct DataTransferPresetView: View {
    @ObservedObject var model: DataTransferModel
    @ObservedObject var store: TransferMappingPresetStore
    private var selectionState = SwiftUI.State<UUID?>(initialValue: nil)
    private var nameState = SwiftUI.State(initialValue: "")
    private var errorState = SwiftUI.State<String?>(initialValue: nil)
    private var selection: UUID? {
        get { selectionState.wrappedValue }
        nonmutating set { selectionState.wrappedValue = newValue }
    }
    private var name: String {
        get { nameState.wrappedValue }
        nonmutating set { nameState.wrappedValue = newValue }
    }
    private var error: String? {
        get { errorState.wrappedValue }
        nonmutating set { errorState.wrappedValue = newValue }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saved Mappings").font(.headline)
                Spacer()
                Button("Reload") { Task { await store.load() } }.controlHover().disabled(store.isBusy)
            }
            HStack {
                Picker("Saved mapping", selection: Binding(get: { selection }, set: { selection = $0 })) {
                    Text("Choose mapping").tag(UUID?.none)
                    ForEach(store.presets) { preset in Text(preset.name).tag(Optional(preset.id)) }
                }.labelsHidden()
                Button("Use") {
                    guard let preset = store.presets.first(where: { $0.id == selection }) else { return }
                    Task { await model.useMapping(preset) }
                }.disabled(selection == nil).controlHover()
                Button("Delete") {
                    guard let selection else { return }
                    Task { do { try await store.delete(selection); self.selection = nil } catch { self.error = error.localizedDescription } }
                }.disabled(selection == nil).controlHover()
            }
            HStack {
                TextField("New mapping name", text: Binding(get: { name }, set: { name = $0 })).textFieldStyle(.roundedBorder)
                Button("Save Mapping") { Task { await model.saveMapping(name: name) } }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.columns.isEmpty || !store.loaded).controlHover()
            }
            Text("Only column names, reviewed types and parser settings are saved. File contents, paths and connection credentials are excluded.")
                .font(.caption).appSecondaryText().textSelection(.enabled)
            if let error = error ?? store.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.disabled(!model.canEdit || store.isBusy)
            .task { if !store.loaded { await store.load() } }
    }
}
