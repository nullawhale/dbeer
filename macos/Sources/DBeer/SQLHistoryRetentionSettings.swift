import Foundation

struct SQLHistoryRetentionSettings: Codable, Equatable, Sendable {
    static let `default` = SQLHistoryRetentionSettings()
    static let maxEntriesRange = 1...100_000
    static let retentionDaysRange = 1...3_650

    var maxEntries: Int = 1_000
    var retentionDays: Int = 30

    var isValid: Bool {
        Self.maxEntriesRange.contains(maxEntries) && Self.retentionDaysRange.contains(retentionDays)
    }

    var retentionInterval: TimeInterval { TimeInterval(retentionDays) * 24 * 60 * 60 }
}
