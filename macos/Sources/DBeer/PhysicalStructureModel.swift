import Combine
import Foundation

struct PhysicalStructureReport: Codable, Equatable, Sendable, Identifiable {
    let version: Int
    let serverEvidence: Bool
    let plan: StructurePhysicalPlan
    var outcome: StructurePhysicalOutcome
    var id: String { outcome.executionId }
    init(plan: StructurePhysicalPlan, outcome: StructurePhysicalOutcome, serverEvidence: Bool = true) { version = 1; self.plan = plan; self.outcome = outcome; self.serverEvidence = serverEvidence }
}

/// Physical operations retain their original dedicated owner and exact review.
@MainActor
final class PhysicalStructureModel: ObservableObject, Identifiable {
    let id = UUID()
    let profile: SavedConnection
    let target: StructureTarget
    let history: [PhysicalStructureReport]
    @Published var intent: StructurePhysicalIntent { didSet { preview = nil } }
    @Published private(set) var preview: StructurePhysicalPlan?
    @Published private(set) var report: PhysicalStructureReport?
    @Published private(set) var openedReport: PhysicalStructureReport?
    @Published private(set) var objects: [StructurePhysicalObject] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isApplying = false
    @Published private(set) var checkingStatus = false
    @Published private(set) var closing = false
    @Published private(set) var invalidated = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var elapsedMilliseconds: Int64 = 0
    @Published private(set) var inspection: StructurePhysicalInspection?
    private let initialIntent: StructurePhysicalIntent
    private var sessionID: String?
    private var sessionUnavailable = false
    private var queryID: String?
    private var stopRequested = false
    private var executionID: String?
    private var executionPlan: StructurePhysicalPlan?
    private let connect: () async throws -> String
    private let send: (BackendCommand) async throws -> BackendMessage
    private let authorize: (StructureApply, StructurePhysicalPlan, String) async throws -> String?
    private let bindingIsCurrent: () -> Bool
    private let operationsAllowed: () -> Bool
    private let helperIsClosed: () async -> Bool
    private let changed: (PhysicalStructureReport) -> Void

    init(profile: SavedConnection, target: StructureTarget, history: [PhysicalStructureReport] = [], connect: @escaping () async throws -> String,
         send: @escaping (BackendCommand) async throws -> BackendMessage,
         authorize: @escaping (StructureApply, StructurePhysicalPlan, String) async throws -> String?,
         bindingIsCurrent: @escaping () -> Bool, operationsAllowed: @escaping () -> Bool = { true },
         helperIsClosed: @escaping () async -> Bool = { false }, changed: @escaping (PhysicalStructureReport) -> Void = { _ in }) {
        self.profile = profile; self.target = target; self.history = history; self.connect = connect; self.send = send; self.authorize = authorize
        self.bindingIsCurrent = bindingIsCurrent; self.operationsAllowed = operationsAllowed; self.helperIsClosed = helperIsClosed; self.changed = changed
        let initial = Self.emptyIntent(profile.engine == .postgresql ? "concurrentIndex" : "onlineIndex", engine: profile.engine, schema: target.schema)
        intent = initial; initialIntent = initial
    }
    var draft: StructurePhysicalDraft { .init(version: 1, target: target, intent: intent) }
    var editable: Bool { !isBusy && !closing && !invalidated && executionID == nil }
    var canOpenIntent: Bool { editable && sessionID == nil }
    var portableIntent: PhysicalStructureIntentDocument { .init(engine: profile.engine, draft: draft) }
    var canInspect: Bool { editable && operationsAllowed() && !sessionUnavailable }
    var canPreview: Bool { canInspect && draft.valid && (inspection == nil || operationKinds.contains(intent.kind)) }
    var canApply: Bool { editable && operationsAllowed() && preview != nil && !profile.policy.readOnly && !sessionUnavailable }
    var canCheckStatus: Bool { !checkingStatus && !closing && executionID != nil && sessionID != nil }
    var canReconcile: Bool { !isBusy && !closing && executionID != nil && !sessionUnavailable && bindingIsCurrent() && operationsAllowed() }
    var hasIntent: Bool { preview != nil || intent != initialIntent }
    var outcomeUnknown: Bool { report?.outcome.state == "outcomeUnknown" || report?.outcome.state == "partiallyApplied" }
    var columnNames: [String] { objects.first?.columns.map(\.name) ?? [] }
    var operationKinds: [String] {
        if let inspection { return inspection.operations }
        return profile.engine == .postgresql
            ? ["concurrentIndex", "createPartition", "attachPartition", "detachPartition", "finalizePartition", "dropPartition", "truncatePartition"]
            : ["onlineIndex", "partitionTable", "removePartitioning", "exchangePartition", "addPartition", "reorganizePartition", "dropPartition", "truncatePartition", "addHashPartitions", "coalescePartitions", "storageEngine", "reorderColumns"]
    }
    static func emptyIntent(_ kind: String, engine: DatabaseEngine, schema: String) -> StructurePhysicalIntent {
        var value = StructurePhysicalIntent(kind: kind)
        if engine == .mysql { value.algorithm = "INPLACE"; value.lock = "NONE" }
        switch kind {
        case "concurrentIndex", "onlineIndex": value.index = .init(action: "add", name: "", columns: [""])
        case "createPartition", "attachPartition": value.child = .init(schema: schema, table: "", create: false); value.bound = .init(kind: "range", from: [.init(kind: "integer", value: "0")], to: [.init(kind: "integer", value: "1")])
        case "detachPartition", "finalizePartition": value.child = .init(schema: schema, table: "", create: false)
        case "dropPartition", "truncatePartition":
            if engine == .postgresql { value.child = .init(schema: schema, table: "", create: false) } else { value.partitions = [""] }
        case "exchangePartition": value.child = .init(schema: schema, table: "", create: false); value.partitions = [""]
        case "addPartition", "reorganizePartition":
            value.definitions = [.init(name: "", bound: .init(kind: "range", to: [.init(kind: "integer", value: "1")]))]
            if kind == "reorganizePartition" { value.partitions = [""] }
        case "partitionTable": value.method = "range"; value.columns = [""]; value.definitions = [.init(name: "", bound: .init(kind: "range", to: [.init(kind: "integer", value: "1")]))]
        case "addHashPartitions", "coalescePartitions": value.count = 1
        case "storageEngine": value.engine = "InnoDB"; value.algorithm = "COPY"; value.lock = "SHARED"
        case "reorderColumns": value.columnOrder = [""]; value.algorithm = "COPY"; value.lock = "SHARED"
        default: break
        }
        return value
    }
    func invalidate() {
        invalidated = true; preview = nil
        error = "The origin connection or catalog changed. Retained execution evidence is kept. Close and explicitly reopen for a new operation."
    }
    private func requireBinding() throws {
        guard !invalidated, !closing, !stopRequested, bindingIsCurrent(), operationsAllowed() else {
            if !bindingIsCurrent() { invalidate() }
            throw ExecutionPolicyError(message: "The physical operation was stopped or its origin connection changed.")
        }
    }
    private func ensureSession() async throws {
        try requireBinding()
        guard !sessionUnavailable else { throw BackendTransportError(.notReady) }
        if sessionID != nil { return }
        sessionID = try await connect()
        try requireBinding()
    }
    private func request(_ operation: String, payload: StructurePhysicalRequest = .init(), authorization: String? = nil, retained: Bool = false) async throws -> StructurePhysicalReply {
        if !retained { try requireBinding() }
        guard let sessionID else { throw BackendTransportError(.notReady) }
        let query = UUID().uuidString
        if !retained { queryID = query }
        defer { if !retained { queryID = nil } }
        let command = BackendCommand(type: "structure.physical." + operation, requestId: UUID().uuidString,
            sessionId: sessionID, queryId: query, authorization: authorization, structure: .init(physical: payload))
        do {
            let message = try await send(command)
            if message.connected == false { sessionUnavailable = true }
            guard message.type == command.terminalType else { throw BackendTransportError(.invalidMessage, outcomeUnknown: operation == "apply") }
            do { try PhysicalTransportAdmission.validate(message.structure?.physical, command: command) }
            catch { throw BackendTransportError(.invalidMessage, outcomeUnknown: operation == "apply") }
            return message.structure!.physical!
        } catch {
            if error is BackendTransportError || (error as? BackendRemoteError)?.reply.connected == false { sessionUnavailable = true }
            throw error
        }
    }
    func inspect() async {
        guard canInspect else { return }
        isBusy = true; error = nil; stopRequested = false; preview = nil
        defer { isBusy = false }
        do {
            try await ensureSession()
            let value = try await request("inspect", payload: .init(target: target))
            try requireBinding()
            guard let inspected = value.inspection, inspected.engine == profile.engine.rawValue, inspected.objects.first?.target == target else { throw BackendTransportError(.invalidMessage) }
            inspection = inspected; objects = inspected.objects
        } catch { self.error = error.localizedDescription }
    }
    func preparePreview() async {
        guard canPreview else { return }
        let frozen = draft
        isBusy = true; error = nil; notice = nil; stopRequested = false; preview = nil
        defer { isBusy = false }
        do {
            try await ensureSession()
            let value = try await request("preview", payload: .init(draft: frozen))
            try requireBinding()
            guard draft == frozen, let plan = value.plan, plan.draft == frozen, plan.engine == profile.engine.rawValue else { throw BackendTransportError(.invalidMessage) }
            preview = plan; objects = plan.objects
        } catch { self.error = error.localizedDescription }
    }
    func apply() async {
        guard canApply, let plan = preview, let owner = sessionID else { return }
        let frozen = draft, invocation = StructureApply(planId: plan.id, digest: plan.digest, executionId: UUID().uuidString)
        isBusy = true; error = nil; notice = nil; stopRequested = false
        defer { isBusy = false; isApplying = false }
        do {
            guard let grant = try await authorize(invocation, plan, owner) else { return }
            try requireBinding()
            guard draft == frozen, StructureTarget.intentBytes(preview) == StructureTarget.intentBytes(Optional(plan)), sessionID == owner else { throw StructureDraftFileError.changedDraft }
            executionID = invocation.executionId; executionPlan = plan; preview = nil; isApplying = true
            let value = try await request("apply", payload: .init(apply: invocation), authorization: grant)
            guard value.draft == plan.draft, let outcome = value.outcome, outcome.executionId == invocation.executionId,
                  PhysicalTransportAdmission.matches(outcome, plan: plan), report.map({ accepts(outcome, after: $0) }) ?? true else { throw BackendTransportError(.invalidMessage, outcomeUnknown: true) }
            retain(plan, outcome)
            if !bindingIsCurrent() { invalidate() }
        } catch {
            self.error = error.localizedDescription
            guard isApplying else { return }
            if let retained = report, retained.serverEvidence, retained.outcome.state != "applying" { return }
            let remote = (error as? BackendRemoteError)?.reply
            let unknown = (error as? BackendTransportError)?.outcomeUnknown ?? (remote.map { $0.outcomeUnknown == true || $0.sqlNotExecuted != true } ?? true)
            var steps = report?.outcome.steps ?? plan.sql.map { _ in StructureStepOutcome(state: "notStarted") }
            for i in steps.indices where !["applied", "failed", "rolledBack"].contains(steps[i].state) {
                steps[i] = .init(state: unknown ? "unknown" : "notStarted", message: unknown ? "Completion was lost. This statement may have run. No automatic retry or cleanup is allowed." : "No execution was acknowledged.")
            }
            let state = steps.allSatisfy { $0.state == "applied" } ? "applied" : (steps.contains { $0.state == "unknown" } ? "outcomeUnknown" : (steps.contains { $0.state == "applied" } ? "partiallyApplied" : (stopRequested ? "cancelled" : "failed")))
            retain(plan, .init(consequences: report?.outcome.consequences, executionId: invocation.executionId, planId: plan.id, state: state, phase: "finished", steps: steps, observed: report?.outcome.observed, refreshError: report?.outcome.refreshError, reconciled: false), serverEvidence: false)
        }
    }
    private func accepts(_ next: StructurePhysicalOutcome, after previous: PhysicalStructureReport) -> Bool {
        guard PhysicalTransportAdmission.preserves(next, previous: previous.outcome, preserveUnknown: previous.serverEvidence) else { return false }
        return !previous.serverEvidence || previous.outcome.state == "applying" || next.state != "applying"
    }
    private func retain(_ plan: StructurePhysicalPlan, _ outcome: StructurePhysicalOutcome, serverEvidence: Bool = true) {
        report = .init(plan: plan, outcome: outcome, serverEvidence: serverEvidence)
        if let observed = outcome.observed { objects = observed }
        preview = nil; changed(report!)
    }
    func checkStatus() async {
        guard canCheckStatus, let plan = executionPlan, let executionID else { return }
        checkingStatus = true; error = nil
        defer { checkingStatus = false }
        do {
            guard !(await helperIsClosed()) else { throw BackendTransportError(.notReady) }
            let value = try await request("status", retained: true)
            guard value.draft == plan.draft, let outcome = value.outcome, outcome.executionId == executionID, PhysicalTransportAdmission.matches(outcome, plan: plan),
                  report.map({ accepts(outcome, after: $0) }) ?? true else { throw BackendTransportError(.invalidMessage) }
            retain(plan, outcome); elapsedMilliseconds = value.elapsedMilliseconds ?? 0
            notice = "Status contains retained server acknowledgements. No SQL was replayed."
        } catch { self.error = "Status could not be verified. Existing evidence is kept. " + error.localizedDescription }
    }
    func reconcile() async {
        guard canReconcile, let old = report else { return }
        isBusy = true; error = nil; stopRequested = false
        defer { isBusy = false }
        do {
            let value = try await request("reconcile")
            try requireBinding()
            guard value.draft == old.plan.draft, let outcome = value.outcome, outcome.executionId == old.id, PhysicalTransportAdmission.matches(outcome, plan: old.plan),
                  accepts(outcome, after: old) else { throw BackendTransportError(.invalidMessage) }
            retain(old.plan, outcome)
            notice = "Current catalog observations are separate from execution acknowledgements. Unknown writes remain unknown. Close and explicitly reopen to review another operation."
        } catch { self.error = error.localizedDescription }
    }
    func setFileError(_ value: any Error) { error = value.localizedDescription }
    func saveIntent(to url: URL, expected: PhysicalStructureIntentDocument, version: SQLFileVersion?) async {
        guard !isBusy, !closing, portableIntent == expected else { error = StructureDraftFileError.changedDraft.localizedDescription; return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let text = try expected.encoded()
            _ = try await Task.detached { try SQLFileBinding.write(text, to: url, expectedVersion: version, maximumBytes: PhysicalStructureIntentDocument.maximumBytes) }.value
        } catch { self.error = error.localizedDescription }
    }
    func openIntent(from url: URL, expected: PhysicalStructureIntentDocument) async {
        guard canOpenIntent, portableIntent == expected else { error = "Open portable intent before connecting this inspector's dedicated session."; return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let loaded = try await Task.detached { try SQLFileBinding.read(url, maximumBytes: PhysicalStructureIntentDocument.maximumBytes) }.value
            let value = try PhysicalStructureIntentDocument.decode(loaded.text)
            guard portableIntent == expected, sessionID == nil, value.engine == profile.engine, value.draft.target == target else { throw StructureDraftFileError.changedDraft }
            intent = value.draft.intent; inspection = nil; objects = []; preview = nil
            notice = "Portable intent is loaded without a dedicated connection or execution authority. Inspect and Preview explicitly before a new review."
        } catch { self.error = error.localizedDescription }
    }
    func saveReport(to url: URL, expected: PhysicalStructureReport, version: SQLFileVersion?) async {
        guard !isBusy, !closing, expected == report || expected == openedReport || history.contains(expected) else { error = StructureDraftFileError.changedDraft.localizedDescription; return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let text = try expected.encoded()
            _ = try await Task.detached { try SQLFileBinding.write(text, to: url, expectedVersion: version, maximumBytes: PhysicalStructureReport.maximumBytes) }.value
        } catch { self.error = error.localizedDescription }
    }
    func openReport(from url: URL) async {
        guard !isBusy, !closing else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let loaded = try await Task.detached { try SQLFileBinding.read(url, maximumBytes: PhysicalStructureReport.maximumBytes) }.value
            openedReport = try PhysicalStructureReport.decode(loaded.text)
            notice = "The opened report is historical evidence only. It has no live status, connection, grant or replay authority."
        } catch { self.error = error.localizedDescription }
    }
    func stop() async {
        stopRequested = true; preview = nil
        guard let sessionID, let queryID else { return }
        _ = try? await send(.cancel(sessionId: sessionID, queryId: queryID))
    }
    func beginClosing() -> Bool { guard !closing else { return false }; closing = true; return true }
    func cancelClosing() { closing = false }
    func close() async -> Bool {
        guard !isBusy, !checkingStatus else { return false }
        closing = true
        guard let sessionID else { return true }
        do {
            let value = try await send(.disconnect(sessionId: sessionID))
            guard value.type == "disconnect.ack", value.sessionId == sessionID else { throw BackendTransportError(.invalidMessage) }
        } catch {
            guard await helperIsClosed() else { closing = false; self.error = "The original physical session could not be closed. Retained evidence is kept."; return false }
        }
        self.sessionID = nil
        return true
    }
}

enum PhysicalReviewText {
    static func confirmation(_ plan: StructurePhysicalPlan) -> String {
        (["Apply this exact physical operation?", "Plan: " + plan.id, "Digest: " + plan.digest,
          "Transaction prerequisite: " + PhysicalOperationLabels.transaction(plan.transactionMode), "Expected locking: " + plan.locking,
          "Execution is never retried automatically. Interrupted concurrent indexes may remain INVALID and are never cleaned up automatically."] +
         plan.prerequisites + plan.risks + plan.consequences.map { $0.object + ": " + $0.message } +
         plan.objects.map { $0.target.schema + "." + $0.target.table + " · fingerprint " + $0.fingerprint } + plan.sql).joined(separator: "\n\n")
    }
}

enum PhysicalTransportAdmission {
    static func validate(_ value: StructurePhysicalReply?, command: BackendCommand) throws {
        guard let value, value.valid(for: command.type + ".result") else { throw BackendTransportError(.invalidMessage) }
        if let draft = command.structure?.physical?.draft, value.plan?.draft != draft { throw BackendTransportError(.invalidMessage) }
        if let apply = command.structure?.physical?.apply {
            guard value.outcome?.planId == apply.planId, value.outcome?.executionId == apply.executionId else { throw BackendTransportError(.invalidMessage) }
        }
        if let target = command.structure?.physical?.target, value.inspection?.objects.first?.target != target { throw BackendTransportError(.invalidMessage) }
    }
    static func matches(_ outcome: StructurePhysicalOutcome, plan: StructurePhysicalPlan) -> Bool {
        outcome.valid && outcome.planId == plan.id && outcome.steps.count == plan.sql.count
    }
    static func preserves(_ next: StructurePhysicalOutcome, previous: StructurePhysicalOutcome, preserveUnknown: Bool = true) -> Bool {
        next.executionId == previous.executionId && next.planId == previous.planId && next.steps.count == previous.steps.count &&
            zip(next.steps, previous.steps).allSatisfy { next, old in
                (old.state != "applied" || next.state == "applied") &&
                (!["failed", "rolledBack"].contains(old.state) || next.state == old.state) &&
                (!preserveUnknown || old.state != "unknown" || next.state == "unknown")
            }
    }
}

enum PhysicalOperationLabels {
    static func outcome(_ state: String) -> String {
        switch state {
        case "applied": "Applied and acknowledged"
        case "failed": "Failed"
        case "partiallyApplied": "Partially applied"
        case "cancelled": "Cancelled"
        case "outcomeUnknown": "Outcome unknown"
        case "applying": "Applying"
        default: "Unavailable"
        }
    }
    static func transaction(_ mode: String) -> String {
        switch mode {
        case "transaction": "Dedicated transaction; commit acknowledgement required"
        case "outsideTransaction": "Idle dedicated session; runs outside a transaction"
        case "implicitCommit": "Implicit commit; DDL cannot be rolled back"
        default: "Unavailable"
        }
    }
    static func phase(_ phase: String) -> String {
        switch phase {
        case "metadataRecheck": "Rechecking reviewed metadata"
        case "running": "Statement dispatched; awaiting acknowledgement"
        case "acknowledged": "Statement completion acknowledged"
        case "finished": "Execution finished"
        default: "Unavailable"
        }
    }
    static func step(_ state: String) -> String {
        switch state {
        case "applied": "Applied and acknowledged"
        case "failed": "Server reported failure"
        case "notStarted": "No dispatch acknowledged"
        case "rolledBack": "Rolled back"
        case "unknown": "Outcome unknown"
        default: "Unavailable"
        }
    }
    static func label(_ kind: String) -> String {
        switch kind {
        case "concurrentIndex": "PostgreSQL concurrent index"
        case "onlineIndex": "MySQL index with explicit ALGORITHM / LOCK"
        case "partitionTable": "Partition an ordinary MySQL table"
        case "removePartitioning": "Remove MySQL partitioning"
        case "exchangePartition": "Exchange a MySQL partition with a table"
        case "createPartition": "Create PostgreSQL partition"
        case "attachPartition": "Attach PostgreSQL partition"
        case "detachPartition": "Detach PostgreSQL partition"
        case "finalizePartition": "Finalize pending PostgreSQL detach"
        case "addPartition": "Add RANGE / LIST partitions"
        case "reorganizePartition": "Reorganize RANGE / LIST partitions"
        case "dropPartition": "Drop selected partitions and their data"
        case "truncatePartition": "Truncate selected partition data"
        case "addHashPartitions": "Add HASH / KEY partitions"
        case "coalescePartitions": "Coalesce HASH / KEY partitions"
        case "storageEngine": "Convert MySQL storage engine"
        case "reorderColumns": "Reorder MySQL columns with COPY"
        default: kind
        }
    }
}
