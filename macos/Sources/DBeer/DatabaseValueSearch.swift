import Combine
import Foundation

struct DatabaseSearchFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct DatabaseSearchTable: Identifiable, Sendable, Equatable {
    let schema: String
    let name: String
    let kind: String
    var id: Data { Data([schema, name, kind].map { Data($0.utf8).base64EncodedString() }.joined(separator: ":").utf8) }
    var reference: TableReference { .init(schema: schema, name: name, kind: kind) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

enum DatabaseSearchColumnKind: String, CaseIterable, Identifiable, Sendable {
    case text, number, binary, other
    var id: String { rawValue }
    var title: String { switch self { case .text: "Text"; case .number: "Numbers"; case .binary: "Binary"; case .other: "Other types" } }
    static func classify(_ type: String) -> Self {
        let type = type.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !type.hasSuffix("[]") else { return .other }
        let base = String(type.split(separator: "(", maxSplits: 1).first ?? "")
            .replacingOccurrences(of: " unsigned", with: "").trimmingCharacters(in: .whitespaces)
        if ["bytea", "blob", "tinyblob", "mediumblob", "longblob", "binary", "varbinary"].contains(base) { return .binary }
        if ["int", "integer", "int2", "int4", "int8", "tinyint", "smallint", "mediumint", "bigint", "numeric", "decimal", "real", "float", "float4", "float8", "double", "double precision", "money"].contains(base) { return .number }
        if ["text", "tinytext", "mediumtext", "longtext", "varchar", "character varying", "character", "char", "bpchar", "nchar", "nvarchar", "clob", "citext"].contains(base) { return .text }
        return .other
    }
}

enum DatabaseSearchMode: String, CaseIterable, Identifiable, Sendable {
    case exact, contains
    var id: String { rawValue }
    var title: String { self == .exact ? "Exact value" : "Contains text" }
}

enum DatabaseSearchValueKind: String, CaseIterable, Identifiable, Sendable {
    case text, number, binary, null, sqliteInteger, sqliteReal
    var id: String { rawValue }
    var title: String {
        switch self { case .text: "Text"; case .number: "Exact number"; case .binary: "Binary (Base64)"; case .null: "SQL NULL"; case .sqliteInteger: "SQLite INTEGER"; case .sqliteReal: "SQLite REAL" }
    }
    static func available(_ engine: DatabaseEngine) -> [Self] {
        engine == .sqlite ? [.text, .sqliteInteger, .sqliteReal, .binary, .null] : [.text, .number, .binary, .null]
    }
}

struct DatabaseSearchQuery: Sendable, Equatable {
    var text = ""
    var mode: DatabaseSearchMode = .exact
    var valueKind: DatabaseSearchValueKind = .text
    var columnKinds = Set(DatabaseSearchColumnKind.allCases)
    var timeoutSeconds = 60

    static func == (lhs: Self, rhs: Self) -> Bool {
        Data(lhs.text.utf8) == Data(rhs.text.utf8) && lhs.mode == rhs.mode && lhs.valueKind == rhs.valueKind &&
            lhs.columnKinds == rhs.columnKinds && lhs.timeoutSeconds == rhs.timeoutSeconds
    }

    func validate(engine: DatabaseEngine) throws {
        guard DatabaseSearchValueKind.available(engine).contains(valueKind), !columnKinds.isEmpty,
              (15...300).contains(timeoutSeconds), valueKind == .null || text.utf8.count <= 4_096 else {
            throw DatabaseSearchFailure("Choose column types and a supported value of at most 4 KiB, with a deadline from 15 to 300 seconds.")
        }
        guard mode == .exact || valueKind == .text else { throw DatabaseSearchFailure("Contains searches accept text. Choose Exact value for other storage types.") }
        if valueKind != .null, text.contains("\0"), !(engine == .sqlite && valueKind == .text && mode == .exact) {
            throw DatabaseSearchFailure("This search mode cannot represent a NUL character.")
        }
        if valueKind == .binary, Data(base64Encoded: text)?.base64EncodedString() != text {
            throw DatabaseSearchFailure("Enter canonical Base64 bytes for a binary search.")
        }
        if valueKind == .number {
            guard text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]{1,4})?$"#, options: .regularExpression) != nil else {
                throw DatabaseSearchFailure("Enter an exact decimal number. Its text is passed directly to the database adapter.")
            }
        }
        if valueKind == .sqliteInteger, Int64(text) == nil { throw DatabaseSearchFailure("Enter a signed 64-bit SQLite integer.") }
        if valueKind == .sqliteReal, Double(text).map({ !$0.isNaN }) != true { throw DatabaseSearchFailure("Enter a SQLite REAL value. Use SQL NULL for a missing value.") }
    }

    func predicate(column: String, nativeType: String, engine: DatabaseEngine, typedSQLite: Bool) throws -> CatalogFilterExpression {
        try validate(engine: engine)
        let category = DatabaseSearchColumnKind.classify(nativeType)
        guard columnKinds.contains(category) else { throw DatabaseSearchFailure("The column type is outside the selected scope.") }
        if mode == .contains, category != .text { throw DatabaseSearchFailure("Contains currently searches declared textual columns.") }
        if valueKind == .null { return .init(kind: "condition", condition: .init(column: column, operator: "isNull")) }
        if engine != .sqlite {
            if category == .binary && valueKind != .binary { throw DatabaseSearchFailure("Choose Binary (Base64) to search this column.") }
            if category == .number && valueKind == .text { throw DatabaseSearchFailure("Choose Exact number to search numeric columns.") }
            if valueKind == .binary && category != .binary { throw DatabaseSearchFailure("Binary search is limited to binary columns on this engine.") }
            if valueKind == .number && category != .number { throw DatabaseSearchFailure("Exact-number search is limited to numeric columns.") }
        }
        let condition: CatalogFilter
        if engine == .sqlite && mode == .exact {
            guard typedSQLite else { throw DatabaseSearchFailure("The matching helper must support typed SQLite filter values.") }
            let value: SQLiteValue
            switch valueKind {
            case .text: value = .init(type: "text", value: Data(text.utf8).base64EncodedString())
            case .binary: value = .init(type: "blob", value: text)
            case .sqliteInteger: value = .init(type: "integer", value: String(Int64(text)!))
            case .sqliteReal: value = .init(type: "real", value: String(format: "%016llx", Double(text)!.bitPattern))
            default: throw DatabaseSearchFailure("Choose a SQLite storage type for the exact search.")
            }
            condition = .init(column: column, operator: "eq", sqliteValue: value)
        } else { condition = .init(column: column, operator: mode == .contains ? "contains" : "eq", value: text) }
        guard condition.isValid else { throw DatabaseSearchFailure("The search value cannot be represented by this table filter.") }
        return .init(kind: "condition", condition: condition)
    }
}

struct DatabaseSearchObservation: Identifiable, Sendable {
    enum State: String, Sendable { case matched, checked, skipped, failed, limited }
    let id = UUID()
    let table: DatabaseSearchTable
    let column: String
    let state: State
    let returnedRows: Int
    let limited: Bool
    let notice: String?
    let predicate: CatalogFilterExpression?
    var hasMatches: Bool { returnedRows > 0 && predicate != nil }
}

struct DatabaseSearchTableReport: Identifiable, Sendable {
    let table: DatabaseSearchTable
    var state = "Not started"
    var checkedColumns = 0
    var notice: String?
    var id: Data { table.id }
}

/// One explicit search owns a separate read-only session and sequential reads.
@MainActor
final class DatabaseValueSearchModel: ObservableObject, Identifiable {
    static let maximumTables = 100
    static let maximumChecks = 2_000
    let id = UUID()
    let profile: SavedConnection
    @Published var schema: String
    @Published var objectFilter = ""
    @Published var selectedTables: Set<Data> = []
    @Published var query = DatabaseSearchQuery()
    @Published var matchesOnly = true
    @Published private(set) var objects: [DatabaseSearchTable] = []
    @Published private(set) var schemas: [String] = []
    @Published private(set) var observations: [DatabaseSearchObservation] = []
    @Published private(set) var tableReports: [DatabaseSearchTableReport] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isClosing = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var inventoryNotice: String?
    @Published private(set) var capturedQuery: DatabaseSearchQuery?
    @Published private(set) var capturedTables: Set<Data> = []
    @Published private(set) var startedAt: Date?
    private let connect: @MainActor () async throws -> (String, [String])
    private let send: @MainActor (BackendCommand) async throws -> BackendMessage
    private let isCurrent: @MainActor () -> Bool
    private let canStart: @MainActor () -> Bool
    private let cancelPreparation: @MainActor () -> Void
    private let open: @MainActor (DatabaseSearchObservation) async -> Void
    private let deadlineSleep: @Sendable (Duration) async throws -> Void
    private var sessionID: String?
    private var capabilities: Set<String> = []
    private var queryID: String?
    private var metadata: CatalogMetadataRequest?
    private var operation: Task<Void, Never>?
    private var closingTask: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var closed = false

    init(profile: SavedConnection, connect: @escaping @MainActor () async throws -> (String, [String]),
         send: @escaping @MainActor (BackendCommand) async throws -> BackendMessage,
         isCurrent: @escaping @MainActor () -> Bool,
         canStart: @escaping @MainActor () -> Bool = { true },
         cancelPreparation: @escaping @MainActor () -> Void = {},
         open: @escaping @MainActor (DatabaseSearchObservation) async -> Void = { _ in },
         deadlineSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.profile = profile; self.connect = connect; self.send = send; self.isCurrent = isCurrent
        self.canStart = canStart; self.cancelPreparation = cancelPreparation; self.open = open; self.deadlineSleep = deadlineSleep
        schema = profile.engine == .sqlite ? "main" : profile.engine == .postgresql ? "public" : profile.database
    }

    var unavailableReason: String? {
        switch profile.engine {
        case .postgresql, .mysql, .sqlite: nil
        case .mongodb: "This client currently searches relational table values. MongoDB collection fields can be sampled; use its JSON query editor for collection searches."
        case .cassandra: "This client currently searches relational table values. Use Cassandra's key/index filters or CQL to choose valid partition predicates."
        }
    }
    var visibleObjects: [DatabaseSearchTable] {
        objects.filter { objectFilter.isEmpty || ($0.schema + "." + $0.name).localizedCaseInsensitiveContains(objectFilter) }
    }
    var visibleObservations: [DatabaseSearchObservation] { observations.filter { !matchesOnly || $0.hasMatches } }
    var pendingSettings: Bool { capturedQuery.map { $0 != query || capturedTables != selectedTables } ?? false }
    var completedColumns: Int { observations.filter { [.matched, .checked, .limited, .failed].contains($0.state) }.count }
    var canStartAction: Bool { !closed && !isClosing && !isBusy && unavailableReason == nil && isCurrent() && canStart() }
    var canSearch: Bool { canStartAction && !selectedTables.isEmpty && selectedTables.count <= Self.maximumTables }

    func loadSchemas() async {
        await perform { token in
            let reply = try await self.read(.init(kind: "schemas"), token: token)
            let names = reply.catalogRecords.compactMap { $0["name"] }
            guard names.count <= 10_000, Set(names.map { Data($0.utf8) }).count == names.count else { throw BackendTransportError(.invalidMessage) }
            self.schemas = names
            self.inventoryNotice = reply.truncated == true ? "The visible schema list is incomplete. Enter an exact schema name to narrow the scope." : reply.displayNotice
        }
    }

    func loadTables() async {
        let selectedSchema = schema
        guard validBrowseName(selectedSchema) else { error = "Enter an exact schema or database name."; return }
        await perform { token in
            var found: [DatabaseSearchTable] = []
            var issues: [String] = []
            for kind in ["table", "view"] {
                let reply = try await self.read(.init(kind: "objects", schema: selectedSchema, objectKind: kind), token: token)
                if reply.truncated == true { issues.append("The loaded object list is incomplete. Only explicitly selected loaded objects will be searched.") }
                if let issue = reply.displayNotice { issues.append(issue) }
                for record in reply.catalogRecords {
                    guard let name = record["name"], validBrowseName(name), record["kind"] == kind else { throw BackendTransportError(.invalidMessage) }
                    guard found.count < 10_000 else { throw DatabaseSearchFailure("The selected schema exceeds the 10,000-object client scope. Choose a narrower scope.") }
                    found.append(.init(schema: selectedSchema, name: name, kind: kind))
                }
            }
            let retained = self.objects.filter { Data($0.schema.utf8) != Data(selectedSchema.utf8) }
            guard retained.count + found.count <= 10_000, Set(found.map(\.id)).count == found.count else {
                throw DatabaseSearchFailure("The client can retain 10,000 objects. Clear the scope and load a narrower schema.")
            }
            self.objects = (retained + found).sorted { $0.id.lexicographicallyPrecedes($1.id) }
            self.selectedTables.formIntersection(Set(self.objects.map(\.id)))
            self.inventoryNotice = issues.isEmpty ? nil : issues.joined(separator: " ")
        }
    }

    func clearScope() {
        guard !isBusy else { return }
        objects = []; selectedTables = []; inventoryNotice = nil
    }

    func search() async {
        guard canSearch else { return }
        let captured = query
        do { try captured.validate(engine: profile.engine) } catch { self.error = error.localizedDescription; return }
        let tables = objects.filter { selectedTables.contains($0.id) }
        guard tables.count == selectedTables.count else { error = "The selected objects changed. Load and select them again."; return }
        observations = []; tableReports = tables.map { .init(table: $0) }; startedAt = Date()
        capturedQuery = captured; capturedTables = selectedTables
        await perform { [self] token in
            self.deadline = Task { @MainActor [weak self] in
                do { try await self?.deadlineSleep(.seconds(captured.timeoutSeconds)) } catch { return }
                guard let self, self.generation == token, self.isBusy else { return }
                await self.stop(deadlineReached: true)
            }
            defer { self.deadline?.cancel(); self.deadline = nil }
            var checks = 0
            for (tableIndex, table) in tables.enumerated() {
                try self.requireCurrent(token)
                self.tableReports[tableIndex].state = "Reading columns"
                do {
                    let reply = try await self.read(.init(kind: "columns", schema: table.schema, object: table.name, objectKind: table.kind), token: token)
                    let columns = reply.catalogRecords
                    guard reply.truncated != true, (reply.rowCount ?? Int64(columns.count)) <= Int64(columns.count),
                          !columns.isEmpty, columns.count <= 10_000,
                          Set(columns.compactMap { $0["name"].map { Data($0.utf8) } }).count == columns.count else {
                        throw DatabaseSearchFailure("Complete column metadata is unavailable. Reload the selected scope.")
                    }
                    self.tableReports[tableIndex].state = "Searching"
                    for record in columns {
                        try self.requireCurrent(token)
                        guard checks < Self.maximumChecks else {
                            self.tableReports[tableIndex].state = "Limited"
                            self.tableReports[tableIndex].notice = "The search reached its 2,000-column check limit. Narrow the scope."
                            self.notice = "The search reached its column check limit. Remaining objects were not searched."
                            return
                        }
                        checks += 1
                        guard let name = record["name"], validBrowseName(name), let nativeType = record["nativeType"] else { throw BackendTransportError(.invalidMessage) }
                        let predicate: CatalogFilterExpression
                        do {
                            predicate = try captured.predicate(column: name, nativeType: nativeType, engine: self.profile.engine,
                                typedSQLite: self.capabilities.contains(TableCellFilters.sqliteCapability))
                        } catch {
                            self.observations.append(.init(table: table, column: name, state: .skipped, returnedRows: 0,
                                limited: false, notice: error.localizedDescription, predicate: nil))
                            continue
                        }
                        do {
                            let result = try await self.read(.init(kind: "browse", schema: table.schema, object: table.name,
                                objectKind: table.kind, page: 0, filterExpression: predicate), token: token)
                            let count = try self.matchCount(result, column: name, query: captured)
                            let limited = result.truncated == true || count >= 200
                            self.observations.append(.init(table: table, column: name, state: count > 0 ? .matched : limited ? .limited : .checked,
                                returnedRows: count, limited: limited, notice: result.displayNotice, predicate: predicate))
                            self.tableReports[tableIndex].checkedColumns += 1
                        } catch {
                            try self.requireCurrent(token)
                            self.observations.append(.init(table: table, column: name, state: .failed, returnedRows: 0,
                                limited: true, notice: error.localizedDescription, predicate: nil))
                            self.tableReports[tableIndex].notice = "Some column reads failed. Inspect the column report."
                        }
                    }
                    self.tableReports[tableIndex].state = "Checked"
                } catch {
                    try self.requireCurrent(token)
                    self.tableReports[tableIndex].state = "Unavailable"
                    self.tableReports[tableIndex].notice = error.localizedDescription
                }
            }
            self.notice = "Selected object checks finished. Match counts describe at most the first 200 rows returned per column; they are not database-wide row counts."
        }
    }

    func openMatch(_ match: DatabaseSearchObservation) async {
        guard canStartAction, match.hasMatches, observations.contains(where: { $0.id == match.id }) else { return }
        await open(match)
    }

    private func matchCount(_ result: BackendMessage, column: String, query: DatabaseSearchQuery) throws -> Int {
        let columns = result.columns ?? [], rows = result.rows ?? []
        let matching = columns.filter { Data($0.name.utf8) == Data(column.utf8) }
        guard matching.count == 1, matching[0].engine == profile.engine, rows.count <= 200,
              rows.allSatisfy({ $0.count == columns.count }), let count = result.rowCount, (0...200).contains(count),
              count >= Int64(rows.count) else { throw BackendTransportError(.invalidMessage) }
        if profile.engine != .sqlite, (matching[0].encoding == "base64") != (query.valueKind == .binary), query.valueKind != .null {
            throw DatabaseSearchFailure("The column's value representation changed. Reload the selected scope.")
        }
        return Int(count)
    }

    private func perform(_ body: @escaping @MainActor (UInt64) async throws -> Void) async {
        guard canStartAction else { return }
        generation &+= 1
        let token = generation
        isBusy = true; error = nil; notice = nil
        let task = Task { @MainActor in
            do { try await body(token) }
            catch {
                if self.generation == token, !self.closed { self.error = error.localizedDescription }
            }
            self.isBusy = false; self.operation = nil
        }
        operation = task
        await task.value
    }

    private func requireCurrent(_ token: UInt64) throws {
        guard !closed, generation == token, !Task.isCancelled, isCurrent() else { throw CancellationError() }
    }

    private func read(_ selector: CatalogRequest, token: UInt64) async throws -> BackendMessage {
        do { return try await readConnected(selector, token: token) }
        catch {
            if (error as? BackendRemoteError)?.reply.connected == false || error is BackendTransportError {
                let failedSession = sessionID
                helperDidFail()
                if let failedSession { _ = try? await send(.disconnect(sessionId: failedSession)) }
            }
            throw error
        }
    }

    private func readConnected(_ selector: CatalogRequest, token: UInt64) async throws -> BackendMessage {
        try requireCurrent(token)
        if sessionID == nil {
            let (opened, supported) = try await connect()
            do { try requireCurrent(token) } catch { _ = try? await send(.disconnect(sessionId: opened)); throw error }
            sessionID = opened; capabilities = Set(supported)
        }
        try requireCurrent(token)
        guard let sessionID else { throw BackendTransportError(.notReady) }
        let reply: BackendMessage
        if selector.supportsMetadataPaging, capabilities.contains("catalogMetadataV1") {
            let owner = CatalogMetadataRequest(); metadata = owner
            defer { owner.finished = true; if metadata === owner { metadata = nil } }
            reply = try await CatalogMetadataLoader.load(selector, sessionID: sessionID, request: owner,
                isCurrent: { self.generation == token && !self.closed && self.isCurrent() }, send: send)
        } else {
            let query = UUID().uuidString; queryID = query
            defer { queryID = nil }
            reply = try await send(.catalog(sessionId: sessionID, queryId: query, request: selector))
            guard reply.sessionId == sessionID, reply.queryId == query, reply.type == "query.result" else { throw BackendTransportError(.invalidMessage) }
        }
        try requireCurrent(token)
        guard reply.connected != false, reply.transactionStatus == .idle else { throw BackendTransportError(.invalidMessage) }
        return reply
    }

    func stop(deadlineReached: Bool = false) async {
        guard !closed, isBusy else { return }
        generation &+= 1; operation?.cancel(); deadline?.cancel(); cancelPreparation()
        metadata?.cancelled = true
        let activeQuery = metadata?.submitted == true ? metadata?.queryID : queryID
        notice = deadlineReached ? "Search deadline reached. Completed observations are retained; remaining objects were not checked." :
            "Search stopped. Completed observations are retained; remaining objects were not checked."
        for index in tableReports.indices where ["Reading columns", "Searching"].contains(tableReports[index].state) {
            tableReports[index].state = deadlineReached ? "Deadline reached" : "Stopped"
        }
        if let sessionID, let activeQuery { _ = try? await send(.cancel(sessionId: sessionID, queryId: activeQuery)) }
    }

    func helperDidFail() {
        guard !closed else { return }
        generation &+= 1; operation?.cancel(); deadline?.cancel(); cancelPreparation(); sessionID = nil
        for index in tableReports.indices where ["Reading columns", "Searching"].contains(tableReports[index].state) {
            tableReports[index].state = "Connection lost"
        }
        notice = "The helper connection ended. Completed observations are historical. Start an explicit new load or search to reconnect."
    }

    func close() async {
        if let closingTask { await closingTask.value; return }
        isClosing = true
        let task = Task { @MainActor in await self.finishClosing() }
        closingTask = task
        await task.value
    }

    private func finishClosing() async {
        await stop()
        closed = true; generation &+= 1
        await operation?.value
        if let sessionID { _ = try? await send(.disconnect(sessionId: sessionID)) }
        sessionID = nil; observations = []; tableReports = []; isBusy = false
    }
}
