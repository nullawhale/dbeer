import Combine
import Foundation

struct AgentClientSummary: Identifiable, Equatable {
    let id: UUID
    let name: String
    let profiles: [String]
    let readOnly: Bool
}

struct AgentAuditEntry: Identifiable, Equatable {
    let id: UUID
    let clientID: UUID
    let profileID: UUID?
    let method: String
    let time: Date
    let permission: String
    let outcome: String
    let responseBytes: Int
}

/// Grants and database sessions belong to one live socket, and never enter workspace persistence.
@MainActor
final class AgentAccessCoordinator: ObservableObject {
    typealias Approval = @MainActor (String, [SavedConnection]) async -> [UUID: Bool]?
    @Published private(set) var clients: [AgentClientSummary] = []
    @Published private(set) var audit: [AgentAuditEntry] = []

    private struct Grant {
        let name: String
        let profiles: [UUID: SavedConnection]
        let writes: [UUID: Bool]
    }
    @MainActor private final class AuditContext {
        var permission: String?
        var outcome: String?
    }
    @MainActor private final class Operation {
        let ownerID = UUID()
        let profileID: UUID
        let queryID: String
        var cancelled = false
        var submitted = false
        var mayWrite = false
        var completed = false
        var backend: BackendClient?
        var sessionID: String?
        var confirmationTask: Task<Bool, Never>?
        init(profileID: UUID, queryID: String) { self.profileID = profileID; self.queryID = queryID }
    }
    private let profiles: @MainActor () -> [SavedConnection]
    private let settings: @MainActor (SavedConnection) async throws -> ConnectionSettings?
    private let backendFactory: @MainActor () async throws -> BackendClient
    private let approve: Approval
    private let confirm: @MainActor (OperationConfirmation) async -> Bool
    private var grants: [UUID: Grant] = [:]
    private var pending: Set<UUID> = []
    private var approvalTasks: [UUID: Task<[UUID: Bool]?, Never>] = [:]
    private var retired: Set<UUID> = []
    private var operations: [UUID: [String: Operation]] = [:]
    private var usedQueryIDs: [UUID: Set<String>] = [:]
    private var stopped = false

    init(profiles: @escaping @MainActor () -> [SavedConnection],
         settings: @escaping @MainActor (SavedConnection) async throws -> ConnectionSettings?,
         backendFactory: @escaping @MainActor () async throws -> BackendClient = {
             let client = BackendClient(); try await client.start(); return client
         },
         approve: @escaping Approval,
         confirm: @escaping @MainActor (OperationConfirmation) async -> Bool = AgentAccessApproval.confirm) {
        self.profiles = profiles; self.settings = settings; self.backendFactory = backendFactory
        self.approve = approve; self.confirm = confirm
    }

    func handle(clientID: UUID, request: AgentRequest) async -> AgentResponse {
        let response: AgentResponse
        let auditContext = AuditContext()
        let profileID = request.profileId.flatMap(UUID.init(uuidString:))
        let permission = profileID.flatMap { grants[clientID]?.writes[$0] } == true ? "write" : "read"
        if stopped || retired.contains(clientID) {
            response = failure(request, "Agent access has ended. Reconnect and request permission again.")
        } else {
            switch request.method {
            case "hello": response = await connect(clientID, request)
            case "connections": response = connections(clientID, request)
            case "query", "catalog": response = await run(clientID, request, auditContext: auditContext)
            case "cancel": response = await cancel(clientID, request)
            default: response = failure(request, "Unsupported agent operation.")
            }
        }
        audit.append(.init(id: UUID(), clientID: clientID, profileID: profileID,
            method: ["hello", "connections", "query", "catalog", "cancel"].contains(request.method) ? request.method : "invalid",
            time: Date(), permission: auditContext.permission ?? permission, outcome: auditContext.outcome ?? (response.ok ? "success" : "rejected"),
            responseBytes: (try? JSONEncoder().encode(response).count) ?? 0))
        if audit.count > 200 { audit.removeFirst(audit.count - 200) }
        return response
    }

    func disconnect(clientID: UUID) async { await retire(clientID: clientID, method: "disconnect") }

    func revoke(clientID: UUID) async { await retire(clientID: clientID, method: "revoke") }

    private func retire(clientID: UUID, method: String) async {
        // Invalidate before awaiting cleanup: late credentials, connects and approvals cannot execute.
        recordRetired(clientID); grants[clientID] = nil; pending.remove(clientID)
        approvalTasks.removeValue(forKey: clientID)?.cancel()
        usedQueryIDs[clientID] = nil
        let owned = Array(operations.removeValue(forKey: clientID)?.values ?? Dictionary<String, Operation>().values)
        owned.forEach { $0.cancelled = true }
        publishClients()
        audit.append(.init(id: UUID(), clientID: clientID, profileID: nil, method: method, time: Date(),
            permission: "revoked", outcome: "success", responseBytes: 0))
        if audit.count > 200 { audit.removeFirst(audit.count - 200) }
        await withTaskGroup(of: Void.self) { group in
            for operation in owned { group.addTask { await self.close(operation) } }
        }
    }

    func shutdown() async {
        stopped = true
        let ids = Set(grants.keys).union(pending).union(operations.keys)
        for id in ids { await revoke(clientID: id) }
    }

    private func connect(_ clientID: UUID, _ request: AgentRequest) async -> AgentResponse {
        guard grants[clientID] == nil, !pending.contains(clientID), grants.count + pending.count < 8,
              let name = request.clientName, !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return failure(request, "An agent connection cannot be approved.")
        }
        let available = profiles().filter(eligible)
        guard !available.isEmpty else { return failure(request, "No supported connection profiles are available.") }
        pending.insert(clientID)
        let task = Task { @MainActor in await self.approve(name, available) }
        approvalTasks[clientID] = task
        let selected = await task.value
        approvalTasks[clientID] = nil
        pending.remove(clientID)
        guard !stopped, !retired.contains(clientID), !task.isCancelled, let selected else {
            recordRetired(clientID)
            return failure(request, "Agent access was not approved.")
        }
        let current = profiles()
        let approved = available.filter { selected[$0.id] != nil && current.contains($0) }
        guard !approved.isEmpty else {
            recordRetired(clientID)
            return failure(request, "No unchanged connection profiles were approved.")
        }
        let snapshots = Dictionary(uniqueKeysWithValues: approved.map { ($0.id, $0) })
        let writes = Dictionary(uniqueKeysWithValues: approved.map { ($0.id, selected[$0.id] == true && !$0.policy.readOnly) })
        grants[clientID] = Grant(name: name, profiles: snapshots, writes: writes)
        publishClients()
        return connections(clientID, request)
    }

    private func eligible(_ profile: SavedConnection) -> Bool {
        [.postgresql, .mysql].contains(profile.engine) && profile.passwordCommand == nil
    }

    private func connections(_ clientID: UUID, _ request: AgentRequest) -> AgentResponse {
        guard let grant = grants[clientID] else { return failure(request, "Approve this agent in DBeer before using connections.") }
        let entries = grant.profiles.values.filter { valid(clientID, profile: $0) }.sorted { $0.name < $1.name }.map {
            AgentConnection(id: $0.id.uuidString, name: $0.name, engine: $0.engine.rawValue,
                readOnly: $0.policy.readOnly || grant.writes[$0.id] != true)
        }
        return AgentResponse(id: request.id, ok: true, connections: entries)
    }

    private func valid(_ clientID: UUID, profile: SavedConnection, operation: Operation? = nil) -> Bool {
        !stopped && !retired.contains(clientID) && operation?.cancelled != true &&
            grants[clientID]?.profiles[profile.id] == profile && profiles().contains(profile)
    }

    private func run(_ clientID: UUID, _ request: AgentRequest, auditContext: AuditContext) async -> AgentResponse {
        guard let profileID = request.profileId.flatMap(UUID.init(uuidString:)),
              let profile = grants[clientID]?.profiles[profileID], valid(clientID, profile: profile) else {
            return failure(request, "This connection is not available to this agent.")
        }
        let limit = request.maxRows ?? 100, timeout = request.timeoutSeconds ?? 30
        guard (1...1_000).contains(limit), (1...60).contains(timeout),
              let queryID = request.queryId, BackendMessage.validID(queryID), !queryID.contains("\0"),
              usedQueryIDs[clientID]?.contains(queryID) != true,
              (usedQueryIDs[clientID]?.count ?? 0) < 4_096, (operations[clientID]?.count ?? 0) < 4 else {
            return failure(request, "Invalid query limits or identifier; use a fresh identifier for each operation.")
        }
        var catalog: CatalogRequest?
        if request.method == "query" {
            guard let sql = request.sql, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  sql.utf8.count <= 128 * 1_024, !sql.contains("\0") else {
                return failure(request, "A query must contain at most 128 KiB of SQL.")
            }
        } else {
            guard let kind = request.kind, ["schemas", "tables", "columns"].contains(kind),
                  [request.schema, request.object].allSatisfy({ $0 == nil || ($0!.utf8.count <= 1_024 && !$0!.contains("\0")) }),
                  kind != "columns" || request.object?.isEmpty == false else {
                return failure(request, "Choose schemas, tables or columns with bounded object names.")
            }
            catalog = CatalogRequest(kind: kind == "tables" ? "objects" : kind, schema: request.schema, object: request.object,
                objectKind: kind == "tables" ? "table" : nil)
        }
        let operation = Operation(profileID: profileID, queryID: queryID)
        usedQueryIDs[clientID, default: []].insert(queryID)
        operations[clientID, default: [:]][queryID] = operation
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            operation.cancelled = true
            await self?.close(operation)
        }
        defer {
            deadline.cancel()
            if operations[clientID]?[queryID] === operation { operations[clientID]?[queryID] = nil }
        }
        do {
            guard var connection = try await settings(profile), valid(clientID, profile: profile, operation: operation),
                  profile.matches(connection) else { throw AgentFailure() }
            connection.policy.readOnly = catalog != nil || profile.policy.readOnly || grants[clientID]?.writes[profileID] != true
            auditContext.permission = connection.policy.readOnly ? "read" : "write"
            let backend = try await backendFactory()
            operation.backend = backend
            guard valid(clientID, profile: profile, operation: operation) else { await close(operation); throw AgentFailure() }
            try await SSHConnectionReview.prepare(connection, client: backend, ownerID: operation.ownerID, reviewID: operation.ownerID.uuidString)
            guard valid(clientID, profile: profile, operation: operation) else { await close(operation); throw AgentFailure() }
            let connected = try await backend.request(.connect(connection))
            operation.sessionID = connected.sessionId
            guard let sessionID = operation.sessionID, valid(clientID, profile: profile, operation: operation) else {
                await close(operation); throw AgentFailure()
            }
            var command: BackendCommand
            if let catalog {
                command = .catalog(sessionId: sessionID, queryId: queryID, request: catalog)
            } else {
                let sql = request.sql!
                let operations = [OperationRequest(type: "execute", sql: sql)]
                let assessed = try await backend.request(.assess(sessionId: sessionID, operations: operations))
                guard valid(clientID, profile: profile, operation: operation),
                      assessed.sessionId == sessionID, let assessment = assessed.assessment,
                      assessment.policy == connection.policy, assessment.operations.count == 1,
                      assessment.operations[0].statements.count == 1, assessment.decision != "deny",
                      let authorization = assessment.authorization else { throw AgentFailure() }
                // Readonly is enforced by the helper/server too; never trust client claims or SQL prefixes.
                if connection.policy.readOnly && assessment.operations[0].kind != "read" { throw AgentFailure() }
                operation.mayWrite = assessment.operations[0].kind != "read"
                if assessment.decision == "confirm" {
                    var effectiveProfile = profile; effectiveProfile.policy = connection.policy
                    let confirmation = OperationConfirmation(profile: effectiveProfile, operations: operations, assessment: assessment, isScript: false)
                    let task = Task { @MainActor in await self.confirm(confirmation) }
                    operation.confirmationTask = task
                    let accepted = await task.value
                    operation.confirmationTask = nil
                    guard accepted, !task.isCancelled, valid(clientID, profile: profile, operation: operation) else { throw AgentFailure() }
                }
                command = .execute(sessionId: sessionID, queryId: queryID, sql: sql)
                command.authorization = authorization
            }
            guard valid(clientID, profile: profile, operation: operation) else { throw AgentFailure() }
            operation.submitted = true
            let reply = try await backend.request(command)
            operation.completed = true
            guard valid(clientID, profile: profile, operation: operation), reply.type == "query.result",
                  reply.sessionId == sessionID, reply.queryId == queryID else { throw AgentFailure() }
            let response = try bounded(reply, request: request, limit: limit)
            await close(operation)
            guard valid(clientID, profile: profile, operation: operation) else { throw AgentFailure() }
            return response
        } catch {
            await close(operation)
            let knownFailure = (error as? BackendRemoteError)?.reply.outcomeUnknown == false || error is BackendRequestError
            let unknown = operation.submitted && operation.mayWrite && !operation.completed && !knownFailure
            auditContext.outcome = operation.completed ? "completed" : unknown ? "unknown" : operation.cancelled ? "cancelled" : operation.submitted ? "failed" : "rejected"
            let message = operation.completed ? "The database operation completed, but its response could not be returned within the current access and response limits." :
                operation.cancelled ? "The agent operation was cancelled or timed out." :
                "The agent operation could not complete. Review connection access and operation policy in DBeer."
            return failure(request, message + (unknown ? " A submitted write may have an unknown outcome." : ""))
        }
    }

    private func cancel(_ clientID: UUID, _ request: AgentRequest) async -> AgentResponse {
        guard grants[clientID] != nil, let queryID = request.queryId,
              BackendMessage.validID(queryID), !queryID.contains("\0") else {
            return failure(request, "Approve this agent and provide a valid operation identifier before cancelling.")
        }
        if let operation = operations[clientID]?[queryID] {
            operation.cancelled = true
            await close(operation)
        } else {
            // Cancellation can overtake an admitted query task. Remember it before
            // returning so the late query cannot start, without inspecting other clients.
            if usedQueryIDs[clientID]?.contains(queryID) != true {
                guard (usedQueryIDs[clientID]?.count ?? 0) < 4_096 else {
                    return failure(request, "The operation identifier limit was reached. Reconnect and request permission again.")
                }
                usedQueryIDs[clientID, default: []].insert(queryID)
            }
        }
        return AgentResponse(id: request.id, ok: true, queryId: queryID)
    }

    private func close(_ operation: Operation) async {
        operation.confirmationTask?.cancel()
        SSHConnectionReview.cancel(ownerID: operation.ownerID)
        guard let backend = operation.backend else { return }
        // Shutdown has a separate deadline and remains effective if cancel/disconnect waits on a full pipe.
        let cleanup = Task {
            if let sessionID = operation.sessionID {
                if operation.cancelled { _ = try? await backend.request(.cancel(sessionId: sessionID, queryId: operation.queryID)) }
                _ = try? await backend.request(.disconnect(sessionId: sessionID))
            }
        }
        _ = await backend.shutdown()
        await cleanup.value
    }

    private func bounded(_ reply: BackendMessage, request: AgentRequest, limit: Int) throws -> AgentResponse {
        let sets = reply.resultSets ?? [QueryResultSet(columns: reply.columns ?? [], rows: reply.rows ?? [],
            commandTag: reply.commandTag ?? "", rowCount: reply.rowCount ?? 0,
            displayedRowCount: reply.displayedRowCount ?? 0, truncated: reply.truncated ?? false)]
        var remaining = limit
        var results: [AgentResult] = []
        for set in sets.prefix(16) {
            let count = min(remaining, set.rows.count)
            let result = AgentResult(columns: set.columns.map { AgentColumn(name: $0.name, type: $0.nativeType, encoding: $0.encoding) },
                rows: Array(set.rows.prefix(count)), commandTag: String(set.commandTag.prefix(128)), rowCount: set.rowCount,
                truncated: set.truncated || count < set.rows.count || sets.count > 16)
            remaining -= count; results.append(result)
        }
        let encoder = JSONEncoder()
        let maximumBytes = 1_048_576
        let full = AgentResponse(id: request.id, ok: true, results: results, queryId: request.queryId)
        if try encoder.encode(full).count <= maximumBytes { return full }

        // Preserve whole exact cells, NULL and binary metadata. A bounded binary search
        // avoids repeatedly encoding almost the entire result while blocking cancellation.
        func prefixResponse(_ count: Int) -> AgentResponse {
            var remaining = count
            let prefix = results.map { original in
                var result = original
                let keep = min(remaining, original.rows.count)
                result.rows = Array(original.rows.prefix(keep))
                result.truncated = original.truncated || keep < original.rows.count
                remaining -= keep
                return result
            }
            return AgentResponse(id: request.id, ok: true, results: prefix, queryId: request.queryId)
        }
        var fitting = prefixResponse(0)
        guard try encoder.encode(fitting).count <= maximumBytes else { throw AgentFailure() }
        var lower = 0
        var upper = results.reduce(0) { $0 + $1.rows.count }
        while lower + 1 < upper {
            let middle = lower + (upper - lower) / 2
            let candidate = prefixResponse(middle)
            if try encoder.encode(candidate).count <= maximumBytes {
                lower = middle; fitting = candidate
            } else { upper = middle }
        }
        return fitting
    }

    private func recordRetired(_ clientID: UUID) {
        guard !stopped else { return }
        retired.insert(clientID)
        if retired.count >= 4_096 {
            // Fail closed until the broker is restarted instead of retaining unbounded socket identities.
            stopped = true
            Task { @MainActor [weak self] in await self?.shutdown() }
        }
    }

    private func publishClients() {
        clients = grants.map { id, grant in
            AgentClientSummary(id: id, name: grant.name, profiles: grant.profiles.values.map(\.name).sorted(),
                readOnly: !grant.writes.values.contains(true))
        }.sorted { $0.name < $1.name }
    }

    private func failure(_ request: AgentRequest, _ message: String) -> AgentResponse {
        AgentResponse(id: request.id, ok: false, error: message, queryId: request.queryId)
    }
    private struct AgentFailure: Error {}
}
