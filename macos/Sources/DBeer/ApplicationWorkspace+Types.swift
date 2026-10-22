import Combine
import CryptoKit
import Foundation

extension ApplicationWorkspace {
    func updatePostgresTypeProfileRevisions(_ profiles: [SavedConnection]) {
        var fingerprints: [UUID: Data] = [:]
        var revisions: [UUID: UUID] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for profile in profiles {
            guard let data = try? encoder.encode(profile) else { continue }
            let fingerprint = Data(SHA256.hash(data: data))
            fingerprints[profile.id] = fingerprint
            revisions[profile.id] = typeProfileFingerprints[profile.id] == fingerprint
                ? typeProfileRevisions[profile.id] ?? UUID() : UUID()
        }
        typeProfileFingerprints = fingerprints
        typeProfileRevisions = revisions
        if let model = typeInspection, revisions[model.reference.profileID] != model.reference.settingsRevision {
            invalidatePostgresTypeModel(model, reason: "The saved connection or its policy changed. Reopen the type with the current connection.")
        }
    }

    func observePostgresTypeSession(_ service: WorkspaceModel, profileID: UUID) {
        typeServiceGenerations[profileID] = UUID()
        typeSessionObservations[profileID] = [
            service.$sessionId.dropFirst().sink { [weak self] sessionID in
                guard let self else { return }
                self.typeServiceGenerations[profileID] = UUID()
                if let model = self.typeInspection, model.reference.profileID == profileID,
                   sessionID != model.reference.serviceSessionID || self.typeServiceGenerations[profileID] != model.reference.serviceGeneration {
                    self.invalidatePostgresTypeModel(model, reason: "The service session changed. Reopen this type with the current connection.")
                }
            },
            service.$connectionState.dropFirst().sink { [weak self] state in
                guard let self, state != .connected else { return }
                self.typeServiceGenerations[profileID] = UUID()
                self.invalidatePostgresTypeInspection(profileID: profileID,
                    reason: "The service session ended. Reopen this type after connecting again.")
            }
        ]
    }

    func currentPostgresTypeCatalogOrigin(profileID: UUID) -> PostgresTypeCatalogOrigin? {
        guard canInspectPostgresTypes, postgresTypeServiceMatchesSavedProfile(profileID), services[profileID]?.connectionState == .connected,
              let sessionID = services[profileID]?.sessionId, let generation = typeServiceGenerations[profileID],
              let revision = typeProfileRevisions[profileID] else { return nil }
        return .init(serviceSessionID: sessionID, serviceGeneration: generation, settingsRevision: revision)
    }

    private func postgresTypeServiceMatchesSavedProfile(_ profileID: UUID) -> Bool {
        guard let profile = library.savedConnections.first(where: { $0.id == profileID }), profile.engine == .postgresql,
              let service = services[profileID], service.activeConnectionId == profileID else { return false }
        let settings = ConnectionSettings(host: service.host, port: Int(service.port) ?? -1, database: service.database,
            user: service.user, password: "", sslMode: service.sslMode,
            sslRootCert: service.sslRootCert.isEmpty ? nil : service.sslRootCert, engine: service.engine,
            policy: service.policy, contactPoints: service.contactPoints, localDatacenter: service.localDatacenter,
            consistency: service.consistency, ssh: service.ssh, passwordCommand: service.passwordCommand)
        // PostgreSQL identifiers and local provider/certificate paths retain
        // exact UTF-8 bytes. Swift String equality folds canonical Unicode
        // equivalents, so compare credential-free saved descriptions instead.
        let connectedProfile = SavedConnection(id: profile.id, name: profile.name, settings: settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let savedBytes = try? encoder.encode(profile), let connectedBytes = try? encoder.encode(connectedProfile) else { return false }
        return savedBytes == connectedBytes
    }

    private func postgresTypeReference(_ node: CatalogNode) -> PostgresTypeReference? {
        guard canInspectPostgresTypes, node.kind == .object,
              let profile = library.savedConnections.first(where: { $0.id == node.profileID }), profile.engine == .postgresql,
              let service = services[node.profileID], service.connectionState == .connected,
              let sessionID = service.sessionId, let generation = typeServiceGenerations[node.profileID],
              let revision = typeProfileRevisions[node.profileID], let oid = node.localOID,
              let origin = node.typeOrigin,
              origin == currentPostgresTypeCatalogOrigin(profileID: node.profileID) else { return nil }
        let reference = PostgresTypeReference(profileID: node.profileID, serviceSessionID: sessionID,
            serviceGeneration: generation, engine: profile.engine, database: profile.database,
            schema: node.schema, name: node.name, objectKind: node.objectKind, localOID: oid,
            settingsRevision: revision, policy: profile.policy)
        return reference.valid ? reference : nil
    }

    func postgresTypeReferenceIsCurrent(_ reference: PostgresTypeReference) -> Bool {
        canInspectPostgresTypes && reference.valid &&
            postgresTypeServiceMatchesSavedProfile(reference.profileID) &&
            typeProfileRevisions[reference.profileID] == reference.settingsRevision &&
            typeServiceGenerations[reference.profileID] == reference.serviceGeneration &&
            library.savedConnections.contains(where: { $0.id == reference.profileID && $0.engine == .postgresql }) &&
            services[reference.profileID]?.connectionState == .connected &&
            services[reference.profileID]?.sessionId == reference.serviceSessionID
    }

    private func postgresTypeInspectionIsCurrent(_ model: PostgresTypeInspectionModel, generation: UInt64) -> Bool {
        typeInspection === model && model.generation == generation && model.invalidationReason == nil &&
            postgresTypeReferenceIsCurrent(model.reference)
    }

    func inspectPostgresType(_ node: CatalogNode) async {
        guard let reference = postgresTypeReference(node) else {
            reportCopyError("Connect to the PostgreSQL profile and refresh the catalog before inspecting this type.")
            return
        }
        inspection = nil
        let model = PostgresTypeInspectionModel(reference: reference,
            profileName: library.savedConnections.first(where: { $0.id == node.profileID })?.name ?? "PostgreSQL",
            destination: capturePaneSelection())
        typeInspection = model
        await refreshPostgresTypeInspection()
    }

    func refreshPostgresTypeInspection() async {
        guard let model = typeInspection else { return }
        guard postgresTypeReferenceIsCurrent(model.reference) else {
            invalidatePostgresTypeModel(model, reason: "The inspection context changed. Reopen the type with the current connection.")
            return
        }
        cancelPostgresTypeRequest(model)
        let generation = model.advanceGeneration()
        let reference = model.reference
        model.invalidationReason = nil
        model.details = nil
        model.enumValues = nil
        model.dependencies = nil
        model.enumValuesComplete = false
        model.dependenciesComplete = false
        model.metadataError = nil
        model.enumValuesError = nil
        model.dependenciesError = nil
        model.cancellationNotice = nil
        model.isLoading = true
        defer {
            if postgresTypeInspectionIsCurrent(model, generation: generation) { model.isLoading = false }
        }
        do {
            let reply = try await postgresTypeCatalog(reference.request("typeDetails"), model: model)
            guard postgresTypeInspectionIsCurrent(model, generation: generation), !Task.isCancelled else { return }
            model.details = try PostgresTypeCatalog.decodeDetails(reply, reference: reference)
        } catch {
            guard postgresTypeInspectionIsCurrent(model, generation: generation), !Task.isCancelled else { return }
            model.metadataError = safePostgresTypeError(error)
            return
        }
        if reference.objectKind == "enum" {
            do {
                let reply = try await postgresTypeCatalog(reference.request("enumValues"), model: model)
                guard postgresTypeInspectionIsCurrent(model, generation: generation), !Task.isCancelled else { return }
                model.enumValues = try PostgresTypeCatalog.decodeEnumValues(reply)
                model.enumValuesComplete = reply.truncated == false
            } catch {
                guard postgresTypeInspectionIsCurrent(model, generation: generation), !Task.isCancelled else { return }
                model.enumValuesError = safePostgresTypeError(error)
            }
        }
        guard postgresTypeInspectionIsCurrent(model, generation: generation), !Task.isCancelled else { return }
        do {
            let reply = try await postgresTypeCatalog(reference.request("typeDependencies"), model: model)
            guard postgresTypeInspectionIsCurrent(model, generation: generation), !Task.isCancelled else { return }
            model.dependencies = try PostgresTypeCatalog.decodeDependencies(reply)
            model.dependenciesComplete = reply.truncated == false
        } catch {
            guard postgresTypeInspectionIsCurrent(model, generation: generation), !Task.isCancelled else { return }
            model.dependenciesError = safePostgresTypeError(error)
        }
    }

    func previewPostgresTypeChange(_ change: TypeChange) async {
        guard let model = typeInspection, !model.isLoading, let details = model.details,
              postgresTypeReferenceIsCurrent(model.reference), model.invalidationReason == nil else { return }
        cancelPostgresTypeRequest(model)
        let generation = model.advanceGeneration()
        let reference = model.reference
        let destination = model.destination
        model.cancellationNotice = nil
        defer {
            if typeInspection === model, model.generation == generation { model.isPreparingPreview = false }
        }
        do {
            try PostgresTypeCatalog.validateChange(change, details: details, values: model.enumValues,
                                                  valuesComplete: model.enumValuesComplete)
            model.isPreparingPreview = true
            let reply = try await postgresTypeCatalog(reference.request("typeDDL", change: change), model: model)
            guard postgresTypeInspectionIsCurrent(model, generation: generation), !Task.isCancelled,
                  model.destination.pane == destination.pane else { return }
            model.preview = try PostgresTypeCatalog.decodePreview(reply, change: change)
            model.isPreparingPreview = false
        } catch {
            guard postgresTypeInspectionIsCurrent(model, generation: generation), !Task.isCancelled else { return }
            model.previewError = safePostgresTypeError(error)
            model.isPreparingPreview = false
        }
    }

    func discardPostgresTypePreview() {
        guard let model = typeInspection, model.preview != nil || model.isPreparingPreview || model.previewError != nil else { return }
        cancelPostgresTypeRequest(model)
        model.advanceGeneration()
        model.cancellationNotice = nil
    }

    func stopPostgresTypeInspection() {
        guard let model = typeInspection else { return }
        model.advanceGeneration()
        model.isLoading = false
        cancelPostgresTypeRequest(model)
    }

    func dismissPostgresTypeInspection() { typeInspection = nil }

    func invalidatePostgresTypeInspection(profileID: UUID? = nil, reason: String) {
        guard let model = typeInspection, profileID == nil || model.reference.profileID == profileID else { return }
        invalidatePostgresTypeModel(model, reason: reason)
    }

    func invalidatePostgresTypeModel(_ model: PostgresTypeInspectionModel, reason: String) {
        model.advanceGeneration()
        model.isLoading = false
        model.invalidationReason = reason
        cancelPostgresTypeRequest(model)
    }

    @discardableResult
    func openPostgresTypeSQLDraft() -> SQLDocument? {
        guard let model = typeInspection, model.canOpenSQLDraft,
              postgresTypeReferenceIsCurrent(model.reference), let preview = model.preview else { return nil }
        let document = SQLDocument(title: "SQL for " + model.reference.name, text: preview.sql,
                                   profileID: model.reference.profileID)
        document.historyConnectionNotice = "Generated type SQL uses qualified names. Review it and use Run for the normal policy check; refresh type metadata after execution."
        return addDocument(document, context: model.destination)
    }

    func generatedPostgresTypeName(_ node: CatalogNode) async -> String? {
        guard let reference = postgresTypeReference(node) else {
            reportCopyError("Connect to the PostgreSQL profile and refresh the catalog before copying this type name.")
            return nil
        }
        do {
            let reply = try await catalog(reference.request("name"), profileID: reference.profileID,
                                          connectedSessionID: reference.serviceSessionID)
            guard postgresTypeReferenceIsCurrent(reference), !Task.isCancelled else { return nil }
            let rows = try PostgresTypeCatalog.fixedRows(reply, columns: ["name"], requireComplete: true)
            guard rows.count == 1, let name = rows[0][0], !name.isEmpty else { throw PostgresTypeCatalogFailure.malformed }
            return name
        } catch {
            guard postgresTypeReferenceIsCurrent(reference), !Task.isCancelled else { return nil }
            reportCopyError(safePostgresTypeError(error))
            return nil
        }
    }

    private func postgresTypeCatalog(_ request: CatalogRequest, model: PostgresTypeInspectionModel) async throws -> BackendMessage {
        let pending = PostgresTypeCatalogRequest()
        model.activeRequest = pending
        defer { if model.activeRequest === pending { model.activeRequest = nil } }
        return try await withTaskCancellationHandler {
            let reply = try await catalog(request, profileID: model.reference.profileID,
                connectedSessionID: model.reference.serviceSessionID, typeRequest: pending)
            guard reply.sessionId == model.reference.serviceSessionID, reply.queryId == pending.queryID else {
                throw PostgresTypeCatalogFailure.malformed
            }
            return reply
        } onCancel: {
            Task { @MainActor [weak self, weak model] in
                guard let self, let model, model.activeRequest === pending else { return }
                model.advanceGeneration()
                model.isLoading = false
                self.stopPostgresTypeInspectionRequest(model, request: pending)
            }
        }
    }

    private func cancelPostgresTypeRequest(_ model: PostgresTypeInspectionModel) {
        guard let request = model.activeRequest else { return }
        stopPostgresTypeInspectionRequest(model, request: request)
    }

    private func stopPostgresTypeInspectionRequest(_ model: PostgresTypeInspectionModel, request: PostgresTypeCatalogRequest) {
        guard !request.cancelled else { return }
        request.cancelled = true
        request.task?.cancel()
        guard request.submitted else {
            model.cancellationNotice = "The queued request was stopped before submission."
            return
        }
        model.cancellationNotice = "Cancellation requested. Waiting for the helper to confirm."
        let generation = model.generation
        let reference = model.reference
        Task { @MainActor [weak self, weak model] in
            guard let self else { return }
            do {
                let reply = try await self.cancelPostgresTypeCatalogQuery(sessionID: reference.serviceSessionID, queryID: request.queryID)
                guard let model, self.typeInspection === model, model.generation == generation,
                      self.postgresTypeReferenceIsCurrent(reference) else { return }
                guard reply.type == "cancel.ack", reply.sessionId == reference.serviceSessionID,
                      reply.queryId == request.queryID else { throw PostgresTypeCatalogFailure.malformed }
                model.cancellationNotice = reply.status == "accepted"
                    ? "The helper accepted cancellation of the catalog request."
                    : "The catalog request had already finished."
            } catch {
                guard let model, self.typeInspection === model, model.generation == generation,
                      self.postgresTypeReferenceIsCurrent(reference) else { return }
                model.cancellationNotice = "Cancellation could not be confirmed. Wait for the request to finish or disconnect the profile."
            }
        }
    }

    private func safePostgresTypeError(_ error: Error) -> String {
        if let failure = error as? PostgresTypeCatalogFailure { return failure.message }
        if error is CancellationError { return "Type inspection was stopped." }
        return "Type metadata or SQL preview is unavailable. Refresh the catalog and check type access permissions."
    }
}
