import Foundation
import Testing
@testable import DBeer

/// Protocol-process fixtures only. Trusted SSH replies avoid native trust UI;
/// no database, Keychain, windows or application activation are used.
@MainActor
struct ConnectionTesterTests {
    private struct Fixture {
        let directory: URL
        let client: BackendClient
        var trace: [String] {
            (try? String(contentsOf: directory.appendingPathComponent("trace"), encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private func fixture(mode: String = "success", sourceProfile: String = "") throws -> Fixture {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/connection-test-fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time
        from pathlib import Path
        directory, mode, source = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            with (directory / 'trace').open('a') as trace:
                trace.write(kind + '\\n')
            reply = {'requestId':command['requestId']}
            if kind == 'hello':
                reply.update(type='hello.ack', protocolVersion=5)
            elif kind == 'ssh.probe':
                ssh = command['connection']['ssh']
                assert ssh['profileId'] != source
                reply.update(type='ssh.probe.result', ssh={'status':'trusted', 'host':ssh['host'],
                    'port':ssh['port'], 'algorithm':'ssh-ed25519', 'fingerprint':'SHA256:fixture'})
            elif kind == 'connect':
                settings = command['connection']
                assert settings['host'] == 'draft.example.test'
                assert settings['password'] == 'draft-fixture-secret'
                assert settings['sslMode'] == 'verify-full'
                if settings['engine'] == 'mongodb':
                    assert settings['user'] == 'analyst'
                    assert settings['mongodb']['authSource'] == 'admin'
                if settings.get('ssh'):
                    assert settings['ssh']['profileId'] != source
                    assert settings['ssh']['password'] == 'ssh-fixture-secret'
                if mode == 'hang':
                    (directory / 'entered').touch()
                    time.sleep(30)
                if mode == 'late':
                    (directory / 'entered').touch()
                    deadline = time.monotonic() + 5
                    while not (directory / 'release').exists() and time.monotonic() < deadline:
                        time.sleep(.005)
                if mode == 'reject':
                    reply.update(type='error', category='connection', message='Authentication failed.',
                        connected=False, outcomeUnknown=False)
                else:
                    reply.update(type='connect.result', engine=settings['engine'], capabilities=['execute'],
                        sessionId='temporary-test-session', transactionStatus='unsupported' if settings['engine'] in ['cassandra','mongodb'] else 'idle')
            elif kind == 'disconnect':
                assert command['sessionId'] == 'temporary-test-session'
                if mode == 'disconnect-error':
                    reply.update(type='error', sessionId=command['sessionId'], category='connection', message='Disconnect failed.', connected=False, outcomeUnknown=False)
                else:
                    reply.update(type='disconnect.ack', sessionId=command['sessionId'])
            elif kind == 'shutdown':
                reply.update(type='shutdown.ack')
            else:
                sys.exit(42)
            print(json.dumps(reply), flush=True)
            if kind == 'shutdown':
                break
        """, directory.path, mode, sourceProfile])
        return Fixture(directory: directory, client: client)
    }

    private func settings(engine: DatabaseEngine = .postgresql) -> ConnectionSettings {
        ConnectionSettings(host: "draft.example.test", port: engine.defaultPort,
            database: engine.defaultDatabase, user: [.cassandra, .mongodb].contains(engine) ? "analyst" : engine.defaultUser, password: "draft-fixture-secret",
            sslMode: "verify-full", engine: engine,
            contactPoints: engine == .cassandra ? ["draft.example.test"] : nil,
            mongodb: engine == .mongodb ? MongoDBSettings(authSource: "admin") : nil)
    }

    private func waitUntilEntered(_ fixture: Fixture) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("entered").path),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("entered").path))
    }

    @Test(arguments: DatabaseEngine.allCases)
    func successClosesTheTemporarySessionAndHelper(engine: DatabaseEngine) async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let tester = ConnectionTester(helperFactory: { fixture.client })
        // Testing does not require a saved profile or a nonempty profile name.
        let connection = settings(engine: engine)
        let fixtureIsValid = connection.hasValidNativeFields
        try #require(fixtureIsValid, "The connection-test fixture must be valid for its engine.")
        await tester.test(connection)
        try #require(tester.state == .succeeded && !tester.isTesting)
        #expect(fixture.trace == ["hello", "connect", "disconnect", "shutdown"])
        #expect(await fixture.client.waitForExit().status == 0)
        tester.reset()
        #expect(tester.state == .idle)
    }

    @Test(arguments: ["reject", "disconnect-error"])
    func failuresNeverReportSuccessAndStillShutDown(mode: String) async throws {
        let fixture = try fixture(mode: mode)
        defer { fixture.remove() }
        let tester = ConnectionTester(helperFactory: { fixture.client })
        await tester.test(settings())
        let expected = mode == "reject" ? "Authentication failed." : "Disconnect failed."
        #expect(tester.state == .failed(expected))
        #expect(fixture.trace.last == "shutdown")
        #expect(await fixture.client.waitForExit().status == 0)
    }

    @Test func trustedSSHUsesAnIndependentReviewIdentity() async throws {
        let id = UUID()
        let fixture = try fixture(sourceProfile: id.uuidString)
        defer { fixture.remove() }
        var settings = settings()
        settings.ssh = SSHConfiguration(host: "bastion.example.test", user: "analyst", authMethod: .password)
            .runtime(profileId: id, password: "ssh-fixture-secret")
        let tester = ConnectionTester(helperFactory: { fixture.client })
        await tester.test(settings)
        #expect(tester.state == .succeeded)
        #expect(settings.ssh?.profileId == id.uuidString)
        #expect(fixture.trace == ["hello", "ssh.probe", "connect", "disconnect", "shutdown"])
    }

    @Test func invalidSettingsNeverLaunchAHelper() async {
        var launches = 0
        let tester = ConnectionTester(helperFactory: { launches += 1; return BackendClient() })
        var settings = settings()
        settings.port = 0
        await tester.test(settings)
        #expect(launches == 0 && !tester.isTesting)
        if case .failed = tester.state {} else { Issue.record("Invalid settings were accepted") }
    }

    @Test func cancellingAStalledConnectStopsOnlyTheDisposableHelper() async throws {
        let fixture = try fixture(mode: "hang")
        defer { fixture.remove() }
        let tester = ConnectionTester(helperFactory: { fixture.client })
        let test = Task { await tester.test(settings()) }
        try await waitUntilEntered(fixture)
        tester.cancel()
        #expect(tester.state == .cancelling)
        // A second click cannot launch another helper during cancellation.
        await tester.test(settings())
        await test.value
        #expect(tester.state == .cancelled && !tester.isTesting)
        #expect(fixture.trace.filter { $0 == "connect" }.count == 1)
        _ = await fixture.client.waitForExit()
    }

    @Test func taskCancellationClosesALateSessionAndAllowsRetry() async throws {
        let first = try fixture(mode: "late")
        let second = try fixture()
        defer { first.remove(); second.remove() }
        var launches = 0
        let tester = ConnectionTester(helperFactory: {
            launches += 1
            return launches == 1 ? first.client : second.client
        })
        let test = Task { await tester.test(settings()) }
        try await waitUntilEntered(first)
        test.cancel()
        FileManager.default.createFile(atPath: first.directory.appendingPathComponent("release").path, contents: Data())
        await test.value
        #expect(tester.state == .cancelled)
        #expect(first.trace == ["hello", "connect", "disconnect", "shutdown"])
        await tester.test(settings())
        #expect(tester.state == .succeeded && launches == 2)
    }
}
