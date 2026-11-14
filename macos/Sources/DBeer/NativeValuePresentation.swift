import Foundation

/// Presentation and exact captured representation only; it never grants binding authority.
enum NativeValuePresentation {
    static func canonicalData(_ value: NativeValue, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func text(_ value: NativeValue) -> String? {
        switch value.kind {
        case "null": return nil
        case "text", "integer", "decimal", "boolean", "binary", "native": return value.value
        case "float32":
            return value.value.flatMap { UInt32($0, radix: 16) }.map { String(Float(bitPattern: $0)) }
        case "float64":
            return value.value.flatMap { UInt64($0, radix: 16) }.map { String(Double(bitPattern: $0)) }
        default:
            return (try? canonicalData(value)).map { String(decoding: $0, as: UTF8.self) } ?? "Unavailable native value"
        }
    }

    static func description(_ value: NativeValue) -> String {
        let unresolved = value.typeIdentity?.hasPrefix("unresolved:") == true ? " · Type semantics unavailable (unresolved)" : ""
        let result: String
        switch value.kind {
        case "null": result = value.engine == "mongodb" ? "BSON null" : "SQL NULL"
        case "text": result = value.value?.isEmpty == true ? "Empty string" : "Text"
        case "integer": result = "Exact integer"
        case "decimal": result = "Exact decimal"
        case "boolean": result = "Boolean"
        case "binary": result = (value.value?.isEmpty == true ? "Empty binary" : "Binary") + " · Base64"
        case "float32": result = "IEEE-754 binary32 · bits 0x" + (value.value ?? "")
        case "float64": result = "IEEE-754 binary64 · bits 0x" + (value.value ?? "")
        case "list": result = "Native list · ordered elements"
        case "tuple": result = "Native tuple · ordered elements"
        case "set": result = "Native set · captured order"
        case "map": result = "Native map · captured entry order"
        case "object": result = "Native object · ordered entries and duplicate keys"
        case "native": result = "Native wire text · " + (value.nativeType ?? "") + " · Textual wire representation"
        case "opaque": result = "Opaque " + (value.nativeType ?? "native") + " bytes · Base64 · Semantics unavailable"
        default: result = "Unavailable native value"
        }
        return result + unresolved
    }

    static func exactNumber(_ value: NativeValue) -> String? {
        guard value.typeIdentity?.hasPrefix("unresolved:") != true,
              value.kind == "integer" || value.kind == "decimal" else { return nil }
        return value.value
    }
}
