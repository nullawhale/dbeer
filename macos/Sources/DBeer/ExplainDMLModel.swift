import Foundation

/// The helper classifies SQL. This filter only decides when native selection
/// must obtain that classification before constructing a write intent.
enum ExplainDMLAdmission {
    static func possibleDML(_ sql: String, engine: DatabaseEngine) -> Bool {
        guard [.postgresql, .mysql, .mariadb, .sqlite].contains(engine) else { return false }
        let source = sql as NSString
        let words = SQLScriptParser.parse(sql, engine: engine).tokens.filter { $0.kind == .keyword }
            .map { source.substring(with: $0.range).uppercased() }
        guard let first = words.first else { return false }
        return ["INSERT", "UPDATE", "DELETE"].contains(first) || first == "WITH" && words.contains { ["INSERT", "UPDATE", "DELETE"].contains($0) }
    }

    static func validOwner(support: ExplainSupport?, engine: DatabaseEngine?, capabilities: Set<String>, helperSupports: Bool) -> Bool {
        guard helperSupports, capabilities.contains(ExplainDMLSupport.capability), let support,
              support.valid, support.engine == engine, support.dml?.valid(engine: support.engine) == true else { return false }
        return true
    }

    static func accepts(_ target: ExplainDMLTarget, support: ExplainSupport, mode: ExplainMode) -> Bool {
        support.valid && support.modes.contains(mode) && target.valid(engine: support.engine) && support.dml?.valid(engine: support.engine) == true &&
            (mode == .plan ? support.dml?.permitsEstimated(target.analyzeForm, engine: support.engine) == true : support.dml?.analyze.contains(target.analyzeForm) == true)
    }

    /// Called while the physical owner's capabilities still exist. A typed
    /// error never grants authority to a different request or retired session.
    static func accepts(_ outcome: ExplainDMLResult, request: ExplainRequest, support: ExplainSupport,
                        transactionStatus: TransactionStatus?, connected: Bool? = nil, sqlCompleted: Bool?, outcomeUnknown: Bool?, sqlNotExecuted: Bool?) -> Bool {
        guard accepts(outcome.target, support: support, mode: request.mode), outcome.valid(engine: support.engine, mode: request.mode) else { return false }
        if request.mode == .plan { return request.writeIntent == nil && outcome.execution == "estimated" && sqlCompleted == true && outcomeUnknown != true }
        guard let intent = request.writeIntent, intent.valid, request.context?.transactionStatus == intent.expectedTransactionStatus,
              outcome.transactionBefore == intent.expectedTransactionStatus,
              (outcome.transactionAfter == "unknown" ? transactionStatus == nil : transactionStatus?.rawValue == outcome.transactionAfter || connected == false && transactionStatus == nil) else { return false }
        switch outcome.execution {
        case "completed": return sqlCompleted == true && sqlNotExecuted != true && (outcomeUnknown == true) ==
            (outcome.persistence == "unknown" || outcome.targetExecution == "suppressed" && outcome.transactionAfter == "unknown")
        case "notExecuted": return sqlNotExecuted == true && sqlCompleted != true && outcomeUnknown != true
        case "failed": return sqlCompleted != true && sqlNotExecuted != true
        case "unknown": return sqlCompleted != true && sqlNotExecuted != true && outcomeUnknown == true
        default: return false
        }
    }
}

extension ExplainDMLResult {
    var executionLabel: String {
        switch execution {
        case "estimated": "Estimated plan — outer DML was not executed"
        case "completed": targetExecution == "suppressed" ? "Diagnostic completed — target rows were not applied" : "SQL execution completed"
        case "failed": "SQL execution failed — effects may remain"
        case "notExecuted": "SQL was not executed"
        default: "SQL execution outcome unknown — not repeated"
        }
    }
    var persistenceLabel: String {
        switch persistence {
        case "committed": "Commit acknowledged"
        case "transactionPending": "At acknowledgement, target changes were uncommitted in the captured transaction"
        case "notExecuted": targetExecution == "suppressed" ? "Target row changes were suppressed; this does not exclude routine or external effects" : "Outer DML was not executed"
        default: "Persistence unknown — check the database before taking further action"
        }
    }
    var targetExecutionLabel: String {
        switch targetExecution {
        case "executed": "Target DML executed"
        case "suppressed": "Target row changes suppressed by the server diagnostic"
        case "notExecuted": "Target DML not executed"
        default: "Target DML execution unknown"
        }
    }
    static let transactionAvailabilityCaveat = "Historical AFTER state does not establish that the original physical session is still available."
    static let suppressedEffectsCaveat = "MySQL runs diagnostic iterators without applying target UPDATE or DELETE rows. WHERE expressions, routines, locks and external effects may still occur. DBeer does not automatically roll back, retry or rerun this diagnostic."
    static let effectsCaveat = "Sequences, nontransactional tables, triggers and external effects can persist independently of a transaction. DBeer does not automatically roll back, retry or rerun this statement."
    var affectedRowsLabel: String { affectedRowsUnavailableReason == "notExecuted" ? "Affected rows unavailable — not executed" : "Affected rows unavailable — server did not report a reliable DML count" }
}

extension ExplainRequest {
    var exactBindingData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}
