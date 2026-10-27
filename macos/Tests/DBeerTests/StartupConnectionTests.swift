import Darwin
import Foundation
import Testing
@testable import DBeer

struct StartupConnectionTests {
    private let settings = ConnectionSettings(host: "127.0.0.1", port: 54_329,
        database: "playground", user: "tester", password: "fixture-secret",
        sslMode: "disable", sslRootCert: nil)

    @Test func normalLaunchDoesNotReadInput() async {
        let input = await StartupConnection.load(arguments: ["DBeer"]) {
            throw StartupConnection.InputError.invalid
        }
        #expect(input == nil)
    }

    @Test func explicitLaunchDecodesConnectionSettings() async throws {
        let data = try JSONEncoder().encode(settings)
        let input = await StartupConnection.load(arguments: ["DBeer", "--connect-stdin"]) { data }
        #expect(try input?.get() == settings)
    }

    @Test func legacyStartupDefaultsToPostgreSQLAndMySQLValidatesItsTLSModes() throws {
        let original = """
        {"host":"localhost","port":5432,"database":"postgres","user":"postgres","password":"", "sslMode":"disable"}
        """
        #expect(try StartupConnection.decode(Data(original.utf8)).engine == .postgresql)
        let mysql = original.replacingOccurrences(of: "{", with: "{\"engine\":\"mysql\",")
        #expect(try StartupConnection.decode(Data(mysql.utf8)).engine == .mysql)
        let unsupported = mysql.replacingOccurrences(of: "\"disable\"", with: "\"prefer\"")
        #expect(throws: StartupConnection.InputError.self) { _ = try StartupConnection.decode(Data(unsupported.utf8)) }
        let unknown = mysql.replacingOccurrences(of: "\"mysql\"", with: "\"unknown\"")
        #expect(throws: StartupConnection.InputError.self) { _ = try StartupConnection.decode(Data(unknown.utf8)) }
    }

    @Test func invalidInputUsesOneGenericError() async throws {
        var invalidPort = settings
        invalidPort.port = 65_536
        var invalidTLS = settings
        invalidTLS.sslMode = "fixture-secret"
        let invalidInputs = [Data("{fixture-secret".utf8),
            try JSONEncoder().encode(invalidPort), try JSONEncoder().encode(invalidTLS),
            Data(repeating: 32, count: StartupConnection.maxInputBytes + 1)]
        for data in invalidInputs {
            let input = await StartupConnection.load(arguments: ["DBeer", "--connect-stdin"]) { data }
            guard case .failure(let error) = input else {
                Issue.record("Invalid startup input was accepted.")
                continue
            }
            #expect(error.localizedDescription == StartupConnection.InputError.invalid.localizedDescription)
            #expect(!error.localizedDescription.contains("fixture-secret"))
        }
    }

    @Test func pipeReadCompletesAtEOFAndClosesDescriptor() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(Darwin.pipe(&descriptors) == 0)
        let data = try JSONEncoder().encode(settings)
        let written = data.withUnsafeBytes { Darwin.write(descriptors[1], $0.baseAddress, $0.count) }
        #expect(written == data.count)
        Darwin.close(descriptors[1])
        #expect(try StartupConnection.readInput(from: descriptors[0]) == data)
        #expect(Darwin.fcntl(descriptors[0], F_GETFD) == -1)
    }

    @Test func stalledPipeTimesOut() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(Darwin.pipe(&descriptors) == 0)
        defer { Darwin.close(descriptors[1]) }
        #expect(throws: StartupConnection.InputError.self) {
            try StartupConnection.readInput(from: descriptors[0], timeoutMilliseconds: 20)
        }
    }

    @MainActor
    @Test func bootstrapConnectsOnceWithoutExecutingSQL() async {
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        def read():
            return json.loads(sys.stdin.readline())
        def send(message):
            print(json.dumps(message), flush=True)
        command = read()
        send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':5})
        command = read()
        assert command['type'] == 'connect'
        assert command['connection']['host'] == '127.0.0.1'
        assert command['connection']['port'] == 54329
        assert command['connection']['database'] == 'playground'
        assert command['connection']['user'] == 'tester'
        assert command['connection']['password'] == 'fixture-secret'
        assert command['connection']['sslMode'] == 'disable'
        send({'type':'connect.result','engine':'postgresql','capabilities':['execute','cancel','transactions'],'requestId':command['requestId'],'sessionId':'startup-session','transactionStatus':'idle'})
        command = read()
        assert command['type'] == 'shutdown'
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """])
        var launches = 0
        let model = WorkspaceModel(helperFactory: { launches += 1; return client })
        await model.start(startupConnection: .success(settings))
        await model.start(startupConnection: .success(settings))
        #expect(launches == 1)
        #expect(model.sessionId == "startup-session")
        #expect(model.canRun)
        #expect(model.result == nil)
        #expect(model.sql == "SELECT 1 AS id, 'hello'::text AS name;")
        #expect(model.sslRootCert.isEmpty)
        await model.shutdown()
        #expect(await client.waitForExit().status == 0)
    }

    @MainActor
    @Test func failedHelperRetainsFormForManualRetry() async {
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/missing-dbeer-helper"))
        let model = WorkspaceModel(helperFactory: { client })
        await model.start(startupConnection: .success(settings))
        #expect(model.host == settings.host)
        #expect(model.port == String(settings.port))
        #expect(model.database == settings.database)
        #expect(model.user == settings.user)
        #expect(model.password == settings.password)
        #expect(model.sslMode == settings.sslMode)
        #expect(model.canConnect)
        #expect(model.connectionState == .disconnected)
        #expect(model.errorMessage?.contains(settings.password) == false)
        await model.shutdown()
    }

    @MainActor
    @Test func invalidBootstrapDisplaysGenericErrorWithoutConnecting() async {
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        command = json.loads(sys.stdin.readline())
        print(json.dumps({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':5}), flush=True)
        command = json.loads(sys.stdin.readline())
        assert command['type'] == 'shutdown'
        print(json.dumps({'type':'shutdown.ack','requestId':command['requestId']}), flush=True)
        """])
        let model = WorkspaceModel(helperFactory: { client })
        await model.start(startupConnection: .failure(.invalid))
        #expect(model.errorMessage == StartupConnection.InputError.invalid.localizedDescription)
        #expect(model.connectionState == .disconnected)
        #expect(model.canConnect)
        await model.shutdown()
        #expect(await client.waitForExit().status == 0)
    }
}
