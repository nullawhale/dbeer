import Foundation

/// Optional Windows/Linux GPUI metadata. The macOS SwiftUI product does not
/// require this identity and does not launch a helper to inspect it.
struct GPUIProductBuildIdentity: Sendable, Codable, Equatable {
    static let productID = "app.dbeer.DBeer"
    static let protocolVersion = 3
    static let contractRevision = "gpui-v3-captured-export-v1"
    static let requiredCapability = "capturedExportV1"
    static let maximumBytes = 4_096

    enum Failure: Error, Sendable {
        case invalidMetadata
    }
    enum NativeTarget: String, Sendable, Codable {
        case windowsX64 = "windows-x86_64-msvc"
        case linuxX64 = "linux-x86_64-gnu"

        /// A pure label codec; this does not claim the current host is native.
        static func normalized(os: String, architecture: String, abi: String) -> Self? {
            guard architecture == "x86_64" || architecture == "amd64" else { return nil }
            switch (os, abi) {
            case ("windows", "msvc"): return .windowsX64
            case ("linux", "gnu"): return .linuxX64
            default: return nil
            }
        }
    }

    let schemaVersion: UInt32
    let productId: String
    let version: String
    let buildNumber: String
    let target: NativeTarget
    let protocolVersion: UInt32
    let contractRevision: String
    let sourceSha256: String
    let capabilities: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, productId, version, buildNumber, target
        case protocolVersion, contractRevision, sourceSha256, capabilities
    }

    /// Codable validates values/unknown fields. Raw JSON callers MUST use parse
    /// (or optionalFromHelloAck), because Decoder cannot expose duplicate keys.
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: GPUIBuildMetadataKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw Failure.invalidMetadata
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(UInt32.self, forKey: .schemaVersion)
        productId = try values.decode(String.self, forKey: .productId)
        version = try values.decode(String.self, forKey: .version)
        buildNumber = try values.decode(String.self, forKey: .buildNumber)
        target = try values.decode(NativeTarget.self, forKey: .target)
        protocolVersion = try values.decode(UInt32.self, forKey: .protocolVersion)
        contractRevision = try values.decode(String.self, forKey: .contractRevision)
        sourceSha256 = try values.decode(String.self, forKey: .sourceSha256)
        capabilities = try values.decode([String].self, forKey: .capabilities)
        try validate()
    }

    func validate() throws {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        func digits(_ value: some StringProtocol) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
        }
        guard schemaVersion == 1, productId == Self.productID,
              parts.count == 3, parts.allSatisfy({ digits($0) }), version.utf8.count <= 32,
              digits(buildNumber), buildNumber.first != "0", buildNumber.utf8.count <= 20,
              protocolVersion == Self.protocolVersion, contractRevision == Self.contractRevision,
              sourceSha256.utf8.count == 64,
              sourceSha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              capabilities == [Self.requiredCapability] else { throw Failure.invalidMetadata }
    }

    static func parse(_ data: Data) throws -> Self {
        let fields = try GPUIBuildMetadataJSON.fields(in: data, limit: maximumBytes)
        // JSONDecoder accepts 1.0 as an integer; serde's u32 contract does not.
        guard fields["schemaVersion"].map({ data.metadataSlice($0).trimmedASCII == Data("1".utf8) }) == true,
              fields["protocolVersion"].map({ data.metadataSlice($0).trimmedASCII == Data("3".utf8) }) == true else {
            throw Failure.invalidMetadata
        }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw Failure.invalidMetadata }
    }

    /// Exact package.py sorted compact ASCII JSON, with one LF for a file.
    /// Embedded markers use the same bytes with only that final LF omitted.
    func canonicalJSON() throws -> Data {
        try validate()
        return Data(("{\"buildNumber\":\"" + buildNumber + "\",\"capabilities\":[\"capturedExportV1\"],"
            + "\"contractRevision\":\"gpui-v3-captured-export-v1\",\"productId\":\"app.dbeer.DBeer\","
            + "\"protocolVersion\":3,\"schemaVersion\":1,\"sourceSha256\":\"" + sourceSha256
            + "\",\"target\":\"" + target.rawValue + "\",\"version\":\"" + version + "\"}\n").utf8)
    }

    /// Call on the original hello.ack frame before decoding BackendMessage.
    /// The transport retains its existing frame bound. Absent/null metadata is
    /// compatible with ordinary Mac helpers; malformed present metadata refuses.
    static func optionalFromHelloAck(_ frame: Data, maximumFrameBytes: Int = 16 * 1_024 * 1_024) throws -> Self? {
        let fields = try GPUIBuildMetadataJSON.fields(in: frame, limit: maximumFrameBytes)
        guard let type = fields["type"],
              (try? JSONDecoder().decode(String.self, from: frame.metadataSlice(type))) == "hello.ack" else {
            throw Failure.invalidMetadata
        }
        return try optionalIdentity(in: frame, fields: fields)
    }

    /// Transport preflight must precede the general Foundation decode. It
    /// determines the type only after rejecting duplicate original frame keys.
    static func optionalFromFrame(_ frame: Data, maximumFrameBytes: Int) throws -> Self? {
        let fields = try GPUIBuildMetadataJSON.fields(in: frame, limit: maximumFrameBytes)
        guard let rawType = fields["type"],
              let type = try? JSONDecoder().decode(String.self, from: frame.metadataSlice(rawType)) else {
            throw Failure.invalidMetadata
        }
        guard type == "hello.ack" else {
            guard fields["buildIdentity"] == nil else { throw Failure.invalidMetadata }
            return nil
        }
        return try optionalIdentity(in: frame, fields: fields)
    }

    private static func optionalIdentity(in frame: Data, fields: [String: Range<Int>]) throws -> Self? {
        guard let identity = fields["buildIdentity"] else { return nil }
        let raw = frame.metadataSlice(identity)
        if raw.trimmedASCII == Data("null".utf8) { return nil }
        return try parse(raw)
    }

    func requireMatchingHelper(_ remote: Self?, protocolVersion: UInt32, capabilities: [String]) throws {
        try validate()
        guard let remote else { throw Failure.invalidMetadata }
        try remote.validate()
        guard self == remote, protocolVersion == Self.protocolVersion,
              capabilities.contains(Self.requiredCapability) else { throw Failure.invalidMetadata }
    }

    struct Info: Sendable, Codable, Equatable {
        enum Component: String, Sendable, Codable { case gui, helper }
        let component: Component
        let identity: GPUIProductBuildIdentity

        private enum CodingKeys: String, CodingKey { case component, identity }
        init(from decoder: any Decoder) throws {
            let all = try decoder.container(keyedBy: GPUIBuildMetadataKey.self)
            guard Set(all.allKeys.map(\.stringValue)) == ["component", "identity"] else { throw Failure.invalidMetadata }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            component = try values.decode(Component.self, forKey: .component)
            identity = try values.decode(GPUIProductBuildIdentity.self, forKey: .identity)
        }
        static func parse(_ data: Data) throws -> Self {
            let fields = try GPUIBuildMetadataJSON.fields(in: data, limit: maximumBytes + 64)
            guard let identity = fields["identity"] else { throw Failure.invalidMetadata }
            _ = try GPUIProductBuildIdentity.parse(data.metadataSlice(identity))
            do { return try JSONDecoder().decode(Self.self, from: data) }
            catch { throw Failure.invalidMetadata }
        }
        func canonicalJSON() throws -> Data {
            let rawIdentity = try identity.canonicalJSON().dropLast()
            return Data("{\"component\":\"\(component.rawValue)\",\"identity\":".utf8) + rawIdentity + Data("}\n".utf8)
        }
    }
}

private struct GPUIBuildMetadataKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private extension Data {
    func metadataSlice(_ range: Range<Int>) -> Data {
        let lower = index(startIndex, offsetBy: range.lowerBound)
        let upper = index(startIndex, offsetBy: range.upperBound)
        return Data(self[lower..<upper])
    }
    var trimmedASCII: Data {
        let whitespace: Set<UInt8> = [9, 10, 13, 32]
        return Data(drop(while: { whitespace.contains($0) }).reversed()
            .drop(while: { whitespace.contains($0) }).reversed())
    }
}

/// Private raw-frame preflight: retains duplicate object keys before Foundation
/// decodes values. It is bounded by bytes/depth and never stores frame values.
private struct GPUIBuildMetadataJSON {
    private let bytes: [UInt8]
    private var index = 0
    private static let failure = GPUIProductBuildIdentity.Failure.invalidMetadata

    static func fields(in data: Data, limit: Int) throws -> [String: Range<Int>] {
        guard limit >= 0, data.count <= limit, String(data: data, encoding: .utf8) != nil else { throw failure }
        var parser = Self(bytes: Array(data))
        let fields = try parser.object(depth: 0, capture: true)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw failure }
        return fields
    }
    private mutating func whitespace() {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    private mutating func take(_ expected: UInt8) throws {
        whitespace()
        guard index < bytes.count, bytes[index] == expected else { throw Self.failure }
        index += 1
    }
    private mutating func object(depth: Int, capture: Bool = false) throws -> [String: Range<Int>] {
        guard depth <= 64 else { throw Self.failure }
        try take(123)
        var seen: Set<String> = []
        var fields: [String: Range<Int>] = [:]
        whitespace()
        if index < bytes.count, bytes[index] == 125 { index += 1; return fields }
        while true {
            let key = try string()
            guard seen.insert(key).inserted else { throw Self.failure }
            try take(58)
            whitespace()
            let start = index
            try value(depth: depth + 1)
            if capture { fields[key] = start..<index }
            whitespace()
            guard index < bytes.count else { throw Self.failure }
            if bytes[index] == 125 { index += 1; return fields }
            try take(44)
        }
    }
    private mutating func string() throws -> String {
        whitespace()
        let start = index
        try take(34)
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34 {
                guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else { throw Self.failure }
                return value
            }
            guard byte >= 32 else { throw Self.failure }
            if byte == 92 {
                guard index < bytes.count else { throw Self.failure }
                let escape = bytes[index]; index += 1
                if escape == 117 {
                    let code = try hexCode()
                    if (0xDC00...0xDFFF).contains(code) { throw Self.failure }
                    if (0xD800...0xDBFF).contains(code) {
                        guard index + 1 < bytes.count, bytes[index] == 92, bytes[index + 1] == 117 else { throw Self.failure }
                        index += 2
                        guard (0xDC00...0xDFFF).contains(try hexCode()) else { throw Self.failure }
                    }
                } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(escape) { throw Self.failure }
            }
        }
        throw Self.failure
    }
    private mutating func hexCode() throws -> UInt16 {
        guard index + 4 <= bytes.count else { throw Self.failure }
        var code: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[index]; index += 1
            let digit: UInt16
            switch byte {
            case 48...57: digit = UInt16(byte - 48)
            case 65...70: digit = UInt16(byte - 55)
            case 97...102: digit = UInt16(byte - 87)
            default: throw Self.failure
            }
            code = code * 16 + digit
        }
        return code
    }
    private mutating func value(depth: Int) throws {
        guard depth <= 64 else { throw Self.failure }
        whitespace()
        guard index < bytes.count else { throw Self.failure }
        switch bytes[index] {
        case 123: _ = try object(depth: depth)
        case 34: _ = try string()
        case 91:
            index += 1; whitespace()
            if index < bytes.count, bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); whitespace()
                guard index < bytes.count else { throw Self.failure }
                if bytes[index] == 93 { index += 1; return }
                try take(44)
            }
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        default:
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start,
                  (try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])) is NSNumber else { throw Self.failure }
        }
    }
    private mutating func literal(_ value: String) throws {
        let literal = Array(value.utf8)
        guard index + literal.count <= bytes.count, Array(bytes[index..<(index + literal.count)]) == literal else { throw Self.failure }
        index += literal.count
    }
}
