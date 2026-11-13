import Foundation

extension ApplicationWorkspace {
    func supportsRelationshipDiscovery(profileID: UUID?) -> Bool {
        guard let profileID, let service = services[profileID], service.connectionState == .connected else { return false }
        return service.capabilities.contains("incomingRelationsV1") && service.capabilities.contains("catalogMetadataV1")
    }

    private func relationshipContext(profileID: UUID) -> ERDiagramLoadContext? {
        guard let profile = library.savedConnections.first(where: { $0.id == profileID }),
              [.postgresql, .mysql, .sqlite].contains(profile.engine) else { return nil }
        return erConnectedProfileContext(profile.id)
    }

    private func discoveryReader(context: ERDiagramLoadContext, current: @escaping @MainActor () -> Bool) -> CatalogDiscoveryReader {
        CatalogDiscoveryReader(provider: { [weak self] selector, pending, onPage in
            guard let self, current(), self.relationshipContext(profileID: context.profileID) == context else { throw CancellationError() }
            let reply = try await self.catalog(selector, profileID: context.profileID, connectedSessionID: context.sessionID,
                metadataRequest: pending, onMetadataPage: onPage)
            guard current(), self.relationshipContext(profileID: context.profileID) == context,
                  !pending.cancelled, reply.sessionId == context.sessionID, reply.queryId == pending.queryID else { throw CancellationError() }
            return reply
        }, isCurrent: { [weak self] in
            guard let self else { return false }
            return current() && self.relationshipContext(profileID: context.profileID) == context
        }, cancel: { [weak self] pending in
            guard pending.submitted else { return }
            Task { @MainActor [weak self] in
                _ = try? await self?.cancelPostgresTypeCatalogQuery(sessionID: context.sessionID, queryID: pending.queryID)
            }
        })
    }

    /// This action never creates a connection or starts on document restoration.
    func discoverIncomingRows(_ document: SQLDocument) async {
        guard canStartOperation(document), document.canNavigateTable,
              document.incomingRelationships?.isBusy != true,
              let profileID = document.profileID, let table = document.table,
              supportsRelationshipDiscovery(profileID: profileID), let context = relationshipContext(profileID: profileID) else {
            document.tableNavigationError = "Connect the original profile with a helper that supports incoming relationship discovery, then retry explicitly."
            return
        }
        let target = ERTableID(profileID: profileID, schema: table.schema, name: table.name)
        let reader = discoveryReader(context: context, current: { [weak self, weak document] in
            guard let self, let document else { return false }
            return self.relationshipDocumentIsCurrent(document) &&
                document.profileID == profileID && document.table.map { Data($0.schema.utf8) == Data(table.schema.utf8) && Data($0.name.utf8) == Data(table.name.utf8) } == true
        })
        let model = IncomingRelationshipDiscoveryModel(target: target, reader: reader)
        document.incomingRelationships = model
        await model.discover()
    }

    func discoverERVisibleTables(_ document: SQLDocument, schema: String? = nil) async {
        guard canStartOperation(document), let model = document.erDiagramModel, canStartERSource(model.stored.profileID), !model.isLoading, !model.isSearching,
              model.visibleTableDiscovery?.isBusy != true, model.neighbourDiscovery?.isBusy != true,
              supportsRelationshipDiscovery(profileID: model.stored.profileID), let context = erDiagramContext(model) else {
            document.erDiagramModel?.candidateNotice = "Connect explicitly before discovering visible tables."
            return
        }
        let generation = model.generation
        let reader = discoveryReader(context: context, current: { [weak self, weak document, weak model] in
            guard let self, let document, let model else { return false }
            return self.relationshipDocumentIsCurrent(document) &&
                document.erDiagramModel === model && model.stored.profileID == context.profileID && model.generation == generation && self.erDiagramContext(model) == context
        })
        let discovery = VisibleTableDiscoveryModel(profileID: context.profileID, reader: reader)
        model.visibleTableDiscovery = discovery
        await discovery.discover(schema: schema)
    }

    func discoverERNeighbours(_ document: SQLDocument) async {
        guard canStartOperation(document), let model = document.erDiagramModel, !model.isSearching,
              model.visibleTableDiscovery?.isBusy != true, model.neighbourDiscovery?.isBusy != true,
              let target = model.stored.selected, canStartERSource(target.profileID), model.stored.tables.contains(target),
              !model.isLoading, supportsRelationshipDiscovery(profileID: target.profileID), let context = erDiagramContext(model) else { return }
        let generation = model.generation
        let reader = discoveryReader(context: context, current: { [weak self, weak document, weak model] in
            guard let self, let document, let model else { return false }
            return self.relationshipDocumentIsCurrent(document) &&
                document.erDiagramModel === model && model.generation == generation && model.stored.selected == target &&
                model.stored.tables.contains(target) && self.erDiagramContext(model) == context
        })
        let discovery = IncomingRelationshipDiscoveryModel(target: target, reader: reader)
        model.neighbourDiscovery = discovery
        await discovery.discover(includeOutgoing: true)
        if model.generation == generation, erDiagramContext(model) == context,
           model.stored.selected == target, let canonical = discovery.resolvedTarget, discovery.reader.contextIsCurrent {
            model.adoptCanonicalIdentity(target, resolved: canonical)
        }
    }

    func followIncomingRelationship(_ relationship: DiscoveredTableRelationship, rowID: UUID,
                                    in document: SQLDocument, inNewTab: Bool = true) async {
        guard canStartOperation(document), document.canNavigateTable,
              let discovery = document.incomingRelationships, !discovery.isBusy, discovery.reader.contextIsCurrent,
              discovery.relationships.contains(where: { $0.id == relationship.id && $0.key == relationship.key }),
              let source = TableViewLocation(document), let context = relationshipContext(profileID: source.profileID),
              discovery.target == ERTableID(profileID: source.profileID, schema: source.reference.schema, name: source.reference.name),
              relationship.target == discovery.resolvedTarget else { return }
        document.grid?.commitEditing?()
        guard let grid = document.grid, let row = grid.rows.first(where: { $0.id == rowID }) else { return }
        let key = relationship.inverseKey()
        let paneContext = capturePaneSelection(in: pane(containing: document.id))
        document.isNavigatingTable = true
        let wasClosing = grid.isClosing
        grid.isClosing = true
        defer { grid.isClosing = wasClosing; document.isNavigatingTable = false }
        document.tableNavigationError = nil
        func current() -> Bool {
            navigationIsCurrent(document, source: source) && document.incomingRelationships === discovery &&
                relationshipContext(profileID: source.profileID) == context
        }
        do {
            let metadata = try await catalog(.init(kind: "foreignKeys", schema: relationship.source.schema, object: relationship.source.name,
                objectKind: "table"), profileID: source.profileID, connectedSessionID: context.sessionID)
            guard current() else { return }
            let freshKeys = try TableForeignKey.parse(metadata)
            guard freshKeys.contains(where: { $0.sameMapping(as: relationship.key) }) else {
                throw TableNavigationFailure("The declared incoming relationship changed. Discover incoming relations again.")
            }
            let columns = try await navigationColumns(key.target, profileID: source.profileID, required: Set(key.columns.map(\.target)),
                connectedSessionID: context.sessionID)
            guard current() else { return }
            // Exact UTF-8 checks reject canonically equivalent but different catalog names.
            let targetNames = Set(columns.compactMap { $0["name"] }.map { Data($0.utf8) })
            guard key.columns.allSatisfy({ targetNames.contains(Data($0.target.utf8)) }) else {
                throw TableNavigationFailure("The child table's mapped columns changed. Discover incoming relations again.")
            }
            let filters: [CatalogFilter]
            if inNewTab {
                guard let original = row.original else { throw TableNavigationFailure("Apply and reload the new parent row before opening child rows.") }
                let originalFilters = try key.filters(sourceColumns: grid.columns, values: original)
                guard try key.filters(sourceColumns: grid.columns, values: row.values) == originalFilters else {
                    throw TableNavigationFailure("Apply or discard changed parent-key values before opening child rows in a new tab.")
                }
                filters = originalFilters
            } else {
                guard let resolved = try await navigationFiltersAfterReview(document, grid: grid, key: key, row: row) else { return }
                filters = resolved
            }
            guard current() else { return }
            let target: TableViewLocation
            if context.engine == .sqlite {
                guard document.runtime?.capabilities.contains(SQLiteRelationshipScope.capability) == true else {
                    throw TableNavigationFailure("Update the helper to support SQLite relationship restrictions.")
                }
                let scope = try SQLiteRelationshipScope(relationship: relationship, filters: filters)
                target = TableViewLocation(reference: key.target, profileID: source.profileID, relationshipScope: scope)
            } else { target = TableViewLocation(reference: key.target, profileID: source.profileID, filters: filters) }
            if inNewTab { await openRelatedTable(target, columns: columns, source: document, context: paneContext) }
            else if await moveTable(document, from: source, to: target, columns: columns) {
                document.tableBackHistory.append(source)
                if document.tableBackHistory.count > 100 { document.tableBackHistory.removeFirst() }
                document.tableForwardHistory = []
            }
        } catch { if current() { document.tableNavigationError = error.localizedDescription } }
    }
}
