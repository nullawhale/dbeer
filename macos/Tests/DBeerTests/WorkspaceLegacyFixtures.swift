import Foundation
@testable import DBeer

/// Versions before 11 stored conjunction filters, not the current expression
/// tree. Migration fixtures must contain the bytes that those versions wrote.
func workspaceLegacyFilterFixture(_ input: [String: Any]) throws -> [String: Any] {
    var object = input
    object["documents"] = try (input["documents"] as? [[String: Any]] ?? []).map { original in
        var document = original
        guard var table = document["table"] as? [String: Any] else { return document }
        var filters: [CatalogFilter] = []
        if let raw = table["filterExpression"], !(raw is NSNull) {
            let expression = try JSONDecoder().decode(CatalogFilterExpression.self, from: JSONSerialization.data(withJSONObject: raw))
            guard let conjunction = expression.flattenedConjunction else { throw SQLDocumentStoreError.read }
            filters = conjunction
        }
        table["filterExpression"] = nil
        table["filters"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(filters))
        document["table"] = table
        return document
    }
    return object
}
