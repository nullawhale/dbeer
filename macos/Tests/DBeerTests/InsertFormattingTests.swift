import Foundation
import Testing
@testable import DBeer

/// Exercises wire values and helper subprocesses only; no app or windows open.
struct InsertFormattingTests {
    private struct Fixture: Decodable {
        struct Case: Codable { let command: BackendCommand; let response: BackendMessage }
        let version: Int
        let capability: String
        let cases: [Case]
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/copy-inserts-v1/cases.json")))
    }

    @Test func sharedOfflineRequestsAndRepliesKeepTypedValuesAndExactDigits() throws {
        let fixture = try fixture()
        #expect(fixture.version == 1 && fixture.capability == "formatInsertsV1")
        for item in fixture.cases {
            #expect(item.command.type == "formatInserts" && item.command.terminalType == "insertSQL")
            #expect(item.command.sessionId == nil && item.command.queryId == nil && item.command.connection == nil)
            #expect(item.command.insert?.valid == true)
            let encoded = try JSONEncoder().encode(item.command)
            #expect(try JSONDecoder().decode(BackendCommand.self, from: encoded) == item.command)
            try item.response.validate()
            #expect(try NDJSONFramer.decode(JSONEncoder().encode(item.response)) == item.response)
            if let sql = item.response.sql, let request = item.command.insert {
                let script = SQLScriptParser.parse(sql, engine: request.engine)
                #expect(script.diagnostics.isEmpty)
                #expect(script.statements.count == request.rows.count)
            }
        }
        let request = try #require(fixture.cases.first?.command.insert)
        #expect(request.rows[0][1] == ChangeValue(kind: "text", value: "NULL"))
        #expect(request.rows[0][2] == .null)
        #expect(request.rows[0][3] == ChangeValue(kind: "text", value: ""))
        #expect(request.rows[0][4] == .default)
        #expect(request.rows[0][5] == ChangeValue(kind: "binary", value: "AP+A"))
        #expect(request.rows[0][6].value == "9007199254740993.12345678901234567890")
        #expect(fixture.cases[0].response.sql?.contains("9007199254740993.12345678901234567890") == true)
        #expect(fixture.cases[1].response.sql?.contains("CONVERT(X'") == true)
    }

    @Test func requestValidationRejectsMalformedMappingsAndTypedCells() throws {
        var request = try #require(fixture().cases.first?.command.insert)
        request.columns[1].name = request.columns[0].name
        #expect(!request.valid)
        request.columns[1].name = "other"
        request.rows[0][1] = ChangeValue(kind: "null", value: "NULL")
        #expect(!request.valid)
        request.rows[0][1] = ChangeValue(kind: "binary", value: "!!!")
        #expect(!request.valid)
        request.rows[0][1] = .null
        request.rows[0].removeLast()
        #expect(!request.valid)
        request = InsertFormatRequest(engine: .mysql, schema: "", table: "target",
            columns: [InsertFormatColumn(name: "é"), InsertFormatColumn(name: "e\u{301}")], rows: [[.null, .default]])
        #expect(request.valid) // Target identifiers preserve their original UTF-8.
        request.engine = .cassandra
        #expect(!request.valid)
        request.engine = .postgresql
        request.table = "bad\0table"
        #expect(!request.valid)
    }

    @Test func insertRepliesRequireBoundedSQLAndNoSessionIdentity() throws {
        for raw in [
            #"{"type":"insertSQL","requestId":"copy"}"#,
            #"{"type":"insertSQL","requestId":"copy","sql":""}"#,
            #"{"type":"insertSQL","requestId":"copy","sql":"SQL","sessionId":"live"}"#,
            #"{"type":"insertSQL","requestId":"copy","sql":"SQL","queryId":"query"}"#,
            #"{"type":"insertSQL","requestId":"copy","sql":"SQL","sql":"changed"}"#,
            #"{"type":"shutdown.ack","requestId":"copy","sql":"SQL"}"#
        ] {
            #expect(throws: BackendTransportError(.invalidMessage)) { _ = try NDJSONFramer.decode(Data(raw.utf8)) }
        }
        let oversized = BackendMessage(type: "insertSQL", requestId: "copy", sql: String(repeating: "x", count: InsertFormatRequest.maximumBytes + 1))
        #expect(throws: BackendTransportError(.invalidMessage)) { try oversized.validate() }
    }

    private func client(_ body: String) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        def read():
            return json.loads(sys.stdin.readline())
        def send(value):
            print(json.dumps(value), flush=True)
        \(body)
        """])
    }

    @Test func missingCapabilityRejectsBeforeWritingAnyRequest() async throws {
        let client = client("""
        command = read()
        send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':5})
        command = read()
        assert command['type'] == 'shutdown'
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """)
        try await client.start()
        #expect(await client.supportsInsertFormatting() == false)
        let request = try #require(fixture().cases.first?.command.insert)
        await #expect(throws: BackendTransportError(.unsupportedInsertFormatting)) {
            _ = try await client.request(.formatInserts(request))
        }
        #expect(await client.shutdown().acknowledged)
        #expect(await client.waitForExit().status == 0)
    }

    @Test func capableHelperFormatsWithoutAnyConnectionRequest() async throws {
        let client = client("""
        command = read()
        send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':5,'capabilities':['formatInsertsV1']})
        command = read()
        assert command['type'] == 'formatInserts'
        assert 'sessionId' not in command and 'queryId' not in command and 'connection' not in command
        send({'type':'insertSQL','requestId':command['requestId'],'sql':'INSERT INTO "target" ("value") VALUES (NULL);'})
        command = read()
        assert command['type'] == 'shutdown'
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """)
        try await client.start()
        #expect(await client.supportsInsertFormatting())
        let request = InsertFormatRequest(engine: .postgresql, schema: "", table: "target",
            columns: [InsertFormatColumn(name: "value")], rows: [[.null]])
        let response = try await client.request(.formatInserts(request))
        #expect(response.type == "insertSQL" && response.sql == #"INSERT INTO "target" ("value") VALUES (NULL);"#)
        #expect(await client.shutdown().acknowledged)
        #expect(await client.waitForExit().status == 0)
    }

    @Test func helperDeathDuringFormattingHasNoUnknownSQLOutcome() async throws {
        let client = client("""
        command = read()
        send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':5,'capabilities':['formatInsertsV1']})
        command = read()
        assert command['type'] == 'formatInserts'
        sys.exit(23)
        """)
        try await client.start()
        let request = InsertFormatRequest(engine: .postgresql, schema: "", table: "target",
            columns: [InsertFormatColumn(name: "value")], rows: [[.null]])
        do {
            _ = try await client.request(.formatInserts(request))
            Issue.record("Formatter helper exit must fail the pending request.")
        } catch let error as BackendTransportError {
            #expect(!error.outcomeUnknown)
            #expect(error.code == .unexpectedEOF || error.code == .processExited(23))
        }
        _ = await client.shutdown()
    }
}
