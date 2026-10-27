import Testing
@testable import DBeer

@MainActor
struct AppDelegateStartupTests {
    @Test func workspaceDelegateExposesAgentSettingsBeforeStartup() throws {
        var helperStarts = 0
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
            automaticallyWatchFiles: false,
            helperFactory: { helperStarts += 1; return BackendClient() })
        let delegate = AppDelegate(model: workspace.library, workspace: workspace)

        let agents = try #require(delegate.agents)
        #expect(agents.clients.isEmpty)
        #expect(agents.audit.isEmpty)
        #expect(delegate.agentBrokerError == nil)
        #expect(helperStarts == 0)
    }

    @Test func modelOnlyDelegateDoesNotCreateAgentAccess() {
        let model = WorkspaceModel(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let delegate = AppDelegate(model: model)

        #expect(delegate.agents == nil)
    }
}
