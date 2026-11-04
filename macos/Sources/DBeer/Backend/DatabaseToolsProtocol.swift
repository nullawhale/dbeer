import Foundation

enum DatabaseToolsOperation: String, Codable, CaseIterable, Identifiable, Sendable {
    case dump, restore
    var id: String { rawValue }
    var title: String { self == .dump ? "Dump" : "Restore" }
}

enum DatabaseToolsFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case sql, custom, tar
    var id: String { rawValue }
    var title: String {
        switch self { case .sql: "SQL"; case .custom: "PostgreSQL custom archive"; case .tar: "PostgreSQL tar archive" }
    }
    var pathExtension: String { self == .sql ? "sql" : self == .tar ? "tar" : "dump" }
}

enum DatabaseToolsState: String, Codable, Sendable {
    case prepared, running, completed, failed, cancelled, partial, outcomeUnknown, closed
    var isWorking: Bool { self == .running }
    var isUncertain: Bool { self == .partial || self == .outcomeUnknown }
}

struct DatabaseToolsRequest: Codable, Equatable, Sendable {
    var connection: ConnectionSettings?
    var operation: String?
    var format: String?
    var path: String?
    var toolPath: String?
    var planId: String?
    var approvalToken: String?
    var jobId: String?
    var confirmed: Bool?

    static func text(_ value: String?, maximum: Int, required: Bool = false) -> Bool {
        guard let value else { return !required }
        return (!required || !value.isEmpty) && value.utf8.count <= maximum && !value.contains("\0")
    }
    static func absolutePath(_ value: String?) -> Bool {
        text(value, maximum: 4_096, required: true) && value?.hasPrefix("/") == true
    }
    func valid(for type: String) -> Bool {
        let noInput = connection == nil && operation == nil && format == nil && path == nil && toolPath == nil
        switch type {
        case "dbtools.preview":
            guard let connection, connection.sessionPurpose == nil, [.postgresql, .mysql].contains(connection.engine),
                  let operation, DatabaseToolsOperation(rawValue: operation) != nil,
                  let format, DatabaseToolsFormat(rawValue: format) != nil,
                  connection.engine != .mysql || format == "sql" else { return false }
            return Self.absolutePath(path) && Self.absolutePath(toolPath) && planId == nil && approvalToken == nil && jobId == nil && confirmed == nil
        case "dbtools.start":
            return noInput && planId.map(BackendMessage.validID) == true && approvalToken.map(BackendMessage.validID) == true && jobId == nil
        case "dbtools.status", "dbtools.cancel":
            return noInput && jobId.map(BackendMessage.validID) == true && planId == nil && approvalToken == nil && confirmed == nil
        case "dbtools.close":
            return noInput && approvalToken == nil && confirmed == nil &&
                ((jobId.map(BackendMessage.validID) == true && planId == nil) || (planId.map(BackendMessage.validID) == true && jobId == nil))
        default: return false
        }
    }
}

struct DatabaseToolsReply: Codable, Equatable, Sendable {
    var planId: String?
    var approvalToken: String?
    var jobId: String?
    var state: DatabaseToolsState
    var phase: String?
    var engine: DatabaseEngine?
    var operation: String?
    var format: String?
    var database: String?
    var path: String?
    var toolName: String?
    var toolVersion: String?
    var serverVersion: String?
    var message: String?
    var requiresConfirmation: Bool
    var outputPublished: Bool
    var warnings: [String]
    var bytesProcessed: Int64?
    var totalBytes: Int64?
    var exitCode: Int?

    func valid(for type: String) -> Bool {
        guard planId.map(BackendMessage.validID) != false, approvalToken.map(BackendMessage.validID) != false,
              jobId.map(BackendMessage.validID) != false,
              engine == nil || [.postgresql, .mysql].contains(engine!),
              operation == nil || DatabaseToolsOperation(rawValue: operation!) != nil,
              format == nil || DatabaseToolsFormat(rawValue: format!) != nil,
              DatabaseToolsRequest.text(phase, maximum: 128), DatabaseToolsRequest.text(database, maximum: 4_096),
              DatabaseToolsRequest.text(path, maximum: 4_096), DatabaseToolsRequest.text(toolName, maximum: 256),
              DatabaseToolsRequest.text(toolVersion, maximum: 256), DatabaseToolsRequest.text(serverVersion, maximum: 256),
              DatabaseToolsRequest.text(message, maximum: 2_048), warnings.count <= 16,
              warnings.allSatisfy({ DatabaseToolsRequest.text($0, maximum: 1_024, required: true) }),
              bytesProcessed.map({ $0 >= 0 }) != false, totalBytes.map({ $0 >= 0 }) != false,
              exitCode.map({ (0...255).contains($0) }) != false,
              !outputPublished || state == .completed && operation == "dump" else { return false }
        if let bytesProcessed, let totalBytes, bytesProcessed > totalBytes { return false }
        let summaryValid = engine != nil && operation != nil && format != nil && DatabaseToolsRequest.absolutePath(path) &&
            (engine != .mysql || format == "sql") &&
            DatabaseToolsRequest.text(database, maximum: 4_096, required: true) &&
            DatabaseToolsRequest.text(toolName, maximum: 256, required: true) &&
            DatabaseToolsRequest.text(toolVersion, maximum: 256, required: true) &&
            DatabaseToolsRequest.text(serverVersion, maximum: 256, required: true) &&
            requiresConfirmation == (operation == "restore") &&
            toolName == expectedToolName &&
            phase.map { ["ready", "starting", "dumping", "restoring", "publishing", "completed", "failed", "cancelled", "partial", "outcomeUnknown"].contains($0) } == true
        switch type {
        case "dbtools.preview.result":
            return state == .prepared && phase == "ready" && planId != nil && approvalToken != nil && jobId == nil && engine != nil &&
                summaryValid && !outputPublished
        case "dbtools.start.result", "dbtools.status.result", "dbtools.cancel.result":
            return jobId != nil && planId == nil && approvalToken == nil && state != .prepared && state != .closed && summaryValid &&
                (state == .running || phase == state.rawValue)
        case "dbtools.close.result": return state == .closed && phase == "closed" && (planId != nil) != (jobId != nil) && approvalToken == nil
        default: return false
        }
    }
    private var expectedToolName: String {
        if engine == .mysql { return operation == "dump" ? "mysqldump" : "mysql" }
        return operation == "dump" ? "pg_dump" : format == "sql" ? "psql" : "pg_restore"
    }
}
