import Foundation

struct ForeignKeyPickerMetadata {
    let id = UUID()
    let sessionID: String
    let serviceGeneration: UUID?
    let settingsRevision: UUID?
    let keys: [TableForeignKey]
}

@MainActor
private final class ForeignKeyPickerRead {
    var pending: CatalogMetadataRequest?
}

@MainActor
private struct ForeignKeyPickerAccess {
    let engine: DatabaseEngine
    let profileID: UUID
    let sessionID: String
    let serviceGeneration: UUID?
    let settingsRevision: UUID?
    let sourceColumns: [ResultColumn]
    let typedSQLiteFilters: Bool
    let current: @MainActor () -> Bool
    let read: ForeignKeyPickerModel.Read
    let cancel: @MainActor () async -> Void
    let stage: @MainActor ([Int: ChangeValue]) throws -> Void
}

extension ApplicationWorkspace {
    func cachedForeignKeyPickerKeys(_ document: SQLDocument, grid: GridDraft) -> [TableForeignKey]? {
        if document.table != nil { return document.tableForeignKeys }
        guard let profileID = document.profileID, let cached = grid.foreignKeyPickerMetadata,
              cached.sessionID == services[profileID]?.sessionId,
              cached.serviceGeneration == typeServiceGenerations[profileID],
              cached.settingsRevision == typeProfileRevisions[profileID] else { return nil }
        return cached.keys
    }

    /// Explicitly requested metadata for a proven editable SQL-result source.
    /// The immutable grid owns the cache, so a later execution cannot inherit it.
    func loadForeignKeyPickerKeys(_ document: SQLDocument, grid: GridDraft, rowID: UUID) async throws -> [TableForeignKey] {
        let access = try foreignKeyPickerAccess(document, grid: grid, rowID: rowID)
        let response = try await access.read(.init(kind: "foreignKeys", schema: grid.reference.schema,
            object: grid.reference.name, objectKind: "table"))
        guard access.current() else { throw ForeignKeyPickerFailure("The query result or connection changed. Open the picker again.") }
        let keys = try TableForeignKey.parse(response)
        grid.foreignKeyPickerMetadata = .init(sessionID: access.sessionID,
            serviceGeneration: access.serviceGeneration, settingsRevision: access.settingsRevision, keys: keys)
        return keys
    }

    func makeForeignKeyPicker(_ document: SQLDocument, grid: GridDraft, rowID: UUID,
                              key: TableForeignKey) throws -> ForeignKeyPickerModel {
        let access = try foreignKeyPickerAccess(document, grid: grid, rowID: rowID)
        guard let known = cachedForeignKeyPickerKeys(document, grid: grid),
              known.contains(where: { ForeignKeyPickerValues.sameKey($0, key) }) else {
            throw ForeignKeyPickerFailure("Load the source table's current foreign-key metadata before choosing a related record.")
        }
        let source = try ForeignKeyPickerValues.sourceIndices(key: key, columns: access.sourceColumns)
        guard let row = grid.rows.first(where: { $0.id == rowID }), source.allSatisfy({ grid.editableColumns.contains($0) }),
              !source.contains(where: { row.values[$0].kind == "default" && !row.isInserted }) else {
            throw ForeignKeyPickerFailure("Every source key column must be editable and have a resolved value.")
        }
        let revision = document.table == nil ? grid.foreignKeyPickerMetadata?.id : document.foreignKeysRequestID
        let current: @MainActor () -> Bool = { [weak self, weak document, weak grid] in
            guard let self, let document, let grid, access.current(),
                  let keys = self.cachedForeignKeyPickerKeys(document, grid: grid),
                  keys.contains(where: { ForeignKeyPickerValues.sameKey($0, key) }) else { return false }
            return revision == (document.table == nil ? grid.foreignKeyPickerMetadata?.id : document.foreignKeysRequestID)
        }
        return ForeignKeyPickerModel(key: key, engine: access.engine, sourceColumns: access.sourceColumns,
            typedSQLiteFilters: access.typedSQLiteFilters, isCurrent: current, read: access.read, cancel: access.cancel,
            stage: { assignments in
                guard current() else { throw ForeignKeyPickerFailure("The source row or connection changed. Open the picker again.") }
                try access.stage(assignments)
            })
    }

    private func foreignKeyPickerAccess(_ document: SQLDocument, grid: GridDraft, rowID: UUID) throws -> ForeignKeyPickerAccess {
        grid.commitEditing?()
        guard canStartOperation(document), document.grid === grid,
              !document.isRunning, !document.isNavigatingTable, !document.hasPendingBrowseChanges,
              grid.canEdit, !grid.isPreviewing, !grid.hasInlineDraft,
              let row = grid.rows.first(where: { $0.id == rowID }), !row.isDeleted,
              let profileID = document.profileID,
              let profile = library.savedConnections.first(where: { $0.id == profileID }),
              [.postgresql, .mysql, .sqlite].contains(profile.engine),
              let service = services[profileID], service.connectionState == .connected,
              let sessionID = service.sessionId, service.activeConnectionId == profileID,
              let runtime = document.runtime, runtime.connectionState == .connected,
              let runtimeSessionID = runtime.sessionId else {
            throw ForeignKeyPickerFailure("Load the original table or editable query result on its saved connection and finish the current operation first.")
        }
        let sourceColumns = try ForeignKeyPickerValues.canonicalColumns(grid)
        let fromQuery = document.table == nil
        if fromQuery {
            guard document.isSQLDocument, grid.querySource?.isEditable == true,
                  grid.querySessionID == runtimeSessionID, runtime.transactionStatus == .idle else {
                throw ForeignKeyPickerFailure("The query result must have complete editable source provenance and an idle original SQL session.")
            }
        } else {
            guard let table = document.table, ForeignKeyPickerValues.sameTable(table, grid.reference) else {
                throw ForeignKeyPickerFailure("The source table changed. Reload before choosing a related record.")
            }
        }
        let settingsRevision = typeProfileRevisions[profileID]
        let serviceGeneration = typeServiceGenerations[profileID]
        let sourceValues = row.values
        let sourceOriginal = row.original
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let profileBytes = try encoder.encode(profile)
        guard foreignKeyConnectionMatches(service, profile: profile, bytes: profileBytes),
              foreignKeyConnectionMatches(runtime, profile: profile, bytes: profileBytes) else {
            throw ForeignKeyPickerFailure("The saved connection changed. Reconnect and reload before choosing a related record.")
        }
        let owner = ForeignKeyPickerRead()
        let current: @MainActor () -> Bool = { [weak self, weak document, weak grid] in
            guard let self, let document, let grid,
                  self.canStartOperation(document), document.grid === grid,
                  document.profileID == profileID, (document.table == nil) == fromQuery,
                  !document.isRunning, !document.isNavigatingTable, !document.hasPendingBrowseChanges,
                  grid.canEdit, !grid.isPreviewing, !grid.hasInlineDraft,
                  let currentRow = grid.rows.first(where: { $0.id == rowID }), !currentRow.isDeleted,
                  ForeignKeyPickerValues.sameValues(currentRow.values, sourceValues), currentRow.original == sourceOriginal,
                  self.typeProfileRevisions[profileID] == settingsRevision,
                  self.typeServiceGenerations[profileID] == serviceGeneration,
                  self.services[profileID]?.sessionId == sessionID,
                  self.services[profileID]?.connectionState == .connected,
                  document.runtime?.sessionId == runtimeSessionID,
                  document.runtime?.connectionState == .connected,
                  let saved = self.library.savedConnections.first(where: { $0.id == profileID }),
                  (try? encoder.encode(saved)) == profileBytes else { return false }
            if fromQuery { return document.runtime?.transactionStatus == .idle && grid.querySessionID == runtimeSessionID }
            return document.table.map { ForeignKeyPickerValues.sameTable($0, grid.reference) } == true
        }
        let cancel: @MainActor () async -> Void = { [weak self] in
            guard let pending = owner.pending, !pending.finished, !pending.cancelled else { return }
            pending.cancelled = true
            pending.task?.cancel()
            if pending.submitted {
                _ = try? await self?.cancelPostgresTypeCatalogQuery(sessionID: sessionID, queryID: pending.queryID)
            }
        }
        let read: ForeignKeyPickerModel.Read = { [weak self] request in
            guard let self, current(), !Task.isCancelled else { throw ForeignKeyPickerFailure("The source row or connection changed. Open the picker again.") }
            let pending = CatalogMetadataRequest()
            owner.pending = pending
            defer { if owner.pending === pending { owner.pending = nil } }
            let response = try await withTaskCancellationHandler {
                try await self.catalog(request, profileID: profileID, connectedSessionID: sessionID, metadataRequest: pending)
            } onCancel: {
                Task { @MainActor in await cancel() }
            }
            guard current(), !pending.cancelled else { throw CancellationError() }
            return response
        }
        return .init(engine: profile.engine, profileID: profileID, sessionID: sessionID,
            serviceGeneration: serviceGeneration, settingsRevision: settingsRevision, sourceColumns: sourceColumns,
            typedSQLiteFilters: service.capabilities.contains(TableCellFilters.sqliteCapability), current: current,
            read: read, cancel: cancel, stage: { [weak grid] assignments in
                guard current(), let grid else { throw ForeignKeyPickerFailure("The source row or connection changed. Open the picker again.") }
                try grid.stageForeignKey(assignments, rowID: rowID, expectedValues: sourceValues)
            })
    }

    private func foreignKeyConnectionMatches(_ runtime: WorkspaceModel, profile: SavedConnection, bytes: Data) -> Bool {
        let settings = ConnectionSettings(host: runtime.host, port: Int(runtime.port) ?? -1, database: runtime.database,
            user: runtime.user, password: "", sslMode: runtime.sslMode,
            sslRootCert: runtime.sslRootCert.isEmpty ? nil : runtime.sslRootCert,
            engine: runtime.engine, policy: runtime.policy, contactPoints: runtime.contactPoints,
            localDatacenter: runtime.localDatacenter, consistency: runtime.consistency, ssh: runtime.ssh,
            passwordCommand: runtime.passwordCommand, mongodb: runtime.mongodb, sqlite: runtime.sqlite)
        let connected = SavedConnection(id: profile.id, name: profile.name, settings: settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(connected)) == bytes
    }
}
