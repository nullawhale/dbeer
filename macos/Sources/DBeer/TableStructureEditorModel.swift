import Combine
import Foundation

struct TableStructureExecutionReview: Identifiable, Sendable {
    var outcome: StructureOutcome
    let plan: StructurePlan
    let draft: StructureDraft
    var validation: StructureValidationOutcome? = nil
    var id: String { outcome.executionId }
}

struct TableStructureOutcomeRecord {
    let profileID: UUID
    let schema: String
    let table: String
    var review: TableStructureExecutionReview
    var outcome: StructureOutcome { review.outcome }
    func matchesTable(schema: String, table: String) -> Bool {
        guard StructureTarget.sameIdentifier(self.schema, schema) else { return false }
        return StructureTarget.sameIdentifier(self.table, table) ||
            ["applied", "outcomeUnknown"].contains(review.outcome.state) && review.plan.resultTarget.map { StructureTarget.sameIdentifier($0.table, table) } == true
    }
}

@MainActor
final class TableStructureEditorModel: ObservableObject, Identifiable {
    let id = UUID()
    let profile: SavedConnection
    let schema: String
    private let originalCreate: Bool
    @Published private(set) var closing = false
    @Published private(set) var create: Bool
    @Published var table: String { didSet { if !StructureTarget.sameIdentifier(table, oldValue) { baseline = nil; preview = nil; validation = nil } } }
    @Published var draft = StructureDraft(columns: [TableStructureEditorModel.emptyColumn]) {
        didSet {
            let required = draft.minimumAuthoringVersion
            if draft.authoringVersion != required {
                var normalized = draft; normalized.authoringVersion = required; draft = normalized
            }
            preview = nil
            validation = nil
        }
    }
    @Published private(set) var baseline: StructureBaseline?
    @Published private(set) var validation: StructureValidationOutcome?
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
    @Published private(set) var draftFileURL: URL?
    @Published private(set) var fileNotice: String?
    @Published private(set) var statusNotice: String?
    private(set) var draftFileVersion: SQLFileVersion?
    private var savedDraftDocument: StructureDraftDocument?
    private var restoredDraftDocument: StructureDraftDocument?
    private var sessionID: String?
    private var executionSessionID: String?
    private var sessionNeedsReplacement = false
    private var queryID: String?
    private var cancelRequested = false
    private let reconstructionSupported: () -> Bool
    private let destructiveSupported: () -> Bool
    private let confirmPlan: (StructurePlan, StructureDraft) async -> Bool
    private let authorizeValidation: (StructureApply, StructurePlan, String) async throws -> String?
    private let indexAuthoringSupported: () -> Bool
    private let authoringSupported: () -> Bool
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
         bindingIsCurrent: @escaping () -> Bool, authoringSupported: @escaping () -> Bool = { false }, indexAuthoringSupported: @escaping () -> Bool = { false }, destructiveSupported: @escaping () -> Bool = { false }, reconstructionSupported: @escaping () -> Bool = { false }, confirmPlan: @escaping (StructurePlan, StructureDraft) async -> Bool = { _, _ in false }, authorizeValidation: @escaping (StructureApply, StructurePlan, String) async throws -> String? = { _, _, _ in nil }, operationsAllowed: @escaping () -> Bool = { true }, sessionIsKnownClosed: @escaping () async -> Bool = { false }, changed: @escaping (TableStructureExecutionReview) -> Void) {
        self.profile = profile; self.schema = schema; self.table = table; self.create = create; self.originalCreate = create; self.history = history + historyReviews.map(\.outcome); self.historyReviews = historyReviews
        self.connect = connect; self.send = send; self.authorize = authorize; self.authoringSupported = authoringSupported; self.indexAuthoringSupported = indexAuthoringSupported
        self.reconstructionSupported = reconstructionSupported; self.destructiveSupported = destructiveSupported; self.confirmPlan = confirmPlan; self.authorizeValidation = authorizeValidation
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

    var destructiveAvailable: Bool { [.postgresql, .mysql, .mariadb, .sqlite].contains(profile.engine) && destructiveSupported() }
    func permitsAdvanced(_ kind: String) -> Bool { baseline?.advanced?.permits(kind) ?? true }
    var advancedDraftPermitted: Bool { baseline?.advanced?.permits(draft) ?? true }
    var reconstructionAvailable: Bool { permitsAdvanced("reconstruction") && [.postgresql, .mysql, .mariadb, .sqlite].contains(profile.engine) && reconstructionSupported() }
    var conversionAvailable: Bool { baseline?.advanced == nil && [.postgresql, .mysql, .mariadb].contains(profile.engine) && destructiveAvailable }
    var targetWasDropped: Bool { outcomeReview?.plan.droppedTarget == true && outcome?.state == "applied" }
    var indexAuthoringAvailable: Bool { profile.engine != .sqlite && indexAuthoringSupported() }
    private var authoringPermitted: Bool { (!needsAuthoring || authoringAvailable) && (!draft.requiresIndexAuthoring || indexAuthoringAvailable) && (!draft.requiresDestructiveAuthoring || destructiveAvailable) && (!draft.requiresReconstructionAuthoring || reconstructionAvailable) }
    var authoringAvailable: Bool { authoringSupported() }
    private var needsAuthoring: Bool { draft.requiresAuthoringV2 || !create && draft.columns.count > 1 }
    var canReconcileRenamedTarget: Bool { outcomeReview?.plan.resultTarget != nil && outcome?.state == "outcomeUnknown" }
    var canPreview: Bool { !isBusy && !closing && operationsAllowed() && !invalidated && baseline != nil && advancedDraftPermitted && draft.valid(for: profile.engine) && hasExactReconstructionOrder && authoringPermitted && outcome == nil && (operationSupport?.permits("structure.preview", legacyAllowed: true) ?? true) }
    var canApply: Bool { !isBusy && !closing && operationsAllowed() && !invalidated && preview != nil && authoringPermitted && outcome == nil && !profile.policy.readOnly && (operationSupport?.availability("structure.apply").map { $0.state == .available } ?? true) }
    var canValidateData: Bool {
        !isBusy && !closing && operationsAllowed() && !invalidated && destructiveAvailable &&
            preview?.validationChecks.isEmpty == false && authoringPermitted && outcome == nil &&
            (operationSupport?.permits("structure.validate", legacyAllowed: true) ?? true)
    }
    var reconstructionColumnNames: [String] { (baseline?.columns.map(\.name) ?? []) + draft.columns.map(\.name) }
    var hasExactReconstructionOrder: Bool {
        guard let order = draft.columnOrder else { return true }
        let expected = reconstructionColumnNames.map { Data($0.utf8) }
        let actual = order.map { Data($0.utf8) }
        return expected.count == actual.count && Set(expected).count == expected.count && Set(actual) == Set(expected)
    }
    func moveReconstructionColumn(at index: Int, by offset: Int) {
        guard !isBusy, !closing, !invalidated, outcome == nil, reconstructionAvailable,
              var order = draft.columnOrder, order.indices.contains(index), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        draft.columnOrder = order
        draft.allowDestructive = nil
    }
    var target: StructureTarget { .init(schema: schema, table: table, create: create) }
    var canCheckExecutionStatus: Bool {
        guard !isBusy, !closing, !invalidated, operationsAllowed(),
              let executionSessionID, sessionID == executionSessionID, let review = outcomeReview else { return false }
        return StructureTarget.sameIdentifier(schema, review.plan.target.schema) &&
            StructureTarget.sameIdentifier(table, review.plan.target.table)
    }

    @discardableResult func validateBinding() -> Bool {
        guard bindingIsCurrent() else {
            invalidated = true; preview = nil; baseline = nil; validation = nil
            error = "The connection or catalog changed. Close this draft and reopen it with the current connection."
            return false
        }
        return !invalidated
    }
    func invalidate() { invalidated = true; preview = nil; baseline = nil; validation = nil; error = "The catalog changed. Close and reopen this draft before applying any changes." }
    private func requireBinding() throws {
        guard validateBinding(), !cancelRequested, !closing, operationsAllowed() else { throw ExecutionPolicyError(message: "The structure operation was cancelled or its connection changed.") }
    }
    private func request(_ operation: String, _ payload: StructureRequest, authorization: String? = nil) async throws -> StructureReply {
        try requireBinding()
        guard let sessionID else { throw ExecutionPolicyError(message: "Open the dedicated structure session first.") }
        let query = UUID().uuidString; queryID = query
        defer { queryID = nil }
        let response: BackendMessage
        do {
            response = try await send(.init(type: "structure." + operation, requestId: UUID().uuidString,
                sessionId: sessionID, queryId: query, authorization: authorization, structure: payload))
        } catch {
            if error is BackendTransportError || (error as? BackendRemoteError)?.reply.connected == false {
                sessionNeedsReplacement = true
            }
            throw error
        }
        if response.connected == false { sessionNeedsReplacement = true }
        else if response.connected == true && response.transactionStatus == .idle { sessionNeedsReplacement = false }
        guard let reply = response.structure else { throw BackendTransportError(.invalidMessage) }
        if let support = response.operationSupport, support.engine != profile.engine || support.scope != .structure {
            throw BackendTransportError(.invalidMessage)
        }
        operationSupport = response.operationSupport
        return reply
    }
    func load(useResultTarget: Bool = false) async {
        guard !isBusy, !closing, !targetWasDropped, operationsAllowed(), target.valid, validateBinding() else { return }
        isBusy = true; cancelRequested = false; error = nil; preview = nil; validation = nil; statusNotice = nil
        let reconcilingExecution = outcomeReview != nil
        defer { isBusy = false }
        do {
            if sessionID != nil {
                let helperClosed = await sessionIsKnownClosed()
                try requireBinding()
                if sessionNeedsReplacement || helperClosed {
                    try await retireSessionForReload(helperClosed: helperClosed)
                }
            }
            if sessionID == nil {
                sessionID = try await connect()
                sessionNeedsReplacement = false
            }
            try requireBinding()
            let acknowledgedRename = outcome?.state == "applied"
            let renamedTarget = (useResultTarget || acknowledgedRename) ? outcomeReview?.plan.resultTarget : nil
            let requestedTarget = renamedTarget ?? (outcome != nil && (originalCreate || outcomeReview?.plan.droppedTarget == true) ? StructureTarget(schema: schema, table: table, create: true, reconcile: true) : target)
            let reply = try await request("load", .init(target: requestedTarget))
            try requireBinding()
            if restoredDraftDocument != nil {
                guard reply.baseline?.target == requestedTarget, target == requestedTarget else {
                    throw StructureDraftFileError.incompatibleTarget
                }
            }
            guard let freshBaseline = reply.baseline,
                  freshBaseline.engine == profile.engine.rawValue,
                  StructureTarget.sameIdentifier(freshBaseline.target.schema, requestedTarget.schema),
                  StructureTarget.sameIdentifier(freshBaseline.target.table, requestedTarget.table),
                  requestedTarget.reconcile == true || freshBaseline.target.create == requestedTarget.create else {
                throw BackendTransportError(.invalidMessage)
            }
            if let outcome { history.append(outcome) }
            if let outcomeReview, !historyReviews.contains(where: { $0.id == outcomeReview.id }) { historyReviews.append(outcomeReview) }
            if !StructureTarget.sameIdentifier(table, freshBaseline.target.table) { table = freshBaseline.target.table }
            baseline = freshBaseline; create = freshBaseline.target.create
            outcomeReview = nil
            outcome = nil
            executionSessionID = nil
            draft = restoredDraftDocument?.draft ?? .init(columns: create ? [Self.emptyColumn] : [])
            restoredDraftDocument = nil
            fileNotice = nil
            if reconcilingExecution {
                statusNotice = "Current structure loaded. Review retained intent and step evidence in Execution History before preparing a new preview."
            }
        } catch { self.error = error.localizedDescription }
    }
    /// Explicit reconciliation may replace an unusable database connection only
    /// after its owned session has positively closed or its helper has exited.
    private func retireSessionForReload(helperClosed: Bool) async throws {
        guard let originalSession = sessionID else { return }
        if !helperClosed {
            try requireBinding()
            do {
                let reply = try await send(.disconnect(sessionId: originalSession))
                guard reply.type == "disconnect.ack", reply.sessionId == originalSession else {
                    throw BackendTransportError(.invalidMessage)
                }
            } catch {
                guard await sessionIsKnownClosed() else { throw error }
            }
        }
        guard sessionID == originalSession else { throw BackendTransportError(.invalidMessage) }
        sessionID = nil
        executionSessionID = nil
        sessionNeedsReplacement = false
        operationSupport = nil
        try requireBinding()
    }

    func preparePreview() async {
        guard canPreview, let baseline else { return }
        isBusy = true; cancelRequested = false; error = nil; preview = nil; validation = nil
        let frozen = draft
        defer { isBusy = false }
        do {
            let reply = try await request("preview", .init(baselineId: baseline.id, draft: frozen))
            try requireBinding()
            let expectedResult = frozen.renameTable.map { StructureTarget(schema: schema, table: $0, create: false) }
            guard draft == frozen, reply.plan?.valid == true, reply.plan?.baselineId.utf8.elementsEqual(baseline.id.utf8) == true, reply.plan?.target == target, reply.plan?.resultTarget == expectedResult, reply.plan?.droppedTarget == frozen.dropTable else { throw BackendTransportError(.invalidMessage) }
            preview = reply.plan
        } catch { self.error = error.localizedDescription }
    }
    /// Validation is an explicit authorized read of the reviewed checks. Preview never calls it.
    func validateData() async {
        guard canValidateData, let plan = preview, let sessionID, validateBinding() else { return }
        let frozen = draft
        let invocation = StructureApply(planId: plan.id, digest: plan.digest, executionId: UUID().uuidString)
        isBusy = true; cancelRequested = false; error = nil; validation = nil
        defer { isBusy = false }
        do {
            guard let authorization = try await authorizeValidation(invocation, plan, sessionID) else { return }
            try requireBinding()
            guard preview == plan, draft == frozen, destructiveAvailable else {
                throw ExecutionPolicyError(message: "The draft changed. Prepare a fresh preview before validation.")
            }
            let reply = try await request("validate", .init(validation: invocation), authorization: authorization)
            guard validateBinding(), !closing, operationsAllowed() else { return }
            guard preview == plan, draft == frozen, reply.valid(for: "structure.validate.result"),
                  let report = reply.validation, report.executionId.utf8.elementsEqual(invocation.executionId.utf8),
                  report.planId.utf8.elementsEqual(plan.id.utf8), report.digest == plan.digest,
                  report.checks.map({ Data($0.id.utf8) }) == plan.validationChecks.map({ Data($0.id.utf8) }) else { throw BackendTransportError(.invalidMessage) }
            validation = report
        } catch { self.error = error.localizedDescription }
    }
    func apply() async {
        guard canApply, let plan = preview, let sessionID, validateBinding() else { return }
        isBusy = true; cancelRequested = false; error = nil
        let reviewedDraft = draft
        let reviewedValidation = validation
        let apply = StructureApply(planId: plan.id, digest: plan.digest, executionId: UUID().uuidString)
        defer { isBusy = false; isApplying = false }
        do {
            if plan.requiresDestructiveAuthoring || reviewedDraft.requiresDestructiveAuthoring || reviewedDraft.hasReconstructionIntent {
                guard await confirmPlan(plan, reviewedDraft) else { return }
                try requireBinding()
                guard preview == plan, draft == reviewedDraft, authoringPermitted else {
                    throw ExecutionPolicyError(message: "The draft changed. Prepare a fresh preview.")
                }
            }
            guard let authorization = try await authorize(apply, plan, sessionID) else { return }
            try requireBinding()
            guard preview == plan, draft == reviewedDraft, authoringPermitted else { throw ExecutionPolicyError(message: "The draft changed. Prepare a fresh preview.") }
            isApplying = true
            executionSessionID = sessionID
            let reply = try await request("apply", .init(apply: apply), authorization: authorization)
            guard reply.valid(for: "structure.apply.result"), let acknowledged = reply.outcome,
                  matchesExecution(acknowledged, plan: plan, executionID: apply.executionId) else {
                throw BackendTransportError(.invalidMessage, outcomeUnknown: true)
            }
            // Preserve authoritative execution evidence even if the profile changed in flight.
            outcome = reply.outcome; preview = nil; baseline = nil
            if let observed = outcome?.observed { create = observed.target.create }
            else if outcome?.state == "applied" { create = false }
            if let outcome { let review = TableStructureExecutionReview(outcome: outcome, plan: plan, draft: reviewedDraft, validation: reviewedValidation); outcomeReview = review; changed(review) }
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
                preview = nil; baseline = nil; if let outcome { let review = TableStructureExecutionReview(outcome: outcome, plan: plan, draft: reviewedDraft, validation: reviewedValidation); outcomeReview = review; changed(review) }
            }
        }
    }
    /// Reads the retained report from the original helper session. It never starts
    /// another connection or executes a reviewed SQL step.
    func checkExecutionStatus() async {
        guard canCheckExecutionStatus, let review = outcomeReview, let originalSession = sessionID,
              validateBinding() else { return }
        let originalTarget = target
        let originalDraft = draft
        isBusy = true
        cancelRequested = false
        error = nil
        statusNotice = nil
        defer { isBusy = false }
        do {
            let helperClosed = await sessionIsKnownClosed()
            try requireBinding()
            guard !helperClosed else {
                statusNotice = "The original structure helper is unavailable. Retained execution evidence is kept. Inspect the database before preparing another preview."
                return
            }
            let reply = try await request("status", .init())
            try requireBinding()
            guard sessionID == originalSession, target == originalTarget, draft == originalDraft,
                  outcomeReview?.id == review.id, outcomeReview?.plan == review.plan,
                  reply.valid(for: "structure.status.result") else {
                throw BackendTransportError(.invalidMessage)
            }
            guard let retained = reply.outcome else {
                statusNotice = "The original helper has no retained report. Inspect and load the current structure to resolve the existing outcome."
                return
            }
            guard matchesExecution(retained, plan: review.plan, executionID: review.id),
                  preservesAcknowledgements(retained, from: review.outcome, plan: review.plan) else {
                throw BackendTransportError(.invalidMessage)
            }
            if let report = reply.validation {
                guard report.valid, report.planId.utf8.elementsEqual(review.plan.id.utf8), report.digest == review.plan.digest,
                      report.checks.map({ Data($0.id.utf8) }) == review.plan.validationChecks.map({ Data($0.id.utf8) }) else {
                    throw BackendTransportError(.invalidMessage)
                }
            }
            var updated = review
            updated.outcome = retained
            if let report = reply.validation { updated.validation = report }
            outcomeReview = updated
            outcome = retained
            baseline = nil
            preview = nil
            validation = nil
            if let observed = retained.observed { create = observed.target.create }
            else if retained.state == "applied" { create = false }
            if StructureTarget.intentBytes(retained) != StructureTarget.intentBytes(review.outcome) ||
                StructureTarget.intentBytes(updated.validation) != StructureTarget.intentBytes(review.validation) {
                changed(updated)
            }
            switch retained.state {
            case "applying":
                statusNotice = "The original execution is still in progress. Check its status again after completion."
            case "outcomeUnknown":
                statusNotice = "The helper still reports an unknown outcome. Inspect and load the current structure before another preview."
            default:
                statusNotice = "Retained execution acknowledgement loaded. Load the current structure before preparing another preview."
            }
        } catch {
            self.error = "Execution status could not be verified. Retained execution evidence is kept. " + error.localizedDescription
        }
    }

    private func matchesExecution(_ value: StructureOutcome, plan: StructurePlan, executionID: String) -> Bool {
        guard value.valid, value.executionId.utf8.elementsEqual(executionID.utf8),
              value.planId.utf8.elementsEqual(plan.id.utf8), value.steps.count == plan.sql.count,
              value.droppedTarget == (plan.droppedTarget && value.state == "applied") else { return false }
        guard let observed = value.observed else { return true }
        let expected = value.state == "applied" ? plan.resultTarget ?? plan.target : plan.target
        return observed.engine == profile.engine.rawValue && (observed.target.create == (plan.droppedTarget && value.state == "applied")) &&
            StructureTarget.sameIdentifier(observed.target.schema, expected.schema) &&
            StructureTarget.sameIdentifier(observed.target.table, expected.table)
    }

    private func preservesAcknowledgements(_ value: StructureOutcome, from previous: StructureOutcome, plan: StructurePlan) -> Bool {
        guard previous.steps.count == plan.sql.count else { return true }
        return previous.steps.indices.allSatisfy { index in
            previous.steps[index].state != "applied" || value.steps[index].state == "applied"
        }
    }

    var portableDraft: StructureDraftDocument {
        if let review = outcomeReview {
            return .init(engine: profile.engine, target: review.plan.target, draft: review.draft)
        }
        return .init(engine: profile.engine, target: target, draft: draft)
    }
    var canSaveDraft: Bool { !isBusy && !closing && portableDraft.valid }
    var canOpenDraft: Bool { !isBusy && !closing && !invalidated && outcome == nil }
    var draftFileLabel: String? {
        guard let draftFileURL else { return nil }
        return draftFileURL.lastPathComponent + (savedDraftDocument == portableDraft ? " · Saved" : " · Edited")
    }
    var exportablePlan: StructurePlan? { preview ?? outcomeReview?.plan }

    func saveDraft(to url: URL, expectedDocument: StructureDraftDocument, expectedVersion: SQLFileVersion?) async {
        guard canSaveDraft else { return }
        guard portableDraft == expectedDocument else { error = StructureDraftFileError.changedDraft.localizedDescription; return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let version = try await Task.detached {
                try StructureDraftStore.write(expectedDocument, to: url, expectedVersion: expectedVersion)
            }.value
            draftFileURL = url
            draftFileVersion = version
            savedDraftDocument = expectedDocument
        } catch { self.error = error.localizedDescription }
    }

    func openDraft(from url: URL, expectedDocument: StructureDraftDocument, replaceReviewed: Bool) async {
        guard canOpenDraft else { return }
        guard portableDraft == expectedDocument, !hasDraft || replaceReviewed else {
            error = StructureDraftFileError.changedDraft.localizedDescription
            return
        }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let loaded = try await Task.detached { try StructureDraftStore.read(url) }.value
            let document = loaded.document
            guard document.engine == profile.engine, StructureTarget.sameIdentifier(document.target.schema, schema),
                  document.target.create == create,
                  StructureTarget.sameIdentifier(document.target.table, table) || create && table.isEmpty else {
                throw StructureDraftFileError.incompatibleTarget
            }
            guard portableDraft == expectedDocument, outcome == nil, validateBinding() else {
                throw StructureDraftFileError.changedDraft
            }
            table = document.target.table
            baseline = nil
            preview = nil
            operationSupport = nil
            draft = document.draft
            restoredDraftDocument = document
            draftFileURL = url
            draftFileVersion = loaded.version
            savedDraftDocument = document
            fileNotice = "Draft opened. Load current structure and prepare a fresh Preview SQL before Apply."
        } catch { self.error = error.localizedDescription }
    }

    func exportSQL(to url: URL, expectedPlan: StructurePlan, expectedVersion: SQLFileVersion?) async {
        guard !isBusy, !closing, exportablePlan == expectedPlan else {
            error = StructureDraftFileError.changedDraft.localizedDescription
            return
        }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let text = try StructureDraftStore.sql(expectedPlan)
            _ = try await Task.detached {
                try SQLFileBinding.write(text, to: url, expectedVersion: expectedVersion)
            }.value
            fileNotice = "Reviewed SQL saved. Review the current destination before executing the file."
        } catch { self.error = error.localizedDescription }
    }

    func setFileError(_ value: any Error) { error = value.localizedDescription }

    func discard(forClosing: Bool = false) {
        guard !isBusy, forClosing || !closing else { return }
        restoredDraftDocument = nil
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
