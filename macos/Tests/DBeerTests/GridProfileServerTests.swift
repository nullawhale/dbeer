import Foundation
import Testing
@testable import DBeer

@MainActor
private final class ProfileServerFixture {
    let column = ResultColumn(index: 0, name: "n", typeOid: 1700, nativeType: "numeric")
    var commands: [BackendCommand] = []
    var opened = 0
    var current = true
    var pageSizes = [200, 2]
    var pausePage: Int?
    var held: CheckedContinuation<BackendMessage, any Error>?
    var heldCommand: BackendCommand?
    var connectHeld: CheckedContinuation<String, any Error>?
    var pauseConnect = false
    var connectionFlag: Bool? = nil
    var wrongCorrelation = false
    var changedMetadata = false
    var repeatedCursor = false
    var preparationCanceled = 0
    func model(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
               calculate: @escaping @Sendable (GridProfileInput) throws -> GridProfileReport = { try GridDataProfiler.profile($0) }) -> GridProfileServerModel {
        .init(table: .init(schema: "public", name: "fixture", kind: "table"), column: column, engine: .postgresql,
            connect: {
                self.opened += 1
                if self.pauseConnect { return try await withCheckedThrowingContinuation { self.connectHeld = $0 } }
                return "owned-\(self.opened)"
            }, send: { try await self.send($0) }, isCurrent: { self.current },
            cancelPreparation: { self.preparationCanceled += 1 }, sleep: sleep, calculate: calculate)
    }
    func response(_ command: BackendCommand) -> BackendMessage {
        let page = command.catalog?.page ?? 0
        let count = pageSizes[min(page, pageSizes.count - 1)]
        let metadata = changedMetadata && page > 0 ? ResultColumn(index: 0, name: "n", typeOid: 701, nativeType: "float8") : column
        var reply = BackendMessage(type: "query.result", requestId: command.requestId,
            sessionId: wrongCorrelation ? "foreign" : command.sessionId, queryId: command.queryId, transactionStatus: .idle,
            columns: [metadata], rows: Array(repeating: ["9007199254740993.000000000000000001"], count: count))
        reply.connected = connectionFlag
        if repeatedCursor { reply.nextCursor = "repeat" }
        return reply
    }
    func send(_ command: BackendCommand) async throws -> BackendMessage {
        commands.append(command)
        if command.type == "catalog" {
            let page = command.catalog?.page ?? 0
            if pausePage == page {
                heldCommand = command
                return try await withCheckedThrowingContinuation { held = $0 }
            }
            return response(command)
        }
        return BackendMessage(type: command.type + ".result", requestId: command.requestId)
    }
}

private final class ProfileCalculationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var released = false
    func release() { lock.withLock { released = true } }
    var hasStarted: Bool { lock.withLock { started } }
    func calculate(_ input: GridProfileInput) throws -> GridProfileReport {
        lock.withLock { started = true }
        while !Task.isCancelled && !lock.withLock({ released }) { Thread.sleep(forTimeInterval: 0.0001) }
        throw CancellationError()
    }
}

private actor ProfileDeadlineGate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var fired = false
    func sleep(_ duration: Duration) async throws {
        if fired { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func fire() { fired = true; continuation?.resume(); continuation = nil }
}

/// Owned-session lifecycle coverage using deferred protocol replies only.
@MainActor
struct GridProfileServerTests {
    @Test func explicitCaptureUsesFreshSessionAdapterBrowseAndHonestBoundedScope() async throws {
        let fixture = ProfileServerFixture(), model = fixture.model()
        #expect(fixture.opened == 0 && fixture.commands.isEmpty)
        model.rowLimit = 201
        await model.capture()
        let report = try #require(model.report)
        #expect(report.rowCount == 201 && report.scope.partial && report.scope.title.contains("First 201 rows"))
        #expect(report.scope.notice.contains("separate readonly connection") && report.scope.notice.contains("independently from SQL-tab transactions"))
        #expect(report.scope.notice.contains("8 MiB") && report.scope.notice.contains("without this tab's filters") && report.scope.notice.contains("relationship restrictions"))
        #expect(report.columns[0].sum == "1810447050202939593.000000000000000201")
        let reads = fixture.commands.filter { $0.type == "catalog" }
        #expect(reads.count == 2 && reads.map { $0.catalog?.page } == [0, 1])
        #expect(reads.allSatisfy { $0.catalog?.kind == "browse" && $0.sql == nil && $0.sessionId == "owned-1" })
        #expect(fixture.commands.filter { $0.type == "disconnect" }.count == 1)
        await model.capture()
        #expect(fixture.opened == 2 && fixture.commands.last(where: { $0.type == "disconnect" })?.sessionId == "owned-2")
        await model.close()
    }
    @Test func completeEmptyObservationAndUnsupportedOrStaleContextDoNotInventValues() async throws {
        let fixture = ProfileServerFixture(); fixture.pageSizes = [0]
        let model = fixture.model()
        await model.capture()
        #expect(model.report?.rowCount == 0 && model.report?.columns[0].sum == nil && model.report?.scope.partial == false)
        fixture.current = false
        await model.capture()
        #expect(fixture.opened == 1 && model.notice?.contains("context changed") == true)
        let unsupported = GridProfileServerModel(table: .init(schema: "x", name: "y", kind: "table"), column: fixture.column, engine: .mongodb,
            connect: { Issue.record("Unsupported engine connected"); return "foreign" },
            send: { _ in throw CancellationError() }, isCurrent: { true })
        await unsupported.capture()
        #expect(unsupported.notice?.contains("PostgreSQL, MySQL or SQLite") == true)
        await model.close(); await unsupported.close()
    }
    @Test func schemaChangesAndWrongSessionRejectUnsafePages() async throws {
        let fixture = ProfileServerFixture(); fixture.changedMetadata = true
        let model = fixture.model()
        await model.capture()
        #expect(model.report?.rowCount == 200 && model.report?.scope.partial == true)
        #expect(model.report?.scope.notice.contains("changed during capture") == true)
        fixture.changedMetadata = false; fixture.wrongCorrelation = true
        await model.capture()
        #expect(model.report == nil && model.notice?.contains("changed during capture") == true)
        #expect(fixture.commands.filter { $0.type == "disconnect" }.count == 2)
        fixture.wrongCorrelation = false; fixture.connectionFlag = false
        await model.capture()
        #expect(model.report == nil && model.notice?.contains("changed during capture") == true)
        await model.close()
    }
    @Test func stopRetainsCompletedPagesAndWaitsForOwnedQueryTerminal() async throws {
        let fixture = ProfileServerFixture(); fixture.pausePage = 1
        let model = fixture.model()
        let capture = Task { await model.capture() }
        for _ in 0..<200 where fixture.held == nil { await Task.yield() }
        let command = try #require(fixture.heldCommand)
        #expect(model.rowsCaptured == 200)
        await model.stop()
        #expect(model.isBusy)
        #expect(fixture.commands.last(where: { $0.type == "cancel" })?.queryId == command.queryId)
        #expect(fixture.commands.last(where: { $0.type == "cancel" })?.sessionId == "owned-1")
        #expect(!fixture.commands.contains { $0.type == "disconnect" })
        fixture.held?.resume(returning: fixture.response(command)); fixture.held = nil
        await capture.value
        #expect(!model.isBusy && model.report?.rowCount == 200 && model.report?.scope.partial == true)
        #expect(model.report?.scope.notice.contains("only completed pages") == true)
        #expect(fixture.commands.last?.type == "disconnect")
        await model.close()
    }
    @Test func closeDuringConnectDisconnectsLateOwnedSessionAndPublishesNothing() async throws {
        let fixture = ProfileServerFixture(); fixture.pauseConnect = true
        let model = fixture.model()
        let capture = Task { await model.capture() }
        for _ in 0..<200 where fixture.connectHeld == nil { await Task.yield() }
        try #require(fixture.connectHeld != nil)
        let closing = Task { await model.close() }
        for _ in 0..<20 { await Task.yield() }
        #expect(model.isBusy && fixture.preparationCanceled == 1)
        fixture.connectHeld?.resume(returning: "owned-late"); fixture.connectHeld = nil
        await capture.value; await closing.value
        #expect(!model.isBusy && model.report == nil)
        #expect(fixture.commands.filter { $0.type == "disconnect" }.map(\.sessionId) == ["owned-late"])
    }
    @Test func deadlineCancelsOwnedQueryAndSourceChangeLeavesCapturedScopeExplicit() async throws {
        let fixture = ProfileServerFixture(), gate = ProfileDeadlineGate()
        fixture.pausePage = 1
        let model = fixture.model(sleep: { try await gate.sleep($0) })
        let capture = Task { await model.capture() }
        for _ in 0..<200 where fixture.held == nil { await Task.yield() }
        let command = try #require(fixture.heldCommand)
        await gate.fire()
        for _ in 0..<200 where !fixture.commands.contains(where: { $0.type == "cancel" }) { await Task.yield() }
        await model.stop() // Repeated Stop must not erase an already reached deadline.
        fixture.current = false
        fixture.held?.resume(returning: fixture.response(command)); fixture.held = nil
        await capture.value
        #expect(model.report?.scope.notice.contains("deadline") == true)
        #expect(model.report?.scope.notice.contains("earlier captured context") == true)
        #expect(model.report?.rowCount == 200 && model.report?.scope.partial == true)
        await model.close()
    }
    @Test func repeatedCursorNeverLoopsAndRetainsBoundedPages() async throws {
        let fixture = ProfileServerFixture(); fixture.repeatedCursor = true
        let model = fixture.model()
        await model.capture()
        #expect(model.report?.rowCount == 400 && model.report?.scope.notice.contains("cursor repeated") == true)
        #expect(fixture.commands.filter { $0.type == "catalog" }.count == 2)
        await model.close()
    }
    @Test func stopCancelsDetachedStatisticalWorkAfterTheConnectionClosed() async throws {
        let fixture = ProfileServerFixture(), gate = ProfileCalculationGate()
        defer { gate.release() }
        fixture.pageSizes = [1]
        let model = fixture.model(calculate: { try gate.calculate($0) })
        let capture = Task { await model.capture() }
        for _ in 0..<1000 where !gate.hasStarted { await Task.yield() }
        try #require(gate.hasStarted)
        #expect(fixture.commands.last?.type == "disconnect")
        await model.stop()
        await capture.value
        #expect(!model.isBusy && model.report == nil && model.notice?.contains("Statistical calculation stopped") == true)
        #expect(!fixture.commands.contains { $0.type == "cancel" })
        await model.close()
    }

}
