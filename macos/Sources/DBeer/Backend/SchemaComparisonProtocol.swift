import Foundation

struct SchemaNamePair: Codable, Equatable, Sendable {
    var source: String
    var target: String
}
struct SchemaQualifiedName: Codable, Equatable, Sendable {
    var schema: String
    var name: String
}
struct SchemaObjectPair: Codable, Equatable, Sendable {
    var source: SchemaQualifiedName
    var target: SchemaQualifiedName
}
struct SchemaTablePair: Codable, Equatable, Sendable {
    var source: SchemaQualifiedName
    var target: SchemaQualifiedName
    var columns: [SchemaNamePair] = []
    var constraints: [SchemaNamePair] = []
    var indexes: [SchemaNamePair] = []
}
struct SchemaMappings: Codable, Equatable, Sendable {
    var schemas: [SchemaNamePair] = [.init(source: "public", target: "public")]
    var tables: [SchemaTablePair] = []
    var types: [SchemaObjectPair] = []

    static func == (lhs: Self, rhs: Self) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }
    var valid: Bool {
        guard let bytes = try? JSONEncoder().encode(self), bytes.count <= 1_048_576 else { return false }
        func name(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0") }
        func pairs(_ values: [SchemaNamePair]) -> Bool {
            values.allSatisfy { name($0.source) && name($0.target) } &&
            Set(values.map { Data($0.source.utf8) }).count == values.count &&
            Set(values.map { Data($0.target.utf8) }).count == values.count
        }
        func objects(_ values: [SchemaObjectPair]) -> Bool {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return values.allSatisfy { value in
                name(value.source.name) && name(value.target.name) && schemas.contains {
                    $0.source.utf8.elementsEqual(value.source.schema.utf8) && $0.target.utf8.elementsEqual(value.target.schema.utf8)
                }
            } && Set(values.compactMap { try? encoder.encode($0.source) }).count == values.count &&
                Set(values.compactMap { try? encoder.encode($0.target) }).count == values.count
        }
        return (1...32).contains(schemas.count) && tables.count <= 10_000 && types.count <= 10_000 && pairs(schemas) &&
            objects(tables.map { .init(source: $0.source, target: $0.target) }) && objects(types) &&
            tables.allSatisfy { pairs($0.columns) && pairs($0.constraints) && pairs($0.indexes) }
    }
}
struct SchemaComparisonSide: Codable, Equatable, Sendable { var connection: ConnectionSettings }
struct SchemaComparisonRequest: Codable, Equatable, Sendable {
    var source: SchemaComparisonSide?
    var target: SchemaComparisonSide?
    var mappings: SchemaMappings?
    var jobId: String?
    var collection: String?
    var offset: Int64?
    var limit: Int?
    var maxBytes: Int?
    var valueRef: String?

    func valid(for type: String) -> Bool {
        let noSources = source == nil && target == nil && mappings == nil
        let job = jobId.map(BackendMessage.validID) == true
        switch type {
        case "schema.start":
            return source != nil && target != nil && source?.connection.engine == target?.connection.engine &&
                mappings?.valid == true && jobId == nil &&
                collection == nil && offset == nil && limit == nil && maxBytes == nil && valueRef == nil
        case "schema.status", "schema.cancel", "schema.close":
            return noSources && job && collection == nil && offset == nil && limit == nil && maxBytes == nil && valueRef == nil
        case "schema.diff":
            return noSources && job && (offset ?? 0) >= 0 && collection == nil && limit == nil && maxBytes == nil && valueRef == nil
        case "schema.page":
            return noSources && job && ["differences", "issues"].contains(collection) && (offset ?? 0) >= 0 &&
                (1...1_000).contains(limit ?? 100) && (4_096...1_048_576).contains(maxBytes ?? 262_144) && valueRef == nil
        case "schema.value", "schema.export":
            return noSources && job && collection == nil && limit == nil && (offset ?? 0) >= 0 &&
                (1...1_048_576).contains(maxBytes ?? 65_536) &&
                (type == "schema.export" ? valueRef == nil : valueRef.map(BackendMessage.validID) == true)
        default: return false
        }
    }
}
struct SchemaCaptureContext: Codable, Equatable, Sendable {
    var engine: String
    var version: String
    var database: String
    var startedAt: String
    var finishedAt: String
    var consistency: String
    var visibility: String
    var valid: Bool {
        ["postgresql", "mysql", "cassandra"].contains(engine) && version.utf8.count <= 4_096 && database.utf8.count <= 256 &&
        ["repeatableRead", "bestEffort"].contains(consistency) && ["complete", "partial", "unknown"].contains(visibility) &&
        startedAt.utf8.count <= 64 && finishedAt.utf8.count <= 64 && !startedAt.isEmpty && !finishedAt.isEmpty
    }
}
struct SchemaComparisonScope: Codable, Equatable, Sendable { var kind: String; var excludedObjectKinds: [String] }
struct SchemaComparisonSummary: Codable, Equatable, Sendable {
    var formatVersion: Int
    var engine: String
    var source: SchemaCaptureContext
    var target: SchemaCaptureContext
    var mappings: SchemaMappings
    var scope: SchemaComparisonScope
    var equalObjects: Int64
    var sourceOnlyObjects: Int64
    var targetOnlyObjects: Int64
    var changedObjects: Int64
    var indeterminateObjects: Int64
    var differenceCount: Int64
    var issueCount: Int64
    var complete: Bool
    var fullEquality: Bool
    var modelDigest: String
    var valid: Bool {
        formatVersion == 1 && source.valid && target.valid && engine == source.engine && engine == target.engine && mappings.valid &&
        scope.kind == "mappedTableStructure" && scope.excludedObjectKinds.count <= 32 && scope.excludedObjectKinds.allSatisfy { $0.utf8.count <= 128 } &&
        [equalObjects, sourceOnlyObjects, targetOnlyObjects, changedObjects, indeterminateObjects, differenceCount, issueCount].allSatisfy { $0 >= 0 } &&
        modelDigest.count == 64 && modelDigest.allSatisfy { $0.isHexDigit } &&
        (!fullEquality || complete && source.visibility == "complete" && target.visibility == "complete" && differenceCount == 0 && indeterminateObjects == 0)
    }
}
struct SchemaObjectRef: Codable, Equatable, Sendable {
    var kind: String; var schema: String; var name: String; var table: String?
    var title: String { [schema, table, name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
    var valid: Bool { [kind, schema, name, table ?? ""].allSatisfy { $0.utf8.count <= 256 && !$0.contains("\0") } }
}
struct SchemaValuePreview: Codable, Equatable, Sendable {
    var text: String; var totalBytes: Int64; var truncated: Bool; var valueRef: String
    var valid: Bool { text.utf8.count <= 256 && totalBytes >= Int64(text.utf8.count) && truncated == (totalBytes > text.utf8.count) && BackendMessage.validID(valueRef) }
}
struct SchemaDifference: Codable, Equatable, Sendable, Identifiable {
    var index: Int64; var sourceRef: SchemaObjectRef?; var targetRef: SchemaObjectRef?; var property: String
    var kind: String; var sourcePreview: SchemaValuePreview?; var targetPreview: SchemaValuePreview?
    var planning: String; var reasonCodes: [String]
    var id: Int64 { index }
    var valid: Bool {
        index >= 0 && (sourceRef != nil || targetRef != nil) && sourceRef?.valid != false && targetRef?.valid != false &&
        property.utf8.count <= 4_096 && ["sourceOnly", "targetOnly", "changed", "indeterminate"].contains(kind) &&
        ["structured", "manual"].contains(planning) && sourcePreview?.valid != false && targetPreview?.valid != false &&
        reasonCodes.count <= 32 && reasonCodes.allSatisfy { $0.utf8.count <= 128 }
    }
}
struct SchemaComparisonIssue: Codable, Equatable, Sendable, Identifiable {
    var index: Int64; var side: String; var ref: SchemaObjectRef?; var property: String; var code: String
    var message: String; var blocksEquality: Bool; var planning: String
    var id: Int64 { index }
    var valid: Bool { index >= 0 && ["source", "target", "both"].contains(side) && ref?.valid != false &&
        property.utf8.count <= 4_096 && code.utf8.count <= 128 && message.utf8.count <= 4_096 && ["structured", "manual"].contains(planning) }
}
struct SchemaComparisonPage: Codable, Equatable, Sendable {
    var collection: String; var offset: Int64; var nextOffset: Int64; var hasMore: Bool
    var differences: [SchemaDifference] = []; var issues: [SchemaComparisonIssue] = []
    enum CodingKeys: String, CodingKey { case collection, offset, nextOffset, hasMore, items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decode(String.self, forKey: .collection); offset = try c.decode(Int64.self, forKey: .offset)
        nextOffset = try c.decode(Int64.self, forKey: .nextOffset); hasMore = try c.decode(Bool.self, forKey: .hasMore)
        if collection == "differences" { differences = try c.decode([SchemaDifference].self, forKey: .items) }
        else if collection == "issues" { issues = try c.decode([SchemaComparisonIssue].self, forKey: .items) }
        else { throw BackendTransportError(.invalidMessage) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(collection, forKey: .collection); try c.encode(offset, forKey: .offset); try c.encode(nextOffset, forKey: .nextOffset)
        try c.encode(hasMore, forKey: .hasMore)
        if collection == "differences" { try c.encode(differences, forKey: .items) } else { try c.encode(issues, forKey: .items) }
    }
    var count: Int { differences.count + issues.count }
    var valid: Bool { offset >= 0 && nextOffset == offset + Int64(count) && count <= 1_000 && (!hasMore || count > 0) &&
        differences.enumerated().allSatisfy { $0.element.valid && $0.element.index == offset + Int64($0.offset) } &&
        issues.enumerated().allSatisfy { $0.element.valid && $0.element.index == offset + Int64($0.offset) } }
}
struct SchemaComparisonChunk: Codable, Equatable, Sendable {
    var valueRef: String?; var sha256: String?; var totalBytes: Int64; var offset: Int64; var nextOffset: Int64
    var dataBase64: String; var hasMore: Bool
    var data: Data? { Data(base64Encoded: dataBase64) }
    var valid: Bool { offset >= 0 && totalBytes >= 0 && totalBytes <= 192 * 1_024 * 1_024 && nextOffset <= totalBytes &&
        data != nil && (data?.count ?? Int.max) <= 1_048_576 && nextOffset == offset + Int64(data?.count ?? 0) &&
        hasMore == (nextOffset < totalBytes) && (!hasMore || nextOffset > offset) }
}
struct SchemaComparisonResponse: Codable, Equatable, Sendable {
    var jobId: String; var state: ResultComparisonState; var code: String?; var message: String?
    var summary: SchemaComparisonSummary?; var page: SchemaComparisonPage?; var value: SchemaComparisonChunk?; var export: SchemaComparisonChunk?
    var diff: ComparisonTextDiff?
    var offset: Int64?
    func valid(for type: String) -> Bool {
        guard (diff == nil && offset == nil) || type == "schema.diff.result" else { return false }
        guard BackendMessage.validID(jobId), (message?.utf8.count ?? 0) <= 4_096, (code?.utf8.count ?? 0) <= 128 else { return false }
        switch type {
        case "schema.diff.result": return state == .completed && diff?.valid == true && (offset ?? -1) >= 0 && summary == nil && page == nil && value == nil && export == nil
        case "schema.start.result": return state == .pending && summary == nil && page == nil && value == nil && export == nil
        case "schema.status.result": return (state == .completed ? summary?.valid == true : summary == nil) && page == nil && value == nil && export == nil
        case "schema.page.result": return state == .completed && summary == nil && page?.valid == true && value == nil && export == nil
        case "schema.value.result": return state == .completed && summary == nil && page == nil && value?.valid == true && value?.valueRef != nil && export == nil
        case "schema.export.result": return state == .completed && summary == nil && page == nil && value == nil && export?.valid == true && export?.sha256?.count == 64
        case "schema.cancel.result": return state == .cancelled && summary == nil && page == nil && value == nil && export == nil
        case "schema.close.result": return state == .closed && summary == nil && page == nil && value == nil && export == nil
        default: return false
        }
    }
}
