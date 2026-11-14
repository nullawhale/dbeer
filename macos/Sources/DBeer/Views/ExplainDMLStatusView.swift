import SwiftUI

struct ExplainDMLStatusView: View {
    let outcome: ExplainDMLResult
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(outcome.executionLabel).font(.callout).bold()
            Text(outcome.targetExecutionLabel).font(.caption)
            Text(outcome.persistenceLabel).font(.callout)
            if outcome.persistence == "transactionPending" {
                Text(ExplainDMLResult.transactionAvailabilityCaveat).font(.caption)
            }
            if !outcome.transactionBefore.isEmpty {
                Text("Transaction: \(outcome.transactionBefore) → \(outcome.transactionAfter)").font(.caption)
            }
            Text(outcome.affectedRowsLabel).font(.caption)
            if outcome.execution == "estimated" {
                Text("Planning may run stored functions or other server routines. Their effects remain subject to the exact operation review and database privileges.").font(.caption)
            } else if outcome.execution != "notExecuted" {
                Text(outcome.targetExecution == "suppressed" ? ExplainDMLResult.suppressedEffectsCaveat : ExplainDMLResult.effectsCaveat).font(.caption)
            }
        }.foregroundStyle(outcome.persistence == "unknown" ? .orange : .secondary).textSelection(.enabled)
    }
}
