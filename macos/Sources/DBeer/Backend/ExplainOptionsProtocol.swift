import Foundation

enum ExplainSerialize: String, Codable, CaseIterable, Sendable { case none, text, binary }
enum MySQLExplainFormat: String, Codable, CaseIterable, Sendable { case auto, tree, json }
struct PostgresExplainOptions: Codable, Sendable, Equatable {
    var buffers: Bool? = nil
    var wal: Bool? = nil
    var settings: Bool? = nil
    var memory: Bool? = nil
    var serialize: ExplainSerialize? = nil
    var timing: Bool? = nil
    private enum CodingKeys: String, CodingKey { case buffers, wal, settings, memory, serialize, timing }
    var keys: Set<String> {
        var keys = Set<String>()
        if buffers != nil { keys.insert("buffers") }; if wal != nil { keys.insert("wal") }
        if settings != nil { keys.insert("settings") }; if memory != nil { keys.insert("memory") }
        if serialize != nil { keys.insert("serialize") }; if timing != nil { keys.insert("timing") }
        return keys
    }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: [], optional: ["buffers", "wal", "settings", "memory", "serialize", "timing"])
        let v = try decoder.container(keyedBy: CodingKeys.self)
        buffers = v.contains(.buffers) ? try v.decode(Bool.self, forKey: .buffers) : nil
        wal = v.contains(.wal) ? try v.decode(Bool.self, forKey: .wal) : nil
        settings = v.contains(.settings) ? try v.decode(Bool.self, forKey: .settings) : nil
        memory = v.contains(.memory) ? try v.decode(Bool.self, forKey: .memory) : nil
        serialize = v.contains(.serialize) ? try v.decode(ExplainSerialize.self, forKey: .serialize) : nil
        timing = v.contains(.timing) ? try v.decode(Bool.self, forKey: .timing) : nil
    }
    init(buffers: Bool? = nil, wal: Bool? = nil, settings: Bool? = nil, memory: Bool? = nil, serialize: ExplainSerialize? = nil, timing: Bool? = nil) {
        self.buffers = buffers; self.wal = wal; self.settings = settings; self.memory = memory; self.serialize = serialize; self.timing = timing
    }
}
struct MySQLExplainOptions: Codable, Sendable, Equatable {
    var format: MySQLExplainFormat
    init(format: MySQLExplainFormat) { self.format = format }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["format"])
        format = try decoder.container(keyedBy: CodingKeys.self).decode(MySQLExplainFormat.self, forKey: .format)
    }
    private enum CodingKeys: String, CodingKey { case format }
}
struct ExplainOptions: Codable, Sendable, Equatable {
    var postgresql: PostgresExplainOptions? = nil
    var mysql: MySQLExplainOptions? = nil
    var valid: Bool { (postgresql != nil) != (mysql != nil) }
    func valid(engine: DatabaseEngine) -> Bool { valid && (engine == .postgresql ? postgresql != nil : engine == .mysql && mysql != nil) }
    init(postgresql: PostgresExplainOptions? = nil, mysql: MySQLExplainOptions? = nil) { self.postgresql = postgresql; self.mysql = mysql }
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: [], optional: ["postgresql", "mysql"])
        let v = try decoder.container(keyedBy: CodingKeys.self)
        postgresql = v.contains(.postgresql) ? try v.decode(PostgresExplainOptions.self, forKey: .postgresql) : nil
        mysql = v.contains(.mysql) ? try v.decode(MySQLExplainOptions.self, forKey: .mysql) : nil
        guard valid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Explain options require exactly one engine.")) }
    }
    private enum CodingKeys: String, CodingKey { case postgresql, mysql }
}
struct PostgresExplainOptionSupport: Codable, Sendable, Equatable {
    var plan: [String]
    var analyze: [String]
}
struct MySQLExplainOptionSupport: Codable, Sendable, Equatable {
    var plan: [String]
    var analyze: [String]
    var jsonAnalyzeRequiresVersion2: Bool
}
struct ExplainOptionSupport: Codable, Sendable, Equatable {
    var postgresql: PostgresExplainOptionSupport? = nil
    var mysql: MySQLExplainOptionSupport? = nil
    func valid(engine: DatabaseEngine) -> Bool {
        func validKeys(_ keys: [String], _ allowed: Set<String>) -> Bool { Set(keys).count == keys.count && Set(keys).isSubset(of: allowed) }
        if engine == .postgresql, let pg = postgresql, mysql == nil {
            return validKeys(pg.plan, ["buffers", "settings", "memory"]) && validKeys(pg.analyze, ["buffers", "wal", "settings", "memory", "serialize", "timing"])
        }
        if engine == .mysql, let my = mysql, postgresql == nil {
            return validKeys(my.plan, ["tree", "json"]) && validKeys(my.analyze, ["tree", "json"]) && my.analyze.contains("json") == my.jsonAnalyzeRequiresVersion2
        }
        return false
    }
    func accepts(options: ExplainOptions, mode: ExplainMode, engine: DatabaseEngine) -> Bool {
        guard valid(engine: engine), options.valid(engine: engine) else { return false }
        if let pg = options.postgresql, let support = postgresql { return pg.keys.isSubset(of: Set(mode == .plan ? support.plan : support.analyze)) }
        if let my = options.mysql, let support = mysql {
            let formats = mode == .plan ? support.plan : support.analyze
            return !formats.isEmpty && (my.format == .auto || formats.contains(my.format.rawValue))
        }
        return false
    }
}

func validExplainSelection(support: ExplainSupport, options: ExplainOptions?, mode: ExplainMode, format: String?, status: String? = nil) -> Bool {
    if let format {
        guard support.engine == .mysql ? (["tree", "json"].contains(format) || status != nil && ["jsonV1", "jsonV2"].contains(format)) : [.postgresql, .mariadb].contains(support.engine) && format == "json" else { return false }
    }
    if let options {
        guard support.options?.accepts(options: options, mode: mode, engine: support.engine) == true, let format else { return false }
        if let my = options.mysql {
            let selected = my.format == .auto ? support.format : my.format.rawValue
            guard selected == "tree" ? format == "tree" : ["json", "jsonV1", "jsonV2"].contains(format) else { return false }
        }
    }
    if support.engine == .mysql {
        if status == "tree" && format == "json" || mode == .analyze && format == "jsonV1" { return false }
        if format == "jsonV2" && mode == .analyze && support.options?.mysql?.analyze.contains("json") != true { return false }
    }
    return true
}

extension PostgresExplainOptionSupport {
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["plan", "analyze"])
        let v = try decoder.container(keyedBy: CodingKeys.self)
        plan = try v.decode([String].self, forKey: .plan)
        analyze = try v.decode([String].self, forKey: .analyze)
    }
    private enum CodingKeys: String, CodingKey { case plan, analyze }
}
extension MySQLExplainOptionSupport {
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: ["plan", "analyze", "jsonAnalyzeRequiresVersion2"])
        let v = try decoder.container(keyedBy: CodingKeys.self)
        plan = try v.decode([String].self, forKey: .plan)
        analyze = try v.decode([String].self, forKey: .analyze)
        jsonAnalyzeRequiresVersion2 = try v.decode(Bool.self, forKey: .jsonAnalyzeRequiresVersion2)
    }
    private enum CodingKeys: String, CodingKey { case plan, analyze, jsonAnalyzeRequiresVersion2 }
}
extension ExplainOptionSupport {
    init(from decoder: Decoder) throws {
        try requireExplainKeys(decoder, required: [], optional: ["postgresql", "mysql"])
        let v = try decoder.container(keyedBy: CodingKeys.self)
        postgresql = v.contains(.postgresql) ? try v.decode(PostgresExplainOptionSupport.self, forKey: .postgresql) : nil
        mysql = v.contains(.mysql) ? try v.decode(MySQLExplainOptionSupport.self, forKey: .mysql) : nil
        guard (postgresql != nil) != (mysql != nil) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Explain option support requires exactly one engine.")) }
    }
    private enum CodingKeys: String, CodingKey { case postgresql, mysql }
}
