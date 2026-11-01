import Foundation

@MainActor
private final class TableStructureSessionLease {
    var client: BackendClient?
}

extension ApplicationWorkspace {
    func canEditTableStructure(_ node: CatalogNode) -> Bool {
        guard tableImporter == nil, canStartTableStructure(node.profileID), let service = services[node.profileID], service.connectionState == .connected,
              [.postgresql, .mysql].contains(service.engine), service.capabilities.contains("tableStructureEditorV1") else { return false }
        return node.kind == .schema || node.kind == .group && node.objectKind == "table" || node.kind == .object && node.objectKind == "table"
    }
    func openTableStructure(_ node: CatalogNode, create: Bool) async {
        guard structureEditor == nil, canEditTableStructure(node),
              let profile = library.savedConnections.first(where: { $0.id == node.profileID }),
              let service = services[profile.id], let originSession = service.sessionId else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let profileBytes = try? encoder.encode(profile)
        let sshSnapshot = service.ssh
        let current: @MainActor () -> Bool = { [weak self, weak service] in
            guard let self, let service, self.services[profile.id] === service, service.connectionState == .connected,
                  service.sessionId == originSession,
                  let saved = self.library.savedConnections.first(where: { $0.id == profile.id }),
                  (try? encoder.encode(saved)) == profileBytes else { return false }
            let live = ConnectionSettings(host: service.host, port: Int(service.port) ?? -1,
                database: service.database, user: service.user, password: "", sslMode: service.sslMode,
                sslRootCert: service.sslRootCert.isEmpty ? nil : service.sslRootCert,
                engine: service.engine, policy: service.policy, contactPoints: service.contactPoints,
                localDatacenter: service.localDatacenter, consistency: service.consistency,
                ssh: service.ssh, passwordCommand: service.passwordCommand)
            return (try? encoder.encode(SavedConnection(id: profile.id, name: profile.name, settings: live))) == profileBytes
        }
        guard current() else { return }
        let lease = TableStructureSessionLease()
        let targetName = create ? "" : node.name
        let model = TableStructureEditorModel(profile: profile, schema: node.schema, table: targetName, create: create,
            historyReviews: structureOutcomeReports.filter { $0.profileID == profile.id && StructureTarget.sameIdentifier($0.schema, node.schema) && StructureTarget.sameIdentifier($0.table, targetName) }.map(\.review),
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
                guard current(), response.capabilities?.contains("tableStructureEditorV1") == true else {
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
            }, bindingIsCurrent: current, operationsAllowed: { [weak self] in self?.canStartTableStructure(profile.id) == true }, sessionIsKnownClosed: {
                guard let client = lease.client else { return false }
                return await client.hasExited()
            }, changed: { [weak self] review in
                guard let self else { return }
                // Retain staged data changes; require an explicit reload before further edits.
                for document in self.documents where document.profileID == profile.id { document.markQueryResultStale() }
                self.recordStructureOutcome(profile.id, schema: review.plan.target.schema, table: review.plan.target.table, review: review)
            })
        structureEditor = model
        if !create { await model.load() }
    }
    func closeTableStructure() async {
        guard let model = structureEditor, !model.isBusy, model.beginClosing() else { return }
        guard await model.close() else { model.cancelClosing(); return }
        if structureEditor === model { structureEditor = nil }
    }
}
