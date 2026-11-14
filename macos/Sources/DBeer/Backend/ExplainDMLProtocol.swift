import Foundation

/// Process-local authority to execute once in the tab's current physical session.
struct ExplainWriteIntent: Codable, Sendable, Equatable {
    var disposition: String = "currentSession"
    var expectedTransactionStatus: String
    var valid: Bool { disposition == "currentSession" && ["idle", "transaction"].contains(expectedTransactionStatus) }
    private enum CodingKeys: String, CodingKey { case disposition, expectedTransactionStatus }
    init(disposition: String = "currentSession", expectedTransactionStatus: String) {
        self.disposition = disposition
        self.expectedTransactionStatus = expectedTransactionStatus
    }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["disposition", "expectedTransactionStatus"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        disposition = try fields.decode(String.self, forKey: .disposition)
        expectedTransactionStatus = try fields.decode(String.self, forKey: .expectedTransactionStatus)
        guard valid else { throw invalidExplainDML(decoder) }
    }
}
struct ExplainDMLSupport: Codable, Sendable, Equatable {
    static let capability = "explainDMLV1"
    var estimated: Bool
    var analyze: [String]
    var analyzeTargetExecution: String
    private enum CodingKeys: String, CodingKey { case estimated, analyze, analyzeTargetExecution }
    func valid(engine: DatabaseEngine) -> Bool {
        let allowed: Set<String> = engine == .postgresql ? ["insert", "update", "delete", "dataModifyingCTE"] : engine == .mysql ? ["mysqlMultiTableUpdate", "mysqlMultiTableDelete"] : []
        let expected = analyze.isEmpty ? "unavailable" : engine == .postgresql ? "executes" : "suppresses"
        return analyzeTargetExecution == expected && [.postgresql, .mysql, .sqlite].contains(engine) && estimated && analyze.count <= 4 &&
            Set(analyze).count == analyze.count && Set(analyze).isSubset(of: allowed)
    }
    init(estimated: Bool = true, analyze: [String], analyzeTargetExecution: String) { self.estimated = estimated; self.analyze = analyze; self.analyzeTargetExecution = analyzeTargetExecution }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["estimated", "analyze", "analyzeTargetExecution"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        estimated = try fields.decode(Bool.self, forKey: .estimated)
        analyze = try fields.decode([String].self, forKey: .analyze)
        analyzeTargetExecution = try fields.decode(String.self, forKey: .analyzeTargetExecution)
    }
}
struct ExplainDMLTarget: Codable, Sendable, Equatable {
    var statement: String
    var dataModifyingCTE: Bool
    var mysqlMultiTable: Bool
    private enum CodingKeys: String, CodingKey { case statement, dataModifyingCTE, mysqlMultiTable }
    var analyzeForm: String {
        if dataModifyingCTE { return "dataModifyingCTE" }
        if mysqlMultiTable { return statement == "update" ? "mysqlMultiTableUpdate" : "mysqlMultiTableDelete" }
        return statement
    }
    func valid(engine: DatabaseEngine) -> Bool {
        [.postgresql, .mysql, .sqlite].contains(engine) &&
        (["insert", "update", "delete"].contains(statement) || statement == "select" && dataModifyingCTE) &&
        (!dataModifyingCTE || engine == .postgresql) &&
        (!mysqlMultiTable || engine == .mysql && ["update", "delete"].contains(statement))
    }
    init(statement: String, dataModifyingCTE: Bool = false, mysqlMultiTable: Bool = false) {
        self.statement = statement; self.dataModifyingCTE = dataModifyingCTE; self.mysqlMultiTable = mysqlMultiTable
    }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["statement", "dataModifyingCTE", "mysqlMultiTable"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        statement = try fields.decode(String.self, forKey: .statement)
        dataModifyingCTE = try fields.decode(Bool.self, forKey: .dataModifyingCTE)
        mysqlMultiTable = try fields.decode(Bool.self, forKey: .mysqlMultiTable)
    }
}
struct ExplainDMLResult: Codable, Sendable, Equatable {
    var target: ExplainDMLTarget
    var execution: String
    var persistence: String
    var transactionBefore: String
    var transactionAfter: String
    var affectedRowsUnavailableReason: String
    var targetExecution: String
    private enum CodingKeys: String, CodingKey { case target, execution, persistence, transactionBefore, transactionAfter, affectedRowsUnavailableReason, targetExecution }
    func valid(engine: DatabaseEngine, mode: ExplainMode) -> Bool {
        guard target.valid(engine: engine) else { return false }
        if execution == "estimated" {
            return mode == .plan && targetExecution == "notExecuted" && persistence == "notExecuted" && transactionBefore.isEmpty && transactionAfter.isEmpty && affectedRowsUnavailableReason == "notExecuted"
        }
        guard mode == .analyze, engine != .sqlite, ["idle", "transaction"].contains(transactionBefore),
              ["idle", "transaction", "failedTransaction", "unknown"].contains(transactionAfter) else { return false }
        switch execution {
        case "notExecuted": return targetExecution == "notExecuted" && persistence == "notExecuted" && affectedRowsUnavailableReason == "notExecuted"
        case "completed":
            if engine == .mysql { return targetExecution == "suppressed" && persistence == "notExecuted" && affectedRowsUnavailableReason == "notReported" }
            return targetExecution == "executed" && affectedRowsUnavailableReason == "notReported" &&
            (persistence == "committed" && transactionAfter == "idle" || persistence == "transactionPending" && transactionAfter == "transaction" || persistence == "unknown")
        case "failed", "unknown": return targetExecution == "unknown" && persistence == "unknown" && affectedRowsUnavailableReason == "notReported"
        default: return false
        }
    }
    init(target: ExplainDMLTarget, execution: String, persistence: String, transactionBefore: String, transactionAfter: String, affectedRowsUnavailableReason: String, targetExecution: String) {
        self.target = target; self.execution = execution; self.persistence = persistence
        self.transactionBefore = transactionBefore; self.transactionAfter = transactionAfter
        self.affectedRowsUnavailableReason = affectedRowsUnavailableReason
        self.targetExecution = targetExecution
    }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["target", "execution", "persistence", "transactionBefore", "transactionAfter", "affectedRowsUnavailableReason", "targetExecution"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        target = try fields.decode(ExplainDMLTarget.self, forKey: .target)
        execution = try fields.decode(String.self, forKey: .execution)
        persistence = try fields.decode(String.self, forKey: .persistence)
        transactionBefore = try fields.decode(String.self, forKey: .transactionBefore)
        transactionAfter = try fields.decode(String.self, forKey: .transactionAfter)
        affectedRowsUnavailableReason = try fields.decode(String.self, forKey: .affectedRowsUnavailableReason)
        targetExecution = try fields.decode(String.self, forKey: .targetExecution)
    }
}
private func invalidExplainDML(_ decoder: Decoder) -> DecodingError {
    .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid DML Explain intent."))
}
