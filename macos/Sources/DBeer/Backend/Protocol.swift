import Foundation

enum BackendProtocol {
    static let version = 3
    static let maxFrameBytes = 16 * 1_024 * 1_024
}

enum DatabaseEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case postgresql, mysql

    var id: String { rawValue }
    var displayName: String { self == .postgresql ? "PostgreSQL" : "MySQL" }
    var defaultPort: Int { self == .postgresql ? 5432 : 3306 }
    var defaultDatabase: String { self == .postgresql ? "postgres" : "mysql" }
    var defaultUser: String { self == .postgresql ? "postgres" : "root" }
    var sslModes: [String] {
        self == .postgresql ? ["disable", "allow", "prefer", "require", "verify-ca", "verify-full"] :
            ["disable", "require", "verify-ca", "verify-full"]
    }
}

struct ConnectionSettings: Codable, Sendable, Equatable {
    var engine: DatabaseEngine
    var host: String
    var port: Int
    var database: String
    var user: String
    var password: String
    var sslMode: String
    var sslRootCert: String?
    var policy: ExecutionPolicy

    init(host: String, port: Int, database: String, user: String, password: String,
         sslMode: String, sslRootCert: String? = nil, engine: DatabaseEngine = .postgresql,
         policy: ExecutionPolicy = ExecutionPolicy()) {
        self.engine = engine
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.password = password
        self.sslMode = sslMode
        self.sslRootCert = sslRootCert
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case engine, host, port, database, user, password, sslMode, sslRootCert, policy
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        engine = try values.decodeIfPresent(DatabaseEngine.self, forKey: .engine) ?? .postgresql
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        database = try values.decode(String.self, forKey: .database)
        user = try values.decode(String.self, forKey: .user)
        password = try values.decode(String.self, forKey: .password)
        sslMode = try values.decode(String.self, forKey: .sslMode)
        sslRootCert = try values.decodeIfPresent(String.self, forKey: .sslRootCert)
        policy = try values.decodeIfPresent(ExecutionPolicy.self, forKey: .policy) ?? ExecutionPolicy()
    }
}

struct CatalogRequest: Codable, Sendable, Equatable {
    /// `completion` returns 200 objects per page with JSON column-name arrays.
    var kind: String
    var schema: String?
    var object: String?
    var objectKind: String?
    var identity: String?
    var search: String?
    var page: Int?
    var sort: [CatalogSort]?
    var filters: [CatalogFilter]?
}

struct CatalogSort: Codable, Sendable, Equatable {
    var column: String
    var direction: String
}

struct CatalogFilter: Codable, Sendable, Equatable {
    var column: String
    var `operator`: String
    var value: String?
}

struct ExportRequest: Codable, Sendable, Equatable {
    var path: String
    var format: String
    var nullMarker: String?
}

struct QueryResultSet: Codable, Sendable, Equatable {
    var columns: [ResultColumn] = []
    var rows: [[String?]] = []
    var commandTag: String = ""
    var rowCount: Int64 = 0
    var displayedRowCount: Int = 0
    var truncated: Bool = false
    var displayNotice: String?

    func valid(streamed: Bool = false) -> Bool {
        rowCount >= 0 && displayedRowCount >= 0 &&
            (streamed ? rows.isEmpty : displayedRowCount == rows.count) &&
            columns.enumerated().allSatisfy { $0.offset == $0.element.index &&
                ($0.element.encoding == nil || $0.element.encoding == "base64") } &&
            rows.allSatisfy { $0.count == columns.count }
    }
}

struct BackendCommand: Codable, Sendable, Equatable {
    let type: String
    let requestId: String
    var protocolVersion: Int?
    var connection: ConnectionSettings?
    var sessionId: String?
    var queryId: String?
    var sql: String?
    var catalog: CatalogRequest?
    var stream: Bool?
    var export: ExportRequest?
    var sequence: Int?
    var changes: ChangesRequest?
    var operations: [OperationRequest]?
    var authorization: String?

    static func hello() -> Self {
        Self(type: "hello", requestId: UUID().uuidString, protocolVersion: BackendProtocol.version)
    }

    static func connect(_ connection: ConnectionSettings) -> Self {
        Self(type: "connect", requestId: UUID().uuidString, connection: connection)
    }

    static func execute(sessionId: String, queryId: String = UUID().uuidString, sql: String) -> Self {
        Self(type: "execute", requestId: UUID().uuidString, sessionId: sessionId, queryId: queryId, sql: sql, stream: true)
    }

    static func catalog(sessionId: String, queryId: String = UUID().uuidString, request: CatalogRequest) -> Self {
        Self(type: "catalog", requestId: UUID().uuidString, sessionId: sessionId, queryId: queryId, catalog: request, stream: true)
    }

    static func runToFile(sessionId: String, queryId: String = UUID().uuidString, sql: String, export: ExportRequest) -> Self {
        Self(type: "execute", requestId: UUID().uuidString, sessionId: sessionId, queryId: queryId, sql: sql, stream: true, export: export)
    }

    static func previewChanges(sessionId: String, queryId: String = UUID().uuidString, request: ChangesRequest) -> Self {
        Self(type: "changes.preview", requestId: UUID().uuidString, sessionId: sessionId, queryId: queryId, changes: request)
    }

    static func applyChanges(sessionId: String, queryId: String = UUID().uuidString, request: ChangesRequest) -> Self {
        Self(type: "changes.apply", requestId: UUID().uuidString, sessionId: sessionId, queryId: queryId, changes: request)
    }

    static func cancel(sessionId: String, queryId: String) -> Self {
        Self(type: "cancel", requestId: UUID().uuidString, sessionId: sessionId, queryId: queryId)
    }

    static func disconnect(sessionId: String) -> Self {
        Self(type: "disconnect", requestId: UUID().uuidString, sessionId: sessionId)
    }

    static func shutdown() -> Self {
        Self(type: "shutdown", requestId: UUID().uuidString)
    }

    static func assess(sessionId: String, operations: [OperationRequest]) -> Self {
        Self(type: "operation.assess", requestId: UUID().uuidString, sessionId: sessionId,
            queryId: UUID().uuidString, operations: operations)
    }

    var terminalType: String? {
        switch type {
        case "hello": "hello.ack"
        case "connect": "connect.result"
        case "execute", "catalog", "changes.preview", "changes.apply": "query.result"
        case "cancel": "cancel.ack"
        case "disconnect": "disconnect.ack"
        case "shutdown": "shutdown.ack"
        case "operation.assess": "operation.assessment"
        default: nil
        }
    }
}

enum TransactionStatus: String, Codable, Sendable {
    case idle, transaction, failedTransaction
}

struct ResultColumn: Codable, Sendable, Equatable {
    let index: Int
    let name: String
    let engine: DatabaseEngine
    let nativeType: String
    let typeOid: UInt32
    let encoding: String?

    init(index: Int, name: String, typeOid: UInt32 = 0, engine: DatabaseEngine = .postgresql,
         nativeType: String = "", encoding: String? = nil) {
        self.index = index
        self.name = name
        self.engine = engine
        self.nativeType = nativeType
        self.typeOid = typeOid
        self.encoding = encoding
    }

    private enum CodingKeys: String, CodingKey { case index, name, engine, nativeType, typeOid, encoding }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        index = try values.decode(Int.self, forKey: .index)
        name = try values.decode(String.self, forKey: .name)
        engine = try values.decodeIfPresent(DatabaseEngine.self, forKey: .engine) ?? .postgresql
        nativeType = try values.decodeIfPresent(String.self, forKey: .nativeType) ?? ""
        typeOid = try values.decodeIfPresent(UInt32.self, forKey: .typeOid) ?? 0
        encoding = try values.decodeIfPresent(String.self, forKey: .encoding)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(index, forKey: .index)
        try values.encode(name, forKey: .name)
        try values.encode(engine, forKey: .engine)
        try values.encode(nativeType, forKey: .nativeType)
        if typeOid != 0 { try values.encode(typeOid, forKey: .typeOid) }
        try values.encodeIfPresent(encoding, forKey: .encoding)
    }
}

/// A single wire reply; optional fields belong to the corresponding message type.
/// `validate` enforces that a decoded reply has the required fields before use.
struct BackendMessage: Codable, Sendable, Equatable {
    let type: String
    let requestId: String
    var protocolVersion: Int?
    var engine: DatabaseEngine?
    var capabilities: [String]?
    var sessionId: String?
    var queryId: String?
    var transactionStatus: TransactionStatus?
    var durationMs: Double?
    var columns: [ResultColumn]?
    var rows: [[String?]]?
    var commandTag: String?
    var rowCount: Int64?
    var displayedRowCount: Int?
    var truncated: Bool?
    var displayNotice: String?
    var status: String?
    var category: String?
    var message: String?
    var sqlState: String?
    var errorPosition: Int?
    var resultSets: [QueryResultSet]?
    var streamed: Bool?
    var sequence: Int?
    var resultIndex: Int?
    var exportPath: String?
    var exportFormat: String?
    var exportRowCount: Int64?
    var connected: Bool?
    var outcomeUnknown: Bool?
    var assessment: OperationAssessment?

    func validate() throws {
        guard Self.validID(requestId) else { throw BackendTransportError(.invalidMessage) }
        if let sessionId, !Self.validID(sessionId) { throw BackendTransportError(.invalidMessage) }
        if let queryId, !Self.validID(queryId) { throw BackendTransportError(.invalidMessage) }
        let valid: Bool
        switch type {
        case "hello.ack": valid = protocolVersion != nil
        case "operation.assessment": valid = sessionId != nil && queryId != nil && assessment?.valid == true
        case "connect.result": valid = sessionId != nil && transactionStatus != nil && engine != nil && capabilities != nil
        case "query.started": valid = sessionId != nil && queryId != nil
        case "query.chunk":
            valid = sessionId != nil && queryId != nil && (sequence ?? 0) > 0 &&
                (resultIndex ?? -1) >= 0 && (resultIndex ?? 1_024) < 1_024 && rows != nil &&
                (columns?.enumerated().allSatisfy { $0.offset == $0.element.index &&
                    ($0.element.encoding == nil || $0.element.encoding == "base64") } ?? true)
        case "query.result":
            if let columns, let rows, let durationMs, let rowCount, let displayedRowCount {
                valid = sessionId != nil && queryId != nil && transactionStatus != nil &&
                    durationMs.isFinite && durationMs >= 0 && rowCount >= 0 &&
                    (streamed == true ? (rows.isEmpty && displayedRowCount >= 0) : displayedRowCount == rows.count) && truncated != nil && commandTag != nil &&
                    columns.enumerated().allSatisfy { $0.offset == $0.element.index &&
                        ($0.element.encoding == nil || $0.element.encoding == "base64") } &&
                    rows.allSatisfy { $0.count == columns.count } &&
                    (resultSets?.allSatisfy { $0.valid(streamed: streamed == true) } ?? true)
            } else { valid = false }
        case "cancel.ack":
            valid = sessionId != nil && queryId != nil && ["accepted", "alreadyFinished"].contains(status)
        case "disconnect.ack": valid = sessionId != nil
        case "shutdown.ack": valid = true
        case "error":
            valid = category != nil && message != nil && connected != nil && outcomeUnknown != nil &&
                (errorPosition == nil || errorPosition! > 0)
                && (resultSets?.allSatisfy { $0.valid(streamed: streamed == true) } ?? true)
        default: valid = false
        }
        guard valid else { throw BackendTransportError(.invalidMessage) }
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
    }
}

struct BackendRemoteError: LocalizedError, Sendable {
    let reply: BackendMessage
    var errorDescription: String? { reply.message }
}

struct BackendTransportError: LocalizedError, Sendable, Equatable {
    enum Code: Sendable, Equatable {
        case missingExecutable, alreadyStarted, notReady, invalidMessage, frameTooLarge
        case invalidUTF8, unexpectedEOF, processExited(Int32), writeFailed
        case incompatibleVersion(Int), handshakeTimeout, duplicateRequest
    }

    let code: Code
    var outcomeUnknown: Bool

    init(_ code: Code, outcomeUnknown: Bool = false) {
        self.code = code
        self.outcomeUnknown = outcomeUnknown
    }

    var errorDescription: String? {
        let explanation: String
        switch code {
        case .missingExecutable: explanation = "The bundled helper is missing. Build and open DBeer.app with scripts/build-app.sh."
        case .alreadyStarted: explanation = "The helper has already started."
        case .notReady: explanation = "The helper is unavailable. Connect again to start a new session."
        case .invalidMessage: explanation = "The helper sent an invalid protocol message."
        case .frameTooLarge: explanation = "A protocol message exceeded the 16 MiB transport limit."
        case .invalidUTF8: explanation = "The helper sent invalid UTF-8."
        case .unexpectedEOF: explanation = "The helper closed its output unexpectedly."
        case .processExited(let status): explanation = "The helper exited unexpectedly (status \(status))."
        case .writeFailed: explanation = "The command could not be sent to the helper."
        case .incompatibleVersion(let version): explanation = "The helper uses incompatible protocol version \(version)."
        case .handshakeTimeout: explanation = "The helper did not complete its handshake within 5 seconds."
        case .duplicateRequest: explanation = "A command identifier was reused."
        }
        return explanation + (outcomeUnknown ? " The SQL outcome is unknown; the command was not repeated." : "")
    }
}

/// Buffers bytes, never decoded strings: a UTF-8 scalar may span pipe reads.
struct NDJSONFramer: Sendable {
    let maxFrameBytes: Int
    private var buffer = Data()

    init(maxFrameBytes: Int = BackendProtocol.maxFrameBytes) {
        self.maxFrameBytes = maxFrameBytes
    }

    mutating func append(_ bytes: Data) throws -> [Data] {
        var frames: [Data] = []
        var start = bytes.startIndex
        for index in bytes.indices where bytes[index] == 0x0A {
            let segment = bytes[start..<index]
            guard buffer.count + segment.count <= maxFrameBytes else {
                throw BackendTransportError(.frameTooLarge)
            }
            buffer.append(segment)
            frames.append(buffer)
            buffer = Data()
            start = bytes.index(after: index)
        }
        let tail = bytes[start...]
        guard buffer.count + tail.count <= maxFrameBytes else {
            throw BackendTransportError(.frameTooLarge)
        }
        buffer.append(tail)
        return frames
    }

    func finish() throws {
        guard buffer.isEmpty else { throw BackendTransportError(.unexpectedEOF) }
    }

    static func decode(_ frame: Data) throws -> BackendMessage {
        guard String(data: frame, encoding: .utf8) != nil else { throw BackendTransportError(.invalidUTF8) }
        guard let reply = try? JSONDecoder().decode(BackendMessage.self, from: frame) else {
            throw BackendTransportError(.invalidMessage)
        }
        try reply.validate()
        return reply
    }
}
