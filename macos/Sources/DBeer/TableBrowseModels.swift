import Foundation

/// A bounded, typed expression shared by browse requests and local saved views.
struct CatalogFilterExpression: Codable, Equatable, Sendable {
    var kind: String
    var condition: CatalogFilter?
    var children: [Self]?

    static func predicate(_ condition: CatalogFilter) -> Self {
        Self(kind: "condition", condition: condition)
    }

    static func group(_ kind: String, _ children: [Self]) -> Self {
        Self(kind: kind, children: children)
    }

    static func conjunction(_ filters: [CatalogFilter]) -> Self? {
        filters.isEmpty ? nil : .group("and", filters.map(Self.predicate))
    }

    var isValid: Bool {
        var nodes = 0
        var conditions = 0
        func validate(_ expression: Self, depth: Int) -> Bool {
            nodes += 1
            guard depth <= 4, nodes <= 64 else { return false }
            if expression.kind == "condition" {
                conditions += 1
                return conditions <= 32 && expression.children == nil && expression.condition?.isValid == true
            }
            guard ["and", "or"].contains(expression.kind), expression.condition == nil,
                  let children = expression.children, !children.isEmpty else { return false }
            return children.allSatisfy { validate($0, depth: depth + 1) }
        }
        return validate(self, depth: 1)
    }

    /// Nil means the expression contains OR or is malformed, never an empty filter.
    var flattenedConjunction: [CatalogFilter]? {
        guard isValid else { return nil }
        if kind == "condition" { return condition.map { [$0] } }
        guard kind == "and", let children else { return nil }
        var filters: [CatalogFilter] = []
        for child in children {
            guard let nested = child.flattenedConjunction else { return nil }
            filters += nested
        }
        return filters
    }

    var columns: Set<String> {
        if let condition { return [condition.column] }
        return (children ?? []).reduce(into: Set<String>()) { $0.formUnion($1.columns) }
    }

    var conditionCount: Int { kind == "condition" ? 1 : (children ?? []).reduce(0) { $0 + $1.conditionCount } }

    var displayText: String {
        if let condition { return "\(condition.column) \(condition.operator)" + (condition.value.map { " \($0)" } ?? "") }
        return "(" + (children ?? []).map(\.displayText).joined(separator: kind == "or" ? " OR " : " AND ") + ")"
    }

    private enum CodingKeys: String, CodingKey { case kind, condition, children }

    init(kind: String, condition: CatalogFilter? = nil, children: [Self]? = nil) {
        self.kind = kind
        self.condition = condition
        self.children = children
    }

    init(from decoder: Decoder) throws {
        guard decoder.codingPath.filter({ $0.stringValue == "children" }).count < 4 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Filter nesting exceeds four levels."))
        }
        let all = try decoder.container(keyedBy: BrowseCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["kind", "condition", "children"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown filter field."))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind)
        guard kind == "condition" ? (values.contains(.condition) && !values.contains(.children)) :
                (["and", "or"].contains(kind) && values.contains(.children) && !values.contains(.condition)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid filter node fields."))
        }
        condition = try values.decodeIfPresent(CatalogFilter.self, forKey: .condition)
        children = try values.decodeIfPresent([Self].self, forKey: .children)
        if values.contains(.condition) {
            let operand = try values.superDecoder(forKey: .condition).container(keyedBy: BrowseCodingKey.self)
            guard Set(operand.allKeys.map(\.stringValue)).isSubset(of: ["column", "operator", "value"]) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown condition field."))
            }
        }
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid or oversized filter expression."))
        }
    }
}

private struct BrowseCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension CatalogFilter {
    var isValid: Bool {
        guard validBrowseName(column) else { return false }
        switch self.operator {
        case "isNull", "isNotNull": return value == nil
        case "eq", "ne", "lt", "lte", "gt", "gte", "contains":
            return value.map { $0.utf8.count <= 1_024 * 1_024 && !$0.contains("\0") } == true
        default: return false
        }
    }
}

func validBrowseName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 1_024 && !name.contains("\0")
}

struct TableBrowseConfiguration: Codable, Equatable, Sendable {
    var filterExpression: CatalogFilterExpression?
    var sort: [CatalogSort]

    init(filterExpression: CatalogFilterExpression? = nil, sort: [CatalogSort] = []) {
        self.filterExpression = filterExpression
        self.sort = sort
    }

    var isValid: Bool {
        (filterExpression == nil || filterExpression?.isValid == true) && sort.count <= 32 &&
            Set(sort.map(\.column)).count == sort.count && sort.allSatisfy {
                validBrowseName($0.column) && ["asc", "desc"].contains($0.direction)
            }
    }

    private enum CodingKeys: String, CodingKey { case filterExpression, sort }

    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: BrowseCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["filterExpression", "sort"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown browse setting."))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        filterExpression = try values.decodeIfPresent(CatalogFilterExpression.self, forKey: .filterExpression)
        sort = try values.decode([CatalogSort].self, forKey: .sort)
        var orders = try values.nestedUnkeyedContainer(forKey: .sort)
        while !orders.isAtEnd {
            let fields = try orders.superDecoder().container(keyedBy: BrowseCodingKey.self)
            guard Set(fields.allKeys.map(\.stringValue)) == ["column", "direction"] else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown sort setting."))
            }
        }
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid browse settings."))
        }
    }
}
