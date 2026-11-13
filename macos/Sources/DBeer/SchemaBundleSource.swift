import Foundation

struct SchemaBundleSourceDescriptor: Codable, Equatable, Sendable {
    var path: String
    var allowSQLChanges = false
    var engine: String?
    var manifestSha256: String?
    var contentSha256: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        Data(lhs.path.utf8) == Data(rhs.path.utf8) && lhs.allowSQLChanges == rhs.allowSQLChanges &&
        lhs.engine == rhs.engine && lhs.manifestSha256 == rhs.manifestSha256 && lhs.contentSha256 == rhs.contentSha256
    }
    var databaseEngine: DatabaseEngine? { engine.flatMap(DatabaseEngine.init(rawValue:)) }
    func valid(inspecting: Bool) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.contains("\0"), (path as NSString).isAbsolutePath,
              !path.hasPrefix("file:") else { return false }
        if inspecting { return engine == nil && manifestSha256 == nil && contentSha256 == nil }
        guard let engine, ["postgresql", "mysql", "sqlite"].contains(engine) else { return false }
        return manifestSha256.map(DataComparisonRequest.digestValid) == true && contentSha256.map(DataComparisonRequest.digestValid) == true
    }
}

struct SchemaImportedSource: Codable, Equatable, Sendable {
    var source: SchemaBundleSourceDescriptor
    var label: String
    var schemas: [String]
    var modifiedSQL: Int
    var manualObjects: Int
    var complete: Bool
    var valid: Bool {
        source.valid(inspecting: false) && !label.isEmpty && label.utf8.count <= 256 && !label.contains("\0") &&
            SchemaBundleManifest.schemasValid(schemas, engine: source.engine ?? "") &&
            (0...20_000).contains(modifiedSQL) && (0...10_000).contains(manualObjects) && (!complete || manualObjects == 0)
    }
    var title: String { "\(label) · \(source.databaseEngine?.displayName ?? source.engine ?? "Schema bundle")" }
}

struct SchemaHistoricalOrigin: Codable, Equatable, Sendable {
    var kind: String
    var label: String
    var manifestSha256: String
    var contentSha256: String
    var modifiedSQL: Int
    var manualObjects: Int
    var valid: Bool {
        ["bundle", "editedBundle"].contains(kind) && !label.isEmpty && label.utf8.count <= 256 && !label.contains("\0") &&
            DataComparisonRequest.digestValid(manifestSha256) && DataComparisonRequest.digestValid(contentSha256) &&
            (0...20_000).contains(modifiedSQL) && (0...10_000).contains(manualObjects) &&
            (kind != "bundle" || modifiedSQL == 0) && (kind != "editedBundle" || modifiedSQL > 0)
    }
}

enum SchemaBundleSourceFrame {
    /// Check original field presence as well as typed values. An optional null,
    /// duplicate key or case-aliased field is not a compatible source variant.
    static func validate(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String, type.hasPrefix("schema.") else { return }
        if !type.hasPrefix("schema.import."),
           (root["schemaComparison"] as? [String: Any])?["summary"] == nil { return }
        try SchemaBundleJSON.validate(data)
        guard let response = root["schemaComparison"] as? [String: Any] else { return }
        if type.hasPrefix("schema.import.") {
            try closed(root, required: ["type", "requestId", "schemaComparison"], optional: [])
            try closed(response, required: ["jobId", "state"], optional: ["code", "message", "importSummary"])
            if let raw = response["importSummary"] {
                let summary = try closed(raw, required: ["source", "label", "schemas", "modifiedSQL", "manualObjects", "complete"], optional: [])
                _ = try closed(summary["source"], required: ["path", "allowSQLChanges", "engine", "manifestSha256", "contentSha256"], optional: [])
            }
        }
        if let summary = response["summary"] as? [String: Any] {
            for key in ["source", "target"] {
                if let context = summary[key] as? [String: Any], let origin = context["origin"] {
                    _ = try closed(origin, required: ["kind", "label", "manifestSha256", "contentSha256", "modifiedSQL", "manualObjects"], optional: [])
                }
            }
        }
    }
    @discardableResult private static func closed(_ raw: Any?, required: Set<String>, optional: Set<String>) throws -> [String: Any] {
        guard let value = raw as? [String: Any], required.isSubset(of: Set(value.keys)),
              Set(value.keys).isSubset(of: required.union(optional)), !value.values.contains(where: { $0 is NSNull }) else {
            throw BackendTransportError(.invalidMessage)
        }
        return value
    }
}
