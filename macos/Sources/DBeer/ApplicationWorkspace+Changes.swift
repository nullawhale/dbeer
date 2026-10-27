import Foundation

extension ApplicationWorkspace {
    func previewGrid(_ document: SQLDocument) async {
        document.grid?.commitEditing?()
        guard canStartOperation(document), !document.isRunning,
              let grid = document.grid, grid.pendingCount > 0, !grid.isApplying, !grid.isPreviewing else { return }
        let request = grid.request()
        grid.isPreviewing = true
        grid.error = nil
        defer { grid.isPreviewing = false }
        do {
            let reply = try await performChanges(document, grid: grid, request: request, apply: false)
            if grid.request() == request { grid.preview = reply }
        } catch { grid.error = error.localizedDescription }
    }

    @discardableResult func applyGrid(_ document: SQLDocument, forClosing: Bool = false) async -> Bool {
        document.grid?.commitEditing?()
        guard canStartOperation(document, forClosing: forClosing), !document.isRunning,
              let grid = document.grid, grid.pendingCount > 0, !grid.isApplying,
              !grid.outcomeUnknown, !grid.policyReadOnly, grid.readOnlyReason == nil else { return false }
        if let status = grid.partitionStatus, !status.allowsApply {
            grid.error = status.help
            return false
        }
        grid.isApplying = true
        grid.cancelRequested = false
        grid.error = nil
        grid.notice = nil
        let request = grid.request()
        defer {
            grid.isApplying = false
            grid.applySessionID = nil
            grid.applyQueryID = nil
        }
        do {
            let reply = try await performChanges(document, grid: grid, request: request, apply: true, forClosing: forClosing)
            if grid.isCassandra, reply.appliedChangeCount != request.changes.count {
                throw BackendTransportError(.invalidMessage, outcomeUnknown: true)
            }
            if grid.querySource != nil {
                // The captured SELECT is never replayed by Apply, including while closing.
                grid.discardAfterSuccessfulApply()
                document.markQueryResultStale()
                grid.notice = "Changes applied. This result is stale; run the query explicitly to refresh it."
                return true
            }
            document.attachGrid(nil)
            grid.isApplying = false
            if grid.isCassandra { document.resetTablePaging() }
            if !forClosing { await run(document) }
            document.grid?.notice = reply.commandTag ?? "Changes applied."
            return true
        } catch {
            if let remote = error as? BackendRemoteError {
                grid.outcomeUnknown = remote.reply.outcomeUnknown == true
                if grid.querySource != nil, remote.reply.category == "conflict" {
                    document.markQueryResultStale()
                }
                if grid.isCassandra {
                    grid.preview = nil
                    if let count = remote.reply.appliedChangeCount, count != 0 { grid.outcomeUnknown = true }
                }
            }
            if let transport = error as? BackendTransportError { grid.outcomeUnknown = transport.outcomeUnknown }
            grid.error = error.localizedDescription
            if grid.outcomeUnknown {
                grid.error = grid.isCassandra
                    ? "The atomic write outcome is unknown. The whole batch may have been applied. Review the data in a new tab, then discard local changes and reload before applying further changes."
                    : "The write outcome is unknown. Review the data in a new tab, then discard local changes and reload before applying further changes."
            }
            if grid.isCassandra { document.resetTablePaging() }
            return false
        }
    }

    func stopGridApply(_ document: SQLDocument) async {
        guard ownedSQLContext(for: document) != nil, let grid = document.grid, grid.isApplying else { return }
        grid.cancelRequested = true
        guard let sessionID = grid.applySessionID, let queryID = grid.applyQueryID,
              let client = try? await ensureHelper(), ownedSQLContext(for: document) != nil else { return }
        _ = try? await client.request(.cancel(sessionId: sessionID, queryId: queryID))
    }

    func discardGrid(_ document: SQLDocument) async {
        document.grid?.commitEditing?()
        guard canStartOperation(document), !document.isRunning,
              let grid = document.grid, !grid.isApplying else { return }
        let unknown = grid.outcomeUnknown
        grid.discard()
        grid.outcomeUnknown = unknown
        if grid.querySource != nil {
            if unknown { document.markQueryResultStale() }
        } else { await reloadTableAfterDiscard(document) }
    }

    func reviewGridData(_ document: SQLDocument) async {
        guard let table = document.table ?? document.grid?.querySource.map({ TableReference(schema: $0.schema, name: $0.table, kind: "table") }),
              let profileID = document.profileID else { return }
        let node = CatalogNode(profileID: profileID, name: table.name, kind: .object,
            schema: table.schema, object: table.name, objectKind: table.kind)
        await openData(node, inNewTab: true)
    }

    private func performChanges(_ document: SQLDocument, grid: GridDraft, request: ChangesRequest,
                                apply: Bool, forClosing: Bool = false) async throws -> BackendMessage {
        guard let profileID = document.profileID,
              let profile = library.savedConnections.first(where: { $0.id == profileID }),
              let runtime = document.runtime, let boundSessionID = runtime.sessionId,
              let boundPort = Int(runtime.port) else {
            throw ChangesClientError(message: "Reconnect the profile and reload the table before previewing or applying changes.")
        }
        guard grid.querySource == nil || (grid.querySessionID == boundSessionID && runtime.transactionStatus == .idle) else {
            throw ChangesClientError(message: "The source session changed or has an active transaction. Discard local changes and run the query again before editing.")
        }
        let boundSettings = ConnectionSettings(host: runtime.host, port: boundPort, database: runtime.database,
            user: runtime.user, password: "", sslMode: runtime.sslMode,
            sslRootCert: runtime.sslRootCert.isEmpty ? nil : runtime.sslRootCert, engine: runtime.engine, policy: runtime.policy,
            contactPoints: runtime.contactPoints, localDatacenter: runtime.localDatacenter, consistency: runtime.consistency,
            ssh: runtime.ssh, passwordCommand: runtime.passwordCommand)
        func validateConnectionBinding() throws {
            guard ownedSQLContext(for: document) != nil,
                  document.profileID == profileID, document.runtime === runtime, document.grid === grid,
                  runtime.connectionState == .connected, runtime.sessionId == boundSessionID,
                  grid.querySource == nil || runtime.transactionStatus == .idle,
                  runtime.activeConnectionId == profileID,
                  profile.matches(boundSettings),
                  library.savedConnections.first(where: { $0.id == profileID })?.matches(boundSettings) == true,
                  runtime.engine == boundSettings.engine, runtime.host == boundSettings.host,
                  Int(runtime.port) == boundSettings.port, runtime.database == boundSettings.database,
                  runtime.user == boundSettings.user, runtime.sslMode == boundSettings.sslMode,
                  runtime.contactPoints == boundSettings.contactPoints, runtime.localDatacenter == boundSettings.localDatacenter,
                  runtime.consistency == boundSettings.consistency, runtime.policy == boundSettings.policy,
                  runtime.ssh == boundSettings.ssh,
                  runtime.passwordCommand == boundSettings.passwordCommand,
                  (runtime.sslRootCert.isEmpty ? nil : runtime.sslRootCert) == boundSettings.sslRootCert else {
                throw ChangesClientError(message: "The profile changed after this table was loaded. Reconnect the profile and reload the table before previewing or applying changes.")
            }
        }
        try validateConnectionBinding()
        guard let password = await library.passwordForConnection(profileID) else {
            throw ChangesClientError(message: library.connectionsError ?? "This profile is unavailable.")
        }
        try validateConnectionBinding()
        guard canStartOperation(document, forClosing: forClosing), !grid.cancelRequested || !apply else {
            throw ChangesClientError(message: "The changes operation was cancelled before execution.")
        }
        let client = try await ensureHelper()
        try validateConnectionBinding()
        guard canStartOperation(document, forClosing: forClosing), !grid.cancelRequested || !apply else {
            throw ChangesClientError(message: "The changes operation was cancelled before execution.")
        }
        var temporarySettings = profile.settings(password: password)
        temporarySettings.ssh = boundSettings.ssh
        let connected = try await client.request(.connect(temporarySettings))
        guard let sessionID = connected.sessionId else { throw ChangesClientError(message: "The changes session could not be opened.") }
        let queryID = UUID().uuidString
        if apply {
            grid.applySessionID = sessionID
            grid.applyQueryID = queryID
        }
        do {
            try validateConnectionBinding()
            guard canStartOperation(document, forClosing: forClosing), !grid.cancelRequested || !apply else {
                throw ChangesClientError(message: "The changes operation was cancelled before execution.")
            }
            var command: BackendCommand = apply
                ? .applyChanges(sessionId: sessionID, queryId: queryID, request: request)
                : .previewChanges(sessionId: sessionID, queryId: queryID, request: request)
            if apply {
                let previewQueryID = UUID().uuidString
                grid.applyQueryID = previewQueryID
                let preview = try await client.request(.previewChanges(sessionId: sessionID, queryId: previewQueryID, request: request))
                grid.applyQueryID = queryID
                try validateConnectionBinding()
                guard grid.request() == request, !grid.cancelRequested,
                      canStartOperation(document, forClosing: forClosing) else {
                    throw ChangesClientError(message: "The changes operation was cancelled or changed before confirmation.")
                }
                let generatedSQL = preview.catalogRecords.map { record in
                    (record["sql"] ?? "") + "\nParameters: " + (record["parameters"] ?? "")
                }.joined(separator: "\n\n")
                let generatedPreview = [grid.editingNotice, generatedSQL].compactMap { $0 }.joined(separator: "\n\n")
                guard let authorization = try await authorizeOperations([OperationRequest(type: "changes.apply", changes: request)],
                    sessionID: sessionID, profile: profile, client: client, generatedPreview: generatedPreview) else {
                    throw ChangesClientError(message: "Apply was cancelled before execution.")
                }
                try validateConnectionBinding()
                guard grid.request() == request, !grid.cancelRequested,
                      canStartOperation(document, forClosing: forClosing) else {
                    throw ChangesClientError(message: "The changes or execution context changed after confirmation.")
                }
                command.authorization = authorization
            }
            let reply = try await client.request(command)
            _ = try? await client.request(.disconnect(sessionId: sessionID))
            return reply
        } catch {
            _ = try? await client.request(.disconnect(sessionId: sessionID))
            throw error
        }
    }
}

private struct ChangesClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
