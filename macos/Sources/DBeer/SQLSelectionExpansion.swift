import Foundation

/// Source-only selection scopes. Strings and comments use the dialect parser's
/// token boundaries so punctuation inside them cannot create code blocks.
struct SQLSelectionExpansion {
    private let text: String
    private let ranges: [NSRange]

    init(text: String, engine: DatabaseEngine) {
        self.text = text
        let source = text as NSString
        let units = Array(text.utf16)
        let parsed = SQLScriptParser.parse(text, engine: engine)
        var scopes: [NSRange] = []

        func trimmed(_ range: NSRange) -> NSRange {
            var start = range.location, end = NSMaxRange(range)
            while start < end, let scalar = UnicodeScalar(units[start]), CharacterSet.whitespacesAndNewlines.contains(scalar) { start += 1 }
            while end > start, let scalar = UnicodeScalar(units[end - 1]), CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
            return NSRange(location: start, length: end - start)
        }
        func add(_ range: NSRange) {
            guard range.length > 0 else { return }
            let content = trimmed(range)
            if content.length > 0 { scopes.append(content) }
            scopes.append(range)
        }
        func between(_ start: Int, _ end: Int) {
            let range = trimmed(NSRange(location: start, length: max(0, end - start)))
            if range.length > 0 { scopes.append(range) }
        }

        var namesByEnd: [Int: NSRange] = [:]
        var previousName: NSRange?
        for token in parsed.tokens {
            add(token.range)
            let start = token.range.location, end = NSMaxRange(token.range)
            let value = source.substring(with: token.range)
            if value.hasPrefix("/*"), value.hasSuffix("*/"), token.range.length >= 4 {
                between(start + 2, end - 2)
            } else if token.kind == .comment {
                let prefix = value.hasPrefix("--") || value.hasPrefix("//") ? 2 : 1
                between(start + prefix, end)
            } else if let first = value.utf16.first, [UInt16(39), 34, 96].contains(first),
                      value.utf16.last == first, token.range.length >= 2 {
                between(start + 1, end - 1)
            } else if token.kind == .string, value.hasPrefix("$"),
                      let tagEnd = value.dropFirst().firstIndex(of: "$") {
                let tag = String(value[...tagEnd])
                if value.hasSuffix(tag), token.range.length >= tag.utf16.count * 2 {
                    between(start + tag.utf16.count, end - tag.utf16.count)
                }
            }
            if token.kind == .identifier {
                var name = token.range
                if let previousName, NSMaxRange(previousName) + 1 == start, units[start - 1] == 46 {
                    name = NSUnionRange(previousName, name)
                    add(name)
                }
                previousName = name
                namesByEnd[end] = name
            } else { previousName = nil }
        }

        var brackets: [(unit: UInt16, location: Int)] = []
        var blocks: [NSRange] = []
        var tokenIndex = 0
        var index = 0
        let opening: [UInt16: UInt16] = [41: 40, 93: 91, 125: 123]
        while index < units.count {
            if tokenIndex < parsed.tokens.count, parsed.tokens[tokenIndex].range.location == index {
                let token = parsed.tokens[tokenIndex]
                if token.kind == .keyword {
                    let word = source.substring(with: token.range).uppercased()
                    if word == "CASE" || word == "BEGIN" { blocks.append(token.range) }
                    else if word == "END", let start = blocks.popLast() {
                        between(NSMaxRange(start), index)
                        between(start.location, NSMaxRange(token.range))
                    }
                }
                index = NSMaxRange(token.range)
                tokenIndex += 1
                continue
            }
            let unit = units[index]
            if [40, 91, 123].contains(unit) { brackets.append((unit, index)) }
            else if let match = opening[unit] {
                if let start = brackets.last, start.unit == match {
                    brackets.removeLast()
                    between(start.location + 1, index)
                    between(start.location, index + 1)
                    if match == 40 {
                        var nameEnd = start.location
                        while nameEnd > 0, units[nameEnd - 1] == 32 || units[nameEnd - 1] == 9 { nameEnd -= 1 }
                        if let name = namesByEnd[nameEnd] { between(name.location, index + 1) }
                    }
                } else {
                    // Incomplete input must not pair across mismatched brackets.
                    brackets.removeAll()
                }
            }
            index += 1
        }
        for statement in parsed.statements { add(statement.range) }
        for range in parsed.statementEditorRanges { add(range) }
        add(NSRange(location: 0, length: source.length))
        ranges = Array(Set(scopes)).sorted {
            $0.length == $1.length ? $0.location < $1.location : $0.length < $1.length
        }
    }

    func extending(_ selection: NSRange) -> NSRange {
        let length = text.utf16.count
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= length, selection.length <= length - selection.location else { return selection }
        func contains(_ range: NSRange) -> Bool {
            range.location <= selection.location && NSMaxRange(range) >= NSMaxRange(selection) && range.length > selection.length
        }
        var next = ranges.first(where: contains)
        if let word = SQLTextEditing.wordRange(in: text, at: selection.location), contains(word),
           word.length < (next?.length ?? Int.max) {
            next = word
        }
        return next ?? selection
    }
}
