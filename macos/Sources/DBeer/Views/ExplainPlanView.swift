import SwiftUI

struct ExplainPlanView: View {
    let plan: ExplainPlanModel
    let stale: Bool
    var planLibrary: PlanArtifactsModel? = nil
    var saveTitle = "Execution Plan"
    var canSave: () -> Bool = { true }
    var openLibrary: (() -> Void)? = nil
    var makeTuning: (() -> TuningPanelModel?)? = nil
    var tuningUnavailableReason: String? = nil
    private var tuning = SwiftUI.State<TuningPanelModel?>(initialValue: nil)
    private var saving = SwiftUI.State(initialValue: false)
    private var display = SwiftUI.State(initialValue: ExplainPlanDisplay.tree)
    private var selected = SwiftUI.State<String?>(initialValue: nil)
    private var collapsed = SwiftUI.State(initialValue: Set<String>())
    private var engine: DatabaseEngine { plan.result?.support.engine ?? plan.profile?.engine ?? plan.sourceProfileBinding?.profile.engine ?? .postgresql }
    private var evidenceTitle: String { engine.hasEngineDiagnostics ? "Engine Diagnostics" : "Execution Plan" }
    private struct Row: Identifiable { let node: ExplainNode; let depth: Int; var id: String { node.id } }
    private var rows: [Row] {
        guard let result = plan.result else { return [] }
        let indexed = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.id, $0) })
        var pending = result.roots.reversed().map { ($0, 0) }
        var rows: [Row] = []
        while let (id, depth) = pending.popLast(), let node = indexed[id] {
            rows.append(Row(node: node, depth: depth))
            if !collapsed.wrappedValue.contains(id) { pending.append(contentsOf: node.children.reversed().map { ($0, depth + 1) }) }
        }
        return rows
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(evidenceTitle) · \(plan.request.mode.title(engine: engine))").font(.headline)
                Text(plan.status).foregroundStyle(.secondary)
                Spacer()
                if let planLibrary {
                    Button(engine.hasEngineDiagnostics ? "Save Diagnostic…" : "Save Plan…") { saving.wrappedValue = true }.controlHover()
                        .disabled(plan.result == nil || planLibrary.isBusy || !canSave())
                }
                if let openLibrary { Button("Saved Plans…", action: openLibrary).controlHover().disabled(!canSave()) }
                if let makeTuning {
                    Button("Tuning…") { tuning.wrappedValue = makeTuning() }.controlHover().disabled(stale || tuningUnavailableReason != nil || plan.result == nil || !canSave()).help(tuningUnavailableReason ?? "Open explicit tuning advice, experiments and bounded collection")
                }
                Picker("Plan display", selection: display.projectedValue) {
                    if engine.hasEngineDiagnostics {
                        Text("Diagnostic").tag(ExplainPlanDisplay.tree)
                    } else {
                        Text("Tree").tag(ExplainPlanDisplay.tree)
                        Text("Graph").tag(ExplainPlanDisplay.graph)
                        if engine != .sqlite { Text("Flame").tag(ExplainPlanDisplay.flame) }
                    }
                    Text("Raw Output").tag(ExplainPlanDisplay.raw)
                }.pickerStyle(.segmented).frame(width: engine.hasEngineDiagnostics ? 180 : 300)
            }
            if let profile = plan.sourceProfileBinding?.profile {
                Text("Source: \(profile.name) · \(profile.endpointDescription)").font(.caption).foregroundStyle(.secondary)
            }
            if let profile = plan.profile { Text("Target: \(profile.name) · \(profile.endpointDescription)").font(.caption).foregroundStyle(.secondary) }
            if let evidence = plan.sourceEvidence {
                Text("Original UTF-16 range: \(evidence.rangeLocation)…\(evidence.rangeLocation + evidence.rangeLength) · Captured transaction: \(evidence.transactionStatus ?? "unavailable")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let kind = plan.request.planKind { Text(kind.title).font(.caption).foregroundStyle(.secondary) }
            if let options = plan.request.options { Text(options.summary).font(.caption).foregroundStyle(.secondary) }
            if let parameters = plan.request.parameters {
                DisclosureGroup("Captured Parameters · included when you save or export this plan") {
                    ForEach(parameters, id: \.name) { parameter in
                        Text(":" + parameter.name + " · " + parameter.type.label + " · " + (parameter.value.map { $0.isEmpty ? "Empty string" : $0 } ?? "SQL NULL"))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            DisclosureGroup("Captured Query · included when you save or export this evidence") {
                ScrollView { Text(plan.request.sql).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
            }
            if stale { Label("Earlier query or connection — collect again to refresh", systemImage: "clock.arrow.circlepath").foregroundStyle(.orange) }
            if let dml = plan.dmlOutcome ?? plan.result?.dml { ExplainDMLStatusView(outcome: dml) }
            if let failure = plan.failure { Text(failure.message).foregroundStyle(.red).textSelection(.enabled) }
            if let result = plan.result {
                Text("\(result.support.engine.displayName) \(result.support.serverVersion) · \((result.format ?? result.support.format).uppercased()) · Command completed")
                    .font(.caption).foregroundStyle(.secondary)
                if result.support.engine == .postgresql, result.advancedMetrics != nil {
                    Text("PostgreSQL VERBOSE evidence · output and per-worker details when reported; older captures may lack worker details.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array((result.support.notices ?? []).enumerated()), id: \.offset) { _, notice in
                    Text(notice).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let diagnostic = result.diagnostic { Text(diagnostic).foregroundStyle(.orange).textSelection(.enabled) }
                if let diagnostic = result.engineDiagnostic, display.wrappedValue != .raw {
                    EngineDiagnosticView(diagnostic: diagnostic)
                    if let duration = plan.clientDurationMs {
                        Text("Client elapsed: \(duration.formatted(.number.precision(.fractionLength(2)))) ms · includes transport and diagnostic collection")
                            .font(.caption).appSecondaryText()
                    }
                } else if display.wrappedValue == .raw || result.status != "tree" {
                    ScrollView([.horizontal, .vertical]) {
                        Text(result.raw).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Text(engine == .mongodb ? "Captured canonical BSON evidence · server/session metadata excluded" : engine == .cassandra ? "Bounded trace observation · eventual events may be missing" : result.complete ? "Original captured server output" : "Incomplete captured evidence").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy Raw Output") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.raw, forType: .string) }.controlHover()
                    }
                } else {
                    let ranking = ExplainRanking(result)
                    Text(ranking.basis).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        ForEach(ranking.entries) { entry in
                            Button { reveal(entry.id, in: result) } label: { Label(entry.operation, systemImage: "flame").lineLimit(1) }.controlHover()
                        }
                    }
                    Text(engine == .sqlite ?
                        "SQLite EQP reports strategy and native id/parent/aux/detail fields. It does not report actual row counts, elapsed time or planner cost." :
                        "Inclusive parent and child values overlap. Do not add them; parallel work can exceed wall time.")
                        .font(.caption).foregroundStyle(.secondary)
                    HSplitView {
                        if display.wrappedValue == .graph || display.wrappedValue == .flame {
                            ExplainPlanVisualView(result: result, display: display.wrappedValue, selection: selected.projectedValue).frame(minWidth: 320)
                        } else {
                        ScrollViewReader { proxy in
                        List(selection: selected.projectedValue) {
                            ForEach(rows) { row in
                                HStack(spacing: 4) {
                                    if !row.node.children.isEmpty {
                                        Button { if !collapsed.wrappedValue.insert(row.id).inserted { collapsed.wrappedValue.remove(row.id) } } label: {
                                            Image(systemName: collapsed.wrappedValue.contains(row.id) ? "chevron.right" : "chevron.down")
                                        }.buttonStyle(.plain).accessibilityLabel(collapsed.wrappedValue.contains(row.id) ? "Expand operation" : "Collapse operation")
                                    }
                                    if ranking.entries.contains(where: { $0.id == row.id }) { Image(systemName: "flame").foregroundStyle(.orange) }
                                    Text(row.node.operation).lineLimit(2)
                                    if let badge = ExplainMetricPresentation.rowBadge(row.node) {
                                        Text(badge).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if result.roots.contains(row.id) { Text(engine == .sqlite ? "EQP root" : "Plan total").font(.caption).foregroundStyle(.secondary) }
                                }.padding(.leading, CGFloat(row.depth) * 12).tag(row.id).id(row.id)
                            }
                        }.onChange(of: selected.wrappedValue) { _, id in
                            if let id { proxy.scrollTo(id, anchor: .center) }
                        }
                        }.frame(minWidth: 240)
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                if let node = result.nodes.first(where: { $0.id == selected.wrappedValue }) ?? result.nodes.first {
                                    Text(node.operation).font(.headline)
                                    Text(node.execution == "notExecuted" ? "Not executed" : node.execution.capitalized).foregroundStyle(.secondary)
                                    if result.support.engine != .sqlite { ExplainAdvancedMetricsView(node: node) }
                                    ForEach(node.metrics.keys.sorted(), id: \.self) { key in
                                        Text("\(ExplainMetricPresentation.title(key)): \(ExplainMetricPresentation.label(node.metrics[key]!))").textSelection(.enabled)
                                    }
                                    ForEach(node.details.keys.sorted(), id: \.self) { key in
                                        Text("\(key): \(node.details[key]!)").textSelection(.enabled)
                                    }
                                    Divider()
                                    ForEach(result.metrics.keys.sorted(), id: \.self) { key in
                                        Text("Server \(ExplainMetricPresentation.title(key)): \(ExplainMetricPresentation.label(result.metrics[key]!))").textSelection(.enabled)
                                    }
                                    if let duration = plan.clientDurationMs { Text("Client elapsed: \(duration.formatted(.number.precision(.fractionLength(2)))) ms").foregroundStyle(.secondary) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }.frame(minWidth: 260)
                    }
                }
            } else { Text("Plan evidence will appear after the helper reports completion.").foregroundStyle(.secondary); Spacer() }
        }.padding(10)
            .onChange(of: plan.id) { _, _ in
                selected.wrappedValue = nil
                collapsed.wrappedValue = []
                display.wrappedValue = .tree
            }
            .sheet(item: tuning.projectedValue) { model in
                TuningPanelView(model: model, planLibrary: planLibrary, openLibrary: openLibrary)
            }
            .sheet(isPresented: saving.projectedValue) {
                if let planLibrary {
                    PlanArtifactNameView(title: "Save " + evidenceTitle, initialName: saveTitle) { title, baseline in
                        guard canSave() else { return false }
                        return await planLibrary.save(plan, title: title, baselineName: baseline, sourceWasStale: stale) != nil
                    }
                }
            }
    }
    private func reveal(_ id: String, in result: ExplainResult) {
        var parents: [String: String] = [:]
        for node in result.nodes { for child in node.children { parents[child] = node.id } }
        var current = id
        while let parent = parents[current] { collapsed.wrappedValue.remove(parent); current = parent }
        display.wrappedValue = .tree
        selected.wrappedValue = id
    }
}
