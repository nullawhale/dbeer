import Foundation

private struct OperationSupportCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Eligibility belongs to the session or object response that supplied it.
/// The helper still assesses and authorizes the exact operation at execution.
struct OperationSupport: Codable, Sendable, Equatable {
    enum Scope: String, Codable, Sendable { case session, structure, result }
    var version: Int
    var engine: DatabaseEngine
    var scope: Scope
    var operations: [OperationAvailability]

    var valid: Bool {
        version == 1 && (1...64).contains(operations.count) &&
            Set(operations.map(\.operation)).count == operations.count && operations.allSatisfy(\.valid)
    }

    func availability(_ operation: String) -> OperationAvailability? {
        operations.first { $0.operation == operation }
    }

    /// A session-level metadata requirement preserves the existing object check.
    func permits(_ operation: String, legacyAllowed: Bool) -> Bool {
        guard let value = availability(operation) else { return legacyAllowed }
        switch value.state {
        case .available: return true
        case .unavailable: return false
        case .requiresMetadata: return legacyAllowed
        }
    }

    private enum CodingKeys: String, CodingKey { case version, engine, scope, operations }
    init(version: Int = 1, engine: DatabaseEngine, scope: Scope, operations: [OperationAvailability]) {
        self.version = version
        self.engine = engine
        self.scope = scope
        self.operations = operations
    }
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: OperationSupportCodingKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == ["version", "engine", "scope", "operations"] else {
            throw BackendTransportError(.invalidMessage)
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        engine = try values.decode(DatabaseEngine.self, forKey: .engine)
        scope = try values.decode(Scope.self, forKey: .scope)
        operations = try values.decode([OperationAvailability].self, forKey: .operations)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}

struct OperationAvailability: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case available, unavailable, requiresMetadata }
    var operation: String
    var state: State
    var reason: String?

    var valid: Bool {
        guard (1...128).contains(operation.utf8.count),
              operation.range(of: #"^[A-Za-z][A-Za-z0-9.]*$"#, options: .regularExpression) == operation.startIndex..<operation.endIndex else { return false }
        if state == .available { return reason == nil }
        guard let reason else { return false }
        return !reason.isEmpty && reason.utf8.count <= 1_024 && !reason.contains("\0")
    }

    private enum CodingKeys: String, CodingKey { case operation, state, reason }
    init(operation: String, state: State, reason: String? = nil) {
        self.operation = operation
        self.state = state
        self.reason = reason
    }
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: OperationSupportCodingKey.self)
        guard Set(keys.allKeys.map(\.stringValue)).isSubset(of: ["operation", "state", "reason"]) else {
            throw BackendTransportError(.invalidMessage)
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        operation = try values.decode(String.self, forKey: .operation)
        state = try values.decode(State.self, forKey: .state)
        if values.contains(.reason), try values.decodeNil(forKey: .reason) { throw BackendTransportError(.invalidMessage) }
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }
}
