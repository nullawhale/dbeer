import AppKit
import Foundation
import Testing
@testable import DBeer

@MainActor
struct AppTerminationTests {
    @Test func terminationWaitsForActiveQueryAndHelperExitBeforeReplyingOnce() async throws {
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time
        def read():
            return json.loads(sys.stdin.readline())
        def send(message):
            print(json.dumps(message), flush=True)
        command = read()
        send({'type':'hello.ack','requestId':command['requestId'],'protocolVersion':3})
        command = read()
        send({'type':'connect.result','engine':'postgresql','capabilities':['execute','cancel','transactions'],'requestId':command['requestId'],'sessionId':'closing-session','transactionStatus':'idle'})
        execute = read()
        send({'type':'query.started','requestId':execute['requestId'],'sessionId':execute['sessionId'],'queryId':execute['queryId']})
        command = read()
        if command['type'] != 'shutdown':
            sys.exit(40)
        time.sleep(0.1)
        send({'type':'error','requestId':execute['requestId'],'sessionId':execute['sessionId'],'queryId':execute['queryId'],
              'category':'cancelled','message':'Query cancelled.','connected':False,'outcomeUnknown':False})
        send({'type':'shutdown.ack','requestId':command['requestId']})
        """])
        let model = WorkspaceModel(helperFactory: { client })
        await model.start()
        await model.connect()
        model.password = "runtime-only-fixture"
        let execution = Task { await model.run() }
        let startedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !model.canStop, ContinuousClock.now < startedDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.canStop)
        var replies: [Bool] = []
        let delegate = AppDelegate(model: model, terminationReply: { replies.append($0) })
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(replies.isEmpty)
        let replyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while replies.isEmpty, ContinuousClock.now < replyDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(replies == [true])
        // The callback is the production point at which AppKit may exit.
        // At this point both the request and the child have already finished.
        #expect(await client.waitForExit().status == 0)
        await execution.value
        #expect(model.sessionId == nil)
        #expect(model.connectionState == .disconnected)
        #expect(!model.isExecuting)
        #expect(model.password.isEmpty)
        if case .stopped = model.state {} else { Issue.record("Termination must finish model shutdown before replying.") }
        await model.shutdown()
    }
}
