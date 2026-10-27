import Foundation

struct DataComparisonTable: Codable, Equatable, Sendable {
    var schema: String
    var name: String
    var valid: Bool { Self.nameValid(schema) && Self.nameValid(name) }
    static func nameValid(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0") }
    var title: String { schema + " · " + name }
}
struct DataComparisonColumn: Codable, Equatable, Sendable {
    var index: Int; var name: String; var nativeType: String; var typeLabel: String; var encoding: String?
    var primaryKey: Int; var numeric: Bool; var generated: Bool; var identity: Bool; var nullable: Bool
    var valueComparison: String?
}
struct DataComparisonDescriptor: Codable, Equatable, Sendable {
    var formatVersion: Int; var engine: DatabaseEngine; var table: DataComparisonTable
    var columns: [DataComparisonColumn]; var digest: String
    var valid: Bool {
        formatVersion == 1 && table.valid && DataComparisonRequest.digestValid(digest) &&
        (1...4_096).contains(columns.count) && Set(columns.map { Data($0.name.utf8) }).count == columns.count &&
        columns.enumerated().allSatisfy { $0.element.index == $0.offset && DataComparisonTable.nameValid($0.element.name) &&
            !$0.element.nativeType.isEmpty && $0.element.nativeType.utf8.count <= 65_536 && $0.element.typeLabel.utf8.count <= 4_096 &&
            $0.element.primaryKey >= 0 && $0.element.primaryKey <= 32 &&
            ($0.element.valueComparison == nil || $0.element.valueComparison == "unresolved") &&
            ($0.element.encoding == nil || $0.element.encoding == "base64") }
    }
}
struct DataComparisonDescriptors: Codable, Equatable, Sendable {
    var source: DataComparisonDescriptor; var target: DataComparisonDescriptor
    var valid: Bool { source.valid && target.valid && source.engine == target.engine }
}
struct DataComparisonFilter: Codable, Equatable, Sendable {
    var column: String; var `operator`: String; var value: String?
    var valid: Bool {
        guard DataComparisonTable.nameValid(column) else { return false }
        if ["isNull", "isNotNull"].contains(`operator`) { return value == nil }
        return ["eq", "ne", "lt", "lte", "gt", "gte", "contains"].contains(`operator`) && value != nil &&
            (value?.utf8.count ?? Int.max) <= 4_096 && value?.contains("\0") == false
    }
}
struct DataComparisonMapping: Codable, Equatable, Sendable { var source: String; var target: String; var key: Bool }
struct DataComparisonReadSide: Codable, Equatable, Sendable {
    var connection: ConnectionSettings; var table: DataComparisonTable
    var descriptorDigest: String?; var filters: [DataComparisonFilter]?; var readLimit: Int?
    var validRead: Bool { table.valid && descriptorDigest.map(DataComparisonRequest.digestValid) == true && filters != nil &&
        (filters?.count ?? Int.max) <= 32 && filters?.allSatisfy(\.valid) == true && (1...100_000).contains(readLimit ?? 0) }
}
struct DataComparisonRequest: Codable, Equatable, Sendable {
    var source: DataComparisonReadSide?; var target: DataComparisonReadSide?; var columns: [DataComparisonMapping]?
    var originals: String?; var jobId: String?; var offset: Int64?; var limit: Int?; var maxBytes: Int?; var cellOffset: Int?; var valueRef: String?
    var modelDigest: String?
    static func digestValid(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    func valid(for type: String) -> Bool {
        let noInputs = source == nil && target == nil && columns == nil && originals == nil
        if type != "data.plan", modelDigest != nil { return false }
        switch type {
        case "data.plan":
            return noInputs && jobId.map(BackendMessage.validID) == true && modelDigest.map(Self.digestValid) == true && offset == nil && limit == nil && maxBytes == nil && cellOffset == nil && valueRef == nil
        case "data.describe", "data.start":
            guard let source, let target, source.connection.engine == target.connection.engine,
                  source.table.valid, target.table.valid, jobId == nil, offset == nil, limit == nil, maxBytes == nil, cellOffset == nil, valueRef == nil else { return false }
            if type == "data.describe" { return source.descriptorDigest == nil && source.filters == nil && source.readLimit == nil &&
                target.descriptorDigest == nil && target.filters == nil && target.readLimit == nil && columns == nil && originals == nil }
            guard source.validRead, target.validRead, ["allColumns", "selectedColumns"].contains(originals), let columns,
                  (1...4_096).contains(columns.count), (1...32).contains(columns.filter(\.key).count) else { return false }
            return columns.allSatisfy { DataComparisonTable.nameValid($0.source) && DataComparisonTable.nameValid($0.target) } &&
                Set(columns.map { Data($0.source.utf8) }).count == columns.count && Set(columns.map { Data($0.target.utf8) }).count == columns.count
        case "data.status", "data.cancel", "data.close":
            return noInputs && jobId.map(BackendMessage.validID) == true && offset == nil && limit == nil && maxBytes == nil && cellOffset == nil && valueRef == nil
        case "data.diff":
            return noInputs && jobId.map(BackendMessage.validID) == true && (offset ?? 0) >= 0 &&
                (cellOffset ?? 0) >= 0 && limit == nil && maxBytes == nil && valueRef == nil
        case "data.page":
            return noInputs && jobId.map(BackendMessage.validID) == true && (offset ?? 0) >= 0 && (1...1_000).contains(limit ?? 100) &&
                (4_096...1_048_576).contains(maxBytes ?? 262_144) && (cellOffset ?? 0) >= 0 && valueRef == nil
        case "data.value":
            return noInputs && jobId.map(BackendMessage.validID) == true && valueRef.map(ResultComparisonRequest.validToken) == true &&
                (offset ?? 0) >= 0 && (1...1_048_576).contains(maxBytes ?? 65_536) && limit == nil && cellOffset == nil
        default: return false
        }
    }
}
struct DataComparisonCaptureContext: Codable, Equatable, Sendable {
    var startedAt: String; var finishedAt: String; var consistency: String; var rendering: String
    var storedRows: Int64; var observedAtLeast: Int64; var readLimit: Int; var partialReasons: [String]; var fullOriginals: Bool
    var descriptorDigest: String; var captureDigest: String; var table: DataComparisonTable; var engine: DatabaseEngine; var excludedColumns: Int
    var valid: Bool {
        !startedAt.isEmpty && !finishedAt.isEmpty && startedAt.utf8.count <= 64 && finishedAt.utf8.count <= 64 &&
        (engine == .cassandra ? consistency == "bestEffort" && rendering == "cassandraCQLv1" && partialReasons.contains("nonSnapshot") :
            consistency == (engine == .postgresql ? "repeatableRead" : "repeatableReadBestEffortMetadata") &&
            (engine == .postgresql ? rendering == "postgresTextUTCISOv1" : ["mysqlTextUTCUTF8v1", "mysqlTextUTCUTF8v2", "mysqlTextUTCUTF8v3"].contains(rendering)) && !partialReasons.contains("nonSnapshot")) &&
        (1...100_000).contains(readLimit) &&
        storedRows >= 0 && storedRows <= readLimit && observedAtLeast >= storedRows && observedAtLeast <= Int64(readLimit) + 1 &&
        (!partialReasons.contains("readLimit") || storedRows == readLimit && observedAtLeast == Int64(readLimit) + 1) &&
        partialReasons.count <= 3 && Set(partialReasons).count == partialReasons.count &&
        partialReasons.allSatisfy { ["readLimit", "storageLimit", "nonSnapshot"].contains($0) } &&
        (partialReasons.isEmpty ? observedAtLeast == storedRows : true) &&
        DataComparisonRequest.digestValid(descriptorDigest) && DataComparisonRequest.digestValid(captureDigest) && table.valid &&
        (0...4_096).contains(excludedColumns)
    }
}
struct DataComparisonSummary: Codable, Equatable, Sendable {
    var formatVersion: Int; var comparison: ResultComparisonSummary; var source: DataComparisonCaptureContext; var target: DataComparisonCaptureContext
    var mappedColumns: Int; var keyColumns: Int; var modelDigest: String
    var valid: Bool {
        formatVersion == 1 && comparison.valid && source.valid && target.valid && source.engine == target.engine &&
        comparison.leftRows == source.storedRows && comparison.rightRows == target.storedRows &&
        comparison.complete == (source.partialReasons.isEmpty && target.partialReasons.isEmpty) &&
        (!comparison.fullEquality || source.fullOriginals && target.fullOriginals && source.excludedColumns == 0 && target.excludedColumns == 0) &&
        (1...4_096).contains(mappedColumns) && (1...min(32, mappedColumns)).contains(keyColumns) && DataComparisonRequest.digestValid(modelDigest)
    }
}
struct DataComparisonResponse: Codable, Equatable, Sendable {
    var jobId: String; var state: ResultComparisonState; var phase: String?; var code: String?; var message: String?
    var descriptors: DataComparisonDescriptors?; var summary: DataComparisonSummary?
    var page: ResultComparisonPage?; var value: ResultComparisonValueChunk?
    var diff: ComparisonTextDiff?
    var offset: Int64?
    var cellOffset: Int?
    var plan: SynchronizationSQLPlan?
    func valid(for type: String) -> Bool {
        guard plan == nil || type == "data.plan.result" else { return false }
        guard (diff == nil && offset == nil && cellOffset == nil) || type == "data.diff.result" else { return false }
        guard BackendMessage.validID(jobId), (message?.utf8.count ?? 0) <= 4_096, (code?.utf8.count ?? 0) <= 128,
              phase == nil || ["capturing", "comparing"].contains(phase), summary?.valid != false, descriptors?.valid != false else { return false }
        switch type {
        case "data.plan.result": return state == .completed && plan?.valid == true && plan?.kind == "data" && descriptors == nil && summary == nil && page == nil && value == nil
        case "data.diff.result": return state == .completed && diff?.valid == true && (offset ?? -1) >= 0 && (cellOffset ?? -1) >= 0 && descriptors == nil && summary == nil && page == nil && value == nil
        case "data.start.result", "data.describe.result": return state == .pending && descriptors == nil && summary == nil && page == nil && value == nil
        case "data.status.result": return page == nil && value == nil &&
            (state == .completed ? (descriptors != nil) != (summary != nil) : descriptors == nil && summary == nil)
        case "data.page.result": return state == .completed && summary == nil && descriptors == nil && page?.valid == true && value == nil
        case "data.value.result": return state == .completed && summary == nil && descriptors == nil && value?.valid == true && page == nil
        case "data.cancel.result": return state == .cancelled && descriptors == nil && summary == nil && page == nil && value == nil
        case "data.close.result": return state == .closed && descriptors == nil && summary == nil && page == nil && value == nil
        default: return false
        }
    }
}
