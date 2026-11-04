import Foundation

struct MonitoredSession: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var user: String?
    var database: String?
    var client: String?
    var application: String?
    var state: String?
    var query: String?
    var queryAgeMs: String?
    var transactionAgeMs: String?
    var waitType: String?
    var waitEvent: String?
    var isMonitor: Bool
    var queryTruncated: Bool

    var valid: Bool {
        SessionMonitorSnapshot.validNumber(id) &&
        [user, database, client, application, state, waitType, waitEvent].allSatisfy { SessionMonitorSnapshot.validText($0, limit: 1_024) } &&
        SessionMonitorSnapshot.validText(query, limit: 4_096) &&
        [queryAgeMs, transactionAgeMs].allSatisfy { $0.map(SessionMonitorSnapshot.validNumber) ?? true } &&
        (!queryTruncated || query != nil)
    }
}

struct MonitorWait: Codable, Sendable, Equatable, Identifiable {
    var waitingId: String
    var blockingId: String
    var kind: String
    var object: String?
    var lockMode: String?

    var id: String {
        [Optional(waitingId), Optional(blockingId), Optional(kind), object, lockMode]
            .map { $0.map { "v" + Data($0.utf8).base64EncodedString() } ?? "n" }.joined(separator: ":")
    }
    var valid: Bool {
        SessionMonitorSnapshot.validNumber(waitingId) && SessionMonitorSnapshot.validNumber(blockingId) &&
        ["lock", "data", "metadata"].contains(kind) &&
        SessionMonitorSnapshot.validText(object, limit: 1_024) && SessionMonitorSnapshot.validText(lockMode, limit: 1_024)
    }
}

struct SessionMonitorSnapshot: Codable, Sendable, Equatable {
    var engine: DatabaseEngine
    var collectionStartedAt: String
    var collectedAt: String
    var sessions: [MonitoredSession]
    var waits: [MonitorWait]
    var sessionsComplete: Bool
    var waitsComplete: Bool
    var notices: [String]

    static func validNumber(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 20 && (value == "0" || value.utf8.first != 48) &&
        value.utf8.allSatisfy { (48...57).contains($0) }
    }
    static func validText(_ value: String?, limit: Int) -> Bool {
        value.map { $0.utf8.count <= limit && !$0.contains("\0") } ?? true
    }
    private static func date(_ value: String) -> (Int64, Int64)? {
        guard value.utf8.count <= 40,
              value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) == value.startIndex..<value.endIndex else { return nil }
        let bytes = Array(value.utf8)
        func number(_ start: Int, _ count: Int) -> Int64 { Int64(String(decoding: bytes[start..<(start + count)], as: UTF8.self)) ?? -1 }
        let year = number(0, 4), month = number(5, 2), day = number(8, 2)
        let hour = number(11, 2), minute = number(14, 2), second = number(17, 2)
        let leap = year % 400 == 0 || year % 4 == 0 && year % 100 != 0
        let monthDays: [Int64] = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...monthDays[Int(month - 1)]).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        var zoneIndex = 19
        var nanos: Int64 = 0
        if bytes[zoneIndex] == 46 {
            zoneIndex += 1
            let start = zoneIndex
            while zoneIndex < bytes.count, (48...57).contains(bytes[zoneIndex]) { zoneIndex += 1 }
            nanos = number(start, zoneIndex - start)
            for _ in (zoneIndex - start)..<9 { nanos *= 10 }
        }
        var offset: Int64 = 0
        if bytes[zoneIndex] != 90 {
            let zoneHour = number(zoneIndex + 1, 2), zoneMinute = number(zoneIndex + 4, 2)
            guard (0...23).contains(zoneHour), (0...59).contains(zoneMinute) else { return nil }
            offset = (zoneHour * 3_600 + zoneMinute * 60) * (bytes[zoneIndex] == 45 ? -1 : 1)
        }
        // Proleptic Gregorian days, retaining nanosecond ordering without Date's
        // floating-point rounding or permissive calendar normalization.
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return (days * 86_400 + hour * 3_600 + minute * 60 + second - offset, nanos)
    }
    var valid: Bool {
        guard [.postgresql, .mysql].contains(engine),
              let start = Self.date(collectionStartedAt), let end = Self.date(collectedAt), end >= start,
              sessions.count <= 500, waits.count <= 2_000, notices.count <= 16,
              sessions.allSatisfy(\.valid), waits.allSatisfy(\.valid),
              Set(sessions.map(\.id)).count == sessions.count,
              Set(waits.map(\.id)).count == waits.count,
              (sessionsComplete && waitsComplete || !notices.isEmpty),
              notices.allSatisfy({ !$0.isEmpty && Self.validText($0, limit: 1_024) }),
              let bytes = try? JSONEncoder().encode(self), bytes.count <= 4 * 1_024 * 1_024 else { return false }
        return true
    }
}
