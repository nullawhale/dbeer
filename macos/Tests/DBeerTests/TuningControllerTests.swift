import Foundation
import Testing
@testable import DBeer

/// Fully injected controller; filesystem paths are unused and no desktop or DB is touched.
@MainActor
private final class TuningControllerFixture {
    var current = true
    var transaction = TransactionStatus.idle
    var epoch = UUID()
    var currentKiB = 4_096
    var failSetting = false
    var changeDuringReview = false
    var sent: [BackendCommand] = []
    var reviewed: [OperationRequest] = []
    var adopted: [ExplainRequest] = []
    var edits: [StructureIndexEdit] = []
    var starts = 0
    var persisted: ExplainCollectorConfiguration?
    let inspect: TuningInspectRequest
    let inspection: TuningInspection
    let validation: TuningValidation
    init() throws {
        inspect = try TuningNativeFixture.decode(TuningInspectRequest.self, "inspectRequest")
        inspection = try TuningNativeFixture.decode(TuningInspection.self, "inspection")
        validation = try TuningNativeFixture.decode(TuningValidation.self, "validation")
    }
    func model() -> TuningPanelModel {
        var plan = ExplainPlanModel(request: inspect.source, sourceText: inspect.source.sql,
            sourceRange: NSRange(location: 0, length: inspect.source.sql.utf16.count), profileID: UUID())
        plan.result = inspect.capture
        let unused = TuningNativeFixture.root.appendingPathComponent("build/f7-native-test/unused-" + UUID().uuidString)
        return TuningPanelModel(plan: plan, collector: ExplainCollector(store: PlanArtifactStore(rootURL: unused)), configuration: .init(),
            current: { self.current }, operationEpoch: { self.epoch }, transaction: { self.transaction },
            send: { command in
                self.sent.append(command)
                switch command.type {
                case "tuning.inspect": return BackendMessage(type: "tuning.inspect.result", requestId: command.requestId,
                    sessionId: command.sessionId, queryId: command.queryId, transactionStatus: self.transaction, tuningInspection: self.inspection)
                case "tuning.validate": return BackendMessage(type: "tuning.validate.result", requestId: command.requestId,
                    sessionId: command.sessionId, queryId: command.queryId, transactionStatus: self.transaction, tuningValidation: self.validation)
                case "tuning.setting.observe": return BackendMessage(type: "tuning.setting.observe.result", requestId: command.requestId,
                    sessionId: command.sessionId, queryId: command.queryId, transactionStatus: self.transaction,
                    tuningSettingObservation: .init(version: 1, name: "work_mem", workMemKiB: self.currentKiB, scope: "currentTransaction"))
                case "tuning.setting":
                    if self.failSetting { throw TuningExecutionError(message: "Synthetic acknowledgement loss", outcomeUnknown: true) }
                    let setting = try #require(command.tuningSetting)
                    var restore = setting; restore.valueKiB = setting.expectedValueKiB; restore.expectedValueKiB = setting.valueKiB
                    self.currentKiB = setting.valueKiB
                    return BackendMessage(type: "tuning.setting.result", requestId: command.requestId,
                        sessionId: command.sessionId, queryId: command.queryId, transactionStatus: self.transaction,
                        tuningSetting: .init(version: 1, state: "applied", beforeKiB: setting.expectedValueKiB,
                            requestedKiB: setting.valueKiB, restore: restore, limitations: ["Synthetic current-transaction observation"]))
                default: throw CancellationError()
                }
            }, authorize: { operation, _ in self.reviewed.append(operation); if self.changeDuringReview { self.current = false }; return "fresh-grant" },
            adopt: { self.adopted.append($0) }, editIndex: { _, edit in self.edits.append(edit) }, cancel: {},
            startCollector: { _ in self.starts += 1 }, persistConfiguration: { self.persisted = $0 })
    }
}

struct TuningControllerTests {
    @Test @MainActor func onlyExplicitActionsInspectAdoptRouteIndexAndSeparatelyReviewValidation() async throws {
        let fixture = try TuningControllerFixture(); let model = fixture.model()
        #expect(fixture.sent.isEmpty && fixture.reviewed.isEmpty && fixture.starts == 0)
        await model.inspect(schema: "public", table: "items")
        let advice = try #require(model.inspection?.indexes.first)
        await model.openIndex(advice)
        #expect(fixture.edits == [advice.edit] && fixture.sent.count == 1)
        let variant = try #require(model.inspection?.variants.first)
        model.adoptVariant(variant)
        #expect(fixture.adopted.first?.context == nil && fixture.adopted.first?.writeIntent == nil)
        #expect(fixture.adopted.first?.sql == variant.request.sql && model.plan.request.sql == fixture.inspect.source.sql)
        #expect(fixture.reviewed.isEmpty)
        await model.validate(variant)
        let request = try #require(fixture.reviewed.first?.tuningValidation)
        #expect(fixture.reviewed.count == 1 && request.original.sql == fixture.inspect.source.sql)
        #expect(request.original.context?.documentId == request.variant.context?.documentId)
        #expect(request.original.context?.targetDocumentId == request.variant.context?.targetDocumentId)
        #expect(request.original.context?.rangeLocation == request.variant.context?.rangeLocation)
        #expect(request.variant.context?.rangeLength == variant.request.sql.utf16.count)
        #expect(request.original.parameters == request.variant.parameters && request.original.options == request.variant.options)
        #expect(model.validation?.complete == true && variant.validation == "unvalidated")
        #expect(fixture.sent.last?.authorization == "fresh-grant")
    }
    @Test @MainActor func changedOriginalDuringReviewNeverDispatchesCandidate() async throws {
        let fixture = try TuningControllerFixture(); let model = fixture.model()
        await model.inspect(schema: "public", table: "items")
        let variant = try #require(model.inspection?.variants.first)
        fixture.changeDuringReview = true
        await model.validate(variant)
        #expect(fixture.reviewed.count == 1 && fixture.sent.count == 1 && model.validation == nil)
        #expect(model.currentReason != nil)
    }
    @Test @MainActor func openTransactionCannotInspectOrValidateAndRestoreNeedsFreshReviewAndSameEpoch() async throws {
        let fixture = try TuningControllerFixture(); let model = fixture.model()
        fixture.transaction = .transaction
        await model.inspect(schema: "public", table: "items")
        #expect(fixture.sent.isEmpty && model.inspectReason != nil)
        await model.observeSetting()
        #expect(model.settingObservation?.workMemKiB == 4_096)
        await model.setWorkMem(8_192)
        #expect(fixture.reviewed.count == 1 && model.settingResult?.restore.valueKiB == 4_096)
        #expect(model.settingObservation == nil)
        await model.setWorkMem(0, restoring: true)
        #expect(fixture.reviewed.count == 1)
        await model.observeSetting()
        await model.setWorkMem(0, restoring: true)
        #expect(fixture.reviewed.count == 2 && fixture.reviewed.last?.tuningSetting?.valueKiB == 4_096)
        // COMMIT and a later BEGIN can have identical status but must not reuse a restore.
        fixture.epoch = UUID()
        await model.observeSetting()
        await model.setWorkMem(0, restoring: true)
        #expect(fixture.reviewed.count == 2)
    }
    @Test @MainActor func independentOwnerOperationPreservesCapturedOwnersSettingRestore() async throws {
        let captured = try TuningControllerFixture(); let model = captured.model()
        let independent = try TuningControllerFixture()
        captured.transaction = .transaction
        await model.observeSetting(); await model.setWorkMem(8_192)
        independent.epoch = UUID(); independent.transaction = .transaction
        await model.observeSetting(); await model.setWorkMem(0, restoring: true)
        #expect(captured.reviewed.count == 2 && captured.currentKiB == 4_096)
        #expect(independent.reviewed.isEmpty && independent.sent.isEmpty)
    }

    @Test @MainActor func unknownSettingAcknowledgementNeverCreatesRestoreOrRetries() async throws {
        let fixture = try TuningControllerFixture(); let model = fixture.model(); fixture.transaction = .transaction
        await model.observeSetting(); fixture.failSetting = true
        await model.setWorkMem(8_192)
        #expect(model.settingResult == nil && model.settingObservation == nil)
        #expect(model.status.contains("unknown") && fixture.sent.filter { $0.type == "tuning.setting" }.count == 1)
        await model.setWorkMem(0, restoring: true)
        #expect(fixture.sent.filter { $0.type == "tuning.setting" }.count == 1)
    }
    @Test @MainActor func collectionConfigurationIsSavedOnlyOnExplicitEligibleStart() throws {
        let fixture = try TuningControllerFixture(); let model = fixture.model()
        #expect(fixture.persisted == nil && fixture.starts == 0 && !model.collector.running)
        fixture.transaction = .transaction; model.startCollection()
        #expect(fixture.starts == 0)
        fixture.transaction = .idle; model.startCollection()
        #expect(fixture.starts == 1 && fixture.persisted?.valid == true)
    }
}
