import CoreFoundation
import Foundation

extension ExplainMode {
    func title(engine: DatabaseEngine) -> String {
        switch engine {
        case .mongodb: self == .analyze ? "Execution Statistics" : "Query Planner"
        case .cassandra: self == .analyze ? "Trace Read" : "Estimated Plan Unavailable"
        default: title
        }
    }
    func commandTitle(engine: DatabaseEngine) -> String {
        title(engine: engine) + (self == .analyze ? "…" : "")
    }
}

extension DatabaseEngine {
    var hasEngineDiagnostics: Bool { self == .mongodb || self == .cassandra }
    func supportsExplain(_ mode: ExplainMode) -> Bool {
        switch self {
        case .postgresql, .mysql, .mariadb, .sqlite, .mongodb: true
        case .cassandra: mode == .analyze
        }
    }
}

extension ExplainResult {
    var evidenceKind: String { engineDiagnostic?.kind ?? "relationalPlan" }
}

/// Both negotiation and the actual physical owner state are required. An
/// unsupported transaction never authorizes a relational Explain request.
enum ExplainDiagnosticAdmission {
    static func validOwner(support: ExplainSupport?, capabilities: Set<String>, helperSupports: Bool,
                           transaction: TransactionStatus?, parameters: [QueryParameterBinding]?,
                           planKind: ExplainPlanKind?) -> Bool {
        guard let support, support.valid, support.engine.hasEngineDiagnostics,
              helperSupports, capabilities.contains("engineDiagnosticsV1"), transaction == .unsupported,
              parameters == nil, planKind == nil else { return false }
        return support.diagnosticModel == (support.engine == .mongodb ? "mongodbExplain" : "cassandraTrace")
    }
}

extension MongoDBScript {
    /// Admission only: send the original bytes to the helper's shared BSON
    /// parser. Never round-trip exact numeric or Extended JSON query values.
    static func validDiagnostic(_ text: String) -> Bool {
        let data = Data(text.utf8)
        guard (try? ExactJSONKeys.validate(data, maximumBytes: 1_048_576)) != nil,
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(document.keys).isSubset(of: ["database", "collection", "find", "sort", "projection", "limit", "aggregate"]),
              let collection = document["collection"] as? String, validName(collection),
              document["database"].map({ ($0 as? String).map(validName) == true }) ?? true,
              safeValue(document, depth: 0) else { return false }
        let find = document["find"] != nil, aggregate = document["aggregate"] != nil
        guard find != aggregate else { return false }
        if aggregate {
            return document["sort"] == nil && document["projection"] == nil && document["limit"] == nil &&
                validPipeline(document["aggregate"], depth: 0)
        }
        guard document["find"] is [String: Any],
              document["projection"].map({ $0 is [String: Any] }) ?? true else { return false }
        if let sort = document["sort"] {
            guard let sort = sort as? [String: Any], sort.count <= 32,
                  sort.allSatisfy({ entry in
                      guard validName(entry.key), let value = integer(entry.value) else { return false }
                      return [-1, 1].contains(value)
                  }) else { return false }
        }
        if let limit = document["limit"] {
            guard let value = integer(limit), (1...1_000_000).contains(value) else { return false }
        }
        return true
    }

    private static func validName(_ name: String) -> Bool { !name.isEmpty && name.utf8.count <= 1_024 && !name.contains("\0") }
    private static func integer(_ value: Any) -> Int? {
        if let object = value as? [String: Any], object.count == 1,
           let text = (object["$numberInt"] ?? object["$numberLong"]) as? String { return Int(text) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return Int(number.stringValue)
    }
    private static func safeValue(_ value: Any, depth: Int) -> Bool {
        guard depth <= 64 else { return false }
        if let object = value as? [String: Any] {
            let denied: Set<String> = ["$where", "$function", "$accumulator", "$eval", "$changeStream", "$code"]
            return object.allSatisfy { !denied.contains($0.key) && safeValue($0.value, depth: depth + 1) }
        }
        if let array = value as? [Any] { return array.allSatisfy { safeValue($0, depth: depth + 1) } }
        return true
    }
    private static func validPipeline(_ value: Any?, depth: Int) -> Bool {
        guard depth <= 32, let stages = value as? [[String: Any]], stages.count <= 256 else { return false }
        let allowed: Set<String> = ["$addFields", "$bucket", "$bucketAuto", "$collStats", "$count", "$densify", "$documents", "$facet", "$fill", "$geoNear", "$graphLookup", "$group", "$indexStats", "$limit", "$lookup", "$match", "$project", "$redact", "$replaceRoot", "$replaceWith", "$sample", "$set", "$setWindowFields", "$skip", "$sort", "$sortByCount", "$unionWith", "$unset", "$unwind"]
        return stages.allSatisfy { stage in
            guard stage.count == 1, let (name, value) = stage.first, allowed.contains(name) else { return false }
            if name == "$facet" {
                guard let facets = value as? [String: Any] else { return false }
                return facets.values.allSatisfy { validPipeline($0, depth: depth + 1) }
            }
            if ["$lookup", "$unionWith"].contains(name), let fields = value as? [String: Any], let pipeline = fields["pipeline"] {
                return validPipeline(pipeline, depth: depth + 1)
            }
            return true
        }
    }
}
