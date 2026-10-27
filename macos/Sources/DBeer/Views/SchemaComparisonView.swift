import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SchemaComparisonView: View {
    @ObservedObject var model: SchemaComparisonModel
    let close: () -> Void
    private var collectionState = SwiftUI.State<String>(initialValue: "differences")
    private var collection: String {
        get { collectionState.wrappedValue }
        nonmutating set { collectionState.wrappedValue = newValue }
    }
    private var selectedDifferenceIDState = SwiftUI.State<Int64?>(initialValue: nil)
    private var selectedDifferenceID: Int64? {
        get { selectedDifferenceIDState.wrappedValue }
        nonmutating set { selectedDifferenceIDState.wrappedValue = newValue }
    }
    private var inspectedValueRefState = SwiftUI.State<String?>(initialValue: nil)
    private var inspectedValueRef: String? {
        get { inspectedValueRefState.wrappedValue }
        nonmutating set { inspectedValueRefState.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            Group {
                if !model.hasStarted { configuration }
                else if let summary = model.summary { report(summary) }
                else { progress }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .padding(.horizontal, 20).padding(.bottom, 12)
                    .accessibilityIdentifier("schemaCompareError")
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(minWidth: 900, idealWidth: 1120, minHeight: 660, idealHeight: 780)
        .background(AppPalette.panel).foregroundStyle(AppPalette.text).tint(AppPalette.accent)
        .interactiveDismissDisabled(model.isWorking || model.isExporting)
        .sheet(item: Binding(get: { model.planDraft }, set: { if $0 == nil { model.dismissPlan() } })) { draft in
            SynchronizationPlanView(draft: draft, close: { model.dismissPlan() })
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("schemaComparison")
        .onChange(of: selectedDifferenceID) { _, id in
            inspectedValueRef = nil
        }
        .task(id: "\(collection):\(selectedDifferenceID ?? -1):\(model.isLoading)") {
            guard !model.isLoading, collection == "differences", model.page?.collection == "differences",
                  let difference = model.page?.differences.first(where: { $0.id == selectedDifferenceID }) else { return }
            await model.inspectDifference(difference)
        }
        .onChange(of: model.page?.differences.map(\.id), initial: true) { _, ids in
            guard let ids, collection == "differences" else { return }
            if !ids.contains(selectedDifferenceID ?? -1) { selectedDifferenceID = ids.first }
        }
        .onChange(of: model.hasStarted) { _, started in
            if !started { collection = "differences"; selectedDifferenceID = nil; inspectedValueRef = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up").font(.title2).foregroundStyle(AppPalette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Compare Schema Structure").font(.title2.weight(.semibold))
                if model.hasStarted {
                    Text("\(model.sourceProfile?.name ?? "Source") → \(model.targetProfile?.name ?? "Target")")
                        .font(.callout).appSecondaryText().lineLimit(1)
                        .accessibilityIdentifier("schemaCompareDirection")
                } else {
                    Text("Choose connections and the schemas to compare.").font(.callout).appSecondaryText()
                }
            }
            Spacer()
            Label("Read-only", systemImage: "lock").font(.caption).appSecondaryText().accessibilityIdentifier("schemaCompareScope")
            if model.isWorking {
                ProgressView().controlSize(.small)
                Button("Stop") { Task { await model.stop() } }.accessibilityIdentifier("schemaCompareStop")
            }
            Button("Close", action: close).keyboardShortcut(.cancelAction).accessibilityIdentifier("schemaCompareClose")
        }
    }

    private var configuration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    profilePicker("Source", selection: $model.sourceID, identifier: "schemaCompareSource")
                    Image(systemName: "arrow.right").appSecondaryText().padding(.top, 36).accessibilityHidden(true)
                    profilePicker("Target", selection: $model.targetID, identifier: "schemaCompareTarget")
                }
                if let source = model.profiles.first(where: { $0.id == model.sourceID }),
                   let target = model.profiles.first(where: { $0.id == model.targetID }), source.engine != target.engine {
                    Label("Choose two connections using the same database engine.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Schemas").font(.headline)
                    namePairs($model.mappings.schemas, source: "Source schema", target: "Target schema", addTitle: "Add Schema Pair")
                }
                DisclosureGroup("Advanced options") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Names match exactly. Add overrides only when corresponding objects have different names.")
                            .font(.caption).appSecondaryText()
                        tableOverrides
                        typeOverrides
                    }.padding(.top, 10)
                }
                DisclosureGroup("What is compared?") {
                    Text("Table structure and referenced types and sequences. Views, routines, triggers, privileges, statistics, stored data and sequence counters are excluded. Captures are independent; MySQL and Cassandra metadata are best effort.")
                        .font(.callout).appSecondaryText().fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                if !model.mappings.valid {
                    Label("Enter unique, nonempty name pairs within the selected schemas.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.padding(24)
        }
    }

    private func profilePicker(_ title: String, selection: Binding<UUID?>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Picker(title, selection: selection) {
                Text("Choose connection").tag(UUID?.none)
                ForEach(model.profiles) { profile in
                    Text("\(profile.name) · \(profile.engine.displayName)").tag(Optional(profile.id))
                }
            }.labelsHidden().accessibilityIdentifier(identifier)
            if let profile = model.profiles.first(where: { $0.id == selection.wrappedValue }) {
                Text("\(profile.host):\(profile.port) · \(profile.database)")
                    .font(.caption).appSecondaryText().textSelection(.enabled).lineLimit(2)
            }
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(AppPalette.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var tableOverrides: some View {
        DisclosureGroup("Table and member names (\(model.mappings.tables.count))") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.mappings.tables.indices, id: \.self) { i in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            objectPair(source: $model.mappings.tables[i].source, target: $model.mappings.tables[i].target)
                            DisclosureGroup("Columns") { namePairs($model.mappings.tables[i].columns) }
                            DisclosureGroup("Constraints") { namePairs($model.mappings.tables[i].constraints) }
                            DisclosureGroup("Indexes") { namePairs($model.mappings.tables[i].indexes) }
                            Button("Remove Table Override") { model.mappings.tables.remove(at: i) }
                        }.padding(8)
                    }
                }
                Button("Add Table Override") {
                    let pair = model.mappings.schemas.first ?? .init(source: "", target: "")
                    model.mappings.tables.append(.init(source: .init(schema: pair.source, name: ""), target: .init(schema: pair.target, name: "")))
                }
            }.padding(.top, 8)
        }
    }

    private var typeOverrides: some View {
        DisclosureGroup("Type names (\(model.mappings.types.count))") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.mappings.types.indices, id: \.self) { i in
                    HStack {
                        objectPair(source: $model.mappings.types[i].source, target: $model.mappings.types[i].target)
                        ControlIconButton(systemName: "minus.circle") { model.mappings.types.remove(at: i) }
                            .accessibilityLabel("Remove type override")
                    }
                }
                Button("Add Type Override") {
                    let pair = model.mappings.schemas.first ?? .init(source: "", target: "")
                    model.mappings.types.append(.init(source: .init(schema: pair.source, name: ""), target: .init(schema: pair.target, name: "")))
                }
            }.padding(.top, 8)
        }
    }

    private func namePairs(_ pairs: Binding<[SchemaNamePair]>, source: String = "Source name", target: String = "Target name", addTitle: String = "Add Name Pair") -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(pairs.wrappedValue.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    TextField(source, text: pairs[i].source).textFieldStyle(.roundedBorder).accessibilityLabel(source)
                    Image(systemName: "arrow.right").appSecondaryText().accessibilityHidden(true)
                    TextField(target, text: pairs[i].target).textFieldStyle(.roundedBorder).accessibilityLabel(target)
                    ControlIconButton(systemName: "minus.circle") { pairs.wrappedValue.remove(at: i) }
                        .accessibilityLabel("Remove name pair")
                }
            }
            Button(addTitle) { pairs.wrappedValue.append(.init(source: "", target: "")) }
        }.padding(.vertical, 4)
    }

    private func objectPair(source: Binding<SchemaQualifiedName>, target: Binding<SchemaQualifiedName>) -> some View {
        HStack {
            TextField("Source schema", text: source.schema).accessibilityLabel("Source schema")
            TextField("Source object", text: source.name).accessibilityLabel("Source object")
            Image(systemName: "arrow.right").accessibilityHidden(true)
            TextField("Target schema", text: target.schema).accessibilityLabel("Target schema")
            TextField("Target object", text: target.name).accessibilityLabel("Target object")
        }.textFieldStyle(.roundedBorder)
    }

    private var progress: some View {
        VStack(spacing: 14) {
            if model.isWorking { ProgressView().controlSize(.large) }
            Image(systemName: model.phase == .cancelled ? "stop.circle" : "square.stack.3d.up")
                .font(.largeTitle).appSecondaryText().opacity(model.isWorking ? 0 : 1)
            Text(model.phase == .cancelled ? "Comparison stopped" : model.phase == .failed ? "Comparison failed" : "Reading schema structure…")
                .font(.headline)
            if model.isWorking { Text("Capturing metadata from Source and Target.").font(.callout).appSecondaryText() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func report(_ summary: SchemaComparisonSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(conclusion(summary), systemImage: summary.fullEquality ? "checkmark.circle.fill" : "square.stack.3d.up")
                        .font(.headline).foregroundStyle(summary.fullEquality ? Color.green : AppPalette.text)
                        .accessibilityIdentifier("schemaCompareConclusion")
                    Spacer()
                    Text("\(summary.equalObjects) unchanged").font(.caption).appSecondaryText()
                }
                HStack(spacing: 16) {
                    count(summary.changedObjects, "changed", color: .orange)
                    count(summary.sourceOnlyObjects, "source only", color: .red)
                    count(summary.targetOnlyObjects, "target only", color: .green)
                    if summary.indeterminateObjects > 0 { count(summary.indeterminateObjects, "unresolved", color: .orange) }
                    Spacer()
                }.accessibilityIdentifier("schemaCompareCounts")
                if !summary.complete || summary.source.visibility != "complete" || summary.target.visibility != "complete" {
                    Label("Incomplete metadata. Matching captured objects does not establish equality.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                comparisonDetails(summary)
                Picker("Report", selection: collectionState.projectedValue) {
                    Text("Differences (\(summary.differenceCount))").tag("differences")
                    Text("Issues (\(summary.issueCount))").tag("issues")
                }
                .pickerStyle(.segmented).accessibilityIdentifier("schemaCompareCollection")
                .onChange(of: collection) { _, value in
                    selectedDifferenceID = nil
                    Task { await model.loadPage(collection: value) }
                }
            }.padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            if collection == "differences" { differenceBrowser(summary) }
            else { issueBrowser }
            Divider()
            pagination.padding(.horizontal, 20).padding(.vertical, 8)
        }
    }

    private func conclusion(_ summary: SchemaComparisonSummary) -> String {
        if summary.fullEquality { return "Selected table structure matches" }
        if summary.differenceCount > 0 { return "Structure differences found" }
        return "No differences in captured objects"
    }

    private func count(_ value: Int64, _ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text("\(value) \(title)").font(.caption).monospacedDigit()
        }
    }

    private func differenceBrowser(_ summary: SchemaComparisonSummary) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Objects").font(.caption.weight(.semibold))
                    Spacer()
                    if model.isLoading { ProgressView().controlSize(.mini) }
                }.padding(12)
                Divider()
                List(selection: selectedDifferenceIDState.projectedValue) {
                    ForEach(differenceGroups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.differences) { difference in
                                differenceRow(difference).tag(difference.id)
                            }
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                    .accessibilityIdentifier("schemaCompareReport")
                if model.page?.differences.isEmpty == true {
                    Text(summary.fullEquality ? "No differences" : "No differences on this page")
                        .font(.callout).appSecondaryText().padding(16)
                }
            }
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 400)
            .background(AppPalette.sidebar)
            differenceInspector.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxHeight: .infinity)
    }

    private struct DifferenceGroup {
        let title: String
        var differences: [SchemaDifference]
    }
    private var differenceGroups: [DifferenceGroup] {
        var groups: [DifferenceGroup] = []
        for difference in model.page?.differences ?? [] {
            let ref = difference.targetRef ?? difference.sourceRef
            let object = ref?.table ?? ref?.name ?? "Scope"
            let title = [ref?.schema, object].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ".")
            if let index = groups.firstIndex(where: { $0.title == title }) { groups[index].differences.append(difference) }
            else { groups.append(.init(title: title, differences: [difference])) }
        }
        return groups
    }

    private func differenceRow(_ difference: SchemaDifference) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text((difference.targetRef ?? difference.sourceRef)?.name ?? "Scope")
                .font(.callout.weight(.medium)).lineLimit(1)
            Text(propertyTitle(difference.property)).font(.caption).lineLimit(2)
            Label(statusTitle(difference.kind), systemImage: statusIcon(difference.kind))
                .font(.caption2).foregroundStyle(statusColor(difference.kind))
        }.padding(.vertical, 5)
    }

    @ViewBuilder private var differenceInspector: some View {
        if let selected = model.selectedDifference, selected.id == selectedDifferenceID {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text((selected.targetRef ?? selected.sourceRef)?.title ?? "Scope")
                            .font(.headline).textSelection(.enabled)
                        Text("SQL definition").font(.caption).appSecondaryText()
                    }
                    Spacer()
                    Label(statusTitle(selected.kind), systemImage: statusIcon(selected.kind))
                        .font(.caption).foregroundStyle(statusColor(selected.kind))
                }.padding(14)
                if selected.planning == "manual" {
                    Label("Manual review required", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange).padding(.horizontal, 14).padding(.bottom, 10)
                }
                Divider()
                if model.isLoadingDiff {
                    ProgressView("Loading difference…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let diff = model.diff {
                    ComparisonDiffView(diff: diff, syntaxEngine: model.sourceProfile?.engine,
                        limitedMessage: "SQL preview is incomplete. See technical details for the captured metadata.")
                } else {
                    Text(model.diffError ?? "Select a difference to inspect its SQL definition.")
                        .font(.callout).appSecondaryText().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                technicalDetails(selected).padding(12)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right.square").font(.largeTitle).appSecondaryText()
                Text("Select a difference").font(.headline)
                Text("Source and Target SQL definitions appear side by side.").font(.callout).appSecondaryText()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func technicalDetails(_ difference: SchemaDifference) -> some View {
        DisclosureGroup("Technical details") {
            VStack(alignment: .leading, spacing: 8) {
                Text(difference.property.isEmpty ? "Object" : difference.property)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("SQL is reconstructed from the captured structure for comparison. Mapped source names use the target namespace; expressions keep their original server text.")
                    .font(.caption).appSecondaryText().fixedSize(horizontal: false, vertical: true)
                if !difference.reasonCodes.isEmpty {
                    Text(difference.reasonCodes.joined(separator: " · ")).font(.caption).appSecondaryText().textSelection(.enabled)
                }
                HStack {
                    if let value = difference.sourcePreview {
                        Button("Inspect Source JSON") { inspectedValueRef = value.valueRef; Task { await model.inspect(value) } }
                    }
                    if let value = difference.targetPreview {
                        Button("Inspect Target JSON") { inspectedValueRef = value.valueRef; Task { await model.inspect(value) } }
                    }
                }
                if let text = model.valueText, inspectedValueRef != nil {
                    ScrollView([.horizontal, .vertical]) {
                        Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }.frame(maxHeight: 120)
                    HStack {
                        Button("Previous Chunk") { Task { await model.previousValue() } }.disabled(!model.canPreviousValue)
                        Text("\(model.valueOffset)–\(model.valueNextOffset) of \(model.valueTotalBytes) bytes")
                            .font(.caption).appSecondaryText().monospacedDigit()
                        Button("Next Chunk") { Task { await model.nextValue() } }.disabled(!model.valueHasMore)
                            .accessibilityIdentifier("schemaCompareNextValue")
                    }
                    if model.valueBoundaryBytes > 0 {
                        Text("A character crossing the chunk boundary appears on the adjacent page.").font(.caption).appSecondaryText()
                    }
                }
            }.padding(.top, 8)
        }.font(.caption)
    }

    private func propertyTitle(_ property: String) -> String {
        let part = property.split(separator: ".").last(where: { $0 != "items" && $0 != "value" }).map(String.init) ?? ""
        let titles = [
            "tables": "Table definition", "columns": "Column definition", "indexes": "Index definition",
            "constraints": "Constraint definition", "types": "Type definition", "sequences": "Sequence definition",
            "type": "Type", "nullable": "Nullability", "default": "Default", "generated": "Generated expression",
            "identity": "Identity", "charset": "Character set", "collation": "Collation", "comment": "Comment",
            "onUpdate": "On update", "visible": "Visibility", "ordinal": "Column order", "options": "Options",
            "keys": "Index keys", "includes": "Included columns", "predicate": "Index condition",
            "unique": "Uniqueness", "method": "Index method", "check": "Check condition",
            "dependencies": "Dependencies", "observation": "Metadata availability", "existence": "Existence",
            "engineContext": "Database settings", "storage": "Storage", "kind": "Object kind",
        ]
        return titles[part] ?? "Definition"
    }

    private var issueBrowser: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if model.page?.collection == "issues", model.page?.issues.isEmpty == true {
                    Label("No issues in this report", systemImage: "checkmark.circle").font(.callout).appSecondaryText().padding()
                }
                ForEach(model.page?.issues ?? []) { issue in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: issue.blocksEquality ? "exclamationmark.triangle" : "info.circle").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(issue.side.capitalized) · \(issue.ref?.title ?? "Capture")").font(.callout.weight(.medium))
                            Text(issue.message).font(.callout).textSelection(.enabled)
                            DisclosureGroup("Details") {
                                Text("\(issue.code) · \(issue.property)").font(.caption).appSecondaryText().textSelection(.enabled)
                            }
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppPalette.background, in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(20)
        }.accessibilityIdentifier("schemaCompareReport")
    }

    private func comparisonDetails(_ summary: SchemaComparisonSummary) -> some View {
        DisclosureGroup("Comparison details") {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    capture("Source", summary.source)
                    capture("Target", summary.target)
                    Text("Captures are independent. Expressions retain their exact server representation. Only selected table structure and referenced types and sequences are compared.")
                    DisclosureGroup("Name correspondence") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(summary.mappings.schemas.indices, id: \.self) { i in
                                Text("Schema: \(summary.mappings.schemas[i].source) → \(summary.mappings.schemas[i].target)")
                            }
                            ForEach(summary.mappings.tables.indices, id: \.self) { i in
                                let pair = summary.mappings.tables[i]
                                Text("Table: \(pair.source.schema).\(pair.source.name) → \(pair.target.schema).\(pair.target.name)")
                                ForEach(Array((pair.columns + pair.constraints + pair.indexes).enumerated()), id: \.offset) { _, names in
                                    Text("\(names.source) → \(names.target)").padding(.leading, 12)
                                }
                            }
                            ForEach(summary.mappings.types.indices, id: \.self) { i in
                                let pair = summary.mappings.types[i]
                                Text("Type: \(pair.source.schema).\(pair.source.name) → \(pair.target.schema).\(pair.target.name)")
                            }
                        }
                    }
                }.font(.caption).appSecondaryText().textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }.frame(maxHeight: 140)
        }.font(.caption)
    }

    private func capture(_ title: String, _ context: SchemaCaptureContext) -> some View {
        Text("\(title): \(context.database) · \(context.version)\n\(context.startedAt) → \(context.finishedAt) · \(context.consistency) · visibility: \(context.visibility)")
    }

    private var pagination: some View {
        HStack(spacing: 12) {
            Button("Previous") { Task { await model.previousPage() } }.disabled(!model.canPrevious)
            Text("\((model.page?.offset ?? 0) + (model.page?.count == 0 ? 0 : 1))–\(model.page?.nextOffset ?? 0)")
                .font(.caption).monospacedDigit().appSecondaryText()
            Button("Next") { Task { await model.nextPage() } }.disabled(!model.canNext)
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
        }
    }

    private var footer: some View {
        HStack {
            if !model.hasStarted {
                Spacer()
                Button("Compare") { Task { await model.start() } }.keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart).accessibilityIdentifier("schemaCompareStart")
            } else {
                if model.targetProfile.map({ [.postgresql, .mysql].contains($0.engine) }) == true {
                    Button(model.isGeneratingPlan ? "Generating SQL…" : "Generate SQL Plan") { Task { await model.generatePlan() } }
                        .disabled(!model.canGeneratePlan).controlHover().accessibilityIdentifier("schemaComparePlan")
                }
                Button("New Comparison") { Task { await model.reset() } }.disabled(model.isWorking || model.isExporting)
                    .accessibilityIdentifier("schemaCompareReset")
                Spacer()
                if model.exportComplete { Label("Report exported", systemImage: "checkmark").font(.caption).appSecondaryText() }
                Button(model.isExporting ? "Exporting…" : "Export JSON Report…", action: exportReport)
                    .disabled(model.summary == nil || model.isExporting).accessibilityIdentifier("schemaCompareExport")
            }
        }
    }

    private func statusTitle(_ kind: String) -> String {
        switch kind {
        case "sourceOnly": "Source only"
        case "targetOnly": "Target only"
        case "changed": "Changed"
        default: "Unresolved"
        }
    }
    private func statusIcon(_ kind: String) -> String {
        switch kind {
        case "sourceOnly": "minus.circle"
        case "targetOnly": "plus.circle"
        case "changed": "pencil.circle"
        default: "questionmark.circle"
        }
    }
    private func statusColor(_ kind: String) -> Color {
        switch kind {
        case "sourceOnly": .red
        case "targetOnly": .green
        default: .orange
        }
    }

    private func exportReport() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "schema-comparison.json"
        panel.begin { response in if response == .OK, let url = panel.url { Task { await model.export(to: url) } } }
    }
}
