import Foundation

struct EditorSearchOptions: Equatable, Sendable {
    var caseSensitive = false
    var wholeWord = false
    var regularExpression = false
}

enum EditorSearch {
    enum LimitError: LocalizedError {
        case timeLimit, tooManyMatches
        var errorDescription: String? {
            switch self {
            case .timeLimit: "Search took too long. Simplify the expression."
            case .tooManyMatches: "Too many matches. Refine the search."
            }
        }
    }
    static func expression(_ query: String, options: EditorSearchOptions) throws -> NSRegularExpression {
        let body = options.regularExpression ? query : NSRegularExpression.escapedPattern(for: query)
        let pattern = options.wholeWord ? "(?<![\\p{L}\\p{N}_])(?:\(body))(?![\\p{L}\\p{N}_])" : body
        return try NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive])
    }

    static func matches(text: String, query: String, options: EditorSearchOptions,
                        ranges: [NSRange]? = nil) throws -> [NSTextCheckingResult] {
        guard !query.isEmpty else { return [] }
        let expression = try expression(query, options: options)
        let length = text.utf16.count
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var matches: [NSTextCheckingResult] = []
        var failure: LimitError?
        for range in ranges ?? [NSRange(location: 0, length: length)] {
            guard range.location >= 0, range.location <= length, range.length <= length - range.location else { continue }
            expression.enumerateMatches(in: text, options: [.reportProgress], range: range) { match, _, stop in
                if ProcessInfo.processInfo.systemUptime > deadline { failure = .timeLimit; stop.pointee = true; return }
                if let match { matches.append(match) }
                if matches.count > 100_000 { failure = .tooManyMatches; stop.pointee = true }
            }
            if let failure { throw failure }
        }
        return matches.sorted { $0.range.location < $1.range.location }
    }
}
