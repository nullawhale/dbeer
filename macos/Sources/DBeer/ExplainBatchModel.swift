import Foundation

/// Choices are captured from the original editor. Merely finding a setup
/// statement never authorizes running it.
struct ExplainBatchStatement: Identifiable, Equatable, Sendable {
    enum Action: String, Sendable { case plan, execute }
    var id: Int { range.location }
    let sql: String
    let range: NSRange
    let action: Action
    let line: Int
    let selectedByDefault: Bool

    static func candidates(text: String, selections: [NSRange], engine: DatabaseEngine) throws -> [Self] {
        let length = text.utf16.count
        guard selections.allSatisfy({ $0.location >= 0 && $0.location <= length &&
            $0.length >= 0 && $0.length <= length - $0.location }) else {
            throw ExecutionPolicyError(message: "The editor selections are no longer valid.")
        }
        let parsed = SQLScriptParser.parse(text, engine: engine)
        let fragments = selections.compactMap { SQLExecutionFragment.resolve(text: text, selection: $0, engine: engine) }
        if let diagnostic = fragments.compactMap(\.diagnostic).first {
            throw ExecutionPolicyError(message: diagnostic.message)
        }
        let selected = fragments.flatMap(\.statements)
        if selected.isEmpty, let diagnostic = parsed.diagnostics.first {
            throw ExecutionPolicyError(message: diagnostic.message)
        }
        guard parsed.statements.count <= 256 || !selected.isEmpty else {
            throw ExecutionPolicyError(message: "Choose a script with no more than 256 statements for Explain.")
        }
        // Incomplete text elsewhere in the editor must not prevent explaining
        // a valid selection. Whole-script candidates require a complete parse.
        let wholeScript = parsed.diagnostics.isEmpty && parsed.statements.count <= 256 ? parsed.statements : []
        let chosen = selected.map(\.range)
        var statements = selected
        statements.append(contentsOf: wholeScript.filter { whole in
            !chosen.contains { NSIntersectionRange($0, whole.range).length > 0 }
        })
        var seen = Set<Int>()
        statements = statements.filter { seen.insert($0.range.location).inserted }.sorted { $0.range.location < $1.range.location }
        guard statements.count <= 256 else { throw ExecutionPolicyError(message: "Choose no more than 256 statements for Explain.") }
        return statements.map { statement in
            let fragment = SQLExecutionFragment(kind: .statement, sourceSQL: statement.sql, range: statement.range,
                statements: [statement], diagnostic: nil, firstLine: 1, lastLine: 1)
            let action: Action = (try? ExplainPlanModel.request(fragment: fragment, mode: engine == .cassandra ? .analyze : .plan, engine: engine)) == nil ? .execute : .plan
            let prefix = (text as NSString).substring(to: statement.range.location)
            return Self(sql: statement.sql, range: statement.range, action: action,
                line: 1 + prefix.utf16.filter { $0 == 10 }.count,
                selectedByDefault: action == .plan && chosen.contains(statement.range))
        }
    }

    func matches(_ text: String) -> Bool {
        range.location >= 0 && range.length == sql.utf16.count && range.location <= text.utf16.count &&
            range.length <= text.utf16.count - range.location &&
            sql.utf8.elementsEqual((text as NSString).substring(with: range).utf8)
    }
}

struct ExplainBatchTarget: Identifiable {
    let id: String
    let documentID: UUID?
    let profile: SavedConnection
    let binding: ExplainProfileBinding
    let sessionID: String?
    let transactionStatus: TransactionStatus?
    let title: String
}

struct ExplainBatchDraft: Identifiable {
    let id = UUID()
    let sourceDocumentID: UUID
    let sourceText: String
    let sourceProfileID: UUID
    let sourceProfileBinding: ExplainProfileBinding
    let definitions: [SQLParameterDefinition]
    let mode: ExplainMode
    let statements: [ExplainBatchStatement]
    let targets: [ExplainBatchTarget]
    let defaultTargetID: String

    func selected(_ ids: Set<Int>) throws -> [ExplainBatchStatement] {
        guard !ids.isEmpty, ids.count <= 256, ids.isSubset(of: Set(statements.map(\.id))) else {
            throw ExecutionPolicyError(message: "Select at least one statement to continue.")
        }
        let selected = statements.filter { ids.contains($0.id) }
        guard selected.allSatisfy({ $0.matches(sourceText) }) else {
            throw ExecutionPolicyError(message: "The original statement ranges are no longer valid.")
        }
        return selected
    }
}

/// No runtime identifiers are portable. The original range and transaction
/// label remain useful historical evidence without granting execution rights.
struct ExplainSourceEvidence: Codable, Equatable, Sendable {
    var rangeLocation: Int
    var rangeLength: Int
    var transactionStatus: String?
    var valid: Bool {
        (0...16_777_216).contains(rangeLocation) && (1...1_048_576).contains(rangeLength) &&
            (transactionStatus == nil || ["idle", "transaction", "failedTransaction", "unsupported"].contains(transactionStatus))
    }
}

struct ExplainBatchExecution: Identifiable {
    let id = UUID()
    let statement: ExplainBatchStatement
    var status = "Pending"
    var plan: ExplainPlanModel?
    var context: ExplainContext?
    var targetProfile: SavedConnection?
    var result: BackendMessage?
    var failure: WorkspaceModel.QueryFailure?
    var clientDurationMs: Double?
}
