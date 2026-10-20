import Foundation

extension ApplicationWorkspace {
    func authorizeOperations(_ operations: [OperationRequest], sessionID: String, profile: SavedConnection,
                             client: BackendClient, isScript: Bool = false, sourceSQL: String? = nil,
                             generatedPreview: String? = nil) async throws -> String? {
        let reply = try await client.request(.assess(sessionId: sessionID, operations: operations))
        guard let assessment = reply.assessment, assessment.operations.count == operations.count,
              assessment.policy == profile.policy, reply.sessionId == sessionID else {
            throw ExecutionPolicyError(message: "The execution context changed. Review the operation again.")
        }
        if assessment.decision == "deny" {
            throw ExecutionPolicyError(message: "Readonly blocks writes and unknown operations. Use a database account with restricted privileges for strict protection.")
        }
        let isBatch = isScript || operations.count > 1 || assessment.operations.contains { $0.statements.count > 1 }
        if isBatch || assessment.decision == "confirm" {
            guard await executionDecision(OperationConfirmation(profile: profile, operations: operations,
                assessment: assessment, isScript: isBatch, sourceSQL: sourceSQL, generatedPreview: generatedPreview)) else {
                // Cancel also destroys any unconsumed batch grant in the helper.
                if let queryID = reply.queryId { _ = try? await client.request(.cancel(sessionId: sessionID, queryId: queryID)) }
                return nil
            }
        }
        return assessment.authorization
    }
}

struct ExecutionPolicyError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
