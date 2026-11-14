import Foundation

/// Repeatable mappings contain metadata and parser settings, never file bytes,
/// file locations, connection settings, passwords or imported values.
struct TransferMappingPreset: Codable, Identifiable, Equatable, Sendable {
    struct Column: Codable, Equatable, Sendable {
        var sourceIndex: Int
        var targetName: String?
        var type: String?
        var nullable: Bool?
        var precision: Int?
        var scale: Int?
    }
    struct FileOptions: Codable, Equatable, Sendable {
        var delimiter: String
        var hasHeader: Bool
        var nullMarker: String?
        var emptyFieldsAreNull: Bool

        init(_ options: DelimitedImportOptions) {
            delimiter = options.delimiter.rawValue; hasHeader = options.hasHeader
            nullMarker = options.nullMarker; emptyFieldsAreNull = options.emptyFieldsAreNull
        }
        var options: DelimitedImportOptions? {
            guard let delimiter = DelimitedImportDelimiter(rawValue: delimiter) else { return nil }
            return DelimitedImportOptions(delimiter: delimiter, hasHeader: hasHeader,
                nullMarker: nullMarker, emptyFieldsAreNull: emptyFieldsAreNull)
        }
    }
    var id = UUID()
    var name: String
    var engine: DatabaseEngine
    var purpose: String
    var headers: [String]
    var columns: [Column]
    var fileOptions: FileOptions

    var valid: Bool {
        guard [.postgresql, .mysql, .mariadb, .sqlite].contains(engine), ["append", "create", "table"].contains(purpose),
              Self.nameValid(name), (1...256).contains(headers.count), headers.allSatisfy(Self.fieldValid),
              columns.count == headers.count, Set(columns.map(\.sourceIndex)) == Set(headers.indices),
              columns.allSatisfy(columnValid), fileOptions.options != nil,
              fileOptions.nullMarker.map(Self.fieldValid) ?? true else { return false }
        let names = columns.compactMap(\.targetName)
        return !names.isEmpty && names.allSatisfy(Self.nameValid) && Set(names.map { Data($0.utf8) }).count == names.count
    }
    func matches(headers: [String], engine: DatabaseEngine, purpose: String) -> Bool {
        self.engine == engine && self.purpose == purpose && self.headers.map { Data($0.utf8) } == headers.map { Data($0.utf8) }
    }
    private func columnValid(_ column: Column) -> Bool {
        if purpose == "append" || column.targetName == nil {
            return column.type == nil && column.nullable == nil && column.precision == nil && column.scale == nil
        }
        guard [.postgresql, .mysql, .mariadb].contains(engine), let name = column.targetName,
              let type = column.type, let nullable = column.nullable else { return false }
        let mapped = DataTransferColumn(sourceIndex: column.sourceIndex, name: name, type: type,
            nullable: nullable, precision: column.precision, scale: column.scale)
        return mapped.valid && (!engine.usesMySQLSyntax || type != "decimal" ||
            (column.precision ?? 0) <= 65 && (column.scale ?? 0) <= (engine == .mariadb ? 38 : 30))
    }
    private static func fieldValid(_ value: String) -> Bool { value.utf8.count <= 1_024 && !value.contains("\0") }
    private static func nameValid(_ value: String) -> Bool { fieldValid(value) && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
