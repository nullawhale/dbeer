import Foundation

@MainActor
private final class TableStructureSessionLease {
    var client: BackendClient?
}

extension ApplicationWorkspace {
    func canEditTableStructure(_ node: CatalogNode) -> Bool {
        guard tableImporter == nil, migrationComposer == nil, physicalStructure == nil, canStartTableStructure(node.profileID), let service = services[node.profileID], service.connectionState == .connected,
              [.postgresql, .mysql, .sqlite].contains(service.engine),
              service.permitsOperation("structure.preview", legacyAllowed: service.capabilities.contains("tableStructureEditorV1")) else { return false }
        return node.kind == .schema || node.kind == .group && node.objectKind == "table" || node.kind == .object && node.objectKind == "table"
    }
    func openTableStructure(_ node: CatalogNode, create: Bool, bindingIsCurrent: @escaping () -> Bool = { true },
                            initialDraft: StructureDraft? = nil, changed: @escaping (TableStructureExecutionReview) -> Void = { _ in }) async {
        guard structureEditor == nil, canEditTableStructure(node),
              let profile = library.savedConnections.first(where: { $0.id == node.profileID }),
              let service = services[profile.id], let originSession = service.sessionId else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var profileIdentity = profile; profileIdentity.name = ""
        let profileBytes = try? encoder.encode(profileIdentity)
        let sshSnapshot = service.ssh
        let current: @MainActor () -> Bool = { [weak self, weak service] in
            guard bindingIsCurrent(), let self, let service, self.services[profile.id] === service, service.connectionState == .connected,
                  service.sessionId == originSession,
                  let saved = self.library.savedConnections.first(where: { $0.id == profile.id }) else { return false }
            var savedIdentity = saved; savedIdentity.name = ""
            guard (try? encoder.encode(savedIdentity)) == profileBytes else { return false }
            let live = ConnectionSettings(host: service.host, port: Int(service.port) ?? -1,
                database: service.database, user: service.user, password: "", sslMode: service.sslMode,
                sslRootCert: service.sslRootCert.isEmpty ? nil : service.sslRootCert,
                engine: service.engine, policy: service.policy, contactPoints: service.contactPoints,
                localDatacenter: service.localDatacenter, consistency: service.consistency,
                ssh: service.ssh, passwordCommand: service.passwordCommand, mongodb: service.mongodb, sqlite: service.sqlite)
            return (try? encoder.encode(SavedConnection(id: profile.id, name: "", settings: live))) == profileBytes
        }
        guard current() else { return }
        let lease = TableStructureSessionLease()
        let targetName = create ? "" : node.name
        let model = TableStructureEditorModel(profile: profile, schema: node.schema, table: targetName, create: create,
            historyReviews: structureOutcomeReports.filter { $0.profileID == profile.id && $0.matchesTable(schema: node.schema, table: targetName) }.map(\.review),
            connect: { [weak self] in
                guard let self, current(), let password = await self.library.passwordForConnection(profile.id), current() else {
                    throw ExecutionPolicyError(message: "The profile changed or its credentials are unavailable.")
                }
                let client = try await self.ensureHelper()
                guard current() else { throw ExecutionPolicyError(message: "The profile changed.") }
                var settings = profile.settings(password: password)
                guard sshSnapshot?.configuration == profile.ssh else { throw ExecutionPolicyError(message: "The SSH configuration changed. Reconnect the profile.") }
                settings.ssh = sshSnapshot
                settings.sessionPurpose = "structure"
                try await SSHConnectionReview.prepare(settings, client: client)
                guard current() else { throw ExecutionPolicyError(message: "The connection changed during SSH preparation.") }
                let response = try await client.request(.connect(settings))
                guard let session = response.sessionId else { throw BackendTransportError(.invalidMessage) }
                guard current(), response.operationSupport?.permits("structure.preview", legacyAllowed: response.capabilities?.contains("tableStructureEditorV1") == true) ?? (response.capabilities?.contains("tableStructureEditorV1") == true) else {
                    _ = try? await client.request(.disconnect(sessionId: session))
                    throw ExecutionPolicyError(message: "The connection changed or the helper does not support structure editing.")
                }
                lease.client = client
                return session
            }, send: { [weak self] command in
                guard self != nil, let client = lease.client else { throw BackendTransportError(.notReady) }
                return try await client.request(command)
            }, authorize: { [weak self] apply, plan, session in
                guard let self, current() else { throw ExecutionPolicyError(message: "The connection changed.") }
                guard let client = lease.client else { throw BackendTransportError(.notReady) }
                guard current() else { throw ExecutionPolicyError(message: "The connection changed.") }
                return try await self.authorizeOperations([.init(type: "structure.apply", structure: apply)],
                    sessionID: session, profile: profile, client: client,
                    generatedPreview: plan.sql.joined(separator: "\n") + "\n\n" + plan.risks.joined(separator: "\n"))
            }, bindingIsCurrent: current, authoringSupported: { [weak service] in service?.capabilities.contains("tableStructureAuthoringV2") == true }, indexAuthoringSupported: { [weak service] in service?.capabilities.contains("tableStructureIndexAuthoringV1") == true }, destructiveSupported: { [weak service] in service?.capabilities.contains("tableStructureDestructiveV1") == true }, reconstructionSupported: { [weak service] in service?.capabilities.contains("tableStructureReconstructionV1") == true }, confirmPlan: { [weak self] plan, _ in
                guard let self, current() else { return false }
                let consequences = plan.consequences.map { $0.object + ": " + $0.message }
                let review = ["Apply this exact reviewed structure plan?", "Plan: " + plan.id, "Digest: " + plan.digest,
                    "Target: " + plan.target.schema + "." + plan.target.table,
                    plan.sql.joined(separator: "\n\n"), (plan.risks + consequences).joined(separator: "\n"),
                    "Data validation is a separate observation and cannot guarantee later writes or conversions will succeed."].joined(separator: "\n\n")
                return await self.executionDecision(.standalone(profile: profile, preview: review))
            }, authorizeValidation: { [weak self] validation, plan, session in
                guard let self, current(), let client = lease.client else { throw ExecutionPolicyError(message: "The connection changed.") }
                let checks = plan.validationChecks.map { check in
                    check.summary + "\n" + (check.sql ?? check.unavailableReason ?? "No executable validation check") + "\n" + check.risks.joined(separator: "\n")
                }.joined(separator: "\n\n")
                return try await self.authorizeOperations([.init(type: "structure.validate", structure: validation)],
                    sessionID: session, profile: profile, client: client,
                    generatedPreview: "Validate data for plan " + plan.id + "\nDigest: " + plan.digest + "\n\n" + checks +
                        "\n\nThese reads can scan the table and evaluate the disclosed builtin conversion expressions. They do not execute DDL or authorize Apply; unavailable checks are not evaluated.", forceConfirmation: true)
            }, operationsAllowed: { [weak self] in self?.canStartTableStructure(profile.id) == true }, sessionIsKnownClosed: {
                guard let client = lease.client else { return false }
                return await client.hasExited()
            }, changed: { [weak self] review in
                guard let self else { return }
                // Retain staged data changes; require an explicit reload before further edits.
                for document in self.documents where document.profileID == profile.id { document.markQueryResultStale() }
                self.recordStructureOutcome(profile.id, schema: review.plan.target.schema, table: review.plan.target.table, review: review)
                changed(review)
            })
        structureEditor = model
        if !create {
            await model.load()
            if current(), structureEditor === model, model.baseline != nil, !model.invalidated, let initialDraft {
                model.draft = initialDraft
            }
        }
    }
    func closeTableStructure() async {
        guard let model = structureEditor, !model.isBusy, model.beginClosing() else { return }
        guard await model.close() else { model.cancelClosing(); return }
        if structureEditor === model { structureEditor = nil }
    }
}
