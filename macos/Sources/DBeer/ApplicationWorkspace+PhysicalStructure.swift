import Foundation

struct PhysicalStructureOutcomeRecord {
    let profileID: UUID
    var report: PhysicalStructureReport
}

@MainActor
private final class PhysicalStructureSessionLease { var client: BackendClient? }

extension ApplicationWorkspace {
    func canManagePhysicalStructure(_ node: CatalogNode) -> Bool {
        guard canManageWorkspace, canStartTableStructure(node.profileID), physicalStructure == nil,
              structureEditor == nil, migrationComposer == nil, tableImporter == nil, queryParameterPrompt == nil,
              node.kind == .object, node.objectKind == "table", let service = services[node.profileID],
              service.connectionState == .connected, [.postgresql, .mysql, .mariadb].contains(service.engine),
              service.capabilities.contains(structurePhysicalCapability) else { return false }
        return service.permitsOperation("structure.physical.preview", legacyAllowed: true)
    }
    func openPhysicalStructure(_ node: CatalogNode) {
        guard canManagePhysicalStructure(node), structureEditor == nil, tableImporter == nil,
              let profile = library.savedConnections.first(where: { $0.id == node.profileID }),
              let service = services[profile.id], let originSession = service.sessionId else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var identity = profile; identity.name = ""
        let bytes = try? encoder.encode(identity)
        let sshSnapshot = service.ssh
        let current: @MainActor () -> Bool = { [weak self, weak service] in
            guard let self, let service, self.services[profile.id] === service, service.connectionState == .connected,
                  service.sessionId == originSession, let saved = self.library.savedConnections.first(where: { $0.id == profile.id }) else { return false }
            var savedIdentity = saved; savedIdentity.name = ""
            guard (try? encoder.encode(savedIdentity)) == bytes else { return false }
            let live = ConnectionSettings(host: service.host, port: Int(service.port) ?? -1, database: service.database, user: service.user,
                password: "", sslMode: service.sslMode, sslRootCert: service.sslRootCert.isEmpty ? nil : service.sslRootCert,
                engine: service.engine, policy: service.policy, contactPoints: service.contactPoints, localDatacenter: service.localDatacenter,
                consistency: service.consistency, ssh: service.ssh, passwordCommand: service.passwordCommand, mongodb: service.mongodb, sqlite: service.sqlite)
            return (try? encoder.encode(SavedConnection(id: profile.id, name: "", settings: live))) == bytes
        }
        guard current() else { return }
        let lease = PhysicalStructureSessionLease()
        let initial = StructureTarget(schema: node.schema, table: node.kind == .object ? node.name : "", create: false)
        physicalStructure = PhysicalStructureModel(profile: profile, target: initial,
            history: physicalStructureReports.filter { $0.profileID == profile.id }.map(\.report), connect: { [weak self] in
                guard let self, current(), let password = await self.library.passwordForConnection(profile.id), current() else {
                    throw ExecutionPolicyError(message: "The profile changed or its credentials are unavailable.")
                }
                let client = try await self.ensureHelper()
                guard current() else { throw ExecutionPolicyError(message: "The profile changed.") }
                var settings = profile.settings(password: password)
                guard sshSnapshot?.configuration == profile.ssh else { throw ExecutionPolicyError(message: "The SSH configuration changed. Reconnect the profile.") }
                settings.ssh = sshSnapshot; settings.sessionPurpose = "structure"
                try await SSHConnectionReview.prepare(settings, client: client)
                guard current() else { throw ExecutionPolicyError(message: "The connection changed during SSH preparation.") }
                let response = try await client.request(.connect(settings))
                guard let session = response.sessionId else { throw BackendTransportError(.invalidMessage) }
                guard current(), response.capabilities?.contains(structurePhysicalCapability) == true else {
                    _ = try? await client.request(.disconnect(sessionId: session))
                    throw ExecutionPolicyError(message: "The connection changed or the helper does not support physical operations.")
                }
                lease.client = client
                return session
            }, send: { command in
                guard let client = lease.client else { throw BackendTransportError(.notReady) }
                return try await client.request(command)
            }, authorize: { [weak self] apply, plan, session in
                guard let self, current(), let client = lease.client else { throw ExecutionPolicyError(message: "The connection changed.") }
                return try await self.authorizeOperations([.init(type: "structure.physical.apply", structure: apply)],
                    sessionID: session, profile: profile, client: client, generatedPreview: PhysicalReviewText.confirmation(plan), forceConfirmation: true)
            }, bindingIsCurrent: current, operationsAllowed: { [weak self] in self?.canStartTableStructure(profile.id) == true },
            helperIsClosed: { guard let client = lease.client else { return false }; return await client.hasExited() },
            changed: { [weak self] report in self?.recordPhysicalStructureOutcome(profile.id, report: report) })
    }
    func closePhysicalStructure() async {
        guard let model = physicalStructure, !model.isBusy, !model.checkingStatus, model.beginClosing() else { return }
        guard await model.close() else { model.cancelClosing(); return }
        if physicalStructure === model { physicalStructure = nil }
    }
}
