import AppKit
import SwiftUI

struct ResultComparisonView: View {
    @StateObject private var model: ResultComparisonModel
    @Environment(\.dismiss) private var dismiss
    private var encodedValue = SwiftUI.State(initialValue: false)

    init(model: ResultComparisonModel) { _model = StateObject(wrappedValue: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare Result Snapshots").font(.title2.weight(.semibold))
                Spacer()
                if model.isLoadingConfiguration || model.isWorking || model.isStopping {
                    ProgressView().controlSize(.small)
                }
                Text(status).font(.callout).appSecondaryText()
                    .accessibilityIdentifier("comparisonStatus")
            }
            if model.summary == nil { configuration }
            if let summary = model.summary { results(summary) }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .accessibilityIdentifier("comparisonError")
            }
            if model.summary == nil { Spacer(minLength: 0) }
            Divider()
            HStack {
                Text("Saved artifacts only · No database connection or SQL execution")
                    .font(.caption).appSecondaryText()
                Spacer()
                if model.isWorking {
                    Button("Stop") { Task { await model.stop() } }.controlHover()
                        .disabled(model.isStopping).accessibilityIdentifier("stopResultComparison")
                } else if model.summary != nil {
                    Button("New Comparison") { Task { await model.reset() } }.controlHover()
                        .accessibilityIdentifier("resetResultComparison")
                } else {
                    Button("Compare") { Task { await model.start() } }.controlHover()
                        .keyboardShortcut(.defaultAction).disabled(!model.canStart)
                        .accessibilityIdentifier("startResultComparison")
                }
                Button("Close") { Task { await model.close(); dismiss() } }.controlHover()
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("closeResultComparison")
            }
        }
        .padding(20).frame(width: 1120, height: 760)
        .tint(AppPalette.accent).focusEffectDisabled().interactiveDismissDisabled(model.isWorking || model.isStopping)
        .onDisappear { Task { await model.close() } }
        .onChange(of: model.selectedValue) { _, _ in encodedValue.wrappedValue = false }
        .accessibilityElement(children: .contain).accessibilityIdentifier("resultComparison")
    }

    private var status: String {
        if model.isStopping { return "Stopping…" }
        if model.isLoadingConfiguration { return "Reading local metadata…" }
        switch model.phase {
        case .idle: return "Choose two snapshots and matching rules"
        case .starting: return "Starting comparison…"
        case .running: return "Comparing saved results…"
        case .completed: return "Comparison complete"
        case .cancelled: return "Comparison cancelled"
        case .failed: return "Comparison failed"
        case .closed: return "Closed"
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 20) {
                snapshotPicker(left: true)
                Image(systemName: "arrow.left.arrow.right").padding(.top, 22).accessibilityHidden(true)
                snapshotPicker(left: false)
            }
            Picker("Match rows using", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                Text("Choose matching rules").tag(ResultComparisonMode?.none)
                Text("Selected key columns").tag(Optional(ResultComparisonMode.key))
                Text("Saved row order").tag(Optional(ResultComparisonMode.rowOrder))
            }
            .frame(maxWidth: 540, alignment: .leading).controlHover()
            .accessibilityIdentifier("comparisonMatchingMode")
            if model.mode == .rowOrder {
                Label("Rows will be paired by their saved positions. A different sort order can change every pairing.",
                    systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .accessibilityIdentifier("comparisonRowOrderWarning")
            } else {
                Text("Duplicate keys are reported as ambiguous. Exact saved values and engine, native type and encoding are compared strictly.")
                    .font(.callout).appSecondaryText()
            }
            if model.leftManifest != nil, model.rightManifest != nil {
                HStack {
                    Text("Column mapping").font(.headline)
                    Spacer()
                    Text("Columns omitted on either side count as schema differences.").font(.caption).appSecondaryText()
                }
                Table(model.mappings) {
                    TableColumn("Left column") { mapping in
                        if let column = model.leftManifest?.columns[mapping.left] { columnDescription(column) }
                    }.width(min: 180, ideal: 250)
                    TableColumn("Right column or exclusion") { mapping in
                        Picker("Map left column \(mapping.left + 1)", selection: Binding(get: { mapping.right },
                            set: { model.setMapping(left: mapping.left, right: $0) })) {
                            Text("Exclude this left column").tag(Int?.none)
                            ForEach(model.rightManifest?.columns ?? [], id: \.index) { column in
                                Text(columnLabel(column)).tag(Optional(column.index))
                            }
                        }.labelsHidden().controlHover()
                            .accessibilityIdentifier("comparisonMapping-\(mapping.left)")
                    }.width(min: 240, ideal: 420)
                    TableColumn("Key") { mapping in
                        Toggle("Key column \(mapping.left + 1)", isOn: Binding(get: { mapping.key },
                            set: { model.setKey(left: mapping.left, selected: $0) }))
                            .labelsHidden().toggleStyle(.checkbox).controlHover()
                            .disabled(model.mode != .key || mapping.right == nil)
                            .accessibilityIdentifier("comparisonKey-\(mapping.left)")
                    }.width(55)
                }
                .frame(height: 200).accessibilityIdentifier("comparisonColumnMappings")
                if !model.excludedLeft.isEmpty || !model.excludedRight.isEmpty {
                    DisclosureGroup("Excluded columns: \(model.excludedLeft.count) left, \(model.excludedRight.count) right") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(model.excludedLeft, id: \.index) { Text("Left · " + columnLabel($0)) }
                                ForEach(model.excludedRight, id: \.index) { Text("Right · " + columnLabel($0)) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 90)
                    }.font(.caption).accessibilityIdentifier("comparisonExcludedColumns")
                }
            }
            if let problem = model.configurationProblem {
                Text(problem).font(.caption).appSecondaryText().accessibilityIdentifier("comparisonConfigurationHint")
            }
        }.disabled(!model.canConfigure)
    }

    private func snapshotPicker(left: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker(left ? "Left snapshot (before)" : "Right snapshot (after)", selection: Binding(
                get: { left ? model.leftID : model.rightID }, set: { value in
                    Task { await model.configure(left: left ? value : model.leftID, right: left ? model.rightID : value) }
                })) {
                Text("Select saved snapshot").tag(UUID?.none)
                ForEach(model.snapshots) { snapshot in
                    Text("\(snapshot.title) · \(snapshot.capturedAt.formatted(.dateTime.month().day().hour().minute())) · \(snapshot.id.uuidString.prefix(8))")
                        .tag(Optional(snapshot.id))
                }
            }.controlHover().accessibilityIdentifier(left ? "comparisonLeftSnapshot" : "comparisonRightSnapshot")
            let manifest = left ? model.leftManifest : model.rightManifest
            if let manifest {
                Text("\(manifest.engine.displayName) · \(manifest.rowCount.formatted()) saved rows · \(manifest.environment.label)")
                    .font(.caption).appSecondaryText()
                if !manifest.isComplete {
                    Label("Partial snapshot: cannot establish complete-set equality.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier(left ? "comparisonLeftPartial" : "comparisonRightPartial")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func results(_ summary: ResultComparisonSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.fullEquality ? "Complete saved result sets are equal." :
                summary.complete ? "Review the differences and uncertainties below." :
                "Partial inputs: this comparison cannot establish equality of complete result sets.")
                .font(.headline).foregroundStyle(summary.fullEquality ? .primary : .secondary)
                .accessibilityIdentifier("comparisonConclusion")
            HStack(spacing: 18) {
                count("Added", summary.addedRows)
                count("Deleted", summary.deletedRows)
                count("Changed", summary.changedRows)
                count("Ambiguous", summary.ambiguousRows)
                count("Uncertain", summary.uncertainRows)
                count("Equal pairs", summary.equalRows)
                Spacer()
                Text("\(summary.leftRows) left / \(summary.rightRows) right rows").font(.caption).appSecondaryText()
            }
            if summary.ambiguousRows > 0 || summary.uncertainRows > 0 {
                Text("Duplicate-key rows are ambiguous and are never paired arbitrarily. Unresolved type identities cannot establish equality.")
                    .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("comparisonAmbiguityNotice")
            }
            if !summary.warnings.isEmpty || summary.schemaDifferenceCount > 0 {
                DisclosureGroup("\(summary.warnings.count) warnings · \(summary.schemaDifferenceCount) schema differences") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(summary.warnings.enumerated()), id: \.offset) { _, warning in Text(warning) }
                            ForEach(Array(summary.schemaDifferences.enumerated()), id: \.offset) { _, difference in
                                Text(schemaDifference(difference))
                            }
                            if summary.schemaDifferencesTruncated {
                                Text("Showing the first \(summary.schemaDifferences.count) schema differences. Review the complete positional column mapping before drawing conclusions.")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                }.font(.caption).accessibilityIdentifier("comparisonWarnings")
            }
            HSplitView {
                VStack(spacing: 8) {
                    Table(model.page?.rows ?? [], selection: Binding(get: { model.selectedRow?.index }, set: { index in
                        model.selectRow(model.page?.rows.first { $0.index == index })
                    })) {
                        TableColumn("Change") { row in Text(row.kind.capitalized) }.width(min: 70, ideal: 90)
                        TableColumn("Left row") { row in Text(row.leftIndex.map { ($0 + 1).formatted() } ?? "—") }.width(min: 55, ideal: 65)
                        TableColumn("Right row") { row in Text(row.rightIndex.map { ($0 + 1).formatted() } ?? "—") }.width(min: 55, ideal: 65)
                    }.accessibilityIdentifier("comparisonRows")
                    HStack {
                        Text("\(model.page?.offset ?? 0)–\(model.page?.nextOffset ?? 0) of \(summary.reportRows) report rows")
                            .font(.caption).appSecondaryText()
                        Spacer()
                        ControlIconButton(systemName: "chevron.left") { Task { await model.loadPreviousPage() } }
                            .disabled(!model.canLoadPrevious).accessibilityLabel("Previous comparison page")
                            .accessibilityIdentifier("comparisonPreviousPage")
                        ControlIconButton(systemName: "chevron.right") { Task { await model.loadNextPage() } }
                            .disabled(!model.canLoadNext).accessibilityLabel("Next comparison page")
                            .accessibilityIdentifier("comparisonNextPage")
                    }
                }.frame(minWidth: 280, idealWidth: 300, maxWidth: 420)
                rowDetails.frame(minWidth: 370, maxWidth: .infinity)
                valueInspector.frame(minWidth: 280, idealWidth: 310, maxWidth: .infinity)
            }
        }.frame(maxHeight: .infinity)
    }

    private var rowDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mapped values").font(.headline)
            if let row = model.selectedRow {
                Text("\(row.kind.capitalized) · Left \(row.leftIndex.map { ($0 + 1).formatted() } ?? "—") / Right \(row.rightIndex.map { ($0 + 1).formatted() } ?? "—")")
                    .font(.caption).appSecondaryText()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(row.cells, id: \.mapping) { cell in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Mapping \(cell.mapping + 1)").font(.caption.weight(.semibold))
                                    if cell.uncertain { Text("Uncertain type").font(.caption).foregroundStyle(.orange) }
                                    else if cell.different { Text("Different").font(.caption).foregroundStyle(.orange) }
                                }
                                cellPreview(cell.left, column: model.column(mapping: cell.mapping, left: true), left: true)
                                cellPreview(cell.right, column: model.column(mapping: cell.mapping, left: false), left: false)
                            }
                            Divider()
                        }
                    }.padding(.trailing, 8)
                }.accessibilityIdentifier("comparisonMappedValues")
                HStack {
                    Text("Columns \(row.cellOffset + (row.cells.isEmpty ? 0 : 1))–\(row.nextCellOffset) of \(row.totalCells)")
                        .font(.caption).appSecondaryText()
                    Spacer()
                    ControlIconButton(systemName: "chevron.left") { Task { await model.loadPreviousCells() } }
                        .disabled(!model.canLoadPreviousCells).accessibilityLabel("Previous mapped columns")
                        .accessibilityIdentifier("comparisonPreviousColumns")
                    ControlIconButton(systemName: "chevron.right") { Task { await model.loadNextCells() } }
                        .disabled(!model.canLoadNextCells).accessibilityLabel("More mapped columns")
                        .accessibilityIdentifier("comparisonNextColumns")
                }
                if row.cellsTruncated {
                    Text("This bounded preview contains part of the row. Use More mapped columns to inspect the rest.")
                        .font(.caption).appSecondaryText().accessibilityIdentifier("comparisonWideRowNotice")
                }
            } else {
                Text("Select a reported row to inspect its mapped columns.").font(.callout).appSecondaryText()
                Spacer()
            }
        }.padding(.horizontal, 8)
    }

    private func cellPreview(_ value: ResultComparisonValuePreview?, column: ResultColumn?, left: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text((left ? "Left · " : "Right · ") + (column.map(columnLabel) ?? "Absent row"))
                .font(.caption).appSecondaryText().lineLimit(2)
            if let value {
                Button {
                    Task { await model.inspect(value, title: (left ? "Left · " : "Right · ") + (column.map(columnLabel) ?? "Value"), encoding: column?.encoding) }
                } label: {
                    Text(value.display).font(.system(.caption, design: .monospaced)).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).controlHover().help("Inspect exact saved value in bounded chunks")
                    .accessibilityIdentifier("comparisonInspect-\(value.valueRef)")
                if value.truncated {
                    Text("Preview · \(value.totalBytes.formatted()) UTF-8 bytes · select to inspect exact chunks")
                        .font(.caption2).appSecondaryText()
                }
            } else { Text("No row on this side").font(.caption).appSecondaryText() }
        }
    }

    private var valueInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exact Saved Value").font(.headline)
            if let selection = model.selectedValue {
                Text(selection.title).font(.caption).textSelection(.enabled)
                Text(selection.encoding == "base64" ? "Binary value · saved Base64 representation" :
                    selection.preview.isNull ? "SQL NULL" : selection.preview.totalBytes == 0 ? "Empty text" : "Saved text · exact UTF-8 bytes")
                    .font(.caption).appSecondaryText()
                if model.isLoadingValue { ProgressView().controlSize(.small) }
                if let chunk = model.valueChunk {
                    Text("Bytes \(chunk.offset)–\(chunk.nextOffset) of \(chunk.totalBytes)")
                        .font(.caption).monospacedDigit().accessibilityIdentifier("comparisonValueOffsets")
                    Toggle("Show exact chunk as Base64", isOn: encodedValue.projectedValue)
                        .toggleStyle(.checkbox).controlHover().font(.caption)
                        .accessibilityIdentifier("comparisonValueBase64")
                    ScrollView([.horizontal, .vertical]) {
                        Text(chunk.isNull ? "SQL NULL" : encodedValue.wrappedValue ? chunk.dataBase64 :
                            model.valueTextWindow?.text ?? "This chunk is not valid UTF-8. Select Base64 to inspect its exact bytes.")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }.frame(maxHeight: .infinity).accessibilityIdentifier("comparisonExactValue")
                    if let text = model.valueTextWindow, text.leadingBytes != 0 || text.trailingBytes != 0 {
                        Text("Text shows complete characters in bytes \(chunk.offset + Int64(text.leadingBytes))–\(chunk.nextOffset - Int64(text.trailingBytes)).")
                            .font(.caption2).appSecondaryText().accessibilityIdentifier("comparisonValueUTF8Boundary")
                    }
                    Text("Chunks overlap by up to 3 bytes for readable UTF-8. Copy includes only the displayed chunk's exact bytes as Base64.")
                        .font(.caption2).appSecondaryText()
                    HStack {
                        Button("Copy Chunk as Base64") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(chunk.dataBase64, forType: .string)
                        }.controlHover().disabled(chunk.isNull || model.isLoadingValue)
                            .accessibilityIdentifier("comparisonCopyValueChunk")
                        Spacer()
                        ControlIconButton(systemName: "chevron.left") { Task { await model.loadPreviousValue() } }
                            .disabled(!model.canLoadPreviousValue).accessibilityLabel("Previous value chunk")
                            .accessibilityIdentifier("comparisonPreviousValueChunk")
                        ControlIconButton(systemName: "chevron.right") { Task { await model.loadNextValue() } }
                            .disabled(!model.canLoadNextValue).accessibilityLabel("Next value chunk")
                            .accessibilityIdentifier("comparisonNextValueChunk")
                    }
                } else { Spacer() }
                if let error = model.valueError { Text(error).font(.caption).foregroundStyle(.orange) }
            } else {
                Text("Select a left or right cell preview. Large values are read in bounded chunks; SQL NULL and empty text remain distinct.")
                    .font(.callout).appSecondaryText()
                Spacer()
            }
        }.padding(.horizontal, 8).accessibilityElement(children: .contain).accessibilityIdentifier("comparisonValueInspector")
    }

    private func count(_ label: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).appSecondaryText()
            Text(value.formatted()).font(.callout.weight(.semibold)).monospacedDigit()
        }.accessibilityElement(children: .combine).accessibilityIdentifier("comparisonCount-\(label)")
    }

    private func columnDescription(_ column: ResultColumn) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("[\(column.index + 1)] \(column.name)").lineLimit(1)
            Text(typeLabel(column)).font(.caption).appSecondaryText().lineLimit(1)
        }
    }
    private func columnLabel(_ column: ResultColumn) -> String { "[\(column.index + 1)] \(column.name) · \(typeLabel(column))" }
    private func typeLabel(_ column: ResultColumn) -> String {
        [column.engine.displayName, column.nativeType.isEmpty ? "Unknown type" : column.nativeType,
         column.encoding == "base64" ? "Base64 binary" : "Text"].joined(separator: " / ")
    }
    private func schemaDifference(_ difference: ResultComparisonSchemaDifference) -> String {
        let left = difference.left.flatMap { index in model.leftManifest?.columns.first { $0.index == index } }.map { "Left " + columnLabel($0) }
        let right = difference.right.flatMap { index in model.rightManifest?.columns.first { $0.index == index } }.map { "Right " + columnLabel($0) }
        return [left, right, difference.reason].compactMap { $0 }.joined(separator: " · ")
    }
}
