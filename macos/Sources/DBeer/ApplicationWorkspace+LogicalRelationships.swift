import Foundation

@MainActor
private final class LogicalRelationshipMetadataSessions {
    var sessions: [ObjectIdentifier: String] = [:]
}

extension ApplicationWorkspace {
    func presentLogicalRelationships() {
        guard canManageWorkspace else { return }
        isLogicalRelationshipsPresented = true
        Task { await logicalRelationships.load() }
    }
    func dismissLogicalRelationships() {
        closeLogicalRelationshipEditor()
        isLogicalRelationshipsPresented = false
    }
    func closeLogicalRelationshipEditor(id: UUID? = nil) {
        guard id == nil || logicalRelationshipEditor?.id == id else { return }
        logicalRelationshipEditor?.close()
        logicalRelationshipEditor = nil
    }
    func editLogicalRelationship(_ relationship: LogicalRelationship? = nil, sourceProfileID: UUID? = nil, reference: TableReference? = nil) {
        guard canManageWorkspace else { return }
        let editorID = UUID()
        let sessions = LogicalRelationshipMetadataSessions()
        let sourceProfileID = sourceProfileID ?? selectedDocument?.profileID ?? library.selectedConnectionId
        let reference = reference ?? selectedDocument?.table
        let model = LogicalRelationshipEditorModel(id: editorID, relationship: relationship,
            sourceProfileID: sourceProfileID, reference: reference,
            profiles: { [weak self] in self?.library.savedConnections ?? [] },
            mayStart: { [weak self] in self?.canManageWorkspace == true },
            isCurrent: { [weak self] in
                guard let self else { return false }
                return self.relationshipServiceContextIsAvailable && self.logicalRelationshipEditor?.id == editorID
            }, reader: { [weak self] endpoint, pending in
                guard let self, self.logicalEditorIsCurrent(id: editorID, endpoint: endpoint), !pending.cancelled else { throw CancellationError() }
                if self.services[endpoint.profileID]?.connectionState != .connected { await self.connectProfile(endpoint.profileID) }
                guard self.logicalEditorIsCurrent(id: editorID, endpoint: endpoint), !pending.cancelled,
                      let context = self.logicalMetadataContext(endpoint) else {
                    throw LogicalRelationshipError.metadata("The selected profile could not be connected with matching settings. The local draft has been kept.")
                }
                sessions.sessions[ObjectIdentifier(pending)] = context.sessionID
                defer { sessions.sessions.removeValue(forKey: ObjectIdentifier(pending)) }
                let result = try await self.catalog(.init(kind: "columns", schema: endpoint.schema,
                    object: endpoint.name, objectKind: endpoint.kind), profileID: endpoint.profileID,
                    connectedSessionID: context.sessionID, metadataRequest: pending)
                guard self.logicalEditorIsCurrent(id: editorID, endpoint: endpoint), !pending.cancelled,
                      self.logicalMetadataContext(endpoint) == context, result.sessionId == context.sessionID,
                      result.queryId == pending.queryID else { throw CancellationError() }
                guard result.truncated != true, (result.displayNotice ?? "").isEmpty else {
                    throw LogicalRelationshipError.metadata("Column metadata is incomplete or carries a server notice. Refresh the object and resolve the notice before validating its local mapping.")
                }
                return try ERDiagramMetadata.columns(result)
            }, cancel: { [weak self] _, pending in
                guard pending.submitted, let session = sessions.sessions[ObjectIdentifier(pending)] else { return }
                Task { @MainActor [weak self] in
                    _ = try? await self?.cancelPostgresTypeCatalogQuery(sessionID: session, queryID: pending.queryID)
                }
            })
        logicalRelationshipEditor = model
        isLogicalRelationshipsPresented = true
        Task { await logicalRelationships.load() }
    }
    private func logicalEditorIsCurrent(id: UUID, endpoint: LogicalRelationshipEndpoint) -> Bool {
        relationshipServiceContextIsAvailable && logicalRelationshipEditor?.id == id &&
            library.savedConnections.contains(where: endpoint.matches)
    }
    func logicalRelationshipProfilesMatch(_ relationship: LogicalRelationship) -> Bool {
        library.savedConnections.contains(where: relationship.source.matches) &&
            library.savedConnections.contains(where: relationship.target.matches)
    }
    func logicalMetadataContext(_ endpoint: LogicalRelationshipEndpoint) -> ERDiagramLoadContext? {
        guard let profile = library.savedConnections.first(where: { $0.id == endpoint.profileID }), endpoint.matches(profile) else { return nil }
        return erConnectedProfileContext(profile.id)
    }
}
