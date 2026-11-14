import Combine
import Foundation

struct TuningExecutionError: LocalizedError {
    let message: String
    let outcomeUnknown: Bool
    var errorDescription: String? { message + (outcomeUnknown ? " The acknowledgement is unknown. No operation was repeated or restored." : "") }
}

@MainActor
final class TuningPanelModel: ObservableObject, Identifiable {
    let id = UUID()
    let plan: ExplainPlanModel
    let collector: ExplainCollector
    @Published var configuration: ExplainCollectorConfiguration
    @Published private(set) var inspection: TuningInspection?
    @Published private(set) var validation: TuningValidation?
    @Published private(set) var settingObservation: TuningSettingObservation?
    @Published private(set) var settingResult: TuningSettingResult?
    @Published private(set) var status = "Choose an explicit action. Captured evidence is untrusted advice input."
    @Published private(set) var isBusy = false
    private var generation = UUID()
    private let readOnly: @MainActor () -> Bool
    private let current: @MainActor () -> Bool
    private var observedEpoch: UUID?
    private var settingEpoch: UUID?
    private var optimizerInspectionEpoch: UUID?
    private let operationEpoch: @MainActor () -> UUID
    private let transaction: @MainActor () -> TransactionStatus?
    private let send: @MainActor (BackendCommand) async throws -> BackendMessage
    private let authorize: @MainActor (OperationRequest, String) async throws -> String?
    private let adopt: @MainActor (ExplainRequest) -> Void
    private let editIndex: @MainActor (StructureTarget, StructureIndexEdit) async -> Void
    private let cancel: @MainActor () async -> Void
    private let startCollector: @MainActor (ExplainCollectorConfiguration) -> Void
    private let persistConfiguration: @MainActor (ExplainCollectorConfiguration) -> Void

    init(plan: ExplainPlanModel, collector: ExplainCollector, configuration: ExplainCollectorConfiguration,
         current: @escaping @MainActor () -> Bool, readOnly: @escaping @MainActor () -> Bool = { false }, operationEpoch: @escaping @MainActor () -> UUID, transaction: @escaping @MainActor () -> TransactionStatus?,
         send: @escaping @MainActor (BackendCommand) async throws -> BackendMessage,
         authorize: @escaping @MainActor (OperationRequest, String) async throws -> String?,
         adopt: @escaping @MainActor (ExplainRequest) -> Void,
         editIndex: @escaping @MainActor (StructureTarget, StructureIndexEdit) async -> Void,
         cancel: @escaping @MainActor () async -> Void,
         startCollector: @escaping @MainActor (ExplainCollectorConfiguration) -> Void,
         persistConfiguration: @escaping @MainActor (ExplainCollectorConfiguration) -> Void) {
        self.plan = plan; self.collector = collector; self.configuration = configuration
        self.current = current; self.readOnly = readOnly; self.operationEpoch = operationEpoch; self.transaction = transaction; self.send = send; self.authorize = authorize
        self.adopt = adopt; self.editIndex = editIndex; self.cancel = cancel
        self.startCollector = startCollector; self.persistConfiguration = persistConfiguration
    }
    var currentReason: String? {
        if !current() { return "The original document, typed parameter definitions, profile or physical SQL owner changed. Collect a new plan and reopen tuning." }
        return nil
    }
    var inspectReason: String? { currentReason ?? (transaction() != .idle ? "Inspection and result validation need an idle SQL owner; existing transactions, temporary and uncommitted contexts are unsupported." : nil) }
    var settingReason: String? {
        currentReason ?? (plan.result?.support.engine != .postgresql ? "Transaction-local work_mem is PostgreSQL only." : transaction() != .transaction ? "Begin a transaction explicitly in the SQL editor before observing or changing work_mem." : nil)
    }
    var settingChangeReason: String? { settingReason ?? (readOnly() ? "Readonly policy permits observation and denies setting changes or restore." : nil) }
    var optimizerReason: String? {
        inspectReason ?? (readOnly() ? "Readonly policy denies optimizer setting trials." :
            plan.result?.support.engine != .mariadb || plan.request.mode != .plan ? "Optimizer trials need an estimated MariaDB read plan." :
            inspection?.mariaDBOptimizer == nil || optimizerInspectionEpoch != operationEpoch() ? "Inspect current metadata and optimizer state before a trial." : nil)
    }
    var collectorReason: String? {
        inspectReason ?? (plan.request.mode != .plan || plan.request.writeIntent != nil || ExplainDMLAdmission.possibleDML(plan.request.sql, engine: plan.result?.support.engine ?? .postgresql) ? "Background collection accepts estimated read plans only. Each capture needs a fresh allow assessment; writes and review-required queries stop collection." : nil)
    }
    private func context() throws -> ExplainContext {
        guard current(), var context = plan.request.context, let transaction = transaction() else { throw ExecutionPolicyError(message: currentReason ?? "The source context is unavailable.") }
        context.transactionStatus = transaction.rawValue
        return context
    }
    private func perform(_ work: @MainActor (UUID) async throws -> Void) async {
        guard !isBusy else { return }
        let token = generation; isBusy = true
        defer { if token == generation { isBusy = false } }
        do { try await work(token) }
        catch { if token == generation { status = error.localizedDescription } }
    }
    private func valid(_ token: UUID) throws {
        guard token == generation, current(), !Task.isCancelled else { throw CancellationError() }
    }
    func inspect(schema: String, table: String) async {
        await perform { token in
            guard inspectReason == nil, let capture = plan.result else { throw ExecutionPolicyError(message: inspectReason ?? "Captured evidence is unavailable.") }
            var source = plan.request; source.context = try context()
            let target = StructureTarget(schema: schema, table: table, create: false)
            let request = TuningInspectRequest(version: 1, source: source, capture: capture, target: target)
            guard request.valid else { throw ExecutionPolicyError(message: "Enter one qualified ordinary table. This source is not eligible for tuning inspection.") }
            inspection = nil; validation = nil; optimizerInspectionEpoch = nil
            let reply = try await send(.tuningInspect(sessionId: source.context!.sessionId, request: request))
            try valid(token); inspection = reply.tuningInspection
            if inspection?.mariaDBOptimizer != nil { optimizerInspectionEpoch = operationEpoch() }
            status = "Metadata inspected. Recommendations predict neither equivalence nor speedup."
        }
    }
    func validateOptimizer() async {
        await perform { token in
            guard optimizerReason == nil, let inspection, let observed = inspection.mariaDBOptimizer else {
                throw ExecutionPolicyError(message: optimizerReason ?? "Inspect optimizer state before a trial.")
            }
            var original = plan.request; original.context = try context()
            let setting = MariaDBOptimizerVariant(expectedNativeSwitch: observed.nativeSwitch,
                indexConditionPushdown: !observed.indexConditionPushdown)
            let request = TuningValidationRequest(version: 1, original: original, variant: original,
                target: inspection.target, metadataFingerprint: inspection.metadataFingerprint,
                maxRows: 1_000, maxBytes: 1_048_576, timeoutMs: 5_000, comparison: "multiset", mariaDBOptimizer: setting)
            guard request.valid else { throw ExecutionPolicyError(message: "The optimizer trial is unavailable for this unchanged query and context.") }
            let preview = "Run two sequential SELECT observations on this existing idle MariaDB owner?\n\nOriginal:\n" + original.sql +
                "\n\nCandidate with a statement-scoped optimizer setting:\n" + TuningTransportAdmission.optimizerSQL(setting, sql: original.sql) +
                "\n\nAt most 1,000 rows each, 1 MiB combined native values and 5 seconds including metadata. The server restores the optimizer setting after this candidate statement. Current settings and transaction context are checked before and after acknowledged reads. Observed equality does not prove equivalence or speed; no retry or automatic recovery operation is issued."
            guard let grant = try await authorize(.init(type: "tuning.validate", tuningValidation: request), preview) else {
                status = "Optimizer trial review cancelled"; return
            }
            try valid(token); guard transaction() == .idle else { throw CancellationError() }
            var command = BackendCommand.tuningValidate(sessionId: original.context!.sessionId, request: request)
            command.authorization = grant
            validation = nil; optimizerInspectionEpoch = nil
            let reply = try await send(command)
            try valid(token); validation = reply.tuningValidation
            status = "Optimizer trial completed. Inspect again before another trial; result equality does not establish equivalence or speed."
        }
    }
    func validate(_ variant: TuningVariant) async {
        await perform { token in
            guard inspectReason == nil, plan.request.mode == .plan, let inspection,
                  inspection.variants.contains(variant) else { throw ExecutionPolicyError(message: inspectReason ?? "Collect an estimated plan and inspect again before paired validation.") }
            var original = plan.request; original.context = try context()
            var candidate = variant.request
            candidate.context = original.context; candidate.context?.rangeLength = candidate.sql.utf16.count
            let request = TuningValidationRequest(version: 1, original: original, variant: candidate,
                target: inspection.target, metadataFingerprint: inspection.metadataFingerprint,
                maxRows: 1_000, maxBytes: 1_048_576, timeoutMs: 5_000, comparison: "multiset")
            guard request.valid else { throw ExecutionPolicyError(message: "This candidate cannot be validated with the unchanged original query, typed values and options.") }
            validation = nil
            let preview = "Run two sequential SELECT observations on this existing idle SQL owner?\n\nOriginal:\n" + original.sql +
                "\n\nUNVALIDATED CANDIDATE (not text in the original document):\n" + candidate.sql +
                "\n\nUp to 1,000 rows each, 1 MiB combined native-row retention and 5 seconds including metadata. Exact native types and duplicate multiplicity are compared as bags; ordering is ignored. These are sequential observations, not a guaranteed shared snapshot or proof of equivalence. No index or setting is changed."
            guard let grant = try await authorize(.init(type: "tuning.validate", tuningValidation: request), preview) else { status = "Validation review cancelled"; return }
            try valid(token)
            guard transaction() == .idle else { throw CancellationError() }
            var command = BackendCommand.tuningValidate(sessionId: original.context!.sessionId, request: request); command.authorization = grant
            let reply = try await send(command)
            try valid(token); validation = reply.tuningValidation
            status = "Result observation completed. Candidate remains unvalidated for other data, contexts or executions."
        }
    }
    func adoptVariant(_ variant: TuningVariant) {
        guard current(), !isBusy, inspection?.variants.contains(variant) == true else { return }
        adopt(variant.request.portable)
        status = "Candidate opened in a new SQL document. Normal Explain or execution needs that document's fresh context and review."
    }
    func openIndex(_ advice: TuningIndexAdvice) async {
        guard inspectReason == nil, !isBusy, let inspection, inspection.indexes.contains(advice) else { return }
        await editIndex(inspection.target, advice.edit)
    }
    func observeSetting() async {
        await perform { token in
            guard settingReason == nil else { throw ExecutionPolicyError(message: settingReason!) }
            let context = try context(); settingObservation = nil
            let reply = try await send(.tuningObserveSetting(sessionId: context.sessionId,
                request: .init(version: 1, context: context, name: "work_mem")))
            try valid(token); settingObservation = reply.tuningSettingObservation; observedEpoch = operationEpoch()
            status = "Observed work_mem in the current existing transaction. Older grants were retired."
        }
    }
    func setWorkMem(_ value: Int, restoring: Bool = false) async {
        await perform { token in
            guard settingChangeReason == nil, observedEpoch == operationEpoch(), let observed = settingObservation else { throw ExecutionPolicyError(message: settingChangeReason ?? "Observe the current transaction value first.") }
            let context = try context()
            let request: TuningSettingRequest
            if restoring {
                guard settingEpoch == operationEpoch(), var restore = settingResult?.restore, restore.context == context,
                      restore.expectedValueKiB == observed.workMemKiB else { throw ExecutionPolicyError(message: "Observe the unchanged current transaction before a separate restore review.") }
                restore.context = context; request = restore
            } else { request = .init(version: 1, context: context, name: "work_mem", expectedValueKiB: observed.workMemKiB, valueKiB: value) }
            guard request.valid else { throw ExecutionPolicyError(message: "Choose a different work_mem value from 64 through 1,048,576 KiB.") }
            let preview = TuningTransportAdmission.settingSQL(request.valueKiB) + "\n\nSeparate restore candidate:\n" + TuningTransportAdmission.settingSQL(request.expectedValueKiB) +
                "\n\nApplies only in this existing transaction. COMMIT/ROLLBACK ends it; rollback to an earlier savepoint may revert it. Memory is per operation/worker, not a total query cap. No transaction command or automatic restore/retry is issued."
            guard let grant = try await authorize(.init(type: "tuning.setting", tuningSetting: request), preview) else { status = "Setting review cancelled"; return }
            try valid(token); guard transaction() == .transaction else { throw CancellationError() }
            var command = BackendCommand.tuningSet(sessionId: context.sessionId, request: request); command.authorization = grant
            settingObservation = nil; settingResult = nil; observedEpoch = nil; settingEpoch = nil
            let reply = try await send(command)
            try valid(token); settingResult = reply.tuningSetting; settingEpoch = operationEpoch()
            settingObservation = nil
            status = "SET LOCAL acknowledged. Observe again before another change or a separately reviewed restore."
        }
    }
    func startCollection() {
        guard collectorReason == nil, !isBusy, configuration.valid else { status = collectorReason ?? "Collection bounds are invalid."; return }
        persistConfiguration(configuration); startCollector(configuration)
    }
    func close() async {
        generation = UUID()
        if isBusy { await cancel() }
        isBusy = false
    }
}
