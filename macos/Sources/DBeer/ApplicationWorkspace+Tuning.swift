import Combine
import Foundation

extension ApplicationWorkspace {
    func tuningUnavailableReason(_ document: SQLDocument, plan: ExplainPlanModel) -> String? {
        guard let result = plan.result else { return "Collect plan evidence explicitly before opening tuning." }
        guard [.postgresql, .mysql, .mariadb].contains(result.support.engine) else { return "Tuning is available only for supported PostgreSQL, Oracle MySQL and MariaDB SQL owners." }
        guard let context = plan.request.context,
              let target = allOwnedSQLDocuments.first(where: { $0.id.uuidString == context.targetDocumentId }),
              target.runtime?.connectionState == .connected, target.runtime?.sessionId == context.sessionId else { return "The original physical SQL owner is disconnected or has changed. Collect a new plan explicitly." }
        guard target.runtime?.capabilities.contains(TuningInspectRequest.capability) == true else { return "This helper or SQL owner does not advertise tuning support. PostgreSQL 14+, recognized Oracle MySQL 8.0.30+, or a supported MariaDB session and paired helper support are required." }
        guard plan.request.writeIntent == nil else { return "DML Analyze evidence cannot authorize tuning or background collection." }
        if document.isRunning || target.isRunning { return "Wait for the active SQL operation to finish." }
        return nil
    }

    func makeTuningPanel(_ document: SQLDocument, plan: ExplainPlanModel) -> TuningPanelModel? {
        guard canStartOperation(document), !document.isRunning, !document.queryResultSelectionLocked,
              let sourceContext = plan.request.context, let result = plan.result,
              sourceContext.documentId == document.id.uuidString,
              let target = allOwnedSQLDocuments.first(where: { $0.id.uuidString == sourceContext.targetDocumentId }),
              let runtime = target.runtime, runtime.connectionState == .connected, !target.isRunning,
              let session = runtime.sessionId, session == sourceContext.sessionId,
              let profile = library.savedConnections.first(where: { $0.id == plan.profileID }),
              let binding = plan.profileBinding ?? ExplainProfileBinding(profile), binding.matches(profile),
              plan.request.writeIntent == nil else { return nil }
        let definitions = selectedSQLLibraryEntry(for: document)?.parameters ?? document.queryParameters
        guard definitions == (plan.request.parameters ?? []).map({ SQLParameterDefinition(name: $0.name, type: $0.type) }) else { return nil }
        let sourceFence = tuningSourceFence(document)
        let librarySnapshotFence = tuningLibrarySnapshotFence(document)
        let current: @MainActor () -> Bool = { [weak self, weak document, weak target, weak runtime] in
            guard let self, let document, let target, let runtime,
                  self.canStartOperation(document), self.canStartOperation(target), sourceFence(),
                  self.allOwnedSQLDocuments.contains(where: { $0 === document }), self.allOwnedSQLDocuments.contains(where: { $0 === target }),
                  !document.stopRequested, !target.stopRequested,
                  !document.queryResultSelectionLocked, !target.queryResultSelectionLocked,
                  target.runtime === runtime, runtime.connectionState == .connected, runtime.sessionId == session,
                  target.profileID == profile.id, runtime.activeConnectionId == profile.id,
                  binding.matches(self.library.savedConnections.first { $0.id == profile.id }), binding.matchesRuntime(runtime),
                  runtime.explainSupport == result.support,
                  runtime.capabilities.contains(TuningInspectRequest.capability),
                  !plan.isStaleSource(text: document.text, profileID: document.profileID,
                      profile: self.library.savedConnections.first { $0.id == document.profileID }) else { return false }
            return TuningTransportAdmission.validOwner(support: runtime.explainSupport, engine: runtime.engine,
                capabilities: Set(runtime.capabilities), helperSupports: true)
        }
        guard current() else { return nil }
        let collector: ExplainCollector
        if let existing = document.explainCollector { collector = existing }
        else {
            collector = explainCollectorFactory(document.id)
            document.explainCollector = collector
        }
        let send: @MainActor (BackendCommand) async throws -> BackendMessage = { [weak self, weak document, weak target, weak runtime] command in
            guard let self, let document, let target, let runtime, current(), !document.isRunning, !target.isRunning else { throw ExecutionPolicyError(message: "Tuning is unavailable for this helper or current SQL owner.") }
            let client = try await self.ensureHelper()
            guard current(), await client.supportsTuning() else { throw ExecutionPolicyError(message: "Tuning requires both the current helper and SQL-owner capabilities.") }
            document.isRunning = true; target.isRunning = true
            defer { document.isRunning = false; target.isRunning = false }
            guard current(), let completion = await runtime.run(authorization: command.authorization, tuning: command) else { throw CancellationError() }
            if let failure = completion.failure { throw TuningExecutionError(message: failure.message, outcomeUnknown: failure.outcomeUnknown) }
            guard current(), let reply = completion.reply else { throw CancellationError() }
            return reply
        }
        let cancel: @MainActor () async -> Void = { [weak runtime] in
            guard let runtime, runtime.sessionId == session else { return }
            await runtime.stop()
        }
        return TuningPanelModel(plan: plan, collector: collector,
            configuration: document.explainCollectorConfiguration ?? .init(), current: current, readOnly: { [weak runtime] in runtime?.policy.readOnly ?? true },
            operationEpoch: { [weak runtime] in runtime?.tuningOperationEpoch ?? UUID() },
            transaction: { [weak runtime] in runtime?.transactionStatus }, send: send,
            authorize: { [weak self] operation, preview in
                guard let self, current() else { throw CancellationError() }
                let client = try await self.ensureHelper()
                guard current(), await client.supportsTuning() else { throw CancellationError() }
                let grant = try await self.authorizeOperations([operation], sessionID: session, profile: profile,
                    client: client, generatedPreview: preview, forceConfirmation: true)
                guard current() else { _ = try? await client.request(.cancel(sessionId: session, queryId: UUID().uuidString)); throw CancellationError() }
                return grant
            }, adopt: { [weak self] request in
                guard let self, current() else { return }
                let candidate = self.newDocument(profileID: profile.id, text: request.sql)
                candidate.queryParameters = (request.parameters ?? []).map { .init(name: $0.name, type: $0.type) }
            }, editIndex: { [weak self] target, edit in
                guard let self, current(), runtime.transactionStatus == .idle else { return }
                let node = CatalogNode(profileID: profile.id, name: target.table, kind: .object,
                    schema: target.schema, object: target.table, objectKind: "table", engine: profile.engine)
                let draft = StructureDraft(columns: [], indexes: [edit], authoringVersion: 3)
                // This opens a NEW dedicated E2 session/baseline. Advice never supplies a baseline or apply identity.
                await self.openTableStructure(node, create: false, bindingIsCurrent: current, initialDraft: draft)
            }, cancel: cancel, startCollector: { [weak self, weak document, weak target, weak runtime, weak collector] configuration in
                guard let self, let document, let target, let runtime, let collector, current(), runtime.transactionStatus == .idle,
                      plan.request.mode == .plan, plan.request.writeIntent == nil,
                      !ExplainDMLAdmission.possibleDML(plan.request.sql, engine: profile.engine) else { return }
                let epoch = runtime.tuningOperationEpoch
                let collecting: @MainActor () -> Bool = { [weak runtime] in
                    current() && runtime?.tuningOperationEpoch == epoch && runtime?.transactionStatus == .idle
                }
                collector.start(configuration: configuration, current: collecting) { [weak self, weak document, weak target, weak runtime] captureLease in
                    guard let self, let document, let target, let runtime, collecting(), !document.isRunning, !target.isRunning else { throw CancellationError() }
                    let client = try await self.ensureHelper()
                    guard collecting(), await client.supportsTuning() else { throw CancellationError() }
                    var request = plan.request
                    request.context?.transactionStatus = "idle"
                    let assessed = try await client.request(.assess(sessionId: session, operations: [.init(type: "explain.run", explain: request)]))
                    guard captureLease.isActive, collecting(), !Task.isCancelled else {
                        await client.discardAssessmentIfCurrent(assessed)
                        throw CancellationError()
                    }
                    guard let assessment = assessed.assessment, assessment.valid, assessment.policy == profile.policy,
                          assessment.decision == "allow", assessment.operations.count == 1,
                          assessment.operations[0].kind == "read", assessment.operations[0].explain?.support == runtime.explainSupport,
                          assessment.operations[0].explain?.mode == .plan,
                          assessment.operations[0].explain?.options == request.options, let grant = assessment.authorization else {
                        await client.discardAssessmentIfCurrent(assessed)
                        throw ExecutionPolicyError(message: "Current query needs review or is no longer admitted as an estimated read. Start again explicitly after reviewing it.")
                    }
                    guard captureLease.isActive, collecting(), !document.isRunning, !target.isRunning else {
                        await client.discardAssessmentIfCurrent(assessed)
                        throw CancellationError()
                    }
                    let captureQueryID = UUID().uuidString
                    guard captureLease.bind(queryID: captureQueryID, cancel: { queryID in
                        await client.cancelPendingCapture(sessionID: session, queryID: queryID)
                    }) else { await client.discardAssessmentIfCurrent(assessed); throw CancellationError() }
                    document.isRunning = true; target.isRunning = true
                    defer { document.isRunning = false; target.isRunning = false }
                    let completion = await runtime.run(authorization: grant, explain: request, collectedExplain: true, ownedQueryID: captureQueryID, captureAdmission: captureLease.admission)
                    captureLease.finishQuery(captureQueryID)
                    if !captureLease.isActive || completion == nil || completion?.failure != nil {
                        await client.discardAssessmentIfCurrent(assessed)
                    }
                    guard captureLease.isActive, let completion, completion.failure == nil, collecting(), let captured = completion.reply?.explain,
                          captured.support == result.support, captured.options == request.options else {
                        throw ExecutionPolicyError(message: "Capture failed or its context changed. No automatic retry is scheduled.")
                    }
                    var evidence = ExplainPlanModel(request: request, sourceText: plan.sourceText, sourceRange: plan.sourceRange, profileID: profile.id)
                    evidence.profile = profile; evidence.result = captured
                    evidence.sourceEvidence = ExplainSourceEvidence(rangeLocation: plan.sourceRange.location,
                        rangeLength: request.sql.utf16.count, transactionStatus: "idle")
                    return try PlanArtifact.capture(evidence, title: document.title + " · collected estimated plan")
                }
                // Normal execution, transaction changes and owner/policy teardown retire the immutable run.
                collector.observations = [
                    runtime.$tuningOperationEpoch.dropFirst().sink { [weak collector] _ in collector?.stop("Stopped — SQL owner executed another operation") },
                    runtime.$sessionId.dropFirst().sink { [weak collector] _ in collector?.stop("Stopped — SQL owner changed") },
                    runtime.$transactionStatus.dropFirst().removeDuplicates().sink { [weak collector] status in if status != .idle { collector?.stop("Stopped — transaction context changed") } },
                    runtime.$policy.dropFirst().sink { [weak collector] policy in
                        if policy != profile.policy { collector?.stop("Stopped — this SQL owner's policy changed") }
                    },
                    self.library.$savedConnections.dropFirst().sink { [weak collector] profiles in
                        if !binding.matches(profiles.first { $0.id == profile.id }) ||
                            plan.sourceProfileBinding.map({ !$0.matches(profiles.first { $0.id == plan.sourceProfileID }) }) == true {
                            collector?.stop("Stopped — captured profile or policy changed")
                        }
                    },
                    self.sqlLibrary.$snapshot.dropFirst().sink { [weak collector] snapshot in
                        if !librarySnapshotFence(snapshot) { collector?.stop("Stopped — captured SQL library scope or definitions changed") }
                    }
                ]
            }, persistConfiguration: { [weak document] configuration in
                if configuration.valid { document?.explainCollectorConfiguration = configuration }
            })
    }
}
