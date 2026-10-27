import Foundation
import Testing
@testable import DBeer

/// A deterministic local service for model and owned-window tests. It never
/// launches a helper, opens a database, or reads the desktop.
actor ResultComparisonTestBackend: ResultComparisonBackend {
    let job = "comparison-test-job"
    var operations: [String] = []
    var requests: [ResultComparisonRequest] = []
    var shutdowns = 0
    var summary: ResultComparisonSummary
    var rows: [ResultComparisonRow]
    var values: [String: String]
    var nullReferences: Set<String>
    var reportPageSize: Int
    var cellPageSize: Int
    var holdStart: Bool
    var startWaiter: CheckedContinuation<ResultComparisonResponse, Error>?
    var blockedValueRef: String?
    var valueWaiter: CheckedContinuation<ResultComparisonResponse, Error>?
    var blockedValueResponse: ResultComparisonResponse?
    var failPage = false

    init(summary: ResultComparisonSummary, rows: [ResultComparisonRow], values: [String: String] = [:],
         nullReferences: Set<String> = [], reportPageSize: Int = 100, cellPageSize: Int = 100,
         holdStart: Bool = false, blockedValueRef: String? = nil) {
        self.summary = summary; self.rows = rows; self.values = values; self.nullReferences = nullReferences
        self.reportPageSize = reportPageSize; self.cellPageSize = cellPageSize
        self.holdStart = holdStart; self.blockedValueRef = blockedValueRef
    }

    func start(_ request: ResultComparisonRequest) async throws -> ResultComparisonResponse {
        operations.append("start"); requests.append(request)
        if holdStart { return try await withCheckedThrowingContinuation { startWaiter = $0 } }
        return ResultComparisonResponse(jobId: job, state: .pending)
    }

    func resumeStart() {
        startWaiter?.resume(returning: .init(jobId: job, state: .pending)); startWaiter = nil
    }

    func request(_ operation: String, _ request: ResultComparisonRequest) async throws -> ResultComparisonResponse {
        operations.append(operation); requests.append(request)
        switch operation {
        case "status": return .init(jobId: job, state: .completed, summary: summary)
        case "page":
            if failPage { throw BackendTransportError(.unexpectedEOF) }
            let start = Int(request.offset ?? 0)
            let end = min(rows.count, start + min(request.limit ?? 100, reportPageSize))
            let cellStart = request.cellOffset ?? 0
            let pageRows = rows[start..<end].map { source in
                var row = source
                let cellEnd = min(source.cells.count, cellStart + cellPageSize)
                row.cells = Array(source.cells[cellStart..<cellEnd])
                row.cellOffset = cellStart; row.nextCellOffset = cellEnd
                row.cellsTruncated = cellEnd < source.totalCells
                return row
            }
            return .init(jobId: job, state: .completed, page: .init(offset: Int64(start), nextOffset: Int64(end),
                hasMore: end < rows.count, rows: pageRows))
        case "value":
            let ref = request.valueRef ?? ""
            let data = Data((values[ref] ?? "").utf8)
            let start = Int(request.offset ?? 0)
            let end = min(data.count, start + (request.maxBytes ?? 65_536))
            let reply = ResultComparisonResponse(jobId: job, state: .completed,
                value: .init(valueRef: ref, isNull: nullReferences.contains(ref), totalBytes: Int64(data.count),
                    offset: Int64(start), nextOffset: Int64(end), dataBase64: data[start..<end].base64EncodedString(), hasMore: end < data.count))
            if blockedValueRef == ref {
                blockedValueResponse = reply
                return try await withCheckedThrowingContinuation { valueWaiter = $0 }
            }
            return reply
        case "cancel": return .init(jobId: job, state: .cancelled)
        case "close": return .init(jobId: job, state: .closed)
        default: throw BackendRequestError.invalidCommand
        }
    }

    func resumeValue() {
        if let response = blockedValueResponse { valueWaiter?.resume(returning: response) }
        valueWaiter = nil; blockedValueResponse = nil
    }
    func failFollowingPages() { failPage = true }
    func shutdown() async { shutdowns += 1 }
}

@MainActor
enum ResultComparisonTestFixtures {
    static func summary(count: Int64 = 1, complete: Bool = true) -> ResultComparisonSummary {
        .init(leftRows: count, rightRows: count, equalRows: 0, addedRows: 0, deletedRows: 0, changedRows: count,
            ambiguousRows: 0, uncertainRows: 0, reportRows: count, complete: complete, fullEquality: false,
            schemaDifferenceCount: 0, schemaDifferencesTruncated: false, schemaDifferences: [], warnings: [])
    }
    static func preview(_ text: String?, ref: String) -> ResultComparisonValuePreview {
        let source = text ?? ""
        var preview = ""
        for scalar in source.unicodeScalars {
            guard preview.utf8.count + String(scalar).utf8.count <= 256 else { break }
            preview.unicodeScalars.append(scalar)
        }
        return .init(isNull: text == nil, preview: preview, totalBytes: Int64(source.utf8.count),
            truncated: preview.utf8.count < source.utf8.count, valueRef: ref)
    }
    static func row(index: Int64 = 0, columns: Int = 1) -> ResultComparisonRow {
        .init(index: index, kind: "changed", leftIndex: index, rightIndex: index,
            cells: (0..<columns).map { .init(mapping: $0,
                left: preview("before", ref: "left-\(index)-\($0)"), right: preview("after", ref: "right-\(index)-\($0)"),
                different: true, uncertain: false) }, cellOffset: 0, nextCellOffset: columns, totalCells: columns, cellsTruncated: false)
    }
    static func directory() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/r17/native-\(UUID().uuidString)")
    }
    static func snapshots(_ store: ResultSnapshotStore, columns: Int = 1, partial: Bool = false) async throws -> [ResultSnapshotSummary] {
        let capture = ResultSnapshotCapture(title: "Synthetic snapshot", sql: "SELECT fixture;", engine: .postgresql,
            columns: (0..<columns).map { ResultColumn(index: $0, name: "duplicate", nativeType: "text") },
            rows: [Array(repeating: "fixture", count: columns)], partial: partial)
        return [try await store.save(capture), try await store.save(capture)]
    }
    static func configure(_ model: ResultComparisonModel, snapshots: [ResultSnapshotSummary]) async {
        await model.configure(left: snapshots[0].id, right: snapshots[1].id)
        model.setMode(.rowOrder)
    }
    static func waitFor(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await condition())
    }
}

/// Local artifact/configuration/lifecycle checks only; no windows or processes.
@MainActor
struct ResultComparisonModelTests {
    @Test func selectionIsExplicitLazyAndPositionalEvenWithDuplicateNames() async throws {
        let root = ResultComparisonTestFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResultSnapshotStore(rootURL: root)
        let snapshots = try await ResultComparisonTestFixtures.snapshots(store, columns: 3)
        var helperStarts = 0
        let service = ResultComparisonTestBackend(summary: ResultComparisonTestFixtures.summary(), rows: [])
        let model = ResultComparisonModel(store: store, snapshots: snapshots, backendFactory: { helperStarts += 1; return service })
        #expect(model.leftID == nil && model.rightID == nil && model.mode == nil && !model.canStart)
        await model.configure(left: snapshots[0].id, right: snapshots[1].id)
        #expect(helperStarts == 0 && model.mappings.map(\.left) == [0, 1, 2])
        #expect(model.requestedColumns.map(\.right) == [0, 1, 2] && model.mode == nil && !model.canStart)
        model.setMode(.key)
        #expect(!model.canStart)
        model.setKey(left: 1, selected: true)
        #expect(model.canStart && model.requestedColumns[1].key == true)
        model.setMapping(left: 2, right: nil)
        #expect(model.excludedLeft.map(\.index) == [2] && model.excludedRight.map(\.index) == [2])
        model.setMapping(left: 0, right: 1)
        #expect(!model.canStart && model.configurationProblem?.contains("only once") == true)
        model.setMapping(left: 0, right: 0)
        model.setMode(.rowOrder)
        #expect(model.canStart && model.requestedColumns.allSatisfy { $0.key == nil })
        #expect(helperStarts == 0)
        #expect(await service.operations.isEmpty)
        await model.close()
    }

    @Test func pagesAndWideRowColumnsRemainReachableWithoutLoadingEveryCell() async throws {
        let root = ResultComparisonTestFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResultSnapshotStore(rootURL: root)
        let snapshots = try await ResultComparisonTestFixtures.snapshots(store, columns: 5)
        let service = ResultComparisonTestBackend(summary: ResultComparisonTestFixtures.summary(count: 2),
            rows: [ResultComparisonTestFixtures.row(columns: 5), ResultComparisonTestFixtures.row(index: 1, columns: 5)],
            reportPageSize: 1, cellPageSize: 2)
        let model = ResultComparisonModel(store: store, snapshots: snapshots, pollDelay: .seconds(60), backendFactory: { service })
        await ResultComparisonTestFixtures.configure(model, snapshots: snapshots)
        await model.start(); await model.pollNow()
        #expect(model.phase == .completed && model.page?.rows.count == 1 && model.canLoadNext)
        #expect(model.selectedRow?.cells.map(\.mapping) == [0, 1] && model.canLoadNextCells)
        await model.loadNextCells()
        #expect(model.selectedRow?.cells.map(\.mapping) == [2, 3] && model.canLoadNextCells)
        await model.loadNextCells()
        #expect(model.selectedRow?.cells.map(\.mapping) == [4] && !model.canLoadNextCells)
        #expect(model.column(mapping: 4, left: true)?.index == 4)
        await model.loadPreviousCells()
        #expect(model.selectedRow?.cellOffset == 2)
        await model.loadNextPage()
        #expect(model.page?.offset == 1 && model.selectedRow?.index == 1 && model.canLoadPrevious && !model.canLoadNext)
        await model.loadPreviousPage()
        #expect(model.page?.offset == 0 && model.selectedRow?.index == 0 && !model.canLoadPrevious)
        await model.close()
        let operations = await service.operations
        #expect(operations.suffix(2) == ["cancel", "close"])
        #expect(await service.shutdowns >= 1)
    }

    @Test func closeAndStopIgnoreLateAdmissionAndNeverReplaceTheNextComparison() async throws {
        let root = ResultComparisonTestFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResultSnapshotStore(rootURL: root)
        let snapshots = try await ResultComparisonTestFixtures.snapshots(store)
        let slow = ResultComparisonTestBackend(summary: ResultComparisonTestFixtures.summary(), rows: [], holdStart: true)
        let next = ResultComparisonTestBackend(summary: ResultComparisonTestFixtures.summary(), rows: [ResultComparisonTestFixtures.row()])
        var starts = 0
        let model = ResultComparisonModel(store: store, snapshots: snapshots, pollDelay: .seconds(60), backendFactory: {
            starts += 1; return starts == 1 ? slow : next
        })
        await ResultComparisonTestFixtures.configure(model, snapshots: snapshots)
        let admission = Task { await model.start() }
        try await ResultComparisonTestFixtures.waitFor { await slow.startWaiter != nil }
        await model.stop()
        #expect(model.phase == .cancelled)
        #expect(await slow.shutdowns == 1)
        await model.start(); await model.pollNow()
        #expect(model.phase == .completed && starts == 2)
        await slow.resumeStart(); await admission.value
        #expect(model.phase == .completed && model.page?.rows.count == 1 && model.error == nil)
        await model.close()
        #expect(model.phase == .closed && model.page == nil)
        #expect(await slow.operations.suffix(2) == ["cancel", "close"])
    }

    @Test func exactChunkWindowsKeepSplitUnicodeReadableAndBase64Authoritative() async throws {
        let root = ResultComparisonTestFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResultSnapshotStore(rootURL: root)
        let snapshots = try await ResultComparisonTestFixtures.snapshots(store)
        let source = String(repeating: "a", count: 65_535) + "🌍" + String(repeating: "b", count: 70_000)
        let preview = ResultComparisonTestFixtures.preview(source, ref: "large")
        let service = ResultComparisonTestBackend(summary: ResultComparisonTestFixtures.summary(), rows: [ResultComparisonTestFixtures.row()], values: ["large": source])
        let model = ResultComparisonModel(store: store, snapshots: snapshots, pollDelay: .seconds(60), backendFactory: { service })
        await ResultComparisonTestFixtures.configure(model, snapshots: snapshots)
        await model.start(); await model.pollNow()
        await model.inspect(preview, title: "Large exact text", encoding: nil)
        let first = try #require(model.valueChunk)
        #expect(first.data?.count == 65_536 && first.text == nil && model.valueTextWindow?.trailingBytes == 1)
        #expect(first.data == Data(source.utf8).prefix(65_536))
        await model.loadNextValue()
        let second = try #require(model.valueChunk)
        #expect(second.offset == 65_533 && (second.data?.count ?? 0) <= 65_539)
        #expect(model.valueTextWindow?.text.contains("🌍") == true)
        #expect(second.data == Data(source.utf8)[Int(second.offset)..<Int(second.nextOffset)])
        await model.loadPreviousValue()
        #expect(model.valueChunk == first && !model.canLoadPreviousValue)
        await model.close()
    }

    @Test func failedNavigationPreservesTheLastPageAndCloseRejectsLateAdmission() async throws {
        let root = ResultComparisonTestFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResultSnapshotStore(rootURL: root)
        let snapshots = try await ResultComparisonTestFixtures.snapshots(store)
        let service = ResultComparisonTestBackend(summary: ResultComparisonTestFixtures.summary(count: 2),
            rows: [ResultComparisonTestFixtures.row(), ResultComparisonTestFixtures.row(index: 1)], reportPageSize: 1)
        let model = ResultComparisonModel(store: store, snapshots: snapshots, pollDelay: .seconds(60), backendFactory: { service })
        await ResultComparisonTestFixtures.configure(model, snapshots: snapshots)
        await model.start(); await model.pollNow()
        let first = model.page
        await service.failFollowingPages()
        await model.loadNextPage()
        #expect(model.page == first && model.error != nil && !model.canLoadPrevious)
        await model.close()

        let slow = ResultComparisonTestBackend(summary: ResultComparisonTestFixtures.summary(), rows: [], holdStart: true)
        let closing = ResultComparisonModel(store: store, snapshots: snapshots, backendFactory: { slow })
        await ResultComparisonTestFixtures.configure(closing, snapshots: snapshots)
        let admission = Task { await closing.start() }
        try await ResultComparisonTestFixtures.waitFor { await slow.startWaiter != nil }
        await closing.close()
        #expect(closing.phase == .closed)
        await slow.resumeStart(); await admission.value
        #expect(closing.phase == .closed && closing.page == nil && closing.summary == nil)
        #expect(await slow.shutdowns >= 1)
    }

    @Test func nullEmptyAndStaleValueReadsRemainDistinct() async throws {
        let root = ResultComparisonTestFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResultSnapshotStore(rootURL: root)
        let snapshots = try await ResultComparisonTestFixtures.snapshots(store)
        let service = ResultComparisonTestBackend(summary: ResultComparisonTestFixtures.summary(), rows: [ResultComparisonTestFixtures.row()],
            values: ["late": "old value", "empty": ""], nullReferences: ["null"], blockedValueRef: "late")
        let model = ResultComparisonModel(store: store, snapshots: snapshots, pollDelay: .seconds(60), backendFactory: { service })
        await ResultComparisonTestFixtures.configure(model, snapshots: snapshots)
        await model.start(); await model.pollNow()
        let late = Task { await model.inspect(ResultComparisonTestFixtures.preview("old value", ref: "late"), title: "Old", encoding: nil) }
        try await ResultComparisonTestFixtures.waitFor { await service.valueWaiter != nil }
        await model.inspect(ResultComparisonTestFixtures.preview(nil, ref: "null"), title: "Null", encoding: nil)
        #expect(model.valueChunk?.isNull == true && model.valueChunk?.totalBytes == 0)
        await service.resumeValue(); await late.value
        #expect(model.valueChunk?.valueRef == "null" && model.selectedValue?.title == "Null")
        await model.inspect(ResultComparisonTestFixtures.preview("", ref: "empty"), title: "Empty", encoding: nil)
        #expect(model.valueChunk?.isNull == false && model.valueChunk?.text == "")
        await model.close()
    }

    @Test func incompleteInputsRejectAnInvalidFullEqualityConclusion() async throws {
        let root = ResultComparisonTestFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResultSnapshotStore(rootURL: root)
        let snapshots = try await ResultComparisonTestFixtures.snapshots(store, partial: true)
        var invalid = ResultComparisonTestFixtures.summary()
        invalid.equalRows = 1; invalid.changedRows = 0; invalid.reportRows = 0; invalid.fullEquality = true
        let service = ResultComparisonTestBackend(summary: invalid, rows: [])
        let model = ResultComparisonModel(store: store, snapshots: snapshots, pollDelay: .seconds(60), backendFactory: { service })
        await ResultComparisonTestFixtures.configure(model, snapshots: snapshots)
        await model.start(); await model.pollNow()
        #expect(model.phase == .failed && model.summary == nil && model.error != nil)
        #expect(await service.shutdowns >= 1)
        await model.close()
    }
}
