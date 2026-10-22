import Foundation
import Testing
@testable import DBeer

/// Models and protocol fixtures only; no windows or application activation.
@MainActor
struct PasswordCommandTests {
    private func settings(_ command: PasswordCommand) -> ConnectionSettings {
        ConnectionSettings(host: "db.example.test", port: 5432, database: "app", user: "reader",
            password: "must-not-be-saved", sslMode: "verify-full", passwordCommand: command)
    }

    @Test func localRoundTripAndPortableTransferNeverEnableCommands() throws {
        let command = PasswordCommand(executable: "/synthetic/token-cli", arguments: ["token", "literal $HOME", ""])
        let value = settings(command)
        #expect(value.password.isEmpty && value.hasValidNativeFields)
        let profile = SavedConnection(name: "Dynamic", settings: value)
        let local = try JSONEncoder().encode(SavedConnectionLibrary(connections: [profile]))
        let restored = try JSONDecoder().decode(SavedConnectionLibrary.self, from: local)
        #expect(restored.connections.first?.passwordCommand == command)
        #expect(!String(decoding: local, as: UTF8.self).contains("must-not-be-saved"))
        #expect(profile.matches(profile.settings(password: "ignored-keychain-value")))
        var changed = value
        changed.passwordCommand?.arguments = ["different"]
        #expect(!profile.matches(changed))

        let portable = try ProfileTransfer.encode([profile])
        let text = String(decoding: portable, as: UTF8.self)
        #expect(!text.contains("passwordCommand") && !text.contains("token-cli") && !text.contains("$HOME"))
        let imported = try #require(ProfileTransfer.preview(portable).first)
        #expect(imported.profile.passwordCommand == nil)
        var envelope = try #require(JSONSerialization.jsonObject(with: portable) as? [String: Any])
        var records = try #require(envelope["profiles"] as? [[String: Any]])
        records[0]["passwordCommand"] = ["executable": "/bin/echo", "arguments": []] as [String: Any]
        envelope["profiles"] = records
        #expect(throws: ProfileTransferError.self) { _ = try ProfileTransfer.preview(JSONSerialization.data(withJSONObject: envelope)) }
    }

    @Test func editorKeepsExactArgumentsAndRejectsInvalidCommands() throws {
        let command = PasswordCommand(executable: "/synthetic/token cli", arguments: ["two words", "", "$(literal)", "quoted\"value"])
        let profile = SavedConnection(name: "Dynamic", settings: settings(command))
        var draft = ConnectionEditorRequest.duplicate(profile).makeDraft()
        #expect(draft.usesPasswordCommand && draft.settings?.passwordCommand == command)
        #expect(draft.settings?.password.isEmpty == true)
        try draft.applyConnectionURL("postgresql://reader@db.example.test/app")
        #expect(draft.usesPasswordCommand)
        try draft.applyConnectionURL("postgresql://reader:explicit@db.example.test/app")
        #expect(!draft.usesPasswordCommand && draft.password == "explicit")
        draft.usesPasswordCommand = true
        draft.passwordArguments = "token --database app"
        #expect(draft.settings == nil)
        draft.passwordArguments = "[1]"
        #expect(draft.settings == nil)
        draft.passwordArguments = "[]"
        draft.passwordExecutable = "relative-cli"
        #expect(draft.settings == nil)
        draft.usesPasswordCommand = false
        draft.password = "static"
        #expect(draft.settings?.passwordCommand == nil && draft.settings?.password == "static")
        for invalid in [PasswordCommand(executable: "cli", arguments: []),
                        PasswordCommand(executable: "/bin/echo", arguments: ["\0"]),
                        PasswordCommand(executable: "/bin/echo", arguments: Array(repeating: "", count: 129)),
                        PasswordCommand(executable: "/bin/echo", arguments: [String(repeating: "x", count: 65_536)])] {
            #expect(!settings(invalid).hasValidNativeFields)
        }
    }

    @Test func savingSelectingAndRestoringDoNotLaunchTheCommandOrSaveTokens() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/r30/model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("must-not-exist")
        let command = PasswordCommand(executable: "/usr/bin/touch", arguments: [marker.path])
        let store = MemoryConnectionLibraryStore()
        let credentials = MemoryConnectionCredentialStore()
        let model = WorkspaceModel(connectionStore: store, credentialStore: credentials)
        try #require(await model.saveConnection(name: "Dynamic", settings: settings(command)))
        let id = try #require(model.savedConnections.first?.id)
        #expect(await credentials.password(for: id) == nil)
        #expect(await model.passwordForConnection(id) == "")
        await model.selectConnection(id)
        #expect(model.passwordCommand == command && model.connectionState == .disconnected)
        let restored = try JSONDecoder().decode(SavedConnectionLibrary.self, from: JSONEncoder().encode(await store.load()))
        let restoredProfile = try #require(restored.connections.first)
        #expect(restoredProfile.passwordCommand == command)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        // Switching from Keychain explicitly removes the old persistent secret.
        var staticSettings = settings(command)
        staticSettings.passwordCommand = nil
        staticSettings.password = "old-static"
        try #require(await model.saveConnection(name: "Static", settings: staticSettings, id: id))
        #expect(await credentials.password(for: id) == "old-static")
        try #require(await model.saveConnection(name: "Dynamic", settings: settings(command), id: id))
        #expect(await credentials.password(for: id) == nil)
    }

    @Test func missingHelperCapabilityRejectsBeforeSending() async throws {
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        for line in sys.stdin:
            command = json.loads(line)
            if command['type'] == 'hello':
                reply = dict(type='hello.ack', requestId=command['requestId'], protocolVersion=5)
            elif command['type'] == 'shutdown':
                reply = dict(type='shutdown.ack', requestId=command['requestId'])
            else:
                sys.exit(23)
            print(json.dumps(reply), flush=True)
            if command['type'] == 'shutdown': break
        """])
        try await client.start()
        do {
            _ = try await client.request(.connect(settings(PasswordCommand(executable: "/bin/echo", arguments: ["token"]))))
            Issue.record("An unsupported command was accepted")
        } catch { #expect(error as? BackendRequestError == .unsupportedPasswordCommand) }
        await client.shutdown()
    }

    @Test func providerFailureDoesNotRetryOrSendUserSQL() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/r30/failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = root.appendingPathComponent("trace")
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        from pathlib import Path
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            with Path(sys.argv[1]).open('a') as trace: trace.write(kind + '\\n')
            reply = dict(requestId=command['requestId'])
            if kind == 'hello':
                reply.update(type='hello.ack', protocolVersion=5, capabilities=['passwordCommandV1'])
            elif kind == 'connect':
                reply.update(type='error', category='credential', message='The password command failed.')
            elif kind == 'shutdown': reply.update(type='shutdown.ack')
            else: sys.exit(24)
            print(json.dumps(reply), flush=True)
            if kind == 'shutdown': break
        """, trace.path])
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), helperFactory: { client })
        await workspace.start()
        try #require(await workspace.library.saveConnection(name: "Dynamic",
            settings: settings(PasswordCommand(executable: "/synthetic/token-cli", arguments: []))))
        let id = try #require(workspace.library.selectedConnectionId)
        let document = workspace.newDocument(profileID: id, text: "SELECT 1;")
        await workspace.run(document)
        #expect(document.runtime?.sessionId == nil)
        let operations = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n")
        #expect(operations.filter { $0 == "connect" }.count == 1)
        #expect(!operations.contains("execute"))
        await workspace.shutdown()
    }
}
