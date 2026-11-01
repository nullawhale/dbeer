import Foundation
import Testing
@testable import DBeer

/// Wire values and isolated protocol subprocesses only. No application, windows,
/// file choosers or database sessions. Subprocess files contain counts only.
struct TableImportProtocolTests {
    private var fingerprint: String { String(repeating: "a", count: 64) }
    private var request: TableImportRequest {
        TableImportRequest(schema: "public", table: "import_fixture", fingerprint: fingerprint,
            columns: ["value"], rows: [[ChangeValue(kind: "text", value: "exact synthetic value")]])
    }

    private func helper(capability: Bool = true, body: String = "", arguments: [String] = []) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, os, sys
        def read(): return json.loads(sys.stdin.readline())
        def send(value): print(json.dumps(value), flush=True)
        def started(command):
            send(dict(type='query.started', requestId=command['requestId'], sessionId=command['sessionId'], queryId=command['queryId']))
        hello = read()
        send(dict(type='hello.ack',requestId=hello['requestId'],protocolVersion=\(BackendProtocol.version),
            capabilities=['tableImportV1'] if \(capability ? "True" : "False") else []))
        \(body)
        """] + arguments)
    }

    private var rejectionHelperBody: String {
        """
        for line in sys.stdin:
            command = json.loads(line)
            if command['type'] == 'disconnect':
                send(dict(type='disconnect.ack',requestId=command['requestId'],sessionId=command['sessionId']))
            elif command['type'] == 'shutdown':
                send(dict(type='shutdown.ack',requestId=command['requestId']))
                break
            else:
                sys.exit(71)
        """
    }

    private func assertNotRegistered(_ command: BackendCommand, client: BackendClient, error: BackendRequestError) async throws {
        await #expect(throws: error) { _ = try await client.request(command) }
        // A locally rejected command must not reserve its ID or write a frame.
        // The child exits if any command besides disconnect/shutdown arrives.
        var reusable = BackendCommand.disconnect(sessionId: "import-session")
        reusable = BackendCommand(type: reusable.type, requestId: command.requestId, sessionId: reusable.sessionId)
        #expect(try await client.request(reusable).type == "disconnect.ack")
    }

    @Test func sharedFixtureRoundTripsCommandsAndValidatesEveryTerminalShape() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            repository.appendingPathComponent("protocol/fixtures/table-import-v1.json"))) as? [String: Any])
        #expect(fixture["capability"] as? String == "tableImportV1")
        var commands: [String: BackendCommand] = [:]
        for key in ["describe", "preview", "apply", "assessment"] {
            let object = try #require(fixture[key])
            let command = try JSONDecoder().decode(BackendCommand.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command)) == command)
            commands[key] = command
        }
        #expect(commands["describe"]?.tableImport?.valid(for: "import.describe") == true)
        #expect(commands["preview"]?.tableImport == commands["apply"]?.tableImport)
        #expect(commands["assessment"]?.operations?.first?.tableImport == commands["apply"]?.tableImport)
        let rows = try #require(commands["apply"]?.tableImport?.rows)
        #expect(rows[0][0] == ChangeValue(kind: "text", value: "NULL") && rows[0][2] == .null)
        #expect(rows[1][0] == ChangeValue(kind: "text", value: "") && rows[1][1] == ChangeValue(kind: "binary", value: ""))
        for key in ["describeResult", "previewResult", "applyResult", "rowError", "unknownCommit"] {
            let object = try #require(fixture[key])
            let reply = try NDJSONFramer.decode(JSONSerialization.data(withJSONObject: object))
            if key == "rowError" { #expect(reply.tableImport?.row == 2 && reply.outcomeUnknown == false) }
            if key == "unknownCommit" { #expect(reply.outcomeUnknown == true && reply.connected == false) }
        }
    }

    @Test func requestDecoderRejectsUnknownFieldsNullPayloadsAndInvalidTypedCells() throws {
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let malformed: [[String: Any]] = [
            ["schema": ""], ["table": "bad\0name"], ["fingerprint": String(repeating: "A", count: 64)],
            ["columns": ["same", "same"], "rows": [[ ["kind": "null"], ["kind": "null"] ]]],
            ["rows": []], ["rows": NSNull()], ["rows": [[ ["kind": "default"] ]]],
            ["rows": [[ ["kind": "null", "value": NSNull()] ]]],
            ["rows": [[ ["kind": "text", "value": NSNull()] ]]],
            ["rows": [[ ["kind": "text", "value": 42] ]]],
            ["rows": [[ ["kind": "text", "value": "x", "extra": true] ]]],
            ["rows": [[ ["kind": "text", "value": "x\0y"] ]]],
            ["rows": [[ ["kind": "binary", "value": "AB=="] ]]],
            ["rows": [[ ["kind": "text", "value": "x"], ["kind": "text", "value": "y"] ]]],
            ["unexpected": true],
        ]
        for mutation in malformed {
            let object = original.merging(mutation) { _, newer in newer }
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(TableImportRequest.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }
        #expect(TableImportRequest(schema: "public", table: "target").valid(for: "import.describe"))
        #expect(!request.valid(for: "import.describe") && !request.valid(for: "execute"))
    }

    @Test func requestBoundsCoverRowsColumnsCellsExactUtf8NamesAndValueBytes() {
        var value = request
        value.rows = Array(repeating: [.null], count: 10_000)
        #expect(value.valid(for: "import.apply"))
        value.rows?.append([.null])
        #expect(!value.valid(for: "import.apply"))
        value = request
        value.columns = (0..<256).map { "column_\($0)" }
        value.rows = [Array(repeating: .null, count: 256)]
        #expect(value.valid(for: "import.preview"))
        value.columns?.append("extra"); value.rows?[0].append(.null)
        #expect(!value.valid(for: "import.preview"))
        value.columns = (0..<10).map { "column_\($0)" }
        value.rows = Array(repeating: Array(repeating: .null, count: 10), count: 10_000)
        #expect(value.valid(for: "import.apply"))
        value.columns?.append("extra")
        value.rows = Array(repeating: Array(repeating: .null, count: 11), count: 10_000)
        #expect(!value.valid(for: "import.apply"))
        value = request
        value.columns = ["é", "e\u{301}"]
        value.rows = [[.null, .null]]
        #expect(value.valid(for: "import.apply"))
        value = request
        value.rows = [[ChangeValue(kind: "text", value: String(repeating: "x", count: TableImportRequest.maximumValueBytes))]]
        #expect(value.valid(for: "import.apply"))
        value.rows?[0][0].value?.append("x")
        #expect(!value.valid(for: "import.apply"))
    }

    @Test func malformedReplyPayloadsCannotMasqueradeAsSuccessfulImport() throws {
        let column: [String: Any] = ["name": "value", "nativeType": "text", "nullable": true, "hasDefault": false, "generated": false, "binary": false]
        let cases: [(String, [String: Any])] = [
            ("import.describe.result", ["columns": [column], "fingerprint": fingerprint, "rowCount": 1]),
            ("import.describe.result", ["columns": [column, column], "fingerprint": fingerprint]),
            ("import.preview.result", ["fingerprint": fingerprint, "rowCount": 0, "sql": "INSERT"]),
            ("import.preview.result", ["fingerprint": fingerprint, "rowCount": 1, "sql": ""]),
            ("import.preview.result", ["fingerprint": fingerprint, "rowCount": 1, "sql": "INSERT", "unknown": true]),
            ("import.apply.result", ["rowCount": 10_001]),
            ("import.apply.result", ["rowCount": 1, "row": 1]),
            ("query.result", ["rowCount": 1]),
        ]
        for (type, payload) in cases {
            let reply: [String: Any] = ["type": type, "requestId": "reply", "sessionId": "import-session",
                "queryId": "query", "connected": true, "transactionStatus": "idle", "tableImport": payload]
            #expect(throws: BackendTransportError.self) { try NDJSONFramer.decode(JSONSerialization.data(withJSONObject: reply)) }
        }
    }

    @Test func missingCapabilityRejectsEveryImportEntryPointBeforeRegistrationOrWriting() async throws {
        let client = helper(capability: false, body: rejectionHelperBody)
        try await client.start()
        #expect(await client.supportsTableImport() == false)
        let describe = TableImportRequest(schema: "public", table: "target")
        var settings = ConnectionSettings(host: "localhost", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable")
        settings.sessionPurpose = "import"
        let commands: [BackendCommand] = [BackendCommand.tableImport("describe", sessionId: "import-session", request: describe),
            .tableImport("preview", sessionId: "import-session", request: request),
            .tableImport("apply", sessionId: "import-session", request: request),
            .assess(sessionId: "import-session", operations: [OperationRequest(type: "import.apply", tableImport: request)]), .connect(settings)]
        for command in commands { try await assertNotRegistered(command, client: client, error: .unsupportedTableImport) }
        #expect(await client.shutdown().acknowledged)
    }

    @Test func invalidImportCommandsAndAssessmentPayloadsAreRejectedWithoutWriting() async throws {
        let client = helper(body: rejectionHelperBody)
        try await client.start()
        var badTarget = request; badTarget.table = ""
        var badValue = request; badValue.rows = [[ChangeValue(kind: "binary", value: "not Base64")]]
        var foreign = BackendCommand.execute(sessionId: "import-session", sql: "SELECT 1"); foreign.tableImport = request
        var mixed = BackendCommand.tableImport("preview", sessionId: "import-session", request: request); mixed.sql = "SELECT 1"
        let commands: [BackendCommand] = [.tableImport("preview", sessionId: "import-session", request: badTarget),
            .tableImport("apply", sessionId: "import-session", request: badValue), foreign, mixed,
            .assess(sessionId: "import-session", operations: [OperationRequest(type: "execute", tableImport: request)]),
            .assess(sessionId: "import-session", operations: [OperationRequest(type: "import.apply", sql: "SELECT 1", tableImport: request)])]
        for command in commands { try await assertNotRegistered(command, client: client, error: .invalidCommand) }
        #expect(await client.shutdown().acknowledged)
    }

    @Test(arguments: ["fingerprint", "rowCount", "missingStarted"])
    func mismatchedPreviewTerminalInvalidatesTransport(_ mismatch: String) async throws {
        let client = helper(body: """
        command = read()
        if sys.argv[1] != 'missingStarted': started(command)
        payload = dict(fingerprint=command['tableImport']['fingerprint'],rowCount=len(command['tableImport']['rows']),sql='INSERT INTO fixture VALUES ($1)')
        if sys.argv[1] == 'fingerprint': payload['fingerprint'] = 'b' * 64
        if sys.argv[1] == 'rowCount': payload['rowCount'] += 1
        send(dict(type='import.preview.result',requestId=command['requestId'],sessionId=command['sessionId'],queryId=command['queryId'],
            connected=True,transactionStatus='idle',tableImport=payload))
        sys.stdin.read()
        """, arguments: [mismatch])
        try await client.start()
        do {
            _ = try await client.request(.tableImport("preview", sessionId: "import-session", request: request))
            Issue.record("Mismatched import preview was accepted")
        } catch let error as BackendTransportError {
            #expect(error.code == .invalidMessage && !error.outcomeUnknown)
        }
        #expect(await client.shutdown().forced)
    }

    @Test func transportLossDuringApplyKeepsUnknownOutcomeAndDoesNotRetry() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/table-import/protocol/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let countFile = directory.appendingPathComponent("counts.json")
        let client = helper(body: """
        command = read()
        if command['type'] != 'import.apply': sys.exit(72)
        with open(sys.argv[1], 'w') as handle: json.dump(dict(applies=1),handle)
        started(command)
        sys.exit(37)
        """, arguments: [countFile.path])
        try await client.start()
        do {
            _ = try await client.request(.tableImport("apply", sessionId: "import-session", request: request))
            Issue.record("Lost import transport returned success")
        } catch let error as BackendTransportError { #expect(error.outcomeUnknown) }
        #expect(await client.waitForExit().status == 37)
        _ = await client.shutdown()
        let counts = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: countFile)) as? [String: Int])
        #expect(counts == ["applies": 1])
    }
}
