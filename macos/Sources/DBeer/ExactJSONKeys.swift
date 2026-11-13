import Foundation

struct ExactJSONStringEntry: Sendable, Equatable {
    let key: String
    let value: String
    static func == (lhs: Self, rhs: Self) -> Bool { Data(lhs.key.utf8) == Data(rhs.key.utf8) && Data(lhs.value.utf8) == Data(rhs.value.utf8) }
}

/// JSON object names are decoded UTF-8 identities. Swift String equality is
/// deliberately not used to detect duplicate keys or retain native type maps.
enum ExactJSONKeys {
    enum Failure: Error { case invalid }
    static func validate(_ data: Data, maximumBytes: Int, maximumDepth: Int = 64) throws {
        guard data.count <= maximumBytes, String(data: data, encoding: .utf8) != nil else { throw Failure.invalid }
        var parser = Parser(bytes: Array(data), maximumDepth: maximumDepth)
        try parser.value(depth: 0); parser.space()
        guard parser.index == parser.bytes.count else { throw Failure.invalid }
    }
    static func stringEntries(_ data: Data, maximumBytes: Int, maximumEntries: Int) throws -> [ExactJSONStringEntry] {
        guard data.count <= maximumBytes, maximumEntries >= 0, String(data: data, encoding: .utf8) != nil else { throw Failure.invalid }
        var parser = Parser(bytes: Array(data))
        try parser.take(123); parser.space()
        var result: [ExactJSONStringEntry] = [], seen = Set<Data>()
        if parser.consume(125) { parser.space(); guard parser.index == parser.bytes.count else { throw Failure.invalid }; return result }
        while true {
            let key = try parser.string()
            guard result.count < maximumEntries, seen.insert(Data(key.utf8)).inserted else { throw Failure.invalid }
            try parser.take(58)
            let value = try parser.string()
            result.append(.init(key: key, value: value))
            if parser.consume(125) { break }
            try parser.take(44)
        }
        parser.space(); guard parser.index == parser.bytes.count else { throw Failure.invalid }
        return result
    }
    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var nodes = 0
        var maximumDepth = 64
        mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func consume(_ byte: UInt8) -> Bool {
            space(); guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true
        }
        mutating func take(_ byte: UInt8) throws { guard consume(byte) else { throw Failure.invalid } }
        mutating func string() throws -> String {
            space(); let start = index; try take(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 {
                    guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else { throw Failure.invalid }
                    return value
                }
                guard byte >= 32 else { throw Failure.invalid }
                if byte == 92 {
                    guard index < bytes.count else { throw Failure.invalid }
                    let escape = bytes[index]; index += 1
                    if escape == 117 {
                        let code = try hexCode()
                        if (0xDC00...0xDFFF).contains(code) { throw Failure.invalid }
                        if (0xD800...0xDBFF).contains(code) {
                            guard index + 1 < bytes.count, bytes[index] == 92, bytes[index + 1] == 117 else { throw Failure.invalid }
                            index += 2
                            guard (0xDC00...0xDFFF).contains(try hexCode()) else { throw Failure.invalid }
                        }
                    } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(escape) { throw Failure.invalid }
                }
            }
            throw Failure.invalid
        }
        mutating func hexCode() throws -> UInt16 {
            guard index + 4 <= bytes.count else { throw Failure.invalid }
            var result: UInt16 = 0
            for _ in 0..<4 {
                let byte = bytes[index]; index += 1
                let digit: UInt16
                switch byte {
                case 48...57: digit = UInt16(byte - 48)
                case 65...70: digit = UInt16(byte - 55)
                case 97...102: digit = UInt16(byte - 87)
                default: throw Failure.invalid
                }
                result = result * 16 + digit
            }
            return result
        }
        mutating func value(depth: Int) throws {
            nodes += 1
            guard depth <= maximumDepth, nodes <= 1_000_000 else { throw Failure.invalid }
            space(); guard index < bytes.count else { throw Failure.invalid }
            switch bytes[index] {
            case 123:
                index += 1; var keys = Set<Data>()
                if consume(125) { return }
                while true {
                    let key = try string(); guard keys.insert(Data(key.utf8)).inserted else { throw Failure.invalid }
                    try take(58); try value(depth: depth + 1)
                    if consume(125) { return }; try take(44)
                }
            case 91:
                index += 1; if consume(93) { return }
                while true { try value(depth: depth + 1); if consume(93) { return }; try take(44) }
            case 34: _ = try string()
            default:
                let start = index
                while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                guard index > start else { throw Failure.invalid }
                let token = Data(bytes[start..<index])
                guard (try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed])) is NSNumber ||
                    token == Data("null".utf8) else { throw Failure.invalid }
            }
        }
    }
}
