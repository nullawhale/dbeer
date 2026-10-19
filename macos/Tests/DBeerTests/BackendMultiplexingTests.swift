import Foundation
import Testing
@testable import DBeer

struct BackendMultiplexingTests {
    private func helper(_ body: String) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time
        def read():
            return json.loads(sys.stdin.readline())
        def send(message):
            print(json.dumps(message), flush=True)
        def started(command):
            send({'type':'query.started','requestId':command['requestId'],'sessionId':command['sessionId'],'queryId':command['queryId']})
        def result(command):
            send({'type':'query.result','requestId':command['requestId'],'sessionId':command['sessionId'],'queryId':command['queryId'],
                  'columns':[{'index':0,'name':'session','engine':'postgresql','nativeType':'text','typeOid':25}],
                  'rows':[[command['sessionId']]],'durationMs':1,'rowCount':1,'displayedRowCount':1,
                  'commandTag':'SELECT 1','truncated':False,'transactionStatus':'idle'})
        command = read()
        send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':3})
        \(body)
        """])
    }

    @Test func concurrentSessionsKeepEventsAndTerminalsCorrelatedWhenRepliesInterleave() async throws {
        let client = helper("""
        commands = [read(), read()]
        for command in reversed(commands):
            started(command)
        for command in reversed(commands):
            result(command)
        command = read()
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """)
        try await client.start()
        let first = BackendCommand.execute(sessionId: "session-a", queryId: "execution-a", sql: "SELECT 1")
        let second = BackendCommand.execute(sessionId: "session-b", queryId: "execution-b", sql: "SELECT 2")
        let (events, continuation) = AsyncStream.makeStream(of: BackendMessage.self)
        async let firstReply = client.request(first) { continuation.yield($0) }
        async let secondReply = client.request(second) { continuation.yield($0) }
        let replies = try await [firstReply, secondReply]
        continuation.finish()
        var received: [BackendMessage] = []
        for await event in events { received.append(event) }
        #expect(replies.map(\.requestId) == [first.requestId, second.requestId])
        #expect(replies.map(\.sessionId) == ["session-a", "session-b"])
        #expect(replies.map(\.queryId) == ["execution-a", "execution-b"])
        #expect(replies.map(\.rows) == [[["session-a"]], [["session-b"]]])
        #expect(Set(received.map(\.requestId)) == [first.requestId, second.requestId])
        #expect(received.count == 2)
        #expect(await client.shutdown().acknowledged)
    }

    @Test func helperDeathFailsEveryPendingExecutionWithUnknownOutcome() async throws {
        let client = helper("""
        commands = [read(), read(), read()]
        for command in commands:
            if command['type'] == 'execute':
                started(command)
        sys.exit(23)
        """)
        try await client.start()
        func failure(for command: BackendCommand) async -> BackendTransportError? {
            do {
                _ = try await client.request(command)
                Issue.record("Helper death must fail all pending requests.")
            } catch let error as BackendTransportError { return error }
            catch { Issue.record("Expected a transport failure.") }
            return nil
        }
        async let first = failure(for: .execute(sessionId: "a", sql: "SELECT 1"))
        async let second = failure(for: .execute(sessionId: "b", sql: "SELECT 2"))
        async let disconnect = failure(for: .disconnect(sessionId: "c"))
        let failures = await [first, second, disconnect]
        #expect(failures[0]?.outcomeUnknown == true)
        #expect(failures[1]?.outcomeUnknown == true)
        #expect(failures[2]?.outcomeUnknown == false)
        #expect(await client.waitForExit().status == 23)
        _ = await client.shutdown()
    }

    @Test func wrongSessionIdentifierInvalidatesTheEntireTransport() async throws {
        let client = helper("""
        command = read()
        send({'type':'query.started','requestId':command['requestId'],'sessionId':'wrong-session','queryId':command['queryId']})
        time.sleep(10)
        """)
        try await client.start()
        do {
            _ = try await client.request(.execute(sessionId: "expected-session", sql: "SELECT 1"))
            Issue.record("A reply from a different session must not reach the caller.")
        } catch let error as BackendTransportError {
            #expect(error.code == .invalidMessage)
            #expect(error.outcomeUnknown)
        }
        #expect(await client.shutdown().forced)
    }

    @Test func connectionReplyRequiresV2AdapterMetadataAndBinaryColumnsCarryEncoding() throws {
        let missing = Data("""
        {"type":"connect.result","requestId":"request","sessionId":"session","transactionStatus":"idle"}
        """.utf8)
        #expect(throws: BackendTransportError(.invalidMessage)) { _ = try NDJSONFramer.decode(missing) }
        let complete = try NDJSONFramer.decode(Data("""
        {"type":"connect.result","requestId":"request","sessionId":"session","transactionStatus":"idle",
         "engine":"mysql","capabilities":["execute","cancel","transactions"]}
        """.utf8))
        #expect(complete.engine == .mysql)
        #expect(complete.capabilities?.contains("cancel") == true)
        let column = try JSONDecoder().decode(ResultColumn.self, from: Data("""
        {"index":0,"name":"bytes","engine":"mysql","nativeType":"BLOB","encoding":"base64"}
        """.utf8))
        #expect(column.engine == .mysql && column.typeOid == 0)
        #expect(column.encoding == "base64")
    }

    @Test func connectionReplyCannotChangeTheRequestedEngine() async throws {
        let client = helper("""
        command = read()
        send({'type':'connect.result','requestId':command['requestId'],'sessionId':'session','transactionStatus':'idle',
              'engine':'postgresql','capabilities':['execute']})
        time.sleep(10)
        """)
        try await client.start()
        let settings = ConnectionSettings(host: "localhost", port: 3306, database: "mysql", user: "root",
            password: "", sslMode: "disable", engine: .mysql)
        await #expect(throws: BackendTransportError(.invalidMessage)) { _ = try await client.request(.connect(settings)) }
        #expect(await client.shutdown().forced)
    }
}
