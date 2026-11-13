import Foundation

private func validMetadataID(_ value: String) -> Bool {
    BackendMessage.validID(value) && !value.contains { $0 == "\0" || $0 == "\r" || $0 == "\n" || $0 == "\t" || $0 == " " }
}

extension CatalogRequest {
    var normalizedMetadataSelector: CatalogRequest {
        var value = self
        if value.schema == "" { value.schema = nil }
        if value.object == "" { value.object = nil }
        if value.objectKind == "" { value.objectKind = nil }
        if value.identity == "" { value.identity = nil }
        if value.search == "" { value.search = nil }
        return value
    }

    var supportsMetadataPaging: Bool {
        guard ["schemas", "objects", "search", "columns", "foreignKeys", "referencingTables", "keys", "indexes", "constraints", "triggers"].contains(kind),
              page == nil, cursor == nil, sort == nil, filters == nil, filterExpression == nil, typeChange == nil,
              (identity ?? "").isEmpty, !["foreignKeys", "referencingTables"].contains(kind) || identity == nil,
              [schema, object, objectKind, search].allSatisfy({ value in
                  value.map { $0.utf8.count <= 1_024 && !$0.contains("\0") } ?? true
              }) else { return false }
        let kinds = ["table", "view", "function", "procedure", "trigger", "enum", "type"]
        switch kind {
        case "schemas": return (schema ?? "").isEmpty && (object ?? "").isEmpty && (objectKind ?? "").isEmpty && (search ?? "").isEmpty
        case "objects": return schema?.isEmpty == false && (object ?? "").isEmpty && kinds.contains(objectKind ?? "") && (search ?? "").isEmpty
        case "search": return search?.isEmpty == false && (object ?? "").isEmpty && (objectKind ?? "").isEmpty
        case "referencingTables": return schema?.isEmpty == false && object?.isEmpty == false && ["", "table"].contains(objectKind ?? "") && (search ?? "").isEmpty
        case "columns": return schema?.isEmpty == false && object?.isEmpty == false && ["", "table", "view", "type"].contains(objectKind ?? "") && (search ?? "").isEmpty
        default: return schema?.isEmpty == false && object?.isEmpty == false && ["", "table", "view"].contains(objectKind ?? "") && (search ?? "").isEmpty
        }
    }
}

private struct MetadataSelector: Codable {
    var request: CatalogRequest
    init(_ request: CatalogRequest) { self.request = request }
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CatalogMetadataCodingKey.self)
        guard Set(keys.allKeys.map(\.stringValue)).isSubset(of: ["kind", "schema", "object", "objectKind", "identity", "search"]) else {
            throw BackendTransportError(.invalidMessage)
        }
        for key in keys.allKeys where try keys.decodeNil(forKey: key) { throw BackendTransportError(.invalidMessage) }
        request = try CatalogRequest(from: decoder)
        guard request.supportsMetadataPaging else { throw BackendTransportError(.invalidMessage) }
    }
    func encode(to encoder: any Encoder) throws { try request.encode(to: encoder) }
}

struct CatalogMetadataPageRequest: Codable, Equatable, Sendable {
    var selectors: [CatalogRequest] = []
    var cursor: String?
    var pageSize: Int?
    var captureIds: [String]?

    func valid(for type: String) -> Bool {
        if type == "catalog.close" {
            return selectors.isEmpty && cursor == nil && pageSize == nil &&
                captureIds.map { (1...32).contains($0.count) && $0.allSatisfy(validMetadataID) } == true
        }
        guard ["catalog.page", "catalog.batch"].contains(type), (1...32).contains(selectors.count),
              captureIds == nil, selectors.allSatisfy(\.supportsMetadataPaging),
              pageSize.map({ (0...1_000).contains($0) }) ?? true,
              cursor.map(validMetadataID) ?? true else { return false }
        for (index, selector) in selectors.enumerated() {
            if selectors.prefix(index).contains(where: { $0.normalizedMetadataSelector == selector.normalizedMetadataSelector }) {
                return false
            }
        }
        return type == "catalog.page" ? selectors.count == 1 : cursor == nil
    }

    private enum CodingKeys: String, CodingKey { case selectors, cursor, pageSize, captureIds }
    init(selectors: [CatalogRequest] = [], cursor: String? = nil, pageSize: Int? = nil, captureIds: [String]? = nil) {
        self.selectors = selectors; self.cursor = cursor; self.pageSize = pageSize; self.captureIds = captureIds
    }
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CatalogMetadataCodingKey.self)
        guard Set(keys.allKeys.map(\.stringValue)).isSubset(of: ["selectors", "cursor", "pageSize", "captureIds"]) else { throw BackendTransportError(.invalidMessage) }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selectors = values.contains(.selectors) ? try values.decode([MetadataSelector].self, forKey: .selectors).map(\.request) : []
        cursor = values.contains(.cursor) ? try values.decode(String.self, forKey: .cursor) : nil
        pageSize = values.contains(.pageSize) ? try values.decode(Int.self, forKey: .pageSize) : nil
        captureIds = values.contains(.captureIds) ? try values.decode([String].self, forKey: .captureIds) : nil
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if !selectors.isEmpty { try values.encode(selectors.map(MetadataSelector.init), forKey: .selectors) }
        try values.encodeIfPresent(cursor, forKey: .cursor)
        try values.encodeIfPresent(pageSize, forKey: .pageSize)
        try values.encodeIfPresent(captureIds, forKey: .captureIds)
    }
}

struct CatalogRelationTarget: Codable, Equatable, Sendable {
    let schema: String
    let name: String
    var valid: Bool { [schema, name].allSatisfy { !$0.isEmpty && $0.utf8.count <= 1_024 && !$0.contains("\0") } }
    static func == (lhs: Self, rhs: Self) -> Bool { Data(lhs.schema.utf8) == Data(rhs.schema.utf8) && Data(lhs.name.utf8) == Data(rhs.name.utf8) }
    private enum CodingKeys: String, CodingKey { case schema, name }
    init(schema: String, name: String) { self.schema = schema; self.name = name }
    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CatalogMetadataCodingKey.self)
        guard Set(fields.allKeys.map(\.stringValue)) == ["schema", "name"] else { throw BackendTransportError(.invalidMessage) }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(String.self, forKey: .schema)
        name = try values.decode(String.self, forKey: .name)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct CatalogMetadataCollection: Codable, Equatable, Sendable {
    var selector: CatalogRequest
    var captureId: String
    var observedAt: String
    var consistency: String
    var state: String
    var columns: [ResultColumn]
    var rows: [[String?]]
    var nextCursor: String?
    var issue: String?
    var target: CatalogRelationTarget? = nil

    private var validTarget: Bool {
        if selector.kind == "referencingTables" {
            if ["unavailable", "stale"].contains(state) { return target == nil }
            return target?.valid == true
        }
        return target == nil
    }
    private static func validDate(_ value: String) -> Bool {
        let parser = ISO8601DateFormatter()
        if parser.date(from: value) != nil { return true }
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) != nil
    }
    var valid: Bool {
        validTarget && selector.supportsMetadataPaging && validMetadataID(captureId) &&
            Self.validDate(observedAt) &&
            ["repeatableRead", "schemaVersion", "bestEffort"].contains(consistency) &&
            ["complete", "partial", "unavailable", "stale"].contains(state) &&
            columns.count <= 64 && Set(columns.map(\.name)).count == columns.count &&
            columns.enumerated().allSatisfy { $0.offset == $0.element.index && !$0.element.name.isEmpty } &&
            rows.count <= 1_032 && rows.allSatisfy { $0.count == columns.count } &&
            (nextCursor.map(validMetadataID) ?? true) &&
            (nextCursor == nil || !["unavailable", "stale"].contains(state)) &&
            (issue.map { $0.utf8.count <= 4_096 && !$0.contains("\0") } ?? true) &&
            (state == "complete" || issue?.isEmpty == false)
    }
}

struct CatalogMetadataReply: Codable, Equatable, Sendable {
    var collections: [CatalogMetadataCollection]
    var closed: Bool?
    var valid: Bool {
        closed == true ? collections.isEmpty : (1...32).contains(collections.count) && collections.allSatisfy(\.valid)
    }
}

extension CatalogMetadataCollection {
    private enum CodingKeys: String, CodingKey {
        case selector, captureId, observedAt, consistency, state, columns, rows, nextCursor, issue, target
    }
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CatalogMetadataCodingKey.self)
        guard Set(keys.allKeys.map(\.stringValue)).isSubset(of: ["selector", "captureId", "observedAt", "consistency", "state", "columns", "rows", "nextCursor", "issue", "target"]) else {
            throw BackendTransportError(.invalidMessage)
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selector = try values.decode(MetadataSelector.self, forKey: .selector).request
        captureId = try values.decode(String.self, forKey: .captureId)
        observedAt = try values.decode(String.self, forKey: .observedAt)
        consistency = try values.decode(String.self, forKey: .consistency)
        state = try values.decode(String.self, forKey: .state)
        columns = try values.decode([ResultColumn].self, forKey: .columns)
        rows = try values.decode([[String?]].self, forKey: .rows)
        nextCursor = values.contains(.nextCursor) ? try values.decode(String.self, forKey: .nextCursor) : nil
        issue = values.contains(.issue) ? try values.decode(String.self, forKey: .issue) : nil
        target = values.contains(.target) ? try values.decode(CatalogRelationTarget.self, forKey: .target) : nil
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

extension CatalogMetadataReply {
    private enum CodingKeys: String, CodingKey { case collections, closed }
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CatalogMetadataCodingKey.self)
        guard Set(keys.allKeys.map(\.stringValue)).isSubset(of: ["collections", "closed"]) else {
            throw BackendTransportError(.invalidMessage)
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        collections = try values.decode([CatalogMetadataCollection].self, forKey: .collections)
        closed = values.contains(.closed) ? try values.decode(Bool.self, forKey: .closed) : nil
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

/// A page accumulator is bounded independently from transport frames and keeps
/// the original observation identity stable across every continuation.
struct CatalogMetadataAccumulator {
    static let maximumRows = 100_000
    static let maximumBytes = 64 << 20
    private(set) var observation: CatalogMetadataCollection?
    private(set) var rows: [[String?]] = []
    private var bytes = 0
    private var cursors: Set<String> = []

    mutating func append(_ page: CatalogMetadataCollection, selector: CatalogRequest) throws {
        guard page.valid, page.selector.normalizedMetadataSelector == selector.normalizedMetadataSelector else { throw BackendTransportError(.invalidMessage) }
        if let observation {
            guard observation.captureId == page.captureId, observation.observedAt == page.observedAt,
                  observation.columns == page.columns, observation.state == page.state,
                  observation.consistency == page.consistency, observation.issue == page.issue, observation.target == page.target else { throw BackendTransportError(.invalidMessage) }
        } else { observation = page }
        if let cursor = page.nextCursor, !cursors.insert(cursor).inserted { throw BackendTransportError(.invalidMessage) }
        bytes += try JSONEncoder().encode(page.rows).count
        guard rows.count + page.rows.count <= Self.maximumRows, bytes <= Self.maximumBytes else { throw CatalogMetadataFailure("Metadata exceeds the client capture limit. Narrow the scope and refresh.") }
        rows.append(contentsOf: page.rows)
    }

    func result(requestId: String, sessionId: String, queryId: String) throws -> BackendMessage {
        guard let observation else { throw BackendTransportError(.invalidMessage) }
        if observation.state == "unavailable" || observation.state == "stale" {
            throw CatalogMetadataFailure(observation.issue ?? "Metadata is unavailable. Refresh explicitly.")
        }
        var result = BackendMessage(type: "query.result", requestId: requestId, sessionId: sessionId,
            queryId: queryId, transactionStatus: .idle, durationMs: 0, columns: observation.columns, rows: rows, commandTag: "SELECT",
            rowCount: Int64(rows.count), displayedRowCount: rows.count, truncated: observation.state != "complete")
        result.displayNotice = observation.issue
        return result
    }
}

struct CatalogMetadataFailure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct CatalogMetadataCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
