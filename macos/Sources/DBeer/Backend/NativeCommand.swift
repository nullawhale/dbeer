import Foundation

/// Ordered exact arguments; callers never quote, join or shell-split them.
struct NativeCommand: Codable, Equatable, Sendable {
    static let capability = "nativeCommandsV1"
    static let maximumBytes = 96 * 1_024
    var name: String
    var arguments: [NativeCommandArgument]

    var valid: Bool {
        let name = Array(name.utf8)
        guard !name.isEmpty, name.count <= 64, arguments.count <= 1_024,
              name.enumerated().allSatisfy({ i, c in
                  (65...90).contains(c) || (97...122).contains(c) ||
                  i > 0 && ((48...57).contains(c) || [95, 46, 45].contains(c))
              }) else { return false }
        var size = name.count
        for argument in arguments {
            size += argument.value.utf8.count
            guard size <= Self.maximumBytes else { return false }
            switch argument.kind {
            case "text": break
            case "binary":
                guard Data(base64Encoded: argument.value).map({ $0.base64EncodedString() == argument.value }) == true else { return false }
            default: return false
            }
        }
        let wireBytes = 24 + Self.stringWireBytes(self.name) + max(0, arguments.count - 1) +
            arguments.reduce(0) { $0 + 18 + Self.stringWireBytes($1.kind) + Self.stringWireBytes($1.value) }
        return wireBytes <= Self.maximumBytes
    }

    private static func stringWireBytes(_ text: String) -> Int {
        var count = 2
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 8, 9, 10, 12, 13, 34, 92: count += 2
            case 0..<32, 38, 60, 62, 0x2028, 0x2029: count += 6
            case 0..<0x80: count += 1
            case 0..<0x800: count += 2
            case 0..<0x10000: count += 3
            default: count += 4
            }
        }
        return count
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        Data(lhs.name.utf8) == Data(rhs.name.utf8) && lhs.arguments == rhs.arguments
    }
}

struct NativeCommandArgument: Codable, Equatable, Sendable {
    var kind: String
    var value: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        Data(lhs.kind.utf8) == Data(rhs.kind.utf8) && Data(lhs.value.utf8) == Data(rhs.value.utf8)
    }
}

extension NativeCommand {
    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: NativeCommandKey.self)
        guard Set(fields.allKeys.map(\.stringValue)) == ["name", "arguments"] else { throw ExactJSONKeys.Failure.invalid }
        name = try fields.decode(String.self, forKey: NativeCommandKey("name"))
        arguments = try fields.decode([NativeCommandArgument].self, forKey: NativeCommandKey("arguments"))
        guard valid else { throw ExactJSONKeys.Failure.invalid }
    }
}

extension NativeCommandArgument {
    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: NativeCommandKey.self)
        guard Set(fields.allKeys.map(\.stringValue)) == ["kind", "value"] else { throw ExactJSONKeys.Failure.invalid }
        kind = try fields.decode(String.self, forKey: NativeCommandKey("kind"))
        value = try fields.decode(String.self, forKey: NativeCommandKey("value"))
    }
}

private struct NativeCommandKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}
