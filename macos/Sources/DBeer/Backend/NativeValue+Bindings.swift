import Foundation

extension NativeValue {
    /// Only captured primitives accepted by the existing flat binding contract cross this boundary.
    private var primitiveChangeValue: ChangeValue? {
        guard valid, typeIdentity?.hasPrefix("unresolved:") != true else { return nil }
        switch kind {
        case "null": return .null
        case "text", "integer", "decimal", "boolean": return .init(kind: "text", value: value)
        case "binary": return .init(kind: "binary", value: value)
        default: return nil
        }
    }
    func flatChangeValue(for column: ResultColumn) -> ChangeValue? {
        guard matches(column), column.typeIdentity?.hasPrefix("unresolved:") != true else { return nil }
        if let primitive = primitiveChangeValue { return primitive }
        if let floating = finiteFloat(for: column) { return floating }
        if let scalar = resolvedNativeScalar(for: column) { return scalar }
        // The helper's resolved identity proves recursively stable PostgreSQL output.
        guard kind == "native", column.engine == .postgresql, column.typeOid != 0,
              let identity = typeIdentity, identity.hasPrefix("pgtype-v1:"),
              identity.dropFirst("pgtype-v1:".count).utf8.count == 64,
              identity.dropFirst("pgtype-v1:".count).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return .init(kind: "text", value: value)
    }

    /// ENUM/SET originals also require the helper's exact ordinal/mask witness.
    func mariaDBStoredChoiceOriginal(for column: ResultColumn, storageToken: String?) -> ChangeValue? {
        let prefix = "mariadb.storage.v1:"
        guard valid, column.engine == .mariadb, engine == "mariadb", nativeType == column.nativeType, matches(column),
              let storageToken, storageToken.hasPrefix(prefix), storageToken.utf8.count == prefix.utf8.count + 64,
              storageToken.dropFirst(prefix.count).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let identity = typeIdentity, identity.hasPrefix("unresolved:"),
              let facts = String(identity.dropFirst("unresolved:".count)).data(using: .utf8)
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              facts["engine"] as? String == "mariadb", let code = facts["type"] as? Int,
              let flags = facts["flags"] as? Int,
              column.nativeType == "ENUM" && (code == 247 || code == 254 && flags & 256 != 0) ||
                column.nativeType == "SET" && (code == 248 || code == 254 && flags & 2_048 != 0) else { return nil }
        switch kind {
        case "null": return .null
        case "native" where column.encoding != "base64": return .init(kind: "text", value: value)
        case "binary" where column.encoding == "base64": return .init(kind: "binary", value: value)
        default: return nil
        }
    }

    private func resolvedNativeScalar(for column: ResultColumn) -> ChangeValue? {
        guard kind == "native", engine == column.engine.rawValue, nativeType == column.nativeType,
              let identity = typeIdentity, !identity.isEmpty, identity == column.typeIdentity,
              !identity.hasPrefix("unresolved:"),
              let facts = identity.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return nil }
        switch column.engine {
        case .cassandra:
            guard ["uuid", "timeuuid", "inet", "date", "time"].contains(column.nativeType),
                  let type = facts["type"] as? [String: Any], type["kind"] as? String == "builtin",
                  let reference = type["ref"] as? [String: Any], reference["name"] as? String == column.nativeType,
                  reference["kind"] as? String == "type", reference["schema"] as? String == "" else { return nil }
        case .mysql, .mariadb:
            let codes = ["DATE": 10, "TIME": 11, "DATETIME": 12, "JSON": 245, "DOUBLE": 5, "DOUBLE UNSIGNED": 5]
            guard let code = codes[column.nativeType], facts["engine"] as? String == column.engine.rawValue, facts["type"] as? Int == code else { return nil }
            if column.nativeType == "DOUBLE" || column.nativeType == "DOUBLE UNSIGNED" {
                guard facts["decimals"] as? Int == 31, let value, Double(value)?.isFinite == true else { return nil }
            }
        default: return nil
        }
        // These existing adapter binders accept the captured native scalar directly.
        return .init(kind: "text", value: value)
    }

    private func finiteFloat(for column: ResultColumn) -> ChangeValue? {
        guard ["float32", "float64"].contains(kind), let value, let identity = typeIdentity, !identity.isEmpty else { return nil }
        let width = kind == "float32" ? 32 : 64
        let proven: Bool
        switch column.engine {
        case .postgresql:
            proven = column.typeOid == (width == 32 ? 700 : 701) && identity.hasPrefix("pgtype-v1:") &&
                identity.dropFirst("pgtype-v1:".count).utf8.count == 64 &&
                identity.dropFirst("pgtype-v1:".count).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        case .mysql, .mariadb:
            let facts = identity.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            proven = width == 64 && column.nativeType.uppercased().hasPrefix("DOUBLE") && facts?["engine"] as? String == column.engine.rawValue &&
                facts?["type"] as? Int == 5 && facts?["decimals"] as? Int == 31
        case .cassandra:
            proven = column.nativeType == (width == 32 ? "float" : "double")
        default: proven = false
        }
        guard proven else { return nil }
        if width == 32, let bits = UInt32(value, radix: 16) {
            let number = Float(bitPattern: bits)
            return number.isFinite ? .init(kind: "text", value: String(number)) : nil
        }
        if width == 64, let bits = UInt64(value, radix: 16) {
            let number = Double(bitPattern: bits)
            return number.isFinite ? .init(kind: "text", value: String(number)) : nil
        }
        return nil
    }

    private func matches(_ column: ResultColumn) -> Bool {
        valid && (engine == nil || engine == column.engine.rawValue) &&
            (nativeType == nil || nativeType.map({ Data($0.utf8) == Data(column.nativeType.utf8) }) == true) &&
            (typeIdentity == nil || typeIdentity.map({ Data($0.utf8) }) == column.typeIdentity.map({ Data($0.utf8) }))
    }

    /// Native textual wire data is admitted only by the existing declaration/OID-backed navigation path.
    func navigationChangeValue(for column: ResultColumn) -> ChangeValue? {
        guard valid, [.postgresql, .mysql, .mariadb].contains(column.engine), engine == column.engine.rawValue,
              typeIdentity?.hasPrefix("unresolved:") != true,
              nativeType.map({ Data($0.utf8) == Data(column.nativeType.utf8) }) == true,
              typeIdentity.map({ Data($0.utf8) }) == column.typeIdentity.map({ Data($0.utf8) }) else { return nil }
        if kind == "native" { return .init(kind: "nativeText", value: value) }
        return nil
    }

}
