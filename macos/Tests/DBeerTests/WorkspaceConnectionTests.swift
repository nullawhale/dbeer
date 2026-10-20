import Foundation
import Testing
@testable import DBeer

@MainActor
struct WorkspaceConnectionTests {
    private func helper(_ body: String) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        def read():
            return json.loads(sys.stdin.readline())
        def send(message):
            print(json.dumps(message), flush=True)
        command = read()
        send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':4})
        \(body)
        """])
    }

    private var successfulSession: String {
        """
        while True:
            command = read()
            kind = command['type']
            if kind == 'connect':
                send({'type':'connect.result','engine':'postgresql','capabilities':['execute','cancel','transactions'],'requestId':command['requestId'],'sessionId':'test-session','transactionStatus':'idle'})
            elif kind == 'disconnect':
                send({'type':'disconnect.ack','requestId':command['requestId'],'sessionId':command['sessionId']})
            elif kind == 'shutdown':
                send({'type':'shutdown.ack','requestId':command['requestId']})
                break
        """
    }

    @Test func connectionOwnsSessionAndDisconnectReleasesForm() async {
        let client = helper(successfulSession)
        let model = WorkspaceModel(helperFactory: { client })
        await model.start()
        #expect(model.canConnect)
        #expect(model.canEditConnection)
        await model.connect()
        #expect(model.connectionState == .connected)
        #expect(model.sessionId == "test-session")
        #expect(model.transactionStatus == .idle)
        #expect(!model.canConnect)
        #expect(!model.canEditConnection)
        #expect(model.canDisconnect)
        await model.disconnect()
        #expect(model.connectionState == .disconnected)
        #expect(model.sessionId == nil)
        #expect(model.canEditConnection)
        await model.shutdown()
    }

    @Test func connectionErrorKeepsHelperReadyAndDisplaysSQLState() async {
        let client = helper("""
        command = read()
        send({'type':'error','requestId':command['requestId'],'category':'connection','message':'PostgreSQL authentication failed.','sqlState':'28P01','connected':False,'outcomeUnknown':False})
        command = read()
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """)
        let model = WorkspaceModel(helperFactory: { client })
        model.password = "fixture-password"
        await model.start()
        await model.connect()
        #expect(model.connectionState == .disconnected)
        #expect(model.canConnect)
        #expect(model.errorMessage?.contains("28P01") == true)
        #expect(model.errorMessage?.contains(model.password) == false)
        await model.shutdown()
        #expect(model.password.isEmpty)
    }

    @Test func helperFailureRequiresNewProcessAndExplicitConnect() async {
        let failed = helper("read(); sys.exit(23)")
        let recovered = helper(successfulSession)
        var launches = 0
        let model = WorkspaceModel(helperFactory: {
            launches += 1
            return launches == 1 ? failed : recovered
        })
        await model.start()
        await model.connect()
        #expect(model.sessionId == nil)
        #expect(model.connectionState == .disconnected)
        #expect(model.canConnect)
        #expect(launches == 1)
        await model.connect()
        #expect(launches == 2)
        #expect(model.connectionState == .connected)
        #expect(model.errorMessage == nil)
        await model.shutdown()
    }

    @Test func invalidPortDoesNotSendConnectionCommand() async {
        let client = helper("""
        command = read()
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """)
        let model = WorkspaceModel(helperFactory: { client })
        await model.start()
        model.port = "65536"
        await model.connect()
        #expect(model.errorMessage?.contains("65535") == true)
        #expect(model.connectionState == .disconnected)
        await model.shutdown()
        #expect(await client.waitForExit().status == 0)
    }

    @Test func processExitInvalidatesAJustConnectedSession() async throws {
        let client = helper("""
        command = read()
        send({'type':'connect.result','engine':'postgresql','capabilities':['execute','cancel','transactions'],'requestId':command['requestId'],'sessionId':'test-session','transactionStatus':'idle'})
        sys.exit(23)
        """)
        let model = WorkspaceModel(helperFactory: { client })
        await model.start()
        await model.connect()
        _ = await client.waitForFailure()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while model.sessionId != nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.sessionId == nil)
        #expect(model.connectionState == .disconnected)
        #expect(model.canConnect)
        await model.shutdown()
    }
}
