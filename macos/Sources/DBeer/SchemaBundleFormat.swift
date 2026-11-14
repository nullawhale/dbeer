import CryptoKit
import Foundation

enum SchemaBundleFailure: LocalizedError {
    case invalid, changed, write
    var errorDescription: String? {
        switch self {
        case .invalid: "The schema bundle is invalid or exceeds its limits."
        case .changed: "The destination changed. Choose a new, empty destination and export again."
        case .write: "The schema bundle could not be saved. Choose a writable local directory and retry."
        }
    }
}
struct SchemaBundleFile: Codable, Equatable, Sendable {
    var id: String; var path: String; var bytes: Int64; var sha256: String
    var valid: Bool { bytes >= 0 && bytes <= SchemaBundleManifest.maximumBytes && DataComparisonRequest.digestValid(sha256) }
}
struct SchemaBundleRef: Codable, Equatable, Sendable {
    var rowType: Bool?
    var kind: String; var schema: String; var name: String; var table: String?
    var key: Data { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return (try? encoder.encode(self)) ?? Data() }
    var valid: Bool { [kind, schema, name, table ?? ""].allSatisfy { $0.utf8.count <= 256 && !$0.contains("\0") } && !name.isEmpty && !kind.isEmpty }
}
struct SchemaBundleDependency: Codable, Equatable, Sendable { var ref: SchemaBundleRef; var state: String }
struct SchemaBundleObject: Codable, Equatable, Sendable {
    var ref: SchemaBundleRef; var file: SchemaBundleFile; var state: String; var reasonCodes: [String]; var dependencies: [SchemaBundleDependency]
}
struct SchemaBundleIssue: Codable, Equatable, Sendable {
    var index: Int64; var side: String; var ref: SchemaBundleRef?; var property: String; var code: String; var message: String
    var blocksEquality: Bool; var planning: String
}
struct SchemaBundleSummary: Codable, Equatable, Sendable {
    var formatVersion: Int; var engine: String; var schemas: [String]; var manifest: SchemaBundleFile
    var included: Int; var omitted: Int; var incomplete: Int; var totalBytes: Int64
    var valid: Bool {
        formatVersion == 1 && SchemaBundleManifest.schemasValid(schemas, engine: engine) && manifest.valid && manifest.id == "manifest" && manifest.path == "manifest.json" &&
        manifest.bytes <= SchemaBundleManifest.maximumManifestBytes && included >= 0 && omitted >= 0 && incomplete >= 0 &&
        included <= 10_000 && omitted <= 10_000 - included && incomplete <= 10_000 - included - omitted &&
        totalBytes >= manifest.bytes && totalBytes <= SchemaBundleManifest.maximumBytes
    }
}
struct SchemaBundleManifest: Codable, Equatable, Sendable {
    static let maximumBytes: Int64 = 128 * 1_024 * 1_024
    static let maximumManifestBytes: Int64 = 8 * 1_024 * 1_024
    var formatVersion: Int; var engine: String; var schemas: [String]; var scope: String; var excludedObjectKinds: [String]
    var capture: SchemaBundleFile; var objects: [SchemaBundleObject]; var issues: [SchemaBundleIssue]; var complete: Bool
    static func schemasValid(_ schemas: [String], engine: String) -> Bool {
        ["postgresql", "mysql", "mariadb", "sqlite"].contains(engine) && (1...32).contains(schemas.count) &&
        schemas.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") } &&
        Set(schemas.map { Data($0.utf8) }).count == schemas.count && (engine != "sqlite" || schemas == ["main"])
    }
    static func parse(_ data: Data, summary: SchemaBundleSummary) throws -> Self {
        guard summary.valid, Int64(data.count) == summary.manifest.bytes,
              digest(data) == summary.manifest.sha256 else { throw SchemaBundleFailure.invalid }
        try SchemaBundleJSON.validate(data)
        let raw = try JSONSerialization.jsonObject(with: data)
        try closed(raw, keys: ["formatVersion", "engine", "schemas", "scope", "excludedObjectKinds", "capture", "objects", "issues", "complete"])
        guard let root = raw as? [String: Any], let objectValues = root["objects"] as? [Any], let issueValues = root["issues"] as? [Any] else { throw SchemaBundleFailure.invalid }
        func file(_ value: Any?) throws { guard let value else { throw SchemaBundleFailure.invalid }; try closed(value, keys: ["id", "path", "bytes", "sha256"]) }
        func ref(_ value: Any?) throws {
            guard let value, let fields = value as? [String: Any], Set(fields.keys).isSubset(of: ["rowType", "kind", "schema", "name", "table"]),
                  ["kind", "schema", "name"].allSatisfy({ fields[$0] != nil }), !fields.values.contains(where: { $0 is NSNull }),
                  fields["rowType"] == nil || fields["rowType"] as? Bool == true,
                  fields["table"] == nil || (fields["table"] as? String)?.isEmpty == false else { throw SchemaBundleFailure.invalid }
        }
        try file(root["capture"])
        for object in objectValues {
            try closed(object, keys: ["ref", "file", "state", "reasonCodes", "dependencies"])
            guard let object = object as? [String: Any], let dependencies = object["dependencies"] as? [Any] else { throw SchemaBundleFailure.invalid }
            try file(object["file"]); try ref(object["ref"])
            for dependency in dependencies { try closed(dependency, keys: ["ref", "state"]); try ref((dependency as? [String: Any])?["ref"]) }
        }
        for issue in issueValues {
            guard let fields = issue as? [String: Any] else { throw SchemaBundleFailure.invalid }
            let required: Set<String> = ["index", "side", "property", "code", "message", "blocksEquality", "planning"]
            guard required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: required.union(["ref"])), !fields.values.contains(where: { $0 is NSNull }) else { throw SchemaBundleFailure.invalid }
            if fields["ref"] != nil { try ref(fields["ref"]) }
        }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        try manifest.validate(summary: summary)
        return manifest
    }
    private static func closed(_ raw: Any, keys: Set<String>) throws {
        guard let value = raw as? [String: Any], Set(value.keys) == keys, !value.values.contains(where: { $0 is NSNull }) else { throw SchemaBundleFailure.invalid }
    }
    func validate(summary: SchemaBundleSummary) throws {
        guard formatVersion == 1, summary.valid, engine == summary.engine, schemas.map({ Data($0.utf8) }) == summary.schemas.map({ Data($0.utf8) }),
              Self.schemasValid(schemas, engine: engine), scope == "supportedSchemaDefinitions", objects.count <= 10_000, issues.count <= 100_000,
              excludedObjectKinds.count <= 32, excludedObjectKinds.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              capture.valid, capture.id == "capture", capture.path == "capture.json" else { throw SchemaBundleFailure.invalid }
        var ids: Set<String> = ["capture", "manifest"], paths: Set<String> = ["capture.json", "manifest.json"], refs: Set<Data> = []
        var bytes = capture.bytes + summary.manifest.bytes, included = 0, omitted = 0, incomplete = 0, members = 0
        for object in objects {
            let ref = object.ref, file = object.file
            guard ref.valid, ["schema", "table", "type", "sequence"].contains(ref.kind), ref.rowType != true, ref.table == nil || ref.table == "",
                  (ref.kind == "schema" ? ref.schema.isEmpty && schemas.contains(where: { $0.utf8.elementsEqual(ref.name.utf8) }) : schemas.contains(where: { $0.utf8.elementsEqual(ref.schema.utf8) })),
                  refs.insert(ref.key).inserted, file.valid, DataComparisonRequest.digestValid(file.id), ids.insert(file.id).inserted,
                  file.path.hasPrefix(ref.kind + "-"), file.path.hasSuffix("-" + file.id + ".sql"), file.path.utf8.count <= 100,
                  file.path.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }),
                  paths.insert(file.path.lowercased()).inserted, file.bytes <= 128 * 1_024,
                  ["included", "omitted", "incomplete"].contains(object.state), object.reasonCodes.count <= 32,
                  object.reasonCodes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
                  (object.state == "included" ? object.reasonCodes.isEmpty : !object.reasonCodes.isEmpty),
                  object.dependencies.count <= 100_000 else { throw SchemaBundleFailure.invalid }
            var dependencies: Set<Data> = []
            for dependency in object.dependencies {
                guard dependency.ref.valid, ["builtin", "included", "omitted", "incomplete", "external"].contains(dependency.state),
                      dependencies.insert(dependency.ref.key).inserted else { throw SchemaBundleFailure.invalid }
            }
            members += object.dependencies.count
            guard members <= 100_000, bytes <= Self.maximumBytes - file.bytes else { throw SchemaBundleFailure.invalid }
            bytes += file.bytes
            switch object.state { case "included": included += 1; case "omitted": omitted += 1; default: incomplete += 1 }
        }
        let states = Dictionary(uniqueKeysWithValues: objects.map { ($0.ref.key, $0.state) })
        for object in objects { for dependency in object.dependencies {
            switch dependency.state {
            case "builtin": guard engine == "postgresql" && ["pg_catalog", "information_schema"].contains(dependency.ref.schema) || ["mysql", "mariadb"].contains(engine) && dependency.ref.schema.isEmpty && ["type", "collation"].contains(dependency.ref.kind) || engine == "sqlite" && dependency.ref.schema == "sqlite" && dependency.ref.kind == "type" else { throw SchemaBundleFailure.invalid }
            case "external": guard states[dependency.ref.key] == nil else { throw SchemaBundleFailure.invalid }
            default: guard states[dependency.ref.key] == dependency.state else { throw SchemaBundleFailure.invalid }
            }
            guard object.state != "included" || ["builtin", "included"].contains(dependency.state) else { throw SchemaBundleFailure.invalid }
        } }
        guard included == summary.included, omitted == summary.omitted, incomplete == summary.incomplete, bytes == summary.totalBytes,
              !complete || omitted == 0 && incomplete == 0,
              issues.enumerated().allSatisfy({ item in item.element.index == Int64(item.offset) && item.element.side == "source" && item.element.ref?.valid != false && item.element.code.utf8.count <= 128 && item.element.property.utf8.count <= 4_096 && item.element.message.utf8.count <= 1_048_576 && ["manual", "structured"].contains(item.element.planning) }) else { throw SchemaBundleFailure.invalid }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Reject duplicate (including escaped) keys before Foundation discards them.
struct SchemaBundleJSON {
    let bytes: [UInt8]; var index = 0
    static func validate(_ data: Data) throws {
        guard Int64(data.count) <= SchemaBundleManifest.maximumManifestBytes, String(data: data, encoding: .utf8) != nil else { throw SchemaBundleFailure.invalid }
        var parser = Self(bytes: Array(data)); try parser.value(depth: 0); parser.space()
        guard parser.index == parser.bytes.count else { throw SchemaBundleFailure.invalid }
    }
    mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func take(_ byte: UInt8) throws { space(); guard index < bytes.count, bytes[index] == byte else { throw SchemaBundleFailure.invalid }; index += 1 }
    mutating func string() throws -> Data {
        space(); let start = index; try take(34)
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 { let string = try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])); return Data(string.utf8) }
            guard byte >= 32 else { throw SchemaBundleFailure.invalid }
            if byte == 92 { guard index < bytes.count else { throw SchemaBundleFailure.invalid }; index += 1 }
        }
        throw SchemaBundleFailure.invalid
    }
    mutating func value(depth: Int) throws {
        guard depth <= 64 else { throw SchemaBundleFailure.invalid }; space(); guard index < bytes.count else { throw SchemaBundleFailure.invalid }
        switch bytes[index] {
        case 123:
            index += 1; space(); var keys: Set<Data> = []
            if index < bytes.count && bytes[index] == 125 { index += 1; return }
            while true { let key = try string(); guard keys.insert(key).inserted else { throw SchemaBundleFailure.invalid }; try take(58); try value(depth: depth + 1); space(); guard index < bytes.count else { throw SchemaBundleFailure.invalid }; if bytes[index] == 125 { index += 1; return }; try take(44) }
        case 91:
            index += 1; space(); if index < bytes.count && bytes[index] == 93 { index += 1; return }
            while true { try value(depth: depth + 1); space(); guard index < bytes.count else { throw SchemaBundleFailure.invalid }; if bytes[index] == 93 { index += 1; return }; try take(44) }
        case 34: _ = try string()
        default:
            let start = index; while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw SchemaBundleFailure.invalid }
            let token = Array(bytes[start..<index])
            if ![Array("true".utf8), Array("false".utf8), Array("null".utf8)].contains(token) {
                let digits = token.first == 45 ? Array(token.dropFirst()) : token
                guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }), digits.count == 1 || digits.first != 48 else { throw SchemaBundleFailure.invalid }
            }
        }
    }
}

extension SchemaBundleSummary {
    /// Validate original bytes, including integer spelling and closed payloads.
    static func validateFrame(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String, type.hasPrefix("schema.bundle.") else { return }
        try SchemaBundleJSON.validate(data)
        guard Set(root.keys) == ["type", "requestId", "schemaComparison"],
              let response = root["schemaComparison"] as? [String: Any] else { throw SchemaBundleFailure.invalid }
        let allowed: Set<String> = ["jobId", "state", "code", "message", "bundleSummary", "export"]
        guard Set(response.keys).isSubset(of: allowed), response["jobId"] != nil, response["state"] != nil,
              !response.values.contains(where: { $0 is NSNull }) else { throw SchemaBundleFailure.invalid }
        if let summary = response["bundleSummary"] {
            guard let fields = summary as? [String: Any], Set(fields.keys) == ["formatVersion", "engine", "schemas", "manifest", "included", "omitted", "incomplete", "totalBytes"],
                  !fields.values.contains(where: { $0 is NSNull }), let file = fields["manifest"] as? [String: Any],
                  Set(file.keys) == ["id", "path", "bytes", "sha256"], !file.values.contains(where: { $0 is NSNull }) else { throw SchemaBundleFailure.invalid }
        }
        if let raw = response["export"] {
            guard let chunk = raw as? [String: Any], Set(chunk.keys) == ["valueRef", "sha256", "totalBytes", "offset", "nextOffset", "dataBase64", "hasMore"],
                  !chunk.values.contains(where: { $0 is NSNull }) else { throw SchemaBundleFailure.invalid }
        }
    }
}
