import Foundation

enum QueryParameterType: String, CaseIterable, Codable, Hashable, Sendable {
    case text, integer, decimal, boolean, date, timestamp

    var label: String {
        switch self {
        case .text: "Text"
        case .integer: "Integer"
        case .decimal: "Decimal"
        case .boolean: "Boolean"
        case .date: "Date"
        case .timestamp: "Timestamp"
        }
    }

    var placeholder: String {
        switch self {
        case .text: "Text, including an empty string"
        case .integer: "Signed 64-bit integer"
        case .decimal: "Exact decimal, for example 123.45"
        case .boolean: "true or false"
        case .date: "YYYY-MM-DD"
        case .timestamp: "YYYY-MM-DD HH:mm:ss[.ffffff]"
        }
    }

    func accepts(_ value: String) -> Bool {
        switch self {
        case .text: return true
        case .integer:
            return value.range(of: #"\A[+-]?[0-9]+\z"#, options: .regularExpression) != nil && Int64(value) != nil
        case .decimal:
            return value.range(of: #"\A[+-]?[0-9]+(?:\.[0-9]+)?\z"#, options: .regularExpression) != nil
        case .boolean: return value == "true" || value == "false"
        case .date: return validQueryParameterDate(value)
        case .timestamp:
            let bytes = Array(value.utf8)
            guard bytes.count >= 19, bytes.count <= 26, bytes[10] == 32,
                  validQueryParameterDate(String(decoding: bytes.prefix(10), as: UTF8.self)),
                  bytes[13] == 58, bytes[16] == 58,
                  let hour = queryParameterNumber(bytes[11..<13]), hour <= 23,
                  let minute = queryParameterNumber(bytes[14..<16]), minute <= 59,
                  let second = queryParameterNumber(bytes[17..<19]), second <= 59 else { return false }
            return bytes.count == 19 || (bytes.count >= 21 && bytes[19] == 46 &&
                bytes[20...].allSatisfy { (48...57).contains($0) })
        }
    }
}

/// Definitions are safe local metadata. Values belong only to an execution request.
struct SQLParameterDefinition: Equatable, Sendable, Codable {
    static let maximumCount = 128
    var name: String
    var type: QueryParameterType

    init(name: String, type: QueryParameterType) { self.name = name; self.type = type }

    var isValid: Bool {
        !name.isEmpty && name.utf8.count <= 64 &&
            name.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*\z"#, options: .regularExpression) != nil
    }

    static func validate(_ definitions: [SQLParameterDefinition]) throws {
        guard definitions.count <= maximumCount, definitions.allSatisfy(\.isValid),
              Set(definitions.map(\.name)).count == definitions.count else {
            throw QueryParameterError.invalidDefinitions
        }
    }

    private enum CodingKeys: String, CodingKey { case name, type }

    init(from decoder: Decoder) throws {
        try requireQueryParameterKeys(decoder, exactly: ["name", "type"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        type = try values.decode(QueryParameterType.self, forKey: .type)
        guard isValid else { throw QueryParameterError.invalidDefinitions }
    }
}

struct QueryParameterBinding: Equatable, Sendable, Codable {
    var name: String
    var type: QueryParameterType
    var value: String?

    init(name: String, type: QueryParameterType, value: String?) {
        self.name = name; self.type = type; self.value = value
    }

    static func validate(_ bindings: [QueryParameterBinding]) throws {
        _ = try SQLParameterInput.validate(bindings.map {
            SQLParameterInput(definition: SQLParameterDefinition(name: $0.name, type: $0.type),
                value: $0.value ?? "", isNull: $0.value == nil)
        })
    }

    private enum CodingKeys: String, CodingKey { case name, type, value }

    init(from decoder: Decoder) throws {
        try requireQueryParameterKeys(decoder, exactly: ["name", "type", "value"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        type = try values.decode(QueryParameterType.self, forKey: .type)
        value = try values.decodeIfPresent(String.self, forKey: .value)
        _ = try SQLParameterInput(definition: SQLParameterDefinition(name: name, type: type),
            value: value ?? "", isNull: value == nil).validate()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(type, forKey: .type)
        if let value { try values.encode(value, forKey: .value) }
        else { try values.encodeNil(forKey: .value) }
    }
}

/// Ephemeral form state; intentionally not Codable and never stored in a workspace.
struct SQLParameterInput: Equatable, Sendable {
    static let maximumValueBytes = 1_048_576
    var definition: SQLParameterDefinition
    var value: String
    var isNull: Bool

    init(definition: SQLParameterDefinition, value: String = "", isNull: Bool = false) {
        self.definition = definition; self.value = value; self.isNull = isNull
    }

    func validate() throws -> QueryParameterBinding {
        guard definition.isValid else { throw QueryParameterError.invalidDefinitions }
        if !isNull {
            guard value.utf8.count <= Self.maximumValueBytes else { throw QueryParameterError.valuesTooLarge }
            guard !value.utf8.contains(0) else { throw QueryParameterError.invalidText }
            guard definition.type.accepts(value) else { throw QueryParameterError.invalidValue(definition.type) }
        }
        return QueryParameterBinding(name: definition.name, type: definition.type, value: isNull ? nil : value)
    }

    static func validate(_ inputs: [SQLParameterInput]) throws -> [QueryParameterBinding] {
        try SQLParameterDefinition.validate(inputs.map(\.definition))
        var totalBytes = 0
        return try inputs.map { input in
            let binding = try input.validate()
            totalBytes += binding.value?.utf8.count ?? 0
            guard totalBytes <= maximumValueBytes else { throw QueryParameterError.valuesTooLarge }
            return binding
        }
    }
}

enum QueryParameterError: LocalizedError {
    case invalidDefinitions, invalidValue(QueryParameterType), valuesTooLarge, invalidText

    var errorDescription: String? {
        switch self {
        case .invalidDefinitions:
            "Use up to 128 parameters with unique names. Names must start with an ASCII letter or underscore, contain only ASCII letters, digits or underscores, and be at most 64 characters."
        case .invalidValue(let type):
            switch type {
            case .text: "Enter a valid text value."
            case .integer: "Enter an integer between -9223372036854775808 and 9223372036854775807, or select NULL."
            case .decimal: "Enter an exact decimal with digits before the decimal point, without an exponent, or select NULL."
            case .boolean: "Enter true or false in lowercase, or select NULL."
            case .date: "Enter a valid date as YYYY-MM-DD with a year from 0001 to 9999, or select NULL."
            case .timestamp: "Enter a valid timestamp as YYYY-MM-DD HH:mm:ss with up to six fractional second digits and no time zone, or select NULL."
            }
        case .valuesTooLarge: "Parameter values must total no more than 1 MiB."
        case .invalidText: "Parameter values cannot contain a NUL character."
        }
    }
}

private func validQueryParameterDate(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
          let year = queryParameterNumber(bytes[0..<4]), year >= 1,
          let month = queryParameterNumber(bytes[5..<7]), (1...12).contains(month),
          let day = queryParameterNumber(bytes[8..<10]), day >= 1 else { return false }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return day <= days[month - 1]
}

private func queryParameterNumber(_ bytes: ArraySlice<UInt8>) -> Int? {
    guard bytes.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return bytes.reduce(0) { $0 * 10 + Int($1 - 48) }
}

private struct QueryParameterCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireQueryParameterKeys(_ decoder: Decoder, exactly allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: QueryParameterCodingKey.self)
    guard Set(values.allKeys.map(\.stringValue)) == allowed else { throw QueryParameterError.invalidDefinitions }
}
