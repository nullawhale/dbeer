import Foundation

enum StructureDraftFileError: LocalizedError {
    case invalidDocument, incompatibleTarget, changedDraft

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            "The structure draft is invalid, unsupported or exceeds its size limits."
        case .incompatibleTarget:
            "Open this draft from the same database engine, schema and table. Create-table drafts require a matching create-table editor."
        case .changedDraft:
            "The structure draft changed while the file dialog was open. Review the current draft and save again."
        }
    }
}

/// Portable intent deliberately excludes server baselines, execution plans and grants.
struct StructureDraftDocument: Codable, Equatable, Sendable {
    static let maximumBytes = 1_048_576
    static let currentFormatVersion = 1
    let formatVersion: Int
    let engine: DatabaseEngine
    let target: StructureTarget
    let draft: StructureDraft

    init(engine: DatabaseEngine, target: StructureTarget, draft: StructureDraft) {
        formatVersion = Self.currentFormatVersion
        self.engine = engine
        self.target = .init(schema: target.schema, table: target.table, create: target.create)
        var retained = draft
        retained.allowDestructive = nil
        self.draft = retained
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, engine, target, draft }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: DraftFileCodingKey.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(["formatVersion", "engine", "target", "draft"]) else {
            throw StructureDraftFileError.invalidDocument
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .formatVersion)
        guard version == Self.currentFormatVersion else {
            throw StructureDraftFileError.invalidDocument
        }
        let target = try values.decode(StructureTarget.self, forKey: .target)
        guard target.reconcile == nil else { throw StructureDraftFileError.invalidDocument }
        let draft = try values.decode(StructureDraft.self, forKey: .draft)
        guard !draft.requiresAuthoringV2 && draft.authoringVersion == nil else { throw StructureDraftFileError.invalidDocument }
        self.init(engine: try values.decode(DatabaseEngine.self, forKey: .engine), target: target, draft: draft)
        guard valid else { throw StructureDraftFileError.invalidDocument }
    }

    var valid: Bool {
        guard [.postgresql, .mysql, .sqlite].contains(engine),
              StructureTarget.identifier(target.schema),
              StructureTarget.identifier(target.table) || target.create && target.table.isEmpty,
              draft.columns.count <= 128,
              draft.authoringVersion == nil,
              !draft.requiresAuthoringV2,
              draft.renameTable == nil,
              (draft.changes?.count ?? 0) + (draft.indexes?.count ?? 0) + (draft.keys?.count ?? 0) <= 64 else { return false }
        // Incomplete editor fields remain saveable, while imported collections and text stay bounded.
        return draft.columns.allSatisfy { column in
            Self.name(column.name) && Self.type(column.type) && Self.defaultValue(column.default) && Self.generation(column.generated) && Self.identity(column.identity)
        } && (draft.changes ?? []).allSatisfy { change in
            Self.name(change.name) && (change.type.map(Self.type) ?? true) &&
                (change.default.map(Self.defaultValue) ?? true) && (change.renameTo.map(Self.name) ?? true) && Self.generation(change.generated) && Self.identity(change.identity)
        } && (draft.indexes ?? []).allSatisfy { index in
            ["add", "drop", "replace"].contains(index.action) && Self.name(index.name) &&
                Self.names(index.columns ?? [])
        } && (draft.keys ?? []).allSatisfy { key in
            ["add", "drop", "replace"].contains(key.action) &&
                ["primary", "unique", "foreign"].contains(key.kind) && Self.name(key.name) &&
                Self.names(key.columns ?? []) && Self.names(key.referenceColumns ?? []) &&
                (key.reference.map { Self.name($0.schema) && Self.name($0.table) && !$0.create && $0.reconcile != true } ?? true) &&
                (key.onUpdate.map { $0.isEmpty || StructureKeyEdit.actions.contains($0) } ?? true) &&
                (key.onDelete.map { $0.isEmpty || StructureKeyEdit.actions.contains($0) } ?? true)
        }
    }

    private static func name(_ value: String) -> Bool { value.utf8.count <= 63 && !value.contains("\0") }
    private static func names(_ values: [String]) -> Bool { values.count <= 32 && values.allSatisfy(name) }
    private static func type(_ value: StructureDataType) -> Bool {
        ["integer", "bigint", "boolean", "text", "real", "blob", "any", "sqliteNumeric", "varchar", "numeric"].contains(value.kind) &&
            (value.reference.map { name($0.schema) && name($0.name) } ?? true) &&
            [value.length, value.precision, value.scale].allSatisfy { $0.map { (-1_000_000...1_000_000).contains($0) } ?? true }
    }
    private static func defaultValue(_ value: StructureDefault) -> Bool {
        ["none", "null", "text", "numeric", "boolean"].contains(value.kind) &&
            (value.value.map { $0.utf8.count <= 4096 && !$0.contains("\0") } ?? true)
    }

    private static func generation(_ value: StructureGeneration?) -> Bool {
        guard let value else { return true }
        return ["none", "stored", "virtual"].contains(value.storage) && (value.expression.map { $0.utf8.count <= 4096 && !$0.contains("\0") } ?? true)
    }
    private static func identity(_ value: StructureIdentity?) -> Bool {
        guard let value else { return true }
        return ["none", "always", "byDefault", "autoIncrement"].contains(value.kind) &&
            [value.start, value.increment, value.minimum, value.maximum, value.cache].allSatisfy { $0.map { $0.utf8.count <= 64 && !$0.contains("\0") } ?? true }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.formatVersion == rhs.formatVersion && lhs.engine == rhs.engine && lhs.target == rhs.target && lhs.draft == rhs.draft
    }
}

private struct DraftFileCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct LoadedStructureDraft: Sendable {
    let document: StructureDraftDocument
    let version: SQLFileVersion
}

enum StructureDraftStore {
    static func text(_ document: StructureDraftDocument) throws -> String {
        guard document.valid else { throw StructureDraftFileError.invalidDocument }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count < StructureDraftDocument.maximumBytes else { throw StructureDraftFileError.invalidDocument }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func read(_ url: URL) throws -> LoadedStructureDraft {
        let file = try SQLFileBinding.read(url, maximumBytes: StructureDraftDocument.maximumBytes)
        let document = try JSONDecoder().decode(StructureDraftDocument.self, from: Data(file.text.utf8))
        return .init(document: document, version: file.version)
    }

    static func destinationVersion(_ url: URL, maximumBytes: Int = 2_097_152) throws -> SQLFileVersion? {
        if !FileManager.default.fileExists(atPath: url.path) { return nil }
        return try SQLFileBinding.read(url, maximumBytes: maximumBytes).version
    }

    static func write(_ document: StructureDraftDocument, to url: URL, expectedVersion: SQLFileVersion?) throws -> SQLFileVersion {
        try SQLFileBinding.write(text(document), to: url, expectedVersion: expectedVersion).version
    }

    static func sql(_ plan: StructurePlan) throws -> String {
        guard plan.valid else { throw StructureDraftFileError.invalidDocument }
        let target = (plan.target.schema + "." + plan.target.table).components(separatedBy: .newlines).map { "-- " + $0 }
        let warnings = plan.risks.flatMap { $0.components(separatedBy: .newlines) }.map { "-- Warning: " + $0 }
        let header = ["-- DBeer reviewed structure SQL"] + target + [
                      "-- Captured plan. Review the current target before executing.",
                      "-- Steps can commit independently on engines with implicit DDL commits."] + warnings
        let steps = plan.sql.enumerated().map { index, sql in "-- Step \(index + 1)\n" + sql }
        return header.joined(separator: "\n") + "\n\n" + steps.joined(separator: "\n\n") + "\n"
    }
}
