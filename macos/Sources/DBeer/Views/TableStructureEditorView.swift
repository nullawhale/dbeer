import SwiftUI

struct TableStructureEditorView: View {
    @ObservedObject var model: TableStructureEditorModel
    let close: () -> Void
    var saveEvidence: (() -> Void)? = nil
    var evidenceModel: SavedEvidenceModel? = nil
    private var confirmClose = SwiftUI.State(initialValue: false)
    private var canEdit: Bool { !model.isBusy && !model.closing && !model.invalidated && model.baseline != nil && model.outcome == nil }
    private var canEditTarget: Bool { model.create && !model.isBusy && !model.closing && !model.invalidated && model.baseline == nil && model.outcome == nil }
    private var canLoad: Bool {
        !model.isBusy && !model.closing && !model.invalidated && model.target.valid &&
            !(model.outcome == nil && model.baseline != nil && model.hasDraft)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.create ? "Create Table" : "Edit Structure").font(.title2)
                Spacer()
                Text(model.profile.name + " · " + model.profile.policy.label).appSecondaryText()
            }
            HStack {
                Text("Schema/database: " + model.schema).font(.caption).textSelection(.enabled)
                TextField("Exact table name", text: Binding(get: { model.table }, set: {
                    guard canEditTarget else { return }; model.table = $0
                })).textFieldStyle(.roundedBorder).disabled(!canEditTarget)
                Button(model.outcome != nil ? "Reconcile" : model.baseline == nil ? "Load Structure" : "Reload Structure") {
                    guard canLoad else { return }; Task { await model.load() }
                }.controlHover().disabled(!canLoad)
                    .help("Read the current structure. Discard unapplied edits before reloading; reconciliation never retries DDL.")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Prepare local column, index and key changes. Preview reads metadata and shows the complete SQL; only Apply executes the reviewed plan.")
                        .font(.caption).appSecondaryText()
                    if let baseline = model.baseline {
                        DisclosureGroup("Current loaded structure") { TableStructureBaselineDetails(baseline: baseline) }
                    }
                    if model.outcome == nil {
                        draftEditors
                    }
                    if let preview = model.preview {
                        GroupBox("Reviewed SQL (\(preview.sql.count) steps)") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(preview.sql.enumerated()), id: \.offset) { i, sql in
                                    Text("Step \(i + 1)").font(.caption).appSecondaryText()
                                    ScrollView([.horizontal, .vertical]) {
                                        Text(sql).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.frame(minHeight: 35, maxHeight: 140)
                                }
                                ForEach(Array(preview.risks.enumerated()), id: \.offset) { _, risk in
                                    Text(risk).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let review = model.outcomeReview {
                        if let saveEvidence {
                            Button("Save Outcome Evidence", action: saveEvidence).controlHover().disabled(model.closing || evidenceModel?.isBusy == true)
                                .help("Save the retained reviewed SQL, intended changes and step outcome as immutable local evidence.")
                        }
                        if let evidenceModel { SavedEvidenceStatusView(model: evidenceModel) }
                        TableStructureExecutionReportView(review: review)
                    } else if let outcome = model.outcome {
                        legacyOutcome(outcome)
                    }
                    history
                    if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 220, idealHeight: 420, maxHeight: 580)
            footer
        }.padding(20).frame(width: 850).frame(minHeight: 400, idealHeight: 640, maxHeight: 800)
        .interactiveDismissDisabled()
        .confirmationDialog("Close this structure draft? Unapplied edits will be discarded. Applied changes remain in the database; an unknown outcome requires reconciliation. Reviewed SQL, intended changes and execution evidence remain available when you reopen this table during this workspace session.", isPresented: confirmClose.projectedValue) {
            Button("Discard Draft and Close", role: .destructive) { if !model.isBusy && !model.closing { close() } }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    private var draftEditors: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.draft.columns.indices, id: \.self) { i in
                TableStructureNewColumnEditor(column: columnBinding(i), number: i + 1, engine: model.profile.engine,
                    create: model.create, canRemove: !model.create || model.draft.columns.count > 1) {
                    guard canEdit, model.draft.columns.indices.contains(i) else { return }
                    model.draft.columns.remove(at: i)
                    if model.draft.destructive { model.draft.allowDestructive = nil }
                }
            }
            if model.create {
                Button("Add Column") {
                    guard canEdit, model.draft.columns.count < 128 else { return }
                    model.draft.columns.append(TableStructureEditorModel.emptyColumn)
                }.controlHover().disabled(!canEdit || model.draft.columns.count >= 128)
            }
            TableStructureIntentEditors(model: model)
        }.disabled(!canEdit)
    }
    private var history: some View {
        Group {
            if !model.historyReviews.isEmpty || !model.history.isEmpty {
                DisclosureGroup("Previous execution evidence (retained for this workspace session)") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.historyReviews) { review in
                            DisclosureGroup(review.outcome.state + " · " + review.plan.target.schema + " · " + review.plan.target.table) {
                                if let saveEvidence {
                            Button("Save Outcome Evidence", action: saveEvidence).controlHover().disabled(model.closing || evidenceModel?.isBusy == true)
                                .help("Save the retained reviewed SQL, intended changes and step outcome as immutable local evidence.")
                        }
                        if let evidenceModel { SavedEvidenceStatusView(model: evidenceModel) }
                        TableStructureExecutionReportView(review: review)
                            }
                        }
                        ForEach(Array(model.history.filter { outcome in !model.historyReviews.contains { $0.id == outcome.executionId } }.enumerated()), id: \.offset) { _, report in
                            legacyOutcome(report)
                        }
                    }
                }
            }
        }
    }
    private var footer: some View {
        HStack {
            Button("Discard") { if canEdit { model.discard() } }.controlHover().disabled(!canEdit)
            Spacer()
            if model.isBusy {
                ProgressView().controlSize(.small)
                Button("Stop") { if !model.closing { Task { await model.stop() } } }.controlHover().disabled(model.closing)
            }
            Button("Preview SQL") { Task { await model.preparePreview() } }.controlHover().disabled(!model.canPreview || model.closing)
            Button("Apply") { Task { await model.apply() } }.controlHover().disabled(!model.canApply || model.closing)
            Button("Close") {
                guard !model.isBusy && !model.closing else { return }
                if model.outcome == nil && model.hasDraft || ["outcomeUnknown", "partiallyApplied"].contains(model.outcome?.state ?? "") {
                    confirmClose.wrappedValue = true
                } else { close() }
            }.controlHover().disabled(model.isBusy || model.closing).keyboardShortcut(.cancelAction)
        }
    }
    private func columnBinding(_ i: Int) -> Binding<StructureColumn> {
        Binding(get: { model.draft.columns.indices.contains(i) ? model.draft.columns[i] : TableStructureEditorModel.emptyColumn }, set: {
            guard canEdit, model.draft.columns.indices.contains(i) else { return }
            model.draft.columns[i] = $0
            if model.draft.destructive { model.draft.allowDestructive = nil }
        })
    }
    private func legacyOutcome(_ outcome: StructureOutcome) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Execution: " + outcome.state).font(.headline).textSelection(.enabled)
            ForEach(Array(outcome.steps.enumerated()), id: \.offset) { i, step in
                Text("Step \(i + 1): " + step.state + (step.message.map { " · " + $0 } ?? "")).textSelection(.enabled)
            }
            Text("Reviewed SQL and intended edits are unavailable for this earlier report.").font(.caption).appSecondaryText()
            if let error = outcome.refreshError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let observed = outcome.observed { TableStructureBaselineDetails(baseline: observed) }
        }
    }
}
