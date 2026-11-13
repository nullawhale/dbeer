import Foundation
import Testing
@testable import DBeer

struct OperationSupportTests {
    private struct Fixture: Decodable {
        var version: Int
        var valid: [OperationSupport]
    }
    private static func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/operation-support-v1.json")
    }

    @Test func sharedContractRejectsMalformedAndAmbiguousEligibility() throws {
        let data = try Data(contentsOf: Self.fixtureURL())
        let decoder = JSONDecoder()
        let fixture = try decoder.decode(Fixture.self, from: data)
        #expect(fixture.version == 1)
        #expect(fixture.valid.count == 4)
        for support in fixture.valid {
            #expect(support.valid)
            #expect(try decoder.decode(OperationSupport.self, from: JSONEncoder().encode(support)) == support)
        }
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let invalid = try #require(object["invalid"] as? [[String: Any]])
        for item in invalid {
            let value = try #require(item["value"])
            let raw = try JSONSerialization.data(withJSONObject: value)
            #expect(throws: (any Error).self) { try decoder.decode(OperationSupport.self, from: raw) }
        }
    }

    @Test func sessionDescriptorPreservesObjectChecksAndIndependentModes() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixtureURL()))
        let session = fixture.valid[0]
        #expect(session.permits("execute", legacyAllowed: false))
        #expect(session.permits("gridEditing", legacyAllowed: true))
        #expect(!session.permits("gridEditing", legacyAllowed: false))
        #expect(session.permits("futureOperation", legacyAllowed: true))
        let sqlite = fixture.valid[1]
        #expect(sqlite.permits("explain.plan", legacyAllowed: false))
        #expect(!sqlite.permits("explain.analyze", legacyAllowed: true))
        var message = BackendMessage(type: "connect.result", requestId: "r", engine: .sqlite,
            capabilities: ["execute"], sessionId: "s", transactionStatus: .idle, operationSupport: sqlite)
        try message.validate()
        message.engine = .postgresql
        #expect(throws: BackendTransportError.self) { try message.validate() }
        message.engine = .sqlite
        let wrongContext = BackendMessage(type: "query.started", requestId: "r", sessionId: "s", queryId: "q", operationSupport: sqlite)
        #expect(throws: BackendTransportError.self) { try wrongContext.validate() }
        message.operationSupport = nil
        try message.validate()
    }

    @Test func sourceEligibilityRequiresCurrentObjectEvidence() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixtureURL()))
        let columns = [ResultColumn(index: 0, name: "id", engine: .postgresql, nativeType: "bigint")]
        var source = SQLResultSource(schema: "public", table: "sample", columns: [
            SQLResultSourceColumn(name: "id", nativeType: "bigint", tableIndex: 0, primaryKey: 1, editable: true, generated: false)
        ])
        #expect(source.valid(for: columns))
        #expect(source.isEditable)
        source.operationSupport = fixture.valid[3]
        #expect(source.valid(for: columns))
        #expect(source.canOpenRow)
        #expect(!source.isEditable)
        source.operationSupport?.scope = .session
        #expect(!source.valid(for: columns))
        source.operationSupport = fixture.valid[3]
        source.operationSupport?.engine = .mysql
        #expect(!source.valid(for: columns))
    }

    @Test func descriptorBoundsAndReasonStatesAreEnforced() {
        var value = OperationAvailability(operation: "execute", state: .requiresMetadata, reason: "Load metadata.")
        #expect(value.valid)
        value.reason = String(repeating: "a", count: 1_025)
        #expect(!value.valid)
        value.reason = "\0"
        #expect(!value.valid)
        value = OperationAvailability(operation: "execute", state: .available, reason: "Available")
        #expect(!value.valid)
        let duplicate = OperationSupport(engine: .postgresql, scope: .session, operations: [
            .init(operation: "execute", state: .available), .init(operation: "execute", state: .available)
        ])
        #expect(!duplicate.valid)
    }

    @MainActor @Test func normalConnectionStoresAndClearsSessionEvidenceWithLegacyFallback() async {
        for descriptor in ["", ", 'operationSupport': {'version':1,'engine':'postgresql','scope':'session','operations':[{'operation':'gridEditing','state':'unavailable','reason':'This connection is readonly.'}]} "] {
            let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
            import json, sys
            def read():
                return json.loads(sys.stdin.readline())
            def send(value):
                print(json.dumps(value), flush=True)
            command = read()
            send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':6})
            command = read()
            send({'type':'connect.result','requestId':command['requestId'],'sessionId':'synthetic-session','engine':'postgresql','transactionStatus':'idle','capabilities':['execute','gridEditing']\(descriptor)})
            command = read()
            send({'type':'disconnect.ack','requestId':command['requestId'],'sessionId':command['sessionId']})
            command = read()
            send({'type':'shutdown.ack','requestId':command['requestId']})
            """])
            let model = WorkspaceModel(helperFactory: { client })
            await model.start()
            await model.connect()
            #expect(model.connectionState == .connected)
            #expect(model.supportsGridEditing == descriptor.isEmpty)
            #expect((model.operationSupport == nil) == descriptor.isEmpty)
            await model.disconnect()
            #expect(model.operationSupport == nil)
            #expect(!model.supportsGridEditing)
            await model.shutdown()
        }
    }
}
