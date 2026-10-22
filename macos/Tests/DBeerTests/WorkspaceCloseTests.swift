import AppKit
import Foundation
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct WorkspaceCloseTests {
    private func helper() -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        transactions = {}
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            reply = {'requestId':command['requestId']}
            if kind == 'hello':
                reply.update(type='hello.ack', protocolVersion=5)
            elif kind == 'operation.assess':
                reply.update(type='operation.assessment', sessionId=command['sessionId'], queryId=command['queryId'],
                             assessment={'decision':'allow','policy':{'environment':'unspecified','readOnly':False},
                             'operations':[{'kind':'read','statements':[]} for op in command['operations']], 'authorization':'test-grant'})
            elif kind == 'connect':
                session = 'session-' + str(len(transactions))
                transactions[session] = 'idle'
                reply.update(type='connect.result', engine='postgresql', capabilities=['execute','cancel','transactions'],
                             sessionId=session, transactionStatus='idle')
            elif kind in ['execute', 'catalog']:
                session = command['sessionId']
                sql = command.get('sql', '')
                if sql == 'BEGIN':
                    transactions[session] = 'transaction'
                elif sql in ['COMMIT', 'ROLLBACK']:
                    transactions[session] = 'idle'
                print(json.dumps({'type':'query.started','requestId':command['requestId'],
                                  'sessionId':session,'queryId':command['queryId']}), flush=True)
                reply.update(type='query.result', sessionId=session, queryId=command['queryId'], durationMs=1,
                             transactionStatus=transactions[session], columns=[], rows=[], commandTag=sql or 'SELECT 0',
                             rowCount=0, displayedRowCount=0, truncated=False)
            elif kind == 'cancel':
                reply.update(type='cancel.ack', sessionId=command['sessionId'], queryId=command['queryId'], status='alreadyFinished')
            elif kind == 'disconnect':
                reply.update(type='disconnect.ack', sessionId=command['sessionId'])
            elif kind == 'shutdown':
                reply.update(type='shutdown.ack')
            else:
                sys.exit(40)
            print(json.dumps(reply), flush=True)
            if kind == 'shutdown':
                break
        """])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    private func profile(on workspace: ApplicationWorkspace, settings: ConnectionSettings? = nil) async throws -> UUID {
        let settings = settings ?? ConnectionSettings(host: "localhost", port: 5432, database: "fixture",
            user: "fixture", password: "", sslMode: "disable")
        try #require(await workspace.library.saveConnection(name: "Close fixture", settings: settings))
        return try #require(workspace.library.selectedConnectionId)
    }

    private final class PreviousWindowDelegate: NSObject, NSWindowDelegate {
        var closed = 0
        func windowWillClose(_ notification: Notification) { closed += 1 }
    }

    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = NSView()
        window.orderFront(nil)
        return window
    }

    @Test func nativeWindowCloseCanCancelThenRollbackAndPreservesOriginalDelegateCallbacks() async throws {
        let client = helper()
        var decisions: [WorkspaceCloseDecision] = [.cancel, .rollback]
        var issues: [WorkspaceCloseIssue] = []
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: {
                issues.append($0)
                return decisions.isEmpty ? .cancel : decisions.removeFirst()
            }, helperFactory: { client })
        defer { Task { await workspace.shutdown() } }
        await workspace.start()
        let id = try await profile(on: workspace)
        let document = workspace.newDocument(profileID: id, text: "BEGIN")
        await workspace.run(document)
        let runtime = try #require(document.runtime)
        try #require(runtime.transactionStatus == .transaction)
        let nativeWindow = window()
        let previous = PreviousWindowDelegate()
        nativeWindow.delegate = previous
        let guardCoordinator = WorkspaceWindowCloseGuard.Coordinator(workspace: workspace)
        guardCoordinator.install(on: nativeWindow)
        defer { nativeWindow.close() }
        nativeWindow.performClose(nil)
        try await waitUntil { issues.count == 1 && !workspace.isClosing }
        #expect(nativeWindow.isVisible)
        #expect(previous.closed == 0)
        #expect(runtime.transactionStatus == .transaction)
        nativeWindow.performClose(nil)
        try await waitUntil { !nativeWindow.isVisible }
        #expect(issues == [.transaction(document.title, failed: false), .transaction(document.title, failed: false)])
        #expect(runtime.transactionStatus == .idle)
        #expect(previous.closed == 1)
        // This isolated window has no application delegate. The helper stays
        // usable until the production termination step explicitly shuts it down.
        #expect(runtime.connectionState == .connected)
        await workspace.shutdown()
        #expect(await client.waitForExit().status == 0)
    }

    @Test func applicationTerminationCancelLeavesSessionAliveAndRetryCommitsBeforeReplying() async throws {
        let client = helper()
        var decisions: [WorkspaceCloseDecision] = [.cancel, .commit]
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: { _ in
                decisions.isEmpty ? .cancel : decisions.removeFirst()
            }, helperFactory: { client })
        defer { Task { await workspace.shutdown() } }
        await workspace.start()
        let id = try await profile(on: workspace)
        let document = workspace.newDocument(profileID: id, text: "BEGIN")
        await workspace.run(document)
        let runtime = try #require(document.runtime)
        var replies: [Bool] = []
        let delegate = AppDelegate(model: workspace.library, workspace: workspace, terminationReply: { replies.append($0) })
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await waitUntil { !replies.isEmpty }
        #expect(replies == [false])
        #expect(runtime.transactionStatus == .transaction && runtime.connectionState == .connected)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await waitUntil { replies.count == 2 }
        #expect(replies == [false, true])
        #expect(await client.waitForExit().status == 0)
        #expect(decisions.isEmpty)
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func nativeWindowCancelThenStopAndRollbackUsesRealPostgresAndReapsItsBackend() async throws {
        let components = try #require(URLComponents(string: ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? ""))
        let parameters = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last })
        let settings = ConnectionSettings(host: try #require(components.host), port: components.port ?? 5432,
            database: String(components.path.dropFirst()), user: try #require(components.user), password: components.password ?? "",
            sslMode: parameters["sslmode"] ?? "verify-full", sslRootCert: parameters["sslrootcert"])
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let client = BackendClient(executableURL: executable)
        let observer = BackendClient(executableURL: executable)
        var decisions: [WorkspaceCloseDecision] = [.cancel, .stop, .rollback, .commit]
        var issues: [WorkspaceCloseIssue] = []
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: {
                issues.append($0)
                return decisions.isEmpty ? .cancel : decisions.removeFirst()
            }, helperFactory: { client })
        let nativeWindow = window()
        defer { nativeWindow.close() }
        let closeGuard = WorkspaceWindowCloseGuard.Coordinator(workspace: workspace)
        closeGuard.install(on: nativeWindow)
        defer { withExtendedLifetime(closeGuard) {} }
        do {
            await workspace.start()
            let id = try await profile(on: workspace, settings: settings)
            let document = workspace.newDocument(profileID: id)
            await workspace.run(document, sql: "SELECT pg_backend_pid()")
            let runtime = try #require(document.runtime)
            let backendText = try #require(runtime.result?.rows?.first?.first ?? nil)
            let backend = try #require(Int(backendText))
            await workspace.run(document, sql: "CREATE TEMP TABLE dbeer_close_fixture(value integer)")
            await workspace.run(document, sql: "BEGIN")
            await workspace.run(document, sql: "INSERT INTO dbeer_close_fixture VALUES (1)")
            let running = Task { await workspace.run(document, sql: "SELECT pg_sleep(10)") }
            try await waitUntil { runtime.canStop }
            nativeWindow.performClose(nil)
            try await waitUntil { issues.count == 1 && !workspace.isClosing }
            #expect(nativeWindow.isVisible && document.isRunning)
            nativeWindow.performClose(nil)
            try await waitUntil { !nativeWindow.isVisible }
            await running.value
            #expect(runtime.transactionStatus == .idle)
            #expect(issues.contains(.transaction(document.title, failed: true)))
            await workspace.run(document, sql: "SELECT COUNT(*)::text FROM dbeer_close_fixture")
            #expect(runtime.result?.rows == [["0"]])
            await workspace.run(document, sql: "BEGIN")
            await workspace.run(document, sql: "INSERT INTO dbeer_close_fixture VALUES (2)")
            #expect(await workspace.prepareToClose(.document(document.id)))
            await workspace.run(document, sql: "SELECT COUNT(*)::text FROM dbeer_close_fixture")
            #expect(runtime.result?.rows == [["1"]])
            try await observer.start()
            let connected = try await observer.request(.connect(settings))
            let session = try #require(connected.sessionId)
            await workspace.shutdown()
            #expect(await client.waitForExit().status == 0)
            var closed = try await observer.request(.execute(sessionId: session,
                sql: "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid=\(backend))::text"))
            let closeDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while closed.rows == [["true"]], ContinuousClock.now < closeDeadline {
                try await Task.sleep(for: .milliseconds(20))
                closed = try await observer.request(.execute(sessionId: session,
                    sql: "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid=\(backend))::text"))
            }
            #expect(closed.rows == [["false"]])
            #expect(decisions.isEmpty)
            _ = await observer.shutdown()
        } catch {
            await workspace.shutdown()
            _ = await observer.shutdown()
            throw error
        }
    }
}
