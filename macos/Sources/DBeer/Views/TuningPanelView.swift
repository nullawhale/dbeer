import SwiftUI

struct TuningPanelView: View {
    @ObservedObject var model: TuningPanelModel
    let planLibrary: PlanArtifactsModel?
    let openLibrary: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    private var schema = SwiftUI.State(initialValue: "")
    private var table = SwiftUI.State(initialValue: "")
    private var workMem = SwiftUI.State(initialValue: 8_192)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tuning · captured evidence and explicit experiments").font(.headline)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).controlHover()
            }
            Text(model.status).foregroundStyle(.secondary).textSelection(.enabled)
            if let reason = model.currentReason { Text(reason).foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sourceSection
                    inspectionSection
                    settingsSection
                    collectorSection
                    GroupBox("Saved baseline comparison · offline") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Save captures to the plan library and compare existing baselines. Comparisons require exact engine/version/format, SQL, typed bindings, options and scope. Duplicate structural paths and partial, parallel, logical or incompatible loop measurements stay unavailable. Comparison never connects or recaptures.")
                            if let openLibrary { Button("Compare Saved Plans…") { dismiss(); openLibrary() }.controlHover() }
                        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(2)
            }
        }.padding(16).frame(minWidth: 720, idealWidth: 850, minHeight: 650, idealHeight: 820)
            .onDisappear { Task { await model.close() } }
    }
    private var sourceSection: some View {
        GroupBox("Original source · retained unchanged") {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.plan.request.sql).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if let parameters = model.plan.request.parameters {
                    DisclosureGroup("Exact captured typed values") {
                        ForEach(parameters, id: \.name) { parameter in
                            Text(":" + parameter.name + " · " + parameter.type.label + " · " + (parameter.value.map { $0.isEmpty ? "Empty string" : $0 } ?? "SQL NULL"))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
                if let options = model.plan.request.options { Text(options.summary).font(.caption) }
                Text("Advice uses supplied capture evidence and fresh metadata. It does not establish equivalence or predict performance gains.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var inspectionSection: some View {
        GroupBox("Inspect one ordinary table · index advice and query candidates") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Schema / database", text: schema.projectedValue)
                    TextField("Table", text: table.projectedValue)
                    Button("Inspect Metadata") { Task { await model.inspect(schema: schema.wrappedValue, table: table.wrappedValue) } }
                        .disabled(model.isBusy || model.inspectReason != nil).controlHover()
                }
                if let reason = model.inspectReason { Text(reason).font(.caption).foregroundStyle(.orange) }
                if let inspection = model.inspection {
                    ForEach(inspection.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    ForEach(inspection.indexes, id: \.id) { advice in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(advice.explanation).fontWeight(.medium)
                            ForEach(advice.evidence + advice.limitations, id: \.self) { Text($0).font(.caption) }
                            Button("Open New Structure Draft for Review…") {
                                dismiss()
                                Task { await model.openIndex(advice) }
                            }.disabled(model.isBusy || model.inspectReason != nil).controlHover()
                            Text("A new dedicated editor loads a fresh baseline. Preview and exact reviewed Apply remain separate actions.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(inspection.variants, id: \.id) { variant in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("UNVALIDATED CANDIDATE · " + variant.explanation).fontWeight(.medium)
                            Text(variant.request.sql).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text("This candidate is separate from the original document. Paired validation observes exact native-value bags in two sequential reads; it does not prove equivalence, ordering or speed.").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Review Bounded Result Validation…") { Task { await model.validate(variant) } }.controlHover()
                                Button("Adopt Candidate in New SQL Tab") { model.adoptVariant(variant) }.controlHover()
                            }.disabled(model.isBusy || model.inspectReason != nil)
                        }
                    }
                    if let validation = model.validation {
                        Text(validation.state == "observedEqual" ? "Observed equal native-value bags" : validation.state == "observedDifferent" ? "Observed different native-value bags" : "Inconclusive — no equality established").fontWeight(.medium)
                        Text("\(validation.originalRows) original / \(validation.variantRows) candidate rows · \(validation.comparedBytes) encoded bytes · sequential current-session observation").font(.caption)
                        ForEach(validation.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var settingsSection: some View {
        GroupBox("PostgreSQL work_mem · existing transaction only") {
            VStack(alignment: .leading, spacing: 7) {
                Text("Observe uses fixed SHOW work_mem inside your existing transaction. Changes use SET LOCAL. Commit/rollback ends the local value; an earlier savepoint rollback may revert it. Memory applies per operation and worker. No transaction is started, committed or restored automatically.").font(.caption).foregroundStyle(.secondary)
                if let reason = model.settingChangeReason { Text(reason).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Observe Current Value") { Task { await model.observeSetting() } }.controlHover()
                    if let observed = model.settingObservation { Text("\(observed.workMemKiB) KiB").font(.caption) }
                    TextField("Desired KiB", value: workMem.projectedValue, format: .number).frame(width: 120)
                    Button("Review SET LOCAL…") { Task { await model.setWorkMem(workMem.wrappedValue) } }.controlHover().disabled(model.settingObservation == nil || model.settingChangeReason != nil)
                    if model.settingResult != nil {
                        Button("Review Separate Restore…") { Task { await model.setWorkMem(0, restoring: true) } }.controlHover().disabled(model.settingObservation == nil || model.settingChangeReason != nil)
                    }
                }.disabled(model.isBusy || model.settingReason != nil)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var collectorSection: some View {
        TuningCollectorView(model: model, planLibrary: planLibrary)
    }
}

private struct TuningCollectorView: View {
    @ObservedObject var model: TuningPanelModel
    @ObservedObject private var collector: ExplainCollector
    let planLibrary: PlanArtifactsModel?
    private var status = SwiftUI.State(initialValue: "")
    init(model: TuningPanelModel, planLibrary: PlanArtifactsModel?) {
        self.model = model; self.collector = model.collector; self.planLibrary = planLibrary
    }
    var body: some View {
        GroupBox("Opt-in bounded background collection · estimated read plans") {
            VStack(alignment: .leading, spacing: 8) {
                Text(collector.status).fontWeight(.medium)
                Text("Start binds this unchanged SQL, exact typed values/options, profile and current physical idle owner. Every capture receives a fresh current allow assessment. Edits, another SQL operation, policy/owner changes, Stop or teardown end the run. Restoration is always stopped and disconnected.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Stepper("Every \(model.configuration.intervalSeconds)s", value: $model.configuration.intervalSeconds, in: 30...3_600, step: 30)
                    Stepper("At most \(model.configuration.maximumCaptures) captures", value: $model.configuration.maximumCaptures, in: 1...100)
                }.disabled(collector.running)
                HStack {
                    Stepper("Runtime \(model.configuration.maximumRuntimeSeconds)s", value: $model.configuration.maximumRuntimeSeconds, in: 30...3_600, step: 30)
                    Stepper("Retain \(model.configuration.retentionDays) days", value: $model.configuration.retentionDays, in: 1...30)
                }.disabled(collector.running)
                Picker("Storage per document", selection: $model.configuration.maximumStorageBytes) {
                    ForEach([1, 4, 8, 16, 32], id: \.self) { value in Text("\(value) MiB").tag(value * 1_024 * 1_024) }
                }.frame(maxWidth: 280).disabled(collector.running)
                HStack {
                    Button("Start Collection Explicitly") { model.startCollection() }.controlHover()
                        .disabled(collector.running || model.isBusy || model.collectorReason != nil)
                    Button("Stop Collection") { collector.stop("Stopped explicitly") }.controlHover().disabled(!collector.running)
                    if let planLibrary, let latest = collector.captures.first {
                        Button("Save Latest to Plan Library") {
                            Task {
                                do {
                                    let artifact = try await collector.store.load(latest.id)
                                    let saved = await planLibrary.save(artifact.displayPlan, title: artifact.title, baselineName: nil)
                                    status.wrappedValue = saved == nil ? "The plan could not be saved." : "Saved offline evidence to the plan library."
                                } catch { status.wrappedValue = error.localizedDescription }
                            }
                        }.controlHover().disabled(planLibrary.isBusy)
                    }
                }
                if let reason = model.collectorReason { Text(reason).font(.caption).foregroundStyle(.orange) }
                Text("\(collector.captures.count) retained captures. Count, bytes and age are pruned at explicit Start and capture; expiry does not run after shutdown.").font(.caption).foregroundStyle(.secondary)
                if !status.wrappedValue.isEmpty { Text(status.wrappedValue).font(.caption) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.task { await collector.refreshEvidence() }
    }
}
