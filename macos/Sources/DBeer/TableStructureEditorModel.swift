import Combine
import Foundation

struct TableStructureExecutionReview: Identifiable, Sendable {
    var outcome: StructureOutcome
    let plan: StructurePlan
    let draft: StructureDraft
    var id: String { outcome.executionId }
}

struct TableStructureOutcomeRecord {
    let profileID: UUID
    let schema: String
    let table: String
    var review: TableStructureExecutionReview
    var outcome: StructureOutcome { review.outcome }
}

@MainActor
final class TableStructureEditorModel: ObservableObject, Identifiable {
    let id = UUID()
    let profile: SavedConnection
    let schema: String
    private let originalCreate: Bool
    @Published private(set) var closing = false
    @Published private(set) var create: Bool
    @Published var table: String { didSet { if !StructureTarget.sameIdentifier(table, oldValue) { baseline = nil; preview = nil } } }
    @Published var draft = StructureDraft(columns: [TableStructureEditorModel.emptyColumn]) { didSet { preview = nil } }
    @Published private(set) var baseline: StructureBaseline?
    @Published private(set) var preview: StructurePlan?
    @Published private(set) var operationSupport: OperationSupport?
    @Published private(set) var outcome: StructureOutcome?
    @Published private(set) var history: [StructureOutcome]
    @Published private(set) var outcomeReview: TableStructureExecutionReview?
    @Published private(set) var historyReviews: [TableStructureExecutionReview]
    @Published private(set) var isBusy = false
    @Published private(set) var isApplying = false
    @Published private(set) var error: String?
    @Published private(set) var invalidated = false
    private var sessionID: String?
    private var queryID: String?
    private var cancelRequested = false
    private let connect: () async throws -> String
    private let send: (BackendCommand) async throws -> BackendMessage
    private let authorize: (StructureApply, StructurePlan, String) async throws -> String?
    private let bindingIsCurrent: () -> Bool
    private let operationsAllowed: () -> Bool
    private let sessionIsKnownClosed: () async -> Bool
    private let changed: (TableStructureExecutionReview) -> Void

    init(profile: SavedConnection, schema: String, table: String, create: Bool, history: [StructureOutcome] = [], historyReviews: [TableStructureExecutionReview] = [],
         connect: @escaping () async throws -> String,
         send: @escaping (BackendCommand) async throws -> BackendMessage,
         authorize: @escaping (StructureApply, StructurePlan, String) async throws -> String?,
         bindingIsCurrent: @escaping () -> Bool, operationsAllowed: @escaping () -> Bool = { true }, sessionIsKnownClosed: @escaping () async -> Bool = { false }, changed: @escaping (TableStructureExecutionReview) -> Void) {
        self.profile = profile; self.schema = schema; self.table = table; self.create = create; self.originalCreate = create; self.history = history + historyReviews.map(\.outcome); self.historyReviews = historyReviews
        self.connect = connect; self.send = send; self.authorize = authorize
        self.bindingIsCurrent = bindingIsCurrent; self.operationsAllowed = operationsAllowed; self.sessionIsKnownClosed = sessionIsKnownClosed; self.changed = changed
    }
    static var emptyColumn: StructureColumn {
        .init(name: "", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))
    }
    var hasDraft: Bool {
        guard outcome == nil else { return false }
        let initial = StructureDraft(columns: create ? [Self.emptyColumn] : [])
        return preview != nil || draft != initial
    }

    var canPreview: Bool { !isBusy && !closing && operationsAllowed() && !invalidated && baseline != nil && draft.valid && outcome == nil && (operationSupport?.permits("structure.preview", legacyAllowed: true) ?? true) }
    var canApply: Bool { !isBusy && !closing && operationsAllowed() && !invalidated && preview != nil && outcome == nil && !profile.policy.readOnly && (operationSupport?.availability("structure.apply").map { $0.state == .available } ?? true) }
    var target: StructureTarget { .init(schema: schema, table: table, create: create) }

    @discardableResult func validateBinding() -> Bool {
        guard bindingIsCurrent() else {
            invalidated = true; preview = nil; baseline = nil
            error = "The connection or catalog changed. Close this draft and reopen it with the current connection."
            return false
        }
        return !invalidated
    }
    func invalidate() { invalidated = true; preview = nil; baseline = nil; error = "The catalog changed. Close and reopen this draft before applying any changes." }
    private func requireBinding() throws {
        guard validateBinding(), !cancelRequested, !closing, operationsAllowed() else { throw ExecutionPolicyError(message: "The structure operation was cancelled or its connection changed.") }
    }
    private func request(_ operation: String, _ payload: StructureRequest, authorization: String? = nil) async throws -> StructureReply {
        try requireBinding()
        guard let sessionID else { throw ExecutionPolicyError(message: "Open the dedicated structure session first.") }
        let query = UUID().uuidString; queryID = query
        defer { queryID = nil }
        let response = try await send(.init(type: "structure." + operation, requestId: UUID().uuidString,
            sessionId: sessionID, queryId: query, authorization: authorization, structure: payload))
        guard let reply = response.structure else { throw BackendTransportError(.invalidMessage) }
        if let support = response.operationSupport, support.engine != profile.engine || support.scope != .structure {
            throw BackendTransportError(.invalidMessage)
        }
        operationSupport = response.operationSupport
        return reply
    }
    func load() async {
        guard !isBusy, !closing, operationsAllowed(), target.valid, validateBinding() else { return }
        isBusy = true; cancelRequested = false; error = nil; preview = nil
        defer { isBusy = false }
        do {
            if sessionID == nil { sessionID = try await connect() }
            try requireBinding()
            let requestedTarget = outcome != nil && originalCreate ? StructureTarget(schema: schema, table: table, create: true, reconcile: true) : target
            let reply = try await request("load", .init(target: requestedTarget))
            try requireBinding()
            baseline = reply.baseline
            if let baseline { create = baseline.target.create }
            if let outcome { history.append(outcome) }
            if let outcomeReview, !historyReviews.contains(where: { $0.id == outcomeReview.id }) { historyReviews.append(outcomeReview) }
            outcomeReview = nil
            outcome = nil
            draft = .init(columns: create ? [Self.emptyColumn] : [])
        } catch { self.error = error.localizedDescription }
    }
    func preparePreview() async {
        guard canPreview, let baseline else { return }
        isBusy = true; cancelRequested = false; error = nil; preview = nil
        let frozen = draft
        defer { isBusy = false }
        do {
            let reply = try await request("preview", .init(baselineId: baseline.id, draft: frozen))
            try requireBinding()
            guard draft == frozen, reply.plan?.target == target else { throw BackendTransportError(.invalidMessage) }
            preview = reply.plan
        } catch { self.error = error.localizedDescription }
    }
    func apply() async {
        guard canApply, let plan = preview, let sessionID, validateBinding() else { return }
        isBusy = true; cancelRequested = false; error = nil
        let reviewedDraft = draft
        let apply = StructureApply(planId: plan.id, digest: plan.digest, executionId: UUID().uuidString)
        defer { isBusy = false; isApplying = false }
        do {
            guard let authorization = try await authorize(apply, plan, sessionID) else { return }
            try requireBinding()
            guard preview == plan, draft == reviewedDraft else { throw ExecutionPolicyError(message: "The draft changed. Prepare a fresh preview.") }
            isApplying = true
            let reply = try await request("apply", .init(apply: apply), authorization: authorization)
            guard reply.outcome?.steps.count == plan.sql.count else { throw BackendTransportError(.invalidMessage, outcomeUnknown: true) }
            // Preserve authoritative execution evidence even if the profile changed in flight.
            outcome = reply.outcome; preview = nil; baseline = nil
            if let observed = outcome?.observed { create = observed.target.create }
            else if outcome?.state == "applied" { create = false }
            if let outcome { let review = TableStructureExecutionReview(outcome: outcome, plan: plan, draft: reviewedDraft); outcomeReview = review; changed(review) }
            _ = validateBinding()
        } catch {
            self.error = error.localizedDescription
            if isApplying {
                let transport = error as? BackendTransportError
                let remote = (error as? BackendRemoteError)?.reply
                let unknown: Bool
                if let transport { unknown = transport.outcomeUnknown }
                else if let remote { unknown = remote.outcomeUnknown == true || remote.sqlNotExecuted != true }
                else { unknown = false }
                let cancelled = cancelRequested || error is CancellationError || remote?.category == "cancelled"
                let evidence: [StructureStepOutcome] = unknown
                    ? [.init(state: "unknown", message: "Aggregate completion was lost; unreported steps may have run. Reconcile before another edit.")]
                    : plan.sql.map { _ in .init(state: "notStarted", message: "No DDL was executed.") }
                outcome = .init(executionId: apply.executionId, planId: plan.id,
                    state: unknown ? "outcomeUnknown" : (cancelled ? "cancelled" : "failed"),
                    steps: evidence,
                    refreshError: "Reconcile explicitly to load the current structure.")
                preview = nil; baseline = nil; if let outcome { let review = TableStructureExecutionReview(outcome: outcome, plan: plan, draft: reviewedDraft); outcomeReview = review; changed(review) }
            }
        }
    }
    func discard(forClosing: Bool = false) {
        guard !isBusy, forClosing || !closing else { return }
        draft = .init(columns: create ? [Self.emptyColumn] : []); preview = nil
    }
    func stop() async {
        cancelRequested = true
        guard let sessionID, let queryID else { return }
        _ = try? await send(.cancel(sessionId: sessionID, queryId: queryID))
    }
    func beginClosing() -> Bool {
        guard !closing else { return false }
        closing = true
        return true
    }
    func cancelClosing() { closing = false }
    func close() async -> Bool {
        if !closing { closing = true }
        guard !isBusy else { return false }
        if let sessionID {
            do {
                let reply = try await send(.disconnect(sessionId: sessionID))
                guard reply.type == "disconnect.ack", reply.sessionId == sessionID else { throw BackendTransportError(.invalidMessage) }
            } catch {
                if !isBusy, await sessionIsKnownClosed() { self.sessionID = nil; return true }
                self.error = "The structure session could not be closed. Wait for its terminal outcome and try again."
                closing = false
                return false
            }
        }
        sessionID = nil
        return true
    }
}
