import Foundation
import Testing
@testable import DBeer

@MainActor
private final class DatabaseSearchFixture {
    var connected = 0
    var commands: [BackendCommand] = []
    var current = true
    var deniedTable: String?
    var loseConnection = false
    var pauseBrowse = false
    var held: CheckedContinuation<BackendMessage, any Error>?
    var heldCommand: BackendCommand?
    var opened: [DatabaseSearchObservation] = []
    var tableNames = ["fixture"]
    var rowCount = 1
    var metadataOverride: [[String?]]?

    var profile: SavedConnection {
        .init(id: UUID(), name: "Search fixture", settings: .init(host: "localhost", port: 5432,
            database: "fixture", user: "fixture", password: "", sslMode: "disable"))
    }
    func makeModel(deadlineSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) -> DatabaseValueSearchModel {
        DatabaseValueSearchModel(profile: profile, connect: {
            self.connected += 1
            return ("search-session-\(self.connected)", ["catalog", "serverReadOnly"])
        }, send: { try await self.send($0) }, isCurrent: { self.current }, open: { self.opened.append($0) }, deadlineSleep: deadlineSleep)
    }

    func message(_ command: BackendCommand, names: [String], rows: [[String?]], types: [String]? = nil) -> BackendMessage {
        let columns = names.enumerated().map { offset, name in
            ResultColumn(index: offset, name: name, nativeType: types?[offset] ?? "text", encoding: name == "payload" ? "base64" : nil)
        }
        var reply = BackendMessage(type: "query.result", requestId: command.requestId, sessionId: command.sessionId,
            queryId: command.queryId, transactionStatus: .idle, columns: columns, rows: rows,
            rowCount: Int64(rows.count), displayedRowCount: rows.count)
        reply.connected = true
        return reply
    }

    func browse(_ command: BackendCommand) -> BackendMessage {
        let values: [String?] = ["1", "needle", "AP8="]
        return message(command, names: ["id", "label", "payload"], rows: Array(repeating: values, count: rowCount),
            types: ["integer", "text", "bytea"])
    }

    func send(_ command: BackendCommand) async throws -> BackendMessage {
        commands.append(command)
        guard let selector = command.catalog else { return BackendMessage(type: command.type + ".result", requestId: command.requestId) }
        if selector.kind == "schemas" { return message(command, names: ["name"], rows: [["public"]]) }
        if selector.kind == "objects" {
            return message(command, names: ["name", "kind", "schema"],
                rows: selector.objectKind == "table" ? tableNames.map { [$0, "table", selector.schema] } : [])
        }
        if selector.kind == "columns" {
            if selector.object == deniedTable {
                var reply = BackendMessage(type: "error", requestId: command.requestId)
                reply.connected = true; reply.message = "Metadata is denied."
                throw BackendRemoteError(reply: reply)
            }
            return message(command, names: ["name", "nativeType"], rows: metadataOverride ?? [["id", "integer"], ["label", "text"], ["payload", "bytea"]])
        }
        if selector.kind == "browse" {
            if loseConnection { throw BackendTransportError(.unexpectedEOF) }
            if pauseBrowse {
                heldCommand = command
                return try await withCheckedThrowingContinuation { held = $0 }
            }
            return browse(command)
        }
        throw BackendTransportError(.invalidMessage)
    }
}

private actor DatabaseSearchDeadlineGate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var fired = false
    func sleep(_ duration: Duration) async throws {
        if fired { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func fire() { fired = true; continuation?.resume(); continuation = nil }
}

@Suite(.serialized)
@MainActor
struct DatabaseValueSearchTests {
    @Test func openingDoesNotConnectAndMatchNavigationRetainsCapturedPredicate() async throws {
        let fixture = DatabaseSearchFixture(), model = fixture.makeModel()
        #expect(fixture.connected == 0 && fixture.commands.isEmpty)
        await model.loadTables()
        model.selectedTables = Set(model.objects.map(\.id)); model.query.text = "needle"
        await model.search()
        #expect(fixture.connected == 1)
        #expect(model.completedColumns == 1)
        #expect(model.observations.filter { $0.state == .skipped }.count == 2)
        let firstMatch = model.observations.first(where: \.hasMatches)
        let match = try #require(firstMatch)
        #expect(match.predicate?.condition?.value == "needle")
        model.query.text = "another search"
        #expect(model.pendingSettings)
        await model.openMatch(match)
        #expect(fixture.opened.first?.predicate?.condition?.value == "needle")
        fixture.current = false
        await model.openMatch(match)
        #expect(fixture.opened.count == 1)
        await model.close()
        #expect(fixture.commands.filter { $0.type == "disconnect" }.count == 1)
    }

    @Test func typedInputsPreserveDecimalBinaryEmptyNullAndSQLiteStorage() throws {
        #expect(DatabaseSearchColumnKind.classify("point") == .other)
        #expect(DatabaseSearchColumnKind.classify("interval") == .other)
        #expect(DatabaseSearchColumnKind.classify("numeric(20,4)[]") == .other)
        var query = DatabaseSearchQuery(text: "9007199254740993.000000000000000001", valueKind: .number)
        #expect(try query.predicate(column: "n", nativeType: "numeric(65,30)", engine: .postgresql, typedSQLite: false).condition?.value == query.text)
        query.valueKind = .binary; query.text = "AP8="
        #expect(try query.predicate(column: "b", nativeType: "bytea", engine: .postgresql, typedSQLite: false).condition?.value == "AP8=")
        #expect(try query.predicate(column: "any", nativeType: "ANY", engine: .sqlite, typedSQLite: true).condition?.sqliteValue == .init(type: "blob", value: "AP8="))
        query.valueKind = .text
        #expect(try query.predicate(column: "any", nativeType: "ANY", engine: .sqlite, typedSQLite: true).condition?.sqliteValue == .init(type: "text", value: Data("AP8=".utf8).base64EncodedString()))
        query.text = ""
        #expect(try query.predicate(column: "s", nativeType: "text", engine: .postgresql, typedSQLite: false).condition?.value == "")
        query.text = "NULL"
        #expect(try query.predicate(column: "s", nativeType: "text", engine: .postgresql, typedSQLite: false).condition?.operator == "eq")
        query.valueKind = .null
        #expect(try query.predicate(column: "s", nativeType: "text", engine: .postgresql, typedSQLite: false).condition?.operator == "isNull")
        query.valueKind = .sqliteInteger; query.text = "9223372036854775807"
        #expect(try query.predicate(column: "any", nativeType: "ANY", engine: .sqlite, typedSQLite: true).condition?.sqliteValue?.value == query.text)
        #expect(throws: (any Error).self) { try query.predicate(column: "any", nativeType: "ANY", engine: .sqlite, typedSQLite: false) }
        query.mode = .contains
        #expect(throws: (any Error).self) { try query.validate(engine: .sqlite) }
    }

    @Test func schemaScopeAndSearchSettingsKeepExactUnicodeBytes() async throws {
        let fixture = DatabaseSearchFixture()
        fixture.tableNames = ["é", "e\u{301}"]
        let model = fixture.makeModel()
        await model.loadTables()
        #expect(model.objects.count == 2 && Set(model.objects.map(\.id)).count == 2)
        model.selectedTables = Set(model.objects.map(\.id)); model.query.text = "a\u{301}\u{323}"
        await model.search()
        #expect(model.tableReports.count == 2)
        model.query.text = "a\u{323}\u{301}"
        #expect(model.pendingSettings)
        await model.close()
    }

    @Test func deniedObjectsAndBoundedMatchesRemainExplicit() async throws {
        let fixture = DatabaseSearchFixture()
        fixture.tableNames = ["denied", "fixture"]; fixture.deniedTable = "denied"; fixture.rowCount = 200
        let model = fixture.makeModel()
        await model.loadTables()
        model.selectedTables = Set(model.objects.map(\.id)); model.query.text = "needle"
        await model.search()
        #expect(model.tableReports.contains { $0.table.name == "denied" && $0.state == "Unavailable" })
        let firstMatch = model.observations.first(where: \.hasMatches)
        let match = try #require(firstMatch)
        #expect(match.returnedRows == 200 && match.limited)
        #expect(model.notice?.contains("not database-wide row counts") == true)
        await model.close()
    }

    @Test func stopCancelsOnlyOwnedReadAndRejectsLateResults() async throws {
        let fixture = DatabaseSearchFixture(), model = fixture.makeModel()
        await model.loadTables()
        model.selectedTables = Set(model.objects.map(\.id)); model.query.text = "needle"; fixture.pauseBrowse = true
        let task = Task { await model.search() }
        for _ in 0..<100 where fixture.held == nil { await Task.yield() }
        let command = try #require(fixture.heldCommand)
        await model.stop()
        #expect(fixture.commands.last(where: { $0.type == "cancel" })?.queryId == command.queryId)
        fixture.held?.resume(returning: fixture.browse(command)); fixture.held = nil
        await task.value
        #expect(!model.isBusy && model.observations.allSatisfy { !$0.hasMatches })
        #expect(model.tableReports.first?.state == "Stopped")
        await model.close()
    }

    @Test func deadlineStopsQueryAndKeepsUnstartedScopeVisible() async throws {
        let fixture = DatabaseSearchFixture(), gate = DatabaseSearchDeadlineGate()
        fixture.tableNames = ["fixture", "later"]
        let model = fixture.makeModel(deadlineSleep: { try await gate.sleep($0) })
        await model.loadTables()
        model.selectedTables = Set(model.objects.map(\.id)); model.query.text = "needle"; fixture.pauseBrowse = true
        let task = Task { await model.search() }
        for _ in 0..<100 where fixture.held == nil { await Task.yield() }
        let command = try #require(fixture.heldCommand)
        await gate.fire()
        for _ in 0..<100 where model.notice?.contains("deadline") != true { await Task.yield() }
        fixture.held?.resume(returning: fixture.browse(command)); fixture.held = nil
        await task.value
        #expect(model.tableReports.contains { $0.state == "Deadline reached" })
        #expect(model.tableReports.contains { $0.state == "Not started" })
        #expect(fixture.commands.contains { $0.type == "cancel" && $0.queryId == command.queryId })
        await model.close()
    }

    @Test func helperLossNeverReconnectsInsideFailedSearch() async {
        let fixture = DatabaseSearchFixture(), model = fixture.makeModel()
        fixture.tableNames = ["fixture", "later"]
        await model.loadTables()
        model.selectedTables = Set(model.objects.map(\.id)); model.query.text = "needle"; fixture.loseConnection = true
        await model.search()
        #expect(fixture.connected == 1)
        #expect(model.tableReports.contains { $0.state == "Connection lost" })
        #expect(model.tableReports.contains { $0.state == "Not started" })
        #expect(model.notice?.contains("helper connection ended") == true)
        fixture.loseConnection = false
        await model.loadSchemas()
        #expect(fixture.connected == 2)
        await model.close()
    }

    @Test func columnBudgetBoundsSkippedMetadataAsWellAsQueries() async {
        var query = DatabaseSearchQuery(text: "needle", columnKinds: [.text])
        #expect(throws: (any Error).self) { try query.predicate(column: "n", nativeType: "numeric", engine: .postgresql, typedSQLite: false) }
        query.columnKinds = [.binary]
        #expect(throws: (any Error).self) { try query.predicate(column: "label", nativeType: "text", engine: .postgresql, typedSQLite: false) }
        let fixture = DatabaseSearchFixture(), model = fixture.makeModel()
        fixture.metadataOverride = (0...DatabaseValueSearchModel.maximumChecks).map { ["column_\($0)", "text"] }
        await model.loadTables()
        model.selectedTables = Set(model.objects.map(\.id)); model.query = query
        await model.search()
        let reads = fixture.commands.filter { $0.catalog?.kind == "browse" }
        #expect(reads.isEmpty)
        #expect(model.observations.count == DatabaseValueSearchModel.maximumChecks)
        #expect(model.tableReports.first?.state == "Limited")
        await model.close()
    }
}
