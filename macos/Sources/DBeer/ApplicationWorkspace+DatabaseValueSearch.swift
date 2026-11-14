import Combine
import Foundation

extension ApplicationWorkspace {
    func makeDatabaseValueSearch(_ profile: SavedConnection) -> DatabaseValueSearchModel? {
        guard canManageWorkspace, databaseSearchModel == nil || databaseSearchModel?.isClosing == true,
              let binding = SessionMonitorProfileBinding(profile) else { return nil }
        let lease = SessionMonitorClientLease()
        let attempt = UUID()
        let reviewID = "data-search:" + attempt.uuidString
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.databaseSearchBindingIsCurrent(binding)
        }
        let model = DatabaseValueSearchModel(profile: profile, connect: { [weak self] in
            guard let self, current() else { throw CancellationError() }
            var settings = try await self.readonlyOperationSettings(profile, attempt: attempt)
            guard current() else { throw CancellationError() }
            settings.policy.readOnly = true
            settings.sessionPurpose = nil
            let client = try await self.ensureHelper()
            lease.client = client
            try await SSHConnectionReview.prepare(settings, client: client, ownerID: attempt, reviewID: reviewID)
            guard current() else { throw CancellationError() }
            let reply = try await client.request(.connect(settings))
            guard let session = reply.sessionId else { throw BackendTransportError(.invalidMessage) }
            guard current(), reply.capabilities?.contains("catalog") == true,
                  reply.capabilities?.contains("serverReadOnly") == true else {
                _ = try? await client.request(.disconnect(sessionId: session))
                throw DatabaseSearchFailure("A dedicated server-readonly catalog connection is required for this search.")
            }
            return (session, reply.capabilities ?? [])
        }, send: { command in
            guard let client = lease.client else { throw BackendTransportError(.notReady) }
            return try await client.request(command)
        }, isCurrent: current, canStart: { [weak self] in self?.canManageWorkspace == true }, cancelPreparation: {
            SSHConnectionReview.cancel(ownerID: attempt)
            SSHConnectionReview.cancel(profileId: reviewID)
            SSHConnectionReview.cancel(profileId: DataComparisonCredentials.promptID(profile.id, attempt))
        }, open: { [weak self] observation in
            guard let self, self.canManageWorkspace, current(), observation.hasMatches, let predicate = observation.predicate else { return }
            let document = SQLDocument(title: observation.table.name, text: "Table data", profileID: profile.id)
            document.table = observation.table.reference
            document.tableFilterExpression = predicate
            document.tableNeedsExplicitLoad = true
            self.addDocument(document)
            await self.run(document)
        })
        databaseSearchModel = model
        databaseSearchProfileObservation = library.$savedConnections.dropFirst().sink { [weak self, weak model] profiles in
            guard !binding.matches(in: profiles), let model else { return }
            Task { await self?.closeDatabaseValueSearch(expectedID: model.id) }
        }
        return model
    }

    func showDatabaseValueSearch(_ profile: SavedConnection) {
        guard canManageWorkspace else { return }
        let intent = databaseSearchPresentation.requestOpen()
        databaseSearchRequestedProfileID = profile.id
        Task { [weak self] in
            guard let self, self.databaseSearchPresentation.isCurrent(intent), self.canManageWorkspace else { return }
            defer {
                if self.databaseSearchPresentation.isCurrent(intent) { self.databaseSearchRequestedProfileID = nil }
            }
            if let existing = self.databaseSearchWindow {
                if SessionMonitorProfileBinding(existing.model.profile)?.matches(profile) == true, !existing.model.isClosing {
                    existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return
                }
                await self.closeDatabaseValueSearch(expectedID: existing.model.id)
            }
            if let existing = self.databaseSearchModel { await self.closeDatabaseValueSearch(expectedID: existing.id) }
            guard self.databaseSearchPresentation.isCurrent(intent), self.canManageWorkspace,
                  let binding = SessionMonitorProfileBinding(profile), binding.matches(in: self.library.savedConnections),
                  let model = self.makeDatabaseValueSearch(profile) else { return }
            let controller = DatabaseValueSearchWindowController(model: model, appearance: self.appearance, requestClose: { [weak self] in
                Task { await self?.closeDatabaseValueSearch(expectedID: model.id) }
            })
            self.databaseSearchWindow = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        }
    }

    func closeDatabaseValueSearch(expectedID: UUID? = nil) async {
        if expectedID == nil { databaseSearchPresentation.cancelPendingOpen(); databaseSearchRequestedProfileID = nil }
        guard let model = databaseSearchModel,
              SessionMonitorPresentationIntent.mayClose(expectedID: expectedID, activeID: model.id) else { return }
        await model.close()
        guard databaseSearchModel === model else { return }
        if let controller = databaseSearchWindow, controller.model === model {
            controller.finishClosing(); databaseSearchWindow = nil
        }
        databaseSearchModel = nil; databaseSearchProfileObservation = nil
    }

    func closeDatabaseValueSearch(profileID: UUID) async {
        if databaseSearchRequestedProfileID == profileID {
            databaseSearchPresentation.cancelPendingOpen(); databaseSearchRequestedProfileID = nil
        }
        guard let model = databaseSearchModel, model.profile.id == profileID else { return }
        await closeDatabaseValueSearch(expectedID: model.id)
    }
}
