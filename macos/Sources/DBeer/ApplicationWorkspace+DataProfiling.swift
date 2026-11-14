import Combine
import Foundation

/// Workspace ownership survives sheet disappearance and closes only after an
/// accepted action affecting this source document or profile.
@MainActor
struct GridProfileServerOwner {
    let documentID: UUID
    let profileID: UUID
    let model: GridProfileServerModel
    let profileObservation: AnyCancellable
}

extension ApplicationWorkspace {
    func makeGridProfileServer(document: SQLDocument, grid: GridDraft, column: ResultColumn) throws -> GridProfileServerModel {
        guard canStartOperation(document), document.grid === grid, let table = document.table,
              ForeignKeyPickerValues.sameTable(table, grid.reference),
              !document.isRunning, !document.isNavigatingTable, !document.hasPendingBrowseChanges,
              grid.pendingCount == 0, !grid.hasInlineDraft, !grid.outcomeUnknown, !grid.resultIsStale,
              let profileID = document.profileID,
              let profile = library.savedConnections.first(where: { $0.id == profileID }),
              [.postgresql, .mysql, .mariadb, .sqlite].contains(profile.engine),
              grid.columns.contains(where: { Data($0.name.utf8) == Data(column.name.utf8) }),
              let binding = SessionMonitorProfileBinding(profile) else {
            throw GridProfileFailure("Open a current PostgreSQL, MySQL, MariaDB or SQLite table view and resolve local changes before capturing a fresh sample.")
        }
        let sourceRuntime = document.runtime
        let sourceSessionID = sourceRuntime?.sessionId
        let sourcePresentation = grid.presentation
        let current: @MainActor () -> Bool = { [weak self, weak document, weak grid, weak sourceRuntime] in
            guard let self, let document, let grid, self.gridProfileBindingIsCurrent(binding),
                  self.ownedSQLContext(for: document) != nil, document.profileID == profileID,
                  document.runtime === sourceRuntime, document.runtime?.sessionId == sourceSessionID,
                  document.grid === grid, grid.presentation === sourcePresentation,
                  !grid.outcomeUnknown, !grid.resultIsStale, let actual = document.table,
                  ForeignKeyPickerValues.sameTable(actual, table) else { return false }
            return true
        }
        let lease = SessionMonitorClientLease()
        let attempt = UUID()
        let reviewID = "data-profile:" + attempt.uuidString
        let model = GridProfileServerModel(table: table, column: column, engine: profile.engine, connect: { [weak self] in
            guard let self, current() else { throw CancellationError() }
            var settings = try await self.readonlyOperationSettings(profile, attempt: attempt)
            guard current() else { throw CancellationError() }
            settings.policy.readOnly = true
            settings.sessionPurpose = nil
            let client = try await self.ensureHelper()
            lease.client = client
            try await SSHConnectionReview.prepare(settings, client: client, ownerID: attempt, reviewID: reviewID)
            try Task.checkCancellation()
            guard current() else { throw CancellationError() }
            let response = try await client.request(.connect(settings))
            guard let session = response.sessionId else { throw BackendTransportError(.invalidMessage) }
            guard current(), response.type == "connect.result", response.transactionStatus == .idle,
                  response.capabilities?.contains("serverReadOnly") == true,
                  response.capabilities?.contains("catalog") == true else {
                _ = try? await client.request(.disconnect(sessionId: session))
                throw GridProfileFailure("The helper could not establish a dedicated readonly sample connection.")
            }
            return session
        }, send: { command in
            guard let client = lease.client else { throw BackendTransportError(.notReady) }
            return try await client.request(command)
        }, isCurrent: current, canStart: { [weak self, weak document, weak grid] in
            guard let self, let document, let grid else { return false }
            return self.canStartOperation(document) && !document.isRunning && !document.isNavigatingTable &&
                !document.hasPendingBrowseChanges && grid.pendingCount == 0 && !grid.hasInlineDraft
        }, didClose: { [weak self] id in self?.gridProfileServers[id] = nil }, cancelPreparation: {
            SSHConnectionReview.cancel(ownerID: attempt)
            SSHConnectionReview.cancel(profileId: reviewID)
            SSHConnectionReview.cancel(profileId: DataComparisonCredentials.promptID(profile.id, attempt))
        })
        let observation = library.$savedConnections.dropFirst().sink { [weak self, weak model] profiles in
            guard !binding.matches(in: profiles), let model else { return }
            Task { await self?.closeGridProfileServer(id: model.id) }
        }
        gridProfileServers[model.id] = GridProfileServerOwner(documentID: document.id, profileID: profileID,
            model: model, profileObservation: observation)
        return model
    }

    func closeGridProfileServer(id: UUID) async {
        guard let owner = gridProfileServers[id] else { return }
        await owner.model.close()
    }

    func closeGridProfileServers(profileID: UUID) async {
        let owners = gridProfileServers.values.filter { $0.profileID == profileID }
        for owner in owners { await owner.model.close() }
    }

    func closeGridProfileServers(documentIDs: Set<UUID>) async {
        let owners = gridProfileServers.values.filter { documentIDs.contains($0.documentID) }
        for owner in owners { await owner.model.close() }
    }

    func closeGridProfileServers() async {
        let owners = Array(gridProfileServers.values)
        for owner in owners { await owner.model.close() }
    }
}
