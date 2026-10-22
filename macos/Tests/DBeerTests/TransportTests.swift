import Foundation
import Testing
@testable import DBeer

private let repositoryURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

struct ProtocolFixtureTests {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: repositoryURL.appendingPathComponent("protocol/fixtures/\(name).ndjson"))
    }

    @Test func sharedCommandsRoundTripWithoutChangingShape() throws {
        for frame in try fixture("commands").split(separator: 0x0A) {
            let data = Data(frame)
            let command = try JSONDecoder().decode(BackendCommand.self, from: data)
            let encoded = try JSONEncoder().encode(command)
            #expect(try (JSONSerialization.jsonObject(with: data) as! NSDictionary) ==
                    (JSONSerialization.jsonObject(with: encoded) as! NSDictionary))
        }
    }

    @Test func sharedRepliesRoundTripAndPreserveNULLAndPrecision() throws {
        let messages = try fixture("responses").split(separator: 0x0A).map { try NDJSONFramer.decode(Data($0)) }
        for message in messages {
            #expect(try NDJSONFramer.decode(JSONEncoder().encode(message)) == message)
        }
        let result = try #require(messages.first { $0.type == "query.result" })
        #expect(result.columns?.map(\.name) == ["x", "x", "precise"])
        #expect(result.rows?[0][0] == nil)
        #expect(result.rows?[0][1] == "")
        #expect(result.rows?[1][0] == "NULL")
        #expect(result.rows?[0][2] == "9007199254740993.123456789")
        #expect(result.rows?[1][1] == "κόσμος 🌍\nline")
    }

    @Test func partialAndCoalescedReadsIncludingSplitUTF8Scalars() throws {
        let data = try fixture("responses")
        let expected: [Data] = data.split(separator: 0x0A)
        for chunkSize in 1...31 {
            var framer = NDJSONFramer()
            var actual: [Data] = []
            for offset in stride(from: 0, to: data.count, by: chunkSize) {
                actual += try framer.append(data.subdata(in: offset..<min(offset + chunkSize, data.count)))
            }
            try framer.finish()
            #expect(actual == expected)
            for frame in actual { _ = try NDJSONFramer.decode(frame) }
        }
        var framer = NDJSONFramer()
        #expect(try framer.append(data) == expected)
    }

    @Test func frameLimitExcludesNewlineAndBoundsUnterminatedInput() throws {
        var framer = NDJSONFramer()
        let limit = BackendProtocol.maxFrameBytes
        #expect(try framer.append(Data(repeating: 0x61, count: limit)).isEmpty)
        let frames = try framer.append(Data([0x0A]))
        #expect(frames.count == 1)
        #expect(frames[0].count == limit)
        #expect(throws: BackendTransportError(.frameTooLarge)) {
            _ = try framer.append(Data(repeating: 0x61, count: limit + 1))
        }
    }

    @Test func incompleteInvalidUTF8AndInvalidJSONAreTransportErrors() throws {
        var framer = NDJSONFramer()
        _ = try framer.append(Data("{\"type\":".utf8))
        #expect(throws: BackendTransportError(.unexpectedEOF)) { try framer.finish() }
        #expect(throws: BackendTransportError(.invalidUTF8)) { _ = try NDJSONFramer.decode(Data([0xFF])) }
        #expect(throws: BackendTransportError(.invalidMessage)) { _ = try NDJSONFramer.decode(Data("not JSON".utf8)) }
        #expect(throws: BackendTransportError(.invalidMessage)) {
            _ = try NDJSONFramer.decode(Data("{\"type\":\"query.result\",\"requestId\":\"r\"}".utf8))
        }
    }
}

struct BackendClientTests {
    private func fake(_ body: String) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, os, sys, time
        def read():
            return json.loads(sys.stdin.readline())
        def send(message):
            print(json.dumps(message, ensure_ascii=False), flush=True)
        def hello():
            command = read()
            send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':5})
        \(body)
        """])
    }

    @Test func independentlyDrainsStderrBeforeHandshakeAndAcknowledgesShutdown() async throws {
        let client = fake("""
        sys.stderr.write('x' * 262144)
        sys.stderr.flush()
        hello()
        command = read()
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """)
        try await client.start()
        let result = await client.shutdown()
        #expect(result.acknowledged)
        #expect(!result.forced)
        #expect(await client.stderrBytesRead() == 262144)
        #expect(await client.waitForExit().status == 0)
    }

    @Test func incompatibleVersionFailsHandshake() async throws {
        let client = fake("""
        command = read()
        send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':1})
        """)
        await #expect(throws: BackendTransportError(.incompatibleVersion(1))) { try await client.start() }
        _ = await client.shutdown()
    }

    @Test func EOFWithPartialFrameFailsWithoutWaitingForProcessExit() async throws {
        let client = fake("""
        read()
        sys.stdout.write('{"type":')
        sys.stdout.flush()
        os.close(1)
        time.sleep(10)
        """)
        await #expect(throws: BackendTransportError(.unexpectedEOF)) { try await client.start() }
        #expect(await client.shutdown().forced)
    }

    @Test func processDeathFailsActiveSQLWithUnknownOutcome() async throws {
        let client = fake("""
        hello()
        command = read()
        send({'type':'query.started','requestId':command['requestId'],'sessionId':command['sessionId'],'queryId':command['queryId']})
        sys.exit(23)
        """)
        try await client.start()
        let (events, continuation) = AsyncStream.makeStream(of: BackendMessage.self)
        let command = BackendCommand.execute(sessionId: "session", sql: "SELECT 1")
        do {
            _ = try await client.request(command) { continuation.yield($0) }
            Issue.record("A process exit must not satisfy an execute request.")
        } catch let error as BackendTransportError {
            #expect(error.outcomeUnknown)
            #expect(error.code == .unexpectedEOF || error.code == .processExited(23))
        }
        continuation.finish()
        var received: [BackendMessage] = []
        for await event in events { received.append(event) }
        #expect(received.map(\.type) == ["query.started"])
        #expect(await client.waitForExit().status == 23)
        _ = await client.shutdown()
    }

    @Test func wrongRequestIdentifierInvalidatesTransport() async throws {
        let client = fake("""
        read()
        send({'type':'hello.ack','requestId':'unrelated-request','protocolVersion':5})
        """)
        await #expect(throws: BackendTransportError(.invalidMessage)) { try await client.start() }
        _ = await client.shutdown()
    }

    @Test func closedCommandPipeThrowsInsteadOfSignallingTheApplication() async throws {
        let client = fake("""
        command = read()
        os.close(0)
        send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':5})
        time.sleep(10)
        """)
        try await client.start()
        await #expect(throws: BackendTransportError(.writeFailed)) {
            _ = try await client.request(.disconnect(sessionId: "session"))
        }
        _ = await client.shutdown()
    }

    @Test func remoteErrorsStayStructuredAndDoNotKillTransport() async throws {
        let client = fake("""
        hello()
        command = read()
        send({'type':'error','requestId':command['requestId'],'category':'connection','message':'Not connected 🌍','connected':False,'outcomeUnknown':False})
        command = read()
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """)
        try await client.start()
        do {
            _ = try await client.request(.connect(ConnectionSettings(host: "localhost", port: 5432,
                database: "fixture", user: "fixture", password: "fixture-only", sslMode: "disable")))
            Issue.record("Expected a structured remote error.")
        } catch let error as BackendRemoteError {
            #expect(error.reply.category == "connection")
            #expect(error.localizedDescription == "Not connected 🌍")
            #expect(error.reply.connected == false)
        }
        #expect(await client.shutdown().acknowledged)
    }

    @Test func shutdownKillsAnUnresponsiveHelperAfterTwoSeconds() async throws {
        let client = fake("""
        hello()
        read()
        time.sleep(10)
        """)
        try await client.start()
        let clock = ContinuousClock()
        let start = clock.now
        let result = await client.shutdown()
        #expect(!result.acknowledged)
        #expect(result.forced)
        #expect(start.duration(to: clock.now) < .seconds(4))
        #expect(await client.waitForExit().status == 9)
    }

    @Test func handshakeHasAFiveSecondDeadline() async throws {
        let client = fake("""
        read()
        time.sleep(10)
        """)
        await #expect(throws: BackendTransportError(.handshakeTimeout)) { try await client.start() }
        #expect(await client.shutdown().forced)
    }
}
