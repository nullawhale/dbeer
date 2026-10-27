import Foundation

/// A presentation-neutral diff computed from exact captured values by the helper.
/// Highlight offsets are half-open UTF-8 byte ranges, never Cocoa UTF-16 offsets.
struct ComparisonTextDiff: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case complete, limited, binary }
    enum ValueKind: String, Codable, Sendable { case text, null, absent, binary }
    enum LineKind: String, Codable, Sendable { case equal, changed, sourceOnly, targetOnly }
    struct Value: Codable, Equatable, Sendable {
        var kind: ValueKind
        var totalBytes: Int64
        var valid: Bool { totalBytes >= 0 && (![ValueKind.null, .absent].contains(kind) || totalBytes == 0) }
        var label: String? {
            switch kind {
            case .null: "SQL NULL"
            case .absent: "Not present"
            case .binary: "Binary value · \(totalBytes.formatted()) bytes"
            case .text: totalBytes == 0 ? "Empty text" : nil
            }
        }
    }
    struct Highlight: Codable, Equatable, Sendable {
        var start: Int
        var end: Int

        func cocoaRange(in text: String) -> NSRange? {
            guard start >= 0, end > start, end <= text.utf8.count else { return nil }
            let bytes = text.utf8
            let a = bytes.index(bytes.startIndex, offsetBy: start)
            let b = bytes.index(bytes.startIndex, offsetBy: end)
            guard let lower = a.samePosition(in: text.utf16), let upper = b.samePosition(in: text.utf16) else { return nil }
            return NSRange(location: text.utf16.distance(from: text.utf16.startIndex, to: lower),
                           length: text.utf16.distance(from: lower, to: upper))
        }
    }
    struct TextLine: Codable, Equatable, Sendable {
        var number: Int
        var text: String
        var highlights: [Highlight]
        var valid: Bool {
            guard number > 0, !text.contains("\n"), highlights.count <= 16_384 else { return false }
            var previous = 0
            for highlight in highlights {
                guard highlight.start >= previous, highlight.cocoaRange(in: text) != nil else { return false }
                previous = highlight.end
            }
            return true
        }
    }
    struct Line: Codable, Equatable, Sendable {
        var kind: LineKind
        var source: TextLine?
        var target: TextLine?
        var valid: Bool {
            guard source?.valid != false, target?.valid != false else { return false }
            switch kind {
            case .equal:
                return source != nil && target != nil && source?.text.utf8.elementsEqual(target!.text.utf8) == true &&
                    source?.highlights.isEmpty == true && target?.highlights.isEmpty == true
            case .changed: return source != nil && target != nil
            case .sourceOnly: return source != nil && target == nil
            case .targetOnly: return source == nil && target != nil
            }
        }
    }
    var formatVersion: Int
    var status: Status
    var source: Value
    var target: Value
    var lines: [Line]

    var valid: Bool {
        guard formatVersion == 1, source.valid, target.valid, lines.count <= 16_384,
              lines.allSatisfy(\.valid) else { return false }
        if status == .binary { return lines.isEmpty && (source.kind == .binary || target.kind == .binary) }
        guard source.kind != .binary, target.kind != .binary else { return false }
        var sourceNumber = 0, targetNumber = 0
        var sourceBytes: Int64 = 0, targetBytes: Int64 = 0
        for line in lines {
            if let value = line.source {
                guard source.kind == .text, value.number == sourceNumber + 1 else { return false }
                sourceNumber = value.number; sourceBytes += Int64(value.text.utf8.count)
            }
            if let value = line.target {
                guard target.kind == .text, value.number == targetNumber + 1 else { return false }
                targetNumber = value.number; targetBytes += Int64(value.text.utf8.count)
            }
        }
        return sourceBytes <= source.totalBytes && targetBytes <= target.totalBytes && sourceBytes + targetBytes <= 2_097_152
    }
}
