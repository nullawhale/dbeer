import AppKit
import SwiftUI

struct DataComparisonView: View {
    @ObservedObject var model: DataComparisonModel
    let close: () -> Void
    private var selectedColumnState = SwiftUI.State<Int?>(initialValue: nil)
    private var selectedColumn: Int? {
        get { selectedColumnState.wrappedValue }
        nonmutating set { selectedColumnState.wrappedValue = newValue }
    }
    private var showUnchangedState = SwiftUI.State<Bool>(initialValue: false)
    private var showUnchanged: Bool {
        get { showUnchangedState.wrappedValue }
        nonmutating set { showUnchangedState.wrappedValue = newValue }
    }
    private var showExactValueState = SwiftUI.State<Bool>(initialValue: false)
    private var showExactValue: Bool {
        get { showExactValueState.wrappedValue }
        nonmutating set { showExactValueState.wrappedValue = newValue }
    }
    private var encodedState = SwiftUI.State<Bool>(initialValue: false)
    private var advancedExpanded = SwiftUI.State(initialValue: false)
    private var encoded: Bool {
        get { encodedState.wrappedValue }
        nonmutating set { encodedState.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            if let summary = model.summary {
                results(summary)
            } else {
                configuration.padding(20)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .padding(.horizontal, 20).padding(.bottom, 12).accessibilityIdentifier("dataCompareError")
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(minWidth: 980, idealWidth: 1160, minHeight: 660, idealHeight: 800)
        .background(AppPalette.panel).tint(AppPalette.accent).focusEffectDisabled()
        .interactiveDismissDisabled(model.isWorking || model.isStopping)
        .accessibilityElement(children: .contain).accessibilityIdentifier("dataComparison")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compare Table Data").font(.title2.weight(.semibold))
                Label("Read-only comparison", systemImage: "lock")
                    .font(.caption).appSecondaryText().accessibilityIdentifier("dataCompareScope")
            }
            Spacer()
            if model.isWorking || model.isStopping {
                ProgressView().controlSize(.small)
                Text(model.isStopping ? "Stopping…" : model.operation == "describe" ? "Loading columns…" : "Comparing…").font(.callout).appSecondaryText()
                if model.isWorking {
                    Button("Stop") { Task { await model.stop() } }.disabled(model.isStopping)
                        .controlHover().accessibilityIdentifier("dataCompareStop")
                }
            }
            Button("Close", action: close).keyboardShortcut(.cancelAction).controlHover()
                .accessibilityIdentifier("dataCompareClose")
        }
    }

    private var configuration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 20) {
                    side("Source", id: $model.sourceID, table: $model.sourceTable)
                    Image(systemName: "arrow.right").appSecondaryText().padding(.top, 38).accessibilityHidden(true)
                    side("Target", id: $model.targetID, table: $model.targetTable)
                }.disabled(model.isWorking || model.isStopping)
                if let source = model.profiles.first(where: { $0.id == model.sourceID }),
                   let target = model.profiles.first(where: { $0.id == model.targetID }), source.engine != target.engine {
                    Label("Choose two PostgreSQL or two MySQL connections.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let descriptors = model.descriptors, model.metadataMatches {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Match columns").font(.headline)
                            Spacer()
                            Text("Select at least one key to identify matching rows.").font(.caption).appSecondaryText()
                        }
                        HStack {
                            Text("Key").frame(width: 44, alignment: .leading)
                            Text("Source column").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Target column").frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.caption).appSecondaryText().padding(.horizontal, 10)
                        Divider()
                        ForEach(model.mappings.indices, id: \.self) { i in
                            mappingRow(i, descriptors: descriptors)
                        }
                    }.padding(12).background(AppPalette.background, in: RoundedRectangle(cornerRadius: 8))
                        .disabled(model.isWorking || model.isStopping)
                } else {
                    Label(model.descriptors == nil ? "Choose two tables, then load their columns." : "Table selection changed. Load columns again.",
                          systemImage: model.descriptors == nil ? "tablecells" : "arrow.clockwise")
                        .font(.callout).appSecondaryText()
                }
                advancedOptions.disabled(model.isWorking || model.isStopping)
            }.padding(2)
        }
    }

    private func side(_ title: String, id: Binding<UUID?>, table: Binding<DataComparisonTable>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Picker("\(title) connection", selection: id) {
                Text("Choose connection").tag(UUID?.none)
                ForEach(model.profiles) { profile in
                    Text("\(profile.name) · \(profile.engine.displayName)").tag(Optional(profile.id))
                }
            }.labelsHidden().accessibilityIdentifier("dataCompare\(title)")
            HStack {
                TextField("Schema / database", text: table.schema)
                TextField("Table", text: table.name)
            }.textFieldStyle(.roundedBorder)
            if let profile = model.profiles.first(where: { $0.id == id.wrappedValue }) {
                Text("\(profile.host):\(profile.port) · \(profile.database) · \(profile.policy.label)")
                    .font(.caption).appSecondaryText().lineLimit(1).help("\(profile.host):\(profile.port) · \(profile.database) · \(profile.policy.label)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mappingRow(_ i: Int, descriptors: DataComparisonDescriptors) -> some View {
        let column = descriptors.source.columns[i]
        return HStack(spacing: 12) {
            Toggle("Key for \(column.name)", isOn: $model.mappings[i].key).labelsHidden().toggleStyle(.checkbox)
                .disabled(model.mappings[i].target == nil).frame(width: 44, alignment: .leading)
                .accessibilityIdentifier("dataCompareKey-\(i)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(column.name).font(.system(.callout, design: .monospaced))
                    if column.primaryKey > 0 { Image(systemName: "key.fill").font(.caption2).appSecondaryText().help("Primary key") }
                }
                Text(column.typeLabel).font(.caption).appSecondaryText().lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Picker("Target for \(column.name)", selection: Binding<Int?>(get: {
                descriptors.target.columns.first { candidate in
                    model.mappings[i].target.map { $0.utf8.elementsEqual(candidate.name.utf8) } == true
                }?.index
            }, set: { index in model.mappings[i].target = index.map { descriptors.target.columns[$0].name } })) {
                Text("Exclude").tag(Int?.none)
                ForEach(descriptors.target.columns, id: \.index) { Text($0.name).tag(Optional($0.index)) }
            }.labelsHidden().frame(maxWidth: .infinity).accessibilityIdentifier("dataCompareMapping-\(i)")
        }.padding(.horizontal, 10).padding(.vertical, 3)
    }

    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                advancedExpanded.wrappedValue.toggle()
            } label: {
                Label("Advanced options", systemImage: advancedExpanded.wrappedValue ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain).controlHover().accessibilityIdentifier("dataCompareAdvanced")
            .accessibilityValue(advancedExpanded.wrappedValue ? "Expanded" : "Collapsed")
            if advancedExpanded.wrappedValue {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 20) {
                    readLimit("Source", value: $model.sourceLimit)
                    readLimit("Target", value: $model.targetLimit)
                }
                if let descriptors = model.descriptors, model.metadataMatches {
                    HStack(alignment: .top, spacing: 16) {
                        filters("Source filters", values: $model.sourceFilters, columns: descriptors.source.columns)
                        filters("Target filters", values: $model.targetFilters, columns: descriptors.target.columns)
                    }
                }
                Picker("Temporary originals", selection: $model.originals) {
                    Text("All columns").tag("allColumns")
                    Text("Compared columns only").tag("selectedColumns")
                }.accessibilityIdentifier("dataCompareOriginals")
                Text(model.originals == "allColumns" ? "Retain all original columns in the temporary capture." : "Excluded columns are not captured; full-original planning is unavailable.")
                    .font(.caption).appSecondaryText().accessibilityIdentifier("dataCompareOriginalsNotice")
                Text("Captures use independent read-only sessions, with no common snapshot across servers. Keys are matched by exact type and value; duplicate keys are ambiguous. Samples may differ because server ordering and collations differ. Temporary files share a 256 MiB budget and are removed on close. No database writes or synchronization SQL.")
                    .font(.caption).appSecondaryText().fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 10)
            }
        }
    }

    private func readLimit(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text("\(title) row limit").font(.callout)
            TextField("10000", value: value, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 100)
                .accessibilityIdentifier("dataCompare\(title)Limit")
            Text("1–100,000").font(.caption).appSecondaryText()
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
                            TextField("Value / Base64", text: Binding(get: { values[i].value.wrappedValue ?? "" }, set: { values[i].value.wrappedValue = $0 })).textFieldStyle(.roundedBorder)
                        }
                        ControlIconButton(systemName: "minus.circle") { values.wrappedValue.remove(at: i) }.accessibilityLabel("Remove filter")
                    }
                }
                Button("Add Filter") { if let column = columns.first { values.wrappedValue.append(.init(column: column.name, operator: "eq", value: "")) } }
                    .controlHover().disabled(values.wrappedValue.count >= 32)
            }.padding(6)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack {
            if model.summary != nil {
                Button("New Comparison") { selectedColumn = nil; showExactValue = false; Task { await model.reset() } }
                    .controlHover().accessibilityIdentifier("dataCompareReset")
            } else if model.metadataMatches {
                Text("\(model.requestedMappings.count) columns · \(model.requestedMappings.filter(\.key).count) keys")
                    .font(.caption).appSecondaryText()
            }
            Spacer()
            if model.summary == nil {
                if model.metadataMatches {
                    Button("Compare") { Task { await model.compare() } }.keyboardShortcut(.defaultAction)
                        .disabled(!model.canCompare).controlHover().accessibilityIdentifier("dataCompareStart")
                } else {
                    Button("Load Columns") { Task { await model.readMetadata() } }.keyboardShortcut(.defaultAction)
                        .disabled(!model.canDescribe).controlHover().accessibilityIdentifier("dataCompareDescribe")
                }
            }
        }
    }

    private func results(_ summary: DataComparisonSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            resultSummary(summary).padding(.horizontal, 20).padding(.top, 16)
            HSplitView {
                rowList(summary).frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
                VStack(alignment: .leading, spacing: 0) {
                    if let row = model.selectedRow {
                        columnResults(row)
                        Divider()
                        cellDiff(row).frame(minHeight: 180, maxHeight: .infinity)
                    } else if model.isLoadingPage {
                        ProgressView("Loading rows…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if summary.comparison.reportRows == 0 {
                        ContentUnavailableView("No differences", systemImage: "checkmark.circle", description: Text("The captured rows have no reported differences."))
                    } else {
                        ContentUnavailableView("No rows loaded", systemImage: "tablecells", description: Text("Load a report page to inspect the differences."))
                    }
                }.frame(minWidth: 580, maxWidth: .infinity)
            }.accessibilityIdentifier("dataCompareReport")
            HStack {
                Button("Previous") { Task { await model.previousPage() } }.disabled(!model.canPrevious).controlHover()
                Text("\((model.page?.offset ?? 0) + (model.page?.rows.isEmpty == true ? 0 : 1))–\(model.page?.nextOffset ?? 0) of \(summary.comparison.reportRows)")
                    .font(.caption).monospacedDigit().appSecondaryText()
                Button("Next") { Task { await model.nextPage() } }.disabled(!model.canNext).controlHover()
                if model.isLoadingPage { ProgressView().controlSize(.small) }
                Spacer()
            }.padding(.horizontal, 20).padding(.bottom, 12)
        }
    }

    private func resultSummary(_ summary: DataComparisonSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.sourceProfile?.name ?? "Source") → \(model.targetProfile?.name ?? "Target")")
                .font(.headline).accessibilityIdentifier("dataCompareDirection")
            Text(summary.comparison.fullEquality ? "Table data matches in the captured scope" : !summary.comparison.complete ? "Partial comparison — only captured rows were compared" : summary.comparison.reportRows == 0 ? "No differences in the compared columns" : summary.comparison.changedRows + summary.comparison.deletedRows + summary.comparison.addedRows == 0 ? "Rows need review" : "Data differences found")
                .font(.callout.weight(.medium)).foregroundStyle(summary.comparison.fullEquality ? .green : .orange)
                .accessibilityIdentifier("dataCompareConclusion")
            HStack(spacing: 14) {
                Label("\(summary.comparison.changedRows) changed", systemImage: "pencil.circle").foregroundStyle(.orange)
                Label("\(summary.comparison.deletedRows) source only", systemImage: "minus.circle").foregroundStyle(.red)
                Label("\(summary.comparison.addedRows) target only", systemImage: "plus.circle").foregroundStyle(.green)
                Text("\(summary.comparison.equalRows) equal").appSecondaryText()
                if summary.comparison.ambiguousRows + summary.comparison.uncertainRows > 0 {
                    Label("\(summary.comparison.ambiguousRows + summary.comparison.uncertainRows) need review", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }.font(.caption).monospacedDigit().accessibilityIdentifier("dataCompareCounts")
            DisclosureGroup("Comparison details") {
                VStack(alignment: .leading, spacing: 6) {
                    context("Source", summary.source); context("Target", summary.target)
                    Text("Source filters: \(filterDescription(model.capturedSourceFilters))\nTarget filters: \(filterDescription(model.capturedTargetFilters))")
                    Text("Source-only and target-only rows in partial captures are observations, not confirmed inserts or deletions. No database writes.")
                }.font(.caption).appSecondaryText().textSelection(.enabled).padding(.top, 6)
            }.font(.caption)
        }
    }

    private func rowList(_ summary: DataComparisonSummary) -> some View {
        List {
            ForEach(model.page?.rows ?? []) { row in
                Button {
                    guard model.selectedRow?.index != row.index else { return }
                    selectedColumn = nil; showExactValue = false; model.selectRow(row)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rowKey(row)).font(.system(.callout, design: .monospaced)).lineLimit(1)
                        Label(rowTitle(row, complete: summary.comparison.complete), systemImage: rowIcon(row))
                            .font(.caption).foregroundStyle(rowColor(row))
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        .background(model.selectedRow?.index == row.index ? AppPalette.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("dataCompareRow-\(row.index)")
            }
        }.listStyle(.sidebar).disabled(model.isLoadingPage)
    }

    private func columnResults(_ row: ResultComparisonRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(rowKey(row)).font(.headline).lineLimit(1)
                Spacer()
                Toggle("Unchanged columns", isOn: showUnchangedState.projectedValue).toggleStyle(.checkbox).font(.caption)
            }
            HStack(spacing: 12) {
                Text("Column").frame(width: 160, alignment: .leading)
                Text("Source").frame(maxWidth: .infinity, alignment: .leading)
                Text("Target").frame(maxWidth: .infinity, alignment: .leading)
            }.font(.caption.weight(.medium)).appSecondaryText().padding(.horizontal, 8)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(row.cells.filter { showUnchanged || $0.different || $0.uncertain || $0.left == nil || $0.right == nil }, id: \.mapping) { cell in
                        cellRow(cell)
                    }
                }
            }.frame(minHeight: 80, idealHeight: 150, maxHeight: 210)
            if row.cellsTruncated || model.canPreviousCells {
                HStack {
                    Button("Previous Columns") { selectedColumn = nil; Task { await model.cells(next: false) } }.disabled(!model.canPreviousCells)
                    Button("Next Columns") { selectedColumn = nil; Task { await model.cells(next: true) } }.disabled(!row.cellsTruncated || model.isLoadingPage)
                        .accessibilityIdentifier("dataCompareNextColumns")
                }.font(.caption)
            }
        }.padding(12)
    }

    private func cellRow(_ cell: ResultComparisonCell) -> some View {
        let mapping = model.capturedMappings[cell.mapping]
        let active = activeCell?.mapping == cell.mapping
        return Button { selectedColumn = cell.mapping; showExactValue = false } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mapping.source).lineLimit(1)
                    if mapping.source != mapping.target { Text("→ \(mapping.target)").font(.caption).appSecondaryText().lineLimit(1) }
                    if mapping.key { Label("Key", systemImage: "key.fill").font(.caption2).appSecondaryText() }
                }.frame(width: 160, alignment: .leading)
                cellPreview(cell.left).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4).background(cell.different || cell.right == nil ? Color.red.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 3))
                cellPreview(cell.right).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4).background(cell.different || cell.left == nil ? Color.green.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 3))
                if cell.uncertain { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("Type identity or row match is uncertain") }
            }.font(.system(.callout, design: .monospaced)).padding(8)
                .background(active ? AppPalette.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("dataCompareCell-\(cell.mapping)")
    }

    private func cellPreview(_ preview: ResultComparisonValuePreview?) -> some View {
        Text(preview?.display ?? "No observed row").lineLimit(2).help(preview?.display ?? "No observed row")
    }

    private var activeCell: ResultComparisonCell? {
        guard let row = model.selectedRow else { return nil }
        if let selectedColumn, let cell = row.cells.first(where: { $0.mapping == selectedColumn }) { return cell }
        return row.cells.first { $0.different || $0.uncertain || $0.left == nil || $0.right == nil } ?? row.cells.first
    }

    private func cellDiff(_ row: ResultComparisonRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cell = activeCell {
                HStack {
                    Text(model.capturedMappings[cell.mapping].source).font(.headline)
                    Spacer()
                    Button(showExactValue ? "Show Diff" : "Inspect Exact Value") { showExactValue.toggle() }
                        .controlHover().font(.caption).accessibilityIdentifier("dataCompareExactToggle")
                }.padding(.horizontal, 12).padding(.top, 10)
                if cell.uncertain || row.kind == "ambiguous" {
                    Label(row.kind == "ambiguous" ? "Duplicate key — this row pairing is ambiguous." : "Type identity or row match is uncertain.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).padding(.horizontal, 12)
                }
                if showExactValue {
                    exactValue(cell)
                } else if model.isLoadingDiff {
                    ProgressView("Loading diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let diff = model.diff {
                    ComparisonDiffView(diff: diff, sourceTitle: cellTypeTitle(cell, source: true), targetTitle: cellTypeTitle(cell, source: false))
                } else {
                    Text(model.diffError ?? "Select a column to compare its values.").font(.callout).appSecondaryText()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.task(id: "\(row.index):\(activeCell?.mapping ?? -1):\(model.isLoadingPage)") {
            if !model.isLoadingPage, let cell = activeCell { await model.inspectCell(cell) }
        }
    }

    private func exactValue(_ cell: ResultComparisonCell) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let value = cell.left {
                    Button("Source Value") { inspect(value, cell: cell, source: true) }.accessibilityIdentifier("dataCompareInspect-\(value.valueRef)")
                }
                if let value = cell.right {
                    Button("Target Value") { inspect(value, cell: cell, source: false) }.accessibilityIdentifier("dataCompareInspect-\(value.valueRef)")
                }
                Spacer()
                Toggle("Base64", isOn: encodedState.projectedValue).toggleStyle(.checkbox).font(.caption)
            }
            if let chunk = model.valueChunk,
               chunk.valueRef == cell.left?.valueRef || chunk.valueRef == cell.right?.valueRef {
                Text("\(model.valueTitle) · \(chunk.isNull ? "SQL NULL" : chunk.totalBytes == 0 ? "Empty value" : "Bytes \(chunk.offset)–\(chunk.nextOffset) of \(chunk.totalBytes)")")
                    .font(.caption).appSecondaryText()
                ScrollView([.horizontal, .vertical]) {
                    Text(chunk.isNull ? "SQL NULL" : encoded ? chunk.dataBase64 : model.valueText?.text ?? "Use Base64 to inspect this value.")
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }.accessibilityIdentifier("dataCompareExactValue")
                HStack {
                    Button("Previous") { Task { await model.value(next: false) } }.disabled(!model.canPreviousValue)
                    Button("Next") { Task { await model.value(next: true) } }.disabled(!chunk.hasMore || model.isLoadingValue)
                        .accessibilityIdentifier("dataCompareNextValue")
                    if model.valueEncoding == "base64" { Text("Binary · Base64").font(.caption).appSecondaryText().accessibilityIdentifier("dataCompareBinaryValue") }
                }
            } else {
                Text("Choose a source or target value.").font(.callout).appSecondaryText()
                Spacer()
            }
        }.padding(12)
    }

    private func inspect(_ value: ResultComparisonValuePreview, cell: ResultComparisonCell, source: Bool) {
        let mapping = model.capturedMappings[cell.mapping]
        let columns = source ? model.descriptors?.source.columns : model.descriptors?.target.columns
        let name = source ? mapping.source : mapping.target
        let encoding = columns?.first { $0.name.utf8.elementsEqual(name.utf8) }?.encoding
        Task { await model.inspect(value, title: source ? "Source" : "Target", encoding: encoding) }
    }

    private func cellTypeTitle(_ cell: ResultComparisonCell, source: Bool) -> String {
        let mapping = model.capturedMappings[cell.mapping]
        let columns = source ? model.descriptors?.source.columns : model.descriptors?.target.columns
        let name = source ? mapping.source : mapping.target
        let title = source ? "Source" : "Target"
        guard let type = columns?.first(where: { $0.name.utf8.elementsEqual(name.utf8) })?.typeLabel else { return title }
        return "\(title) · \(type)"
    }

    private func rowKey(_ row: ResultComparisonRow) -> String {
        let keys = row.cells.filter { model.capturedMappings[$0.mapping].key }.map { cell in
            "\(model.capturedMappings[cell.mapping].source) = \((cell.left ?? cell.right)?.display ?? "?")"
        }
        return keys.isEmpty ? "Row \(row.index + 1)" : keys.joined(separator: ", ")
    }
    private func rowIcon(_ row: ResultComparisonRow) -> String {
        switch row.kind { case "deleted": "minus.circle"; case "added": "plus.circle"; case "changed": "pencil.circle"; default: "exclamationmark.triangle" }
    }
    private func rowColor(_ row: ResultComparisonRow) -> Color {
        switch row.kind { case "deleted": .red; case "added": .green; default: .orange }
    }
    private func rowTitle(_ row: ResultComparisonRow, complete: Bool) -> String {
        switch row.kind { case "deleted": complete ? "Source only" : "Observed source only"; case "added": complete ? "Target only" : "Observed target only"; case "changed": "Changed"; case "ambiguous": "Ambiguous key"; default: "Uncertain match" }
    }
    private func context(_ title: String, _ value: DataComparisonCaptureContext) -> some View {
        Text("\(title): \(value.table.title) · \(value.storedRows) rows · limit \(value.readLimit) · \(value.excludedColumns) columns excluded\n\(value.partialReasons.isEmpty ? "Filtered scope fully read" : "Partial: \(value.partialReasons.joined(separator: ", ")); observed at least \(value.observedAtLeast), total unknown")\n\(value.startedAt) → \(value.finishedAt) · \(value.consistency) · \(value.rendering)\n\(value.fullOriginals ? "All original columns retained" : "Only mapped columns retained")")
    }
    private func filterDescription(_ filters: [DataComparisonFilter]) -> String {
        filters.isEmpty ? "None" : filters.map { "\($0.column) \($0.operator) \($0.value ?? "")" }.joined(separator: "; ")
    }
}
