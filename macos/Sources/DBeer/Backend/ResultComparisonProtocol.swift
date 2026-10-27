import Foundation

enum ResultComparisonMode: String, Codable, CaseIterable, Sendable {
    case key, rowOrder
}

struct ResultComparisonArtifactReference: Codable, Equatable, Sendable {
    var kind = "snapshot"
    var id: String

    init(id: UUID) { self.id = id.uuidString.lowercased() }
    var valid: Bool { kind == "snapshot" && UUID(uuidString: id)?.uuidString.lowercased() == id }
}

struct ResultComparisonColumnMapping: Codable, Equatable, Sendable {
    var left: Int
    var right: Int
    var key: Bool?
}

/// This command contains managed artifact IDs and bounded presentation requests,
/// never captured result rows, SQL, credentials, or caller-supplied file paths.
struct ResultComparisonRequest: Codable, Equatable, Sendable {
    var left: ResultComparisonArtifactReference?
    var right: ResultComparisonArtifactReference?
    var mode: ResultComparisonMode?
    var columns: [ResultComparisonColumnMapping]?
    var jobId: String?
    var offset: Int64?
    var limit: Int?
    var maxBytes: Int?
    var valueRef: String?
    var cellOffset: Int?

    func valid(for type: String) -> Bool {
        let noSource = left == nil && right == nil && mode == nil && columns == nil
        let validJob = jobId.map(Self.validToken) == true
        switch type {
        case "compare.start":
            guard left?.valid == true, right?.valid == true, let mode, let columns,
                  !columns.isEmpty, columns.count <= 65_536,
                  columns.allSatisfy({ (0..<65_536).contains($0.left) && (0..<65_536).contains($0.right) }),
                  Set(columns.map(\.left)).count == columns.count,
                  Set(columns.map(\.right)).count == columns.count,
                  jobId == nil, offset == nil, limit == nil, maxBytes == nil, valueRef == nil, cellOffset == nil else { return false }
            return mode == .key ? columns.contains { $0.key == true } : columns.allSatisfy { $0.key != true }
        case "compare.status", "compare.cancel", "compare.close":
            return noSource && validJob && offset == nil && limit == nil && maxBytes == nil && valueRef == nil && cellOffset == nil
        case "compare.page":
            return noSource && validJob && (offset ?? 0) >= 0 && (1...1_000).contains(limit ?? 100) &&
                (4_096...1_048_576).contains(maxBytes ?? 262_144) && valueRef == nil && (cellOffset ?? 0) >= 0
        case "compare.value":
            return noSource && validJob && valueRef.map(Self.validToken) == true && (offset ?? 0) >= 0 &&
                (1...1_048_576).contains(maxBytes ?? 65_536) && limit == nil && cellOffset == nil
        default: return false
        }
    }

    static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.contains("\0")
    }
}

enum ResultComparisonState: String, Codable, Sendable {
    case pending, running, completed, cancelled, failed, closed
    var isWorking: Bool { self == .pending || self == .running }
}

struct ResultComparisonSchemaDifference: Codable, Equatable, Sendable {
    var left: Int?
    var right: Int?
    var reason: String
}

struct ResultComparisonSummary: Codable, Equatable, Sendable {
    var leftRows: Int64
    var rightRows: Int64
    var equalRows: Int64
    var addedRows: Int64
    var deletedRows: Int64
    var changedRows: Int64
    var ambiguousRows: Int64
    var uncertainRows: Int64
    var reportRows: Int64
    var complete: Bool
    var fullEquality: Bool
    var schemaDifferenceCount: Int64
    var schemaDifferencesTruncated: Bool
    var schemaDifferences: [ResultComparisonSchemaDifference]
    var warnings: [String]

    var valid: Bool {
        [leftRows, rightRows, equalRows, addedRows, deletedRows, changedRows, ambiguousRows,
         uncertainRows, reportRows].allSatisfy { $0 >= 0 } &&
        schemaDifferenceCount >= Int64(schemaDifferences.count) && schemaDifferences.count <= 64 &&
        schemaDifferencesTruncated == (schemaDifferenceCount > Int64(schemaDifferences.count)) && schemaDifferences.allSatisfy {
            ($0.left == nil || (0..<65_536).contains($0.left!)) &&
            ($0.right == nil || (0..<65_536).contains($0.right!)) && $0.reason.utf8.count <= 4_096
        } && warnings.count <= 1_024 && warnings.allSatisfy { $0.utf8.count <= 4_096 } &&
        (!fullEquality || complete && leftRows == rightRows && equalRows == leftRows && addedRows == 0 && deletedRows == 0 && changedRows == 0 &&
            ambiguousRows == 0 && uncertainRows == 0 && reportRows == 0 && schemaDifferenceCount == 0)
    }
}

struct ResultComparisonValuePreview: Codable, Equatable, Sendable {
    var isNull: Bool
    var preview: String
    var totalBytes: Int64
    var truncated: Bool
    var valueRef: String

    var valid: Bool {
        totalBytes >= 0 && preview.utf8.count <= 256 && Int64(preview.utf8.count) <= totalBytes &&
        ResultComparisonRequest.validToken(valueRef) &&
        (isNull ? totalBytes == 0 && preview.isEmpty && !truncated : truncated == (Int64(preview.utf8.count) < totalBytes))
    }

    var display: String {
        if isNull { return "SQL NULL" }
        if totalBytes == 0 { return "\"\" (empty text)" }
        return preview + (truncated ? "…" : "")
    }
}

struct ResultComparisonCell: Codable, Equatable, Sendable {
    var mapping: Int
    var left: ResultComparisonValuePreview?
    var right: ResultComparisonValuePreview?
    var different: Bool
    var uncertain: Bool
}

struct ResultComparisonRow: Codable, Equatable, Identifiable, Sendable {
    var index: Int64
    var kind: String
    var leftIndex: Int64?
    var rightIndex: Int64?
    var cells: [ResultComparisonCell]
    var cellOffset: Int
    var nextCellOffset: Int
    var totalCells: Int
    var cellsTruncated: Bool
    var id: Int64 { index }

    var valid: Bool {
        index >= 0 && ["added", "deleted", "changed", "ambiguous", "uncertain"].contains(kind) &&
        (leftIndex.map { $0 >= 0 && $0 < Int64.max } ?? true) && (rightIndex.map { $0 >= 0 && $0 < Int64.max } ?? true) &&
        (leftIndex != nil || rightIndex != nil) && (0...65_536).contains(cellOffset) && cells.count <= 65_536 &&
        nextCellOffset == cellOffset + cells.count &&
        nextCellOffset <= totalCells && totalCells <= 65_536 &&
        cellsTruncated == (nextCellOffset < totalCells) && (!cellsTruncated || !cells.isEmpty) &&
        cells.enumerated().allSatisfy { index, cell in
            cell.mapping == cellOffset + index && (cell.left != nil || cell.right != nil) &&
            (cell.left?.valid ?? true) && (cell.right?.valid ?? true)
        }
    }
}

struct ResultComparisonPage: Codable, Equatable, Sendable {
    var offset: Int64
    var nextOffset: Int64
    var hasMore: Bool
    var rows: [ResultComparisonRow]

    var valid: Bool {
        offset >= 0 && nextOffset >= offset && nextOffset - offset == Int64(rows.count) && rows.count <= 1_000 &&
        (!hasMore || !rows.isEmpty) && rows.enumerated().allSatisfy { ordinal, row in
            row.valid && row.index == offset + Int64(ordinal)
        } && ((try? JSONEncoder().encode(self).count) ?? Int.max) <= 1_048_576
    }
}

struct ResultComparisonValueChunk: Codable, Equatable, Sendable {
    var valueRef: String
    var isNull: Bool
    var totalBytes: Int64
    var offset: Int64
    var nextOffset: Int64
    var dataBase64: String
    var hasMore: Bool

    var data: Data? { Data(base64Encoded: dataBase64) }
    var text: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
    var valid: Bool {
        guard ResultComparisonRequest.validToken(valueRef), totalBytes >= 0, offset >= 0, nextOffset >= offset,
              nextOffset <= totalBytes, let data, data.count <= 1_048_576,
              nextOffset - offset == Int64(data.count), hasMore == (nextOffset < totalBytes),
              !hasMore || !data.isEmpty else { return false }
        return !isNull || totalBytes == 0 && offset == 0 && data.isEmpty && !hasMore
    }
}

struct ResultComparisonResponse: Codable, Equatable, Sendable {
    var jobId: String
    var state: ResultComparisonState
    var message: String?
    var summary: ResultComparisonSummary?
    var page: ResultComparisonPage?
    var value: ResultComparisonValueChunk?

    func valid(for type: String) -> Bool {
        guard ResultComparisonRequest.validToken(jobId), (message?.utf8.count ?? 0) <= 4_096,
              summary?.valid ?? true else { return false }
        switch type {
        case "compare.start.result": return state.isWorking && summary == nil && page == nil && value == nil
        case "compare.status.result": return state != .closed && (state != .completed || summary != nil) && page == nil && value == nil
        case "compare.page.result": return state == .completed && page?.valid == true && value == nil
        case "compare.value.result": return state == .completed && value?.valid == true && page == nil
        case "compare.cancel.result": return state == .cancelled && page == nil && value == nil
        case "compare.close.result": return state == .closed && page == nil && value == nil
        default: return false
        }
    }
}
