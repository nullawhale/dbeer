import SwiftUI

struct ExplainBatchResultsView: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var workspace: ApplicationWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Statement result", selection: $document.selectedExplainExecution) {
                ForEach(document.explainExecutions.indices, id: \.self) { index in
                    let execution = document.explainExecutions[index]
                    Text("\(index + 1). Line \(execution.statement.line) · \(execution.statement.action == .plan ? execution.plan?.request.mode.title(engine: execution.targetProfile?.engine ?? .postgresql) ?? "Plan" : "Setup") · \(execution.status)")
                        .tag(index)
                }
            }.padding(.horizontal, 10).controlHover()
            if document.explainExecutions.indices.contains(document.selectedExplainExecution) {
                let execution = document.explainExecutions[document.selectedExplainExecution]
                if let plan = execution.plan {
                    let sourceProfile = workspace.library.savedConnections.first { $0.id == document.profileID }
                    let targetProfile = workspace.library.savedConnections.first { $0.id == plan.profileID }
                    ExplainPlanView(plan: plan,
                        stale: plan.isStaleSource(text: document.text, profileID: document.profileID, profile: sourceProfile) ||
                            plan.profileBinding?.matches(targetProfile) == false,
                        planLibrary: workspace.planArtifacts, saveTitle: document.title,
                        canSave: { workspace.canManageWorkspace }, openLibrary: { workspace.isPlansPresented = true }).id(plan.id)
                } else {
                    Text(execution.status).font(.headline)
                    if let profile = execution.targetProfile {
                        Text("Target: \(profile.name) · \(profile.endpointDescription)").font(.caption).appSecondaryText()
                    }
                    if let context = execution.context {
                        Text("Original UTF-16 range: \(context.rangeLocation)…\(context.rangeLocation + context.rangeLength) · Captured transaction: \(context.transactionStatus)")
                            .font(.caption).appSecondaryText()
                    }
                    if let failure = execution.failure {
                        Text(failure.message).foregroundStyle(.red).textSelection(.enabled)
                        if let state = failure.sqlState { Text("SQLSTATE: " + state).font(.caption).appSecondaryText() }
                        Text(failure.outcomeUnknown ? "SQL outcome is unknown. This operation was not repeated." :
                            failure.sqlNotExecuted ? "SQL was not executed." : "The server reported a failed operation.")
                            .font(.caption).appSecondaryText()
                    }
                    if execution.failure == nil, let result = execution.result, result.type == "query.result", result.outcomeUnknown != true {
                        Text(result.commandTag ?? "SQL completed").font(.caption).appSecondaryText()
                    }
                    Text(execution.statement.sql).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                }
            }
        }
    }
}
