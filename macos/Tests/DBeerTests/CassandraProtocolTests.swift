import Foundation
import Testing
@testable import DBeer

struct CassandraProtocolTests {
    @Test func sharedGridFixtureRetainsCassandraSnapshotTypes() throws {
        struct Fixture: Decodable { let commands: [BackendCommand]; let responses: [BackendMessage] }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: repository.appendingPathComponent("protocol/fixtures/contract-v4.json")))
        let command = try #require(fixture.commands.first { $0.requestId == "cassandra-grid-preview" })
        #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command)) == command)
        #expect(command.changes?.columns.allSatisfy { $0.engine == .cassandra } == true)
        let original = try #require(command.changes?.changes.first?.original)
        #expect(original[1] == .null && original[2] == ChangeValue(kind: "binary", value: "AAH/"))
        #expect(original[3].value == "9007199254740993.123456789")
        let response = try #require(fixture.responses.first { $0.requestId == "cassandra-grid-applied" })
        try response.validate()
        #expect(response.affectedRowCountKnown == true && response.rowCount == 1 && response.transactionStatus == .unsupported)
        #expect(response.appliedChangeCount == 1)
        let unknown = try #require(fixture.responses.first { $0.requestId == "cassandra-grid-atomic-unknown" })
        try unknown.validate()
        #expect(unknown.appliedChangeCount == nil && unknown.outcomeUnknown == true)
        let conflict = try #require(fixture.responses.first { $0.requestId == "cassandra-grid-atomic-conflict" })
        try conflict.validate()
        #expect(conflict.appliedChangeCount == 0 && conflict.outcomeUnknown == false)
        var invalid = unknown
        invalid.appliedChangeCount = -1
        #expect(throws: BackendTransportError(.invalidMessage)) { try invalid.validate() }
        invalid.appliedChangeCount = 1001
        #expect(throws: BackendTransportError(.invalidMessage)) { try invalid.validate() }
    }
    @Test func settingsPreserveLegacyDefaultsAndCassandraOptions() throws {
        let legacy = Data(#"{"host":"localhost","port":5432,"database":"db","user":"u","password":"","sslMode":"disable"}"#.utf8)
        let old = try JSONDecoder().decode(ConnectionSettings.self, from: legacy)
        #expect(old.engine == .postgresql)
        #expect(old.contactPoints == nil && old.localDatacenter == nil && old.consistency == nil)
        let settings = ConnectionSettings(host: "", port: 9042, database: "", user: "", password: "",
            sslMode: "verify-full", engine: .cassandra, contactPoints: ["node1", "node2"], localDatacenter: "dc1")
        #expect(settings.consistency == "LOCAL_QUORUM")
        #expect(try JSONDecoder().decode(ConnectionSettings.self, from: JSONEncoder().encode(settings)) == settings)
        #expect(DatabaseEngine.cassandra.defaultPort == 9042)
    }

    @Test func cassandraResultsPreserveUnknownAffectedCountAndCursor() throws {
        let frame = Data(#"{"type":"query.result","requestId":"r","sessionId":"s","queryId":"q","transactionStatus":"unsupported","durationMs":1,"columns":[],"rows":[],"commandTag":"UPDATE","rowCount":0,"displayedRowCount":0,"truncated":false,"affectedRowCountKnown":false,"nextCursor":"opaque"}"#.utf8)
        let result = try NDJSONFramer.decode(frame)
        #expect(result.transactionStatus == .unsupported)
        #expect(result.affectedRowCountKnown == false)
        #expect(result.rowCount == 0 && result.nextCursor == "opaque")
        var invalid = result
        invalid.nextCursor = String(repeating: "a", count: 129)
        #expect(throws: BackendTransportError(.invalidMessage)) { try invalid.validate() }
    }
    @Test func acknowledgedWriteDeliveryFailureIsCompletedWithoutExportPublication() throws {
        let frame = Data(#"{"type":"error","requestId":"r","sessionId":"s","queryId":"q","transactionStatus":"unsupported","category":"result","message":"Cassandra confirmed completion, but local result delivery failed.","connected":true,"outcomeUnknown":false,"sqlCompleted":true}"#.utf8)
        let reply = try NDJSONFramer.decode(frame)
        #expect(reply.sqlCompleted == true && reply.outcomeUnknown == false && reply.exportPublication == nil)
        var unknown = reply
        unknown.outcomeUnknown = true
        #expect(throws: BackendTransportError(.invalidMessage)) { try unknown.validate() }
        var notExecuted = reply
        notExecuted.sqlNotExecuted = true
        #expect(throws: BackendTransportError(.invalidMessage)) { try notExecuted.validate() }
        var invalidPublication = reply
        invalidPublication.exportPublication = "published"
        #expect(throws: BackendTransportError(.invalidMessage)) { try invalidPublication.validate() }
    }

}
