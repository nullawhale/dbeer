import Foundation

extension ApplicationWorkspace {
    @discardableResult
    func openERDiagram(_ node: CatalogNode) -> SQLDocument? {
        guard canManageWorkspace, let profile = library.savedConnections.first(where: { $0.id == node.profileID }),
              [.postgresql, .mysql, .sqlite].contains(profile.engine), node.kind == .schema || (node.kind == .object && node.objectKind == "table") else { return nil }
        var stored = StoredERDiagram(profileID: profile.id, engine: profile.engine, database: profile.database)
        stored.sources = [.init(profile)]
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

    func erConnectedProfileContext(_ profileID: UUID) -> ERDiagramLoadContext? {
        guard relationshipServiceContextIsAvailable,
              let profile = library.savedConnections.first(where: { $0.id == profileID }),
              let service = services[profile.id], service.connectionState == .connected,
              let sessionID = service.sessionId, let revision = ERDiagramSource(profile).revision,
              let serviceGeneration = typeServiceGenerations[profile.id], service.activeConnectionId == profile.id else { return nil }
        let settings = ConnectionSettings(host: service.host, port: Int(service.port) ?? -1, database: service.database,
            user: service.user, password: "", sslMode: service.sslMode,
            sslRootCert: service.sslRootCert.isEmpty ? nil : service.sslRootCert, engine: service.engine,
            policy: service.policy, contactPoints: service.contactPoints, localDatacenter: service.localDatacenter,
            consistency: service.consistency, ssh: service.ssh, passwordCommand: service.passwordCommand, mongodb: service.mongodb, sqlite: service.sqlite)
        let connected = SavedConnection(id: profile.id, name: profile.name, settings: settings)
        guard LogicalRelationshipEndpoint.fingerprint(profile) == LogicalRelationshipEndpoint.fingerprint(connected) else { return nil }
        return .init(profileID: profile.id, sessionID: sessionID, serviceGeneration: serviceGeneration,
                     settingsRevision: revision, engine: profile.engine, database: profile.database)
    }

    func erDiagramContext(_ model: ERDiagramModel, profileID: UUID? = nil) -> ERDiagramLoadContext? {
        let id = profileID ?? model.activeSourceID
        guard let binding = model.source(id), let profile = library.savedConnections.first(where: { $0.id == id }),
              binding.matches(profile) else { return nil }
        return erConnectedProfileContext(id)
    }

    func selectERDiagramSource(_ model: ERDiagramModel, profileID: UUID) {
        let pending = model.searchRequest, context = model.searchContext
        model.selectSource(profileID)
        if let pending, let context, pending.submitted, !pending.finished {
            Task { _ = try? await cancelPostgresTypeCatalogQuery(sessionID: context.sessionID, queryID: pending.queryID) }
        }
    }

    func confirmERDiagramSource(_ document: SQLDocument, profileID: UUID, expectedFingerprint: String? = nil) {
        guard canStartOperation(document), canStartERSource(profileID), let model = document.erDiagramModel,
              let profile = library.savedConnections.first(where: { $0.id == profileID }),
              expectedFingerprint == nil || LogicalRelationshipEndpoint.fingerprint(profile) == expectedFingerprint, model.bindSource(profile) else { return }
        model.selectSource(profileID)
    }

    func removeERDiagramSource(_ document: SQLDocument, profileID: UUID, expectedFingerprint: String, expectedTables: [ERTableID]? = nil) {
        guard canStartOperation(document), canStartERSource(profileID), let model = document.erDiagramModel,
              (model.source(profileID)?.fingerprint ?? "legacy") == expectedFingerprint,
              expectedTables == nil || model.stored.tables.filter({ $0.profileID == profileID }) == expectedTables else { return }
        stopERDiagramSource(model, profileID: profileID, reason: "This source was removed from the diagram.")
        model.removeSource(profileID)
        retireChangedERDiagramExports()
    }

    /// Called only after the user reviews the old and new exact ownership.
    func rebindERDiagramTable(_ document: SQLDocument, original: ERTableID, replacement: ERTableID, expectedOriginalFingerprint: String? = nil, expectedDestinationFingerprint: String? = nil) {
        guard canStartOperation(document), canStartERSource(original.profileID), canStartERSource(replacement.profileID), let model = document.erDiagramModel,
              let profile = library.savedConnections.first(where: { $0.id == replacement.profileID }),
              expectedOriginalFingerprint == nil || (model.source(original.profileID)?.fingerprint ?? "legacy") == expectedOriginalFingerprint,
              expectedDestinationFingerprint == nil || LogicalRelationshipEndpoint.fingerprint(profile) == expectedDestinationFingerprint else { return }
        stopERDiagramSource(model, profileID: original.profileID, reason: "An object is being rebound.")
        if replacement.profileID != original.profileID { stopERDiagramSource(model, profileID: replacement.profileID, reason: "An object is being rebound.") }
        do { try model.rebind(original, to: replacement, profile: profile); retireChangedERDiagramExports() }
        catch { model.notice = error.localizedDescription }
    }

    func erDiagramBindingIsCurrent(_ document: SQLDocument, model: ERDiagramModel, context: ERDiagramLoadContext) -> Bool {
        relationshipDocumentIsCurrent(document) && document.erDiagramModel === model &&
            document.profileID == model.stored.profileID && erDiagramContext(model, profileID: context.profileID) == context
    }

    /// Each explicitly selected source owns its connection and metadata attempt.
    func buildERDiagram(_ document: SQLDocument, profileID: UUID? = nil, connect: Bool = false, retryFailuresOnly: Bool = false) async {
        guard canStartOperation(document), let model = document.erDiagramModel else { return }
        let id = profileID ?? model.activeSourceID
        let state = model.sourceState(id)
        guard canStartERSource(id), state.request?.finished != false, !state.loading,
              model.stored.isValid, model.stored.tables.contains(where: { $0.profileID == id }) else { return }
        guard let profile = library.savedConnections.first(where: { $0.id == id }),
              let binding = model.source(id), binding.matches(profile) else {
            model.sourceStates[id, default: .init()].notice = "The original profile is missing, changed or unconfirmed. Confirm a legacy binding or explicitly rebind its objects before loading."
            return
        }
        model.sourceStates[id, default: .init()].generation &+= 1
        let invocation = model.sourceState(id).generation
        model.sourceStates[id, default: .init()].loading = true
        defer { model.finishLoad(id, generation: invocation) }
        let settingsRevision = binding.fingerprint
        if connect, erDiagramContext(model, profileID: id) == nil { await connectProfile(id) }
        guard relationshipDocumentIsCurrent(document), document.erDiagramModel === model,
              model.sourceState(id).generation == invocation, settingsRevision == model.source(id)?.fingerprint,
              model.source(id)?.matches(profile) == true, document.profileID == model.stored.profileID else { return }
        guard let context = erDiagramContext(model, profileID: id) else {
            model.sourceStates[id, default: .init()].notice = "Connect this exact saved profile, then Build explicitly."
            return
        }
        await ERDiagramLoader.load(model, context: context, isCurrent: { [weak self, weak document] in
            guard let self, let document else { return false }
            return self.erDiagramBindingIsCurrent(document, model: model, context: context)
        }, provider: { [weak self] request in
            guard let self, self.erDiagramContext(model, profileID: id) == context else { throw CancellationError() }
            return try await self.erCatalog(request, model: model, context: context)
        }, retryFailuresOnly: retryFailuresOnly)
    }

    private func erCatalog(_ request: CatalogRequest, model: ERDiagramModel, context: ERDiagramLoadContext,
                           searching: Bool = false) async throws -> BackendMessage {
        let pending = CatalogMetadataRequest()
        if searching { model.searchRequest = pending; model.searchContext = context }
        else { model.sourceStates[context.profileID, default: .init()].request = pending }
        defer {
            if searching, model.searchRequest === pending { model.searchRequest = nil; model.searchContext = nil }
            if !searching, model.sourceState(context.profileID).request === pending { model.sourceStates[context.profileID, default: .init()].request = nil }
            model.objectWillChange.send()
        }
        let reply = try await catalog(request, profileID: context.profileID, connectedSessionID: context.sessionID, metadataRequest: pending)
        guard erDiagramContext(model, profileID: context.profileID) == context, !pending.cancelled,
              reply.sessionId == context.sessionID, reply.queryId == pending.queryID else { throw CancellationError() }
        return reply
    }

    func searchERDiagram(_ document: SQLDocument, schema: String, search: String) async {
        guard canStartOperation(document), let model = document.erDiagramModel, canStartERSource(model.activeSourceID), !model.isSearching,
              !model.activeSourceIsLoading, model.searchRequest?.finished != false,
              ERTableID.validName(schema), search.utf8.count <= 1_024,
              let context = erDiagramContext(model) else {
            document.erDiagramModel?.candidateNotice = "Connect explicitly before searching metadata. Enter an exact schema name."
            return
        }
        model.isSearching = true; model.candidateNotice = nil
        let generation = model.sourceState(context.profileID).generation
        model.searchGeneration &+= 1
        let searchGeneration = model.searchGeneration
        defer { if model.searchGeneration == searchGeneration { model.isSearching = false } }
        do {
            let reply = try await erCatalog(CatalogRequest(kind: search.isEmpty ? "objects" : "search", schema: schema,
                objectKind: search.isEmpty ? "table" : nil, search: search.isEmpty ? nil : search), model: model, context: context, searching: true)
            guard erDiagramBindingIsCurrent(document, model: model, context: context), model.sourceState(context.profileID).generation == generation, model.activeSourceID == context.profileID,
                  model.searchGeneration == searchGeneration else { return }
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
            guard erDiagramBindingIsCurrent(document, model: model, context: context), model.sourceState(context.profileID).generation == generation, model.activeSourceID == context.profileID,
                  model.searchGeneration == searchGeneration else { return }
            model.candidateNotice = "Table search is unavailable. Check metadata permissions or add an exact qualified name."
        }
    }

    func stopERDiagramSource(_ model: ERDiagramModel, profileID: UUID, reason: String = "Stopped loading. Build this source explicitly to retry.") {
        let state = model.sourceState(profileID)
        var requests: [(CatalogMetadataRequest?, ERDiagramLoadContext?)] = [(state.request, state.context)]
        if model.searchContext?.profileID == profileID {
            requests.append((model.searchRequest, model.searchContext)); model.isSearching = false
        }
        if model.activeSourceID == profileID {
            model.visibleTableDiscovery?.stop(); model.neighbourDiscovery?.stop()
        }
        model.invalidateSource(profileID, reason: reason)
        let generation = model.sourceState(profileID).generation
        for (pending, context) in requests {
            guard let pending, !pending.cancelled, !pending.finished else { continue }
            pending.cancelled = true; pending.task?.cancel()
            guard pending.submitted, let context else { continue }
            model.sourceStates[profileID, default: .init()].notice = reason + " Cancellation requested; waiting for the helper response."
            Task { @MainActor [weak self, weak model] in
                guard let self else { return }
                do {
                    let reply = try await self.cancelPostgresTypeCatalogQuery(sessionID: context.sessionID, queryID: pending.queryID)
                    guard let model, model.sourceState(profileID).generation == generation else { return }
                    guard reply.type == "cancel.ack", reply.sessionId == context.sessionID, reply.queryId == pending.queryID else { throw CancellationError() }
                    model.sourceStates[profileID, default: .init()].notice = reason + (reply.status == "accepted" ? " The helper accepted cancellation." : " The request had already finished.")
                } catch {
                    guard let model, model.sourceState(profileID).generation == generation else { return }
                    model.sourceStates[profileID, default: .init()].notice = reason + " Cancellation could not be confirmed; wait for completion or disconnect."
                }
            }
        }
    }
    func stopERDiagram(_ model: ERDiagramModel, reason: String = "Stopped loading. Build explicitly to retry.") {
        for id in Set(model.sourceStates.keys).union(model.stored.tables.map(\.profileID)).union([model.stored.profileID]) {
            stopERDiagramSource(model, profileID: id, reason: reason)
        }
        model.visibleTableDiscovery?.stop(); model.neighbourDiscovery?.stop()
    }



    func invalidateERDiagrams(profileID: UUID? = nil, includePreparing: Bool = false, reason: String) {
        for document in documents {
            if profileID == nil || document.profileID == profileID { document.incomingRelationships?.stop() }
            guard let model = document.erDiagramModel else { continue }
            if let profileID {
                guard model.ownsSource(profileID) else { continue }
                let state = model.sourceState(profileID)
                guard includePreparing || state.context != nil || state.request != nil ||
                    model.searchContext?.profileID == profileID || model.visibleTableDiscovery?.profileID == profileID ||
                    model.neighbourDiscovery?.target.profileID == profileID else { continue }
                stopERDiagramSource(model, profileID: profileID, reason: reason)
            } else { stopERDiagram(model, reason: reason) }
        }
    }
    func openERTable(_ document: SQLDocument, table: ERTableID, newTab: Bool = false, structure: Bool = false) async {
        guard canStartOperation(document), canStartERSource(table.profileID), let model = document.erDiagramModel,
              model.stored.tables.contains(table), model.ownsSource(table.profileID),
              document.profileID == model.stored.profileID,
              let profile = library.savedConnections.first(where: { $0.id == table.profileID }),
              model.source(table.profileID)?.matches(profile) == true else { return }
        let node = CatalogNode(profileID: table.profileID, name: table.name, kind: .object, schema: table.schema,
                               object: table.name, objectKind: "table", engine: profile.engine)
        if structure { await inspect(node) }
        else { _ = await openData(node, inNewTab: newTab, in: pane(containing: document.id)) }
    }
}
