import Foundation

extension ApplicationWorkspace {
    @discardableResult
    func openERDiagram(_ node: CatalogNode) -> SQLDocument? {
        guard canManageWorkspace, let profile = library.savedConnections.first(where: { $0.id == node.profileID }),
              [.postgresql, .mysql].contains(profile.engine), node.kind == .schema || (node.kind == .object && node.objectKind == "table") else { return nil }
        var stored = StoredERDiagram(profileID: profile.id, engine: profile.engine, database: profile.database)
        if node.kind == .object {
            let table = ERTableID(profileID: profile.id, schema: node.schema, name: node.name)
            guard table.isValid else { return nil }
            stored.tables = [table]; stored.selected = table
        }
        let document = SQLDocument(title: "ER Diagram", text: "", profileID: profile.id)
        let model = ERDiagramModel(stored: stored)
        model.initialSchema = node.schema
        document.attachERDiagram(model)
        return addDocument(document)
    }

    func erDiagramContext(_ model: ERDiagramModel) -> ERDiagramLoadContext? {
        guard canInspectPostgresTypes,
              let profile = library.savedConnections.first(where: { $0.id == model.stored.profileID }),
              profile.engine == model.stored.engine, Data(profile.database.utf8) == Data(model.stored.database.utf8),
              let service = services[profile.id], service.connectionState == .connected,
              let sessionID = service.sessionId, let revision = typeProfileRevisions[profile.id],
              let serviceGeneration = typeServiceGenerations[profile.id], service.activeConnectionId == profile.id else { return nil }
        let settings = ConnectionSettings(host: service.host, port: Int(service.port) ?? -1, database: service.database,
            user: service.user, password: "", sslMode: service.sslMode,
            sslRootCert: service.sslRootCert.isEmpty ? nil : service.sslRootCert, engine: service.engine,
            policy: service.policy, contactPoints: service.contactPoints, localDatacenter: service.localDatacenter,
            consistency: service.consistency, ssh: service.ssh, passwordCommand: service.passwordCommand)
        let connected = SavedConnection(id: profile.id, name: profile.name, settings: settings)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let savedBytes = try? encoder.encode(profile), let connectedBytes = try? encoder.encode(connected),
              savedBytes == connectedBytes else { return nil }
        return .init(profileID: profile.id, sessionID: sessionID, serviceGeneration: serviceGeneration,
                     settingsRevision: revision, engine: profile.engine, database: profile.database)
    }

    /// Both connection creation and metadata work require this explicit action.
    func buildERDiagram(_ document: SQLDocument, connect: Bool = false, retryFailuresOnly: Bool = false) async {
        guard canStartOperation(document), let model = document.erDiagramModel,
              model.request?.finished != false, model.searchRequest?.finished != false, !model.isLoading,
              model.stored.isValid, !model.stored.tables.isEmpty else { return }
        guard let profile = library.savedConnections.first(where: { $0.id == model.stored.profileID }),
              profile.engine == model.stored.engine, Data(profile.database.utf8) == Data(model.stored.database.utf8) else {
            model.notice = "The original profile is missing or its engine/database changed. Open a new diagram for the current connection context."
            return
        }
        let settingsRevision = typeProfileRevisions[model.stored.profileID]
        let invocation = model.generation
        if connect, erDiagramContext(model) == nil { await connectProfile(model.stored.profileID) }
        guard canStartOperation(document), model.generation == invocation,
              settingsRevision == typeProfileRevisions[model.stored.profileID], document.profileID == model.stored.profileID else { return }
        guard let context = erDiagramContext(model) else {
            model.notice = "Connect the original saved profile with matching engine/database settings, then Build explicitly. A changed database requires a new diagram."
            return
        }
        await ERDiagramLoader.load(model, context: context, isCurrent: { [weak self, weak document] in
            guard let self, let document else { return false }
            return self.canStartOperation(document) && document.erDiagramModel === model &&
                document.profileID == context.profileID && self.erDiagramContext(model) == context
        }, provider: { [weak self] request in
            guard let self, self.erDiagramContext(model) == context else { throw CancellationError() }
            return try await self.erCatalog(request, model: model, context: context)
        }, retryFailuresOnly: retryFailuresOnly)
    }

    private func erCatalog(_ request: CatalogRequest, model: ERDiagramModel, context: ERDiagramLoadContext,
                           searching: Bool = false) async throws -> BackendMessage {
        let pending = CatalogMetadataRequest()
        if searching { model.searchRequest = pending; model.searchContext = context }
        else { model.request = pending }
        defer {
            if searching, model.searchRequest === pending { model.searchRequest = nil; model.searchContext = nil }
            if !searching, model.request === pending { model.request = nil }
            model.objectWillChange.send()
        }
        let reply = try await catalog(request, profileID: context.profileID, connectedSessionID: context.sessionID, metadataRequest: pending)
        guard erDiagramContext(model) == context, !pending.cancelled,
              reply.sessionId == context.sessionID, reply.queryId == pending.queryID else { throw CancellationError() }
        return reply
    }

    func searchERDiagram(_ document: SQLDocument, schema: String, search: String) async {
        guard canStartOperation(document), let model = document.erDiagramModel, !model.isSearching,
              !model.isLoading, model.searchRequest?.finished != false,
              ERTableID.validName(schema), search.utf8.count <= 1_024,
              let context = erDiagramContext(model) else {
            document.erDiagramModel?.candidateNotice = "Connect explicitly before searching metadata. Enter an exact schema name."
            return
        }
        model.isSearching = true; model.candidateNotice = nil
        let generation = model.generation
        defer { model.isSearching = false }
        do {
            let reply = try await erCatalog(CatalogRequest(kind: search.isEmpty ? "objects" : "search", schema: schema,
                objectKind: search.isEmpty ? "table" : nil, search: search.isEmpty ? nil : search), model: model, context: context, searching: true)
            guard canStartOperation(document), model.generation == generation, erDiagramContext(model) == context else { return }
            let names = (reply.columns ?? []).map(\.name)
            guard Set(names).count == names.count, Set(["name", "kind", "schema"]).isSubset(of: Set(names)) else {
                throw ERDiagramFailure("The table list is incomplete or malformed.")
            }
            var seen = Set<ERTableID>()
            model.candidates = reply.catalogRecords.compactMap { record in
                guard record["kind"] == "table", let schema = record["schema"], let name = record["name"] else { return nil }
                let table = ERTableID(profileID: context.profileID, schema: schema, name: name)
                guard table.isValid, seen.insert(table).inserted else { return nil }
                return table
            }
            if reply.truncated == true || (reply.rowCount ?? Int64(reply.rows?.count ?? 0)) > Int64(reply.rows?.count ?? 0) {
                model.candidateNotice = "This list is incomplete. Narrow the search or add an exact schema/table name below."
            } else { model.candidateNotice = ERDiagramMetadata.notice(reply) }
        } catch {
            guard model.generation == generation else { return }
            model.candidateNotice = "Table search is unavailable. Check metadata permissions or add an exact qualified name."
        }
    }

    func stopERDiagram(_ model: ERDiagramModel, reason: String = "Stopped loading. Build explicitly to retry.") {
        let requests = [(model.request, model.context), (model.searchRequest, model.searchContext)]
        model.invalidate(reason); model.isSearching = false
        for (pending, context) in requests {
            guard let pending, !pending.cancelled, !pending.finished else { continue }
            pending.cancelled = true; pending.task?.cancel()
            guard pending.submitted, let context else { continue }
            model.notice = reason + " Cancellation requested; waiting for the helper response."
            let generation = model.generation
            Task { @MainActor [weak self, weak model] in
                guard let self else { return }
                do {
                    let reply = try await self.cancelPostgresTypeCatalogQuery(sessionID: context.sessionID, queryID: pending.queryID)
                    guard let model, model.generation == generation else { return }
                    guard reply.type == "cancel.ack", reply.sessionId == context.sessionID, reply.queryId == pending.queryID else { throw CancellationError() }
                    model.notice = reason + (reply.status == "accepted" ? " The helper accepted cancellation." : " The request had already finished.")
                } catch {
                    guard let model, model.generation == generation else { return }
                    model.notice = reason + " Cancellation could not be confirmed; wait for completion or disconnect."
                }
            }
        }
    }
    func invalidateERDiagrams(profileID: UUID? = nil, reason: String) {
        for document in documents {
            guard let model = document.erDiagramModel, model.context != nil || model.searchContext != nil,
                  profileID == nil || model.stored.profileID == profileID else { continue }
            stopERDiagram(model, reason: reason)
        }
    }
    func openERTable(_ document: SQLDocument, table: ERTableID, newTab: Bool = false, structure: Bool = false) async {
        guard canStartOperation(document), let model = document.erDiagramModel,
              model.stored.tables.contains(table), table.profileID == model.stored.profileID,
              document.profileID == model.stored.profileID,
              let profile = library.savedConnections.first(where: { $0.id == table.profileID }),
              profile.engine == model.stored.engine, Data(profile.database.utf8) == Data(model.stored.database.utf8) else { return }
        let node = CatalogNode(profileID: table.profileID, name: table.name, kind: .object, schema: table.schema,
                               object: table.name, objectKind: "table", engine: model.stored.engine)
        if structure { await inspect(node) }
        else { _ = await openData(node, inNewTab: newTab, in: pane(containing: document.id)) }
    }
}
