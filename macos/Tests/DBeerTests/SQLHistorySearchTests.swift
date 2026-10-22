import Foundation
import Testing
@testable import DBeer

// Model-only search coverage: no windows, application activation, or desktop input.
struct SQLHistorySearchTests {
    private func entry(_ sql: String = "SELECT 1", date: TimeInterval = 100,
                       profileID: UUID? = nil, outcome: SQLHistoryOutcome = .succeeded) -> SQLHistoryEntry {
        var entry = SQLHistoryEntry(date: Date(timeIntervalSince1970: date), profileID: profileID,
            sql: sql, outcome: "legacy")
        entry.outcome = outcome
        entry.legacyOutcome = nil
        return entry
    }

    @Test func searchesTheMiddleAndEndOfLongSQLWithoutUsingThePreview() throws {
        let padding = String(repeating: "SELECT long_fixture_column FROM fixture;\n", count: 20_000)
        let history = entry(padding + "/* middle_sentinel */\n" + padding + "/* end_sentinel */")
        #expect(try SQLHistorySearch.results(entries: [history],
            filter: SQLHistoryFilter(query: "MIDDLE_SENTINEL")) == [history])
        #expect(try SQLHistorySearch.results(entries: [history],
            filter: SQLHistoryFilter(query: "END_SENTINEL")) == [history])
    }

    @Test(arguments: [
        ("SELECT 'Café'", "CAFE"),
        ("SELECT 'Cafe\u{301}'", "CAFÉ"),
        ("SELECT 'Привет мир'", "ВЕТ М"),
        ("SELECT '東京🧪'", "京🧪"),
        ("SELECT 'Ångström'", "angstrom")
    ])
    func findsUnicodeCaseAndCanonicalEquivalentFragments(sql: String, query: String) throws {
        let history = entry(sql)
        #expect(try SQLHistorySearch.results(entries: [history], filter: SQLHistoryFilter(query: query)) == [history])
    }

    @Test func queryIsALiteralSQLFragmentIncludingWhitespaceAndNewlines() throws {
        let matching = entry("SELECT a\n  FROM fixture WHERE marker = '[a-z].*';")
        var other = entry("SELECT a FROM fixture WHERE marker = 'abc';")
        other.errorMessage = "[a-z].*"
        #expect(try SQLHistorySearch.results(entries: [matching, other],
            filter: SQLHistoryFilter(query: "a\n  FROM")) == [matching])
        #expect(try SQLHistorySearch.results(entries: [matching, other],
            filter: SQLHistoryFilter(query: "[a-z].*")) == [matching])
        #expect(try SQLHistorySearch.results(entries: [matching, other],
            filter: SQLHistoryFilter(query: "  ")) == [matching])
        #expect(try SQLHistorySearch.results(entries: [matching, other], filter: SQLHistoryFilter()).count == 2)
    }

    @Test func combinesSQLProfilePeriodAndOutcomeFilters() throws {
        let profileID = UUID()
        let matching = entry("SELECT target", date: 200, profileID: profileID, outcome: .failed)
        let entries = [
            matching,
            entry("SELECT other", date: 200, profileID: profileID, outcome: .failed),
            entry("SELECT target", date: 200, profileID: UUID(), outcome: .failed),
            entry("SELECT target", date: 99, profileID: profileID, outcome: .failed),
            entry("SELECT target", date: 300, profileID: profileID, outcome: .failed),
            entry("SELECT target", date: 200, profileID: profileID, outcome: .succeeded)
        ]
        let filter = SQLHistoryFilter(query: "target", profile: .profile(profileID),
            from: Date(timeIntervalSince1970: 100), before: Date(timeIntervalSince1970: 300), outcome: .failed)
        #expect(try SQLHistorySearch.results(entries: entries, filter: filter) == [matching])
    }

    @Test func profileIdentityWorksWithoutALiveProfileAndUnavailableMeansNoRecordedID() throws {
        let deletedProfileID = UUID()
        let deleted = entry(profileID: deletedProfileID)
        let another = entry(profileID: UUID())
        let unavailable = entry()
        let entries = [deleted, another, unavailable]
        #expect(try SQLHistorySearch.results(entries: entries, filter: SQLHistoryFilter()).count == 3)
        #expect(try SQLHistorySearch.results(entries: entries,
            filter: SQLHistoryFilter(profile: .profile(deletedProfileID))) == [deleted])
        #expect(try SQLHistorySearch.results(entries: entries,
            filter: SQLHistoryFilter(profile: .unavailable)) == [unavailable])
    }

    @Test func dateBoundsIncludeTheStartAndExcludeTheEndUsingTheStoredTerminalDate() throws {
        var start = entry(date: 100)
        start.startedAt = Date(timeIntervalSince1970: 1)
        start.finishedAt = Date(timeIntervalSince1970: 999)
        let middle = entry(date: 200)
        let end = entry(date: 300)
        let entries = [start, middle, end]
        let filter = SQLHistoryFilter(from: Date(timeIntervalSince1970: 100), before: Date(timeIntervalSince1970: 300))
        #expect(try SQLHistorySearch.results(entries: entries, filter: filter) == [middle, start])
        #expect(try SQLHistorySearch.results(entries: entries,
            filter: SQLHistoryFilter(before: Date(timeIntervalSince1970: 100))).isEmpty)
        #expect(try SQLHistorySearch.results(entries: entries,
            filter: SQLHistoryFilter(from: Date(timeIntervalSince1970: 300))) == [end])
        #expect(try SQLHistorySearch.results(entries: entries, filter: SQLHistoryFilter(
            from: Date(timeIntervalSince1970: 300), before: Date(timeIntervalSince1970: 100))).isEmpty)
    }

    @Test func outcomeFiltersKeepEveryTypedOutcomeAndTreatLegacyAsUnknown() throws {
        let outcomes: [SQLHistoryOutcome] = [.succeeded, .failed, .cancelled, .timedOut, .unknown]
        let modern = outcomes.map { entry(outcome: $0) }
        let legacy = SQLHistoryEntry(date: Date(timeIntervalSince1970: 100), sql: "SELECT 1", outcome: "Completed")
        for (index, outcome) in outcomes.enumerated() {
            let matches = try SQLHistorySearch.results(entries: modern + [legacy], filter: SQLHistoryFilter(outcome: outcome))
            #expect(matches == (outcome == .unknown ? [legacy, modern[index]] : [modern[index]]))
        }
    }

    @Test func newestTerminalDatesComeFirstWithReverseInsertionOrderForTies() throws {
        let oldest = entry(date: 1)
        let firstAtSameTime = entry(date: 20)
        let newest = entry(date: 30)
        let lastAtSameTime = entry(date: 20)
        #expect(try SQLHistorySearch.results(entries: [firstAtSameTime, newest, oldest, lastAtSameTime],
            filter: SQLHistoryFilter()) == [newest, lastAtSameTime, firstAtSameTime, oldest])
    }

    @Test func pureSearchCooperatesWithTaskCancellation() async {
        let history = entry()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SQLHistorySearch.results(entries: [history], filter: SQLHistoryFilter())
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test @MainActor func filteringRunsAwayFromTheMainThread() async {
        let probe = SQLHistorySearchExecutionProbe()
        let history = entry()
        let model = SQLHistorySearchModel { entries, filter in
            await probe.record(isMainThread: historySearchIsOnMainThread())
            return try SQLHistorySearch.results(entries: entries, filter: filter)
        }
        await model.update(entries: [history], filter: SQLHistoryFilter()).value
        #expect(await probe.wasOffMainThread)
        #expect(model.results == [history])
        #expect(!model.isSearching)
    }

    @Test @MainActor func newerSearchWinsWhenTheCancelledWorkerStillReturns() async throws {
        let gate = SQLHistorySearchGate()
        let oldEntry = entry("old")
        let newEntry = entry("new")
        let model = SQLHistorySearchModel { _, filter in await gate.run(filter.query) }
        let old = model.update(entries: [oldEntry], filter: SQLHistoryFilter(query: "old"))
        try await waitUntil { await gate.hasStarted("old") }
        let new = model.update(entries: [newEntry], filter: SQLHistoryFilter(query: "new"))
        #expect(model.results.isEmpty)
        #expect(model.isSearching)
        try await waitUntil { await gate.hasStarted("new") }
        await gate.finish("new", with: [newEntry])
        await new.value
        #expect(model.results == [newEntry])
        await gate.finish("old", with: [oldEntry])
        await old.value
        #expect(await gate.wasCancelled("old"))
        #expect(model.results == [newEntry])
        #expect(!model.isSearching)
    }

    @Test @MainActor func clearingOrAddingHistoryCancelsThePendingSnapshot() async throws {
        let gate = SQLHistorySearchGate()
        let oldEntry = entry("old")
        let newEntry = entry("new")
        let model = SQLHistorySearchModel { entries, _ in
            if entries == [oldEntry] { return await gate.run("old") }
            return entries
        }
        let old = model.update(entries: [oldEntry], filter: SQLHistoryFilter())
        try await waitUntil { await gate.hasStarted("old") }
        await model.update(entries: [], filter: SQLHistoryFilter()).value
        #expect(model.results.isEmpty)
        await model.update(entries: [newEntry], filter: SQLHistoryFilter()).value
        #expect(model.results == [newEntry])
        await gate.finish("old", with: [oldEntry])
        await old.value
        #expect(model.results == [newEntry])
        #expect(await gate.wasCancelled("old"))
    }

    @Test @MainActor func cancelPreventsPublishingAndSignalsTheDetachedWorker() async throws {
        let gate = SQLHistorySearchGate()
        let history = entry()
        let model = SQLHistorySearchModel { _, _ in await gate.run("cancel") }
        let pending = model.update(entries: [history], filter: SQLHistoryFilter())
        try await waitUntil { await gate.hasStarted("cancel") }
        model.cancel()
        #expect(model.results.isEmpty)
        #expect(!model.isSearching)
        await gate.finish("cancel", with: [history])
        await pending.value
        #expect(await gate.wasCancelled("cancel"))
        #expect(model.results.isEmpty)
        #expect(!model.isSearching)
    }

    @Test @MainActor func releasingTheModelCancelsWorkWithoutARetainCycle() async throws {
        let gate = SQLHistorySearchGate()
        let history = entry()
        var model: SQLHistorySearchModel? = SQLHistorySearchModel { _, _ in await gate.run("release") }
        weak var weakModel = model
        let pending = model!.update(entries: [history], filter: SQLHistoryFilter())
        try await waitUntil { await gate.hasStarted("release") }
        model = nil
        #expect(weakModel == nil)
        await gate.finish("release", with: [history])
        await pending.value
        #expect(await gate.wasCancelled("release"))
    }

    private func waitUntil(_ predicate: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await predicate(), "The controlled search did not start")
    }
}

private func historySearchIsOnMainThread() -> Bool { Thread.isMainThread }

private actor SQLHistorySearchExecutionProbe {
    private(set) var wasOffMainThread = false
    func record(isMainThread: Bool) { wasOffMainThread = !isMainThread }
}

private actor SQLHistorySearchGate {
    private var started: Set<String> = []
    private var continuations: [String: CheckedContinuation<[SQLHistoryEntry], Never>] = [:]
    private var cancelled: Set<String> = []

    func run(_ name: String) async -> [SQLHistoryEntry] {
        started.insert(name)
        // Intentionally ignore cancellation until resumed, to exercise stale-result guards.
        let entries = await withCheckedContinuation { continuations[name] = $0 }
        if Task.isCancelled { cancelled.insert(name) }
        return entries
    }

    func hasStarted(_ name: String) -> Bool { started.contains(name) }
    func wasCancelled(_ name: String) -> Bool { cancelled.contains(name) }

    func finish(_ name: String, with entries: [SQLHistoryEntry]) {
        continuations.removeValue(forKey: name)?.resume(returning: entries)
    }
}
