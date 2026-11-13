import Foundation

/// Search addresses immutable source ordinals so a filtered grid cannot edit a different row.
struct ResultGridSearchResult: Equatable {
    let sourceRows: [Int]
    let matches: [ResultGridCell]

    func sourceCell(_ displayed: ResultGridCell) -> ResultGridCell? {
        guard sourceRows.indices.contains(displayed.row) else { return nil }
        return ResultGridCell(row: sourceRows[displayed.row], column: displayed.column)
    }

    func displayedCell(_ source: ResultGridCell) -> ResultGridCell? {
        guard let row = sourceRows.firstIndex(of: source.row) else { return nil }
        return ResultGridCell(row: row, column: source.column)
    }

    func sourceSelection(_ displayed: IndexSet) -> IndexSet {
        IndexSet(displayed.compactMap { sourceRows.indices.contains($0) ? sourceRows[$0] : nil })
    }

    func displayedSelection(_ source: IndexSet) -> IndexSet {
        IndexSet(sourceRows.indices.filter { source.contains(sourceRows[$0]) })
    }
}

enum ResultGridSearch {
    static func find(_ query: String, rows: [[String?]], columns: IndexSet,
                     valueKinds: [[String]]? = nil, matchingOnly: Bool = false) -> ResultGridSearchResult {
        guard !query.isEmpty else {
            return ResultGridSearchResult(sourceRows: Array(rows.indices), matches: [])
        }
        var matches: [ResultGridCell] = []
        var matchedRows = IndexSet()
        for row in rows.indices {
            for column in columns where rows[row].indices.contains(column) {
                let isDefault = valueKinds?.indices.contains(row) == true &&
                    valueKinds?[row].indices.contains(column) == true && valueKinds?[row][column] == "default"
                let text = isDefault ? "DEFAULT" : (rows[row][column] ?? "NULL")
                if text.range(of: query, options: [.caseInsensitive]) != nil {
                    matches.append(ResultGridCell(row: row, column: column))
                    matchedRows.insert(row)
                }
            }
        }
        return ResultGridSearchResult(sourceRows: matchingOnly ? Array(matchedRows) : Array(rows.indices), matches: matches)
    }
}
