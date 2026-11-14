import AppKit
import Foundation
import Testing
@testable import DBeer

/// Pure arithmetic and native grid objects only; no windows or desktop interaction.
@MainActor
struct GridDataProfileTests {
    private func input(_ rows: [[String?]], column: ResultColumn = .init(index: 0, name: "n", typeOid: 1700, nativeType: "numeric"),
                       kinds: [[String]]? = nil, sqlite: [[SQLiteValue]]? = nil) throws -> GridProfileInput {
        .init(payload: try ResultCopy.selection(columns: [column], rows: rows, valueKinds: kinds, sqliteValues: sqlite,
            rowIndices: Array(rows.indices), columnIndices: [0]),
            scope: .init(title: "Captured selection", notice: "Only loaded rows", partial: true))
    }
    @Test func arbitraryDigitsSignedScientificAndRepeatingAverageStayExact() throws {
        let report = try GridDataProfiler.profile(input([["99999999999999999999999999999999999999999999999999.9"], ["0.1"], [nil]]))
        let column = try #require(report.columns.first)
        #expect(column.sum == "100000000000000000000000000000000000000000000000000")
        #expect(column.average == "50000000000000000000000000000000000000000000000000")
        #expect(column.minimum == "0.1" && column.maximum == "99999999999999999999999999999999999999999999999999.9")
        #expect(column.count == 3 && column.nullCount == 1)
        #expect(try GridDataProfiler.profile(input([["1"], ["0"], ["0"]])).columns[0].average == "1 / 3")
        #expect(ExactProfileDecimal("-1.25e+3")?.text == "-1250")
        #expect(ExactProfileDecimal("-0.0000")?.text == "0")
        #expect(ExactProfileDecimal("-1.25")?.adding(try #require(ExactProfileDecimal("1.25")))?.text == "0")
        #expect(ExactProfileDecimal("1")?.average(count: 40) == "0.025")
        for value in ["NaN", "Infinity", "1e", "1e+", "1e999999999", "--1", ".1", "1.", String(repeating: "9", count: 4097)] {
            #expect(ExactProfileDecimal(value) == nil)
        }
    }
    @Test func nullTextNullEmptyBinaryAndUnicodeUseCapturedIdentity() throws {
        let rows: [[String?]] = [[nil], ["NULL"], [""], ["é"], ["e\u{301}"], ["NULL"]]
        let report = try GridDataProfiler.profile(input(rows, column: .init(index: 0, name: "t", nativeType: "text")))
        let column = report.columns[0]
        #expect(column.sum == nil && column.nullCount == 1 && column.distinctCount == 5)
        #expect(column.frequencies.first?.value == "NULL" && column.frequencies.first?.count == 2)
        #expect(column.frequencies.contains { $0.label == "SQL NULL" })
        #expect(column.frequencies.contains { $0.label == "Empty string" })
        #expect(Set(column.frequencies.map(\.id)).count == 5)
        let binary = try GridDataProfiler.profile(input([["AA=="], [nil], [""]],
            column: .init(index: 0, name: "b", nativeType: "bytea", encoding: "base64")))
        #expect(binary.columns[0].frequencies.contains { $0.kind == "binary" && $0.value == "AA==" })
        #expect(binary.columns[0].sum == nil && binary.markdown.contains("binary (Base64)"))
        #expect(binary.columns[0].frequencies.contains { $0.label == "Empty binary (0 bytes)" })
    }
    @Test func nativeApproximationDefaultAndMixedSQLiteStorageNeverCoerce() throws {
        for type in ["double precision", "float8", "real", "text", "numeric[]", "interval"] {
            let report = try GridDataProfiler.profile(input([["1.2"]], column: .init(index: 0, name: "n", nativeType: type)))
            #expect(report.columns[0].sum == nil && report.columns[0].numericNotice != nil)
        }
        let defaults = try GridDataProfiler.profile(input([[nil], ["2"]], kinds: [["default"], ["text"]]))
        #expect(defaults.columns[0].defaultCount == 1 && defaults.columns[0].nullCount == 0 && defaults.columns[0].sum == nil)
        let typed: [[SQLiteValue]] = [[.init(type: "integer", value: "1")], [.init(type: "text", value: "MQ==")],
            [.init(type: "real", value: "3ff0000000000000")], [.init(type: "blob", value: "MQ==")], [.init(type: "null")]]
        let mixed = try GridDataProfiler.profile(input(typed.map { [$0[0].displayText] },
            column: .init(index: 0, name: "any", engine: .sqlite, nativeType: "ANY"), sqlite: typed))
        #expect(mixed.columns[0].sum == nil && mixed.columns[0].nullCount == 1 && mixed.columns[0].distinctCount == 5)
        let integers: [[SQLiteValue]] = [[.init(type: "integer", value: "9223372036854775807")], [.init(type: "integer", value: "1")]]
        let exact = try GridDataProfiler.profile(input(integers.map { [$0[0].displayText] },
            column: .init(index: 0, name: "n", engine: .sqlite, nativeType: "INTEGER"), sqlite: integers))
        #expect(exact.columns[0].sum == "9223372036854775808")
    }
    @Test func budgetsCancelAndTopValuesRemainExplicit() async throws {
        let large = String(repeating: "9", count: 4096)
        let bounded = try GridDataProfiler.profile(input(Array(repeating: [large], count: 600)))
        #expect(bounded.columns[0].sum == nil && bounded.columns[0].numericNotice?.contains("work limit") == true)
        let distributions = try GridDataProfiler.profile(input((0..<30).map { [String($0)] }))
        #expect(distributions.columns[0].frequencies.count == 20 && distributions.columns[0].otherCount == 10)
        let preview = GridProfileFrequency(id: Data(), kind: "text", value: "a" + String(repeating: "\u{301}", count: 1000), count: 1, byteCount: 2001)
        #expect(preview.isPreviewLimited && preview.preview.utf8.count <= 515)
        let oversized = try input([[String(repeating: "x", count: GridProfileLimits.maximumBytes + 1)]])
        #expect(throws: (any Error).self) { try GridDataProfiler.profile(oversized) }
        let canceledInput = try input(Array(repeating: ["1"], count: 1000))
        let canceled = Task.detached { try Task.checkCancellation(); return try GridDataProfiler.profile(canceledInput) }
        canceled.cancel()
        do { _ = try await canceled.value; Issue.record("Canceled arithmetic completed") } catch { #expect(error is CancellationError) }
        let payload = ResultClipboardPayload(version: 1, columns: [.init(index: 0, name: "n")], sourceRows: [], sourceColumnIndices: [0], values: [])
        let empty = try GridDataProfiler.profile(.init(payload: payload, scope: .init(title: "Empty table", notice: "0 rows")))
        #expect(empty.rowCount == 0 && empty.columns[0].sum == nil)
    }
    @Test func matchingRowSelectionAndWholeVisibleColumnMapOriginalTypedRows() async throws {
        let coordinator = ResultTableView.Coordinator(), scroll = coordinator.makeScrollView()
        let columns = [ResultColumn(index: 0, name: "n", typeOid: 1700, nativeType: "numeric"), .init(index: 1, name: "label", nativeType: "text")]
        let rows: [[String?]] = [["1", "hidden"], ["9007199254740993", "shown"], ["2", "hidden"], ["3", "shown"]]
        coordinator.update(columns: columns, rows: rows, in: scroll)
        coordinator.setSearch(query: "shown", columns: [1], matchingOnly: true)
        let table = try #require(scroll.documentView as? ResultGridTableView)
        coordinator.onShowRowDetails = {}
        coordinator.activateCell(.init(row: 1, column: 0))
        guard case .values(let selected) = coordinator.captureProfileSelection() else { Issue.record("Missing range"); return }
        #expect(selected.payload.sourceRows == [3] && selected.payload.values[0][0].value == "3")
        guard case .values(let visible) = coordinator.captureProfileSelection(visibleColumn: 0) else { Issue.record("Missing column"); return }
        #expect(visible.payload.sourceRows == [1, 3] && visible.scope.notice.contains("2 visible of 4 loaded"))
        #expect(try GridDataProfiler.profile(visible).columns[0].sum == "9007199254740996")
        coordinator.profileSelectionAllowed = false
        coordinator.profileSelectionNotice = "Resolve edits"
        guard case .unavailable(let notice) = coordinator.captureProfileSelection() else { Issue.record("Staged result was profiled"); return }
        #expect(notice == "Resolve edits")
    }
    @Test func repeatedRepresentableUpdatesDoNotRestartProfilingAndByteChangesDo() async throws {
        let coordinator = ResultTableView.Coordinator(), scroll = coordinator.makeScrollView()
        let columns = [ResultColumn(index: 0, name: "v", nativeType: "text")]
        var deliveries = 0
        coordinator.onProfileSelection = { _ in deliveries += 1 }
        coordinator.update(columns: columns, rows: [["é"]], in: scroll)
        let table = try #require(scroll.documentView as? ResultGridTableView)
        table.selectRowNumber(0)
        for _ in 0..<10 { await Task.yield() }
        let before = deliveries
        coordinator.update(columns: columns, rows: [["é"]], in: scroll)
        coordinator.publishInspection()
        for _ in 0..<10 { await Task.yield() }
        #expect(deliveries == before)
        coordinator.update(columns: columns, rows: [["e\u{301}"]], in: scroll)
        for _ in 0..<10 { await Task.yield() }
        #expect(deliveries == before + 1)
        guard case .values(let updated) = coordinator.captureProfileSelection() else { Issue.record("Missing selection"); return }
        #expect(Data(updated.payload.values[0][0].value!.utf8) == Data("e\u{301}".utf8))
    }
    @Test func sqliteStorageBitsInvalidateIdenticalRenderedValuesAndCanceledSelectionCannotPublish() async throws {
        let coordinator = ResultTableView.Coordinator(), scroll = coordinator.makeScrollView()
        let columns = [ResultColumn(index: 0, name: "v", engine: .sqlite, nativeType: "dynamic")]
        let first: [[SQLiteValue]] = [[.init(type: "real", value: "7ff8000000000001")]]
        let next: [[SQLiteValue]] = [[.init(type: "real", value: "7ff8000000000002")]]
        coordinator.sqliteValues = first
        var deliveries = 0
        coordinator.onProfileSelection = { _ in deliveries += 1 }
        coordinator.update(columns: columns, rows: first.map { [$0[0].displayText] }, in: scroll)
        let table = try #require(scroll.documentView as? ResultGridTableView)
        table.selectRowNumber(0)
        for _ in 0..<10 { await Task.yield() }
        let previous = deliveries
        coordinator.sqliteValues = next
        coordinator.update(columns: columns, rows: next.map { [$0[0].displayText] }, in: scroll)
        for _ in 0..<10 { await Task.yield() }
        #expect(deliveries == previous + 1)
        guard case .values(let captured) = coordinator.captureProfileSelection() else { Issue.record("Missing typed range"); return }
        #expect(captured.payload.sqliteValues == next)
        #expect(try GridDataProfiler.profile(captured).columns[0].frequencies[0].value == "7ff8000000000002")
        let model = GridProfileSelectionModel()
        model.select(.values(try input(Array(repeating: ["1"], count: 1000))))
        model.select(.unavailable("Reload required"))
        for _ in 0..<20 { await Task.yield() }
        #expect(model.report == nil && !model.isBusy && model.notice == "Reload required")
    }

}
