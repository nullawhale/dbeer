import Combine
import Foundation

@MainActor
final class MigrationComposerModel: ObservableObject, Identifiable {
    let id = UUID()
    let profile: SavedConnection
    let initialTarget: StructureTarget
    @Published var draft = StructureMigrationDraft(version: 1, objects: [], repairs: []) { didSet { preview = nil } }
    @Published private(set) var preview: StructureMigrationPlan?
    @Published private(set) var report: MigrationExecutionDocument?
    @Published private(set) var history: [MigrationExecutionDocument]
    @Published private(set) var observations: [StructureBaseline] = []
    @Published private(set) var repairBaseline: StructureBaseline?
    @Published private(set) var objectEditor: TableStructureEditorModel?
    @Published private(set) var isBusy = false
    @Published private(set) var isApplying = false
    @Published private(set) var closing = false
    @Published private(set) var invalidated = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var reconciliationRequired = false
    @Published private(set) var retainedIntentNeedsReview = false
    @Published private(set) var draftFileURL: URL?
    private(set) var draftFileVersion: SQLFileVersion?
    private var savedDocument: MigrationDraftDocument?
    private var sessionID: String?
    private var executionSessionID: String?
    private var sessionUnavailable = false
    private var queryID: String?
    private var stopRequested = false
    private var editingObjectID: String?
    private let connect: () async throws -> String
    private let send: (BackendCommand) async throws -> BackendMessage
    private let authorize: (StructureApply, StructureMigrationPlan, String) async throws -> String?
    private let bindingIsCurrent: () -> Bool
    private let operationsAllowed: () -> Bool
    private let helperIsClosed: () async -> Bool
    private let changed: (MigrationExecutionDocument) -> Void

    init(profile: SavedConnection, initialTarget: StructureTarget, history: [MigrationExecutionDocument] = [], connect: @escaping () async throws -> String,
         send: @escaping (BackendCommand) async throws -> BackendMessage,
         authorize: @escaping (StructureApply, StructureMigrationPlan, String) async throws -> String?,
         bindingIsCurrent: @escaping () -> Bool, operationsAllowed: @escaping () -> Bool = { true },
         helperIsClosed: @escaping () async -> Bool = { false }, changed: @escaping (MigrationExecutionDocument) -> Void = { _ in }) {
        self.profile = profile; self.initialTarget = initialTarget; self.history = history; self.connect = connect; self.send = send; self.authorize = authorize
        self.bindingIsCurrent = bindingIsCurrent; self.operationsAllowed = operationsAllowed; self.helperIsClosed = helperIsClosed; self.changed = changed
    }
    var editable: Bool { !isBusy && !closing && !invalidated && !reconciliationRequired && !retainedIntentNeedsReview && report == nil }
    var canPreview: Bool { editable && objectEditor == nil && operationsAllowed() && draft.valid && !sessionUnavailable }
    var canApply: Bool { editable && objectEditor == nil && operationsAllowed() && preview != nil && !profile.policy.readOnly && !sessionUnavailable }
    var canReconcile: Bool { !isBusy && !closing && !invalidated && report != nil && operationsAllowed() && !sessionUnavailable }
    var canCheckStatus: Bool { !isBusy && !closing && !invalidated && executionSessionID != nil && executionSessionID == sessionID && operationsAllowed() }
    var hasIntent: Bool { !draft.objects.isEmpty || !draft.repairs.isEmpty }
    var portableDraft: MigrationDraftDocument { .init(draft: draft) }
    var draftFileLabel: String? { draftFileURL.map { $0.lastPathComponent + (savedDocument == portableDraft ? " · Saved" : " · Edited") } }
    var exportablePlan: StructureMigrationPlan? { preview ?? report?.plan }

    func invalidate() { invalidated = true; preview = nil; objectEditor?.invalidate(); error = "The connection or catalog changed. Retained intent and reports are kept. Close and reopen with the current connection." }
    private func requireBinding() throws {
        guard bindingIsCurrent(), !invalidated, !closing, !stopRequested, operationsAllowed() else {
            if !bindingIsCurrent() { invalidated = true; preview = nil }
            throw ExecutionPolicyError(message: "The migration was stopped or its connection changed. Retained evidence is kept.")
        }
    }
    private func ensureSession() async throws -> String {
        try requireBinding()
        guard !sessionUnavailable else { throw ExecutionPolicyError(message: "The original migration connection is unavailable. Check retained status, save the intent and report, then explicitly reopen on a fresh connection.") }
        if let sessionID { return sessionID }
        let fresh = try await connect()
        // Retain ownership even if the origin changes while connecting, so Close
        // still disconnects the newly created dedicated session.
        sessionID = fresh
        try requireBinding()
        return fresh
    }
    private func request(_ operation: String, _ payload: StructureMigrationRequest = .init(), authorization: String? = nil) async throws -> StructureMigrationReply {
        try requireBinding()
        guard let sessionID else { throw BackendTransportError(.notReady) }
        if sessionUnavailable && operation != "status" && operation != "close" { throw BackendTransportError(.notReady) }
        let query = UUID().uuidString; queryID = query
        defer { queryID = nil }
        do {
            let command = BackendCommand(type: "structure.migration." + operation, requestId: UUID().uuidString,
                sessionId: sessionID, queryId: query, authorization: authorization, structure: .init(migration: payload))
            let reply = try await send(command)
            if reply.connected == false { sessionUnavailable = true }
            guard reply.type == command.terminalType, let value = reply.structure?.migration,
                  value.valid(for: reply.type) else { throw BackendTransportError(.invalidMessage) }
            return value
        } catch {
            if error is BackendTransportError || (error as? BackendRemoteError)?.reply.connected == false { sessionUnavailable = true }
            throw error
        }
    }
    func preparePreview() async {
        guard canPreview else { return }
        let frozen = draft
        isBusy = true; error = nil; notice = nil; stopRequested = false; preview = nil
        defer { isBusy = false }
        do {
            _ = try await ensureSession()
            let reply = try await request("preview", .init(draft: frozen))
            try requireBinding()
            guard draft == frozen, let plan = reply.plan, plan.valid, plan.engine == profile.engine.rawValue,
                  plan.draft == frozen, reply.draft == frozen else { throw BackendTransportError(.invalidMessage) }
            preview = plan
        } catch { self.error = error.localizedDescription }
    }
    func apply() async {
        guard canApply, let plan = preview, let owner = sessionID else { return }
        let frozen = draft
        let invocation = StructureApply(planId: plan.id, digest: plan.digest, executionId: UUID().uuidString)
        isBusy = true; error = nil; notice = nil; stopRequested = false
        defer { isBusy = false; isApplying = false }
        do {
            // Every migration requires exact whole-plan review, including every repair.
            guard let grant = try await authorize(invocation, plan, owner) else { return }
            try requireBinding()
            guard draft == frozen, StructureTarget.intentBytes(preview) == StructureTarget.intentBytes(Optional(plan)), sessionID == owner else { throw StructureDraftFileError.changedDraft }
            executionSessionID = owner; isApplying = true
            let reply = try await request("apply", .init(apply: invocation), authorization: grant)
            guard let outcome = reply.outcome, outcome.executionId == invocation.executionId,
                  MigrationTransportAdmission.matches(outcome, plan: plan) else { throw BackendTransportError(.invalidMessage, outcomeUnknown: true) }
            retain(.init(plan: plan, outcome: outcome))
            if let retained = reply.draft { draft = retained }
            if !bindingIsCurrent() { invalidate() }
        } catch {
            self.error = error.localizedDescription
            guard isApplying else { return }
            let remote = (error as? BackendRemoteError)?.reply
            let unknown = (error as? BackendTransportError)?.outcomeUnknown ?? (remote.map { $0.outcomeUnknown == true || $0.sqlNotExecuted != true } ?? true)
            let state = unknown ? "outcomeUnknown" : (stopRequested ? "cancelled" : "failed")
            let outcomes = plan.steps.map { step in StructureMigrationStepOutcome(id: step.id, state: unknown ? "outcomeUnknown" : "notStarted",
                statements: step.sql.map { _ in .init(state: unknown ? "unknown" : "notStarted", message: unknown ? "Completion was lost. This statement may have run; reconciliation is required." : "No execution was acknowledged.") }) }
            retain(.init(plan: plan, outcome: .init(planId: plan.id, executionId: invocation.executionId, state: state, steps: outcomes, reconciliationRequired: true)))
        }
    }
    private func retain(_ value: MigrationExecutionDocument) {
        report = value; preview = nil; reconciliationRequired = true; retainedIntentNeedsReview = true
        changed(value)
    }
    func checkStatus() async {
        guard canCheckStatus, let old = report else { return }
        isBusy = true; error = nil; stopRequested = false
        defer { isBusy = false }
        do {
            guard !(await helperIsClosed()) else { throw BackendTransportError(.notReady) }
            let reply = try await request("status")
            guard let outcome = reply.outcome, outcome.executionId == old.id,
                  MigrationTransportAdmission.matches(outcome, plan: old.plan), MigrationTransportAdmission.preserves(outcome, previous: old.outcome) else { throw BackendTransportError(.invalidMessage) }
            // Status never grants a new preview or replaces editable intent.
            retain(.init(plan: old.plan, outcome: outcome))
            notice = "Retained acknowledgement loaded. Reconcile current structures explicitly before reviewing new intent."
        } catch { self.error = "Status could not be verified. The existing report is kept. " + error.localizedDescription }
    }
    func reconcile() async {
        guard canReconcile, let old = report else { return }
        isBusy = true; error = nil; stopRequested = false
        defer { isBusy = false }
        do {
            let reply = try await request("reconcile")
            try requireBinding()
            guard let retained = reply.draft, let observed = reply.observed, !observed.isEmpty,
                  observed.allSatisfy({ $0.engine == profile.engine.rawValue }), let outcome = reply.outcome,
                  outcome.executionId == old.id, MigrationTransportAdmission.matches(outcome, plan: old.plan),
                  MigrationTransportAdmission.preserves(outcome, previous: old.outcome), !outcome.reconciliationRequired else { throw BackendTransportError(.invalidMessage) }
            let updated = MigrationExecutionDocument(plan: old.plan, outcome: outcome)
            report = updated; changed(updated); observations = observed; draft = retained; reconciliationRequired = false
            notice = "Current structures observed. Review the retained selection and remove completed or obsolete intent before preparing another plan. No SQL was replayed."
        } catch { self.error = error.localizedDescription }
    }
    func reviewRetainedIntent() {
        guard !isBusy, !closing, !invalidated, !reconciliationRequired, let old = report else { return }
        if !history.contains(where: { $0.id == old.id }) { history.append(old) }
        report = nil; retainedIntentNeedsReview = false; preview = nil
        // Require renewed destructive consent when building a new plan.
        for index in draft.objects.indices { draft.objects[index].draft.allowDestructive = nil }
        notice = "Retained intent is editable. Every selected entry will be included in the next fresh Preview; remove completed work explicitly."
    }
    func removeObject(_ id: String) {
        guard editable else { return }
        draft.objects.removeAll { $0.id == id }
        for index in draft.objects.indices { draft.objects[index].after.removeAll { $0 == id } }
    }
    func setPrerequisite(objectID: String, prerequisiteID: String, selected: Bool) {
        guard editable, objectID != prerequisiteID, let i = draft.objects.firstIndex(where: { $0.id == objectID }), draft.objects.contains(where: { $0.id == prerequisiteID }) else { return }
        var values = draft.objects[i].after.filter { $0 != prerequisiteID }
        if selected { values.append(prerequisiteID) }
        draft.objects[i].after = values
    }
    func editObject(_ object: StructureMigrationObject?, target: StructureTarget) async {
        guard editable, target.valid, objectEditor == nil, object != nil || draft.objects.count < 16 else { return }
        isBusy = true; error = nil; stopRequested = false
        defer { isBusy = false }
        do {
            let owner = try await ensureSession()
            let editor = TableStructureEditorModel(profile: profile, schema: target.schema, table: target.table, create: target.create,
                connect: { owner }, send: send, authorize: { _, _, _ in nil }, bindingIsCurrent: bindingIsCurrent,
                authoringSupported: { true }, indexAuthoringSupported: { self.profile.engine != .sqlite }, destructiveSupported: { true }, reconstructionSupported: { true }, changed: { _ in })
            editingObjectID = object?.id; objectEditor = editor
            // Ordinary structure loads retire the helper's migration preview.
            preview = nil
            await editor.load()
            try requireBinding()
            guard objectEditor === editor, editor.baseline != nil, !editor.invalidated else { throw ExecutionPolicyError(message: editor.error ?? "The table structure could not be loaded.") }
            if let object { editor.draft = object.draft }
        } catch { objectEditor = nil; editingObjectID = nil; self.error = error.localizedDescription }
    }
    func stageObject() {
        guard editable, let editor = objectEditor, editor.baseline != nil,
              StructureDraftDocument(engine: profile.engine, target: editor.target, draft: editor.draft).valid else { return }
        let value = StructureMigrationObject(id: editingObjectID ?? UUID().uuidString, target: editor.target, draft: editor.draft,
            after: draft.objects.first(where: { $0.id == editingObjectID })?.after ?? [])
        guard !draft.objects.contains(where: { $0.id != value.id && $0.target == value.target }) else { error = "That table is already selected. Edit its existing intent."; return }
        if let i = draft.objects.firstIndex(where: { $0.id == value.id }) { draft.objects[i] = value }
        else if draft.objects.count < 16 { draft.objects.append(value) }
        objectEditor = nil; editingObjectID = nil
    }
    func cancelObjectEditor() { guard !isBusy else { return }; objectEditor = nil; editingObjectID = nil }
    func loadRepairTarget(_ target: StructureTarget) async {
        guard editable, target.valid, !target.create else { return }
        isBusy = true; error = nil; stopRequested = false; repairBaseline = nil
        defer { isBusy = false }
        do {
            let owner = try await ensureSession(); let query = UUID().uuidString; queryID = query
            defer { queryID = nil }
            // Even an owner read without selected repairs retires that preview.
            preview = nil
            let reply = try await send(.init(type: "structure.load", requestId: UUID().uuidString, sessionId: owner, queryId: query, structure: .init(target: target)))
            try requireBinding()
            guard let baseline = reply.structure?.baseline, baseline.target == target, baseline.engine == profile.engine.rawValue else { throw BackendTransportError(.invalidMessage) }
            repairBaseline = baseline
        } catch { self.error = error.localizedDescription }
    }
    func selectRepair(key: StructureKey) {
        guard editable, let baseline = repairBaseline, key.supported, key.kind == "foreign", draft.repairs.count < 16,
              !(draft.repairs.contains { $0.target == baseline.target && StructureTarget.sameIdentifier($0.key, key.name) }) else { return }
        // A user selects the exact owner and key; loading never selects repairs.
        let replacement = StructureKeyEdit(action: "add", kind: "foreign", name: key.name, columns: key.columns,
            reference: key.reference, referenceColumns: key.referenceColumns, onUpdate: key.onUpdate, onDelete: key.onDelete)
        draft.repairs.append(.init(id: UUID().uuidString, target: baseline.target, key: key.name, action: "replace", replacement: replacement))
    }
    func removeRepair(_ id: String) { guard editable else { return }; draft.repairs.removeAll { $0.id == id } }
    func setFileError(_ value: any Error) { error = value.localizedDescription }
    func saveDraft(to url: URL, expected: MigrationDraftDocument, version: SQLFileVersion?) async {
        guard !isBusy, !closing, portableDraft == expected else { error = StructureDraftFileError.changedDraft.localizedDescription; return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let text = try expected.encoded()
            let saved = try await Task.detached { try SQLFileBinding.write(text, to: url, expectedVersion: version, maximumBytes: MigrationDraftDocument.maximumBytes) }.value
            draftFileURL = url; draftFileVersion = saved.version; savedDocument = expected
        } catch { self.error = error.localizedDescription }
    }
    func openDraft(from url: URL, expected: MigrationDraftDocument) async {
        guard editable, sessionID == nil, portableDraft == expected else { error = "Open portable intent in a new disconnected migration composer."; return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let loaded = try await Task.detached { try SQLFileBinding.read(url, maximumBytes: MigrationDraftDocument.maximumBytes) }.value
            let document = try MigrationDraftDocument.decode(loaded.text)
            guard portableDraft == expected, sessionID == nil, !closing else { throw StructureDraftFileError.changedDraft }
            draft = document.draft; observations = []; preview = nil; repairBaseline = nil
            draftFileURL = url; draftFileVersion = loaded.version; savedDocument = document
            notice = "Portable intent opened disconnected. Review this destination, renew destructive opt-ins and request a fresh Preview."
        } catch { self.error = error.localizedDescription }
    }
    var canOpenDraft: Bool { editable && sessionID == nil }
    func saveReport(to url: URL, expected: MigrationExecutionDocument, version: SQLFileVersion?) async {
        guard !isBusy, !closing, report == expected || history.contains(expected) else { error = StructureDraftFileError.changedDraft.localizedDescription; return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let text = try expected.encoded()
            _ = try await Task.detached { try SQLFileBinding.write(text, to: url, expectedVersion: version, maximumBytes: MigrationExecutionDocument.maximumBytes) }.value
            notice = "The immutable reviewed plan and execution report were saved independently of the editable draft."
        } catch { self.error = error.localizedDescription }
    }
    func openReport(from url: URL) async {
        guard !isBusy, !closing else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let loaded = try await Task.detached { try SQLFileBinding.read(url, maximumBytes: MigrationExecutionDocument.maximumBytes) }.value
            let value = try MigrationExecutionDocument.decode(loaded.text)
            if !history.contains(where: { $0.id == value.id }) { history.append(value) }
            notice = "Saved evidence opened for review. It cannot authorize, reconcile or replay an execution."
        } catch { self.error = error.localizedDescription }
    }
    func exportSQL(to url: URL, expected: StructureMigrationPlan, version: SQLFileVersion?) async {
        guard !isBusy, !closing, StructureTarget.intentBytes(exportablePlan) == StructureTarget.intentBytes(Optional(expected)) else { error = StructureDraftFileError.changedDraft.localizedDescription; return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            // Export binds to the exact immutable reviewed SQL, including historical plans.
            let text = MigrationReviewText.sql(expected)
            _ = try await Task.detached { try SQLFileBinding.write(text, to: url, expectedVersion: version, maximumBytes: 8 * 1_024 * 1_024) }.value
            notice = "Reviewed SQL exported for manual execution. The file carries no freshness checks or execution authority."
        } catch { self.error = error.localizedDescription }
    }
    func stop() async {
        stopRequested = true
        await objectEditor?.stop()
        guard let sessionID, let queryID else { return }
        _ = try? await send(.cancel(sessionId: sessionID, queryId: queryID))
    }
    func beginClosing() -> Bool { guard !closing else { return false }; closing = true; return true }
    func cancelClosing() { closing = false }
    func close() async -> Bool {
        guard !isBusy else { return false }
        closing = true
        guard let sessionID else { return true }
        do {
            let reply = try await send(.disconnect(sessionId: sessionID))
            guard reply.type == "disconnect.ack", reply.sessionId == sessionID else { throw BackendTransportError(.invalidMessage) }
        } catch {
            guard await helperIsClosed() else { closing = false; self.error = "The migration session could not be closed. Retained evidence is kept; wait for completion and try again."; return false }
        }
        self.sessionID = nil; executionSessionID = nil; objectEditor = nil
        return true
    }
}

enum MigrationReviewText {
    static func sql(_ plan: StructureMigrationPlan) -> String {
        func comment(_ value: String) -> String { value.components(separatedBy: .newlines).map { "-- " + $0 }.joined(separator: "\n") }
        let warnings = plan.risks.flatMap { $0.components(separatedBy: .newlines) }.map { "-- Warning: " + $0 }
        let header = ["-- DBeer reviewed migration: MANUAL execution.", comment("Plan: " + plan.id), comment("Digest: " + plan.digest),
            "-- The whole migration is non-atomic. Earlier committed groups survive later failure.",
            "-- Review this destination. This file carries no freshness checks, authorization or outcome tracking."] + warnings
        let steps = plan.steps.enumerated().map { i, step in
            let consequences = (step.consequences ?? []).flatMap { ($0.object + ": " + $0.message).components(separatedBy: .newlines) }.map { "-- Consequence: " + $0 }
            let risks = step.risks.map { comment("Warning: " + $0) }
            return ([comment("Step \(i + 1): " + step.id + " · " + step.phase), comment("Digest: " + step.digest)] + risks + consequences + step.sql).joined(separator: "\n")
        }
        return header.joined(separator: "\n") + "\n\n" + steps.joined(separator: "\n\n") + "\n"
    }
    static func confirmation(_ plan: StructureMigrationPlan) -> String {
        "Apply every exact reviewed migration group and selected repair?\n\n" + sql(plan) + "\n" + plan.steps.map { step in
            "Expected before " + step.id + ": " + step.before.map { $0.target.schema + "." + $0.target.table + " at " + $0.initialFingerprint + " after [" + $0.afterSteps.joined(separator: ", ") + "]" }.joined(separator: "; ") +
            "\nExpected after: " + step.after.map { $0.target.schema + "." + $0.target.table + " after [" + $0.afterSteps.joined(separator: ", ") + "]" }.joined(separator: "; ") +
            "\n" + step.risks.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
