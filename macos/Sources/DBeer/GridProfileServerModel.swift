import Combine
import Foundation

/// A fresh, bounded first-N browse sample. This owner never borrows a SQL-tab
/// connection and never turns a sample into a claim about the entire table.
@MainActor
final class GridProfileServerModel: ObservableObject, Identifiable {
    let id = UUID()
    let table: TableReference
    let column: ResultColumn
    let engine: DatabaseEngine
    @Published var rowLimit = 1_000
    @Published var timeoutSeconds = 30
    @Published private(set) var report: GridProfileReport?
    @Published private(set) var notice: String?
    @Published private(set) var isBusy = false
    @Published private(set) var rowsCaptured = 0
    private let connect: @MainActor () async throws -> String
    private let send: @MainActor (BackendCommand) async throws -> BackendMessage
    private let isCurrent: @MainActor () -> Bool
    private let canStart: @MainActor () -> Bool
    private let didClose: @MainActor (UUID) -> Void
    private let cancelPreparation: @MainActor () -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private let calculate: @Sendable (GridProfileInput) throws -> GridProfileReport
    private var statisticsTask: Task<GridProfileReport, any Error>?
    private var sessionID: String?
    private var queryID: String?
    private var operation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var closed = false
    private var stopped = false
    private var deadlineReached = false

    init(table: TableReference, column: ResultColumn, engine: DatabaseEngine,
         connect: @escaping @MainActor () async throws -> String,
         send: @escaping @MainActor (BackendCommand) async throws -> BackendMessage,
         isCurrent: @escaping @MainActor () -> Bool,
         canStart: @escaping @MainActor () -> Bool = { true },
         didClose: @escaping @MainActor (UUID) -> Void = { _ in },
         cancelPreparation: @escaping @MainActor () -> Void = {},
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         calculate: @escaping @Sendable (GridProfileInput) throws -> GridProfileReport = { try GridDataProfiler.profile($0) }) {
        self.table = table; self.column = column; self.engine = engine
        self.connect = connect; self.send = send; self.isCurrent = isCurrent
        self.canStart = canStart; self.didClose = didClose
        self.cancelPreparation = cancelPreparation; self.sleep = sleep; self.calculate = calculate
    }
    deinit { deadline?.cancel(); operation?.cancel(); statisticsTask?.cancel() }

    var isClosed: Bool { closed }
    var canStartAction: Bool { !closed && !isBusy && canStart() && isCurrent() }

    func capture() async {
        guard !closed, !isBusy else { return }
        guard canStart() else { notice = "Finish the pending workspace action before starting another sample."; return }
        guard isCurrent() else { notice = "The source context changed. Open a fresh profile from its table view."; return }
        guard [.postgresql, .mysql, .mariadb, .sqlite].contains(engine), (1...GridProfileLimits.maximumSampleRows).contains(rowLimit),
              (15...300).contains(timeoutSeconds) else {
            notice = "Choose 1–10,000 sample rows and a deadline from 15 to 300 seconds on PostgreSQL, MySQL, MariaDB or SQLite."
            return
        }
        generation &+= 1
        let token = generation, limit = rowLimit, seconds = timeoutSeconds
        isBusy = true; report = nil; notice = nil; rowsCaptured = 0; stopped = false; deadlineReached = false
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.deadline = Task { @MainActor [weak self] in
                do { try await self?.sleep(.seconds(seconds)) } catch { return }
                guard let self, self.generation == token, self.isBusy else { return }
                await self.stop(deadlineReached: true)
            }
            await self.collect(token: token, maximumRows: limit)
        }
        operation = task
        await task.value
        if generation == token { operation = nil }
    }

    private func collect(token: UInt64, maximumRows: Int) async {
        let started = Date.now
        var sampledColumn: ResultColumn?
        var sampledOrdinal: Int?
        var capturedValues: [[ResultClipboardValue]] = []
        var capturedSQLite: [[SQLiteValue]]? = engine == .sqlite ? [] : nil
        var capturedNative: [[NativeValue]]?
        var nativeMode: Bool?
        var nativeBudget = NativeValue.MatrixBudget()
        var headers: Data?
        var bytes = 0
        var page = 0
        var cursor: String?
        var cursors = Set<Data>()
        var usedCursor = false
        var partial = false
        var notes: [String] = []
        let headerEncoder = JSONEncoder()
        headerEncoder.outputFormatting = [.sortedKeys]
        do {
            let opened = try await connect()
            sessionID = opened
            try requireCurrent(token)
            while rowsCaptured < maximumRows {
                try requireCurrent(token)
                let query = UUID().uuidString
                queryID = query
                let response = try await send(.catalog(sessionId: opened, queryId: query,
                    request: .init(kind: "browse", schema: table.schema, object: table.name, objectKind: table.kind,
                        page: cursor == nil ? page : nil, cursor: cursor)))
                queryID = nil
                try requireCurrent(token)
                guard response.type == "query.result", response.sessionId == opened, response.queryId == query,
                      response.connected != false, response.transactionStatus == .idle,
                      let columns = response.columns, let rows = response.rows,
                      let ordinal = columns.firstIndex(where: { Data($0.name.utf8) == Data(column.name.utf8) }),
                      Self.sameColumn(columns[ordinal], column), rows.allSatisfy({ $0.count == columns.count }) else {
                    throw GridProfileFailure("The table, selected column or readonly session changed during capture.")
                }
                guard NativeValue.validMatrix(response.nativeValues, rows: rows.count, columns: columns.count),
                      engine != .sqlite || NativeValue.matchesSQLite(response.nativeValues, storage: response.sqliteValues) else {
                    throw GridProfileFailure("The sample returned invalid native-value evidence.")
                }
                let isNative = response.nativeValues != nil
                guard nativeMode == nil || nativeMode == isNative else {
                    throw GridProfileFailure("The sample changed its captured native-value format between pages.")
                }
                nativeMode = isNative
                if isNative, capturedNative == nil { capturedNative = [] }
                let encoded = try headerEncoder.encode(columns)
                if let headers, headers != encoded { throw GridProfileFailure("Column metadata changed between sample pages.") }
                headers = encoded
                if sampledColumn == nil { sampledColumn = columns[ordinal]; sampledOrdinal = ordinal }
                let remaining = maximumRows - rowsCaptured
                let take = min(remaining, rows.count)
                if take > 0 {
                    let selected = try ResultCopy.selection(columns: columns, rows: rows, sqliteValues: response.sqliteValues, nativeValues: response.nativeValues,
                        rowIndices: Array(0..<take), columnIndices: [ordinal])
                    if capturedValues.isEmpty {
                        sampledColumn = selected.columns[0]; sampledOrdinal = selected.sourceColumnIndices[0]
                    }
                    var nextBytes = 0
                    var nextNativeBudget = nativeBudget
                    if let native = selected.nativeValues {
                        for row in native {
                            guard nextNativeBudget.append(row, columns: 1) else {
                                throw GridProfileFailure("The native sample reached its 4 MiB typed-value limit.")
                            }
                            nextBytes += try NativeValuePresentation.canonicalData(row[0]).count
                        }
                    } else { nextBytes = selected.values.reduce(0) { $0 + ($1[0].value?.utf8.count ?? 0) } }
                    guard bytes + nextBytes <= GridProfileLimits.maximumBytes else {
                        throw GridProfileFailure("The first-N sample reached its 8 MiB value limit.")
                    }
                    bytes += nextBytes
                    capturedValues.append(contentsOf: selected.values)
                    nativeBudget = nextNativeBudget
                    if let native = selected.nativeValues { capturedNative?.append(contentsOf: native) }
                    if let typed = selected.sqliteValues { capturedSQLite?.append(contentsOf: typed) }
                    rowsCaptured += take
                }
                if let warning = response.displayNotice, !warning.isEmpty { notes.append(warning); partial = true }
                if response.truncated == true { partial = true; break }
                if rowsCaptured >= maximumRows {
                    partial = rows.count >= take
                    break
                }
                if let next = response.nextCursor {
                    guard cursors.insert(Data(next.utf8)).inserted else { throw GridProfileFailure("The sample cursor repeated.") }
                    cursor = next; usedCursor = true
                } else {
                    if usedCursor || rows.count < 200 { break }
                    cursor = nil; page += 1
                }
            }
        } catch {
            partial = true
            if deadlineReached { notes.append("The sample deadline was reached.") }
            else if stopped || error is CancellationError { notes.append("Capture stopped; only completed pages are included.") }
            else { notes.append(error.localizedDescription) }
        }
        deadline?.cancel(); deadline = nil; queryID = nil
        if let sessionID { _ = try? await send(.disconnect(sessionId: sessionID)) }
        sessionID = nil
        guard generation == token, !closed else { isBusy = false; return }
        if !isCurrent() { partial = true; notes.append("The source binding changed. This report describes the earlier captured context.") }
        if let sampledColumn, let sampledOrdinal {
            let accumulated = ResultClipboardPayload(version: capturedNative == nil ? 1 : 2, columns: [sampledColumn],
                sourceRows: Array(capturedValues.indices), sourceColumnIndices: [sampledOrdinal], values: capturedValues,
                sqliteValues: capturedSQLite, nativeValues: capturedNative)
            let scope = GridProfileScope(title: "First \(maximumRows) rows · \(table.schema).\(table.name) · \(column.name)",
                notice: "\(rowsCaptured) rows observed on a separate readonly connection. Capture is capped at 8 MiB of selected values (4 MiB for typed native evidence) and uses pages of at most 200 rows. Rows use the adapter's default table-browser ordering, without this tab's filters, relationship restrictions or custom sorting. The sample is best effort across pages and reads visible committed data independently from SQL-tab transactions. " + notes.joined(separator: " "),
                partial: partial, capturedAt: started, completedAt: .now)
            do {
                let input = GridProfileInput(payload: accumulated, scope: scope)
                let calculate = self.calculate
                let worker = Task.detached(priority: .userInitiated) { try calculate(input) }
                statisticsTask = worker
                defer { statisticsTask = nil }
                let completed = try await worker.value
                if generation == token, !closed { report = completed }
            } catch {
                if !closed {
                    notice = error is CancellationError
                        ? "Statistical calculation stopped. Capture a new sample to calculate another report."
                        : error.localizedDescription
                }
            }
        } else { notice = notes.isEmpty ? "The selected table returned no sampled rows." : notes.joined(separator: " ") }
        isBusy = false
    }

    private static func sameColumn(_ left: ResultColumn, _ right: ResultColumn) -> Bool {
        Data(left.name.utf8) == Data(right.name.utf8) && Data(left.nativeType.utf8) == Data(right.nativeType.utf8) &&
            left.typeOid == right.typeOid && left.engine == right.engine && left.encoding == right.encoding &&
            left.typeIdentity.map { Data($0.utf8) } == right.typeIdentity.map { Data($0.utf8) }
    }
    private func requireCurrent(_ token: UInt64) throws {
        guard generation == token, !closed, !stopped, !Task.isCancelled, isCurrent() else { throw CancellationError() }
    }
    func stop(deadlineReached: Bool = false) async {
        guard isBusy else { return }
        self.deadlineReached = self.deadlineReached || deadlineReached; stopped = true
        operation?.cancel(); statisticsTask?.cancel(); cancelPreparation()
        if let sessionID, let queryID { _ = try? await send(.cancel(sessionId: sessionID, queryId: queryID)) }
    }
    func close() async {
        guard !closed else { await operation?.value; return }
        closed = true; generation &+= 1
        await stop()
        await operation?.value; operation = nil
        if let sessionID { _ = try? await send(.disconnect(sessionId: sessionID)) }
        sessionID = nil; report = nil
        didClose(id)
    }
}
