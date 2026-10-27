import Foundation
import Testing
@testable import DBeer

private struct StoreFixtureError: Error {}

private actor ControlledLibraryStore: ConnectionLibraryStore {
    var library = SavedConnectionLibrary()
    var failLoad = false
    var failSave = false

    func setFailure(load: Bool = false, save: Bool = false) { failLoad = load; failSave = save }
    func load() throws -> SavedConnectionLibrary {
        if failLoad { throw StoreFixtureError() }
        return library
    }
    func save(_ library: SavedConnectionLibrary) throws {
        if failSave { throw StoreFixtureError() }
        self.library = library
    }
}

private actor ControlledCredentialStore: ConnectionCredentialStore {
    var values: [UUID: String] = [:]
    var failWrite = false
    var failRead = false
    private(set) var readCount = 0
    private(set) var writeCount = 0

    func setFailure(read: Bool = false, write: Bool = false) { failRead = read; failWrite = write }
    func password(for id: UUID) throws -> String? {
        readCount += 1
        if failRead { throw StoreFixtureError() }
        return values[id]
    }
    func savePassword(_ password: String, for id: UUID) throws {
        writeCount += 1
        if failWrite { throw StoreFixtureError() }
        values[id] = password
    }
    func deletePassword(for id: UUID) { values[id] = nil }
}

@MainActor
struct ConnectionLibraryTests {
    private func settings(host: String = "localhost", password: String = "fixture-secret") -> ConnectionSettings {
        ConnectionSettings(host: host, port: 5432, database: "fixture_db", user: "fixture_user",
            password: password, sslMode: "verify-full", sslRootCert: nil)
    }

    private func helper() -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            reply = {'requestId':command['requestId']}
            if kind == 'hello':
                reply.update(type='hello.ack', protocolVersion=5)
            elif kind == 'connect':
                reply.update(type='connect.result', engine='postgresql', capabilities=['execute','cancel','transactions'], sessionId='library-session', transactionStatus='idle')
            elif kind == 'disconnect':
                reply.update(type='disconnect.ack', sessionId=command['sessionId'])
            elif kind == 'shutdown':
                reply.update(type='shutdown.ack')
            else:
                sys.exit(22)
            print(json.dumps(reply), flush=True)
            if kind == 'shutdown':
                break
        """])
    }

    @Test func metadataRoundTripHasNoPassword() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("connections.json")
        let store = FileConnectionLibraryStore(fileURL: url)
        let profile = SavedConnection(name: "Test database", settings: settings())
        let library = SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id)
        try await store.save(library)
        #expect(try await store.load() == library)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(!json.contains("password"))
        #expect(!json.contains("fixture-secret"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func corruptMetadataStaysUntouchedAndCannotBeOverwritten() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("connections.json")
        let invalid = Data("{ invalid JSON".utf8)
        try invalid.write(to: url)
        let model = WorkspaceModel(connectionStore: FileConnectionLibraryStore(fileURL: url))
        #expect(!(await model.saveConnection(name: "Test", settings: settings())))
        #expect(model.connectionsError?.contains("could not be read") == true)
        #expect(try Data(contentsOf: url) == invalid)
        #expect(model.savedConnections.isEmpty)
    }

    @Test func profilesReloadWithoutReadingCredentialsOrConnecting() async throws {
        let store = MemoryConnectionLibraryStore()
        let credentials = ControlledCredentialStore()
        let first = WorkspaceModel(connectionStore: store, credentialStore: credentials)
        #expect(await first.saveConnection(name: "Work", settings: settings()))
        let id = try #require(first.selectedConnectionId)
        let readsBeforeLaunch = await credentials.readCount
        await credentials.setFailure(read: true)
        let second = WorkspaceModel(helperFactory: { helper() }, connectionStore: store, credentialStore: credentials)
        await second.start()
        #expect(second.savedConnections.count == 1)
        #expect(second.selectedConnectionId == id)
        #expect(second.host == "localhost")
        #expect(second.password.isEmpty)
        #expect(await credentials.readCount == readsBeforeLaunch)
        #expect(second.connectionsError == nil)
        #expect(second.connectionState == .disconnected)
        #expect(second.activeConnectionId == nil)
        #expect(second.sessionId == nil)
        await second.shutdown()
    }

    @Test func selectionDoesNotReadCredentialsAndEachSavedConnectReadsOnce() async throws {
        let first = SavedConnection(name: "A", settings: settings(host: "host-a"))
        let second = SavedConnection(name: "B", settings: settings(host: "host-b"))
        let store = MemoryConnectionLibraryStore(library: SavedConnectionLibrary(
            connections: [first, second], selectedConnectionId: first.id))
        let credentials = ControlledCredentialStore()
        try await credentials.savePassword("first-secret", for: first.id)
        try await credentials.savePassword("second-secret", for: second.id)
        await credentials.setFailure(read: true)
        let model = WorkspaceModel(helperFactory: { helper() }, connectionStore: store, credentialStore: credentials)
        await model.start()
        await model.selectConnection(second.id)
        await model.selectConnection(first.id)
        #expect(model.host == "host-a")
        #expect(model.password.isEmpty)
        #expect(model.connectionsError == nil)
        #expect(await credentials.readCount == 0)

        await credentials.setFailure()
        await model.connectSavedConnection(first.id)
        #expect(model.activeConnectionId == first.id)
        #expect(model.password == "first-secret")
        #expect(await credentials.readCount == 1)
        #expect(await credentials.writeCount == 2)
        await model.selectConnection(second.id)
        #expect(model.host == "host-a")
        #expect(model.password == "first-secret")
        #expect(await credentials.readCount == 1)
        await model.disconnect()
        await model.selectConnection(second.id)
        #expect(model.host == "host-b")
        #expect(model.password.isEmpty)
        #expect(await credentials.readCount == 1)
        await model.connectSavedConnection(second.id)
        #expect(model.activeConnectionId == second.id)
        #expect(model.password == "second-secret")
        #expect(await credentials.readCount == 2)
        #expect(await credentials.writeCount == 2)
        await model.shutdown()
    }

    @Test func failedMetadataSaveRollsBackCredentialChange() async throws {
        let store = ControlledLibraryStore()
        let credentials = ControlledCredentialStore()
        let model = WorkspaceModel(connectionStore: store, credentialStore: credentials)
        #expect(await model.saveConnection(name: "Work", settings: settings()))
        let id = try #require(model.selectedConnectionId)
        await store.setFailure(save: true)
        #expect(!(await model.saveConnection(name: "Renamed", settings: settings(password: "changed-secret"), id: id)))
        #expect(model.savedConnections.first?.name == "Work")
        #expect(try await credentials.password(for: id) == "fixture-secret")
        #expect(model.connectionsError?.contains("could not be saved") == true)
    }

    @Test func failedCredentialSaveDoesNotCreateProfile() async {
        let store = MemoryConnectionLibraryStore()
        let credentials = ControlledCredentialStore()
        await credentials.setFailure(write: true)
        let model = WorkspaceModel(connectionStore: store, credentialStore: credentials)
        #expect(!(await model.saveConnection(name: "Work", settings: settings())))
        #expect(model.savedConnections.isEmpty)
        #expect(await store.load().connections.isEmpty)
        #expect(model.connectionsError?.contains("Keychain") == true)
    }

    @Test func failedPasswordReadIsDistinctFromEmptyAndRetryPreservesPassword() async throws {
        let credentials = ControlledCredentialStore()
        let model = WorkspaceModel(credentialStore: credentials)
        #expect(await model.saveConnection(name: "Work", settings: settings()))
        let id = try #require(model.selectedConnectionId)
        await credentials.setFailure(read: true)
        #expect(await model.passwordForConnection(id) == nil)
        await credentials.setFailure()
        let restoredPassword = try #require(await model.passwordForConnection(id))
        #expect(restoredPassword == "fixture-secret")
        #expect(await model.saveConnection(name: "Renamed", settings: settings(password: restoredPassword), id: id))
        #expect(try await credentials.password(for: id) == "fixture-secret")
        #expect(model.savedConnections.first?.name == "Renamed")

        #expect(await model.saveConnection(name: "Empty", settings: settings(password: "")))
        let emptyId = try #require(model.selectedConnectionId)
        #expect(await model.passwordForConnection(emptyId) == "")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBEER_TEST_KEYCHAIN"] == "1",
                   "Set DBEER_TEST_KEYCHAIN=1 to run the isolated native Keychain smoke test."))
    func nativeKeychainSupportsCreateReadUpdateAndDelete() async throws {
        let service = "dev.dbeer.tests.\(UUID().uuidString)"
        let keychainURL = ProcessInfo.processInfo.environment["DBEER_TEST_KEYCHAIN_PATH"].map {
            URL(fileURLWithPath: $0)
        }
        let credentials = KeychainConnectionCredentialStore(service: service, keychainURL: keychainURL)
        let id = UUID()
        do {
            #expect(try await credentials.password(for: id) == nil)
            try await credentials.savePassword("keychain-fixture-one", for: id)
            #expect(try await credentials.password(for: id) == "keychain-fixture-one")
            try await credentials.savePassword("keychain-fixture-two", for: id)
            // A fresh store retains the original UUID/account and service,
            // just as a relaunch does. This is not a signing-update test.
            let reopened = KeychainConnectionCredentialStore(service: service, keychainURL: keychainURL)
            #expect(try await reopened.password(for: id) == "keychain-fixture-two")
            try await reopened.deletePassword(for: id)
            #expect(try await credentials.password(for: id) == nil)
        } catch {
            try? await credentials.deletePassword(for: id)
            throw error
        }
    }

    @Test func credentialFailureKeepsSuccessfulSQLSessionConnected() async {
        let credentials = ControlledCredentialStore()
        await credentials.setFailure(write: true)
        let model = WorkspaceModel(helperFactory: { helper() }, credentialStore: credentials)
        await model.start(startupConnection: .success(settings()))
        #expect(model.connectionState == .connected)
        #expect(model.sessionId == "library-session")
        #expect(model.canRun)
        #expect(model.connectionsError?.contains("Keychain") == true)
        #expect(model.errorMessage == nil)
        await model.shutdown()
    }

    @Test func selectionAndEditingPreserveLiveConnectionParameters() async throws {
        let model = WorkspaceModel(helperFactory: { helper() })
        #expect(await model.saveConnection(name: "A", settings: settings(host: "host-a")))
        let firstId = try #require(model.selectedConnectionId)
        #expect(await model.saveConnection(name: "B", settings: settings(host: "host-b", password: "second-secret")))
        let secondId = try #require(model.selectedConnectionId)
        await model.start()
        await model.connectSavedConnection(firstId)
        #expect(model.activeConnectionId == firstId)
        await model.selectConnection(secondId)
        #expect(model.selectedConnectionId == secondId)
        #expect(model.activeConnectionId == firstId)
        #expect(model.host == "host-a")
        #expect(model.password == "fixture-secret")
        #expect(await model.saveConnection(name: "A changed", settings: settings(host: "new-host"), id: firstId))
        #expect(model.host == "host-a")
        #expect(model.connectionSummary.contains("host-a"))
        #expect(model.sessionId == "library-session")
        #expect(!(await model.deleteConnection(firstId)))
        await model.disconnect()
        #expect(model.activeConnectionId == nil)
        await model.connectSavedConnection(firstId)
        #expect(model.host == "new-host")
        await model.shutdown()
    }

    @Test func deletingProfileRemovesStoredCredential() async throws {
        let credentials = ControlledCredentialStore()
        let store = MemoryConnectionLibraryStore()
        let model = WorkspaceModel(connectionStore: store, credentialStore: credentials)
        #expect(await model.saveConnection(name: "Work", settings: settings()))
        let id = try #require(model.selectedConnectionId)
        #expect(await model.deleteConnection(id))
        #expect(model.savedConnections.isEmpty)
        #expect(try await credentials.password(for: id) == nil)
        #expect(await store.load().connections.isEmpty)
        #expect(model.selectedConnectionId == nil)
    }

    @Test func stdinImportReusesProfileAndRefreshesKeychainPassword() async throws {
        let store = MemoryConnectionLibraryStore()
        let credentials = ControlledCredentialStore()
        let first = WorkspaceModel(connectionStore: store, credentialStore: credentials)
        #expect(await first.saveConnection(name: "My database", settings: settings()))
        let id = try #require(first.selectedConnectionId)
        let second = WorkspaceModel(helperFactory: { helper() }, connectionStore: store, credentialStore: credentials)
        await second.start(startupConnection: .success(settings(password: "fresh-secret")))
        #expect(second.connectionState == .connected)
        #expect(second.savedConnections.count == 1)
        #expect(second.savedConnections.first?.name == "My database")
        #expect(second.activeConnectionId == id)
        #expect(try await credentials.password(for: id) == "fresh-secret")
        await second.shutdown()
    }
}
