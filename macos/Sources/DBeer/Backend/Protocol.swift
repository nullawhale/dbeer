import Foundation

enum BackendProtocol {
    static let version = 6
    static let maxFrameBytes = 16 * 1_024 * 1_024
}

enum DatabaseEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case postgresql, mysql, cassandra, mongodb, sqlite

    static let availableCases: [Self] = [.postgresql, .mysql, .cassandra, .mongodb, .sqlite]
    var id: String { rawValue }
    var displayName: String { switch self { case .postgresql: "PostgreSQL"; case .mysql: "MySQL"; case .cassandra: "Apache Cassandra"; case .mongodb: "MongoDB"; case .sqlite: "SQLite" } }
    var defaultPort: Int { switch self { case .postgresql: 5432; case .mysql: 3306; case .cassandra: 9042; case .mongodb: 27017; case .sqlite: 0 } }
    var defaultDatabase: String { switch self { case .postgresql: "postgres"; case .mysql: "mysql"; case .cassandra, .mongodb, .sqlite: "" } }
    var defaultUser: String { switch self { case .postgresql: "postgres"; case .mysql: "root"; case .cassandra, .mongodb, .sqlite: "" } }
    var sslModes: [String] {
        switch self {
        case .postgresql: ["disable", "allow", "prefer", "require", "verify-ca", "verify-full"]
        case .mysql: ["disable", "require", "verify-ca", "verify-full"]
        case .cassandra, .mongodb: ["verify-full", "disable"]
        case .sqlite: ["disable"]
        }
    }
}

struct SQLiteSettings: Codable, Sendable, Equatable {
    var path: String

    var isValid: Bool {
        path.hasPrefix("/") && !path.hasPrefix("//") && !path.contains("\0") && path.utf8.count <= 4_096
    }
}

struct ConnectionSettings: Codable, Sendable, Equatable {
    var sessionPurpose: String?
    var engine: DatabaseEngine
    var host: String
    var port: Int
    var database: String
    var user: String
    var password: String
    var passwordCommand: PasswordCommand?
    var sslMode: String
    var sslRootCert: String?
    var policy: ExecutionPolicy
    var contactPoints: [String]?
    var localDatacenter: String?
    var consistency: String?
    var ssh: SSHSettings?
    var mongodb: MongoDBSettings?
    var sqlite: SQLiteSettings?

    init(host: String, port: Int, database: String, user: String, password: String,
         sslMode: String, sslRootCert: String? = nil, engine: DatabaseEngine = .postgresql,
         policy: ExecutionPolicy = ExecutionPolicy(), contactPoints: [String]? = nil,
         localDatacenter: String? = nil, consistency: String? = nil, ssh: SSHSettings? = nil,
         passwordCommand: PasswordCommand? = nil, mongodb: MongoDBSettings? = nil, sqlite: SQLiteSettings? = nil) {
        self.sqlite = sqlite
        self.mongodb = mongodb
        self.passwordCommand = passwordCommand
        self.ssh = ssh
        self.engine = engine
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.password = passwordCommand == nil ? password : ""
        self.sslMode = sslMode
        self.sslRootCert = sslRootCert
        self.policy = policy
        self.contactPoints = contactPoints
        self.localDatacenter = localDatacenter
        self.consistency = consistency ?? (engine == .cassandra ? "LOCAL_QUORUM" : nil)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionPurpose, engine, host, port, database, user, password, passwordCommand, sslMode, sslRootCert, policy, contactPoints, localDatacenter, consistency, ssh, mongodb, sqlite
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionPurpose = try values.decodeIfPresent(String.self, forKey: .sessionPurpose)
        sqlite = try values.decodeIfPresent(SQLiteSettings.self, forKey: .sqlite)
        mongodb = try values.decodeIfPresent(MongoDBSettings.self, forKey: .mongodb)
        ssh = try values.decodeIfPresent(SSHSettings.self, forKey: .ssh)
        engine = try values.decodeIfPresent(DatabaseEngine.self, forKey: .engine) ?? .postgresql
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        database = try values.decode(String.self, forKey: .database)
        user = try values.decode(String.self, forKey: .user)
        password = try values.decode(String.self, forKey: .password)
        passwordCommand = try values.decodeIfPresent(PasswordCommand.self, forKey: .passwordCommand)
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
    var filterExpression: CatalogFilterExpression?
    /// PostgreSQL-only, read-only DDL generation. Empty enum labels are values.
    var typeChange: TypeChange?
    var relationshipScope: SQLiteRelationshipScope? = nil
}

extension CatalogRequest {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind)
        schema = try values.decodeIfPresent(String.self, forKey: .schema)
        object = try values.decodeIfPresent(String.self, forKey: .object)
        objectKind = try values.decodeIfPresent(String.self, forKey: .objectKind)
        identity = try values.decodeIfPresent(String.self, forKey: .identity)
        search = try values.decodeIfPresent(String.self, forKey: .search)
        page = try values.decodeIfPresent(Int.self, forKey: .page)
        cursor = try values.decodeIfPresent(String.self, forKey: .cursor)
        sort = try values.decodeIfPresent([CatalogSort].self, forKey: .sort)
        filters = try values.decodeIfPresent([CatalogFilter].self, forKey: .filters)
        typeChange = try values.decodeIfPresent(TypeChange.self, forKey: .typeChange)
        filterExpression = values.contains(.filterExpression)
            ? try values.decode(CatalogFilterExpression.self, forKey: .filterExpression) : nil
        if ["referencingTables", "foreignKeys", "name"].contains(kind) {
            let fields = try decoder.container(keyedBy: RelationshipSelectorCodingKey.self)
            let allowed: Set<String> = kind == "name" ? ["kind", "schema", "object", "objectKind", "identity"] : ["kind", "schema", "object", "objectKind"]
            guard Set(fields.allKeys.map(\.stringValue)).isSubset(of: allowed),
                  fields.allKeys.allSatisfy({ (try? fields.decodeNil(forKey: $0)) == false }) else { throw BackendTransportError(.invalidMessage) }
            if kind != "name" { guard supportsMetadataPaging else { throw BackendTransportError(.invalidMessage) } }
        }
        relationshipScope = values.contains(.relationshipScope) ? try values.decode(SQLiteRelationshipScope.self, forKey: .relationshipScope) : nil
        if let relationshipScope {
            guard kind == "browse", relationshipScope.matches(.init(schema: schema ?? "", name: object ?? "", kind: objectKind ?? "")) else { throw BackendTransportError(.invalidMessage) }
        }
        let settings = TableBrowseConfiguration(filterExpression: filterExpression ?? .conjunction(filters ?? []), sort: sort ?? [], relationshipScope: relationshipScope)
        guard settings.isValid, filterExpression == nil || ((filters ?? []).isEmpty && kind == "browse") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid browse settings."))
        }
    }
}

struct TypeChange: Codable, Sendable, Equatable {
    var operation: String
    var newName: String?
    var oldValue: String?
    var value: String?
}

struct CatalogSort: Codable, Sendable, Equatable {
    var column: String
    var direction: String
}

struct CatalogFilter: Codable, Sendable, Equatable {
    var column: String
    var `operator`: String
    var value: String?
    var sqliteValue: SQLiteValue?
    var nativeValue: NativeCellFilterValue?

    init(column: String, operator operation: String, value: String? = nil, sqliteValue: SQLiteValue? = nil, nativeValue: NativeCellFilterValue? = nil) {
        self.column = column
        self.operator = operation
        self.value = value
        self.sqliteValue = sqliteValue
        self.nativeValue = nativeValue
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard Data(lhs.column.utf8) == Data(rhs.column.utf8), lhs.operator == rhs.operator, lhs.sqliteValue == rhs.sqliteValue, lhs.nativeValue == rhs.nativeValue else { return false }
        switch (lhs.value, rhs.value) {
        case (nil, nil): return true
        case let (left?, right?): return Data(left.utf8) == Data(right.utf8)
        default: return false
        }
    }

    private enum CodingKeys: String, CodingKey { case column, `operator`, value, sqliteValue, nativeValue }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        guard Set(fields.allKeys.map(\.stringValue)).isSubset(of: ["column", "operator", "value", "sqliteValue", "nativeValue"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown filter condition field."))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        column = try values.decode(String.self, forKey: .column)
        self.operator = try values.decode(String.self, forKey: .operator)
        value = try values.decodeIfPresent(String.self, forKey: .value)
        sqliteValue = nil
        nativeValue = nil
        if values.contains(.nativeValue) {
            guard !values.contains(.value), !values.contains(.sqliteValue) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Ambiguous native filter operands."))
            }
            nativeValue = try values.decode(NativeCellFilterValue.self, forKey: .nativeValue)
        }
        if values.contains(.sqliteValue) {
            guard !values.contains(.value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Ambiguous filter operands."))
            }
            let nested = try values.superDecoder(forKey: .sqliteValue).container(keyedBy: Key.self)
            guard Set(nested.allKeys.map(\.stringValue)).isSubset(of: ["type", "value"]) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown SQLite operand field."))
            }
            if let key = Key(stringValue: "value"), nested.contains(key) { _ = try nested.decode(String.self, forKey: key) }
            sqliteValue = try values.decode(SQLiteValue.self, forKey: .sqliteValue)
        }
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid filter operand."))
        }
    }
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
    var sqliteValues: [[SQLiteValue]]? = nil

    var valid: Bool {
        func validName(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 1_024 && !value.contains("\0") }
        guard [.postgresql, .mysql, .sqlite].contains(engine), (schema.isEmpty || validName(schema)), validName(table),
              !columns.isEmpty, columns.count <= Self.maximumColumns,
              !rows.isEmpty, rows.count <= Self.maximumRows,
              columns.count * rows.count <= Self.maximumCells,
              columns.allSatisfy({ validName($0.name) }), Set(columns.map { Data($0.name.utf8) }).count == columns.count else { return false }
        guard (sqliteValues == nil || engine == .sqlite),
              SQLiteValue.validMatrix(sqliteValues, rows: rows.count, columns: columns.count) else { return false }
        var bytes = (sqliteValues?.joined().reduce(0) { $0 + $1.value.utf8.count } ?? 0) + schema.utf8.count + table.utf8.count + columns.reduce(0) { $0 + $1.name.utf8.count }
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
    var sqliteValues: [[SQLiteValue]]?
    var nativeValues: [[NativeValue]]? = nil
    var storageTokens: [String]?
    var source: SQLResultSource?

    static func validCursor(_ value: String) -> Bool { BackendMessage.validID(value) && !value.contains("\0") }

    func valid(streamed: Bool = false) -> Bool {
        (nextCursor == nil || Self.validCursor(nextCursor!)) && rowCount >= 0 && displayedRowCount >= 0 &&
            Self.validStorageTokens(storageTokens, rowCount: displayedRowCount) &&
            SQLiteValue.validMatrix(sqliteValues, rows: displayedRowCount, columns: columns.count) &&
            NativeValue.validMatrix(nativeValues, rows: displayedRowCount, columns: columns.count) &&
            (!columns.contains(where: { $0.engine == .sqlite }) || NativeValue.matchesSQLite(nativeValues, storage: sqliteValues)) &&
            (source?.valid(for: columns) ?? true) &&
            (streamed ? rows.isEmpty : displayedRowCount == rows.count) &&
            columns.enumerated().allSatisfy { $0.offset == $0.element.index &&
                ($0.element.encoding == nil || $0.element.encoding == "base64") } &&
            rows.allSatisfy { $0.count == columns.count }
    }

    static func validStorageTokens(_ tokens: [String]?, rowCount: Int) -> Bool {
        guard let tokens else { return true }
        return tokens.count == rowCount && tokens.count <= 1_000 && tokens.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 4_096 && !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r")
        }
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
    var catalogMetadata: CatalogMetadataPageRequest?
    var stream: Bool?
    var resultValues: String? = nil
    var export: ExportRequest?
    var sequence: Int?
    var changes: ChangesRequest?
    var operations: [OperationRequest]?
    var authorization: String?
    var sshTrust: SSHTrust?
    var insert: InsertFormatRequest?
    var comparison: ResultComparisonRequest?
    var schemaComparison: SchemaComparisonRequest?
    var dataComparison: DataComparisonRequest?
    var explain: ExplainRequest?
    var structure: StructureRequest?
    var parameters: [QueryParameterBinding]?
    var tableImport: TableImportRequest?
    var databaseTools: DatabaseToolsRequest?
    var transfer: DataTransferRequest?
    var schemaObservation: SchemaObservationRequest?
    var nativeCommand: NativeCommand? = nil

    static func hello() -> Self {
        Self(type: "hello", requestId: UUID().uuidString, protocolVersion: BackendProtocol.version)
    }

    static func sshProbe(_ connection: ConnectionSettings) -> Self {
        Self(type: "ssh.probe", requestId: UUID().uuidString, connection: connection)
    }

    static func sshTrust(_ connection: ConnectionSettings, token: String, replace: Bool = false) -> Self {
        Self(type: "ssh.trust", requestId: UUID().uuidString, connection: connection, sshTrust: SSHTrust(token: token, replace: replace ? true : nil))
    }

    static func sqliteCreate(_ connection: ConnectionSettings) -> Self {
        Self(type: "sqlite.create", requestId: UUID().uuidString, connection: connection)
    }

    static func connect(_ connection: ConnectionSettings) -> Self {
        Self(type: "connect", requestId: UUID().uuidString, connection: connection)
    }

    static func execute(sessionId: String, queryId: String = UUID().uuidString, sql: String,
                        parameters: [QueryParameterBinding]? = nil) -> Self {
        Self(type: "execute", requestId: UUID().uuidString, sessionId: sessionId, queryId: queryId, sql: sql, stream: true,
            parameters: parameters)
    }

    static func executeCommand(sessionId: String, queryId: String = UUID().uuidString, command: NativeCommand) -> Self {
        Self(type: "command.execute", requestId: UUID().uuidString, sessionId: sessionId, queryId: queryId,
            resultValues: NativeValue.format, nativeCommand: command)
    }

    static func catalog(sessionId: String, queryId: String = UUID().uuidString, request: CatalogRequest) -> Self {
        Self(type: "catalog", requestId: UUID().uuidString, sessionId: sessionId, queryId: queryId, catalog: request, stream: true)
    }

    static func runToFile(sessionId: String, queryId: String = UUID().uuidString, sql: String, export: ExportRequest,
                          parameters: [QueryParameterBinding]? = nil) -> Self {
        Self(type: "execute", requestId: UUID().uuidString, sessionId: sessionId, queryId: queryId, sql: sql, stream: true, export: export,
            parameters: parameters)
    }

    static func previewChanges(sessionId: String, queryId: String = UUID().uuidString, request: ChangesRequest) -> Self {
        Self(type: "changes.preview", requestId: UUID().uuidString, sessionId: sessionId, queryId: queryId, changes: request)
    }

    static func applyChanges(sessionId: String, queryId: String = UUID().uuidString, request: ChangesRequest) -> Self {
        Self(type: "changes.apply", requestId: UUID().uuidString, sessionId: sessionId, queryId: queryId, changes: request)
    }

    static func explain(sessionId: String, queryId: String = UUID().uuidString, request: ExplainRequest) -> Self {
        Self(type: "explain.run", requestId: UUID().uuidString, sessionId: sessionId, queryId: queryId, explain: request)
    }

    static func monitorSnapshot(sessionId: String, queryId: String = UUID().uuidString) -> Self {
        Self(type: "monitor.snapshot", requestId: UUID().uuidString, sessionId: sessionId, queryId: queryId)
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

    static func compare(_ operation: String, _ request: ResultComparisonRequest) -> Self {
        Self(type: "compare." + operation, requestId: UUID().uuidString, comparison: request)
    }

    static func compareData(_ operation: String, _ request: DataComparisonRequest) -> Self {
        Self(type: "data." + operation, requestId: UUID().uuidString, dataComparison: request)
    }

    static func compareSchema(_ operation: String, _ request: SchemaComparisonRequest) -> Self {
        Self(type: "schema." + operation, requestId: UUID().uuidString, schemaComparison: request)
    }

    static func databaseTools(_ operation: String, _ request: DatabaseToolsRequest) -> Self {
        Self(type: "dbtools." + operation, requestId: UUID().uuidString, databaseTools: request)
    }

    static func dataTransfer(_ operation: String, _ request: DataTransferRequest) -> Self {
        Self(type: "transfer." + operation, requestId: UUID().uuidString, transfer: request)
    }

    static func assess(sessionId: String, operations: [OperationRequest]) -> Self {
        Self(type: "operation.assess", requestId: UUID().uuidString, sessionId: sessionId,
            queryId: UUID().uuidString, operations: operations)
    }

    static func tableImport(_ operation: String, sessionId: String, queryId: String = UUID().uuidString,
                            request: TableImportRequest) -> Self {
        Self(type: "import." + operation, requestId: UUID().uuidString, sessionId: sessionId,
            queryId: queryId, tableImport: request)
    }

    var terminalType: String? {
        switch type {
        case "hello": "hello.ack"
        case "ssh.probe": "ssh.probe.result"
        case "ssh.trust": "ssh.trust.result"
        case "connect": "connect.result"
        case "sqlite.create": "sqlite.create.result"
        case "execute", "command.execute", "catalog", "changes.preview", "changes.apply": "query.result"
        case "catalog.page", "catalog.batch", "catalog.close": type + ".result"
        case "explain.run": "explain.result"
        case "monitor.snapshot": "monitor.result"
        case "monitor.schema": "monitor.schema.result"
        case "structure.load", "structure.preview", "structure.validate", "structure.apply", "structure.status", "structure.close",
             "structure.physical.inspect", "structure.physical.preview", "structure.physical.apply", "structure.physical.status", "structure.physical.reconcile", "structure.physical.close", "structure.migration.preview", "structure.migration.apply", "structure.migration.export", "structure.migration.status", "structure.migration.reconcile", "structure.migration.close": type + ".result"
        case "import.describe", "import.preview", "import.apply": type + ".result"
        case "cancel": "cancel.ack"
        case "disconnect": "disconnect.ack"
        case "shutdown": "shutdown.ack"
        case "operation.assess": "operation.assessment"
        case "formatInserts": "insertSQL"
        case "data.describe", "data.start", "data.status", "data.page", "data.value", "data.diff", "data.plan", "data.cancel", "data.close": type + ".result"
        case "schema.import.start", "schema.import.status", "schema.import.cancel", "schema.import.close", "schema.bundle.start", "schema.bundle.status", "schema.bundle.export", "schema.bundle.cancel", "schema.bundle.close", "schema.start", "schema.status", "schema.page", "schema.value", "schema.diff", "schema.plan", "schema.export", "schema.cancel", "schema.close": type + ".result"
        case "compare.start", "compare.status", "compare.page", "compare.value", "compare.cancel", "compare.close": type + ".result"
        case "dbtools.preview", "dbtools.start", "dbtools.status", "dbtools.cancel", "dbtools.close": type + ".result"
        case "transfer.describe", "transfer.preview", "transfer.apply", "transfer.status", "transfer.cancel", "transfer.close": type + ".result"
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
    let typeIdentity: String?
    let typeOid: UInt32
    let encoding: String?

    init(index: Int, name: String, typeOid: UInt32 = 0, engine: DatabaseEngine = .postgresql,
         nativeType: String = "", encoding: String? = nil, typeIdentity: String? = nil) {
        self.index = index
        self.name = name
        self.engine = engine
        self.nativeType = nativeType
        self.typeIdentity = typeIdentity
        self.typeOid = typeOid
        self.encoding = encoding
    }

    private enum CodingKeys: String, CodingKey { case index, name, engine, nativeType, typeOid, encoding, typeIdentity }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        index = try values.decode(Int.self, forKey: .index)
        name = try values.decode(String.self, forKey: .name)
        engine = try values.decodeIfPresent(DatabaseEngine.self, forKey: .engine) ?? .postgresql
        nativeType = try values.decodeIfPresent(String.self, forKey: .nativeType) ?? ""
        typeIdentity = try values.decodeIfPresent(String.self, forKey: .typeIdentity)
        typeOid = try values.decodeIfPresent(UInt32.self, forKey: .typeOid) ?? 0
        encoding = try values.decodeIfPresent(String.self, forKey: .encoding)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(index, forKey: .index)
        try values.encode(name, forKey: .name)
        try values.encode(engine, forKey: .engine)
        try values.encode(nativeType, forKey: .nativeType)
        try values.encodeIfPresent(typeIdentity, forKey: .typeIdentity)
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
    var sqliteValues: [[SQLiteValue]]?
    var nativeValues: [[NativeValue]]? = nil
    var storageTokens: [String]?
    var source: SQLResultSource?
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
    @OptionalTransportPayload var comparison: ResultComparisonResponse? = nil
    @OptionalTransportPayload var schemaComparison: SchemaComparisonResponse? = nil
    @OptionalTransportPayload var dataComparison: DataComparisonResponse? = nil
    @OptionalTransportPayload var explain: ExplainResult? = nil
    @OptionalTransportPayload var explainDML: ExplainDMLResult? = nil
    @OptionalTransportPayload var explainSupport: ExplainSupport? = nil
    @OptionalTransportPayload var catalogMetadata: CatalogMetadataReply? = nil
    @OptionalTransportPayload var operationSupport: OperationSupport? = nil
    var structure: StructureReply?
    var tableImport: TableImportReply?
    var monitor: SessionMonitorSnapshot?
    @OptionalTransportPayload var schemaObservation: SchemaObservation? = nil
    var databaseTools: DatabaseToolsReply?
    var transfer: DataTransferReply?

    func validate() throws {
        // Keep phase frames separate from receive/hydrate on the worker stack.
        try validateTransportValues()
        try validateOperationSupport()
        let valid = validMessageShape()
        try validateProductPayloadPlacement()
        try validateSQLCompletion(valid: valid)
    }

    @inline(never)
    private func validateTransportValues() throws {
        guard Self.validID(requestId) else { throw BackendTransportError(.invalidMessage) }
        if let sessionId, !Self.validID(sessionId) { throw BackendTransportError(.invalidMessage) }
        if let queryId, !Self.validID(queryId) { throw BackendTransportError(.invalidMessage) }
        if let nextCursor, !QueryResultSet.validCursor(nextCursor) { throw BackendTransportError(.invalidMessage) }
        if storageTokens != nil && (type != "query.result" || !QueryResultSet.validStorageTokens(storageTokens, rowCount: displayedRowCount ?? -1)) {
            throw BackendTransportError(.invalidMessage)
        }
        if let appliedChangeCount, !(0...1000).contains(appliedChangeCount) || !["query.result", "error"].contains(type) {
            throw BackendTransportError(.invalidMessage)
        }
        if let sqliteValues {
            let typedColumns = streamed == true ? resultSets?.first?.columns.count ?? 0 : columns?.count ?? 0
            guard type == "query.result", SQLiteValue.validMatrix(sqliteValues, rows: displayedRowCount ?? -1, columns: typedColumns) else { throw BackendTransportError(.invalidMessage) }
        }
        if let nativeValues {
            let width = columns?.count ?? rows?.first?.count ?? 0
            guard ["query.result", "query.chunk"].contains(type), streamed != true,
                  NativeValue.validMatrix(nativeValues, rows: rows?.count ?? -1, columns: width),
                  type != "query.result" || columns?.contains(where: { $0.engine == .sqlite }) != true ||
                    NativeValue.matchesSQLite(nativeValues, storage: sqliteValues) else { throw BackendTransportError(.invalidMessage) }
        }
        let sourceColumns = streamed == true
            ? (resultSets?.first(where: { !$0.columns.isEmpty })?.columns ?? columns ?? []) : (columns ?? [])
        if let source, type != "query.result" || !source.valid(for: sourceColumns) {
            throw BackendTransportError(.invalidMessage)
        }
    }

    @inline(never)
    private func validateOperationSupport() throws {
        if let operationSupport {
            guard operationSupport.valid,
                  type == "connect.result" ? operationSupport.scope == .session && operationSupport.engine == engine :
                    type.hasPrefix("structure.") && operationSupport.scope == .structure &&
                    (structure?.baseline.map { $0.engine == operationSupport.engine.rawValue } ?? true) else {
                throw BackendTransportError(.invalidMessage)
            }
        }
    }

    @inline(never)
    private func validMessageShape() -> Bool {
        switch type {
        case "import.describe.result", "import.preview.result", "import.apply.result":
            return validStructuralMessageShape()
        case "structure.load.result", "structure.preview.result", "structure.validate.result", "structure.apply.result", "structure.status.result", "structure.close.result",
             "structure.physical.inspect.result", "structure.physical.preview.result", "structure.physical.apply.result", "structure.physical.status.result", "structure.physical.reconcile.result", "structure.physical.close.result", "structure.migration.preview.result", "structure.migration.apply.result", "structure.migration.export.result", "structure.migration.status.result", "structure.migration.reconcile.result", "structure.migration.close.result":
            return validStructuralMessageShape()
        case "query.progress":
            return validSQLMessageShape()
        case "explain.result":
            return validSQLMessageShape()
        case "query.started":
            return validSQLMessageShape()
        case "query.chunk":
            return validSQLMessageShape()
        case "query.result":
            return validSQLMessageShape()
        case "error":
            return validSQLMessageShape()
        default: return validServiceMessageShape()
        }
    }

    @inline(never)
    private func validStructuralMessageShape() -> Bool {
        switch type {
        case "import.describe.result", "import.preview.result", "import.apply.result":
            return sessionId != nil && queryId != nil && connected == true && transactionStatus == .idle &&
                columns == nil && rows == nil && resultSets == nil && streamed == nil && source == nil &&
                tableImport?.valid(for: type) == true && (durationMs.map { $0.isFinite && $0 >= 0 } ?? true)
        case "structure.load.result", "structure.preview.result", "structure.validate.result", "structure.apply.result", "structure.status.result", "structure.close.result",
             "structure.physical.inspect.result", "structure.physical.preview.result", "structure.physical.apply.result", "structure.physical.status.result", "structure.physical.reconcile.result", "structure.physical.close.result", "structure.migration.preview.result", "structure.migration.apply.result", "structure.migration.export.result", "structure.migration.status.result", "structure.migration.reconcile.result", "structure.migration.close.result":
            return sessionId != nil && queryId != nil && connected != nil &&
                (transactionStatus != nil || connected == false) && columns == nil && rows == nil &&
                resultSets == nil && streamed == nil && source == nil && structure?.valid(for: type) == true
        default: return false
        }
    }

    @inline(never)
    private func validSQLMessageShape() -> Bool {
        switch type {
        case "query.progress": return (sequence ?? 0) > 0 && sessionId != nil && queryId != nil && (resultIndex ?? -1) >= 0 && (rowCount ?? -1) >= 0
        case "explain.result":
            return sessionId != nil && queryId != nil && transactionStatus != nil && sqlCompleted == true &&
                durationMs.map { $0.isFinite && $0 >= 0 } == true && explain?.valid == true &&
                columns == nil && rows == nil && resultSets == nil && streamed == nil && source == nil
        case "query.started": return sessionId != nil && queryId != nil
        case "query.chunk":
            return sessionId != nil && queryId != nil && (sequence ?? 0) > 0 &&
                (resultIndex ?? -1) >= 0 && (resultIndex ?? 1_024) < 1_024 && rows != nil &&
                (columns?.enumerated().allSatisfy { $0.offset == $0.element.index &&
                    ($0.element.encoding == nil || $0.element.encoding == "base64") } ?? true)
        case "query.result":
            if let columns, let rows, let durationMs, let rowCount, let displayedRowCount {
                return sessionId != nil && queryId != nil && transactionStatus != nil &&
                    durationMs.isFinite && durationMs >= 0 && rowCount >= 0 &&
                    (streamed == true ? (rows.isEmpty && displayedRowCount >= 0) : displayedRowCount == rows.count) && truncated != nil && commandTag != nil &&
                    columns.enumerated().allSatisfy { $0.offset == $0.element.index &&
                        ($0.element.encoding == nil || $0.element.encoding == "base64") } &&
                    rows.allSatisfy { $0.count == columns.count } &&
                    (resultSets?.allSatisfy { $0.valid(streamed: streamed == true) } ?? true)
            } else { return false }
        case "error":
            return category != nil && message != nil && connected != nil && outcomeUnknown != nil &&
                (errorPosition == nil || errorPosition! > 0)
                && (resultSets?.allSatisfy { $0.valid(streamed: streamed == true) } ?? true)
        default: return false
        }
    }

    @inline(never)
    private func validServiceMessageShape() -> Bool {
        switch type {
        case "hello.ack": return protocolVersion != nil
        case "dbtools.preview.result", "dbtools.start.result", "dbtools.status.result", "dbtools.cancel.result", "dbtools.close.result":
            return sessionId == nil && queryId == nil && columns == nil && rows == nil && resultSets == nil &&
                streamed == nil && source == nil && databaseTools?.valid(for: type) == true
        case "transfer.describe.result", "transfer.preview.result", "transfer.apply.result", "transfer.status.result", "transfer.cancel.result", "transfer.close.result":
            return sessionId == nil && queryId == nil && columns == nil && rows == nil && resultSets == nil &&
                streamed == nil && source == nil && transfer?.valid == true
        case "sqlite.create.result": return sessionId == nil && queryId == nil
        case "data.describe.result", "data.start.result", "data.status.result", "data.page.result", "data.value.result", "data.diff.result", "data.plan.result", "data.cancel.result", "data.close.result":
            return sessionId == nil && queryId == nil && columns == nil && rows == nil && resultSets == nil && dataComparison?.valid(for: type) == true
        case "schema.import.start.result", "schema.import.status.result", "schema.import.cancel.result", "schema.import.close.result", "schema.bundle.start.result", "schema.bundle.status.result", "schema.bundle.export.result", "schema.bundle.cancel.result", "schema.bundle.close.result", "schema.start.result", "schema.status.result", "schema.page.result", "schema.value.result", "schema.diff.result", "schema.plan.result", "schema.export.result", "schema.cancel.result", "schema.close.result":
            return sessionId == nil && queryId == nil && columns == nil && rows == nil && resultSets == nil && schemaComparison?.valid(for: type) == true
        case "compare.start.result", "compare.status.result", "compare.page.result", "compare.value.result", "compare.cancel.result", "compare.close.result":
            return sessionId == nil && queryId == nil && columns == nil && rows == nil && resultSets == nil &&
                comparison?.valid(for: type) == true
        case "insertSQL":
            return sessionId == nil && queryId == nil && sql?.isEmpty == false &&
                (sql?.utf8.count ?? Int.max) <= InsertFormatRequest.maximumBytes && sql?.contains("\0") == false
        case "operation.assessment": return sessionId != nil && queryId != nil && assessment?.valid == true
        case "ssh.probe.result", "ssh.trust.result": return ssh?.isValid == true
        case "connect.result": return sessionId != nil && transactionStatus != nil && engine != nil && capabilities != nil
        case "catalog.page.result", "catalog.batch.result", "catalog.close.result":
            return sessionId != nil && queryId != nil && connected == true && transactionStatus == .idle &&
                catalogMetadata?.valid == true && columns == nil && rows == nil && resultSets == nil && streamed == nil && source == nil &&
                (type == "catalog.close.result" ? catalogMetadata?.closed == true : catalogMetadata?.closed != true)
        case "monitor.schema.result":
            return sessionId != nil && queryId != nil && connected == true && transactionStatus == .idle &&
                schemaObservation?.valid == true && columns == nil && rows == nil && resultSets == nil && streamed == nil && source == nil
        case "monitor.result":
            return sessionId != nil && queryId != nil && connected == true && transactionStatus == .idle &&
                monitor?.valid == true && columns == nil && rows == nil && resultSets == nil && streamed == nil && source == nil
        case "cancel.ack":
            return sessionId != nil && queryId != nil && ["accepted", "alreadyFinished"].contains(status)
        case "disconnect.ack": return sessionId != nil
        case "shutdown.ack": return true
        default: return false
        }
    }

    @inline(never)
    private func validateProductPayloadPlacement() throws {
        guard tableImport == nil || (type.hasPrefix("import.") || type == "error") && tableImport?.valid(for: type) == true,
              databaseTools == nil || type.hasPrefix("dbtools."),
              transfer == nil || type.hasPrefix("transfer."),
              monitor == nil || type == "monitor.result",
              !_schemaObservation.isPresent || type == "monitor.schema.result",
              !_catalogMetadata.isPresent || ["catalog.page.result", "catalog.batch.result", "catalog.close.result"].contains(type),
              structure == nil || type.hasPrefix("structure."),
              !_explain.isPresent || type == "explain.result",
              validExplainDMLErrorEnvelope,
              !_explainSupport.isPresent || type == "connect.result" && explainSupport?.valid == true && explainSupport?.engine == engine,
              !_dataComparison.isPresent || type.hasPrefix("data."),
              !_schemaComparison.isPresent || type.hasPrefix("schema."),
              !_comparison.isPresent || type.hasPrefix("compare.") else { throw BackendTransportError(.invalidMessage) }
    }

    @inline(never)
    private func validateSQLCompletion(valid: Bool) throws {
        guard sql == nil || (type == "insertSQL" || type == "query.result") &&
                sql?.isEmpty == false && (sql?.utf8.count ?? Int.max) <= BackendProtocol.maxFrameBytes / 2 &&
                sql?.contains("\0") == false,
              sqlNotExecuted != true || (type == "error" && outcomeUnknown != true && sqlCompleted != true),
              sqlCompleted != true || ((type == "error" || type == "explain.result") &&
                (outcomeUnknown != true || permitsExplainDMLUnknownCompletion)),
              exportPublication == nil || ((sqlCompleted == true || sqlNotExecuted == true) && ["notPublished", "unknown"].contains(exportPublication)), valid else { throw BackendTransportError(.invalidMessage) }
    }

    private var permitsExplainDMLUnknownCompletion: Bool {
        guard type == "error", let dml = explainDML, dml.execution == "completed" else { return false }
        return dml.persistence == "unknown" || dml.targetExecution == "suppressed" &&
            dml.persistence == "notExecuted" && dml.transactionAfter == "unknown"
    }

    private var validExplainDMLErrorEnvelope: Bool {
        guard _explainDML.isPresent else { return true }
        guard type == "error", let dml = explainDML,
              columns == nil, rows == nil, resultSets == nil, streamed == nil, source == nil, tableImport == nil,
              exportPublication == nil, exportPath == nil, exportFormat == nil, exportRowCount == nil,
              [DatabaseEngine.postgresql, .mysql].contains(where: { dml.valid(engine: $0, mode: .analyze) }),
              (dml.transactionAfter == "unknown" ? transactionStatus == nil :
                transactionStatus?.rawValue == dml.transactionAfter || connected == false && transactionStatus == nil) else { return false }
        switch dml.execution {
        case "completed": return sqlCompleted == true && (outcomeUnknown == true) == permitsExplainDMLUnknownCompletion
        case "notExecuted": return sqlNotExecuted == true
        case "unknown": return sqlCompleted != true && sqlNotExecuted != true && outcomeUnknown == true
        default: return sqlCompleted != true && sqlNotExecuted != true
        }
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
        case unsupportedResultComparison
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
        case .unsupportedResultComparison: explanation = "The helper does not support result snapshot comparison. Rebuild the matching app and helper."
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
        try SchemaBundleSummary.validateFrame(frame)
        try SchemaBundleSourceFrame.validate(frame)
        try reply.validate()
        return reply
    }
}

private struct RelationshipSelectorCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
