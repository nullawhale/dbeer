import Foundation

struct ExplainNodeMetrics: Codable, Sendable, Equatable {
    static let capability = "explainMetricsV1"
    var version: Int
    var executionScope: String
    var rowComparison: String
    var exclusiveTime: ExplainMetric
    var counters: [String: ExplainMetric]
    var workers: [ExplainWorkerMetrics]
    var jit: ExplainJITMetrics? = nil

    func valid(engine: DatabaseEngine, node: ExplainNode, mode: ExplainMode) -> Bool {
        guard version == 1, [.postgresql, .mysql, .mariadb].contains(engine),
              (engine == .mariadb ? Self.validMariaDBCounters(counters) : Self.validCounters(counters, worker: false)), workers.count <= 256,
              ["serial", "parallel", "unknown", "logical"].contains(executionScope),
              ["comparable", "partialInput", "parallel", "logical", "notExecuted", "notCollected", "notReported", "unknownScope"].contains(rowComparison),
              jit == nil || engine == .postgresql && jit?.valid(scope: "queryAggregate") == true,
              exclusiveTime.unit == "ms", exclusiveTime.basis == "exclusivePerInvocation", exclusiveTime.valid else { return false }
        if executionScope == "logical" && (![DatabaseEngine.mysql, .mariadb].contains(engine) || rowComparison != "logical" || !counters.isEmpty || !workers.isEmpty) ||
            rowComparison == "logical" && executionScope != "logical" || rowComparison == "parallel" && executionScope != "parallel" ||
            rowComparison == "unknownScope" && executionScope != "unknown" { return false }
        if engine == .mysql && !counters.isEmpty { return false }
        if engine == .mariadb && !workers.isEmpty { return false }
        if (!workers.isEmpty || counters["workersPlanned"] != nil || counters["workersLaunched"] != nil) && executionScope != "parallel" { return false }
        if rowComparison == "comparable" {
            guard mode == .analyze, node.execution == "executed", executionScope == "serial",
                  Self.measurement(node, key: "estimatedRows", unit: "rows", basis: "perInvocation"),
                  Self.measurement(node, key: "actualRows", unit: "rows", basis: "perInvocation"),
                  Self.measurement(node, key: "loops", unit: "count", basis: "total"),
                  let loops = node.metrics["loops"]?.value, !Self.isZero(loops) else { return false }
        }
        if let exclusive = exclusiveTime.value {
            guard mode == .analyze, node.execution == "executed", executionScope == "serial", node.children.isEmpty,
                  Self.knownSerialLeaf(engine: engine, operation: node.operation), let loops = node.metrics["loops"]?.value,
                  !Self.isZero(loops), Self.measurement(node, key: "loops", unit: "count", basis: "total"),
                  Self.measurement(node, key: "totalTime", unit: "ms", basis: "perInvocation"), node.metrics["totalTime"]?.value == exclusive else { return false }
        }
        var seen = Set<Int>()
        return workers.allSatisfy { worker in
            engine == .postgresql && (0...65_535).contains(worker.number) && seen.insert(worker.number).inserted &&
                Self.validCounters(worker.metrics, worker: true) && (worker.jit?.valid(scope: "worker") ?? true)
        }
    }
    static func measurement(_ node: ExplainNode, key: String, unit: String, basis: String) -> Bool {
        guard let metric = node.metrics[key] else { return false }
        return metric.value != nil && metric.unit == unit && metric.basis == basis && metric.valid
    }
    static func knownSerialLeaf(engine: DatabaseEngine, operation: String) -> Bool {
        if engine == .postgresql { return ["Seq Scan", "Index Scan", "Index Only Scan", "Bitmap Index Scan", "Values Scan", "Result"].contains(operation) }
        return engine == .mysql && ["Table scan on ", "Index scan on ", "Covering index scan on ", "Index lookup on ", "Covering index lookup on ", "Single-row index lookup on "].contains { operation.hasPrefix($0) }
    }
    static func isZero(_ value: String) -> Bool {
        (value.split(whereSeparator: { $0 == "e" || $0 == "E" }).first ?? "").allSatisfy { $0 == "0" || $0 == "." }
    }
    static func validCounters(_ metrics: [String: ExplainMetric], worker: Bool) -> Bool {
        guard metrics.count <= 26 else { return false }
        return metrics.allSatisfy { key, metric in
            var unit = "", basis = "inclusiveTotal"
            switch key {
            case "sharedHitBlocks", "sharedReadBlocks", "sharedDirtiedBlocks", "sharedWrittenBlocks", "localHitBlocks", "localReadBlocks", "localDirtiedBlocks", "localWrittenBlocks", "tempReadBlocks", "tempWrittenBlocks": unit = "blocks"
            case "ioReadTime", "ioWriteTime", "sharedIOReadTime", "sharedIOWriteTime", "localIOReadTime", "localIOWriteTime", "tempIOReadTime", "tempIOWriteTime": unit = "ms"
            case "walBytes": unit = "bytes"
            case "walRecords", "walFPI", "walBuffersFull": unit = "count"
            case "workersPlanned", "workersLaunched":
                guard !worker else { return false }; unit = "count"; basis = "total"
            case "actualRows" where worker: unit = "rows"; basis = "perInvocation"
            case "startupTime" where worker, "totalTime" where worker: unit = "ms"; basis = "perInvocation"
            case "loops" where worker: unit = "count"; basis = "total"
            default: return false
            }
            return metric.valid && metric.unit == unit && metric.basis == basis
        }
    }
    static func validMariaDBCounters(_ metrics: [String: ExplainMetric]) -> Bool {
        let units = ["mariaDBPagesAccessed": "count", "mariaDBPagesUpdated": "count", "mariaDBPagesRead": "count",
                     "mariaDBPagesPrefetched": "count", "mariaDBPagesReadTime": "ms", "mariaDBOldRowsRead": "rows"]
        return metrics.count <= units.count && metrics.allSatisfy { key, metric in
            units[key] == metric.unit && metric.basis == "total" && metric.valid
        }
    }
    init(version: Int = 1, executionScope: String, rowComparison: String, exclusiveTime: ExplainMetric, counters: [String: ExplainMetric] = [:], workers: [ExplainWorkerMetrics] = [], jit: ExplainJITMetrics? = nil) {
        self.version = version; self.executionScope = executionScope; self.rowComparison = rowComparison
        self.exclusiveTime = exclusiveTime; self.counters = counters; self.workers = workers; self.jit = jit
    }
    private enum CodingKeys: String, CodingKey { case version, executionScope, rowComparison, exclusiveTime, counters, workers, jit }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["version", "executionScope", "rowComparison", "exclusiveTime", "counters", "workers"], optional: ["jit"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        version = try fields.decode(Int.self, forKey: .version)
        executionScope = try fields.decode(String.self, forKey: .executionScope)
        rowComparison = try fields.decode(String.self, forKey: .rowComparison)
        exclusiveTime = try fields.decode(ExplainMetric.self, forKey: .exclusiveTime)
        counters = try fields.decode([String: ExplainMetric].self, forKey: .counters)
        workers = try fields.decode([ExplainWorkerMetrics].self, forKey: .workers)
        jit = fields.contains(.jit) ? try fields.decode(ExplainJITMetrics.self, forKey: .jit) : nil
    }
}
struct ExplainWorkerMetrics: Codable, Sendable, Equatable {
    var number: Int
    var metrics: [String: ExplainMetric]
    var jit: ExplainJITMetrics? = nil
    init(number: Int, metrics: [String: ExplainMetric], jit: ExplainJITMetrics? = nil) { self.number = number; self.metrics = metrics; self.jit = jit }
    private enum CodingKeys: String, CodingKey { case number, metrics, jit }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["number", "metrics"], optional: ["jit"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        number = try fields.decode(Int.self, forKey: .number)
        metrics = try fields.decode([String: ExplainMetric].self, forKey: .metrics)
        jit = fields.contains(.jit) ? try fields.decode(ExplainJITMetrics.self, forKey: .jit) : nil
    }
}
struct ExplainJITMetrics: Codable, Sendable, Equatable {
    var scope: String
    var metrics: [String: ExplainMetric]
    func valid(scope expected: String) -> Bool {
        scope == expected && metrics.count <= 7 && metrics.allSatisfy { key, metric in
            ["functions", "generationTime", "deformTime", "inliningTime", "optimizationTime", "emissionTime", "totalTime"].contains(key) &&
                metric.unit == (key == "functions" ? "count" : "ms") && metric.basis == "total" && metric.valid
        }
    }
    init(scope: String, metrics: [String: ExplainMetric]) { self.scope = scope; self.metrics = metrics }
    private enum CodingKeys: String, CodingKey { case scope, metrics }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["scope", "metrics"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        scope = try fields.decode(String.self, forKey: .scope)
        metrics = try fields.decode([String: ExplainMetric].self, forKey: .metrics)
    }
}
struct ExplainPlanMetrics: Codable, Sendable, Equatable {
    var version: Int
    func valid(engine: DatabaseEngine) -> Bool { version == 1 && [.postgresql, .mysql, .mariadb].contains(engine) }
    init(version: Int = 1) { self.version = version }
    private enum CodingKeys: String, CodingKey { case version }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["version"])
        version = try decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .version)
    }
}
