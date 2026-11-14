import Combine
import Foundation

struct GridProfileFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum GridProfileLimits {
    static let maximumCells = 100_000
    static let maximumBytes = 8 * 1_024 * 1_024
    static let maximumArithmeticWork = 2_000_000
    static let maximumSampleRows = 10_000
    static let maximumFrequentValues = 20
}

struct GridProfileScope: Sendable, Equatable {
    var title: String
    var notice: String
    var partial: Bool = false
    var capturedAt: Date = .now
    var completedAt: Date? = nil
}

struct GridProfileInput: Sendable {
    let payload: ResultClipboardPayload
    let scope: GridProfileScope
}

enum GridProfileSelection: Sendable {
    case empty
    case unavailable(String)
    case values(GridProfileInput)
}

struct GridProfileFrequency: Identifiable, Sendable {
    let id: Data
    let kind: String
    let value: String?
    let count: Int
    let byteCount: Int
    var displayKind: String { kind == "binary" ? "binary (Base64)" : kind }
    var label: String {
        if kind == "null" || kind == "SQLite null" || kind == "Native null" { return "SQL NULL" }
        if kind == "default" { return "DEFAULT" }
        if value?.isEmpty == true {
            return kind == "binary" || kind.hasPrefix("Native binary") || kind.hasPrefix("SQLite blob") ? "Empty binary (0 bytes)" : "Empty string"
        }
        return value ?? "Unavailable"
    }
    var preview: String { String(decoding: label.utf8.prefix(512), as: UTF8.self) }
    var isPreviewLimited: Bool { label.utf8.count > 512 }
}

struct GridProfileColumn: Identifiable, Sendable {
    let id: Int
    let sourceColumn: ResultColumn
    let count: Int
    let nullCount: Int
    let defaultCount: Int
    let distinctCount: Int
    let sum: String?
    let average: String?
    let minimum: String?
    let maximum: String?
    let numericNotice: String?
    let frequencies: [GridProfileFrequency]
    var otherCount: Int { count - frequencies.reduce(0) { $0 + $1.count } }
}

struct GridProfileReport: Identifiable, Sendable {
    let id = UUID()
    let scope: GridProfileScope
    let rowCount: Int
    let columns: [GridProfileColumn]
    var cellCount: Int { rowCount * columns.count }
    var nullCount: Int { columns.reduce(0) { $0 + $1.nullCount } }

    var markdown: String {
        var lines = ["# Data profile", "", Self.escaped(scope.title), "", Self.escaped(scope.notice),
            "", "Captured: " + scope.capturedAt.ISO8601Format(),
            "Rows observed: \(rowCount). Cells observed: \(cellCount)."]
        if let completedAt = scope.completedAt { lines.append("Completed: " + completedAt.ISO8601Format()) }
        if scope.partial { lines.append("Coverage is partial or limited to the stated sample.") }
        for column in columns {
            lines += ["", "## " + Self.escaped(column.sourceColumn.name),
                "", "Native type: " + Self.escaped(column.sourceColumn.nativeType),
                "Count: \(column.count). SQL NULL: \(column.nullCount). DEFAULT: \(column.defaultCount). Distinct captured representations: \(column.distinctCount)."]
            if let sum = column.sum {
                lines.append("Exact sum: \(sum). Average: \(column.average ?? "Unavailable"). Minimum: \(column.minimum ?? "Unavailable"). Maximum: \(column.maximum ?? "Unavailable").")
            }
            if column.average?.contains(" / ") == true { lines.append("The average is an exact fraction with a nonterminating decimal expansion.") }
            if let notice = column.numericNotice { lines.append(Self.escaped(notice)) }
            lines += ["", "| Captured representation | Count | Proportion |", "| --- | --- | --- |"]
            for value in column.frequencies {
                let preview = value.preview
                let suffix = value.isPreviewLimited ? " … (\(value.byteCount) bytes)" : ""
                lines.append("| " + Self.escaped(value.displayKind + ": " + preview + suffix) + " | \(value.count) | \(value.count) / \(column.count) |")
            }
            if column.otherCount > 0 { lines.append("| Other observed values | \(column.otherCount) | \(column.otherCount) / \(column.count) |") }
        }
        return lines.joined(separator: "\n")
    }
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "|", with: "&#124;")
            .replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "`", with: "&#96;")
            .replacingOccurrences(of: "[", with: "&#91;").replacingOccurrences(of: "]", with: "&#93;")
            .replacingOccurrences(of: "*", with: "&#42;").replacingOccurrences(of: "_", with: "&#95;")
    }
}

enum GridDataProfiler {
    static func validate(_ input: GridProfileInput) throws {
        let payload = input.payload
        if payload.values.isEmpty {
            guard (payload.version == 1 && payload.nativeValues == nil || payload.version == 2 && payload.nativeValues != nil), !payload.columns.isEmpty, payload.columns.count <= 4_096,
                  payload.sourceRows.isEmpty, payload.sourceColumnIndices.count == payload.columns.count,
                  Set(payload.columns.map(\.index)).count == payload.columns.count,
                  payload.columns.allSatisfy({ $0.index >= 0 && ($0.encoding == nil || $0.encoding == "base64") }),
                  !payload.columns.contains(where: { $0.engine == .sqlite }) || payload.sqliteValues != nil,
                  Set(payload.sourceColumnIndices).count == payload.columns.count,
                  payload.sourceColumnIndices.allSatisfy({ $0 >= 0 }),
                  SQLiteValue.validMatrix(payload.sqliteValues, rows: 0, columns: payload.columns.count),
                  NativeValue.validMatrix(payload.nativeValues, rows: 0, columns: payload.columns.count),
                  (!payload.columns.contains(where: { $0.engine == .sqlite }) || NativeValue.matchesSQLite(payload.nativeValues, storage: payload.sqliteValues)) else {
                throw GridProfileFailure("The empty profile has invalid column metadata.")
            }
        } else { try ResultCopy.validate(payload) }
        let cells = payload.values.count.multipliedReportingOverflow(by: payload.columns.count)
        guard !cells.overflow, cells.partialValue <= GridProfileLimits.maximumCells else {
            throw GridProfileFailure("Select at most 100,000 cells for a loaded-value profile.")
        }
        var bytes = 0
        for (rowIndex, row) in payload.values.enumerated() {
            try Task.checkCancellation()
            for (columnIndex, value) in row.enumerated() {
                if let native = payload.nativeValues?[rowIndex][columnIndex] {
                    bytes += try NativeValuePresentation.canonicalData(native).count
                } else { bytes += value.value?.utf8.count ?? 0 }
                guard bytes <= GridProfileLimits.maximumBytes else {
                    throw GridProfileFailure("Select at most 8 MiB of captured values for a profile.")
                }
            }
        }
    }

    static func profile(_ input: GridProfileInput) throws -> GridProfileReport {
        try validate(input)
        var columns: [GridProfileColumn] = []
        for ordinal in input.payload.columns.indices {
            try Task.checkCancellation()
            columns.append(try profileColumn(input.payload, ordinal: ordinal))
        }
        return GridProfileReport(scope: input.scope, rowCount: input.payload.values.count, columns: columns)
    }

    private static func profileColumn(_ payload: ResultClipboardPayload, ordinal: Int) throws -> GridProfileColumn {
        let column = payload.columns[ordinal]
        var frequencies: [Data: (kind: String, value: String?, count: Int)] = [:]
        var nulls = 0, defaults = 0, numericCount = 0, work = 0
        var sum = ExactProfileDecimal.zero
        var minimum: ExactProfileDecimal?, maximum: ExactProfileDecimal?
        var numericNotice: String?
        for row in payload.values.indices {
            try Task.checkCancellation()
            let value = payload.values[row][ordinal]
            let sqlite = payload.sqliteValues?[row][ordinal]
            let native = payload.nativeValues?[row][ordinal]
            let kind = native.map { "Native " + $0.kind + ($0.kind == "binary" ? " (Base64)" : "") } ?? sqlite.map { storage in
                "SQLite " + storage.type + (storage.type == "text" || storage.type == "blob" ? " (Base64)" : storage.type == "real" ? " (IEEE 754 hex)" : "")
            } ?? value.kind.rawValue
            var key = Data(kind.utf8)
            key.append(0)
            if let native { key.append(try NativeValuePresentation.canonicalData(native)) }
            else { key.append(contentsOf: (sqlite?.value ?? value.value ?? "").utf8) }
            let representation: String?
            if let native {
                representation = ["float32", "float64"].contains(native.kind)
                    ? "0x" + (native.value ?? "") + " · " + (NativeValuePresentation.text(native) ?? "")
                    : NativeValuePresentation.text(native)
            }
            else if let sqlite { representation = sqlite.type == "null" ? nil : sqlite.value }
            else { representation = value.value }
            if var old = frequencies[key] { old.count += 1; frequencies[key] = old }
            else { frequencies[key] = (kind, representation, 1) }
            if native?.kind == "null" || native == nil && value.kind == .null { nulls += 1; continue }
            if native == nil && value.kind == .default { defaults += 1; numericNotice = "Resolve DEFAULT values before calculating exact aggregates."; continue }
            guard numericNotice == nil else { continue }
            let numeric: String?
            if let native {
                let matchesColumn = column.engine == .sqlite || (native.engine == nil || native.engine == column.engine.rawValue) &&
                    (native.nativeType == nil || native.nativeType.map({ Data($0.utf8) }) == Data(column.nativeType.utf8)) &&
                    (native.typeIdentity == nil || native.typeIdentity.map({ Data($0.utf8) }) == column.typeIdentity.map({ Data($0.utf8) }))
                numeric = matchesColumn ? NativeValuePresentation.exactNumber(native).flatMap {
                    exactNumber(ResultClipboardValue(kind: .text, value: $0), sqlite: sqlite, column: column)
                } : nil
            } else { numeric = exactNumber(value, sqlite: sqlite, column: column) }
            guard let text = numeric, let number = ExactProfileDecimal(text) else {
                numericNotice = "Exact aggregates require finite integer or decimal values within 4,096 digits and exponent magnitude. Native floating-point, text, binary, containers, opaque/unresolved and mixed storage values retain their captured distributions."
                continue
            }
            work += max(sum.workSize, number.workSize)
            guard work <= GridProfileLimits.maximumArithmeticWork, let next = sum.adding(number) else {
                numericNotice = "Exact arithmetic reached its work limit. Narrow the selected rows or columns."
                continue
            }
            sum = next; numericCount += 1
            minimum = min(minimum ?? number, number)
            maximum = max(maximum ?? number, number)
        }
        if numericCount == 0, numericNotice == nil { numericNotice = "There are no non-NULL numeric values in this observation." }
        let available = numericNotice == nil
        try Task.checkCancellation()
        let representations = try frequencies.map { key, value in
            try Task.checkCancellation()
            return GridProfileFrequency(id: key, kind: value.kind, value: value.value, count: value.count,
                byteCount: value.value?.utf8.count ?? 0)
        }
        var comparisons = 0
        let ordered = try representations.sorted { a, b in
            comparisons += 1
            if comparisons.isMultiple(of: 256) { try Task.checkCancellation() }
            return a.count == b.count ? a.id.lexicographicallyPrecedes(b.id) : a.count > b.count
        }
        try Task.checkCancellation()
        return GridProfileColumn(id: payload.sourceColumnIndices[ordinal], sourceColumn: column,
            count: payload.values.count, nullCount: nulls, defaultCount: defaults, distinctCount: frequencies.count,
            sum: available ? sum.text : nil, average: available ? sum.average(count: numericCount) : nil,
            minimum: available ? minimum?.text : nil, maximum: available ? maximum?.text : nil,
            numericNotice: numericNotice, frequencies: Array(ordered.prefix(GridProfileLimits.maximumFrequentValues)))
    }

    private static func exactNumber(_ value: ResultClipboardValue, sqlite: SQLiteValue?, column: ResultColumn) -> String? {
        guard column.typeIdentity?.hasPrefix("unresolved:") != true else { return nil }
        if let sqlite { return sqlite.type == "integer" ? sqlite.value : nil }
        guard value.kind == .text, let text = value.value else { return nil }
        if column.engine == .postgresql { return [20, 21, 23, 26, 1700].contains(column.typeOid) ? text : nil }
        let type = column.nativeType.lowercased().split(separator: "(").first.map(String.init) ?? ""
        let exact = ["integer", "int", "int2", "int4", "int8", "smallint", "bigint", "tinyint", "mediumint",
                     "decimal", "numeric", "varint", "counter", "decimal128"]
        if exact.contains(type.trimmingCharacters(in: .whitespaces)) ||
            (column.engine.usesMySQLSyntax && exact.contains(type.split(separator: " ").first.map(String.init) ?? "")) { return text }
        return nil
    }
}

@MainActor
final class GridProfileSelectionModel: ObservableObject {
    @Published private(set) var report: GridProfileReport?
    @Published private(set) var notice: String?
    @Published private(set) var isBusy = false
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    deinit { task?.cancel() }
    func select(_ selection: GridProfileSelection) {
        generation &+= 1
        task?.cancel(); task = nil; report = nil; notice = nil; isBusy = false
        switch selection {
        case .empty: return
        case .unavailable(let reason): notice = reason
        case .values(let input):
            let token = generation
            isBusy = true
            task = Task { [weak self] in
                do {
                    let worker = Task.detached(priority: .userInitiated) { try GridDataProfiler.profile(input) }
                    let report = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    self.report = report; self.isBusy = false
                } catch {
                    guard let self, self.generation == token else { return }
                    self.isBusy = false
                    if !(error is CancellationError) { self.notice = error.localizedDescription }
                }
            }
        }
    }
    func cancel() { select(.empty) }
}
