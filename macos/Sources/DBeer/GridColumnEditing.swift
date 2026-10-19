import Foundation

/// Presentation choices only. The adapter remains responsible for validating
/// database values and constraints before previewing or applying changes.
struct GridColumnEditing {
    let nativeType: String
    let isEditable: Bool
    let allowsNull: Bool
    let allowsDefault: Bool
    let allowsEmptyString: Bool
    let isBinary: Bool
    private let prefersMultiline: Bool

    init(column: ResultColumn, metadata: [String: String]) {
        nativeType = metadata["nativeType"] ?? column.nativeType
        isEditable = metadata["editable"] == "true"
        allowsNull = isEditable && metadata["nullable"] != "false"
        allowsDefault = isEditable
        isBinary = column.encoding == "base64"

        // Catalog types can include sizes (varchar(255)) or modifiers. OIDs
        // identify PostgreSQL's built-in text types even when their names vary.
        let type = nativeType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let base = String(type.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces)
        let stringTypes: Set<String> = ["char", "character", "bpchar", "name", "varchar", "character varying",
            "text", "tinytext", "mediumtext", "longtext"]
        let postgresText = column.engine == .postgresql && [18, 19, 25, 1042, 1043].contains(column.typeOid)
        allowsEmptyString = isEditable && !isBinary && (postgresText || stringTypes.contains(base))
        prefersMultiline = isBinary || ["text", "tinytext", "mediumtext", "longtext", "json", "jsonb", "xml"].contains(base)
    }

    func usesMultilineEditor(for value: ChangeValue) -> Bool {
        prefersMultiline || (value.value?.count ?? 0) > 160 || value.value?.contains(where: \.isNewline) == true
    }
}
