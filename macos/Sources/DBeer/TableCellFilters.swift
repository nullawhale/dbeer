import Foundation

enum TableCellFilterAction: CaseIterable, Sendable {
    case equal, exclude, selectedValues, isNull, isNotNull

    var title: String {
        switch self {
        case .equal: "Show Only This Value"
        case .exclude: "Hide This Value"
        case .selectedValues: "Show Selected Values in This Column"
        case .isNull: "Show NULL Values"
        case .isNotNull: "Show Non-NULL Values"
        }
    }
}

/// Coordinates address the original loaded result, including during local find.
struct TableCellFilterRequest {
    let action: TableCellFilterAction
    let cell: ResultGridCell
    let rows: [Int]
}

struct TableCellFilterError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum TableCellFilters {
    static let sqliteCapability = "sqliteCellFilterV1"

    static func adding(_ action: TableCellFilterAction, column: ResultColumn, values: [ChangeValue],
                       to configuration: TableBrowseConfiguration, typedSQLite: Bool = false) throws -> TableBrowseConfiguration {
        guard column.engine != .mongodb else {
            throw TableCellFilterError(message: "Choose a sampled field in Filter and Sort to filter MongoDB documents.")
        }
        guard validBrowseName(column.name), configuration.isValid else {
            throw TableCellFilterError(message: "Correct the current filter draft before adding a cell condition.")
        }
        let expression: CatalogFilterExpression
        switch action {
        case .isNull, .isNotNull:
            expression = .predicate(.init(column: column.name, operator: action == .isNull ? "isNull" : "isNotNull"))
        case .equal, .exclude:
            guard let value = values.first else { throw TableCellFilterError(message: "Select a loaded value first.") }
            let condition = try predicate(value, column: column, typedSQLite: typedSQLite)
            if action == .exclude, condition.operator == "eq" {
                var opposite = condition
                opposite.operator = "ne"
                // Hiding one value retains rows whose value is SQL NULL.
                expression = .group("or", [.predicate(opposite), .predicate(.init(column: column.name, operator: "isNull"))])
            } else if action == .exclude {
                expression = .predicate(.init(column: column.name, operator: "isNotNull"))
            } else {
                expression = .predicate(condition)
            }
        case .selectedValues:
            var conditions: [CatalogFilter] = []
            for value in values {
                let condition = try predicate(value, column: column, typedSQLite: typedSQLite)
                if !conditions.contains(condition) { conditions.append(condition) }
                guard conditions.count <= 32 else { throw budgetError }
            }
            guard !conditions.isEmpty else { throw TableCellFilterError(message: "Select loaded rows in this column first.") }
            expression = conditions.count == 1 ? .predicate(conditions[0]) : .group("or", conditions.map(CatalogFilterExpression.predicate))
        }
        var result = configuration
        if let existing = configuration.filterExpression {
            if existing.kind == "and", let children = existing.children {
                result.filterExpression = .group("and", children + [expression])
            } else {
                result.filterExpression = .group("and", [existing, expression])
            }
        } else {
            result.filterExpression = expression
        }
        guard result.isValid else { throw budgetError }
        return result
    }

    private static var budgetError: TableCellFilterError {
        .init(message: "The combined filter exceeds 32 conditions or 4 levels. Simplify the filter draft before adding these values.")
    }

    private static func predicate(_ value: ChangeValue, column: ResultColumn, typedSQLite: Bool) throws -> CatalogFilter {
        if value.kind == "null" { return .init(column: column.name, operator: "isNull") }
        if let storage = value.sqliteValue {
            guard column.engine == .sqlite, typedSQLite else {
                throw TableCellFilterError(message: "Reconnect with a helper that supports typed SQLite cell filters.")
            }
            let condition = CatalogFilter(column: column.name, operator: "eq", sqliteValue: storage)
            guard condition.isValid else { throw TableCellFilterError(message: "This SQLite value exceeds the filter limit or cannot be compared exactly.") }
            return condition
        }
        guard ["text", "binary"].contains(value.kind), let text = value.value,
              (value.kind == "binary") == (column.encoding == "base64"),
              value.kind != "binary" || Data(base64Encoded: text)?.base64EncodedString() == text else {
            throw TableCellFilterError(message: "A DEFAULT or unresolved value cannot identify a filter operand.")
        }
        guard column.engine != .sqlite else {
            throw TableCellFilterError(message: "Reload the table to obtain the SQLite value's storage type before filtering.")
        }
        let condition = CatalogFilter(column: column.name, operator: "eq", value: text)
        guard condition.isValid else { throw TableCellFilterError(message: "This value exceeds the filter limit or contains an unsupported NUL character.") }
        return condition
    }
}

extension TableBrowseNavigation {
    static func cellFilter(_ request: TableCellFilterRequest, document: SQLDocument,
                           workspace: ApplicationWorkspace, grid: GridDraft) throws -> TableBrowseConfiguration {
        guard document.table != nil, document.grid === grid, isEnabled(document: document, workspace: workspace),
              grid.columns.indices.contains(request.cell.column), grid.rows.indices.contains(request.cell.row) else {
            throw TableCellFilterError(message: "Finish or discard pending changes and wait for the current operation before filtering.")
        }
        let rows = request.action == .selectedValues ? request.rows : [request.cell.row]
        guard rows.allSatisfy({ grid.rows.indices.contains($0) && grid.rows[$0].values.indices.contains(request.cell.column) && !grid.rows[$0].isDeleted }) else {
            throw TableCellFilterError(message: "The selected rows changed. Select the loaded values again.")
        }
        let values = rows.map { grid.rows[$0].values[request.cell.column] }
        let configuration = try TableCellFilters.adding(request.action, column: grid.columns[request.cell.column], values: values,
            to: document.browseDraftConfiguration, typedSQLite: document.runtime?.capabilities.contains(TableCellFilters.sqliteCapability) == true)
        if let error = validationError(configuration: configuration, document: document, workspace: workspace) {
            throw TableCellFilterError(message: error)
        }
        return configuration
    }

    static func addCellFilter(_ request: TableCellFilterRequest, document: SQLDocument,
                              workspace: ApplicationWorkspace, grid: GridDraft) {
        do {
            document.browseDraftConfiguration = try cellFilter(request, document: document, workspace: workspace, grid: grid)
            document.tableNavigationError = nil
        } catch {
            document.tableNavigationError = error.localizedDescription
        }
    }
}
