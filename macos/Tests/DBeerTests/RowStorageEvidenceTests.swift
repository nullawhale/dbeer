import Foundation
import Testing
@testable import DBeer

struct RowStorageEvidenceTests {
    struct Fixture: Decodable { var command: BackendCommand; var response: BackendMessage }
    static func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/row-storage-evidence-v1.json")))
    }
    @Test func sharedEvidenceSurvivesProtocolAndSelectedResultProjection() throws {
        let fixture = try Self.fixture()
        try fixture.response.validate()
        #expect(fixture.command.changes?.changes[0].storageToken == fixture.response.storageTokens?[0])
        #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(fixture.command)) == fixture.command)
        var result = fixture.response
        result.resultSets = [QueryResultSet(columns: result.columns!, rows: result.rows!, commandTag: "SELECT 1", rowCount: 1,
            displayedRowCount: 1, storageTokens: result.storageTokens)]
        let selected = try #require(ResultSnapshotSource.project(result, resultSetIndex: 0))
        #expect(selected.storageTokens == fixture.response.storageTokens)
    }
    @Test func malformedOrUnboundStorageEvidenceIsRejected() throws {
        var result = try Self.fixture().response
        result.storageTokens = []
        #expect(throws: BackendTransportError.self) { try result.validate() }
        result.storageTokens = ["line\nbreak"]
        #expect(throws: BackendTransportError.self) { try result.validate() }
        result.storageTokens = [String(repeating: "x", count: 4_097)]
        #expect(throws: BackendTransportError.self) { try result.validate() }
    }

    @Test func streamedRowsRetainTheirTerminalStorageEvidence() async throws {
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys
        def read(): return json.loads(sys.stdin.readline())
        def send(x): print(json.dumps(x),flush=True)
        c=read();send({'type':'hello.ack','requestId':c['requestId'],'protocolVersion':5,'capabilities':[]})
        c=read();base={'requestId':c['requestId'],'sessionId':c['sessionId'],'queryId':c['queryId']}
        send(dict(base,type='query.started'))
        columns=[{'index':0,'name':'id','engine':'postgresql','nativeType':'int4'}]
        send(dict(base,type='query.chunk',sequence=1,resultIndex=0,columns=columns,rows=[['1']]))
        a=read()
        if a['type']!='stream.ack' or a['sequence']!=1: sys.exit(42)
        result={'columns':columns,'rows':[],'commandTag':'SELECT 1','rowCount':1,'displayedRowCount':1,'truncated':False,'storageTokens':['pgrow-v1/16384/(0,1)/456']}
        send(dict(base,type='query.result',durationMs=1,columns=[],rows=[],commandTag='SELECT 1',rowCount=1,displayedRowCount=1,truncated=False,transactionStatus='idle',streamed=True,resultSets=[result]))
        c=read();send({'type':'shutdown.ack','requestId':c['requestId']})
        """])
        try await client.start()
        let result = try await client.request(.execute(sessionId: "session", sql: "SELECT fixture"))
        #expect(result.rows == [["1"]])
        #expect(result.storageTokens == ["pgrow-v1/16384/(0,1)/456"])
        #expect(result.resultSets?.first?.storageTokens == result.storageTokens)
        _ = await client.shutdown()
    }
}
