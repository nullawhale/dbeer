import Foundation

/// Native code retains the captured source scalar. Actual target typing and
/// all lossless conversions belong to the helper's database adapters.
enum LogicalRelationshipNavigation {
    static func filters(_ relationship: LogicalRelationship, sourceColumns: [ResultColumn], sourceDeclarations: [String], sourceTypeOIDs: [UInt32] = [], sourceBaseTypeOIDs: [UInt32] = [], values: [ChangeValue]) throws -> [CatalogFilter] {
        guard relationship.isValid else { throw LogicalRelationshipError.invalid }
        var result: [CatalogFilter] = []
        var bytes = 0
        for pair in relationship.columns {
            let indices = sourceColumns.indices.filter { Data(sourceColumns[$0].name.utf8) == Data(pair.source.utf8) }
            guard indices.count == 1, let index = indices.first, values.indices.contains(index),
                  sourceColumns[index].engine == relationship.source.engine else {
                throw LogicalRelationshipError.metadata("The source row does not contain one unambiguous value for every local relationship column. Reload it before navigating.")
            }
            guard sourceDeclarations.indices.contains(index), Data(sourceDeclarations[index].utf8) == Data(pair.sourceType.utf8),
                  representationMatches(sourceColumns[index], declaration: sourceDeclarations[index], declaredOID: sourceTypeOIDs.indices.contains(index) ? sourceTypeOIDs[index] : 0, baseOID: sourceBaseTypeOIDs.indices.contains(index) ? sourceBaseTypeOIDs[index] : 0) else {
                throw LogicalRelationshipError.metadata("A mapped source declaration or captured value type changed. Reload the source row before navigating; captured values cannot be relabelled with a newly validated type.")
            }
            guard sourceColumns[index].typeIdentity?.hasPrefix("unresolved:") != true else {
                throw LogicalRelationshipError.metadata("A mapped source value has no lossless native representation for its current type, character set or session time zone. Open a source with verified native values before navigating.")
            }
            var value = values[index]
            if value.kind == "nativeText" {
                guard [.postgresql, .mysql, .mariadb].contains(sourceColumns[index].engine) else { throw LogicalRelationshipError.invalid }
                value = .init(kind: "text", value: value.value)
            }
            guard value.kind != "null", value.kind != "default" else {
                throw LogicalRelationshipError.metadata("A NULL or DEFAULT key component does not identify related stored rows. No target read was started.")
            }
            let operand = NativeCellFilterValue(cell: value, sourceEngine: relationship.source.engine, sourceType: pair.sourceType,
                sqliteStorage: relationship.target.engine == .sqlite ? pair.sqliteStorage : "preserve")
            guard operand.isValid else { throw LogicalRelationshipError.metadata("A key component has an invalid or unsupported captured representation.") }
            bytes += operand.encodedByteCount
            guard bytes <= 4 * 1_024 * 1_024 else { throw LogicalRelationshipError.metadata("The composite key exceeds the typed relationship operand limit.") }
            result.append(.init(column: pair.target, operator: "eq", nativeValue: operand))
        }
        return result
    }
    private static func representationMatches(_ column: ResultColumn, declaration: String, declaredOID: UInt32, baseOID: UInt32) -> Bool {
        func numeric(_ type: String, engine: DatabaseEngine) -> String? {
            var value = type.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("pg_catalog.") { value.removeFirst("pg_catalog.".count) }
            if let suffix = value.firstIndex(of: "(") { value = String(value[..<suffix]).trimmingCharacters(in: .whitespaces) }
            value = value.replacingOccurrences(of: " unsigned", with: "").replacingOccurrences(of: " zerofill", with: "")
            if ["smallint", "integer", "bigint", "int2", "int4", "int8", "numeric", "decimal", "tinyint", "mediumint", "int"].contains(value) { return "exact" }
            if engine == .postgresql, ["real", "float4"].contains(value) { return "float32" }
            if engine == .postgresql, ["double precision", "float8"].contains(value) { return "float64" }
            if engine.usesMySQLSyntax, value == "float" { return "float32" }
            if engine.usesMySQLSyntax, value == "double" { return "float64" }
            return nil
        }
        if column.engine == .sqlite { return true }
        let declared = numeric(declaration, engine: column.engine), captured = numeric(column.nativeType, engine: column.engine)
        if column.engine == .postgresql {
            if declaredOID != 0, column.typeOid != declaredOID, column.typeOid != baseOID { return false }
            func builtinOID(_ type: String) -> UInt32? {
                var name = type.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if name.hasPrefix("pg_catalog.") { name.removeFirst("pg_catalog.".count) }
                if let begin = name.firstIndex(of: "("), let end = name[begin...].firstIndex(of: ")") { name.removeSubrange(begin...end) }
                name = name.trimmingCharacters(in: .whitespaces)
                let names: [String: UInt32] = ["bool": 16, "boolean": 16, "bytea": 17, "int8": 20, "bigint": 20,
                    "int2": 21, "smallint": 21, "int4": 23, "integer": 23, "int": 23, "text": 25, "oid": 26,
                    "json": 114, "xml": 142, "float4": 700, "real": 700, "float8": 701, "double precision": 701,
                    "bpchar": 1042, "character": 1042, "char": 1042, "varchar": 1043, "character varying": 1043,
                    "date": 1082, "time": 1083, "time without time zone": 1083, "timestamp": 1114, "timestamp without time zone": 1114,
                    "timestamptz": 1184, "timestamp with time zone": 1184, "interval": 1186, "timetz": 1266, "time with time zone": 1266,
                    "numeric": 1700, "decimal": 1700, "uuid": 2950, "jsonb": 3802]
                return names[name]
            }
            if let expected = builtinOID(declaration) { return column.typeOid == expected && builtinOID(column.nativeType) == expected }
            // Arrays/custom types have different catalog and wire spellings.
            // Bind their captured declaration's actual OID/base OID first;
            // a resolved display identity alone cannot prove that association.
            guard declaredOID != 0, column.typeOid == declaredOID || baseOID != 0 && column.typeOid == baseOID,
                  let identity = column.typeIdentity, identity.hasPrefix("pgtype-v1:") else { return false }
            let digest = identity.dropFirst("pgtype-v1:".count)
            return digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        if declaration.lowercased().hasPrefix("timestamp") {
            return ["CHAR", "VARCHAR"].contains(column.nativeType.uppercased())
        }
        // The table reader projects FLOAT as a lossless DOUBLE. Its immutable
        // declaration still determines the original binary32 representation.
        return declared == captured || declared == "float32" && captured == "float64" && column.typeIdentity?.hasPrefix("unresolved:") != true
    }

}
