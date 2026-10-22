import Foundation
import Testing
@testable import DBeer

struct StreamingTransportTests {
    private func helper(_ body: String) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys
        def read(): return json.loads(sys.stdin.readline())
        def send(value): print(json.dumps(value,ensure_ascii=False),flush=True)
        hello=read()
        send({'type':'hello.ack','requestId':hello['requestId'],'protocolVersion':5})
        command=read()
        ids={'requestId':command['requestId'],'sessionId':command['sessionId'],'queryId':command['queryId']}
        column={'index':0,'name':'x','engine':'postgresql','nativeType':'numeric','typeOid':1700}
        send(dict(ids,type='query.started'))
        \(body)
        command=read()
        if command['type']=='shutdown': send({'type':'shutdown.ack','requestId':command['requestId']})
        """])
    }

    @Test func chunksAreAcknowledgedAndHydratedWithoutLosingExactValues() async throws {
        let client = helper("""
        send(dict(ids,type='query.chunk',sequence=1,resultIndex=0,columns=[column],rows=[]))
        ack=read()
        assert ack['type']=='stream.ack' and ack['sequence']==1 and ack['queryId']==command['queryId']
        send(dict(ids,type='query.chunk',sequence=2,resultIndex=0,rows=[['9007199254740993.123456789'],[None],['']]))
        ack=read()
        assert ack['type']=='stream.ack' and ack['sequence']==2
        summary={'columns':[column],'rows':[],'commandTag':'SELECT 3','rowCount':3,'displayedRowCount':3,'truncated':False}
        send(dict(ids,type='query.result',streamed=True,resultSets=[summary],columns=[],rows=[],commandTag='SELECT 3',rowCount=3,displayedRowCount=3,truncated=False,transactionStatus='idle',durationMs=1))
        """)
        try await client.start()
        let result = try await client.request(.execute(sessionId: "session", sql: "SELECT values"))
        #expect(result.streamed == nil)
        #expect(result.rows == [["9007199254740993.123456789"], [nil], [""]])
        #expect(result.resultSets?.first?.rows == result.rows)
        #expect(result.displayedRowCount == 3)
        let shutdown = await client.shutdown()
        #expect(shutdown.acknowledged)
    }

    @Test func reorderedChunksInvalidateTheTransport() async throws {
        let client = helper("""
        send(dict(ids,type='query.chunk',sequence=2,resultIndex=0,columns=[column],rows=[]))
        """)
        try await client.start()
        do {
            _ = try await client.request(.execute(sessionId: "session", sql: "SELECT values"))
            Issue.record("A reordered data chunk was accepted")
        } catch let error as BackendTransportError {
            #expect(error.code == .invalidMessage)
            #expect(error.outcomeUnknown)
        }
        _ = await client.shutdown()
    }

    @Test func terminalSourceOmissionNoticeSurvivesHydrationAndResultSetSelection() async throws {
        let client = helper("""
        summaries=[]
        for index in range(2):
            send(dict(ids,type='query.chunk',sequence=index+1,resultIndex=index,columns=[column],rows=[[str(index)]]))
            ack=read()
            assert ack['type']=='stream.ack' and ack['sequence']==index+1
            summaries.append(dict(columns=[column],rows=[],commandTag='SELECT 1',rowCount=1,displayedRowCount=1,
                truncated=False,displayNotice='Original result notice.'))
        send(dict(ids,type='query.result',streamed=True,resultSets=summaries,columns=[],rows=[],commandTag='SELECT 1',
            rowCount=1,displayedRowCount=1,truncated=False,transactionStatus='idle',durationMs=1,
            displayNotice='The source SQL exceeded the supported size limit. Pin Result is unavailable.'))
        """)
        try await client.start()
        do {
            let result = try await client.request(.execute(sessionId: "session", sql: "SELECT fixture"))
            #expect(result.sql == nil && result.displayNotice?.contains("source SQL exceeded") == true)
            for index in 0..<2 {
                let selected = try #require(ResultSnapshotSource.project(result, resultSetIndex: index))
                #expect(selected.rows == [[String(index)]])
                #expect(selected.displayNotice?.contains("Original result notice.") == true)
                #expect(selected.displayNotice?.contains("source SQL exceeded") == true)
            }
            #expect(await client.shutdown().acknowledged)
        } catch {
            _ = await client.shutdown()
            throw error
        }
    }
}
