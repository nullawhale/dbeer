import Foundation
import Testing
@testable import DBeer

private actor SSHFailingLibrary: ConnectionLibraryStore {
    var library = SavedConnectionLibrary()
    var fails = false
    func setFailure(_ value: Bool) { fails = value }
    func load() -> SavedConnectionLibrary { library }
    func save(_ value: SavedConnectionLibrary) throws {
        if fails { throw ConnectionLibraryError.save }
        library = value
    }
}

struct SSHNativeTests {
    private func settings(id: UUID = UUID(), method: SSHConfiguration.Authentication = .password) -> ConnectionSettings {
        let config = SSHConfiguration(host: "bastion.example", user: "analyst", authMethod: method,
            identityFile: method == .privateKey ? "/synthetic/private-key" : nil)
        return ConnectionSettings(host: "database.internal", port: 5432, database: "app", user: "reader",
            password: "database-secret", sslMode: "verify-full", ssh: config.runtime(profileId: id,
                password: method == .password ? "ssh-secret" : nil,
                passphrase: method == .privateKey ? "key-secret" : nil))
    }

    @Test func persistenceKeepsOnlyMetadataAndOldProfilesStayDirect() throws {
        let runtime = settings()
        let profile = SavedConnection(name: "SSH", settings: runtime)
        let data = try JSONEncoder().encode(profile)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("database-secret") && !text.contains("ssh-secret"))
        #expect(!text.contains("profileId") && !text.contains("passphrase"))
        let restored = try JSONDecoder().decode(SavedConnection.self, from: data)
        #expect(restored.ssh == runtime.ssh?.configuration)
        #expect(restored.settings(password: "").ssh?.profileId == profile.id.uuidString)
        #expect(restored.settings(password: "").ssh?.password == nil)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "ssh")
        let old = try JSONDecoder().decode(SavedConnection.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.ssh == nil && old.settings(password: "").ssh == nil)
        var different = runtime
        different.ssh?.host = "other.example"
        #expect(!profile.matches(different))
    }

    @Test func transferStripsKeyAuthoritySecretsAndProfileIdentity() throws {
        let source = SavedConnection(name: "Key", settings: settings(method: .privateKey))
        let data = try ProfileTransfer.encode([source])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("identityFile") && !text.contains("/synthetic/private-key"))
        #expect(!text.contains("key-secret") && !text.contains(source.id.uuidString))
        let imported = try #require(ProfileTransfer.preview(data).first)
        #expect(imported.profile.ssh?.authMethod == .privateKey)
        #expect(imported.requiresSSHKeySelection)
        #expect(imported.profile.ssh?.identityFile == nil)
        #expect(imported.profile.sslMode == "verify-full")
        #expect(imported.id != source.id)
        let malicious = text.replacingOccurrences(of: "\"authMethod\" :", with: "\"identityFile\":\"/untrusted/key\",\"authMethod\" :")
        #expect(throws: ProfileTransferError.self) { _ = try ProfileTransfer.preview(Data(malicious.utf8)) }
    }

    @Test func rejectsMalformedSSHInsteadOfChangingTransport() throws {
        var connection = settings()
        for host in ["-option", "host/path", "name@host", "[::1]", "bad\nhost", "x:y", "*.example", "a,b.example", "@revoked", "name\".example"] {
            connection.ssh?.host = host
            #expect(!connection.hasValidNativeFields)
        }
        connection = settings()
        connection.ssh?.profileId = "not-a-uuid"
        #expect(!connection.hasValidNativeFields)
        var draft = ConnectionDraft(connection: nil)
        draft.name = "SSH"
        draft.sshEnabled = true
        #expect(draft.settings == nil)
        draft.sshHost = "bastion.example"
        draft.sshUser = "analyst"
        #expect(draft.settings?.ssh?.authMethod == .agent)
        draft.sshPort = "65536"
        #expect(draft.settings == nil)
    }

    @MainActor @Test func failedSaveRestoresAllCredentialsAndMethodChangeDeletesOldSecret() async throws {
        let library = SSHFailingLibrary()
        let credentials = MemoryConnectionCredentialStore()
        let model = WorkspaceModel(connectionStore: library, credentialStore: credentials)
        #expect(await model.saveConnection(name: "SSH", settings: settings()))
        let id = try #require(model.selectedConnectionId)
        #expect(try await credentials.secret(for: id, purpose: .databasePassword) == "database-secret")
        #expect(try await credentials.secret(for: id, purpose: .sshPassword) == "ssh-secret")
        await library.setFailure(true)
        var updated = settings(id: id, method: .privateKey)
        updated.password = "new-database-secret"
        #expect(!(await model.saveConnection(name: "SSH", settings: updated, id: id)))
        #expect(try await credentials.secret(for: id, purpose: .databasePassword) == "database-secret")
        #expect(try await credentials.secret(for: id, purpose: .sshPassword) == "ssh-secret")
        #expect(try await credentials.secret(for: id, purpose: .sshPassphrase) == nil)
        await library.setFailure(false)
        let savedUpdated = await model.saveConnection(name: "SSH", settings: updated, id: id)
        #expect(savedUpdated, "\(model.connectionsError ?? "No persistence error")")
        #expect(try await credentials.secret(for: id, purpose: .sshPassword) == nil)
        #expect(try await credentials.secret(for: id, purpose: .sshPassphrase) == "key-secret")
        #expect(await model.saveConnection(name: "SSH", settings: updated, id: id, rememberSSHSecret: false))
        #expect(try await credentials.secret(for: id, purpose: .sshPassphrase) == nil)
        #expect(await model.deleteConnection(id))
        #expect(try await credentials.secret(for: id, purpose: .databasePassword) == nil)
    }

    @MainActor @Test(arguments: ["ssh.probe", "connect"])
    func cancelledSSHConnectionNeverConnectsAfterReviewAndReleasesLateSession(_ delayed: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time
        from pathlib import Path
        directory, delayed = Path(sys.argv[1]), sys.argv[2]
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            if kind == delayed:
                (directory / 'entered').touch()
                deadline = time.monotonic() + 5
                while not (directory / 'release').exists() and time.monotonic() < deadline:
                    time.sleep(.005)
            reply = {'requestId':command['requestId']}
            if kind == 'hello':
                reply.update(type='hello.ack', protocolVersion=5)
            elif kind == 'ssh.probe':
                ssh = command['connection']['ssh']
                reply.update(type='ssh.probe.result', ssh={'status':'unknown' if delayed == 'ssh.probe' else 'trusted',
                    'challengeToken':'fixture-token','host':ssh['host'],'port':ssh['port'],
                    'algorithm':'ssh-ed25519','fingerprint':'SHA256:fixture'})
            elif kind == 'connect':
                (directory / 'connected').touch()
                reply.update(type='connect.result', engine='postgresql', capabilities=['execute'], sessionId='late-session', transactionStatus='idle')
            elif kind == 'disconnect':
                (directory / 'disconnected').touch()
                reply.update(type='disconnect.ack', sessionId=command['sessionId'])
            elif kind == 'shutdown':
                reply.update(type='shutdown.ack')
            else:
                sys.exit(48)
            print(json.dumps(reply), flush=True)
            if kind == 'shutdown':
                break
        """, directory.path, delayed])
        let model = WorkspaceModel(helperFactory: { client }, credentialStore: MemoryConnectionCredentialStore())
        await model.start()
        #expect(await model.saveConnection(name: "SSH", settings: settings()))
        let id = try #require(model.selectedConnectionId)
        let connecting = Task { await model.connectSavedConnection(id) }
        defer { FileManager.default.createFile(atPath: directory.appendingPathComponent("release").path, contents: Data()); Task { await model.shutdown() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("entered").path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(FileManager.default.fileExists(atPath: directory.appendingPathComponent("entered").path))
        model.cancelConnection()
        FileManager.default.createFile(atPath: directory.appendingPathComponent("release").path, contents: Data())
        await connecting.value
        #expect(model.connectionState == .disconnected && model.sessionId == nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("connected").path) == (delayed == "connect"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("disconnected").path) == (delayed == "connect"))
        if case .ready = model.state {} else { Issue.record("Cancellation invalidated the unrelated helper transport") }
        await model.shutdown()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBEER_TEST_KEYCHAIN"] == "1", "Requires the isolated test Keychain."))
    func nativeKeychainPurposesAreIndependentAndKeepDatabaseIdentity() async throws {
        let service = "dev.dbeer.tests.ssh.\(UUID().uuidString)"
        let url = ProcessInfo.processInfo.environment["DBEER_TEST_KEYCHAIN_PATH"].map { URL(fileURLWithPath: $0) }
        let store = KeychainConnectionCredentialStore(service: service, keychainURL: url)
        let id = UUID()
        do {
            try await store.savePassword("db", for: id)
            try await store.saveSecret("ssh", for: id, purpose: .sshPassword)
            try await store.saveSecret("key", for: id, purpose: .sshPassphrase)
            #expect(try await store.password(for: id) == "db")
            #expect(try await store.secret(for: id, purpose: .sshPassword) == "ssh")
            #expect(try await store.secret(for: id, purpose: .sshPassphrase) == "key")
            try await store.deleteSecret(for: id, purpose: .sshPassword)
            #expect(try await store.password(for: id) == "db")
            #expect(try await store.secret(for: id, purpose: .sshPassphrase) == "key")
        } catch {
            for purpose in ConnectionCredentialPurpose.allCases { try? await store.deleteSecret(for: id, purpose: purpose) }
            throw error
        }
        for purpose in ConnectionCredentialPurpose.allCases { try await store.deleteSecret(for: id, purpose: purpose) }
    }

    @Test func advertisedSSHTunnelsAllowGracefulWatchdogCleanupBeforeForceExit() async throws {
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time
        for line in sys.stdin:
            command = json.loads(line)
            reply = {'requestId':command['requestId']}
            if command['type'] == 'hello':
                reply.update(type='hello.ack',protocolVersion=5,capabilities=['sshTunnelsV1'])
            elif command['type'] == 'shutdown':
                time.sleep(2.2)
                reply.update(type='shutdown.ack')
            else:
                sys.exit(49)
            print(json.dumps(reply),flush=True)
            if command['type'] == 'shutdown':
                break
        """])
        try await client.start()
        let shutdown = await client.shutdown()
        #expect(shutdown.acknowledged && !shutdown.forced)
    }

    @Test func reviewMessagesAreBoundedAndReplacementIsExplicit() throws {
        let connection = settings()
        let command = BackendCommand.sshTrust(connection, token: "one-use-token", replace: true)
        #expect(command.sshTrust?.replace == true)
        #expect(command.terminalType == "ssh.trust.result")
        var key = SSHHostKey(status: "unknown", challengeToken: "token", host: "bastion.example", port: 22,
            algorithm: "ssh-ed25519", fingerprint: "SHA256:fixture")
        #expect(key.isValid)
        key.challengeToken = nil
        #expect(!key.isValid)
        key.status = "trusted"
        #expect(key.isValid)
        key.fingerprint = "untrusted diagnostic text"
        #expect(!key.isValid)
    }
}
