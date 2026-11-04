import Foundation
import Testing
@testable import DBeer

/// Pure protocol/model tests. These never create windows or activate AppKit.
@MainActor
struct SessionMonitorTests {
    private func profile() -> SavedConnection {
        SavedConnection(name: "Monitor fixture", settings: .init(host: "fixture.invalid", port: 5432,
            database: "fixture", user: "reader", password: "", sslMode: "disable"))
    }
    private func snapshot(id: String = "42") -> SessionMonitorSnapshot {
        SessionMonitorSnapshot(engine: .postgresql, collectionStartedAt: "2026-11-04T12:00:00.000000001Z",
            collectedAt: "2026-11-04T12:00:00.000000002Z",
            sessions: [MonitoredSession(id: id, user: "reader", state: "active", query: "SELECT fixture",
                queryAgeMs: "25", isMonitor: false, queryTruncated: false)],
            waits: [.init(waitingId: id, blockingId: "99", kind: "lock")],
            sessionsComplete: true, waitsComplete: false, notices: ["A blocker is outside visible sessions."])
    }
    private func reply(_ command: BackendCommand, snapshot: SessionMonitorSnapshot? = nil) -> BackendMessage {
        switch command.type {
        case "monitor.snapshot":
            return BackendMessage(type: "monitor.result", requestId: command.requestId, sessionId: command.sessionId,
                queryId: command.queryId, transactionStatus: .idle, connected: true, monitor: snapshot ?? self.snapshot())
        case "cancel":
            return BackendMessage(type: "cancel.ack", requestId: command.requestId, sessionId: command.sessionId,
                queryId: command.queryId, status: "accepted")
        default: return BackendMessage(type: "disconnect.ack", requestId: command.requestId, sessionId: command.sessionId)
        }
    }

    @Test func sharedFixtureValidatesSnapshotsAndReplies() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/session-monitor-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for item in try #require(fixture["snapshots"] as? [[String: Any]]) {
            let bytes = try JSONSerialization.data(withJSONObject: item)
            #expect(try JSONDecoder().decode(SessionMonitorSnapshot.self, from: bytes).valid)
        }
        for item in try #require(fixture["invalidSnapshots"] as? [[String: Any]]) {
            let bytes = try JSONSerialization.data(withJSONObject: item)
            let decoded = try? JSONDecoder().decode(SessionMonitorSnapshot.self, from: bytes)
            #expect(decoded?.valid != true)
        }
        for item in try #require(fixture["validResponses"] as? [[String: Any]]) {
            let bytes = try JSONSerialization.data(withJSONObject: item)
            try JSONDecoder().decode(BackendMessage.self, from: bytes).validate()
        }
    }

    @Test func timestampsBoundsAndUnavailableDurationsAreStrict() {
        var observation = snapshot()
        #expect(observation.valid)
        for time in ["2026-02-30T00:00:00Z", "2026-11-04T25:00:00Z", "2026-11-04T12:61:00Z",
                     "2026-11-04T12:00:60Z", "2026-11-04T12:00:00+25:00", "2026-11-04T12:00:00.0000000001Z"] {
            observation.collectionStartedAt = time
            #expect(!observation.valid)
        }
        observation = snapshot()
        observation.collectedAt = "2026-11-04T12:00:00.000000000Z"
        #expect(!observation.valid)
        observation = snapshot()
        observation.sessions[0].transactionAgeMs = nil
        #expect(observation.valid && observation.sessions[0].transactionAgeMs == nil)
        observation.sessions[0].queryAgeMs = "01"
        #expect(!observation.valid)
        observation = snapshot()
        observation.sessions[0].query = String(repeating: "x", count: 4_097)
        #expect(!observation.valid)
        observation = snapshot()
        observation.notices = []
        #expect(!observation.valid)
        observation = snapshot()
        observation.sessions += observation.sessions
        #expect(!observation.valid)
        observation = snapshot()
        observation.waits += observation.waits
        #expect(!observation.valid)
        observation = snapshot()
        observation.waits.append(.init(waitingId: "42", blockingId: "99", kind: "lock", object: ""))
        #expect(observation.valid)
    }

    @Test func profileBindingsRejectCanonicalUnicodeEditsToServerAndSSHPaths() throws {
        let composed = "caf\u{00e9}"
        let decomposed = "cafe\u{0301}"
        #expect(composed == decomposed && !Data(composed.utf8).elementsEqual(Data(decomposed.utf8)))
        var original = profile()
        original.database = composed
        original.user = composed
        original.ssh = SSHConfiguration(host: "fixture.invalid", user: "reader", authMethod: .privateKey,
            identityFile: "/fixture/\(composed)")
        let binding = try #require(SessionMonitorProfileBinding(original))
        #expect(binding.matches(original) && binding.matches(in: [original]))
        var database = original
        database.database = decomposed
        var user = original
        user.user = decomposed
        var identity = original
        identity.ssh?.identityFile = "/fixture/\(decomposed)"
        for candidate in [database, user, identity] {
            #expect(candidate == original)
            #expect(!binding.matches(candidate) && !binding.matches(in: [candidate]))
        }
        #expect(!binding.matches(nil) && !binding.matches(in: []))
        var unrelated = original
        unrelated.id = UUID()
        #expect(!binding.matches(in: [unrelated]))
    }

    @Test func latestPresentationIntentWinsAndStaleCloseTargetsAreRejected() {
        var presentation = SessionMonitorPresentationIntent()
        let original = presentation.requestOpen()
        let requestedB = presentation.requestOpen()
        let requestedC = presentation.requestOpen()
        #expect(!presentation.isCurrent(original) && !presentation.isCurrent(requestedB) && presentation.isCurrent(requestedC))
        let oldWindow = UUID(), newWindow = UUID()
        #expect(!SessionMonitorPresentationIntent.mayClose(expectedID: oldWindow, activeID: newWindow))
        #expect(SessionMonitorPresentationIntent.mayClose(expectedID: newWindow, activeID: newWindow))
        #expect(!SessionMonitorPresentationIntent.mayClose(expectedID: oldWindow, activeID: nil))
        #expect(SessionMonitorPresentationIntent.mayClose(expectedID: nil, activeID: newWindow))
        presentation.cancelPendingOpen()
        #expect(!presentation.isCurrent(requestedC))
    }

    @Test func refreshReusesOnlyItsDedicatedSessionAndDoesNotOverlap() async {
        let gate = MonitorTestGate<Void>()
        var connects = 0
        var commands: [BackendCommand] = []
        let model = SessionMonitorModel(profile: profile(), connect: { connects += 1; return "monitor-only" }, send: { command in
            commands.append(command)
            if command.type == "monitor.snapshot", commands.filter({ $0.type == "monitor.snapshot" }).count == 1 { await gate.wait() }
            return reply(command)
        }, bindingIsCurrent: { true })
        let first = Task { await model.refresh() }
        await gate.waitUntilWaiting()
        await model.refresh()
        #expect(model.isBusy && connects == 1 && commands.count == 1)
        gate.release(())
        await first.value
        #expect(model.snapshot?.sessions.first?.id == "42" && !model.isStale && !model.autoRefresh)
        await model.refresh()
        #expect(connects == 1 && commands.filter { $0.type == "monitor.snapshot" }.count == 2)
        #expect(commands.allSatisfy { $0.sessionId == "monitor-only" && $0.sql == nil && $0.catalog == nil })
        #expect(model.sessionLabel("99").contains("outside visible"))
        await model.close()
        #expect(commands.last?.type == "disconnect" && model.snapshot == nil)
    }

    @Test func stopDiscardsLateObservationAndCancelsOnlyMonitorRead() async {
        let gate = MonitorTestGate<Void>()
        var commands: [BackendCommand] = []
        let state = MonitorTestState()
        let model = SessionMonitorModel(profile: profile(), connect: { "monitor-only" }, send: { command in
            commands.append(command)
            if command.type == "monitor.snapshot", state.hold { await gate.wait() }
            return reply(command, snapshot: snapshot(id: state.hold ? "77" : "42"))
        }, bindingIsCurrent: { true })
        await model.refresh()
        state.hold = true
        let refresh = Task { await model.refresh() }
        await gate.waitUntilWaiting()
        await model.stop()
        #expect(model.isBusy && model.isStale && model.snapshot?.sessions.first?.id == "42")
        let cancel = commands.first { $0.type == "cancel" }
        #expect(cancel?.sessionId == "monitor-only" && cancel?.queryId == commands.last(where: { $0.type == "monitor.snapshot" })?.queryId)
        gate.release(())
        await refresh.value
        #expect(!model.isBusy && model.snapshot?.sessions.first?.id == "42" && model.isStale)
        await model.close()
    }

    @Test func closingDuringConnectDisposesLateSessionWithoutReading() async {
        let gate = MonitorTestGate<String>()
        let cancelGate = MonitorTestGate<Void>()
        var commands: [BackendCommand] = []
        let model = SessionMonitorModel(profile: profile(), connect: { await gate.wait() }, send: { command in
            commands.append(command); return reply(command)
        }, bindingIsCurrent: { true }, cancelPreparation: { cancelGate.release(()) })
        let refresh = Task { await model.refresh() }
        await gate.waitUntilWaiting()
        let closing = Task { await model.close() }
        await cancelGate.wait()
        gate.release("late-monitor")
        await closing.value
        await refresh.value
        #expect(model.snapshot == nil && model.isClosing)
        #expect(commands.map(\.type) == ["disconnect"] && commands.first?.sessionId == "late-monitor")
        await model.refresh()
        #expect(commands.count == 1)
    }

    @Test func changedProfileAndFailedRefreshCannotLookCurrent() async {
        let state = MonitorTestState()
        var commands: [BackendCommand] = []
        let model = SessionMonitorModel(profile: profile(), connect: { "monitor-only" }, send: { command in
            commands.append(command)
            if state.fail, command.type == "monitor.snapshot" { throw BackendTransportError(.notReady) }
            return reply(command)
        }, bindingIsCurrent: { state.current })
        await model.refresh()
        state.fail = true
        await model.refresh()
        #expect(model.isStale && model.notice?.contains("stale") == true)
        let count = commands.count
        state.current = false
        await model.refresh()
        #expect(model.snapshot == nil && model.notice?.contains("saved connection changed") == true && commands.count == count)
        await model.close()
    }

    @Test func concurrentCloseCallersWaitForTheSameDisconnect() async {
        let disconnect = MonitorTestGate<Void>()
        let secondStarted = MonitorTestGate<Void>()
        let state = MonitorTestState()
        var commands: [BackendCommand] = []
        let model = SessionMonitorModel(profile: profile(), connect: { "monitor-only" }, send: { command in
            commands.append(command)
            if command.type == "disconnect" { await disconnect.wait() }
            return reply(command)
        }, bindingIsCurrent: { true })
        await model.refresh()
        let first = Task { await model.close() }
        await disconnect.waitUntilWaiting()
        let second = Task {
            secondStarted.release(())
            await model.close()
            state.finished = true
        }
        await secondStarted.wait()
        #expect(!state.finished)
        disconnect.release(())
        await first.value
        await second.value
        #expect(state.finished && commands.filter { $0.type == "disconnect" }.count == 1)
    }

    @Test func numericSortsKeepUnavailableDurationsLastAndUseStableIDs() async {
        var observation = snapshot()
        observation.sessions = [
            MonitoredSession(id: "10", queryAgeMs: "10", isMonitor: false, queryTruncated: false),
            MonitoredSession(id: "2", queryAgeMs: "2", transactionAgeMs: "1000", isMonitor: false, queryTruncated: false),
            MonitoredSession(id: "100", transactionAgeMs: "1000", isMonitor: false, queryTruncated: false),
            MonitoredSession(id: "99999999999999999999", queryAgeMs: "0", transactionAgeMs: "2", isMonitor: false, queryTruncated: false)
        ]
        observation.waits = [.init(waitingId: "10", blockingId: "2", kind: "lock"),
                             .init(waitingId: "100", blockingId: "2", kind: "lock"),
                             .init(waitingId: "100", blockingId: "99999999999999999999", kind: "lock")]
        let frozen = observation
        let model = SessionMonitorModel(profile: profile(), connect: { "monitor-only" },
            send: { reply($0, snapshot: frozen) }, bindingIsCurrent: { true })
        await model.refresh()
        #expect(model.visibleSessions.map(\.id) == ["2", "10", "100", "99999999999999999999"])
        model.sort = .queryDuration
        #expect(model.visibleSessions.map(\.id) == ["10", "2", "99999999999999999999", "100"])
        model.sortDescending = false
        #expect(model.visibleSessions.map(\.id) == ["99999999999999999999", "2", "10", "100"])
        model.sort = .transactionDuration
        #expect(model.visibleSessions.map(\.id) == ["2", "100", "99999999999999999999", "10"])
        model.sort = .blocking
        #expect(model.visibleSessions.map(\.id) == ["2", "99999999999999999999", "10", "100"])
        await model.close()
    }

    @Test func filteringAndRelationshipNavigationKeepCountsAndPendingWaitsHonest() async {
        var observation = snapshot()
        observation.sessions = [
            MonitoredSession(id: "2", user: "holder", isMonitor: false, queryTruncated: false),
            MonitoredSession(id: "10", user: "waiter", isMonitor: false, queryTruncated: false),
            MonitoredSession(id: "11", user: "pending", state: "Waiting for table metadata lock", waitType: "metadata", isMonitor: false, queryTruncated: false)
        ]
        observation.waits = [.init(waitingId: "10", blockingId: "2", kind: "lock"),
                             .init(waitingId: "10", blockingId: "99", kind: "lock")]
        let frozen = observation
        let model = SessionMonitorModel(profile: profile(), connect: { "monitor-only" },
            send: { reply($0, snapshot: frozen) }, bindingIsCurrent: { true })
        await model.refresh()
        #expect(model.visibleWaitingCount == 2 && model.visibleBlockingCount == 1)
        model.waitingOnly = true
        #expect(model.visibleSessions.map(\.id) == ["10", "11"] && model.visibleWaits.count == 2)
        model.filter = "pending"
        #expect(model.visibleSessions.map(\.id) == ["11"] && model.visibleWaitingCount == 1 && model.visibleWaits.isEmpty)
        model.selectSession("2")
        #expect(model.filter.isEmpty && !model.waitingOnly && model.selectedSessionID == "2" && model.visibleWaits.count == 1)
        model.selectSession("99")
        #expect(model.selectedSessionID == "2" && model.sessionLabel("99").contains("outside visible"))
        model.filter = "waiter"
        #expect(model.selectedSessionID == nil && model.visibleSessions.map(\.id) == ["10"] && model.visibleWaits.count == 2)
        await model.close()
    }

    @Test func stoppedReadLosingItsSessionReconnectsOnTheNextExplicitRefresh() async {
        let gate = MonitorTestGate<Void>()
        let state = MonitorTestState()
        var connections = 0
        var commands: [BackendCommand] = []
        let model = SessionMonitorModel(profile: profile(), connect: { connections += 1; return "monitor-\(connections)" }, send: { command in
            commands.append(command)
            if command.type == "monitor.snapshot", state.hold {
                await gate.wait()
                throw BackendRemoteError(reply: BackendMessage(type: "error", requestId: command.requestId,
                    sessionId: command.sessionId, queryId: command.queryId,
                    category: "cancelled", message: "Monitoring was cancelled.", connected: false))
            }
            return reply(command)
        }, bindingIsCurrent: { true })
        await model.refresh()
        state.hold = true
        let pending = Task { await model.refresh() }
        await gate.waitUntilWaiting()
        await model.stop()
        gate.release(())
        await pending.value
        state.hold = false
        await model.refresh()
        #expect(connections == 2 && commands.last?.sessionId == "monitor-2" && model.snapshot != nil && !model.isStale)
        await model.close()
    }

    @Test func helperFailurePreservesStaleObservationUntilExplicitReconnect() async {
        var connections = 0
        var commands: [BackendCommand] = []
        let model = SessionMonitorModel(profile: profile(), connect: { connections += 1; return "monitor-\(connections)" }, send: { command in
            commands.append(command); return reply(command)
        }, bindingIsCurrent: { true })
        await model.refresh()
        model.autoRefresh = true
        let requestCount = commands.count
        model.helperDidFail()
        #expect(model.snapshot != nil && model.isStale && !model.autoRefresh && !model.isClosing)
        #expect(commands.count == requestCount && connections == 1 && model.notice?.contains("Refresh explicitly") == true)
        await model.refresh()
        #expect(connections == 2 && commands.last?.sessionId == "monitor-2" && !model.isStale)
        await model.close()
    }

    @Test func clientValidatesMonitorCommandsAndStartedLifecycleWithoutUI() async throws {
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys
        def emit(r): print(json.dumps(r),flush=True)
        for line in sys.stdin:
            c=json.loads(line);k=c['type'];r={'requestId':c['requestId']}
            if k=='hello':r.update(type='hello.ack',protocolVersion=6,capabilities=['sessionMonitorV1'])
            elif k=='connect':
                if c['connection'].get('sessionPurpose')!='monitor':sys.exit(31)
                r.update(type='connect.result',sessionId='dedicated-monitor',engine='postgresql',transactionStatus='idle',capabilities=['sessionMonitorV1'])
            elif k=='monitor.snapshot':
                if set(c)!=set(['type','requestId','sessionId','queryId']):sys.exit(32)
                r.update(sessionId=c['sessionId'],queryId=c['queryId'])
                emit(dict(r,type='query.started'))
                r.update(type='monitor.result',connected=True,transactionStatus='idle',monitor={'engine':'postgresql','collectionStartedAt':'2026-11-04T12:00:00Z','collectedAt':'2026-11-04T12:00:01Z','sessions':[],'waits':[],'sessionsComplete':True,'waitsComplete':True,'notices':[]})
            elif k=='disconnect':r.update(type='disconnect.ack',sessionId=c['sessionId'])
            elif k=='shutdown':emit(dict(r,type='shutdown.ack'));break
            else:sys.exit(33)
            emit(r)
        """])
        try await client.start()
        do {
            var invalid = BackendCommand.monitorSnapshot(sessionId: "dedicated-monitor")
            invalid.sql = "SELECT fixture"
            await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(invalid) }
            var settings = profile().settings(password: "")
            settings.sessionPurpose = "monitor"
            let connection = try await client.request(.connect(settings))
            let session = try #require(connection.sessionId)
            let observation = try await client.request(.monitorSnapshot(sessionId: session))
            #expect(observation.type == "monitor.result" && observation.monitor?.sessions.isEmpty == true)
            _ = try await client.request(.disconnect(sessionId: session))
        } catch {
            _ = await client.shutdown()
            throw error
        }
        #expect(await client.shutdown().acknowledged)
    }
}

@MainActor
private final class MonitorTestGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var pending: Value?
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async -> Value {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        if let pending { self.pending = nil; return pending }
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilWaiting() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release(_ value: Value) {
        if let continuation { self.continuation = nil; continuation.resume(returning: value) }
        else { pending = value }
    }
}

@MainActor
private final class MonitorTestState {
    var current = true
    var fail = false
    var hold = false
    var finished = false
}
