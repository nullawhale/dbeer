import Foundation

enum BackendProtocol {
    static let version = 5
    static let maxFrameBytes = 16 * 1_024 * 1_024
}

enum DatabaseEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case postgresql, mysql, cassandra

    static let availableCases: [Self] = [.postgresql, .mysql, .cassandra]
    var id: String { rawValue }
    var displayName: String { switch self { case .postgresql: "PostgreSQL"; case .mysql: "MySQL"; case .cassandra: "Apache Cassandra" } }
    var defaultPort: Int { switch self { case .postgresql: 5432; case .mysql: 3306; case .cassandra: 9042 } }
    var defaultDatabase: String { switch self { case .postgresql: "postgres"; case .mysql: "mysql"; case .cassandra: "" } }
    var defaultUser: String { switch self { case .postgresql: "postgres"; case .mysql: "root"; case .cassandra: "" } }
    var sslModes: [String] {
        switch self {
        case .postgresql: ["disable", "allow", "prefer", "require", "verify-ca", "verify-full"]
        case .mysql: ["disable", "require", "verify-ca", "verify-full"]
        case .cassandra: ["verify-full", "disable"]
        }
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
    var contactPoints: [String]?
    var localDatacenter: String?
    var consistency: String?
    var ssh: SSHSettings?

    init(host: String, port: Int, database: String, user: String, password: String,
         sslMode: String, sslRootCert: String? = nil, engine: DatabaseEngine = .postgresql,
         policy: ExecutionPolicy = ExecutionPolicy(), contactPoints: [String]? = nil,
         localDatacenter: String? = nil, consistency: String? = nil, ssh: SSHSettings? = nil) {
        self.ssh = ssh
        self.engine = engine
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.password = password
        self.sslMode = sslMode
        self.sslRootCert = sslRootCert
        self.policy = policy
        self.contactPoints = contactPoints
        self.localDatacenter = localDatacenter
        self.consistency = consistency ?? (engine == .cassandra ? "LOCAL_QUORUM" : nil)
    }

    private enum CodingKeys: String, CodingKey {
        case engine, host, port, database, user, password, sslMode, sslRootCert, policy, contactPoints, localDatacenter, consistency, ssh
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ssh = try values.decodeIfPresent(SSHSettings.self, forKey: .ssh)
        engine = try values.decodeIfPresent(DatabaseEngine.self, forKey: .engine) ?? .postgresql
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        database = try values.decode(String.self, forKey: .database)
        user = try values.decode(String.self, forKey: .user)
        password = try values.decode(String.self, forKey: .password)
        sslMode = try values.decode(String.self, forKey: .sslMode)
        sslRootCert = try values.decodeIfPresent(String.self, forKey: .sslRootCert)
        policy = try values.decodeIfPresent(ExecutionPolicy.self, forKey: .policy) ?? ExecutionPolicy()
        contactPoints = try values.decodeIfPresent([String].self, forKey: .contactPoints)
        localDatacenter = try values.decodeIfPresent(String.self, forKey: .localDatacenter)
        consistency = try values.decodeIfPresent(String.self, forKey: .consistency) ?? (engine == .cassandra ? "LOCAL_QUORUM" : nil)
    }
}

struct CatalogRequest: Codable, Sendable, Equatable {
    /// `clusterNodes` returns Cassandra driver observations: address, status,
    /// datacenter, rack and hostId. It accepts no object or paging parameters.
    /// `completion` returns 200 objects per page with JSON column-name and
    /// structured foreign-key and function-signature arrays; rules belong to the helper.
    /// `foreignKeys` returns one row per source/target column pair, ordered by
    /// constraint name and 1-based position. A truncated result is incomplete.
    var kind: String
    var schema: String?
    var object: String?
    var objectKind: String?
    var identity: String?
    var search: String?
    var page: Int?
    var cursor: String?
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

struct ExportDestination: Codable, Sendable, Equatable {
    var exists: Bool
    var identity: String?
    var parentIdentity: String?
    var size: Int64
    var sha256: String
    var modifiedNanoseconds: String?
}

struct ExportRequest: Codable, Sendable, Equatable {
    var path: String
    var format: String
    var nullMarker: String?
    var destination: ExportDestination?
}

/// Offline SQL formatting. Every column name is an explicitly chosen target
/// mapping; values retain the grid's NULL, DEFAULT, text and binary kinds.
struct InsertFormatRequest: Codable, Sendable, Equatable {
    static let maximumRows = 1_000
    static let maximumColumns = 4_096
    static let maximumCells = 100_000
    static let maximumBytes = 8 * 1_024 * 1_024

    var engine: DatabaseEngine
    var schema: String
    var table: String
    var columns: [InsertFormatColumn]
    var rows: [[ChangeValue]]

    var valid: Bool {
        func validName(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 1_024 && !value.contains("\0") }
        guard [.postgresql, .mysql].contains(engine), (schema.isEmpty || validName(schema)), validName(table),
              !columns.isEmpty, columns.count <= Self.maximumColumns,
              !rows.isEmpty, rows.count <= Self.maximumRows,
              columns.count * rows.count <= Self.maximumCells,
              columns.allSatisfy({ validName($0.name) }), Set(columns.map { Data($0.name.utf8) }).count == columns.count else { return false }
        var bytes = schema.utf8.count + table.utf8.count + columns.reduce(0) { $0 + $1.name.utf8.count }
        for row in rows {
            guard row.count == columns.count else { return false }
            for cell in row {
                bytes += cell.value?.utf8.count ?? 0
                guard bytes <= Self.maximumBytes else { return false }
                switch cell.kind {
                case "null", "default": guard cell.value == nil else { return false }
                case "text": guard cell.value != nil else { return false }
                case "binary":
                    guard let value = cell.value,
                          Data(base64Encoded: value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")) != nil else { return false }
                default: return false
                }
            }
        }
        return true
    }
}

struct InsertFormatColumn: Codable, Sendable, Equatable {
    var name: String
}

struct QueryResultSet: Codable, Sendable, Equatable {
    var columns: [ResultColumn] = []
    var rows: [[String?]] = []
    var commandTag: String = ""
    var rowCount: Int64 = 0
    var displayedRowCount: Int = 0
    var truncated: Bool = false
    var displayNotice: String?
    var affectedRowCountKnown: Bool?
    var nextCursor: String?

    static func validCursor(_ value: String) -> Bool { BackendMessage.validID(value) && !value.contains("\0") }

    func valid(streamed: Bool = false) -> Bool {
        (nextCursor == nil || Self.validCursor(nextCursor!)) && rowCount >= 0 && displayedRowCount >= 0 &&
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
    var sshTrust: SSHTrust?
    var insert: InsertFormatRequest?

    static func hello() -> Self {
        Self(type: "hello", requestId: UUID().uuidString, protocolVersion: BackendProtocol.version)
    }

    static func sshProbe(_ connection: ConnectionSettings) -> Self {
        Self(type: "ssh.probe", requestId: UUID().uuidString, connection: connection)
    }

    static func sshTrust(_ connection: ConnectionSettings, token: String, replace: Bool = false) -> Self {
        Self(type: "ssh.trust", requestId: UUID().uuidString, connection: connection, sshTrust: SSHTrust(token: token, replace: replace ? true : nil))
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

    static func formatInserts(_ request: InsertFormatRequest) -> Self {
        Self(type: "formatInserts", requestId: UUID().uuidString, insert: request)
    }

    static func assess(sessionId: String, operations: [OperationRequest]) -> Self {
        Self(type: "operation.assess", requestId: UUID().uuidString, sessionId: sessionId,
            queryId: UUID().uuidString, operations: operations)
    }

    var terminalType: String? {
        switch type {
        case "hello": "hello.ack"
        case "ssh.probe": "ssh.probe.result"
        case "ssh.trust": "ssh.trust.result"
        case "connect": "connect.result"
        case "execute", "catalog", "changes.preview", "changes.apply": "query.result"
        case "cancel": "cancel.ack"
        case "disconnect": "disconnect.ack"
        case "shutdown": "shutdown.ack"
        case "operation.assess": "operation.assessment"
        case "formatInserts": "insertSQL"
        default: nil
        }
    }
}

enum TransactionStatus: String, Codable, Sendable {
    case idle, transaction, failedTransaction, unsupported
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
    var buildIdentity: GPUIProductBuildIdentity?
    var engine: DatabaseEngine?
    var currentKeyspace: String?
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
    var affectedRowCountKnown: Bool?
    var nextCursor: String?
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
    var appliedChangeCount: Int?
    var connected: Bool?
    var outcomeUnknown: Bool?
    var sqlCompleted: Bool?
    var sqlNotExecuted: Bool?
    var exportPublication: String?
    var assessment: OperationAssessment?
    var ssh: SSHHostKey?
    var sql: String?

    func validate() throws {
        guard Self.validID(requestId) else { throw BackendTransportError(.invalidMessage) }
        if let sessionId, !Self.validID(sessionId) { throw BackendTransportError(.invalidMessage) }
        if let queryId, !Self.validID(queryId) { throw BackendTransportError(.invalidMessage) }
        if let nextCursor, !QueryResultSet.validCursor(nextCursor) { throw BackendTransportError(.invalidMessage) }
        if let appliedChangeCount, !(0...1000).contains(appliedChangeCount) || !["query.result", "error"].contains(type) {
            throw BackendTransportError(.invalidMessage)
        }
        let valid: Bool
        switch type {
        case "hello.ack": valid = protocolVersion != nil
        case "insertSQL":
            valid = sessionId == nil && queryId == nil && sql?.isEmpty == false &&
                (sql?.utf8.count ?? Int.max) <= InsertFormatRequest.maximumBytes && sql?.contains("\0") == false
        case "operation.assessment": valid = sessionId != nil && queryId != nil && assessment?.valid == true
        case "ssh.probe.result", "ssh.trust.result": valid = ssh?.isValid == true
        case "connect.result": valid = sessionId != nil && transactionStatus != nil && engine != nil && capabilities != nil
        case "query.progress": valid = (sequence ?? 0) > 0 && sessionId != nil && queryId != nil && (resultIndex ?? -1) >= 0 && (rowCount ?? -1) >= 0
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
        guard sql == nil || type == "insertSQL",
              sqlNotExecuted != true || (type == "error" && outcomeUnknown != true && sqlCompleted != true),
              sqlCompleted != true || (type == "error" && outcomeUnknown != true),
              exportPublication == nil || ((sqlCompleted == true || sqlNotExecuted == true) && ["notPublished", "unknown"].contains(exportPublication)), valid else { throw BackendTransportError(.invalidMessage) }
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
        case incompatibleVersion(Int), handshakeTimeout, duplicateRequest, unsupportedCapturedExport
        case unsupportedInsertFormatting
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
        case .unsupportedCapturedExport: explanation = "The helper does not support captured full export. SQL was not executed."
        case .unsupportedInsertFormatting: explanation = "The helper does not support offline SQL INSERT formatting."
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
        let identity: GPUIProductBuildIdentity?
        do {
            identity = try GPUIProductBuildIdentity.optionalFromFrame(frame, maximumFrameBytes: BackendProtocol.maxFrameBytes)
        } catch { throw BackendTransportError(.invalidMessage) }
        guard var reply = try? JSONDecoder().decode(BackendMessage.self, from: frame) else {
            throw BackendTransportError(.invalidMessage)
        }
        // Keep the value validated from original bytes, before JSONDecoder can
        // discard duplicate keys or normalize an oversized nested representation.
        reply.buildIdentity = identity
        try reply.validate()
        return reply
    }
}
