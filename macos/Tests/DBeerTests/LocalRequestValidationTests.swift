import Foundation
import Testing
@testable import DBeer

@MainActor
struct LocalRequestValidationTests {
    private func helper() -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        def read():
            return json.loads(sys.stdin.readline())
        def send(message):
            print(json.dumps(message), flush=True)
        command = read()
        send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':4})
        command = read()
        send({'type':'connect.result','engine':'postgresql','capabilities':['execute','cancel','transactions'],'requestId':command['requestId'],'sessionId':'same-session','transactionStatus':'transaction'})
        command = read()
        if command['type'] != 'execute' or command['sql'] != 'SELECT 2' or command['sessionId'] != 'same-session':
            sys.exit(40)
        send({'type':'query.started','requestId':command['requestId'],'sessionId':command['sessionId'],'queryId':command['queryId']})
        send({'type':'query.result','requestId':command['requestId'],'sessionId':command['sessionId'],'queryId':command['queryId'],
              'durationMs':1,'columns':[{'index':0,'name':'value','typeOid':23}],'rows':[['2']],
              'commandTag':'SELECT 1','rowCount':1,'displayedRowCount':1,'truncated':False,'transactionStatus':'transaction'})
        command = read()
        if command['type'] != 'shutdown':
            sys.exit(41)
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """])
    }

    @Test func oversizedCommandIsRejectedBeforeRegistrationOrWriting() async throws {
        let client = helper()
        try await client.start()
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "fixture",
            user: "fixture", password: "", sslMode: "disable")
        _ = try await client.request(.connect(settings))
        var command = BackendCommand.execute(sessionId: "same-session",
            sql: String(repeating: "a", count: BackendProtocol.maxFrameBytes))
        let (events, continuation) = AsyncStream.makeStream(of: BackendMessage.self)
        await #expect(throws: BackendRequestError.frameTooLarge) {
            _ = try await client.request(command) { continuation.yield($0) }
        }

        // A rejected command did not consume this request ID. The fixture
        // expects its first execute frame to be this small statement only.
        command.sql = "SELECT 2"
        let reply = try await client.request(command) { continuation.yield($0) }
        continuation.finish()
        var received: [BackendMessage] = []
        for await event in events { received.append(event) }
        #expect(received.map(\.type) == ["query.started"])
        #expect(reply.rows == [["2"]])
        #expect(await client.shutdown().acknowledged)
        #expect(await client.waitForExit().status == 0)
    }

    @Test func oversizedSQLPreservesSessionAndAllowsTheNextRunWithoutReconnectOrReplay() async {
        let client = helper()
        var launches = 0
        let model = WorkspaceModel(helperFactory: { launches += 1; return client })
        await model.start()
        await model.connect()
        model.sql = String(repeating: "a", count: BackendProtocol.maxFrameBytes)
        await model.run()

        #expect(model.sessionId == "same-session")
        #expect(model.connectionState == .connected)
        #expect(model.transactionStatus == .transaction)
        if case .ready = model.state {} else { Issue.record("Local validation must keep the helper ready.") }
        #expect(model.queryPhase == .idle && !model.isExecuting)
        #expect(model.queryFailure?.category == "validation")
        #expect(model.queryFailure?.outcomeUnknown == false)
        #expect(model.errorMessage?.contains("command was not sent") == true)
        #expect(model.errorMessage?.contains("outcome is unknown") == false)
        let canRunAfterRejection = model.canRun
        #expect(canRunAfterRejection)

        model.sql = "SELECT 2"
        await model.run()
        #expect(model.result?.rows == [["2"]])
        #expect(model.sessionId == "same-session")
        #expect(model.queryFailure == nil && model.errorMessage == nil)
        #expect(launches == 1)
        await model.shutdown()
        #expect(await client.waitForExit().status == 0)
    }
}
