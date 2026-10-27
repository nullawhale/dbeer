import Foundation
import Testing
@testable import DBeer

/// Wire checks use synthetic frames and subprocesses only. No app windows,
/// database sessions, Keychain, or global keyboard/mouse events are involved.
struct ResultComparisonProtocolTests {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            var name: String
            var mode: ResultComparisonMode
            var columns: [ResultComparisonColumnMapping]
            var leftColumns: [ResultColumn]
            var rightColumns: [ResultColumn]
            var leftRows: [[String?]]
            var rightRows: [[String?]]
        }
        var version: Int
        var capability: String
        var commands: [BackendCommand]
        var responses: [BackendMessage]
        var cases: [Case]
    }
    private func fixtureData() throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/result-comparison-v1.json"))
    }
    private func fixture() throws -> Fixture { try JSONDecoder().decode(Fixture.self, from: fixtureData()) }

    @Test func sharedManagedRequestsAndBoundedResponsesRoundTripWithoutResultRows() throws {
        let fixture = try fixture()
        #expect(fixture.version == BackendProtocol.version && fixture.capability == "resultComparisonV1")
        #expect(fixture.commands.count == 6 && fixture.responses.count == 6)
        for command in fixture.commands {
            #expect(command.comparison?.valid(for: command.type) == true)
            #expect(command.terminalType == command.type + ".result")
            #expect(command.connection == nil && command.sql == nil && command.sessionId == nil && command.queryId == nil)
            let data = try JSONEncoder().encode(command)
            #expect(data.count < 4_096)
            #expect(try JSONDecoder().decode(BackendCommand.self, from: data) == command)
        }
        for response in fixture.responses {
            try response.validate()
            #expect(try NDJSONFramer.decode(JSONEncoder().encode(response)) == response)
        }
        let start = try #require(fixture.commands.first?.comparison)
        #expect(start.left?.kind == "snapshot" && start.columns?.map(\.left) == [0, 1, 2, 3])
        let page = try #require(fixture.responses.first { $0.comparison?.page != nil }?.comparison?.page)
        #expect(page.rows.first?.cellsTruncated == true && page.rows.first?.nextCellOffset == 2)
        #expect(page.rows.first?.cells.first?.left?.totalBytes == 0)
        #expect(page.rows.first?.cells.first?.right?.preview == "NULL")
        #expect(fixture.responses.first { $0.comparison?.value != nil }?.comparison?.value?.text == "NULL")
    }

    @Test func sharedExactValueCasesPreserveDuplicateNamesNullPrecisionAndBinary() throws {
        let fixture = try fixture()
        let exact = try #require(fixture.cases.first { $0.name == "exact-key-values" })
        #expect(exact.leftColumns.map(\.name) == ["id", "same", "same", "binary"])
        #expect(exact.leftRows[0][1] == nil && exact.leftRows[1][1] == "" && exact.leftRows[2][1] == "NULL")
        #expect(exact.leftRows[0][2] == "9007199254740993.123456789")
        #expect(exact.leftRows[0][3] == "AP8=" && exact.leftColumns[3].encoding == "base64")
        #expect(exact.leftRows[1][2] == "1.00" && exact.rightRows[1][2] == "1.0")
        #expect(fixture.cases.contains { $0.name == "duplicate-keys" })
        let unresolved = try #require(fixture.cases.first { $0.name == "unresolved-local-oid-key" })
        #expect(unresolved.leftColumns[0].nativeType == "oid:42000")
    }

    @Test func requestsRejectImplicitMatchingDuplicateMappingsAndNonManagedReferences() throws {
        var request = try #require(fixture().commands.first?.comparison)
        request.mode = nil
        #expect(!request.valid(for: "compare.start"))
        request.mode = .rowOrder
        #expect(!request.valid(for: "compare.start"))
        request.mode = .key; request.columns?[0].key = nil
        #expect(!request.valid(for: "compare.start"))
        request.columns?[0].key = true; request.columns?[1].right = 0
        #expect(!request.valid(for: "compare.start"))
        request.columns?[1].right = 1; request.left?.id = "../../outside"
        #expect(!request.valid(for: "compare.start"))
        #expect(!ResultComparisonRequest(jobId: "job", offset: -1).valid(for: "compare.page"))
        #expect(!ResultComparisonRequest(jobId: "job", limit: 1_001).valid(for: "compare.page"))
        #expect(!ResultComparisonRequest(jobId: "job", maxBytes: 4_095).valid(for: "compare.page"))
        #expect(!ResultComparisonRequest(jobId: "job", maxBytes: 1_048_577, valueRef: "ref").valid(for: "compare.value"))
        #expect(!ResultComparisonRequest(jobId: "job", valueRef: "ref", cellOffset: 1).valid(for: "compare.value"))
    }

    @Test func malformedRepliesCannotHidePartialEqualityOrUnboundedPreviews() throws {
        let fixture = try fixture()
        var summaryReply = try #require(fixture.responses.first { $0.comparison?.summary != nil })
        summaryReply.comparison?.summary?.fullEquality = true
        #expect(throws: BackendTransportError(.invalidMessage)) { try summaryReply.validate() }
        summaryReply.comparison?.summary?.fullEquality = false
        summaryReply.comparison?.summary?.schemaDifferenceCount = 10
        #expect(throws: BackendTransportError(.invalidMessage)) { try summaryReply.validate() }
        var pageReply = try #require(fixture.responses.first { $0.comparison?.page != nil })
        pageReply.comparison?.page?.rows[0].cells[0].right?.preview = String(repeating: "x", count: 257)
        #expect(throws: BackendTransportError(.invalidMessage)) { try pageReply.validate() }
        var valueReply = try #require(fixture.responses.first { $0.comparison?.value != nil })
        valueReply.comparison?.value?.nextOffset = 3
        #expect(throws: BackendTransportError(.invalidMessage)) { try valueReply.validate() }
        valueReply = try #require(fixture.responses.first { $0.comparison?.value != nil })
        valueReply.sessionId = "sql-session"
        #expect(throws: BackendTransportError(.invalidMessage)) { try valueReply.validate() }
    }

    private func client(_ body: String) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import base64, json, sys
        def read(): return json.loads(sys.stdin.readline())
        def send(value): print(json.dumps(value), flush=True)
        \(body)
        """])
    }

    @Test func capabilityGateRejectsBeforeWritingAComparisonCommand() async throws {
        let client = client("""
        command = read()
        send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':5})
        command = read()
        assert command['type'] == 'shutdown'
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """)
        try await client.start()
        #expect(await client.supportsResultComparison() == false)
        let request = try #require(fixture().commands.first?.comparison)
        await #expect(throws: BackendTransportError(.unsupportedResultComparison)) {
            _ = try await client.request(.compare("start", request))
        }
        #expect(await client.shutdown().acknowledged)
        #expect(await client.waitForExit().status == 0)
    }

    @Test func capableHelperHandlesAllCommandsWithoutConnectionOrSQLRequests() async throws {
        let data = try fixtureData().base64EncodedString()
        let client = client("""
        fixture = json.loads(base64.b64decode('\(data)'))
        command = read()
        send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':5,'capabilities':['resultComparisonV1']})
        for expected, response in zip(fixture['commands'], fixture['responses']):
            command = read()
            assert command['type'] == expected['type'] and command['comparison'] == expected['comparison']
            assert 'sessionId' not in command and 'queryId' not in command and 'connection' not in command and 'sql' not in command
            response['requestId'] = command['requestId']
            send(response)
        command = read()
        assert command['type'] == 'shutdown'
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """)
        try await client.start()
        #expect(await client.supportsResultComparison())
        for command in try fixture().commands {
            let reply = try await client.request(command)
            #expect(reply.type == command.terminalType)
        }
        #expect(await client.shutdown().acknowledged)
        #expect(await client.waitForExit().status == 0)
    }

    @Test func aWrongJobIdentityInvalidatesTheHelperWithoutAnUnknownSQLOutcome() async throws {
        let client = client("""
        command = read()
        send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':5,'capabilities':['resultComparisonV1']})
        command = read()
        send({'type':'compare.cancel.result','requestId':command['requestId'],'comparison':{'jobId':'wrong-job','state':'cancelled'}})
        sys.stdin.read()
        """)
        try await client.start()
        do {
            _ = try await client.request(.compare("cancel", .init(jobId: "expected-job")))
            Issue.record("A reply for a different comparison must fail.")
        } catch let error as BackendTransportError {
            #expect(error.code == .invalidMessage && !error.outcomeUnknown)
        }
        _ = await client.shutdown()
    }
}
