import Combine
import Foundation
import Testing
@testable import DBeer

/// In-memory models and protocol subprocesses only. No windows, controls,
/// desktop interaction, clipboard access or application activation.
@MainActor
struct WorkspaceNotificationTests {
    @Test func postingAnErrorShowsTheSameEntryAsTheFooterCounter() throws {
        let notifications = WorkspaceNotifications()
        #expect(WorkspaceNotifications.toastDuration == .seconds(5))
        #expect(notifications.activeToasts.isEmpty)
        notifications.post("Connection failed.\nTry again.", source: "Connections")
        let entry = try #require(notifications.entries.first)
        #expect(notifications.activeToasts.map(\.id) == [entry.id])
        #expect(notifications.activeToasts.first?.message == entry.message)
        #expect(notifications.activeToasts.first?.source == "Connections")
        #expect(notifications.entries.count == 1 && notifications.unreadCount == 1)
        notifications.post(" \n\t ")
        #expect(notifications.activeToasts.map(\.id) == [entry.id])
        #expect(notifications.entries.count == 1 && notifications.unreadCount == 1)
    }

    @Test func toastStackKeepsTheNewestFiveAndRetainsEveryErrorInHistory() throws {
        let notifications = WorkspaceNotifications()
        #expect(WorkspaceNotifications.maximumToastCount == 5)
        for index in 0..<8 { notifications.post("Failure \(index)") }
        #expect(notifications.activeToasts.map(\.message) == ["Failure 7", "Failure 6", "Failure 5", "Failure 4", "Failure 3"])
        #expect(notifications.entries.map(\.message) == (0..<8).reversed().map { "Failure \($0)" })
        #expect(notifications.unreadCount == 8)
        let evictedID = try #require(notifications.entries.last?.id)
        notifications.dismissToast(evictedID)
        #expect(notifications.activeToasts.count == 5)
        let visibleIDs = notifications.activeToasts.map(\.id)
        notifications.dismissToast(visibleIDs[2])
        #expect(notifications.activeToasts.map(\.id) == [visibleIDs[0], visibleIDs[1], visibleIDs[3], visibleIDs[4]])
        #expect(notifications.entries.count == 8 && notifications.unreadCount == 8)
        for id in visibleIDs { notifications.dismissToast(id) }
        #expect(notifications.activeToasts.isEmpty)
        #expect(notifications.entries.count == 8 && notifications.unreadCount == 8)
    }

    @Test func hidingAMiddleToastPreservesItsNeighborsAndUnreadHistory() throws {
        let notifications = WorkspaceNotifications()
        notifications.post("First failure")
        notifications.post("Second failure")
        notifications.post("Third failure")
        let ids = notifications.activeToasts.map(\.id)
        try #require(ids.count == 3)
        notifications.dismissToast(ids[1])
        #expect(notifications.activeToasts.map(\.id) == [ids[0], ids[2]])
        #expect(notifications.entries.map(\.id) == ids)
        #expect(notifications.unreadCount == 3)
        notifications.markAllRead()
        #expect(notifications.activeToasts.map(\.id) == [ids[0], ids[2]])
        notifications.dismiss(ids[2])
        #expect(notifications.activeToasts.map(\.id) == [ids[0]])
        #expect(notifications.entries.map(\.id) == [ids[0], ids[1]])
        #expect(notifications.unreadCount == 0)
        notifications.dismissToast(ids[0])
        notifications.dismissToast(ids[1])
        #expect(notifications.activeToasts.isEmpty)
    }

    @Test func toastExpiryPreservesTheUnreadErrorInHistory() async throws {
        let notifications = WorkspaceNotifications(toastDuration: .milliseconds(30))
        notifications.post("Export failed", source: "Workspace")
        let entry = try #require(notifications.activeToasts.first)
        try await waitForToastExpiry(notifications)
        #expect(notifications.entries.map(\.id) == [entry.id])
        #expect(notifications.entries.first?.message == "Export failed")
        #expect(notifications.unreadCount == 1)
        notifications.markAllRead()
        #expect(notifications.activeToasts.isEmpty && notifications.unreadCount == 0)
    }

    @Test func toastProgressDecreasesWithTimeAndStaysWithinItsBounds() throws {
        let notifications = WorkspaceNotifications(toastDuration: .seconds(10))
        notifications.post("Failure with progress")
        let id = try #require(notifications.activeToasts.first?.id)
        let sampledAt = ContinuousClock.now
        let initialFraction = notifications.toastRemainingFraction(id, at: sampledAt)
        let laterFraction = notifications.toastRemainingFraction(id, at: sampledAt.advanced(by: .seconds(2)))
        #expect(initialFraction > 0 && initialFraction <= 1)
        #expect(laterFraction < initialFraction)
        #expect(abs((initialFraction - laterFraction) - 0.2) < 0.001)
        #expect(notifications.toastRemainingFraction(id, at: sampledAt.advanced(by: .seconds(-20))) == 1)
        #expect(notifications.toastRemainingFraction(id, at: sampledAt.advanced(by: .seconds(20))) == 0)
        #expect(!notifications.isToastPaused(id))
    }

    @Test func toastProgressIsFiniteAndEmptyForNonpositiveLifetimes() throws {
        for duration in [Duration.zero, .milliseconds(-1)] {
            let notifications = WorkspaceNotifications(toastDuration: duration)
            notifications.post("Immediately expired failure")
            let id = try #require(notifications.activeToasts.first?.id)
            let fraction = notifications.toastRemainingFraction(id)
            #expect(fraction.isFinite && fraction == 0)
        }
    }

    @Test func eachToastExpiresIndependentlyWithoutResettingOlderTimers() async throws {
        let notifications = WorkspaceNotifications(toastDuration: .milliseconds(600))
        notifications.post("First failure")
        let firstID = try #require(notifications.activeToasts.first?.id)
        try await Task.sleep(for: .milliseconds(400))
        notifications.post("Second failure")
        let secondID = try #require(notifications.activeToasts.first?.id)
        #expect(notifications.activeToasts.map(\.id) == [secondID, firstID])
        notifications.markAllRead()
        notifications.post(" \n\t ")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while notifications.activeToasts.contains(where: { $0.id == firstID }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(notifications.activeToasts.map(\.id) == [secondID])
        notifications.dismissToast(firstID)
        #expect(notifications.activeToasts.map(\.id) == [secondID])
        #expect(notifications.entries.map(\.id) == [secondID, firstID])
        #expect(notifications.unreadCount == 0)
        try await waitForToastExpiry(notifications)
        #expect(notifications.entries.map(\.id) == [secondID, firstID])
    }

    @Test func clearingHistoryCancelsAllToastsWithoutHidingLaterErrors() async throws {
        let notifications = WorkspaceNotifications(toastDuration: .milliseconds(600))
        notifications.post("First before clear")
        notifications.post("Second before clear")
        try await Task.sleep(for: .milliseconds(400))
        notifications.clear()
        #expect(notifications.activeToasts.isEmpty)
        #expect(notifications.entries.isEmpty && notifications.unreadCount == 0)
        notifications.post("First after clear")
        notifications.post("Second after clear")
        let ids = notifications.activeToasts.map(\.id)
        try #require(ids.count == 2)
        try await Task.sleep(for: .milliseconds(300))
        #expect(notifications.activeToasts.map(\.id) == ids)
        #expect(notifications.entries.map(\.id) == ids && notifications.unreadCount == 2)
        notifications.dismiss(ids[0])
        #expect(notifications.activeToasts.map(\.id) == [ids[1]])
        notifications.dismiss(ids[1])
        #expect(notifications.activeToasts.isEmpty)
        #expect(notifications.entries.isEmpty && notifications.unreadCount == 0)
    }

    @Test func hoveringPausesOnlyThatToastAndResumesItsRemainingTimeAcrossCycles() async throws {
        let notifications = WorkspaceNotifications(toastDuration: .milliseconds(1_200))
        let source = UUID()
        notifications.post("Hovered failure")
        let hoveredID = try #require(notifications.activeToasts.first?.id)
        notifications.post("Neighbor failure")
        let neighborID = try #require(notifications.activeToasts.first?.id)
        try await Task.sleep(for: .milliseconds(400))
        notifications.pauseToast(hoveredID, source: source)
        let firstPausedFraction = notifications.toastRemainingFraction(hoveredID)
        #expect(notifications.isToastPaused(hoveredID))
        try await Task.sleep(for: .milliseconds(900))
        let neighborDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while notifications.activeToasts.contains(where: { $0.id == neighborID }), ContinuousClock.now < neighborDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(notifications.activeToasts.map(\.id) == [hoveredID])
        #expect(notifications.entries.count == 2 && notifications.unreadCount == 2)
        #expect(notifications.toastRemainingFraction(hoveredID) == firstPausedFraction)

        notifications.resumeToast(hoveredID, source: source)
        #expect(!notifications.isToastPaused(hoveredID))
        #expect(notifications.toastRemainingFraction(hoveredID) <= firstPausedFraction)
        try await Task.sleep(for: .milliseconds(400))
        notifications.pauseToast(hoveredID, source: source)
        let secondPausedFraction = notifications.toastRemainingFraction(hoveredID)
        #expect(secondPausedFraction < firstPausedFraction)
        try await Task.sleep(for: .milliseconds(100))
        #expect(notifications.activeToasts.map(\.id) == [hoveredID])
        #expect(notifications.toastRemainingFraction(hoveredID) == secondPausedFraction)
        notifications.resumeToast(hoveredID, source: source)
        #expect(notifications.toastRemainingFraction(hoveredID) <= secondPausedFraction)
        try await Task.sleep(for: .milliseconds(100))
        #expect(notifications.activeToasts.map(\.id) == [hoveredID])
        notifications.resumeToast(hoveredID, source: source)
        try await waitForToastExpiry(notifications, timeout: .milliseconds(600))
        #expect(notifications.entries.count == 2 && notifications.unreadCount == 2)
    }

    @Test func allHoverSourcesMustLeaveBeforeTheCountdownResumes() async throws {
        let notifications = WorkspaceNotifications(toastDuration: .milliseconds(200))
        let firstSource = UUID(), secondSource = UUID()
        notifications.post("Shared notification")
        let id = try #require(notifications.activeToasts.first?.id)
        notifications.pauseToast(id, source: firstSource)
        notifications.pauseToast(id, source: firstSource)
        notifications.pauseToast(id, source: secondSource)
        notifications.pauseToast(id, source: secondSource)
        let pausedFraction = notifications.toastRemainingFraction(id)
        #expect(notifications.isToastPaused(id))
        #expect(notifications.toastRemainingFraction(id, at: ContinuousClock.now.advanced(by: .seconds(60))) == pausedFraction)
        try await Task.sleep(for: .milliseconds(300))
        #expect(notifications.activeToasts.map(\.id) == [id])
        notifications.resumeToast(id, source: firstSource)
        notifications.resumeToast(id, source: firstSource)
        notifications.resumeToast(id, source: UUID())
        try await Task.sleep(for: .milliseconds(300))
        #expect(notifications.activeToasts.map(\.id) == [id])
        #expect(notifications.isToastPaused(id))
        #expect(notifications.toastRemainingFraction(id) == pausedFraction)
        notifications.resumeToast(id, source: secondSource)
        #expect(!notifications.isToastPaused(id))
        #expect(notifications.toastRemainingFraction(id) <= pausedFraction)
        try await waitForToastExpiry(notifications)
        #expect(notifications.entries.map(\.id) == [id] && notifications.unreadCount == 1)
    }

    @Test func hoverPublishesOnlyChangesBetweenRunningAndPausedCountdowns() throws {
        let notifications = WorkspaceNotifications()
        notifications.post("Observed notification")
        let id = try #require(notifications.activeToasts.first?.id)
        let firstSource = UUID(), secondSource = UUID()
        var updates = 0
        let observation = notifications.objectWillChange.sink { updates += 1 }
        defer { observation.cancel() }

        notifications.pauseToast(id, source: firstSource)
        #expect(updates == 1 && notifications.isToastPaused(id))
        notifications.pauseToast(id, source: firstSource)
        notifications.pauseToast(id, source: secondSource)
        notifications.pauseToast(UUID(), source: firstSource)
        notifications.resumeToast(id, source: UUID())
        notifications.resumeToast(id, source: firstSource)
        notifications.resumeToast(id, source: firstSource)
        #expect(updates == 1 && notifications.isToastPaused(id))

        notifications.resumeToast(id, source: secondSource)
        #expect(updates == 2 && !notifications.isToastPaused(id))
        notifications.resumeToast(id, source: secondSource)
        notifications.resumeToast(id, source: UUID())
        notifications.resumeToast(UUID(), source: firstSource)
        #expect(updates == 2 && !notifications.isToastPaused(id))
    }

    @Test func staleHoverCallbacksDoNotRestoreDismissedClearedOrEvictedToasts() throws {
        let notifications = WorkspaceNotifications()
        let source = UUID()
        notifications.post("Dismissed toast")
        let dismissedID = try #require(notifications.activeToasts.first?.id)
        notifications.pauseToast(dismissedID, source: source)
        notifications.dismissToast(dismissedID)
        notifications.resumeToast(dismissedID, source: source)
        #expect(notifications.activeToasts.isEmpty)
        #expect(notifications.entries.map(\.id) == [dismissedID] && notifications.unreadCount == 1)

        notifications.post("Dismissed history entry")
        let historyID = try #require(notifications.activeToasts.first?.id)
        notifications.pauseToast(historyID, source: source)
        notifications.dismiss(historyID)
        notifications.resumeToast(historyID, source: source)
        #expect(notifications.activeToasts.isEmpty)
        #expect(notifications.entries.map(\.id) == [dismissedID])

        notifications.post("Cleared toast")
        let clearedID = try #require(notifications.activeToasts.first?.id)
        notifications.pauseToast(clearedID, source: source)
        notifications.clear()
        notifications.resumeToast(clearedID, source: source)
        notifications.pauseToast(clearedID, source: source)
        #expect(notifications.activeToasts.isEmpty)
        #expect(notifications.entries.isEmpty && notifications.unreadCount == 0)

        notifications.post("Evicted toast")
        let evictedID = try #require(notifications.activeToasts.first?.id)
        notifications.pauseToast(evictedID, source: source)
        for index in 0..<WorkspaceNotifications.maximumToastCount { notifications.post("New failure \(index)") }
        let visibleIDs = notifications.activeToasts.map(\.id)
        #expect(visibleIDs.count == 5 && !visibleIDs.contains(evictedID))
        notifications.resumeToast(evictedID, source: source)
        notifications.pauseToast(evictedID, source: source)
        notifications.resumeToast(UUID(), source: source)
        #expect(notifications.activeToasts.map(\.id) == visibleIDs)
        #expect(notifications.entries.count == 6 && notifications.unreadCount == 6)
        for id in [dismissedID, historyID, clearedID, evictedID, UUID()] {
            #expect(notifications.toastRemainingFraction(id) == 0)
            #expect(notifications.isToastPaused(id))
        }
    }

    private func waitForToastExpiry(_ notifications: WorkspaceNotifications, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !notifications.activeToasts.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(notifications.activeToasts.isEmpty)
    }

    @Test func messagesKeepTheirExactTextAndNewestFirstOrder() {
        let notifications = WorkspaceNotifications()
        notifications.post("First failure")
        notifications.post("Connection failed.\nПроверьте подключение 🐋", source: "Connections")
        notifications.post(" \n\t ")
        #expect(notifications.entries.map(\.message) == ["Connection failed.\nПроверьте подключение 🐋", "First failure"])
        #expect(notifications.entries.map(\.source) == ["Connections", "Workspace"])
        #expect(notifications.unreadCount == 2)
    }

    @Test func readingAndDismissingDoNotEraseOtherMessagesOrFutureUnreadState() throws {
        let notifications = WorkspaceNotifications()
        notifications.post("First")
        let firstID = try #require(notifications.entries.first?.id)
        notifications.post("Second")
        notifications.markAllRead()
        #expect(notifications.unreadCount == 0 && notifications.entries.count == 2)
        notifications.post("Second")
        #expect(notifications.unreadCount == 1 && notifications.entries.count == 3)
        #expect(notifications.entries[0].id != notifications.entries[1].id)
        notifications.dismiss(firstID)
        #expect(notifications.entries.map(\.message) == ["Second", "Second"])
        #expect(notifications.unreadCount == 1)
        notifications.dismiss(notifications.entries[0].id)
        #expect(notifications.unreadCount == 0 && notifications.entries.count == 1)
        notifications.clear()
        notifications.post("After clear")
        #expect(notifications.entries.map(\.message) == ["After clear"] && notifications.unreadCount == 1)
    }

    @Test func retentionEvictsTheOldestMessagesAndKeepsUnreadCountAccurate() {
        let notifications = WorkspaceNotifications()
        for index in 0..<WorkspaceNotifications.maximumCount { notifications.post("Failure \(index)") }
        notifications.markAllRead()
        for index in 0..<5 { notifications.post("New failure \(index)") }
        #expect(notifications.entries.count == WorkspaceNotifications.maximumCount)
        #expect(notifications.entries.first?.message == "New failure 4")
        #expect(notifications.entries.last?.message == "Failure 5")
        #expect(notifications.unreadCount == 5)
    }

    @Test func workspaceErrorsSurviveTabSelectionAndClosingTheLastTab() async {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: { _ in .discard })
        let first = workspace.newDocument()
        workspace.reportCopyError("Copy failed")
        let second = workspace.newDocument()
        workspace.reportCopyError("Export failed")
        workspace.selectedDocumentID = first.id
        await workspace.closeDocument(first)
        await workspace.closeDocument(second)
        #expect(workspace.selectedDocument == nil)
        #expect(workspace.notifications.entries.map(\.message) == ["Export failed", "Copy failed"])
        workspace.notifications.clear()
        workspace.newDocument()
        #expect(workspace.notifications.entries.isEmpty)
    }

    @Test func connectionLibraryErrorsAreRetainedAfterASuccessfulRetry() async throws {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "test",
            user: "tester", password: "fixture-secret", sslMode: "disable", sslRootCert: nil)
        #expect(await !workspace.library.saveConnection(name: "", settings: settings))
        let entry = try #require(workspace.notifications.entries.first)
        #expect(entry.message == workspace.library.connectionsError && entry.source == "Connections")
        #expect(entry.connection == nil)
        #expect(!entry.message.contains(settings.password))
        #expect(await workspace.library.saveConnection(name: "Test", settings: settings))
        #expect(workspace.library.connectionsError == nil)
        #expect(workspace.notifications.entries.map(\.id) == [entry.id])
    }

    @Test func failedProfileConnectionAddsOneNotification() async throws {
        let message = "The Cassandra request failed. Check cluster connectivity and node discovery."
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        for line in sys.stdin:
            command = json.loads(line)
            reply = {'requestId': command['requestId']}
            if command['type'] == 'hello':
                reply.update(type='hello.ack', protocolVersion=5)
            elif command['type'] == 'connect':
                reply.update(type='error', category='connection', message='\(message)', connected=False, outcomeUnknown=False)
            elif command['type'] == 'shutdown':
                reply.update(type='shutdown.ack')
            print(json.dumps(reply), flush=True)
            if command['type'] == 'shutdown':
                break
        """])
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), helperFactory: { client })
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "test",
            user: "tester", password: "", sslMode: "disable", sslRootCert: nil)
        try #require(await workspace.library.saveConnection(name: "Test", settings: settings))
        let profileID = try #require(workspace.library.selectedConnectionId)
        try #require(await workspace.library.saveConnection(name: "Other profile", settings: settings))
        let otherID = try #require(workspace.library.selectedConnectionId)
        workspace.newDocument(profileID: otherID)
        await workspace.connectProfile(profileID)
        #expect(workspace.services[profileID]?.connectionState == .disconnected)
        #expect(workspace.notifications.entries.map(\.message) == [message])
        #expect(workspace.notifications.entries.first?.connection?.id == profileID)
        #expect(workspace.notifications.entries.first?.connection?.name == "Test")
        #expect(workspace.library.selectedConnectionId == otherID && workspace.selectedDocument?.profileID == otherID)
        #expect(workspace.notifications.unreadCount == 1)
        await workspace.connectProfile(otherID)
        #expect(workspace.notifications.entries.compactMap { $0.connection?.id } == [otherID, profileID])
        #expect(workspace.notifications.entries.compactMap { $0.connection?.name } == ["Other profile", "Test"])
        await workspace.shutdown()
    }

    @Test func connectionLibraryErrorsUseTheEditedProfileAndGeneralErrorsDoNotInheritIt() async throws {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "test",
            user: "tester", password: "", sslMode: "disable")
        try #require(await workspace.library.saveConnection(name: "Original profile", settings: settings))
        let originalID = try #require(workspace.library.selectedConnectionId)
        try #require(await workspace.library.saveConnection(name: "Selected profile", settings: settings))
        let selectedID = try #require(workspace.library.selectedConnectionId)
        #expect(await !workspace.library.saveConnection(name: "", settings: settings, id: originalID))
        let notification = try #require(workspace.notifications.entries.first)
        #expect(notification.connection?.id == originalID && notification.connection?.name == "Original profile")
        #expect(workspace.library.selectedConnectionId == selectedID)
        #expect(await !workspace.library.saveConnection(name: "", settings: settings))
        workspace.reportCopyError("Unrelated workspace error")
        #expect(workspace.notifications.entries[0].connection == nil)
        #expect(workspace.notifications.entries[1].connection == nil)
        #expect(workspace.notifications.entries[2].connection?.id == originalID)
    }

    @Test func editingUsesTheProfileIdentityAfterRenameAndDoesNotRedirectDeletedProfiles() async throws {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "test",
            user: "tester", password: "", sslMode: "disable")
        try #require(await workspace.library.saveConnection(name: "Same name", settings: settings))
        let original = try #require(workspace.library.savedConnections.first)
        workspace.notifications.post("Connection failed", connection: .init(original))
        try #require(await workspace.library.saveConnection(name: "Same name", settings: settings))
        let otherID = try #require(workspace.library.selectedConnectionId)
        try #require(await workspace.library.saveConnection(name: "Renamed profile", settings: settings, id: original.id))
        let connection = try #require(workspace.notifications.entries.first?.connection)
        let edited = try #require(await workspace.prepareConnectionEditor(connection.id))
        #expect(edited.id == original.id && edited.name == "Renamed profile" && edited.id != otherID)
        #expect(connection.name == "Same name")
        try #require(await workspace.library.deleteConnection(original.id))
        #expect(await workspace.prepareConnectionEditor(connection.id) == nil)
        #expect(workspace.notifications.entries.first?.connection == connection)
        #expect(workspace.library.savedConnections.map(\.id) == [otherID])
    }

    @Test func editingAProfileRespectsCancellationForPendingChanges() async throws {
        var decision: WorkspaceCloseDecision = .cancel
        var issues: [WorkspaceCloseIssue] = []
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: { issues.append($0); return decision })
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "test",
            user: "tester", password: "", sslMode: "disable")
        try #require(await workspace.library.saveConnection(name: "Profile with edits", settings: settings))
        let profileID = try #require(workspace.library.selectedConnectionId)
        let document = workspace.newDocument(profileID: profileID)
        let table = TableReference(schema: "public", name: "items", kind: "table")
        document.table = table
        let result = BackendMessage(type: "query.result", requestId: "fixture",
            columns: [ResultColumn(index: 0, name: "id", typeOid: 23, nativeType: "int4"),
                ResultColumn(index: 1, name: "label", typeOid: 25, nativeType: "text")], rows: [["1", "original"]])
        let grid = GridDraft(reference: table, result: result,
            metadata: [["name": "id", "nativeType": "integer", "primaryKey": "1", "editable": "true"],
                ["name": "label", "nativeType": "text", "primaryKey": "0", "editable": "true"]])
        document.attachGrid(grid)
        grid.set(ChangeValue(kind: "text", value: "unsaved"), row: 0, column: 1)
        try #require(grid.pendingCount == 1)
        #expect(await workspace.prepareConnectionEditor(profileID) == nil)
        #expect(document.grid === grid && grid.pendingCount == 1)
        #expect(issues == [.changes(document.title, count: 1)])
        decision = .discard
        #expect(await workspace.prepareConnectionEditor(profileID)?.id == profileID)
        #expect(document.grid == nil)
        await workspace.shutdown()
    }

    @Test func notificationsDoNotReturnAfterWorkspaceRestoration() async {
        let store = MemorySQLDocumentStore()
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store)
        await workspace.restoreSavedWorkspace()
        workspace.newDocument()
        workspace.reportCopyError("Session-only failure")
        await workspace.flushDocuments()
        let restored = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store)
        await restored.restoreSavedWorkspace()
        #expect(restored.documents.count == 1)
        #expect(restored.notifications.entries.isEmpty)
        await workspace.shutdown()
        await restored.shutdown()
    }
}
