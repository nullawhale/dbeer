import Foundation

struct ResultClipboardValue: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case null, text, binary, `default` }
    let kind: Kind
    let value: String?
}

/// Version 1 is shared by every copy command, independently of its text format.
struct ResultClipboardPayload: Codable, Equatable, Sendable {
    let version: Int
    let columns: [ResultColumn]
    let sourceRows: [Int]
    let sourceColumnIndices: [Int]
    let values: [[ResultClipboardValue]]
}

enum ResultCopyFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case tsv, csv, json, markdown, sqlInsert

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tsv: "TSV"
        case .csv: "CSV"
        case .json: "JSON"
        case .markdown: "Markdown"
        case .sqlInsert: "SQL INSERT"
        }
    }
}

struct ResultCopyOptions: Codable, Equatable, Sendable {
    static let `default` = ResultCopyOptions()
    var format: ResultCopyFormat = .tsv
    var includesHeaders = false
}

enum ResultCopyError: LocalizedError {
    case malformed, sqlInsertTargetRequired

    var errorDescription: String? {
        switch self {
        case .malformed: "The selected result is invalid and could not be copied."
        case .sqlInsertTargetRequired: "Choose a target table and dialect to generate SQL INSERT."
        }
    }
}

/// Copying reads loaded values only and never owns or executes a database query.
enum ResultCopy {
    static let nullMarker = "\\N"
    static let defaultMarker = "<DEFAULT>"
    private static let binaryPrefix = "<BINARY:"

    static func selection(columns: [ResultColumn], rows: [[String?]], valueKinds: [[String]]? = nil,
                          rowIndices: [Int], columnIndices: [Int]) throws -> ResultClipboardPayload {
        guard !rowIndices.isEmpty, !columnIndices.isEmpty,
              Set(rowIndices).count == rowIndices.count, Set(columnIndices).count == columnIndices.count,
              rowIndices.allSatisfy(rows.indices.contains), columnIndices.allSatisfy(columns.indices.contains),
              rowIndices.allSatisfy({ rows[$0].count == columns.count }) else { throw ResultCopyError.malformed }
        if let valueKinds {
            guard valueKinds.count == rows.count,
                  rowIndices.allSatisfy({ valueKinds[$0].count == columns.count }) else { throw ResultCopyError.malformed }
        }
        let selectedColumns = columnIndices.map { ordinal in
            let column = columns[ordinal]
            guard isLegacyPostgresBinary(column) else { return column }
            return ResultColumn(index: column.index, name: column.name, typeOid: column.typeOid,
                engine: column.engine, nativeType: column.nativeType, encoding: "base64")
        }
        let values = try rowIndices.map { row in
            try columnIndices.map { column in
                try clipboardValue(rows[row][column], kind: valueKinds?[row][column], column: columns[column])
            }
        }
        let payload = ResultClipboardPayload(version: 1, columns: selectedColumns, sourceRows: rowIndices,
            sourceColumnIndices: columnIndices, values: values)
        try validate(payload)
        return payload
    }

    static func text(_ payload: ResultClipboardPayload, format: ResultCopyFormat,
                     includesHeaders: Bool) throws -> String {
        try validate(payload)
        switch format {
        case .tsv, .csv:
            let separator = format == .tsv ? "\t" : ","
            let newline = format == .tsv ? "\n" : "\r\n"
            var lines: [String] = []
            if includesHeaders {
                lines.append(payload.columns.map { delimitedText($0.name, separator: separator) }.joined(separator: separator))
            }
            lines.append(contentsOf: payload.values.map { row in
                row.map { delimitedValue($0, separator: separator) }.joined(separator: separator)
            })
            return lines.joined(separator: newline)
        case .json:
            // Metadata and row arrays preserve duplicate names and exact numeric strings.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(payload), as: UTF8.self)
        case .markdown:
            let header = try payload.columns.map { column in
                includesHeaders ? markdownEscape(try jsonString(column.name, quoted: false)) : ""
            }
            var lines = [markdownRow(header), markdownRow(Array(repeating: "---", count: header.count))]
            lines.append(contentsOf: try payload.values.map { row in
                markdownRow(try row.map { value in
                    let text = value.kind == .text ? try jsonString(value.value!, quoted: true) : marker(value)
                    return markdownEscape(text)
                })
            })
            return lines.joined(separator: "\n")
        case .sqlInsert:
            // SQL literals belong to the helper adapter and require an explicit target.
            throw ResultCopyError.sqlInsertTargetRequired
        }
    }

    static func validate(_ payload: ResultClipboardPayload) throws {
        guard payload.version == 1, !payload.columns.isEmpty, !payload.values.isEmpty,
              payload.columns.count == payload.sourceColumnIndices.count,
              payload.values.count == payload.sourceRows.count,
              payload.sourceRows.allSatisfy({ $0 >= 0 }), payload.sourceColumnIndices.allSatisfy({ $0 >= 0 }),
              Set(payload.sourceRows).count == payload.sourceRows.count,
              Set(payload.sourceColumnIndices).count == payload.sourceColumnIndices.count,
              Set(payload.columns.map(\.index)).count == payload.columns.count,
              payload.columns.allSatisfy({ $0.index >= 0 && ($0.encoding == nil || $0.encoding == "base64") }),
              payload.values.allSatisfy({ $0.count == payload.columns.count }) else { throw ResultCopyError.malformed }
        for row in payload.values {
            for (index, value) in row.enumerated() {
                switch value.kind {
                case .null, .default:
                    guard value.value == nil else { throw ResultCopyError.malformed }
                case .text:
                    guard value.value != nil, payload.columns[index].encoding == nil,
                          !isLegacyPostgresBinary(payload.columns[index]) else { throw ResultCopyError.malformed }
                case .binary:
                    guard let string = value.value, payload.columns[index].encoding == "base64",
                          canonicalBase64(string) else { throw ResultCopyError.malformed }
                }
            }
        }
    }

    private static func clipboardValue(_ string: String?, kind: String?, column: ResultColumn) throws -> ResultClipboardValue {
        if let kind, ResultClipboardValue.Kind(rawValue: kind) == nil { throw ResultCopyError.malformed }
        if kind == "default" { return ResultClipboardValue(kind: .default, value: nil) }
        if kind == "null" {
            guard string == nil else { throw ResultCopyError.malformed }
            return ResultClipboardValue(kind: .null, value: nil)
        }
        guard let string else {
            guard kind == nil else { throw ResultCopyError.malformed }
            return ResultClipboardValue(kind: .null, value: nil)
        }
        if column.encoding == "base64" {
            guard kind != "text", canonicalBase64(string) else { throw ResultCopyError.malformed }
            return ResultClipboardValue(kind: .binary, value: string)
        }
        if isLegacyPostgresBinary(column) {
            return ResultClipboardValue(kind: .binary, value: try postgresBinary(string))
        }
        guard kind != "binary", column.encoding == nil else { throw ResultCopyError.malformed }
        return ResultClipboardValue(kind: .text, value: string)
    }

    private static func isLegacyPostgresBinary(_ column: ResultColumn) -> Bool {
        column.engine == .postgresql && column.typeOid == 17 && column.encoding == nil
    }

    private static func canonicalBase64(_ string: String) -> Bool {
        Data(base64Encoded: string)?.base64EncodedString() == string
    }

    private static func postgresBinary(_ value: String) throws -> String {
        guard value.utf8.starts(with: "\\x".utf8) else { throw ResultCopyError.malformed }
        let hex = Array(value.utf8.dropFirst(2))
        guard hex.count.isMultiple(of: 2), hex.allSatisfy({ byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }) else { throw ResultCopyError.malformed }
        var bytes = Data()
        bytes.reserveCapacity(hex.count / 2)
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let byte = UInt8(String(decoding: hex[index...index + 1], as: UTF8.self), radix: 16) else {
                throw ResultCopyError.malformed
            }
            bytes.append(byte)
        }
        return bytes.base64EncodedString()
    }

    private static func marker(_ value: ResultClipboardValue) -> String {
        switch value.kind {
        case .null: nullMarker
        case .default: defaultMarker
        case .binary: binaryPrefix + value.value! + ">"
        case .text: value.value!
        }
    }

    private static func delimitedValue(_ value: ResultClipboardValue, separator: String) -> String {
        value.kind == .text ? delimitedText(value.value!, separator: separator) : marker(value)
    }

    /// Only unquoted tokens denote NULL, DEFAULT and binary; literal collisions are quoted.
    private static func delimitedText(_ string: String, separator: String) -> String {
        let separatorScalar = separator.unicodeScalars.first!
        if string.isEmpty || string == nullMarker || string == defaultMarker || string.utf8.starts(with: binaryPrefix.utf8) ||
            string.unicodeScalars.contains(where: { $0 == separatorScalar || $0 == "\n" || $0 == "\r" || $0 == "\"" }) {
            var result = "\""
            for scalar in string.unicodeScalars {
                if scalar == "\"" { result += "\"\"" }
                else { result.unicodeScalars.append(scalar) }
            }
            result += "\""
            return result
        }
        return string
    }

    private static func jsonString(_ string: String, quoted: Bool) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let result = String(decoding: try encoder.encode(string), as: UTF8.self)
        // JSON delimiters are ASCII bytes. Character slicing could also remove
        // a combining mark or prepend scalar joined to either quote.
        return quoted ? result : String(decoding: result.utf8.dropFirst().dropLast(), as: UTF8.self)
    }

    /// Markdown text cells use JSON string notation so line breaks and whitespace
    /// remain explicit. Entities prevent pipes, markup and HTML from changing cells.
    private static func markdownEscape(_ string: String) -> String {
        var result = ""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "|": result += "&#124;"
            case "\\": result += "&#92;"
            case "`": result += "&#96;"
            case "*": result += "&#42;"
            case "_": result += "&#95;"
            case "~": result += "&#126;"
            case "[": result += "&#91;"
            case "]": result += "&#93;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func markdownRow(_ values: [String]) -> String {
        "| " + values.joined(separator: " | ") + " |"
    }
}
