import Foundation

extension ApplicationWorkspace {
    func logicalRelationshipDirections(_ document: SQLDocument, grid: GridDraft) -> [LogicalRelationshipDirection] {
        guard let profileID = document.profileID, let source = try? logicalRelationshipSource(document, grid: grid) else { return [] }
        return logicalRelationships.relationships.flatMap { relationship -> [LogicalRelationshipDirection] in
            var directions: [LogicalRelationshipDirection] = []
            if relationship.source.matches(profileID: profileID, reference: source.reference) { directions.append(.init(relationship: relationship, isReversed: false)) }
            if relationship.target.matches(profileID: profileID, reference: source.reference) { directions.append(.init(relationship: relationship, isReversed: true)) }
            return directions
        }
    }
    func logicalRelationshipTargetLabel(_ direction: LogicalRelationshipDirection) -> String {
        let target = direction.oriented.target
        let profile = library.savedConnections.first { $0.id == target.profileID }
        return direction.relationship.name + " → " + (profile?.name ?? "Missing profile") + " · " + target.label
    }
    func stopLogicalRelationshipNavigation(_ document: SQLDocument) async { await document.logicalRelationshipRead?.stop() }
    func stopLogicalRelationshipNavigations() async {
        for document in allOwnedRuntimeDocuments { await document.logicalRelationshipRead?.stop() }
        closeLogicalRelationshipEditor()
    }
    func followLogicalRelationship(_ direction: LogicalRelationshipDirection, rowID: UUID, in document: SQLDocument) async {
        guard canStartOperation(document), !document.isRunning, !document.isNavigatingTable,
              document.logicalRelationshipRead == nil, let grid = document.grid,
              !grid.isApplying, !grid.isPreviewing, !grid.isReloading, !grid.isClosing,
              !grid.outcomeUnknown, !grid.resultIsStale, !document.hasPendingBrowseChanges,
              let profileID = document.profileID, let runtime = document.runtime,
              runtime.connectionState == .connected, runtime.transactionStatus == .idle,
              let session = runtime.sessionId else {
            document.tableNavigationError = "Load a current table or a provenance-verified query result on its idle original session before following a local relationship."
            return
        }
        grid.commitEditing?()
        guard !grid.hasInlineDraft, let row = grid.rows.first(where: { $0.id == rowID }), !row.isDeleted,
              let original = row.original else {
            document.tableNavigationError = "Finish the cell edit and apply any new source row before following a stored relationship."
            return
        }
        let relationship = direction.oriented
        guard logicalRelationships.relationship(id: direction.relationship.id) == direction.relationship,
              logicalRelationshipProfilesMatch(direction.relationship), relationship.source.profileID == profileID else {
            document.tableNavigationError = "The local relationship or its saved profiles changed. Edit and validate it before use."
            return
        }
        let source: LogicalRelationshipSource
        let filters: [CatalogFilter]
        do {
            source = try logicalRelationshipSource(document, grid: grid)
            guard relationship.source.matches(profileID: profileID, reference: source.reference) else { throw LogicalRelationshipError.invalid }
            filters = try LogicalRelationshipNavigation.filters(relationship, sourceColumns: source.columns, sourceDeclarations: source.declarations, sourceTypeOIDs: source.typeOIDs, sourceBaseTypeOIDs: source.baseTypeOIDs, values: original)
            guard try LogicalRelationshipNavigation.filters(relationship, sourceColumns: source.columns, sourceDeclarations: source.declarations, sourceTypeOIDs: source.typeOIDs, sourceBaseTypeOIDs: source.baseTypeOIDs, values: row.values) == filters else {
                throw LogicalRelationshipError.metadata("Apply or discard changed relationship-key values before opening related rows in a new tab.")
            }
        } catch { document.tableNavigationError = error.localizedDescription; return }
        let selection = capturePaneSelection(in: pane(containing: document.id))
        let read = LogicalRelationshipRead()
        let rowValues = row.values, rowOriginal = original
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        let timeout = Task { @MainActor [weak read] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            await read?.stop()
        }
        document.logicalRelationshipRead = read; document.isNavigatingTable = true; document.stopRequested = false
        let wasClosing = grid.isClosing; grid.isClosing = true; document.tableNavigationError = nil
        defer {
            timeout.cancel()
            read.pending = nil
            grid.isClosing = wasClosing
            if document.logicalRelationshipRead === read { document.logicalRelationshipRead = nil; document.isNavigatingTable = false }
        }
        func current() -> Bool {
            guard !Task.isCancelled, relationshipServiceContextIsAvailable, ownedSQLContext(for: document) != nil,
                  document.logicalRelationshipRead === read, !read.cancelled, !document.stopRequested,
                  document.profileID == profileID, document.grid === grid, document.runtime === runtime,
                  runtime.sessionId == session, runtime.connectionState == .connected, runtime.transactionStatus == .idle,
                  !grid.resultIsStale, !grid.outcomeUnknown, let currentRow = grid.rows.first(where: { $0.id == rowID }),
                  !currentRow.isDeleted, currentRow.original == rowOriginal, currentRow.values == rowValues,
                  logicalRelationships.relationship(id: direction.relationship.id) == direction.relationship,
                  logicalRelationshipProfilesMatch(direction.relationship), let actual = try? logicalRelationshipSource(document, grid: grid),
                  ForeignKeyPickerValues.sameTable(actual.reference, source.reference), actual.fromQuery == source.fromQuery,
                  actual.columns.count == source.columns.count,
                  actual.declarations.map({ Data($0.utf8) }) == source.declarations.map({ Data($0.utf8) }),
                  actual.typeOIDs == source.typeOIDs, actual.baseTypeOIDs == source.baseTypeOIDs else { return false }
            return zip(actual.columns, source.columns).allSatisfy {
                Data($0.name.utf8) == Data($1.name.utf8) && Data($0.nativeType.utf8) == Data($1.nativeType.utf8) && $0.engine == $1.engine &&
                    $0.typeOid == $1.typeOid && $0.typeIdentity.map({ Data($0.utf8) }) == $1.typeIdentity.map({ Data($0.utf8) }) && $0.encoding == $1.encoding
            }
        }
        read.stopHandler = { [weak self, weak read] in
            guard let self, let read else { return }
            if let pending = read.pending, !pending.request.finished {
                pending.request.cancelled = true
                if pending.request.submitted {
                    _ = try? await self.cancelPostgresTypeCatalogQuery(sessionID: pending.session, queryID: pending.request.queryID)
                } else { pending.request.task?.cancel() }
            }
            if let target = read.targetDocument, self.ownedSQLContext(for: target) != nil { await self.stop(target) }
        }
        func metadata(_ endpoint: LogicalRelationshipEndpoint) async throws -> (ERDiagramLoadContext, BackendMessage, [ERColumn]) {
            guard current(), ContinuousClock.now < deadline else { throw CancellationError() }
            if services[endpoint.profileID]?.connectionState != .connected { await connectProfile(endpoint.profileID) }
            guard current(), let context = logicalMetadataContext(endpoint) else {
                throw LogicalRelationshipError.metadata("The saved connection settings changed or the selected profile is unavailable. Reconnect explicitly and retry.")
            }
            let request = CatalogMetadataRequest(); read.pending = (context.sessionID, request)
            defer { if read.pending?.request === request { read.pending = nil } }
            let result = try await catalog(.init(kind: "columns", schema: endpoint.schema, object: endpoint.name, objectKind: endpoint.kind),
                profileID: endpoint.profileID, connectedSessionID: context.sessionID, metadataRequest: request)
            guard current(), !request.cancelled, logicalMetadataContext(endpoint) == context,
                  result.sessionId == context.sessionID, result.queryId == request.queryID else { throw CancellationError() }
            guard (result.rows ?? []).reduce(0, { bytes, row in bytes + row.reduce(0) { $0 + ($1?.utf8.count ?? 4) } }) <= LogicalRelationshipLimits.metadataBytes else {
                throw LogicalRelationshipError.metadata("Relationship metadata exceeded its size limit. Narrow the mapping and retry.")
            }
            guard result.truncated != true, (result.displayNotice ?? "").isEmpty else {
                throw LogicalRelationshipError.metadata("Column metadata is incomplete or carries a server notice. Refresh the object and resolve the notice before navigating.")
            }
            return (context, result, try ERDiagramMetadata.columns(result))
        }
        await withTaskCancellationHandler {
          do {
            let sourceFacts = try await metadata(relationship.source)
            let targetFacts = try await metadata(relationship.target)
            for pair in relationship.columns {
                if relationship.source.engine == .postgresql, let index = source.columns.firstIndex(where: { Data($0.name.utf8) == Data(pair.source.utf8) }),
                   source.typeOIDs[index] != 0 {
                    let current = sourceFacts.1.catalogRecords.first { Data(($0["name"] ?? "").utf8) == Data(pair.source.utf8) }
                    guard UInt32(current?["typeOid"] ?? "") == source.typeOIDs[index],
                          (source.baseTypeOIDs[index] == 0 || UInt32(current?["baseTypeOid"] ?? "") == source.baseTypeOIDs[index]) else {
                        throw LogicalRelationshipError.metadata("A mapped source type identity changed after this row was captured. Reload the source before navigating.")
                    }
                }
                guard sourceFacts.2.contains(where: { Data($0.name.utf8) == Data(pair.source.utf8) && Data($0.nativeType.utf8) == Data(pair.sourceType.utf8) }),
                      targetFacts.2.contains(where: { Data($0.name.utf8) == Data(pair.target.utf8) && Data($0.nativeType.utf8) == Data(pair.targetType.utf8) }) else {
                    throw LogicalRelationshipError.metadata("A mapped column or its native type changed. Edit and validate the local relationship before navigating.")
                }
            }
            guard services[relationship.target.profileID]?.capabilities.contains(NativeCellFilterValue.capability) == true else {
                throw LogicalRelationshipError.metadata("Update the helper to support typed native relationship predicates. No legacy text fallback was used.")
            }
            // A close decision is a temporary admission gate, not evidence that
            // an already completed metadata read belongs to a different source.
            while current(), !canStartOperation(document, forNavigating: true), ContinuousClock.now < deadline {
                read.phase = "Waiting for the workspace close decision…"
                try await Task.sleep(for: .milliseconds(25))
            }
            guard current(), ContinuousClock.now < deadline,
                  logicalMetadataContext(relationship.source) == sourceFacts.0,
                  logicalMetadataContext(relationship.target) == targetFacts.0,
                  canStartOperation(document, forNavigating: true) else { throw CancellationError() }
            read.phase = "Opening related rows in an independent tab…"
            let location = TableViewLocation(reference: relationship.target.reference, profileID: relationship.target.profileID, filters: filters)
            await openRelatedTable(location, columns: targetFacts.1.catalogRecords, source: document, context: selection,
                isCurrent: current, onCreated: { [weak read] target in read?.targetDocument = target })
            if !current() { document.tableNavigationError = "Related-row navigation stopped or its source context changed. The source row and its local draft were kept." }
        } catch {
            if document.logicalRelationshipRead === read {
                document.tableNavigationError = read.cancelled || error is CancellationError
                    ? "Related-row navigation stopped or its source context changed. The source row and draft were kept."
                    : error.localizedDescription
            }
          }
        } onCancel: {
            Task { @MainActor in await read.stop() }
        }
    }
    private func logicalRelationshipSource(_ document: SQLDocument, grid: GridDraft) throws -> LogicalRelationshipSource {
        if let table = document.table {
            guard ForeignKeyPickerValues.sameTable(table, grid.reference),
                  document.tableLoadedConfiguration == document.browseConfiguration else {
                throw LogicalRelationshipError.metadata("Reload the active table view before following its captured row values.")
            }
            guard grid.metadata.count == grid.columns.count, grid.columns.indices.allSatisfy({ index in
                grid.metadata[index]["name"].map { Data($0.utf8) == Data(grid.columns[index].name.utf8) } == true &&
                    !(grid.metadata[index]["nativeType"] ?? "").isEmpty
            }) else { throw LogicalRelationshipError.metadata("The captured source column declarations are incomplete or ambiguous. Reload the source before navigating.") }
            return .init(reference: table, columns: grid.columns, declarations: grid.metadata.map { $0["nativeType"] ?? "" },
                typeOIDs: grid.metadata.map { UInt32($0["typeOid"] ?? "") ?? 0 }, baseTypeOIDs: grid.metadata.map { UInt32($0["baseTypeOid"] ?? "") ?? 0 }, fromQuery: false)
        }
        guard document.isSQLDocument, let source = grid.querySource, source.canOpenRow, source.valid(for: grid.columns),
              let runtime = document.runtime, runtime.connectionState == .connected, runtime.transactionStatus == .idle,
              runtime.sessionId == grid.querySessionID,
              let profile = library.savedConnections.first(where: { $0.id == document.profileID }), runtime.matchesResultSourceProfile(profile),
              ForeignKeyPickerValues.sameTable(.init(schema: source.schema, name: source.table, kind: "table"), grid.reference) else {
            throw LogicalRelationshipError.metadata("This query result has no complete, current source-column provenance. Open its source table instead.")
        }
        let columns = grid.columns.indices.map { index in
            ResultColumn(index: index, name: source.columns[index].name, typeOid: grid.columns[index].typeOid,
                engine: grid.columns[index].engine, nativeType: grid.columns[index].nativeType,
                encoding: grid.columns[index].encoding, typeIdentity: grid.columns[index].typeIdentity)
        }
        // The helper's source proof requires every field DataTypeOID to equal
        // its originating catalog attribute OID, before alias remapping.
        return .init(reference: grid.reference, columns: columns, declarations: source.columns.map(\.nativeType),
            typeOIDs: grid.columns.map(\.typeOid), baseTypeOIDs: Array(repeating: 0, count: grid.columns.count), fromQuery: true)
    }
}
