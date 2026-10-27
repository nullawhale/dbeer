import Foundation
import Testing
@testable import DBeer

/// Drafts, profile metadata and in-memory credential stores only. No windows,
/// native controls, database sessions or application activation.
@MainActor
struct ConnectionEditorDraftTests {
    private func profile(engine: DatabaseEngine = .postgresql, name: String = "Team database") -> SavedConnection {
        let id = UUID()
        let ssh = SSHConfiguration(host: "ssh.example.test", port: 2222, user: "operator", authMethod: .password)
        let settings = ConnectionSettings(host: "127.0.0.1", port: engine.defaultPort,
            database: engine == .cassandra ? "team" : engine.defaultDatabase, user: "analyst",
            password: "fixture-database-secret", sslMode: "verify-full", sslRootCert: "/connection-fixtures/ca.pem",
            engine: engine, policy: ExecutionPolicy(environment: .staging, readOnly: true),
            contactPoints: engine == .cassandra ? ["127.0.0.1", "127.0.0.2"] : nil,
            localDatacenter: engine == .cassandra ? "dc1" : nil,
            consistency: engine == .cassandra ? "LOCAL_ONE" : nil,
            ssh: ssh.runtime(profileId: id, password: "fixture-ssh-secret"),
            mongodb: engine == .mongodb ? MongoDBSettings(directConnection: true) : nil)
        return SavedConnection(id: id, name: name, settings: settings)
    }

    @Test(arguments: DatabaseEngine.allCases)
    func existingConnectionsKeepTheirEngineWhileNewConnectionsCanChoose(engine: DatabaseEngine) {
        let source = profile(engine: engine)
        let request = ConnectionEditorRequest.edit(source)
        var edit = request.makeDraft()
        #expect(request.existingConnection == source && request.credentialSource == source)
        #expect(!edit.allowsEngineSelection)
        for other in DatabaseEngine.allCases { edit.selectEngine(other) }
        #expect(edit.engine == engine && edit.port == String(source.port))

        let newRequest = ConnectionEditorRequest.new
        var new = newRequest.makeDraft()
        #expect(newRequest.existingConnection == nil && newRequest.credentialSource == nil)
        #expect(new.allowsEngineSelection)
        new.selectEngine(engine)
        #expect(new.engine == engine && new.port == String(engine.defaultPort))
    }

    @Test(arguments: DatabaseEngine.allCases)
    func duplicatePrefillsSettingsWithANewSSHIdentityAndAnEditableEngine(engine: DatabaseEngine) throws {
        let source = profile(engine: engine)
        let fixtureIsValid = source.settings(password: "fixture-database-secret").hasValidNativeFields
        try #require(fixtureIsValid, "The duplicated connection fixture must be valid for its engine and SSH topology.")
        let request = ConnectionEditorRequest.duplicate(source)
        let draft = request.makeDraft()
        #expect(request.existingConnection == nil && request.credentialSource == source)
        #expect(draft.allowsEngineSelection && draft.name == "Team database Copy")
        #expect(draft.password.isEmpty && draft.sshPassword.isEmpty && draft.sshPassphrase.isEmpty)
        var settings = try #require(draft.settings)
        #expect(settings.ssh?.profileId != source.id.uuidString)
        #expect(settings.ssh?.configuration == source.ssh)
        settings.ssh?.profileId = source.id.uuidString
        var expected = source.settings(password: "")
        expected.ssh?.password = ""
        #expect(settings == expected)

        var changed = draft
        let next: DatabaseEngine = engine == .mysql ? .postgresql : .mysql
        changed.selectEngine(next)
        #expect(changed.engine == next && changed.port == String(next.defaultPort))
        #expect(source.engine == engine && draft.engine == engine)
        #expect(request.makeDraft().settings?.ssh?.profileId != draft.settings?.ssh?.profileId)
    }

    @Test func duplicateNamesFitTheEditorLimitWithoutSplittingUnicodeCharacters() {
        let source = profile(name: String(repeating: "🐋", count: 128))
        let duplicate = ConnectionEditorRequest.duplicate(source).makeDraft()
        #expect(duplicate.name.count == 128 && duplicate.name.hasSuffix(" Copy"))
        #expect(duplicate.isValid && source.name.count == 128)
    }

    @Test func savingADuplicateCreatesIndependentMetadataAndCredentials() async throws {
        let library = MemoryConnectionLibraryStore()
        let credentials = MemoryConnectionCredentialStore()
        let model = WorkspaceModel(connectionStore: library, credentialStore: credentials)
        var originalSettings = profile().settings(password: "fixture-database-secret")
        originalSettings.ssh?.password = "fixture-ssh-secret"
        try #require(await model.saveConnection(name: "Original", settings: originalSettings))
        let original = try #require(model.savedConnections.first)
        let request = ConnectionEditorRequest.duplicate(original)
        var duplicate = request.makeDraft()
        let source = try #require(request.credentialSource)
        duplicate.password = try #require(await model.passwordForConnection(source.id))
        duplicate.sshPassword = try #require(await model.sshSecretForConnection(source.id, purpose: .sshPassword))
        #expect(model.savedConnections == [original])
        let settings = try #require(duplicate.settings)
        try #require(await model.saveConnection(name: duplicate.name, settings: settings,
            id: request.existingConnection?.id, rememberSSHSecret: duplicate.rememberSSHSecret))
        let duplicateID = try #require(model.selectedConnectionId)
        #expect(duplicateID != original.id && model.savedConnections.count == 2)
        #expect(model.savedConnections.first { $0.id == original.id } == original)
        #expect(await credentials.password(for: original.id) == "fixture-database-secret")
        #expect(await credentials.password(for: duplicateID) == "fixture-database-secret")
        #expect(await credentials.secret(for: original.id, purpose: .sshPassword) == "fixture-ssh-secret")
        #expect(await credentials.secret(for: duplicateID, purpose: .sshPassword) == "fixture-ssh-secret")
        await credentials.savePassword("changed-copy-secret", for: duplicateID)
        #expect(await credentials.password(for: original.id) == "fixture-database-secret")
        let metadata = try JSONEncoder().encode(await library.load())
        let text = String(decoding: metadata, as: UTF8.self)
        #expect(!text.contains("fixture-database-secret") && !text.contains("fixture-ssh-secret"))
    }
}
