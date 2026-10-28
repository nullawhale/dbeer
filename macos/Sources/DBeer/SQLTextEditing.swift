import Foundation

/// All ranges address the complete source in UTF-16, regardless of its presentation.
struct SQLTextEdit: Equatable, Sendable {
    var range: NSRange
    var text: String
}

enum SQLTextEditorAction: String, CaseIterable, Sendable {
    case indent, outdent, toggleLineComment, toggleBlockComment
    case duplicateLines, deleteLines, moveLinesUp, moveLinesDown
    case extendSelection, selectNextOccurrence, selectAllOccurrences, addCursorAbove, addCursorBelow

    var undoTitle: String {
        switch self {
        case .indent: "Indent Lines"
        case .outdent: "Outdent Lines"
        case .toggleLineComment: "Toggle Line Comment"
        case .toggleBlockComment: "Toggle Block Comment"
        case .duplicateLines: "Duplicate Lines"
        case .deleteLines: "Delete Lines"
        case .moveLinesUp: "Move Lines Up"
        case .moveLinesDown: "Move Lines Down"
        default: "Edit"
        }
    }
}

enum SQLTextEditing {
    static func normalized(_ ranges: [NSRange], length: Int) -> [NSRange] {
        let valid = ranges.filter { $0.location != NSNotFound && $0.location >= 0 && $0.length >= 0 && $0.location <= length && $0.length <= length - $0.location }
        guard let primary = valid.first else { return [NSRange(location: 0, length: 0)] }
        var merged: [NSRange] = []
        for range in valid.sorted(by: { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }) {
            if let last = merged.last, range == last || range.location < NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else { merged.append(range) }
        }
        if let index = merged.firstIndex(where: { $0.location <= primary.location && NSMaxRange($0) >= NSMaxRange(primary) }) {
            let first = merged.remove(at: index)
            merged.insert(first, at: 0)
        }
        return merged
    }

    static func applying(_ edits: [SQLTextEdit], to text: String) -> String? {
        let source = text as NSString
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        var end = 0
        for edit in sorted {
            guard edit.range.location != NSNotFound, edit.range.location >= end, edit.range.length >= 0,
                  edit.range.location <= source.length, edit.range.length <= source.length - edit.range.location else { return nil }
            end = NSMaxRange(edit.range)
        }
        let result = NSMutableString(string: text)
        for edit in sorted.reversed() { result.replaceCharacters(in: edit.range, with: edit.text) }
        return result as String
    }

    static func insertionCarets(for ranges: [NSRange], edits: [SQLTextEdit]) -> [NSRange] {
        var locations: [NSRange: Int] = [:]
        var delta = 0
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
            locations[edit.range] = edit.range.location + delta + edit.text.utf16.count
            delta += edit.text.utf16.count - edit.range.length
        }
        return ranges.map { NSRange(location: locations[$0] ?? $0.location, length: 0) }
    }

    static func mapped(_ range: NSRange, through edits: [SQLTextEdit]) -> NSRange {
        mappedRanges([range], through: edits)[0]
    }

    static func mappedRanges(_ ranges: [NSRange], through edits: [SQLTextEdit]) -> [NSRange] {
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        var deltas = [0]
        for edit in sorted { deltas.append(deltas.last! + edit.text.utf16.count - edit.range.length) }
        func offset(_ old: Int, endAffinity: Bool) -> Int {
            var low = 0, high = sorted.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(sorted[middle].range) < old { low = middle + 1 } else { high = middle }
            }
            guard low < sorted.count else { return old + deltas[low] }
            let edit = sorted[low]
            guard old >= edit.range.location else { return old + deltas[low] }
            if old == edit.range.location && !endAffinity { return old + deltas[low] }
            return edit.range.location + deltas[low] + edit.text.utf16.count
        }
        return ranges.map { range in
            let start = offset(range.location, endAffinity: range.length == 0)
            let end = offset(NSMaxRange(range), endAffinity: true)
            return NSRange(location: start, length: max(0, end - start))
        }
    }

    static func lineRanges(in text: String, selections: [NSRange]) -> [NSRange] {
        let source = text as NSString
        var result: [NSRange] = []
        var seen: Set<NSRange> = []
        for selection in normalized(selections, length: source.length) {
            var location = selection.location
            let last = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
            repeat {
                let line = source.lineRange(for: NSRange(location: location, length: 0))
                if seen.insert(line).inserted { result.append(line) }
                let next = NSMaxRange(line)
                if next <= location || next > last || next > source.length { break }
                location = next
            } while true
        }
        return result.sorted { $0.location < $1.location }
    }

    static func lineEdits(action: SQLTextEditorAction, text: String, selections: [NSRange], indent: String, engine: DatabaseEngine) -> [SQLTextEdit] {
        let source = text as NSString
        let lines = lineRanges(in: text, selections: selections)
        switch action {
        case .indent: return lines.map { SQLTextEdit(range: NSRange(location: $0.location, length: 0), text: indent) }
        case .outdent:
            return lines.compactMap { line in
                let value = source.substring(with: line)
                let count = value.hasPrefix("\t") ? 1 : value.prefix(indent.count).prefix(while: { $0 == " " }).count
                return count > 0 ? SQLTextEdit(range: NSRange(location: line.location, length: count), text: "") : nil
            }
        case .toggleLineComment:
            guard engine != .mongodb else { return [] }
            let uncomment = lines.allSatisfy { source.substring(with: $0).trimmingCharacters(in: .whitespaces).hasPrefix("--") }
            return lines.map { line in
                let value = source.substring(with: line)
                let leading = value.prefix(while: { $0 == " " || $0 == "\t" }).utf16.count
                let location = line.location + leading
                if uncomment {
                    let count = (source.substring(from: location).hasPrefix("-- ") ? 3 : 2)
                    return SQLTextEdit(range: NSRange(location: location, length: count), text: "")
                }
                return SQLTextEdit(range: NSRange(location: location, length: 0), text: "-- ")
            }
        case .toggleBlockComment:
            guard engine != .mongodb else { return [] }
            var ranges = Set<NSRange>()
            var result: [SQLTextEdit] = []
            for selection in normalized(selections, length: source.length) {
                let range = selection.length == 0 ? source.lineRange(for: selection) : selection
                guard ranges.insert(range).inserted else { continue }
                let value = source.substring(with: range)
                if value.hasPrefix("/*"), value.hasSuffix("*/"), value.utf16.count >= 4 {
                    result.append(SQLTextEdit(range: range, text: String(value.dropFirst(2).dropLast(2))))
                } else {
                    // MySQL and CQL do not allow nested block comments. Refuse
                    // the complete action rather than emitting malformed text.
                    guard !value.contains("/*"), !value.contains("*/") else { return [] }
                    result.append(SQLTextEdit(range: range, text: "/*" + value + "*/"))
                }
            }
            return result
        case .duplicateLines:
            return mergedLines(lines).map { line in
                let value = source.substring(with: line)
                let separator = value.hasSuffix("\n") || value.hasSuffix("\r") ? "" : newline(in: text)
                return SQLTextEdit(range: NSRange(location: NSMaxRange(line), length: 0), text: separator + value)
            }
        case .deleteLines: return mergedLines(lines).map { SQLTextEdit(range: $0, text: "") }
        case .moveLinesUp, .moveLinesDown:
            var result: [SQLTextEdit] = []
            for block in mergedLines(lines) {
                if action == .moveLinesUp, block.location > 0 {
                    let previous = source.lineRange(for: NSRange(location: block.location - 1, length: 0))
                    let moving = source.substring(with: block)
                    let other = source.substring(with: previous)
                    let swapped = swapLines(first: other, second: moving, newline: newline(in: text))
                    result.append(SQLTextEdit(range: NSUnionRange(previous, block), text: swapped))
                } else if action == .moveLinesDown, NSMaxRange(block) < source.length {
                    let next = source.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
                    result.append(SQLTextEdit(range: NSUnionRange(block, next), text: swapLines(first: source.substring(with: block), second: source.substring(with: next), newline: newline(in: text))))
                }
            }
            // Adjacent moved blocks can share a neighbour; keep the batch unambiguous.
            var end = -1
            return result.filter { edit in
                guard edit.range.location >= end else { return false }
                end = NSMaxRange(edit.range)
                return true
            }
        default: return []
        }
    }

    static func selectionsAfterMovingLines(action: SQLTextEditorAction, text: String, selections: [NSRange], edits: [SQLTextEdit]) -> [NSRange] {
        let source = text as NSString
        let blocks = mergedLines(lineRanges(in: text, selections: selections))
        let fallback = mappedRanges(selections, through: edits)
        return zip(selections, fallback).map { selection, mapped in
            guard let block = blocks.first(where: { selection.location >= $0.location && selection.location < NSMaxRange($0) }),
                  let edit = edits.first(where: { $0.range.location <= block.location && NSMaxRange($0.range) >= NSMaxRange(block) }) else { return mapped }
            if action == .moveLinesUp, edit.range.location < block.location {
                return NSRange(location: selection.location - (block.location - edit.range.location), length: selection.length)
            }
            if action == .moveLinesDown, NSMaxRange(edit.range) > NSMaxRange(block) {
                let following = source.substring(with: NSRange(location: NSMaxRange(block), length: NSMaxRange(edit.range) - NSMaxRange(block)))
                let separator = following.hasSuffix("\n") || following.hasSuffix("\r") ? 0 : newline(in: text).utf16.count
                return NSRange(location: selection.location + following.utf16.count + separator, length: selection.length)
            }
            return mapped
        }
    }

    private static func mergedLines(_ lines: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for line in lines {
            if let last = result.last, line.location <= NSMaxRange(last) { result[result.count - 1] = NSUnionRange(last, line) }
            else { result.append(line) }
        }
        return result
    }

    private static func swapLines(first: String, second: String, newline: String) -> String {
        guard !second.hasSuffix("\n"), !second.hasSuffix("\r") else { return second + first }
        let suffix = first.hasSuffix("\r\n") ? "\r\n" : first.hasSuffix("\n") ? "\n" : first.hasSuffix("\r") ? "\r" : newline
        return second + suffix + (first.hasSuffix(suffix) ? String(first.dropLast(suffix.count)) : first)
    }

    static func newline(in text: String) -> String { text.contains("\r\n") ? "\r\n" : "\n" }

    static func wordRange(in text: String, at location: Int) -> NSRange? {
        let source = text as NSString
        guard source.length > 0 else { return nil }
        let units = Array(text.utf16)
        func isWord(_ unit: UInt16) -> Bool {
            unit == 95 || unit >= 128 || (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit)
        }
        var start = min(location, source.length)
        if start == source.length || !isWord(units[start]) {
            guard start > 0, isWord(units[start - 1]) else { return nil }
            start -= 1
        }
        var end = start
        while start > 0, isWord(units[start - 1]) { start -= 1 }
        while end < units.count, isWord(units[end]) { end += 1 }
        return NSRange(location: start, length: end - start)
    }
}
