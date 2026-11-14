import Foundation

struct DiagnosticMetric: Codable, Equatable, Sendable {
    var value: String?
    var unit: String
    var basis: String
    var unavailableReason: String?
    var valid: Bool {
        ["documents", "keys", "ms", "us", "count"].contains(unit) &&
        ["total", "stage", "stageEstimate", "coordinator", "sourceElapsed"].contains(basis) &&
        (value.map { ExplainMetric.validDecimal($0) && unavailableReason == nil } ??
            ["notCollected", "notReported", "unsupported", "notExecuted"].contains(unavailableReason))
    }
    var label: String {
        guard let value else {
            switch unavailableReason {
            case "notCollected": return "Unavailable — not collected for this diagnostic mode"
            case "unsupported": return "Unavailable — unsupported by this diagnostic"
            case "notExecuted": return "Unavailable — not executed"
            default: return "Unavailable — server did not report this measurement"
            }
        }
        let meaning: String
        switch basis {
        case "sourceElapsed": meaning = "elapsed on this source node"
        case "coordinator": meaning = "coordinator duration"
        case "stageEstimate": meaning = "server stage estimate"
        case "stage": meaning = "reported for this stage"
        default: meaning = "reported total"
        }
        return "\(value) \(unit) · \(meaning)"
    }
}
private func diagnosticText(_ value: String, maximum: Int) -> Bool { value.utf8.count <= maximum }
private func validDiagnosticMetrics(_ values: [String: DiagnosticMetric]) -> Bool {
    values.count <= 16 && values.allSatisfy { diagnosticText($0.key, maximum: 128) && $0.value.valid }
}
struct MongoDBDiagnosticStage: Codable, Equatable, Sendable {
    var path: String
    var operation: String
    var metrics: [String: DiagnosticMetric]
}
struct MongoDBDiagnostic: Codable, Equatable, Sendable {
    var verbosity: String
    var sections: [String]
    var stages: [MongoDBDiagnosticStage]
    var metrics: [String: DiagnosticMetric]
    func valid(mode: ExplainMode) -> Bool {
        verbosity == (mode == .analyze ? "executionStats" : "queryPlanner") &&
        sections.count <= 1_000 && sections.allSatisfy { diagnosticText($0, maximum: 2_048) } &&
        stages.count <= 1_000 && Set(stages.map { Data($0.path.utf8) }).count == stages.count &&
        stages.allSatisfy { !$0.path.isEmpty && diagnosticText($0.path, maximum: 2_048) &&
            !$0.operation.isEmpty && diagnosticText($0.operation, maximum: 1_024) && validDiagnosticMetrics($0.metrics) } &&
        validDiagnosticMetrics(metrics)
    }
}
struct CassandraTraceEvent: Codable, Equatable, Sendable {
    var id: String
    var timestamp: String
    var activity: String
    var source: String
    var thread: String
    var sourceElapsed: DiagnosticMetric
    var valid: Bool {
        BackendMessage.validID(id) && diagnosticText(timestamp, maximum: 64) && diagnosticText(activity, maximum: 16_384) &&
        diagnosticText(source, maximum: 256) && diagnosticText(thread, maximum: 1_024) && sourceElapsed.valid &&
        sourceElapsed.unit == "us" && sourceElapsed.basis == "sourceElapsed"
    }
}
struct CassandraTraceSession: Codable, Equatable, Sendable {
    var id: String
    var command: String
    var coordinator: String
    var startedAt: String
    var duration: DiagnosticMetric
    var events: [CassandraTraceEvent]
    var valid: Bool {
        BackendMessage.validID(id) && diagnosticText(command, maximum: 256) && diagnosticText(coordinator, maximum: 256) &&
        diagnosticText(startedAt, maximum: 64) && duration.valid && duration.unit == "us" && duration.basis == "coordinator" &&
        Set(events.map { Data($0.id.utf8) }).count == events.count && events.allSatisfy(\.valid)
    }
}
struct CassandraDiagnostic: Codable, Equatable, Sendable {
    var scope: String
    var collectionConsistency: String
    var pageSize: Int
    var hasMorePages: Bool
    var traceSessions: [CassandraTraceSession]
    var collectionStatus: String
    var valid: Bool {
        scope == "firstServerPage" && collectionConsistency == "ONE" && pageSize == 200 && traceSessions.count <= 4 &&
        ["observed", "partial", "unavailable", "cancelled", "limited"].contains(collectionStatus) &&
        Set(traceSessions.map { Data($0.id.utf8) }).count == traceSessions.count &&
        traceSessions.reduce(0, { $0 + $1.events.count }) <= 1_000 && traceSessions.allSatisfy(\.valid)
    }
}
struct EngineDiagnostic: Codable, Equatable, Sendable {
    var kind: String
    var mongodb: MongoDBDiagnostic? = nil
    var cassandra: CassandraDiagnostic? = nil
    func valid(engine: DatabaseEngine, mode: ExplainMode) -> Bool {
        switch kind {
        case "mongodbExplain": return engine == .mongodb && cassandra == nil && mongodb?.valid(mode: mode) == true
        case "cassandraTrace": return engine == .cassandra && mode == .analyze && mongodb == nil && cassandra?.valid == true
        default: return false
        }
    }
    private enum CodingKeys: String, CodingKey { case kind, mongodb, cassandra }
    init(kind: String, mongodb: MongoDBDiagnostic? = nil, cassandra: CassandraDiagnostic? = nil) {
        self.kind = kind; self.mongodb = mongodb; self.cassandra = cassandra
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind)
        switch kind {
        case "mongodbExplain":
            try requireExplainKeys(decoder, required: ["kind", "mongodb"])
            mongodb = try values.decode(MongoDBDiagnostic.self, forKey: .mongodb)
        case "cassandraTrace":
            try requireExplainKeys(decoder, required: ["kind", "cassandra"])
            cassandra = try values.decode(CassandraDiagnostic.self, forKey: .cassandra)
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown engine diagnostic kind."))
        }
    }
}
