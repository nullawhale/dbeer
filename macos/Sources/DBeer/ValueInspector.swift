import Combine
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct InspectedValue: Equatable, Sendable {
    let row: Int
    let column: Int
    let name: String
    let nativeType: String
    let value: ChangeValue

    static func == (lhs: Self, rhs: Self) -> Bool {
        let sameText: Bool
        switch (lhs.value.value, rhs.value.value) {
        case (nil, nil): sameText = true
        case let (left?, right?): sameText = left.utf8.elementsEqual(right.utf8)
        default: sameText = false
        }
        return lhs.row == rhs.row && lhs.column == rhs.column && lhs.name.utf8.elementsEqual(rhs.name.utf8) &&
            lhs.nativeType.utf8.elementsEqual(rhs.nativeType.utf8) && lhs.value.kind == rhs.value.kind && sameText
    }

    static func capture(cell: ResultGridCell?, columns: [ResultColumn], rows: [[String?]],
                        valueKinds: [[String]]? = nil) -> Self? {
        guard let cell, columns.indices.contains(cell.column), rows.indices.contains(cell.row),
              rows[cell.row].indices.contains(cell.column) else { return nil }
        let column = columns[cell.column]
        let text = rows[cell.row][cell.column]
        let explicitKind = valueKinds.flatMap { kinds in
            kinds.indices.contains(cell.row) && kinds[cell.row].indices.contains(cell.column)
                ? kinds[cell.row][cell.column] : nil
        }
        let kind = explicitKind ?? (text == nil ? "null" : column.encoding == "base64" ? "binary" : "text")
        return Self(row: cell.row, column: cell.column, name: column.name, nativeType: column.nativeType,
            value: ChangeValue(kind: kind, value: ["null", "default"].contains(kind) ? nil : text))
    }

    var text: String {
        switch value.kind {
        case "null": "NULL"
        case "default": "DEFAULT"
        default: value.value ?? ""
        }
    }

    var description: String {
        if nativeType == "BSON document" { return "BSON · Canonical Extended JSON" }
        return switch value.kind {
        case "null": "SQL NULL"
        case "default": "DEFAULT"
        case "binary": text.isEmpty ? "Empty binary · Base64" : "Binary · Base64"
        default: text.isEmpty ? "Empty string" : "Text"
        }
    }
}

enum InspectorTokenKind: Equatable, Sendable { case key, string, number, literal, markup, comment }
struct InspectorToken: Equatable, Sendable {
    let range: NSRange
    let kind: InspectorTokenKind
}
struct InspectorContent: Sendable {
    var tokens: [InspectorToken] = []
    var formatted: String?
    var formattedTokens: [InspectorToken] = []
    var notice: String?
}

enum ValueInspectorProcessing {
    static let maximumBytes = 8 * 1_024 * 1_024
    static let maximumTokens = 40_000

    static func prepare(_ value: InspectedValue) throws -> InspectorContent {
        try Task.checkCancellation()
        guard value.value.kind == "text" else { return InspectorContent() }
        guard value.text.utf8.count <= maximumBytes else {
            return InspectorContent(notice: "Structured preview is limited to 8 MiB. The original value is shown.")
        }
        let type = value.nativeType.lowercased()
        let start = value.text.drop(while: { $0.isWhitespace }).first
        if type.contains("json") || start == "{" || start == "[" {
            do {
                var parser = InspectorJSONParser(value.text)
                return try parser.parse()
            } catch is CancellationError { throw CancellationError() }
            catch {
                return InspectorContent(notice: "JSON preview is unavailable: invalid JSON or preview limits exceeded. The original value is shown.")
            }
        }
        if type.contains("xml") || start == "<" {
            // Reject DTDs, including internal entities, before invoking the parser.
            guard !value.text.localizedCaseInsensitiveContains("<!DOCTYPE"),
                  !value.text.localizedCaseInsensitiveContains("<!ENTITY") else {
                return InspectorContent(notice: "XML declarations with DTDs or entities are not previewed. The original value is shown.")
            }
            let parser = XMLParser(data: Data(value.text.utf8))
            let delegate = InspectorXMLDelegate()
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            parser.delegate = delegate
            guard parser.parse() else {
                try Task.checkCancellation()
                return InspectorContent(notice: "Invalid XML. The original value is shown.")
            }
            try Task.checkCancellation()
            let expression = try NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|</?[^<>\"']*(?:(?:\"[^\"]*\"|'[^']*')[^<>\"']*)*>"#)
            let nsText = value.text as NSString
            var tokens: [InspectorToken] = []
            expression.enumerateMatches(in: value.text, range: NSRange(location: 0, length: nsText.length)) { match, _, stop in
                if Task.isCancelled || tokens.count >= maximumTokens { stop.pointee = true; return }
                guard let match else { return }
                let kind: InspectorTokenKind = nsText.substring(with: NSRange(location: match.range.location,
                    length: min(4, match.range.length))) == "<!--" ? .comment : .markup
                tokens.append(InspectorToken(range: match.range, kind: kind))
            }
            try Task.checkCancellation()
            return InspectorContent(tokens: tokens)
        }
        return InspectorContent()
    }

    static func matches(in text: String, query: String) throws -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let text = text as NSString
        var location = 0
        var ranges: [NSRange] = []
        while location < text.length && ranges.count < 10_000 {
            try Task.checkCancellation()
            let range = text.range(of: query, options: [.caseInsensitive, .literal],
                range: NSRange(location: location, length: text.length - location))
            guard range.location != NSNotFound, range.length > 0 else { break }
            ranges.append(range)
            location = NSMaxRange(range)
        }
        return ranges
    }
}

private final class InspectorXMLDelegate: NSObject, XMLParserDelegate {
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if Task.isCancelled { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if Task.isCancelled { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}

/// Validates JSON grammar without converting numbers or rebuilding object dictionaries.
/// Formatting retains every original token, duplicate key, escape and numeric lexeme.
private struct InspectorJSONParser {
    struct Token {
        let text: String
        let range: NSRange
        var kind: InspectorTokenKind?
    }
    enum Invalid: Error { case syntax, limit }
    let bytes: [UInt8]
    var offset = 0
    var utf16Offset = 0
    var tokens: [Token] = []

    init(_ text: String) { bytes = Array(text.utf8) }

    mutating func parse() throws -> InspectorContent {
        try value(depth: 0)
        whitespace()
        guard offset == bytes.count else { throw Invalid.syntax }
        var pretty = ""
        var prettyLength = 0
        var prettyBytes = 0
        var spans: [InspectorToken] = []
        var depth = 0
        func append(_ text: String) throws {
            prettyBytes += text.utf8.count
            guard prettyBytes <= 16 * 1_024 * 1_024 else { throw Invalid.limit }
            pretty += text
            prettyLength += text.utf16.count
        }
        for (index, token) in tokens.enumerated() {
            try Task.checkCancellation()
            let previous = index > 0 ? tokens[index - 1].text : ""
            let next = index + 1 < tokens.count ? tokens[index + 1].text : ""
            if token.text == "}" || token.text == "]" {
                depth -= 1
                if previous != "{" && previous != "[" { try append("\n" + String(repeating: "  ", count: depth)) }
            }
            let start = prettyLength
            try append(token.text)
            if let kind = token.kind { spans.append(InspectorToken(range: NSRange(location: start, length: token.range.length), kind: kind)) }
            switch token.text {
            case "{", "[":
                depth += 1
                if next != "}" && next != "]" { try append("\n" + String(repeating: "  ", count: depth)) }
            case ",": try append("\n" + String(repeating: "  ", count: depth))
            case ":": try append(" ")
            default: break
            }
        }
        return InspectorContent(tokens: tokens.compactMap { token in
            token.kind.map { InspectorToken(range: token.range, kind: $0) }
        }, formatted: pretty, formattedTokens: spans)
    }

    mutating func whitespace() {
        while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1; utf16Offset += 1 }
    }

    mutating func token(_ text: String, kind: InspectorTokenKind? = nil) throws {
        whitespace()
        try Task.checkCancellation()
        guard tokens.count < ValueInspectorProcessing.maximumTokens,
              bytes[offset...].starts(with: text.utf8) else { throw Invalid.syntax }
        tokens.append(Token(text: text, range: NSRange(location: utf16Offset, length: text.utf16.count), kind: kind))
        offset += text.utf8.count
        utf16Offset += text.utf16.count
    }

    mutating func value(depth: Int) throws {
        try Task.checkCancellation()
        guard depth < 128 else { throw Invalid.limit }
        whitespace()
        guard offset < bytes.count else { throw Invalid.syntax }
        switch bytes[offset] {
        case 123, 91:
            let object = bytes[offset] == 123
            let close: UInt8 = object ? 125 : 93
            try token(object ? "{" : "[")
            whitespace()
            if offset < bytes.count, bytes[offset] == close { try token(object ? "}" : "]"); return }
            while true {
                if object { try string(key: true); try token(":") }
                try value(depth: depth + 1)
                whitespace()
                guard offset < bytes.count else { throw Invalid.syntax }
                if bytes[offset] == close { try token(object ? "}" : "]"); return }
                try token(",")
            }
        case 34: try string(key: false)
        case 116: try token("true", kind: .literal)
        case 102: try token("false", kind: .literal)
        case 110: try token("null", kind: .literal)
        default:
            let start = offset
            var end = offset
            while end < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[end]) { end += 1 }
            let number = String(decoding: bytes[start..<end], as: UTF8.self)
            guard number.range(of: #"\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z"#,
                options: .regularExpression) != nil else { throw Invalid.syntax }
            try token(number, kind: .number)
        }
    }

    mutating func string(key: Bool) throws {
        whitespace()
        guard offset < bytes.count, bytes[offset] == 34 else { throw Invalid.syntax }
        var end = offset + 1
        while end < bytes.count {
            if end % 4096 == 0 { try Task.checkCancellation() }
            if bytes[end] == 34 {
                try token(String(decoding: bytes[offset...end], as: UTF8.self), kind: key ? .key : .string)
                return
            }
            guard bytes[end] >= 32 else { throw Invalid.syntax }
            if bytes[end] == 92 {
                end += 1
                guard end < bytes.count else { throw Invalid.syntax }
                if bytes[end] == 117 {
                    guard end + 4 < bytes.count,
                          bytes[(end + 1)...(end + 4)].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw Invalid.syntax }
                    end += 4
                } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(bytes[end]) { throw Invalid.syntax }
            }
            end += 1
        }
        throw Invalid.syntax
    }
}

@MainActor
final class ValueInspectorModel: ObservableObject {
    typealias Worker = @Sendable (InspectedValue) async throws -> InspectorContent
    @Published private(set) var selection: InspectedValue?
    @Published private(set) var content = InspectorContent()
    @Published private(set) var isProcessing = false
    @Published private(set) var matches: [NSRange] = []
    @Published var matchIndex = 0
    @Published var query = "" { didSet { search() } }
    @Published var formatted = false { didSet { search() } }
    private let worker: Worker
    private var generation = UUID()
    private var searchGeneration = UUID()
    private var processing: Task<Void, Never>?
    private var searching: Task<Void, Never>?

    init(worker: @escaping Worker = { try ValueInspectorProcessing.prepare($0) }) { self.worker = worker }
    var text: String { formatted ? content.formatted ?? selection?.text ?? "" : selection?.text ?? "" }
    var tokens: [InspectorToken] { formatted && content.formatted != nil ? content.formattedTokens : content.tokens }

    @discardableResult
    func select(_ value: InspectedValue?) -> Task<Void, Never>? {
        guard selection != value else { return processing }
        processing?.cancel()
        generation = UUID()
        selection = value
        content = InspectorContent()
        isProcessing = value != nil
        search()
        guard let value else { processing = nil; return nil }
        let generation = generation
        let worker = worker
        let task = Task.detached(priority: .userInitiated) { try await worker(value) }
        processing = Task { [weak self] in
            let result = try? await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.content = result ?? InspectorContent(notice: "Preview unavailable. The original value is shown.")
            self.isProcessing = false
            self.search()
        }
        return processing
    }

    @discardableResult
    func search() -> Task<Void, Never> {
        searching?.cancel()
        searchGeneration = UUID()
        let generation = searchGeneration
        matches = []
        matchIndex = 0
        let text = text
        let query = query
        let task = Task.detached(priority: .userInitiated) { try ValueInspectorProcessing.matches(in: text, query: query) }
        let delivery = Task { [weak self] in
            let ranges = try? await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
            self.matches = ranges ?? []
        }
        searching = delivery
        return delivery
    }

    func moveMatch(_ direction: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + direction + matches.count) % matches.count
    }

    func cancel() {
        generation = UUID()
        searchGeneration = UUID()
        processing?.cancel()
        searching?.cancel()
        processing = nil
        searching = nil
        selection = nil
        content = InspectorContent()
        isProcessing = false
        matches = []
    }

    deinit { processing?.cancel(); searching?.cancel() }
}
