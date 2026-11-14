import Foundation

/// Presentation uses the helper's scope decisions; it never derives exclusive
/// time by subtracting overlapping parent/child measurements.
enum ExplainMetricPresentation {
    static func title(_ key: String) -> String {
        switch key {
        case "startupCost": "Startup cost"
        case "totalCost": "Total cost"
        case "estimatedRows": "Estimated rows per invocation"
        case "actualRows": "Actual rows per invocation"
        case "loops": "Loops"
        case "startupTime": "First-row time"
        case "totalTime": "Last-row time"
        case "planningTime": "Planning time"
        case "executionTime": "Execution time"
        case "exclusiveTime": "Proven exclusive time"
        case "sharedHitBlocks": "Shared buffer hits"
        case "sharedReadBlocks": "Shared buffer reads"
        case "sharedDirtiedBlocks": "Shared buffers dirtied"
        case "sharedWrittenBlocks": "Shared buffers written"
        case "localHitBlocks": "Local buffer hits"
        case "localReadBlocks": "Local buffer reads"
        case "localDirtiedBlocks": "Local buffers dirtied"
        case "localWrittenBlocks": "Local buffers written"
        case "tempReadBlocks": "Temporary blocks read"
        case "tempWrittenBlocks": "Temporary blocks written"
        case "ioReadTime": "I/O read time"
        case "ioWriteTime": "I/O write time"
        case "sharedIOReadTime": "Shared I/O read time"
        case "sharedIOWriteTime": "Shared I/O write time"
        case "localIOReadTime": "Local I/O read time"
        case "localIOWriteTime": "Local I/O write time"
        case "tempIOReadTime": "Temporary I/O read time"
        case "tempIOWriteTime": "Temporary I/O write time"
        case "walBytes": "WAL bytes"
        case "walRecords": "WAL records"
        case "walFPI": "WAL full-page images"
        case "walBuffersFull": "WAL buffers full"
        case "workersPlanned": "Workers planned"
        case "workersLaunched": "Workers launched"
        case "mariaDBPagesAccessed": "InnoDB pages accessed"
        case "mariaDBPagesUpdated": "InnoDB pages updated"
        case "mariaDBPagesRead": "InnoDB pages read from disk"
        case "mariaDBPagesPrefetched": "InnoDB pages prefetched"
        case "mariaDBPagesReadTime": "InnoDB table read time"
        case "mariaDBOldRowsRead": "InnoDB old row versions read"
        case "functions": "Functions"
        case "generationTime": "Generation (includes deform)"
        case "deformTime": "Deform (included in generation)"
        case "inliningTime": "Inlining"
        case "optimizationTime": "Optimization"
        case "emissionTime": "Emission"
        default: key
        }
    }

    static func label(_ metric: ExplainMetric) -> String {
        guard let value = metric.value else {
            switch metric.unavailableReason {
            case "inclusiveOnly": return "Unavailable — inclusive timing overlaps; exclusive time cannot be derived"
            case "parallel": return "Unavailable — parallel work overlaps"
            case "unknownScope": return "Unavailable — execution scope is unknown"
            case "partialInput": return "Unavailable — parent may have consumed only part of the input"
            default: return metric.unavailableLabel
            }
        }
        let basis: String
        switch metric.basis {
        case "perInvocation": basis = "per invocation"
        case "exclusivePerInvocation": basis = "exclusive per invocation"
        case "inclusiveTotal": basis = "inclusive total across loops"
        default: basis = metric.basis
        }
        return "\(value) \(metric.unit) · \(basis)"
    }

    static func rowComparison(_ node: ExplainNode) -> String {
        guard let advanced = node.advancedMetrics else { return "Row comparison unavailable — this capture has no row-scope evidence" }
        switch advanced.rowComparison {
        case "comparable":
            let estimate = node.metrics["estimatedRows"]?.value ?? "unavailable"
            let actual = node.metrics["actualRows"]?.value ?? "unavailable"
            return "Comparable rows per invocation · estimated \(estimate), actual \(actual)" + (rowBadge(node).map { " · \($0)" } ?? "")
        case "partialInput": return "Rows are not comparable — LIMIT, merge, semi/anti join or another parent may have stopped input early"
        case "parallel": return "Rows are not comparable — parallel and worker scope may differ"
        case "logical": return "Rows are not comparable — logical output estimates are not iterator row counts"
        case "notExecuted": return "Rows are not comparable — operation was not executed (zero loops)"
        case "notCollected": return "Row comparison unavailable — actual rows were not collected"
        case "notReported": return "Row comparison unavailable — server did not report both row counts"
        default: return "Rows are not comparable — execution scope is unknown"
        }
    }

    static func rowBadge(_ node: ExplainNode) -> String? {
        guard node.advancedMetrics?.rowComparison == "comparable",
              let estimate = node.metrics["estimatedRows"]?.decimal,
              let actual = node.metrics["actualRows"]?.decimal else { return nil }
        if estimate == actual { return "Estimate matched" }
        if estimate == 0 { return "Zero estimate; actual rows reported" }
        if actual == 0 { return "No actual rows; positive estimate" }
        var numerator = max(estimate, actual), denominator = min(estimate, actual), ratio = Decimal()
        let error = NSDecimalDivide(&ratio, &numerator, &denominator, .plain)
        guard error == .noError || error == .lossOfPrecision, !ratio.isNaN else { return nil }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &ratio, 2, .plain)
        return "\(actual > estimate ? "Underestimated" : "Overestimated") ≈\(NSDecimalNumber(decimal: rounded).stringValue)×"
    }
}

enum ExplainFlameBasis: String, CaseIterable, Identifiable {
    case inclusiveTime, estimatedCost, exclusiveTime
    var id: String { rawValue }
    var title: String {
        switch self { case .inclusiveTime: "Inclusive time"; case .estimatedCost: "Estimated cost"; case .exclusiveTime: "Proven exclusive time" }
    }
    var explanation: String {
        switch self {
        case .inclusiveTime: "Independent inclusive lanes · each metric states per-invocation or total-across-loops timing. Parent and child values overlap; this is not a timeline or a partition."
        case .estimatedCost: "Independent inclusive lanes · planner cost units. Parent and child costs overlap; costs are not elapsed time."
        case .exclusiveTime: "Independent lanes · exclusive ms per invocation, only where the helper proves a serial leaf. Unknown, parallel and inclusive-only values stay unavailable."
        }
    }
    func metric(_ node: ExplainNode) -> ExplainMetric? {
        let metric: ExplainMetric?
        switch self {
        case .inclusiveTime: metric = node.metrics["totalTime"]
        case .estimatedCost: metric = node.metrics["totalCost"]
        case .exclusiveTime: metric = node.advancedMetrics?.exclusiveTime
        }
        guard let metric else { return nil }
        let expected = self == .estimatedCost ? ("cost", "inclusive") : self == .exclusiveTime ? ("ms", "exclusivePerInvocation") : ("ms", "perInvocation")
        return metric.unit == expected.0 && (metric.basis == expected.1 || self == .inclusiveTime && metric.basis == "inclusiveTotal") && metric.valid ? metric : nil
    }
}

struct ExplainPlanLayout {
    static let maximumVisualNodes = 500
    struct Row: Identifiable {
        let node: ExplainNode
        let depth: Int
        let position: Int
        var id: String { node.id }
        var x: Double { Double(depth) * 240 + 12 }
        var y: Double { Double(position) * 72 + 12 }
    }
    struct Edge: Identifiable {
        let parent: Row
        let child: Row
        var id: String { child.id }
    }
    let rows: [Row]
    let edges: [Edge]
    let totalCount: Int
    var limited: Bool { rows.count < totalCount }
    var width: Double { max(240, (rows.map(\.x).max() ?? 0) + 228) }
    var height: Double { max(80, Double(rows.count) * 72 + 12) }
    var limitLabel: String { "Showing \(rows.count) of \(totalCount) operations. Tree view contains every operation." }

    init(_ result: ExplainResult, limit: Int = Self.maximumVisualNodes) {
        totalCount = result.nodes.count
        let indexed = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.id, $0) })
        var pending = result.roots.reversed().map { ($0, 0) }
        var visited = Set<String>(), ordered: [Row] = []
        while ordered.count < max(0, min(limit, Self.maximumVisualNodes)), let (id, depth) = pending.popLast() {
            guard let node = indexed[id], visited.insert(id).inserted, depth < 128 else { continue }
            ordered.append(Row(node: node, depth: depth, position: ordered.count))
            pending.append(contentsOf: node.children.reversed().map { ($0, depth + 1) })
        }
        rows = ordered
        let visible = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        edges = ordered.flatMap { parent in parent.node.children.compactMap { visible[$0].map { Edge(parent: parent, child: $0) } } }
    }

    /// Logarithmic comparison keeps exact numeric text in the evidence while
    /// allowing finite, bounded geometry for values beyond Double/Decimal.
    static func magnitude(_ metric: ExplainMetric?) -> Double? {
        guard let metric, metric.valid, let value = metric.value else { return nil }
        let parts = value.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        let mantissa = String(parts[0]), exponent = parts.count == 2 ? (Double(parts[1]) ?? .infinity) : 0
        let pieces = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let digits = pieces.joined()
        guard let first = digits.firstIndex(where: { $0 != "0" }) else { return -.infinity }
        let offset = digits.distance(from: digits.startIndex, to: first)
        let significant = String(digits[first...].prefix(15))
        guard let leading = Double(significant), leading > 0 else { return nil }
        let fraction = leading / pow(10, Double(significant.count - 1))
        return log10(fraction) + Double(pieces[0].count - offset - 1) + exponent
    }

    static func fraction(_ metric: ExplainMetric?, maximumMagnitude: Double?) -> Double? {
        guard let magnitude = magnitude(metric), let maximumMagnitude else { return nil }
        if magnitude == -.infinity { return 0 }
        if magnitude == maximumMagnitude { return 1 }
        if !magnitude.isFinite || !maximumMagnitude.isFinite { return 0.02 }
        return min(1, max(0.02, pow(10, magnitude - maximumMagnitude)))
    }
}

/// Advanced evidence is accepted only from the current connected SQL owner.
enum ExplainMetricsAdmission {
    static func validOwner(support: ExplainSupport?, engine: DatabaseEngine?, capabilities: Set<String>, helperSupports: Bool) -> Bool {
        guard helperSupports, capabilities.contains(ExplainNodeMetrics.capability), let support, support.valid,
              [.postgresql, .mysql, .mariadb].contains(support.engine), support.engine == engine else { return false }
        return true
    }
}
