import AppKit
import SwiftUI

struct PhysicalStructureView: View {
    @ObservedObject var model: PhysicalStructureModel
    let close: () -> Void
    private var confirmClose = SwiftUI.State(initialValue: false)
    private var confirmReplace = SwiftUI.State(initialValue: false)
    var makeSavePanel: @MainActor () -> NSSavePanel = { NSSavePanel() }
    var makeOpenPanel: @MainActor () -> NSOpenPanel = { NSOpenPanel() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Partitions, Storage & Online DDL").font(.title2)
                Spacer()
                Text(model.profile.name + " · " + model.profile.policy.label).appSecondaryText()
            }
            Text(model.target.schema + "." + model.target.table).font(.headline).textSelection(.enabled)
            Text("Inspect the current object, select one typed operation, then review its exact SQL and prerequisites. Preview reads metadata. Apply uses the original dedicated session and never retries or cleans up automatically.")
                .font(.caption).appSecondaryText()
            files
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.objects.isEmpty { PhysicalObjectInspectionView(objects: model.objects) }
                    if model.report == nil {
                        PhysicalIntentEditor(intent: $model.intent, kinds: model.operationKinds, engine: model.profile.engine,
                            schema: model.target.schema, columns: model.columnNames, partitions: model.objects.first?.partitions.map(\.name) ?? [])
                            .disabled(!model.editable)
                    }
                    if let plan = model.preview { PhysicalPlanReviewView(plan: plan) }
                    if let report = model.report { PhysicalExecutionReviewView(report: report, elapsed: model.elapsedMilliseconds) }
                    if let report = model.openedReport {
                        DisclosureGroup("Opened historical report · no live authority", isExpanded: .constant(true)) { PhysicalExecutionReviewView(report: report, elapsed: 0) }
                    }
                    if !model.history.isEmpty {
                        DisclosureGroup("Previous reports from this workspace session") {
                            ForEach(model.history) { report in
                                DisclosureGroup(report.plan.draft.target.schema + "." + report.plan.draft.target.table + " · " + PhysicalOperationLabels.outcome(report.outcome.state)) { PhysicalExecutionReviewView(report: report, elapsed: 0) }
                            }
                        }
                    }
                    if model.isApplying, model.report == nil {
                        Text("The original operation is active. Check retained status for acknowledged steps; Stop cannot establish whether an in-flight statement completed.")
                            .font(.caption).appSecondaryText()
                    }
                    if let notice = model.notice { Text(notice).font(.caption).appSecondaryText().textSelection(.enabled) }
                    if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 300, idealHeight: 540, maxHeight: 680)
            footer
        }.padding(20).frame(width: 920).frame(minHeight: 480, idealHeight: 760, maxHeight: 920)
        .interactiveDismissDisabled()
        .confirmationDialog("Close this physical-operation inspector? Retained evidence stays available in this workspace session. Unknown outcomes and INVALID indexes require explicit investigation; closing never replays or cleans up SQL.", isPresented: confirmClose.projectedValue) {
            Button("Close Inspector", role: .destructive, action: close)
            Button("Keep Open", role: .cancel) {}
        }
    }
    private var files: some View {
        HStack {
            Menu("Physical Operation") {
                Button("Open Portable Intent…") { confirmReplace.wrappedValue = true }.disabled(!model.canOpenIntent)
                Button("Save Portable Intent As…", action: saveIntent).disabled(model.isBusy || model.closing || !model.portableIntent.valid)
                Divider()
                Button("Save Execution Report As…") { if let report = model.report { saveReport(report) } }.disabled(model.report == nil || model.isBusy || model.closing)
                Button("Open Historical Report…", action: openReport).disabled(model.isBusy || model.closing)
            }.fixedSize().controlHover().accessibilityIdentifier("physicalFiles")
            Text("Portable files carry no connection or execution authority.").font(.caption).appSecondaryText()
            Spacer()
        }
        .confirmationDialog("Replace local intent with a portable file? It remains disconnected until an explicit Inspect or Preview and requires a fresh review.", isPresented: confirmReplace.projectedValue) {
            Button("Open Portable Intent", action: openIntent)
            Button("Cancel", role: .cancel) {}
        }
    }
    private func saveIntent() {
        let expected = model.portableIntent
        chooseSave(name: "physical-intent.dbeerphysical", limit: PhysicalStructureIntentDocument.maximumBytes) { url, version in
            Task { await model.saveIntent(to: url, expected: expected, version: version) }
        }
    }
    private func saveReport(_ report: PhysicalStructureReport) {
        chooseSave(name: "physical-report.dbeerphysicalreport", limit: PhysicalStructureReport.maximumBytes) { url, version in
            Task { await model.saveReport(to: url, expected: report, version: version) }
        }
    }
    private func chooseSave(name: String, limit: Int, publish: (URL, SQLFileVersion?) -> Void) {
        let panel = makeSavePanel(); panel.nameFieldStringValue = name; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let version = FileManager.default.fileExists(atPath: url.path) ? try SQLFileBinding.version(of: url, maximumBytes: limit) : nil
            publish(url, version)
        } catch { model.setFileError(error) }
    }
    private func openIntent() {
        let expected = model.portableIntent
        let panel = makeOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.openIntent(from: url, expected: expected) }
    }
    private func openReport() {
        let panel = makeOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.openReport(from: url) }
    }
    private var footer: some View {
        HStack {
            Button("Inspect Current Object") { Task { await model.inspect() } }.controlHover().disabled(!model.canInspect)
                .accessibilityIdentifier("physicalInspect")
            Button("Preview Exact SQL") { Task { await model.preparePreview() } }.controlHover().disabled(!model.canPreview)
                .accessibilityIdentifier("physicalPreview")
            Button("Review & Apply…") { Task { await model.apply() } }.controlHover().keyboardShortcut(.defaultAction)
                .disabled(!model.canApply).accessibilityIdentifier("physicalApply")
            Spacer()
            if model.isBusy { Button("Stop") { Task { await model.stop() } }.controlHover().disabled(model.closing) }
            if model.canCheckStatus || model.checkingStatus {
                Button("Check Status") { Task { await model.checkStatus() } }.controlHover().disabled(!model.canCheckStatus)
            }
            if model.report != nil {
                Button("Reconcile Catalog") { Task { await model.reconcile() } }.controlHover().disabled(!model.canReconcile)
            }
            Button("Close") { confirmClose.wrappedValue = true }.controlHover().keyboardShortcut(.cancelAction)
                .disabled(model.isBusy || model.checkingStatus || model.closing)
        }
    }
}

private struct PhysicalIntentEditor: View {
    @Binding var intent: StructurePhysicalIntent
    let kinds: [String]
    let engine: DatabaseEngine
    let schema: String
    let columns: [String]
    let partitions: [String]
    var body: some View {
        GroupBox("Selected operation") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Operation", selection: Binding(get: { intent.kind }, set: { intent = PhysicalStructureModel.emptyIntent($0, engine: engine, schema: schema) })) {
                    ForEach(kinds, id: \.self) { Text(PhysicalOperationLabels.label($0)).tag($0) }
                    if !kinds.contains(intent.kind) { Text(PhysicalOperationLabels.label(intent.kind) + " · unavailable for this object").tag(intent.kind) }
                }.controlHover()
                Text("Candidate families come from the current inspector. Every concrete intent must still pass server-version, object, privilege, locking and metadata checks at Preview and Apply.")
                    .font(.caption).appSecondaryText()
                fields
                if engine == .mysql { onlineChoices }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private var fields: some View {
        if intent.index != nil {
            PhysicalIndexIntentEditor(index: Binding(get: { intent.index ?? .init(action: "add", name: "", columns: [""]) }, set: { if intent.index != nil { intent.index = $0 } }), engine: engine, columns: columns)
        }
        if intent.child != nil {
            HStack {
                TextField("Exact child schema/database", text: Binding(get: { intent.child?.schema ?? "" }, set: { intent.child?.schema = $0 })).textFieldStyle(.roundedBorder)
                TextField(intent.kind == "exchangePartition" ? "Exact exchange table" : "Exact child table", text: Binding(get: { intent.child?.table ?? "" }, set: { intent.child?.table = $0 })).textFieldStyle(.roundedBorder)
            }
        }
        if intent.kind == "detachPartition" {
            Toggle("Detach CONCURRENTLY (outside a transaction)", isOn: Binding(get: { intent.concurrent == true }, set: { intent.concurrent = $0 ? true : nil })).controlHover()
        }
        if intent.bound != nil { PhysicalBoundEditor(bound: Binding(get: { intent.bound ?? .init(kind: "default") }, set: { if intent.bound != nil { intent.bound = $0 } }), allowsFrom: true) }
        if intent.partitions != nil {
            StructureOrderedColumnsEditor(title: "Exact selected partition names", options: partitions.isEmpty ? nil : partitions,
                columns: Binding(get: { intent.partitions ?? [] }, set: { intent.partitions = $0 }))
        }
        if intent.kind == "partitionTable" {
            Picker("Partition method", selection: Binding(get: { intent.method ?? "range" }, set: { method in
                intent.method = method
                if ["hash", "key"].contains(method) { intent.count = 1; intent.definitions = nil }
                else { intent.count = nil; intent.definitions = [.init(name: "", bound: .init(kind: method.hasPrefix("list") ? "list" : "range", to: method.hasPrefix("list") ? nil : [.init(kind: "integer", value: "1")], values: method.hasPrefix("list") ? [[.init(kind: "integer", value: "1")]] : nil))] }
            })) {
                Text("RANGE").tag("range"); Text("RANGE COLUMNS").tag("rangeColumns")
                Text("LIST").tag("list"); Text("LIST COLUMNS").tag("listColumns")
                Text("HASH").tag("hash"); Text("KEY").tag("key")
            }.controlHover()
            StructureOrderedColumnsEditor(title: "Exact partition key columns", options: columns.isEmpty ? nil : columns,
                columns: Binding(get: { intent.columns ?? [] }, set: { intent.columns = $0 }))
        }
        if intent.definitions != nil { definitions }
        if intent.count != nil {
            TextField("Partition count", value: Binding(get: { intent.count ?? 1 }, set: { intent.count = $0 }), format: .number)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Partition count")
        }
        if intent.kind == "storageEngine" {
            Picker("Destination storage engine", selection: Binding(get: { intent.engine ?? "InnoDB" }, set: { intent.engine = $0 })) {
                Text("InnoDB").tag("InnoDB"); Text("MyISAM").tag("MyISAM")
            }.controlHover()
        }
        if intent.kind == "reorderColumns" {
            StructureOrderedColumnsEditor(title: "Complete destination physical column order", options: columns.isEmpty ? nil : columns,
                columns: Binding(get: { intent.columnOrder ?? [] }, set: { intent.columnOrder = $0 }))
            Text("COPY is explicit. Preview rejects any generated-column or AUTO_INCREMENT preservation rule it cannot prove.").font(.caption).appSecondaryText()
        }
    }
    private var definitions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach((intent.definitions ?? []).indices, id: \.self) { i in
                GroupBox("Partition definition \(i + 1)") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Exact partition name", text: definitionBinding(i).name).textFieldStyle(.roundedBorder)
                            ControlIconButton(systemName: "minus.circle") { if intent.definitions?.indices.contains(i) == true { intent.definitions?.remove(at: i) } }.accessibilityLabel("Remove partition definition")
                        }
                        PhysicalBoundEditor(bound: definitionBinding(i).bound, allowsFrom: false)
                    }
                }
            }
            Button("Add Partition Definition") { intent.definitions?.append(.init(name: "", bound: .init(kind: "range", to: [.init(kind: "integer", value: "1")]))) }
                .controlHover().disabled((intent.definitions?.count ?? 0) >= 128)
        }
    }
    private func definitionBinding(_ i: Int) -> Binding<StructurePhysicalPartitionDefinition> {
        Binding(get: {
            guard let values = intent.definitions, values.indices.contains(i) else { return .init(name: "", bound: .init(kind: "default")) }
            return values[i]
        }, set: { if intent.definitions?.indices.contains(i) == true { intent.definitions?[i] = $0 } })
    }
    private var onlineChoices: some View {
        HStack {
            Picker("Required ALGORITHM", selection: Binding(get: { intent.algorithm ?? "INPLACE" }, set: { intent.algorithm = $0 })) {
                Text("INPLACE").tag("INPLACE"); Text("COPY").tag("COPY"); Text("INSTANT").tag("INSTANT")
            }.controlHover()
            Picker("Required LOCK", selection: Binding(get: { intent.lock ?? "NONE" }, set: { intent.lock = $0 })) {
                Text("NONE").tag("NONE"); Text("SHARED").tag("SHARED"); Text("EXCLUSIVE").tag("EXCLUSIVE")
            }.controlHover()
            Text("Unsupported combinations fail; there is no fallback.").font(.caption).appSecondaryText()
        }
    }
}

private struct PhysicalIndexIntentEditor: View {
    @Binding var index: StructureIndexEdit
    let engine: DatabaseEngine
    let columns: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Index operation", selection: Binding(get: { index.action }, set: { action in
                    index = .init(action: action, name: index.name, columns: action == "add" ? [""] : nil)
                })) { Text("Create").tag("add"); Text("Drop").tag("drop") }.controlHover()
                TextField("Exact index name", text: $index.name).textFieldStyle(.roundedBorder)
            }
            if index.action == "add" {
                Toggle("Unique", isOn: Binding(get: { index.unique == true }, set: { index.unique = $0 ? true : nil })).controlHover()
                Toggle("Advanced typed definition", isOn: Binding(get: { index.definition != nil }, set: {
                    index.definition = $0 ? .init(method: "btree", terms: [.init(column: "")]) : nil
                    index.columns = $0 ? nil : [""]
                })).controlHover()
                if index.definition != nil {
                    StructureIndexDefinitionEditor(definition: Binding(get: { index.definition ?? .init(method: "btree", terms: []) }, set: { if index.definition != nil { index.definition = $0 } }), names: columns, engine: engine)
                } else {
                    StructureOrderedColumnsEditor(title: "Exact index columns", options: columns.isEmpty ? nil : columns,
                        columns: Binding(get: { index.columns ?? [] }, set: { index.columns = $0 }))
                }
            }
        }
    }
}

private struct PhysicalBoundEditor: View {
    @Binding var bound: StructurePhysicalBound
    let allowsFrom: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Typed bound", selection: Binding(get: { bound.kind }, set: { kind in
                switch kind {
                case "range": bound = .init(kind: kind, from: allowsFrom ? [.init(kind: "integer", value: "0")] : nil, to: [.init(kind: "integer", value: "1")])
                case "list": bound = .init(kind: kind, values: [[.init(kind: "integer", value: "1")]])
                case "hash": bound = .init(kind: kind, modulus: 1, remainder: 0)
                default: bound = .init(kind: "default")
                }
            })) {
                Text("RANGE").tag("range"); Text("LIST").tag("list")
                if allowsFrom { Text("HASH").tag("hash"); Text("DEFAULT").tag("default") }
            }.controlHover()
            if bound.kind == "range" {
                if allowsFrom { PhysicalTupleEditor(title: "FROM (inclusive)", values: Binding(get: { bound.from ?? [] }, set: { bound.from = $0 })) }
                PhysicalTupleEditor(title: allowsFrom ? "TO (exclusive)" : "LESS THAN", values: Binding(get: { bound.to ?? [] }, set: { bound.to = $0 }))
            }
            if bound.kind == "list" {
                ForEach((bound.values ?? []).indices, id: \.self) { i in
                    HStack(alignment: .top) {
                        PhysicalTupleEditor(title: "LIST tuple \(i + 1)", values: tupleBinding(i))
                        ControlIconButton(systemName: "minus.circle") { if bound.values?.indices.contains(i) == true { bound.values?.remove(at: i) } }.accessibilityLabel("Remove LIST tuple")
                    }
                }
                Button("Add LIST Tuple") { bound.values?.append([.init(kind: "integer", value: "0")]) }.controlHover().disabled((bound.values?.count ?? 0) >= 128)
            }
            if bound.kind == "hash" {
                HStack {
                    TextField("Modulus", value: Binding(get: { bound.modulus ?? 1 }, set: { bound.modulus = $0 }), format: .number).textFieldStyle(.roundedBorder)
                    TextField("Remainder", value: Binding(get: { bound.remainder ?? 0 }, set: { bound.remainder = $0 }), format: .number).textFieldStyle(.roundedBorder)
                }
            }
        }
    }
    private func tupleBinding(_ i: Int) -> Binding<[StructurePhysicalValue]> {
        Binding(get: {
            guard let values = bound.values, values.indices.contains(i) else { return [] }
            return values[i]
        }, set: { if bound.values?.indices.contains(i) == true { bound.values?[i] = $0 } })
    }
}

private struct PhysicalTupleEditor: View {
    let title: String
    @Binding var values: [StructurePhysicalValue]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption)
            ForEach(values.indices, id: \.self) { i in
                PhysicalValueEditor(value: Binding(get: { values.indices.contains(i) ? values[i] : .init(kind: "null") }, set: {
                    if values.indices.contains(i) { values[i] = $0 }
                }), ordinal: i + 1) { if values.indices.contains(i) { values.remove(at: i) } }
            }
            Button("Add Tuple Value") { values.append(.init(kind: "integer", value: "0")) }.controlHover().disabled(values.count >= 16)
        }
    }
}

private struct PhysicalValueEditor: View {
    @Binding var value: StructurePhysicalValue
    let ordinal: Int
    let remove: () -> Void
    var body: some View {
        HStack {
            Picker("Value \(ordinal) kind", selection: Binding(get: { value.kind }, set: { kind in
                value = .init(kind: kind, value: ["integer", "text"].contains(kind) ? (kind == "integer" ? "0" : "") : nil)
            })) {
                Text("Exact integer").tag("integer"); Text("Text").tag("text"); Text("SQL NULL").tag("null")
                Text("MINVALUE").tag("min"); Text("MAXVALUE").tag("max")
            }.controlHover()
            if value.value != nil {
                TextField(value.kind == "integer" ? "Exact integer string" : "Exact text (empty and text NULL are preserved)", text: Binding(get: { value.value ?? "" }, set: { value.value = $0 })).textFieldStyle(.roundedBorder)
            }
            ControlIconButton(systemName: "minus.circle", action: remove).accessibilityLabel("Remove tuple value")
        }
    }
}

struct PhysicalObjectInspectionView: View {
    let objects: [StructurePhysicalObject]
    var body: some View {
        ForEach(Array(objects.enumerated()), id: \.offset) { _, object in
            DisclosureGroup(object.target.schema + "." + object.target.table + " · " + object.kind + (object.storageEngine.map { " · " + $0 } ?? "")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fingerprint: " + object.fingerprint).font(.caption).textSelection(.enabled)
                    if let method = object.partitionMethod { Text("Partition method: " + method + " · " + (object.partitionColumns ?? []).joined(separator: ", ")).font(.caption) }
                    ForEach(Array(object.partitions.enumerated()), id: \.offset) { _, partition in
                        Text(partition.name + " · " + partition.method + " · " + partition.description + (partition.detachPending == true ? " · DETACH PENDING — review Finalize explicitly" : "")).textSelection(.enabled)
                    }
                    ForEach(Array(object.indexes.enumerated()), id: \.offset) { _, index in
                        Text(index.name + (index.valid ? " · valid" : " · INVALID — no automatic cleanup") + (index.ready ? " · ready" : " · not ready") + (index.live ? " · live" : " · not live"))
                            .foregroundStyle(index.valid ? Color.primary : Color.orange).textSelection(.enabled)
                    }
                    ForEach(Array(object.limitations.enumerated()), id: \.offset) { _, text in Text(text).font(.caption).appSecondaryText() }
                    if let definition = object.definition { DisclosureGroup("Captured native definition") { Text(definition).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct PhysicalPlanReviewView: View {
    let plan: StructurePhysicalPlan
    var body: some View {
        GroupBox("Exact immutable preview") {
            VStack(alignment: .leading, spacing: 7) {
                Text("Plan: " + plan.id + " · Digest: " + plan.digest).font(.caption).textSelection(.enabled)
                Text("Transaction prerequisite: " + PhysicalOperationLabels.transaction(plan.transactionMode) + " · Expected locking: " + plan.locking).font(.headline)
                ForEach(Array((plan.prerequisites + plan.risks).enumerated()), id: \.offset) { _, warning in Text(warning).foregroundStyle(.orange).textSelection(.enabled) }
                ForEach(Array(plan.consequences.enumerated()), id: \.offset) { _, value in Text(value.object + ": " + value.message).font(.caption).textSelection(.enabled) }
                ForEach(Array(plan.sql.enumerated()), id: \.offset) { i, sql in
                    Text("Statement \(i + 1)\n" + sql).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PhysicalExecutionReviewView: View {
    let report: PhysicalStructureReport
    let elapsed: Int64
    var body: some View {
        GroupBox("Retained execution evidence · " + PhysicalOperationLabels.outcome(report.outcome.state)) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Execution: " + report.id + " · Plan: " + report.plan.id).font(.caption).textSelection(.enabled)
                Text(report.serverEvidence ? "Observed phase: " + PhysicalOperationLabels.phase(report.outcome.phase) + (elapsed > 0 ? " · elapsed \(elapsed) ms" : "") : "Completion unavailable; no final server phase was verified.")
                Text("Acknowledgements describe completed statements. Catalog observations do not prove an unknown write succeeded. No progress percentage is inferred.").font(.caption).appSecondaryText()
                ForEach(Array(report.outcome.steps.enumerated()), id: \.offset) { i, step in
                    Text("Statement \(i + 1): " + PhysicalOperationLabels.step(step.state)).font(.headline)
                    if report.plan.sql.indices.contains(i) { Text(report.plan.sql[i]).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    if let message = step.message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                }
                DisclosureGroup("Exact reviewed plan and original fingerprints") {
                    PhysicalPlanReviewView(plan: report.plan)
                    PhysicalObjectInspectionView(objects: report.plan.objects)
                }
                ForEach(Array((report.outcome.consequences ?? []).enumerated()), id: \.offset) { _, consequence in
                    Text(consequence.object + ": " + consequence.message).font(.caption).textSelection(.enabled)
                }
                if let error = report.outcome.refreshError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                if let observed = report.outcome.observed { PhysicalObjectInspectionView(objects: observed) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

