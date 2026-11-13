import SwiftUI

struct MigrationPlanReviewView: View {
    let plan: StructureMigrationPlan
    var body: some View {
        GroupBox("Exact reviewed migration (\(plan.steps.count) execution groups)") {
            VStack(alignment: .leading, spacing: 10) {
                Text("The whole migration is non-atomic. Earlier acknowledged groups survive later failure or Stop. Any proven atomic group is identified separately below.").foregroundStyle(.orange).font(.caption)
                Text("Plan: " + plan.id + "\nDigest: " + plan.digest).font(.caption).textSelection(.enabled)
                ForEach(Array(plan.risks.enumerated()), id: \.offset) { _, risk in Text(risk).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, step in
                    DisclosureGroup("\(i + 1). " + step.phase + " · " + step.target.schema + "." + step.target.table) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Step: " + step.id + "\nObject/repair: " + step.objectId + "\nDigest: " + step.digest).font(.caption).textSelection(.enabled)
                            Text(step.atomic ? "This adapter-proven execution group is atomic. The entire migration is not atomic." : "Statements in this group can commit independently; partial results are retained.").font(.caption).foregroundStyle(.orange)
                            ForEach(Array(step.sql.enumerated()), id: \.offset) { j, sql in
                                Text("Statement \(j + 1)").font(.caption).appSecondaryText()
                                Text(sql).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(Array(step.risks.enumerated()), id: \.offset) { _, risk in Text(risk).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                            ForEach(Array((step.consequences ?? []).enumerated()), id: \.offset) { _, consequence in
                                Text(consequence.object + ": " + consequence.message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                            }
                            DisclosureGroup("Expected structures before this group") { expectations(step.before) }
                            DisclosureGroup("Expected structures after this group") { expectations(step.after) }
                            DisclosureGroup("Exact typed transition") { TableStructureDraftSummary(draft: step.draft) }
                        }.padding(.vertical, 5)
                    }
                }
                DisclosureGroup("Captured starting structures") {
                    ForEach(Array(plan.baselines.enumerated()), id: \.offset) { _, baseline in
                        DisclosureGroup(baseline.target.schema + "." + baseline.target.table) { TableStructureBaselineDetails(baseline: baseline) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func expectations(_ values: [StructureMigrationExpectation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Each expectation preserves the captured identity and unmodified facts, then applies exactly the preceding reviewed typed transitions. Fingerprints after execution are observed, never predicted.").font(.caption).appSecondaryText()
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                expectationRow(value)
            }
        }
    }
    private func expectationRow(_ value: StructureMigrationExpectation) -> some View {
        let target: String = value.target.schema + "." + value.target.table
        let steps: String = value.afterSteps.isEmpty ? "none" : value.afterSteps.joined(separator: ", ")
        let lines: [String] = [target, "Captured fingerprint: " + value.initialFingerprint,
            "Identity: " + value.identityDigest, "After exact steps: " + steps]
        return Text(lines.joined(separator: "\n")).font(.caption).textSelection(.enabled)
    }
}

struct MigrationExecutionReportView: View {
    let report: MigrationExecutionDocument
    var body: some View {
        GroupBox("Migration execution: " + report.outcome.state) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Execution: " + report.outcome.executionId).font(.caption).textSelection(.enabled)
                Text(report.outcome.reconciliationRequired ? "Reconciliation is required before any new migration review. Failed and unstarted intent remains retained; no SQL is replayed automatically." : "Current structures were reconciled explicitly. This historical execution report grants no replay authority.")
                    .font(.caption).foregroundStyle(.orange)
                ForEach(Array(report.outcome.steps.enumerated()), id: \.offset) { i, step in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Group \(i + 1): " + step.id + " · " + step.state).font(.headline).textSelection(.enabled)
                        if let message = step.message { Text(message).font(.caption).textSelection(.enabled) }
                        ForEach(Array(step.statements.enumerated()), id: \.offset) { j, statement in
                            Text("Statement \(j + 1): " + statement.state + (statement.message.map { " · " + $0 } ?? "")).font(.caption).textSelection(.enabled)
                        }
                        ForEach(Array((step.observed ?? []).enumerated()), id: \.offset) { _, baseline in
                            Text("Observed " + baseline.target.schema + "." + baseline.target.table + "\nFingerprint: " + baseline.fingerprint + "\nIdentity: " + baseline.identityDigest).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                DisclosureGroup("Immutable reviewed plan and original selection") { MigrationPlanReviewView(plan: report.plan) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
