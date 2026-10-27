import Foundation

struct SQLEditorSymbol: Equatable, Sendable {
    let name: String
    let range: NSRange
    let selectionRange: NSRange
    let kind: String
}

struct SQLEditorDefinition: Equatable, Sendable {
    let range: NSRange?
    let schema: String?
    let name: String
    let kind: String
    let detail: String?
}

struct SQLEditorAnalysis: Equatable, Sendable {
    let version: Int
    let symbols: [SQLEditorSymbol]
    let folds: [NSRange]
    let references: [NSRange]
    let definitions: [SQLEditorDefinition]
}

struct SQLEditorTextEdit: Equatable, Sendable {
    let range: NSRange
    let text: String
}

struct SQLEditorFormatOptions: Equatable, Sendable {
    var insertSpaces = true
    var tabSize = 4
    var keywordCase = "preserve"
}

struct SQLEditorFormatResult: Equatable, Sendable {
    let version: Int
    let edits: [SQLEditorTextEdit]
    let error: String?
}

/// Decode many ranges in linear time instead of rescanning a large document for
/// each outline item or reference. Coordinates remain native UTF-16 offsets.
struct SQLEditorPositionIndex {
    private let units: [UInt16]
    private let starts: [Int]
    init(_ text: String) {
        units = Array(text.utf16)
        var values = [0]
        var index = 0
        while index < units.count {
            if units[index] == 13 {
                if index + 1 < units.count, units[index + 1] == 10 { index += 1 }
                values.append(index + 1)
            } else if units[index] == 10 { values.append(index + 1) }
            index += 1
        }
        starts = values
    }
    func range(_ value: SQLLSPJSON) -> NSRange? {
        func offset(_ position: SQLLSPJSON?) -> Int? {
            guard let line = position?["line"]?.integer, let column = position?["character"]?.integer,
                  starts.indices.contains(line), column >= 0 else { return nil }
            let start = starts[line]
            var end = line + 1 < starts.count ? starts[line + 1] : units.count
            while end > start, units[end - 1] == 10 || units[end - 1] == 13 { end -= 1 }
            guard column <= end - start else { return nil }
            let offset = start + column
            if offset > 0, offset < units.count,
               (0xD800...0xDBFF).contains(units[offset - 1]), (0xDC00...0xDFFF).contains(units[offset]) { return nil }
            return offset
        }
        guard let start = offset(value["start"]), let end = offset(value["end"]), end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
