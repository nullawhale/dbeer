import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SchemaComparisonView: View {
    @ObservedObject var model: SchemaComparisonModel
    let close: () -> Void
    private var collection = SwiftUI.State(initialValue: "differences")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare Schema Structure").font(.title2.weight(.semibold))
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small); Button("Stop") { Task { await model.stop() } }.accessibilityIdentifier("schemaCompareStop") }
                Button("Close", action: close).keyboardShortcut(.cancelAction).accessibilityIdentifier("schemaCompareClose")
            }
            Text("Source → Target · PostgreSQL ↔ PostgreSQL or MySQL ↔ MySQL")
                .font(.callout).appSecondaryText()
            Text("Read-only table structure and referenced types/sequences. Excludes views, routines, triggers, privileges, statistics, stored data and sequence/AUTO_INCREMENT counters. Captures are independent; MySQL is best effort.")
                .font(.caption).appSecondaryText().fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("schemaCompareScope")
            Divider()
            if !model.hasStarted { configuration }
            else if let summary = model.summary { report(summary) }
            else {
                VStack(alignment: .leading, spacing: 8) {
                    capturedProfiles
                    Text(model.phase == .cancelled ? "Comparison cancelled." : model.phase == .failed ? "Comparison failed." : "Reading metadata in two dedicated read-only sessions…")
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("schemaCompareError") }
            HStack {
                if !model.hasStarted {
                    Text("Map exact names. Unmapped names correspond only when identical; renames are never inferred.").font(.caption).appSecondaryText()
                    Spacer()
                    Button("Compare") { Task { await model.start() } }.keyboardShortcut(.defaultAction)
                        .disabled(!model.canStart).accessibilityIdentifier("schemaCompareStart")
                } else {
                    Button("New Comparison") { Task { await model.reset() } }.disabled(model.isWorking || model.isExporting)
                        .accessibilityIdentifier("schemaCompareReset")
                    Spacer()
                    if model.exportComplete { Text("Report exported.").font(.caption).appSecondaryText() }
                    Button(model.isExporting ? "Exporting…" : "Export JSON Report…", action: exportReport)
                        .disabled(model.summary == nil || model.isExporting).accessibilityIdentifier("schemaCompareExport")
                }
            }
        }.padding(20).frame(minWidth: 760, idealWidth: 1000, minHeight: 620, idealHeight: 760)
            .background(AppPalette.panel).accessibilityElement(children: .contain).accessibilityIdentifier("schemaComparison")
    }
    private var configuration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 20) {
                    profilePicker("Source", selection: $model.sourceID, identifier: "schemaCompareSource")
                    Image(systemName: "arrow.right").padding(.top, 26).accessibilityHidden(true)
                    profilePicker("Target", selection: $model.targetID, identifier: "schemaCompareTarget")
                }
                GroupBox("Schema correspondence") {
                    namePairs($model.mappings.schemas, source: "Source schema", target: "Target schema")
                }
                DisclosureGroup("Table and member name overrides (optional)") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.mappings.tables.indices, id: \.self) { i in
                            GroupBox {
                                VStack(alignment: .leading) {
                                    objectPair(source: $model.mappings.tables[i].source, target: $model.mappings.tables[i].target)
                                    DisclosureGroup("Columns") { namePairs($model.mappings.tables[i].columns) }
                                    DisclosureGroup("Constraints") { namePairs($model.mappings.tables[i].constraints) }
                                    DisclosureGroup("Indexes") { namePairs($model.mappings.tables[i].indexes) }
                                    Button("Remove table override") { model.mappings.tables.remove(at: i) }
                                }
                            }
                        }
                        Button("Add Table Override") {
                            let pair = model.mappings.schemas.first ?? .init(source: "", target: "")
                            model.mappings.tables.append(.init(source: .init(schema: pair.source, name: ""), target: .init(schema: pair.target, name: "")))
                        }
                    }.padding(.top, 8)
                }
                DisclosureGroup("Type name overrides (optional)") {
                    VStack(alignment: .leading) {
                        ForEach(model.mappings.types.indices, id: \.self) { i in
                            HStack {
                                objectPair(source: $model.mappings.types[i].source, target: $model.mappings.types[i].target)
                                ControlIconButton(systemName: "minus.circle") { model.mappings.types.remove(at: i) }.accessibilityLabel("Remove type override")
                            }
                        }
                        Button("Add Type Override") {
                            let pair = model.mappings.schemas.first ?? .init(source: "", target: "")
                            model.mappings.types.append(.init(source: .init(schema: pair.source, name: ""), target: .init(schema: pair.target, name: "")))
                        }
                    }.padding(.top, 8)
                }
                if !model.mappings.valid { Text("Use nonempty, one-to-one name pairs inside mapped schemas.").font(.caption).foregroundStyle(.orange) }
            }.padding(2)
        }
    }
    private func profilePicker(_ title: String, selection: Binding<UUID?>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker(title, selection: selection) {
                Text("Choose connection").tag(UUID?.none)
                ForEach(model.profiles) { profile in Text("\(profile.name) · \(profile.engine.displayName)").tag(Optional(profile.id)) }
            }.accessibilityIdentifier(identifier)
            if let profile = model.profiles.first(where: { $0.id == selection.wrappedValue }) {
                Text("\(profile.host):\(profile.port) · \(profile.database) · \(profile.policy.environment.rawValue)")
                    .font(.caption).appSecondaryText().textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func namePairs(_ pairs: Binding<[SchemaNamePair]>, source: String = "Source name", target: String = "Target name") -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(pairs.wrappedValue.indices, id: \.self) { i in
                HStack {
                    TextField(source, text: pairs[i].source).textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                    TextField(target, text: pairs[i].target).textFieldStyle(.roundedBorder)
                    ControlIconButton(systemName: "minus.circle") { pairs.wrappedValue.remove(at: i) }.accessibilityLabel("Remove name pair")
                }
            }
            Button("Add Name Pair") { pairs.wrappedValue.append(.init(source: "", target: "")) }
        }.padding(8)
    }
    private func objectPair(source: Binding<SchemaQualifiedName>, target: Binding<SchemaQualifiedName>) -> some View {
        HStack {
            TextField("Source schema", text: source.schema); TextField("Source object", text: source.name)
            Image(systemName: "arrow.right").accessibilityHidden(true)
            TextField("Target schema", text: target.schema); TextField("Target object", text: target.name)
        }.textFieldStyle(.roundedBorder)
    }
    private var capturedProfiles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(model.sourceProfile?.name ?? "Source") → \(model.targetProfile?.name ?? "Target")")
                .font(.headline).accessibilityIdentifier("schemaCompareDirection")
            if let source = model.sourceProfile, let target = model.targetProfile {
                Text("Source: \(source.host):\(source.port) · \(source.database) · \(source.policy.label)\nTarget: \(target.host):\(target.port) · \(target.database) · \(target.policy.label)")
                    .font(.caption).appSecondaryText()
            }
        }.textSelection(.enabled)
    }
    private func report(_ summary: SchemaComparisonSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            capturedProfiles
            Text(summary.fullEquality ? "Selected table structure matches" : summary.complete ? "Structure differences found" : "Incomplete metadata — equality cannot be established")
                .font(.headline).foregroundStyle(summary.fullEquality ? .green : .orange).accessibilityIdentifier("schemaCompareConclusion")
            Text("\(summary.equalObjects) equal · \(summary.changedObjects) changed · \(summary.sourceOnlyObjects) source only · \(summary.targetOnlyObjects) target only · \(summary.indeterminateObjects) indeterminate")
                .font(.caption).monospacedDigit().accessibilityIdentifier("schemaCompareCounts")
            DisclosureGroup("Capture intervals and scope") {
                VStack(alignment: .leading) {
                    capture("Source", summary.source); capture("Target", summary.target)
                    Text("Expressions retain their exact server representation and may require manual review.")
                }.font(.caption).textSelection(.enabled)
            }
            DisclosureGroup("Captured name correspondence") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(summary.mappings.schemas.indices, id: \.self) { i in
                            Text("Schema: \(summary.mappings.schemas[i].source) → \(summary.mappings.schemas[i].target)")
                        }
                        ForEach(summary.mappings.tables.indices, id: \.self) { i in
                            let pair = summary.mappings.tables[i]
                            Text("Table: \(pair.source.schema) · \(pair.source.name) → \(pair.target.schema) · \(pair.target.name)")
                            ForEach(Array((pair.columns + pair.constraints + pair.indexes).enumerated()), id: \.offset) { _, names in
                                Text("\(names.source) → \(names.target)").padding(.leading, 12)
                            }
                        }
                        ForEach(summary.mappings.types.indices, id: \.self) { i in
                            let pair = summary.mappings.types[i]
                            Text("Type: \(pair.source.schema) · \(pair.source.name) → \(pair.target.schema) · \(pair.target.name)")
                        }
                    }.font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 140)
            }
            Picker("Report", selection: collection.projectedValue) {
                Text("Differences (\(summary.differenceCount))").tag("differences")
                Text("Issues (\(summary.issueCount))").tag("issues")
            }.pickerStyle(.segmented).onChange(of: collection.wrappedValue) { _, value in Task { await model.loadPage(collection: value) } }
                .accessibilityIdentifier("schemaCompareCollection")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.page?.count == 0 { Text("No \(collection.wrappedValue) in this report.").font(.callout).appSecondaryText() }
                    ForEach(model.page?.differences ?? []) { difference in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(difference.kind) · \((difference.targetRef ?? difference.sourceRef)?.title ?? "Scope")").font(.callout.weight(.medium))
                            Text(difference.property).font(.caption).appSecondaryText()
                            HStack(alignment: .top) {
                                preview("Source", difference.sourcePreview); preview("Target", difference.targetPreview)
                            }
                            if difference.planning == "manual" { Text("Manual review required").font(.caption).foregroundStyle(.orange) }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(AppPalette.background, in: RoundedRectangle(cornerRadius: 6))
                    }
                    ForEach(model.page?.issues ?? []) { issue in
                        VStack(alignment: .leading) {
                            Text("\(issue.side) · \(issue.ref?.title ?? "Capture") · \(issue.code)").font(.callout.weight(.medium))
                            Text(issue.message).font(.callout).textSelection(.enabled)
                        }.padding(10)
                    }
                }.padding(2)
            }.accessibilityIdentifier("schemaCompareReport")
            if let text = model.valueText {
                DisclosureGroup("Exact property JSON · bytes \(model.valueOffset)–\(model.valueNextOffset) of \(model.valueTotalBytes)") {
                    VStack(alignment: .leading) {
                        ScrollView([.horizontal, .vertical]) { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 140)
                        if model.valueBoundaryBytes > 0 { Text("An incomplete UTF-8 character at the chunk boundary is shown on the adjacent page.").font(.caption).appSecondaryText() }
                        HStack {
                            Button("Previous Value Chunk") { Task { await model.previousValue() } }.disabled(!model.canPreviousValue)
                            Button("Next Value Chunk") { Task { await model.nextValue() } }.disabled(!model.valueHasMore)
                                .accessibilityIdentifier("schemaCompareNextValue")
                        }
                    }
                }
            }
            HStack {
                Button("Previous") { Task { await model.previousPage() } }.disabled(!model.canPrevious)
                Text("\((model.page?.offset ?? 0) + (model.page?.count == 0 ? 0 : 1))–\(model.page?.nextOffset ?? 0)").font(.caption).monospacedDigit()
                Button("Next") { Task { await model.nextPage() } }.disabled(!model.canNext)
                if model.isLoading { ProgressView().controlSize(.small) }
            }
        }
    }
    private func capture(_ title: String, _ context: SchemaCaptureContext) -> some View {
        Text("\(title): \(context.database) · \(context.version)\n\(context.startedAt) → \(context.finishedAt) · \(context.consistency) · visibility: \(context.visibility)")
    }
    private func preview(_ title: String, _ value: SchemaValuePreview?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.medium))
            if let value {
                Text(value.text + (value.truncated ? "…" : "")).font(.system(.caption, design: .monospaced)).lineLimit(4).textSelection(.enabled)
                Button("Inspect Value") { Task { await model.inspect(value) } }.font(.caption)
            } else { Text("Absent").font(.caption).appSecondaryText() }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func exportReport() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "schema-comparison.json"
        panel.begin { response in if response == .OK, let url = panel.url { Task { await model.export(to: url) } } }
    }
}
