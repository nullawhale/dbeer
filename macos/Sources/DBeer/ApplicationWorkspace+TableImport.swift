import Foundation

@MainActor
private final class TableImportSessionLease {
    var client: BackendClient?
}

extension ApplicationWorkspace {
    func canImportTableData(_ node: CatalogNode) -> Bool {
        guard canManageWorkspace, canStartTableStructure(node.profileID), tableImporter == nil, structureEditor == nil, migrationComposer == nil, queryParameterPrompt == nil,
              node.kind == .object, node.objectKind == "table",
              let service = services[node.profileID], service.connectionState == .connected,
              [.postgresql, .mysql, .sqlite].contains(service.engine), service.capabilities.contains("tableImportV1") else { return false }
        return true
    }

    func importNode(for document: SQLDocument) -> CatalogNode? {
        guard let table = document.table, table.kind == "table", let profileID = document.profileID,
              !document.isRunning, !document.isNavigatingTable else { return nil }
        return CatalogNode(profileID: profileID, name: table.name, kind: .object,
            schema: table.schema, object: table.name, objectKind: "table")
    }

    func openTableImport(_ node: CatalogNode) async {
        guard canImportTableData(node), let profile = library.savedConnections.first(where: { $0.id == node.profileID }),
              let service = services[profile.id], let originSession = service.sessionId else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let profileBytes = try? encoder.encode(profile) else { return }
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
                ssh: service.ssh, passwordCommand: service.passwordCommand, mongodb: service.mongodb, sqlite: service.sqlite)
            return (try? encoder.encode(SavedConnection(id: profile.id, name: profile.name, settings: live))) == profileBytes
        }
        guard current() else { return }
        let lease = TableImportSessionLease()
        let model = TableImportModel(profile: profile, schema: node.schema, table: node.name,
            connect: { [weak self] in
                guard let self, current(), let password = await self.library.passwordForConnection(profile.id), current() else {
                    throw ExecutionPolicyError(message: "The profile changed or its credentials are unavailable.")
                }
                let client = try await self.ensureHelper()
                guard current(), await client.supportsTableImport() else { throw BackendRequestError.unsupportedTableImport }
                var settings = profile.settings(password: password)
                guard sshSnapshot?.configuration == profile.ssh else { throw ExecutionPolicyError(message: "The SSH configuration changed. Reconnect the profile.") }
                settings.ssh = sshSnapshot
                settings.sessionPurpose = "import"
                try await SSHConnectionReview.prepare(settings, client: client)
                guard current() else { throw ExecutionPolicyError(message: "The connection changed during import preparation.") }
                let response = try await client.request(.connect(settings))
                guard let session = response.sessionId else { throw BackendTransportError(.invalidMessage) }
                guard current(), response.capabilities?.contains("tableImportV1") == true else {
                    _ = try? await client.request(.disconnect(sessionId: session))
                    throw ExecutionPolicyError(message: "The connection changed or table import is unavailable.")
                }
                lease.client = client
                return session
            }, send: { [weak self] command in
                guard self != nil, let client = lease.client else { throw BackendTransportError(.notReady) }
                return try await client.request(command)
            }, authorize: { [weak self] request, preview, session in
                guard let self, current(), let client = lease.client else { throw ExecutionPolicyError(message: "The import connection changed.") }
                return try await self.authorizeOperations([OperationRequest(type: "import.apply", tableImport: request)],
                    sessionID: session, profile: profile, client: client,
                    generatedPreview: "Append \(request.rows?.count ?? 0) rows to \(request.schema).\(request.table).\n" + (preview.sql ?? ""))
            }, bindingIsCurrent: current, operationsAllowed: { [weak self] in self?.canStartTableStructure(profile.id) == true },
            sessionIsKnownClosed: {
                guard let client = lease.client else { return false }
                return await client.hasExited()
            },
            changed: { [weak self] in
                guard let self else { return }
                // Keep all tab sessions and pending grid edits; the user reloads explicitly.
                for document in self.documents where document.profileID == profile.id {
                    if document.table == nil { document.markQueryResultStale() }
                    if document.table?.schema == node.schema, document.table?.name == node.name {
                        document.grid?.notice = "Data was imported. Reload this table explicitly to see the inserted rows."
                    }
                }
                self.dataComparison?.dismissPlan()
            })
        tableImporter = model
        await model.load()
    }
}
