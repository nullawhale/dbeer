import Foundation
import Testing
@testable import DBeer

@MainActor
struct WorkspaceQueryTests {
    private func helper(_ body: String) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time
        def read():
            return json.loads(sys.stdin.readline())
        def send(message):
            print(json.dumps(message), flush=True)
        def started(command):
            send({'type':'query.started','requestId':command['requestId'],'sessionId':command['sessionId'],'queryId':command['queryId']})
        def result(command, columns=[], rows=[], tag='SELECT 0', count=0, transaction='idle', truncated=False):
            send({'type':'query.result','requestId':command['requestId'],'sessionId':command['sessionId'],'queryId':command['queryId'],
                  'durationMs':12.5,'columns':columns,'rows':rows,'commandTag':tag,'rowCount':count,
                  'displayedRowCount':len(rows),'truncated':truncated,'transactionStatus':transaction})
        def error(command, category='sql', message='division by zero', sqlstate='22012', transaction='idle'):
            send({'type':'error','requestId':command['requestId'],'sessionId':command['sessionId'],'queryId':command['queryId'],
                  'category':category,'message':message,'sqlState':sqlstate,'connected':True,'outcomeUnknown':False,'transactionStatus':transaction})
        command = read()
        send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':3})
        command = read()
        send({'type':'connect.result','engine':'postgresql','capabilities':['execute','cancel','transactions'],'requestId':command['requestId'],'sessionId':'test-session','transactionStatus':'idle'})
        \(body)
        """])
    }

    private func connected(_ client: BackendClient) async -> WorkspaceModel {
        let model = WorkspaceModel(helperFactory: { client })
        await model.start()
        await model.connect()
        return model
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition())
    }

    @Test func eachRunClearsPreviousResultAndReplacesSchemaWithoutChangingSQL() async throws {
        let client = helper("""
        command = read()
        started(command)
        result(command, [{'index':0,'name':'x','typeOid':20},{'index':1,'name':'x','typeOid':25}],
               [['9007199254740993',None]], 'SELECT 1200', 1200, truncated=True)
        command = read()
        started(command)
        time.sleep(0.15)
        if command['sql'] != 'SELECT 1 WHERE false;':
            sys.exit(40)
        result(command, [{'index':0,'name':'id','typeOid':23}])
        command = read()
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """)
        let model = await connected(client)
        await model.run()
        #expect(model.result?.columns?.map(\.name) == ["x", "x"])
        #expect(model.result?.rows == [["9007199254740993", nil]])
        #expect(model.result?.rowCount == 1_200)
        #expect(model.result?.displayedRowCount == 1)
        #expect(model.result?.truncated == true)
        model.sql = "SELECT 1 WHERE false;"
        let next = Task { await model.run() }
        try await eventually { model.isExecuting }
        #expect(model.result == nil)
        #expect(model.queryFailure == nil)
        #expect(model.errorMessage == nil)
        #expect(!model.canRun && !model.canDisconnect && !model.canEditConnection)
        await model.run() // Repeated Run must not send another command.
        await next.value
        #expect(model.result?.columns?.map(\.name) == ["id"])
        #expect(model.result?.rows == [])
        #expect(model.sql == "SELECT 1 WHERE false;")
        #expect(model.canRun)
        await model.shutdown()
    }

    @Test func sqlErrorKeepsFailedTransactionUntilExplicitRollback() async {
        let client = helper("""
        command = read()
        started(command)
        result(command, tag='BEGIN', transaction='transaction')
        command = read()
        started(command)
        error(command, transaction='failedTransaction')
        command = read()
        started(command)
        result(command, tag='ROLLBACK')
        command = read()
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """)
        let model = await connected(client)
        model.sql = "BEGIN"
        await model.run()
        #expect(model.transactionStatus == .transaction)
        model.sql = "SELECT 1/0"
        await model.run()
        #expect(model.result == nil)
        #expect(model.queryFailure?.sqlState == "22012")
        #expect(model.errorMessage?.contains("SQLSTATE 22012") == true)
        #expect(model.connectionState == .connected)
        #expect(model.transactionStatus == .failedTransaction)
        #expect(model.transactionLabel == "Failed transaction")
        #expect(model.canRun)
        model.sql = "ROLLBACK"
        await model.run()
        #expect(model.queryFailure == nil && model.errorMessage == nil)
        #expect(model.transactionStatus == .idle)
        #expect(model.result?.commandTag == "ROLLBACK")
        model.sql = " \n\t "
        #expect(!model.canRun)
        await model.shutdown()
    }

    @Test func stopAcknowledgementKeepsQueryLockedUntilExecuteTerminal() async throws {
        let client = helper("""
        execute = read()
        started(execute)
        cancel = read()
        if cancel['type'] != 'cancel' or cancel['queryId'] != execute['queryId']:
            sys.exit(40)
        send({'type':'cancel.ack','requestId':cancel['requestId'],'sessionId':cancel['sessionId'],'queryId':cancel['queryId'],'status':'accepted'})
        time.sleep(0.2)
        error(execute, category='cancelled', message='Query cancelled.', sqlstate='57014')
        command = read()
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """)
        let model = await connected(client)
        model.sql = "SELECT pg_sleep(10)"
        let execution = Task { await model.run() }
        try await eventually { model.canStop }
        let activeId = model.activeQueryId
        await model.stop()
        #expect(model.activeQueryId == activeId)
        #expect(model.queryPhase == .cancelling)
        #expect(model.isExecuting && !model.canRun && !model.canStop && !model.canDisconnect)
        await execution.value
        #expect(!model.isExecuting)
        #expect(model.queryFailure?.category == "cancelled")
        #expect(model.queryFailure?.outcomeUnknown == false)
        #expect(model.connectionState == .connected && model.canRun)
        await model.shutdown()
    }

    @Test func successfulExecuteCanWinStopRace() async throws {
        let client = helper("""
        execute = read()
        started(execute)
        cancel = read()
        send({'type':'cancel.ack','requestId':cancel['requestId'],'sessionId':cancel['sessionId'],'queryId':cancel['queryId'],'status':'alreadyFinished'})
        result(execute, [{'index':0,'name':'id','typeOid':23}], [['1']], 'SELECT 1', 1)
        command = read()
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """)
        let model = await connected(client)
        let execution = Task { await model.run() }
        try await eventually { model.canStop }
        await model.stop()
        await execution.value
        #expect(model.result?.commandTag == "SELECT 1")
        #expect(model.queryFailure == nil)
        #expect(model.connectionState == .connected && model.canRun)
        await model.shutdown()
    }

    @Test func transportObserverCannotEraseUnknownSQLOutcomeOrReplayQuery() async throws {
        let client = helper("""
        command = read()
        started(command)
        sys.exit(23)
        """)
        var launches = 0
        let model = WorkspaceModel(helperFactory: { launches += 1; return client })
        await model.start()
        await model.connect()
        await model.run()
        _ = await client.waitForFailure()
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.connectionState == .disconnected && model.sessionId == nil)
        #expect(model.result == nil && !model.isExecuting)
        #expect(model.queryFailure?.outcomeUnknown == true)
        #expect(model.errorMessage?.contains("SQL outcome is unknown") == true)
        #expect(model.canConnect && !model.canRun)
        #expect(launches == 1)
        await model.shutdown()
    }

    @Test func terminalResultRemainsAuthoritativeWhenHelperImmediatelyExits() async throws {
        let client = helper("""
        command = read()
        started(command)
        result(command, [{'index':0,'name':'id','typeOid':23}], [['1']], 'SELECT 1', 1)
        sys.exit(23)
        """)
        let model = await connected(client)
        await model.run()
        _ = await client.waitForFailure()
        try await eventually { model.connectionState == .disconnected }
        #expect(model.result?.commandTag == "SELECT 1")
        #expect(model.result?.rows == [["1"]])
        #expect(model.queryFailure == nil)
        #expect(model.errorMessage?.contains("SQL outcome is unknown") == false)
        #expect(!model.canRun && model.canConnect)
        await model.shutdown()
    }
}
