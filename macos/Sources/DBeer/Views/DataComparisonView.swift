import AppKit
import SwiftUI

struct DataComparisonView: View {
    @ObservedObject var model: DataComparisonModel
    let close: () -> Void
    private var encoded = SwiftUI.State(initialValue: false)
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare Table Data").font(.title2.weight(.semibold))
                Spacer()
                if model.isWorking || model.isStopping { ProgressView().controlSize(.small); Text(model.operation == "describe" ? "Reading table metadata…" : "Capturing and comparing…").font(.caption) }
                if model.isWorking { Button("Stop") { Task { await model.stop() } }.disabled(model.isStopping).accessibilityIdentifier("dataCompareStop") }
                Button("Close", action: close).keyboardShortcut(.cancelAction).accessibilityIdentifier("dataCompareClose")
            }
            Text("Source → Target · Independent read-only sessions · No common atomic snapshot across servers")
                .font(.callout).appSecondaryText().accessibilityIdentifier("dataCompareScope")
            Text("Exact typed keys match locally. Duplicate keys are ambiguous. Limited samples may differ because server ordering and collations differ. Temporary captures and comparison files share a 256 MiB budget.")
                .font(.caption).appSecondaryText().fixedSize(horizontal: false, vertical: true)
            Divider()
            if let summary = model.summary { results(summary) } else { configuration }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled).accessibilityIdentifier("dataCompareError") }
            Divider()
            HStack {
                if model.summary != nil {
                    Button("New Comparison") { Task { await model.reset() } }.accessibilityIdentifier("dataCompareReset")
                } else {
                    Button("Read Table Metadata") { Task { await model.readMetadata() } }.disabled(!model.canDescribe).accessibilityIdentifier("dataCompareDescribe")
                    Text("Metadata is rechecked in each new capture session.").font(.caption).appSecondaryText()
                }
                Spacer()
                Text("Closing removes temporary data. No database writes.").font(.caption).appSecondaryText()
                if model.summary == nil {
                    Button("Compare") { Task { await model.compare() } }.keyboardShortcut(.defaultAction).disabled(!model.canCompare).accessibilityIdentifier("dataCompareStart")
                }
            }
        }.padding(20).frame(minWidth: 980, idealWidth: 1160, minHeight: 660, idealHeight: 800)
            .background(AppPalette.panel).tint(AppPalette.accent).focusEffectDisabled().interactiveDismissDisabled(model.isWorking || model.isStopping)
            .accessibilityElement(children: .contain).accessibilityIdentifier("dataComparison")
    }
    private var configuration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 20) {
                    side("Source", id: $model.sourceID, table: $model.sourceTable, limit: $model.sourceLimit)
                    Image(systemName: "arrow.right").padding(.top, 24).accessibilityHidden(true)
                    side("Target", id: $model.targetID, table: $model.targetTable, limit: $model.targetLimit)
                }.disabled(model.isWorking || model.isStopping)
                if let descriptors = model.descriptors, model.metadataMatches {
                    GroupBox("Column mapping · Select at least one key explicitly") {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(model.mappings.indices, id: \.self) { i in
                                let column = descriptors.source.columns[i]
                                HStack {
                                    Toggle("Key", isOn: $model.mappings[i].key).toggleStyle(.checkbox).disabled(model.mappings[i].target == nil)
                                        .accessibilityIdentifier("dataCompareKey-\(i)")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(column.name + (column.primaryKey > 0 ? " · PK \(column.primaryKey)" : "")).font(.callout)
                                        Text(column.typeLabel).font(.caption2).appSecondaryText().lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.right").accessibilityHidden(true)
                                    Picker("Target for \(column.name)", selection: Binding<Int?>(get: {
                                        descriptors.target.columns.first { candidate in model.mappings[i].target.map { value in value.utf8.elementsEqual(candidate.name.utf8) } == true }?.index
                                    }, set: { index in model.mappings[i].target = index.map { descriptors.target.columns[$0].name } })) {
                                        Text("Exclude from comparison").tag(Int?.none)
                                        ForEach(descriptors.target.columns, id: \.index) { target in Text(target.name).tag(Optional(target.index)) }
                                    }.labelsHidden().frame(maxWidth: .infinity).accessibilityIdentifier("dataCompareMapping-\(i)")
                                }
                            }
                        }.padding(8)
                    }.disabled(model.isWorking || model.isStopping)
                    HStack(alignment: .top, spacing: 16) {
                        filters("Source filters", values: $model.sourceFilters, columns: descriptors.source.columns)
                        filters("Target filters", values: $model.targetFilters, columns: descriptors.target.columns)
                    }.disabled(model.isWorking || model.isStopping)
                    Picker("Temporary originals", selection: $model.originals) {
                        Text("All columns (recommended)").tag("allColumns")
                        Text("Mapped columns only").tag("selectedColumns")
                    }.disabled(model.isWorking || model.isStopping).accessibilityIdentifier("dataCompareOriginals")
                    Text(model.originals == "allColumns" ? "Excluded columns are retained in this private temporary capture, including generated, identity and invisible columns. Only mapped columns are compared." : "Excluded columns are not captured. Full-original data planning will be unavailable.")
                        .font(.caption).appSecondaryText().accessibilityIdentifier("dataCompareOriginalsNotice")
                } else if model.descriptors != nil {
                    Text("Connection or table changed. Read table metadata again.").font(.callout).foregroundStyle(.orange)
                } else {
                    Text("Choose saved connections and exact table names, then explicitly read metadata. Opening or editing this configuration never connects.")
                        .font(.callout).appSecondaryText()
                }
            }.padding(2)
        }
    }
    private func side(_ title: String, id: Binding<UUID?>, table: Binding<DataComparisonTable>, limit: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(title, selection: id) {
                Text("Choose connection").tag(UUID?.none)
                ForEach(model.profiles) { profile in Text("\(profile.name) · \(profile.engine.displayName)").tag(Optional(profile.id)) }
            }.accessibilityIdentifier("dataCompare\(title)")
            if let profile = model.profiles.first(where: { $0.id == id.wrappedValue }) {
                Text("\(profile.host):\(profile.port) · \(profile.database) · \(profile.policy.label)").font(.caption).appSecondaryText()
            }
            HStack { TextField("Schema / database", text: table.schema); TextField("Table", text: table.name) }.textFieldStyle(.roundedBorder)
            HStack {
                Text("Read limit").font(.caption)
                TextField("10000", value: limit, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 100)
                    .accessibilityIdentifier("dataCompare\(title)Limit")
                Text("1–100,000 rows").font(.caption).appSecondaryText()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func filters(_ title: String, values: Binding<[DataComparisonFilter]>, columns: [DataComparisonColumn]) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(values.wrappedValue.indices, id: \.self) { i in
                    HStack {
                        Picker("Column", selection: values[i].column) { ForEach(columns, id: \.index) { Text($0.name).tag($0.name) } }.labelsHidden()
                        Picker("Operator", selection: values[i].operator) {
                            ForEach(["eq", "ne", "lt", "lte", "gt", "gte", "contains", "isNull", "isNotNull"], id: \.self) {
                                Text(["eq": "=", "ne": "≠", "lt": "<", "lte": "≤", "gt": ">", "gte": "≥", "contains": "Contains", "isNull": "IS NULL", "isNotNull": "IS NOT NULL"][$0] ?? $0).tag($0)
                            }
                        }.labelsHidden().frame(width: 96).onChange(of: values[i].operator.wrappedValue) { _, op in
                            values[i].value.wrappedValue = ["isNull", "isNotNull"].contains(op) ? nil : values[i].value.wrappedValue ?? ""
                        }
                        if !["isNull", "isNotNull"].contains(values[i].operator.wrappedValue) {
                            TextField("Exact value / Base64", text: Binding(get: { values[i].value.wrappedValue ?? "" }, set: { values[i].value.wrappedValue = $0 })).textFieldStyle(.roundedBorder)
                        }
                        ControlIconButton(systemName: "minus.circle") { values.wrappedValue.remove(at: i) }.accessibilityLabel("Remove filter")
                    }
                }
                Button("Add Filter") { if let column = columns.first { values.wrappedValue.append(.init(column: column.name, operator: "eq", value: "")) } }.disabled(values.wrappedValue.count >= 32)
            }.padding(6)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func results(_ summary: DataComparisonSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.sourceProfile?.name ?? "Source") → \(model.targetProfile?.name ?? "Target")").font(.headline).accessibilityIdentifier("dataCompareDirection")
            if let source = model.sourceProfile, let target = model.targetProfile {
                Text("Source: \(source.host):\(source.port) · \(source.database) · \(source.policy.label)\nTarget: \(target.host):\(target.port) · \(target.database) · \(target.policy.label)")
                    .font(.caption).appSecondaryText().textSelection(.enabled)
            }
            Text(summary.comparison.fullEquality ? "Mapped table data matches for the captured filtered scope" : !summary.comparison.complete ? "Partial capture — only observed differences are shown" : summary.comparison.reportRows == 0 ? "No differences observed in the loaded mapped rows" : "Data differences found")
                .font(.headline).foregroundStyle(summary.comparison.fullEquality ? .green : .orange).accessibilityIdentifier("dataCompareConclusion")
            Text("\(summary.comparison.equalRows) equal · \(summary.comparison.deletedRows) source only · \(summary.comparison.addedRows) target only · \(summary.comparison.changedRows) changed · \(summary.comparison.ambiguousRows) ambiguous · \(summary.comparison.uncertainRows) uncertain")
                .font(.caption).monospacedDigit().accessibilityIdentifier("dataCompareCounts")
            DisclosureGroup("Capture intervals, limits and excluded columns") {
                VStack(alignment: .leading, spacing: 6) { context("Source", summary.source); context("Target", summary.target)
                    Text("Source filters: \(filterDescription(model.capturedSourceFilters))\nTarget filters: \(filterDescription(model.capturedTargetFilters))").font(.caption)
                    Text("Source-only/target-only rows in partial captures are observations, not confirmed inserts or deletions. No database writes or synchronization SQL are generated.").font(.caption).appSecondaryText()
                }.textSelection(.enabled)
            }
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        if model.page?.rows.isEmpty == true { Text("No differing rows in this loaded scope.").font(.callout).appSecondaryText() }
                        ForEach(model.page?.rows ?? []) { row in
                            Button { model.selectRow(row) } label: {
                                HStack { Text("\(row.index + 1) · \(rowTitle(row, complete: summary.comparison.complete))").font(.callout); Spacer() }
                                    .padding(8).background(model.selectedRow?.index == row.index ? AppPalette.accent.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain).accessibilityIdentifier("dataCompareRow-\(row.index)")
                        }
                    }
                }.frame(minWidth: 160, idealWidth: 180, maxWidth: 240)
                ScrollView {
                    if let row = model.selectedRow {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(rowTitle(row, complete: summary.comparison.complete)).font(.headline)
                            ForEach(row.cells, id: \.mapping) { cell in
                                let mapping = model.capturedMappings[cell.mapping]
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(mapping.source) → \(mapping.target)\(mapping.key ? " · Key" : "")").font(.callout.weight(.medium))
                                    HStack(alignment: .top) {
                                        preview("Source", value: cell.left, encoding: model.descriptors?.source.columns.first { $0.name.utf8.elementsEqual(mapping.source.utf8) }?.encoding)
                                        preview("Target", value: cell.right, encoding: model.descriptors?.target.columns.first { $0.name.utf8.elementsEqual(mapping.target.utf8) }?.encoding)
                                    }
                                    if cell.uncertain { Text("Type identity or row match is uncertain.").font(.caption).foregroundStyle(.orange) }
                                }.padding(8).background(AppPalette.background, in: RoundedRectangle(cornerRadius: 5))
                            }
                            HStack {
                                Button("Previous Columns") { Task { await model.cells(next: false) } }.disabled(!model.canPreviousCells)
                                Button("Next Columns") { Task { await model.cells(next: true) } }.disabled(!row.cellsTruncated || model.isLoadingPage).accessibilityIdentifier("dataCompareNextColumns")
                            }
                        }
                    }
                }.frame(minWidth: 340, maxWidth: .infinity)
                valueInspector.frame(minWidth: 260, idealWidth: 280, maxWidth: 400)
            }.accessibilityIdentifier("dataCompareReport")
            HStack {
                Button("Previous") { Task { await model.previousPage() } }.disabled(!model.canPrevious)
                Text("\((model.page?.offset ?? 0) + (model.page?.rows.isEmpty == true ? 0 : 1))–\(model.page?.nextOffset ?? 0) of \(summary.comparison.reportRows)").font(.caption).monospacedDigit()
                Button("Next") { Task { await model.nextPage() } }.disabled(!model.canNext)
                if model.isLoadingPage { ProgressView().controlSize(.small) }
            }
        }
    }
    private func context(_ title: String, _ value: DataComparisonCaptureContext) -> some View {
        Text("\(title): \(value.table.title) · \(value.storedRows) stored · limit \(value.readLimit) · \(value.excludedColumns) columns excluded\n\(value.partialReasons.isEmpty ? "Filtered scope fully read" : "Partial: \(value.partialReasons.joined(separator: ", ")); observed at least \(value.observedAtLeast), total unknown")\n\(value.startedAt) → \(value.finishedAt) · \(value.consistency) · \(value.rendering)\n\(value.fullOriginals ? "All original columns retained" : "Only mapped columns retained")").font(.caption)
    }
    private func rowTitle(_ row: ResultComparisonRow, complete: Bool) -> String {
        switch row.kind { case "deleted": complete ? "Source only" : "Observed source only"; case "added": complete ? "Target only" : "Observed target only"; case "changed": "Changed"; case "ambiguous": "Ambiguous key"; default: "Uncertain match" }
    }
    private func filterDescription(_ filters: [DataComparisonFilter]) -> String {
        filters.isEmpty ? "None" : filters.map { "\($0.column) \($0.operator) \($0.value ?? "")" }.joined(separator: "; ")
    }
    private func preview(_ title: String, value: ResultComparisonValuePreview?, encoding: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium))
            if let value {
                Text(value.display).font(.system(.caption, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                Button("Inspect Value") { Task { await model.inspect(value, title: title, encoding: encoding) } }.font(.caption)
                    .accessibilityIdentifier("dataCompareInspect-\(value.valueRef)")
            } else { Text("No observed row").font(.caption).appSecondaryText() }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var valueInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exact Captured Value").font(.headline)
            if let chunk = model.valueChunk {
                Text(model.valueTitle).font(.callout)
                if model.valueEncoding == "base64" { Text("Binary value · Base64 representation").font(.caption).appSecondaryText().accessibilityIdentifier("dataCompareBinaryValue") }
                Text(chunk.isNull ? "SQL NULL" : chunk.totalBytes == 0 ? "Empty value" : "Bytes \(chunk.offset)–\(chunk.nextOffset) of \(chunk.totalBytes)").font(.caption).monospacedDigit()
                Toggle("Chunk as Base64", isOn: encoded.projectedValue).toggleStyle(.checkbox).font(.caption)
                ScrollView([.horizontal, .vertical]) {
                    Text(chunk.isNull ? "SQL NULL" : encoded.wrappedValue ? chunk.dataBase64 : model.valueText?.text ?? "Use Base64 to inspect this chunk.")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).accessibilityIdentifier("dataCompareExactValue")
                Text("Binary columns retain their Base64 representation. Adjacent chunks overlap by up to 3 bytes for UTF-8.").font(.caption2).appSecondaryText()
                HStack {
                    ControlIconButton(systemName: "chevron.left") { Task { await model.value(next: false) } }.disabled(!model.canPreviousValue).accessibilityLabel("Previous value chunk")
                    ControlIconButton(systemName: "chevron.right") { Task { await model.value(next: true) } }.disabled(!chunk.hasMore || model.isLoadingValue).accessibilityLabel("Next value chunk").accessibilityIdentifier("dataCompareNextValue")
                }
            } else { Text("Select a source or target preview. NULL, empty text, literal NULL, exact numeric strings and Base64 binary stay distinct.").font(.callout).appSecondaryText(); Spacer() }
        }.padding(.horizontal, 8)
    }
}
