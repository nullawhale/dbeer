import Foundation
import Testing
@testable import DBeer

/// In-memory models and protocol subprocesses only. No windows, controls,
/// desktop interaction, clipboard access or application activation.
@MainActor
struct WorkspaceNotificationTests {
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
