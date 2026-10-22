import Foundation
import Testing
@testable import DBeer

/// Native v5 contract cases shared with Go; GPUI compatibility is deferred.
/// These cases only decode synthetic data; they do not execute SQL or exports.
struct GPUIContractFixturesTests {
    private struct Fixtures: Decodable {
        let version: Int
        let commands: [BackendCommand]
        let responses: [BackendMessage]
    }
    private func fixture() throws -> Fixtures {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf:
            repository.appendingPathComponent("protocol/fixtures/contract-v5.json")))
    }
    @Test func existingWireOperationsRetainTypedValuesAndAuthorization() throws {
        let data = try fixture()
        #expect(data.version == BackendProtocol.version)
        for command in data.commands {
            let encoded = try JSONEncoder().encode(command)
            #expect(try JSONDecoder().decode(BackendCommand.self, from: encoded) == command)
        }
        let apply = try #require(data.commands.first { $0.type == "changes.apply" })
        #expect(apply.authorization == "exact-ordered-grant")
        let changes = try #require(apply.changes?.changes)
        #expect(changes.count == 3)
        #expect(changes[0].original?[0].value == "9007199254740993")
        #expect(changes[0].original?[1].kind == "null")
        #expect(changes[0].values?[0].value.value == "")
        #expect(changes[1].values?[0].value.kind == "default")
        #expect(changes[1].values?[1].value.value == "NULL")
        #expect(changes[1].values?[2].value == ChangeValue(kind: "binary", value: ""))
        let browse = try #require(data.commands.first { $0.catalog?.kind == "browse" }?.catalog)
        #expect(data.commands.contains { $0.catalog?.kind == "clusterNodes" })
        #expect(browse.filters?.count == 10)
        #expect(browse.sort?.map(\.direction) == ["desc", "asc"])
        let batch = try #require(data.commands.first { $0.type == "operation.assess" }?.operations)
        #expect(batch.map(\.type) == ["execute", "changes.apply"])
        #expect(batch[0].export?.format == "json")
        let dynamic = try #require(data.commands.first { $0.requestId == "password-command-connect" }?.connection)
        #expect(dynamic.password.isEmpty && dynamic.hasValidNativeFields)
        #expect(dynamic.passwordCommand == PasswordCommand(executable: "/synthetic/token-cli",
            arguments: ["token", "--database", "app", "literal $HOME"]))
    }
    @Test func existingTerminalShapesRetainPartialSetsExportsAndTransactions() throws {
        let data = try fixture()
        for response in data.responses { try response.validate() }
        let nodes = try #require(data.responses.first { $0.requestId == "cassandra-cluster-nodes" })
        #expect(nodes.catalogRecords.map { $0["status"] } == ["UP", "DOWN", "UNKNOWN"])
        #expect(nodes.catalogRecords[1]["address"] == "[2001:db8::2]:9042")
        let results = try #require(data.responses.first { $0.requestId == "ordered-results" })
        #expect(results.resultSets?.count == 2)
        #expect(results.columns?[0].name == results.columns?[1].name)
        #expect(results.rows?[0] == [nil, "", "9007199254740993.123456789", "AP8="])
        let partial = try #require(data.responses.first { $0.type == "error" && $0.requestId == "partial" })
        #expect(partial.transactionStatus == .failedTransaction)
        #expect(partial.resultSets?.count == 1)
        #expect(partial.streamed == true)
        let export = try #require(data.responses.first { $0.exportPath != nil })
        #expect(export.exportRowCount == 1301)
        #expect(export.exportFormat == "json")
        let unknown = try #require(data.responses.first { $0.requestId == "apply-unknown" })
        #expect(unknown.outcomeUnknown == true)
        #expect(unknown.transactionStatus == nil)
    }

    @Test func sshContractKeepsDatabaseIdentitySeparateFromBastion() throws {
        let data = try fixture()
        let connect = try #require(data.commands.first { $0.requestId == "ssh-connect" })
        let settings = try #require(connect.connection)
        let tunnel = try #require(settings.ssh)
        #expect(settings.host == "db.internal.example")
        #expect(settings.sslMode == "verify-full")
        #expect(tunnel.host == "bastion.example")
        #expect(tunnel.port == 2222)
        #expect(tunnel.password == nil && tunnel.passphrase == nil)
        #expect(data.commands.first { $0.type == "ssh.trust" }?.sshTrust?.token == "synthetic-host-key-challenge")
        let unknown = try #require(data.responses.first { $0.type == "ssh.probe.result" }?.ssh)
        #expect(unknown.status == "unknown")
        #expect(unknown.challengeToken == "synthetic-host-key-challenge")
        let trusted = try #require(data.responses.first { $0.type == "ssh.trust.result" }?.ssh)
        #expect(trusted.status == "trusted")
        #expect(trusted.challengeToken == nil)
    }
}
