import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TableImportView: View {
    @ObservedObject var model: TableImportModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Import CSV / TSV").font(.title2)
                Spacer()
                Text(model.profile.name).appSecondaryText()
            }
            Text(model.profile.engine.displayName + " · " + model.profile.endpointDescription +
                " · " + model.profile.policy.label)
                .font(.caption).appSecondaryText().textSelection(.enabled)
            Text(model.schema + "." + model.table).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text("Choose a local UTF-8 file, map its columns and review the SQL. Apply inserts every row in one transaction. Existing rows are not replaced.")
                .font(.caption).appSecondaryText()
            HStack {
                Button(model.columns.isEmpty ? "Load Columns" : "Reload Columns") {
                    Task { await model.load() }
                }.controlHover().disabled(!model.canLoad)
                Button("Choose File…", action: chooseFile).controlHover().disabled(!model.canEdit)
                    .accessibilityIdentifier("tableImportChooseFile")
                if let file = model.fileName {
                    Text(file).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                if let parsed = model.parsed {
                    Text("\(parsed.rows.count) rows · \(parsed.headers.count) source columns")
                        .font(.caption).appSecondaryText()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fileOptions
                    TableImportMappingLibraryView(model: model, store: model.mappingPresets)
                    if let parsed = model.parsed {
                        columnMapping(parsed)
                        dataPreview(parsed)
                    }
                    if let preview = model.preview, let sql = preview.sql {
                        GroupBox("Reviewed SQL · \(preview.rowCount ?? 0) rows") {
                            VStack(alignment: .leading, spacing: 8) {
                                ScrollView([.horizontal, .vertical]) {
                                    Text(sql).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(minHeight: 45, maxHeight: 150)
                                Text("This INSERT template uses bound values from the file preview. Only Apply sends rows to the database.")
                                    .font(.caption).appSecondaryText()
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityIdentifier("tableImportSQLPreview")
                    }
                    outcome
                    if let validation = model.validationMessage {
                        Text(validation).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let error = model.error {
                        Text(error).foregroundStyle(.orange).textSelection(.enabled)
                            .accessibilityIdentifier("tableImportError")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 250, idealHeight: 460, maxHeight: 620)
            footer
        }.padding(20).frame(width: 880).frame(minHeight: 430, idealHeight: 680, maxHeight: 840)
            .interactiveDismissDisabled()
            .accessibilityElement(children: .contain).accessibilityIdentifier("tableImport")
    }

    private var fileOptions: some View {
        GroupBox("File options") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Picker("Delimiter", selection: option(\.delimiter)) {
                        Text("Comma (CSV)").tag(DelimitedImportDelimiter.comma)
                        Text("Tab (TSV)").tag(DelimitedImportDelimiter.tab)
                    }.pickerStyle(.menu).frame(width: 220)
                    Toggle("First row contains column names", isOn: option(\.hasHeader))
                        .toggleStyle(.checkbox).controlHover()
                }
                HStack(spacing: 12) {
                    Toggle("NULL marker", isOn: Binding(get: { model.options.nullMarker != nil }, set: {
                        var options = model.options
                        options.nullMarker = $0 ? "\\N" : nil
                        model.options = options
                    })).toggleStyle(.checkbox).controlHover()
                    TextField("Exact marker", text: Binding(get: { model.options.nullMarker ?? "" }, set: {
                        var options = model.options
                        options.nullMarker = $0
                        model.options = options
                    })).textFieldStyle(.roundedBorder).frame(width: 130)
                        .disabled(model.options.nullMarker == nil)
                    Toggle("Unquoted empty fields become NULL", isOn: option(\.emptyFieldsAreNull))
                        .toggleStyle(.checkbox).controlHover()
                }
                Text("Quoted markers and quoted empty fields stay text. Binary target columns accept canonical Base64. Omit a target column to use its default or database NULL.")
                    .font(.caption).appSecondaryText()
                Text("Limits: 8 MiB file, 10,000 rows, 256 source columns, 100,000 cells and 4 MiB of mapped values.")
                    .font(.caption).appSecondaryText()
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }.disabled(!model.canEditOptions)
    }

    private func columnMapping(_ parsed: DelimitedImportDocument) -> some View {
        GroupBox("Column mapping") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Exact, unique header names are mapped automatically. Select a target for other columns, or leave them skipped.")
                    .font(.caption).appSecondaryText()
                ForEach(parsed.headers.indices, id: \.self) { source in
                    HStack(spacing: 10) {
                        Text("\(source + 1). " + parsed.headers[source])
                            .font(.system(.body, design: .monospaced)).lineLimit(1)
                            .frame(width: 225, alignment: .leading)
                            .help(parsed.headers[source])
                        Image(systemName: "arrow.right").appSecondaryText()
                        Picker("Target for source column \(source + 1)", selection: mappingSelection(source)) {
                            Text("Skip this column").tag(-1)
                            ForEach(model.columns.indices, id: \.self) { target in
                                let column = model.columns[target]
                                Text(column.name + (column.generated ? " (generated)" : ""))
                                    .tag(target).disabled(column.generated)
                            }
                        }.labelsHidden().pickerStyle(.menu).frame(width: 245)
                        if let target = selectedTarget(source) {
                            Text(target.nativeType + (target.nullable ? " · nullable" : " · required") +
                                (target.hasDefault ? " · default" : "") + (target.binary ? " · Base64" : ""))
                                .font(.caption).appSecondaryText().textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if !model.requiredUnmappedColumns.isEmpty {
                    Text("Required targets still missing: " + model.requiredUnmappedColumns.map(\.name).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                let omitted = model.unmappedColumns.filter { !$0.generated && ($0.hasDefault || $0.nullable) }
                if !omitted.isEmpty {
                    DisclosureGroup("Omitted targets use defaults or NULL (\(omitted.count))") {
                        Text(omitted.map { $0.name + ($0.hasDefault ? " → DEFAULT" : " → NULL") }.joined(separator: "\n"))
                            .font(.caption).appSecondaryText().textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }.disabled(!model.canEdit)
    }

    private func dataPreview(_ parsed: DelimitedImportDocument) -> some View {
        GroupBox("File preview · first \(min(20, parsed.rows.count)) of \(parsed.rows.count) rows") {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    SwiftUI.GridRow {
                        Text("File line").font(.caption.bold())
                        ForEach(parsed.headers.indices, id: \.self) { column in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(parsed.headers[column]).font(.caption.bold())
                                Text(model.mapping.indices.contains(column) ? model.mapping[column] ?? "Skipped" : "Skipped")
                                    .font(.caption2).appSecondaryText()
                            }.frame(width: 155, alignment: .leading)
                        }
                    }
                    ForEach(Array(parsed.rows.prefix(20).enumerated()), id: \.offset) { index, row in
                        SwiftUI.GridRow {
                            Text("\(row.number)").font(.caption).appSecondaryText()
                            ForEach(parsed.headers.indices, id: \.self) { column in
                                cell(model.previewValue(row: index, source: column))
                                    .frame(width: 155, alignment: .leading)
                            }
                        }
                    }
                }.padding(.vertical, 4)
            }.frame(maxHeight: 400)
            Text("NULL is shown separately from empty text (\"\"). Long values are shortened only in this preview.")
                .font(.caption).appSecondaryText().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func cell(_ value: ChangeValue?) -> some View {
        if let value {
            if value.kind == "null" {
                Text("NULL").italic().foregroundStyle(.secondary).font(.system(.caption, design: .monospaced))
            } else if value.kind == "binary" {
                Text("Base64 · \(Data(base64Encoded: value.value ?? "")?.count ?? 0) bytes")
                    .font(.caption).appSecondaryText()
            } else {
                let text = value.value ?? ""
                Text(text.isEmpty ? "\"\"" : String(text.prefix(100)) + (text.count > 100 ? "…" : ""))
                    .font(.system(.caption, design: .monospaced)).lineLimit(3).textSelection(.enabled)
            }
        } else {
            Text("Invalid value").font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var outcome: some View {
        if let rows = model.appliedRowCount {
            Text("Imported \(rows) rows. Close this import before starting another batch.")
                .font(.headline).textSelection(.enabled)
        } else if model.outcomeUnknown {
            Text("The commit outcome is unknown. Check the target table before starting another import; this batch will not be sent again.")
                .font(.headline).foregroundStyle(.orange).textSelection(.enabled)
        } else if model.outcome == .failed {
            Text("The import did not complete. Review the error and prepare a fresh preview before trying again.")
                .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
        }
    }

    private var footer: some View {
        HStack {
            if model.profile.policy.readOnly {
                Text("Readonly: preview is available; Apply is disabled.").font(.caption).appSecondaryText()
            }
            Spacer()
            if model.isBusy {
                ProgressView().controlSize(.small)
                Button("Stop") { Task { await model.stop() } }.controlHover().disabled(model.closing)
            }
            Button("Preview SQL") { Task { await model.preparePreview() } }.controlHover()
                .disabled(!model.canPreview).accessibilityIdentifier("tableImportPreview")
            Button("Apply") { Task { await model.apply() } }.controlHover()
                .disabled(!model.canApply).accessibilityIdentifier("tableImportApply")
            Button("Close") { close() }.controlHover().disabled(model.isBusy || model.closing)
                .keyboardShortcut(.cancelAction)
        }
    }

    private func option<Value>(_ key: WritableKeyPath<DelimitedImportOptions, Value>) -> Binding<Value> {
        Binding(get: { model.options[keyPath: key] }, set: {
            var options = model.options
            options[keyPath: key] = $0
            model.options = options
        })
    }

    private func mappingSelection(_ source: Int) -> Binding<Int> {
        Binding(get: {
            guard model.mapping.indices.contains(source), let name = model.mapping[source] else { return -1 }
            return model.columns.firstIndex { Data($0.name.utf8) == Data(name.utf8) } ?? -1
        }, set: { target in
            model.setMapping(source: source, target: model.columns.indices.contains(target) ? model.columns[target].name : nil)
        })
    }

    private func selectedTarget(_ source: Int) -> TableImportColumn? {
        guard model.mapping.indices.contains(source), let name = model.mapping[source] else { return nil }
        return model.columns.first { Data($0.name.utf8) == Data(name.utf8) }
    }

    private func chooseFile() {
        guard model.canEdit else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.message = "Choose a UTF-8 CSV or TSV file no larger than 8 MiB."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.loadFile(url: url) }
    }
}
