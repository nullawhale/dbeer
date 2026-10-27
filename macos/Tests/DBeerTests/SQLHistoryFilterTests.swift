import Foundation
import Testing
@testable import DBeer

// Calendar and picker data only; no views, windows, or desktop input.
struct SQLHistoryFilterTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ month: Int, _ day: Int, hour: Int = 0) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)))
    }

    @Test(arguments: [(3, 8, 23), (11, 1, 25)])
    func customDaysIncludeTheWholeDayAcrossDST(month: Int, day: Int, hours: Int) throws {
        let selected = try date(month, day, hour: 17)
        let bounds = SQLHistoryPeriod.custom.dateBounds(from: selected, through: selected, calendar: calendar)
        let from = try #require(bounds.from)
        let before = try #require(bounds.before)
        #expect(bounds.isValid)
        #expect(from == (try date(month, day)))
        #expect(before == (try date(month, day + 1)))
        #expect(before.timeIntervalSince(from) == Double(hours * 3_600))
        let first = SQLHistoryEntry(date: from, sql: "SELECT 1", outcome: "Completed")
        let last = SQLHistoryEntry(date: before.addingTimeInterval(-0.1), sql: "SELECT 2", outcome: "Completed")
        let nextDay = SQLHistoryEntry(date: before, sql: "SELECT 3", outcome: "Completed")
        #expect(try SQLHistorySearch.results(entries: [first, last, nextDay],
            filter: SQLHistoryFilter(from: from, before: before)) == [last, first])
    }

    @Test func presetPeriodsIncludeTodayAndTheExpectedPreviousCalendarDays() throws {
        let now = try date(11, 1, hour: 15)
        let periods: [(SQLHistoryPeriod, Date)] = [
            (.today, try date(11, 1)), (.last7Days, try date(10, 26)), (.last30Days, try date(10, 3))
        ]
        for (period, expectedStart) in periods {
            let bounds = period.dateBounds(from: .distantPast, through: .distantPast, now: now, calendar: calendar)
            #expect(bounds.isValid && bounds.from == expectedStart)
            #expect(bounds.before == (try date(11, 2)))
        }
        let all = SQLHistoryPeriod.all.dateBounds(from: now, through: now, now: now, calendar: calendar)
        #expect(all.isValid && all.from == nil && all.before == nil)
    }

    @Test func reversedCustomDatesAreInvalidAndCannotReturnExecutions() throws {
        let from = try date(10, 22)
        let through = try date(10, 21)
        let bounds = SQLHistoryPeriod.custom.dateBounds(from: from, through: through, calendar: calendar)
        #expect(!bounds.isValid)
        let history = SQLHistoryEntry(date: from, sql: "SELECT 1", outcome: "Completed")
        #expect(try SQLHistorySearch.results(entries: [history],
            filter: SQLHistoryFilter(from: bounds.from, before: bounds.before)).isEmpty)
        let sameDay = SQLHistoryPeriod.custom.dateBounds(from: try date(10, 22, hour: 20),
            through: try date(10, 22, hour: 1), calendar: calendar)
        #expect(sameDay.isValid)
    }

    private func profile(_ name: String) -> SavedConnection {
        SavedConnection(name: name, settings: ConnectionSettings(host: "db.example.test", port: 5432,
            database: "history", user: "reader", password: "", sslMode: "disable"))
    }

    private func entry(_ profile: SavedConnection) -> SQLHistoryEntry {
        var entry = SQLHistoryEntry(profileID: profile.id, sql: "SELECT 1", outcome: "Completed")
        entry.profile = SQLHistoryProfile(profile)
        return entry
    }

    @Test func optionsRetainDeletedProfilesAndUseCurrentNamesForSavedProfiles() throws {
        var saved = profile("Original name")
        let savedHistory = entry(saved)
        saved.name = "Current name"
        var deleted = profile("Old deleted name")
        let deletedOldHistory = entry(deleted)
        deleted.name = "Latest deleted name"
        let options = SQLHistoryProfileOption.options(connections: [saved],
            history: [savedHistory, deletedOldHistory, entry(deleted)])
        #expect(Set(options.map(\.id)) == [saved.id, deleted.id])
        let savedOption = try #require(options.first { $0.id == saved.id })
        let deletedOption = try #require(options.first { $0.id == deleted.id })
        #expect(savedOption.label.contains("Current name") && !savedOption.label.contains("deleted"))
        #expect(deletedOption.label.contains("Latest deleted name") && deletedOption.label.contains("deleted"))
    }

    @Test func identicalProfileNamesRemainDistinctAndSelectedMissingOptionsSurviveHistoryClear() throws {
        let first = profile("Same name")
        let second = profile("Same name")
        let options = SQLHistoryProfileOption.options(connections: [first, second], history: [])
        #expect(options.count == 2 && Set(options.map(\.label)).count == 2)
        #expect(Set(options.map(\.id)) == [first.id, second.id])
        let selected = SQLHistoryProfileOption.options(connections: [], history: [], selected: .profile(first.id))
        #expect(selected.count == 1 && selected.first?.id == first.id)
        #expect(selected.first?.label.contains("Unavailable") == true)
    }
}
