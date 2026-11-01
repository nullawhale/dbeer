// Keep additive payloads outside the common envelope's inline storage. Replacing
// immutable storage on every write preserves the wrapped value's copy semantics.
@propertyWrapper
struct OptionalTransportPayload<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    private final class Storage: Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private var storage: Storage?

    var wrappedValue: Value? {
        get { storage?.value }
        set { storage = newValue.map(Storage.init) }
    }

    init(wrappedValue: Value? = nil) {
        storage = wrappedValue.map(Storage.init)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(wrappedValue: try container.decode(Value?.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.wrappedValue == rhs.wrappedValue }
}

extension KeyedDecodingContainer {
    // Synthesized Codable normally requires wrapper properties to be present.
    // Missing and explicit null retain the original optional payload behavior.
    func decode<Value>(_ type: OptionalTransportPayload<Value>.Type, forKey key: Key) throws -> OptionalTransportPayload<Value> {
        OptionalTransportPayload(wrappedValue: try decodeIfPresent(Value.self, forKey: key))
    }
}

extension KeyedEncodingContainer {
    // Preserve omission rather than introducing null keys in existing frames.
    mutating func encode<Value>(_ value: OptionalTransportPayload<Value>, forKey key: Key) throws {
        try encodeIfPresent(value.wrappedValue, forKey: key)
    }
}
