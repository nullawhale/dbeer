import Foundation

enum DelimitedImportDelimiter: String, CaseIterable, Equatable, Sendable {
    case comma, tab

    var label: String { self == .comma ? "CSV (comma)" : "TSV (tab)" }
    fileprivate var byte: UInt8 { self == .comma ? 44 : 9 }
}

struct DelimitedImportOptions: Equatable, Sendable {
    var delimiter: DelimitedImportDelimiter = .comma
    var hasHeader = true
    var nullMarker: String? = "\\N"
    var emptyFieldsAreNull = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.delimiter == rhs.delimiter && lhs.hasHeader == rhs.hasHeader &&
            lhs.emptyFieldsAreNull == rhs.emptyFieldsAreNull &&
            lhs.nullMarker.map { Data($0.utf8) } == rhs.nullMarker.map { Data($0.utf8) }
    }
}

struct DelimitedImportField: Equatable, Sendable {
    var text: String
    var wasQuoted: Bool

    func value(options: DelimitedImportOptions, binary: Bool) throws -> ChangeValue {
        if !wasQuoted && (options.nullMarker.map { text.utf8.elementsEqual($0.utf8) } == true || options.emptyFieldsAreNull && text.isEmpty) {
            return .null
        }
        if binary {
            guard let data = Data(base64Encoded: text), data.base64EncodedString() == text else {
                throw DelimitedImportValueError.invalidBase64
            }
            return ChangeValue(kind: "binary", value: text)
        }
        guard !text.utf8.contains(0) else { throw DelimitedImportValueError.invalidText }
        return ChangeValue(kind: "text", value: text)
    }
}

struct DelimitedImportRow: Equatable, Sendable {
    /// Physical starting line, one based. Quoted embedded newlines advance it.
    var number: Int
    /// Logical record position, one based and including the optional header.
    var ordinal: Int
    var fields: [DelimitedImportField]
}

struct DelimitedImportDocument: Equatable, Sendable {
    var headers: [String]
    var rows: [DelimitedImportRow]

    /// A nil target skips that source field. Output follows source column order;
    /// callers build the destination column list with mapping.compactMap.
    func mappedRows(mapping: [String?], binaryColumns: [String], options: DelimitedImportOptions) throws -> [[ChangeValue]] {
        let targets = mapping.compactMap { $0 }
        let binaryNames = Set(binaryColumns.map { Data($0.utf8) })
        guard !headers.isEmpty, headers.count <= DelimitedTextImport.maximumColumns,
              mapping.count == headers.count, !targets.isEmpty, targets.allSatisfy({ !$0.isEmpty }),
              Set(targets.map { Data($0.utf8) }).count == targets.count else {
            throw DelimitedImportError(line: 1, column: 1, reason: .invalidMapping)
        }
        guard rows.count <= DelimitedTextImport.maximumRows else {
            throw DelimitedImportError(line: rows.last?.number ?? 1, column: 1, reason: .tooManyRows)
        }
        var valueBytes = 0
        var cells = 0
        var result: [[ChangeValue]] = []
        result.reserveCapacity(rows.count)
        for row in rows {
            try Task.checkCancellation()
            guard row.fields.count == headers.count else {
                throw DelimitedImportError(line: row.number, column: min(row.fields.count, headers.count) + 1, reason: .inconsistentWidth)
            }
            cells += row.fields.count
            guard cells <= DelimitedTextImport.maximumCells else {
                throw DelimitedImportError(line: row.number, column: 1, reason: .tooManyCells)
            }
            var values: [ChangeValue] = []
            values.reserveCapacity(targets.count)
            for (index, target) in mapping.enumerated() {
                guard let target else { continue }
                let value: ChangeValue
                do { value = try row.fields[index].value(options: options, binary: binaryNames.contains(Data(target.utf8))) }
                catch let error as DelimitedImportValueError {
                    throw DelimitedImportError(line: row.number, column: index + 1,
                        reason: error == .invalidText ? .invalidText : .invalidBase64)
                }
                valueBytes += value.value?.utf8.count ?? 0
                guard valueBytes <= DelimitedTextImport.maximumMappedValueBytes else {
                    throw DelimitedImportError(line: row.number, column: index + 1, reason: .mappedValuesTooLarge)
                }
                values.append(value)
            }
            result.append(values)
        }
        return result
    }
}

enum DelimitedImportValueError: LocalizedError, Equatable, Sendable {
    case invalidBase64, invalidText
    var errorDescription: String? {
        switch self {
        case .invalidBase64: "Use canonical Base64 for a binary column, or an unquoted NULL marker."
        case .invalidText: "Text values cannot contain a NUL character."
        }
    }
}

struct DelimitedImportError: LocalizedError, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case inputTooLarge, invalidUTF8, emptyFile, unexpectedQuote, unclosedQuote, unexpectedAfterQuote
        case inconsistentWidth, tooManyRows, tooManyColumns, tooManyCells, invalidMapping, invalidBase64, invalidText, mappedValuesTooLarge

        var message: String {
            switch self {
            case .inputTooLarge: "The file exceeds the 8 MiB import limit."
            case .invalidUTF8: "The file must contain valid UTF-8 text."
            case .emptyFile: "The file is empty."
            case .unexpectedQuote: "A quoted field must begin with a quote."
            case .unclosedQuote: "The quoted field has no closing quote."
            case .unexpectedAfterQuote: "Only a delimiter or record ending may follow a closing quote."
            case .inconsistentWidth: "The number of fields does not match the first record."
            case .tooManyRows: "Import at most 10,000 data rows."
            case .tooManyColumns: "Import at most 256 columns."
            case .tooManyCells: "Import at most 100,000 data cells."
            case .invalidMapping: "Map at least one source column to a unique destination column."
            case .invalidBase64: "Use canonical Base64 for a binary column, or an unquoted NULL marker."
            case .invalidText: "Text values cannot contain a NUL character."
            case .mappedValuesTooLarge: "Mapped values exceed the 4 MiB import limit."
            }
        }
    }

    var line: Int
    var column: Int
    var reason: Reason
    var errorDescription: String? { "Line \(line), column \(column): " + reason.message }
}

enum DelimitedTextImport {
    static let maximumInputBytes = 8 * 1_024 * 1_024
    static let maximumRows = 10_000
    static let maximumColumns = 256
    /// Data cells only; the optional header has a separate 256-column bound.
    static let maximumCells = 100_000
    static let maximumMappedValueBytes = 4 * 1_024 * 1_024

    /// Synchronous and free of application state. Call from a detached task when
    /// loading a file; all returned values are Sendable.
    static func parse(data: Data, options: DelimitedImportOptions) throws -> DelimitedImportDocument {
        guard data.count <= maximumInputBytes else {
            throw DelimitedImportError(line: 1, column: 1, reason: .inputTooLarge)
        }
        var bytes = Array(data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard !bytes.isEmpty else { throw DelimitedImportError(line: 1, column: 1, reason: .emptyFile) }
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw DelimitedImportError(line: 1, column: 1, reason: .invalidUTF8)
        }
        var parser = Parser(bytes: bytes, options: options)
        return try parser.parse()
    }

    private struct Parser {
        enum State { case start, unquoted, quoted, afterQuote }
        let bytes: [UInt8]
        let options: DelimitedImportOptions
        var index = 0
        var line = 1
        var recordLine = 1
        var ordinal = 1
        var state = State.start
        var pending = false
        var wasQuoted = false
        var field: [UInt8] = []
        var fields: [DelimitedImportField] = []
        var headers: [String]?
        var rows: [DelimitedImportRow] = []
        var cells = 0

        mutating func parse() throws -> DelimitedImportDocument {
            while index < bytes.count {
                if index % 4_096 == 0 { try Task.checkCancellation() }
                let byte = bytes[index]
                if state == .quoted {
                    if byte == 34 {
                        if index + 1 < bytes.count && bytes[index + 1] == 34 {
                            field.append(34)
                            index += 2
                        } else { state = .afterQuote; index += 1 }
                    } else if byte == 13 || byte == 10 {
                        consumeNewline(insideQuote: true)
                    } else { field.append(byte); index += 1 }
                    continue
                }
                if byte == options.delimiter.byte {
                    try finishField()
                    pending = true
                    index += 1
                } else if byte == 13 || byte == 10 {
                    try finishField()
                    try finishRecord()
                    consumeNewline(insideQuote: false)
                    recordLine = line
                } else if state == .afterQuote {
                    throw failure(.unexpectedAfterQuote)
                } else if byte == 34 {
                    guard state == .start else { throw failure(.unexpectedQuote) }
                    wasQuoted = true
                    state = .quoted
                    pending = true
                    index += 1
                } else {
                    field.append(byte)
                    state = .unquoted
                    pending = true
                    index += 1
                }
            }
            if state == .quoted { throw failure(.unclosedQuote) }
            if pending {
                try finishField()
                try finishRecord()
            }
            return DelimitedImportDocument(headers: headers ?? [], rows: rows)
        }

        mutating func finishField() throws {
            guard fields.count < DelimitedTextImport.maximumColumns else { throw failure(.tooManyColumns) }
            fields.append(DelimitedImportField(text: String(decoding: field, as: UTF8.self), wasQuoted: wasQuoted))
            field.removeAll(keepingCapacity: true)
            wasQuoted = false
            state = .start
        }

        mutating func finishRecord() throws {
            if let headers {
                guard fields.count == headers.count else {
                    throw DelimitedImportError(line: recordLine, column: min(fields.count, headers.count) + 1, reason: .inconsistentWidth)
                }
            } else if options.hasHeader {
                headers = fields.map(\.text)
                fields.removeAll(keepingCapacity: true)
                pending = false
                ordinal += 1
                return
            } else { headers = fields.indices.map { "Column \($0 + 1)" } }
            guard rows.count < DelimitedTextImport.maximumRows else {
                throw DelimitedImportError(line: recordLine, column: 1, reason: .tooManyRows)
            }
            cells += fields.count
            guard cells <= DelimitedTextImport.maximumCells else {
                throw DelimitedImportError(line: recordLine, column: 1, reason: .tooManyCells)
            }
            rows.append(DelimitedImportRow(number: recordLine, ordinal: ordinal, fields: fields))
            fields.removeAll(keepingCapacity: true)
            pending = false
            ordinal += 1
        }

        mutating func consumeNewline(insideQuote: Bool) {
            let count = bytes[index] == 13 && index + 1 < bytes.count && bytes[index + 1] == 10 ? 2 : 1
            if insideQuote { field.append(contentsOf: bytes[index..<(index + count)]) }
            index += count
            line += 1
        }

        func failure(_ reason: DelimitedImportError.Reason) -> DelimitedImportError {
            DelimitedImportError(line: line, column: fields.count + 1, reason: reason)
        }
    }
}
