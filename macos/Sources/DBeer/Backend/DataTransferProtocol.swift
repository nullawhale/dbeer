import Foundation

struct DataTransferEndpoint: Codable, Equatable, Sendable {
    var connection: ConnectionSettings
    var schema: String
    var table: String
    var valid: Bool {
        [.postgresql, .mysql, .mariadb].contains(connection.engine) && connection.sessionPurpose == nil &&
        DataTransferColumn.validName(schema) && DataTransferColumn.validName(table)
    }
}
struct DataTransferColumn: Codable, Equatable, Sendable, Identifiable {
    var sourceIndex: Int
    var name: String
    var type: String
    var nullable: Bool
    var precision: Int?
    var scale: Int?
    var id: Int { sourceIndex }
    static let types = ["text", "integer", "decimal", "real", "boolean", "date", "timestamp", "timestampTZ", "json", "binary"]
    static func validName(_ name: String) -> Bool { !name.isEmpty && validText(name, limit: 1_024) }
    static func validText(_ text: String, limit: Int) -> Bool { text.utf8.count <= limit && !text.contains("\0") }
    var valid: Bool {
        guard (0..<256).contains(sourceIndex), Self.validName(name), Self.types.contains(type) else { return false }
        if type == "decimal" {
            guard let precision, (1...1_000).contains(precision) else { return false }
            return (0...precision).contains(scale ?? 0)
        }
        return (precision ?? 0) == 0 && (scale ?? 0) == 0
    }
}
struct DataTransferDiagnostic: Codable, Equatable, Sendable {
    var row: Int
    var column: Int
    var message: String
}
struct DataTransferRequest: Codable, Equatable, Sendable {
    var mode: String?
    var source: DataTransferEndpoint?
    var target: DataTransferEndpoint?
    var headers: [String]?
    var rows: [[ChangeValue]]?
    var columns: [DataTransferColumn]?
    var jobId: String?
    var planDigest: String?
    var sourceDigest: String?
    var confirmed: Bool?
    var transportConnections: [ConnectionSettings] { [source?.connection, target?.connection].compactMap { $0 } }
    static func validDigest(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func valid(for kind: String) -> Bool {
        if ["transfer.status", "transfer.cancel", "transfer.close", "transfer.apply"].contains(kind) {
            guard jobId.map(BackendMessage.validID) == true, mode == nil, source == nil, target == nil,
                  headers == nil, rows == nil, columns == nil, sourceDigest == nil else { return false }
            return kind == "transfer.apply" ? Self.validDigest(planDigest) && confirmed == true : planDigest == nil && confirmed == nil
        }
        guard ["transfer.describe", "transfer.preview"].contains(kind), jobId == nil, planDigest == nil,
              confirmed == nil, target?.valid == true else { return false }
        let width: Int
        if mode == "csv" {
            guard source == nil, sourceDigest == nil, let headers, let rows,
                  (1...256).contains(headers.count), headers.allSatisfy({ DataTransferColumn.validText($0, limit: 1_024) }),
                  (0...10_000).contains(rows.count) else { return false }
            width = headers.count
            var size = 0
            for row in rows {
                guard row.count == width else { return false }
                for cell in row {
                    guard ["text", "binary", "null"].contains(cell.kind), cell.kind == "null" ? cell.value == nil : cell.value != nil else { return false }
                    if let value = cell.value {
                        size += value.utf8.count
                        guard size <= 4 * 1_024 * 1_024, DataTransferColumn.validText(value, limit: 4 * 1_024 * 1_024) else { return false }
                        if cell.kind == "binary", Data(base64Encoded: value)?.base64EncodedString() != value { return false }
                    }
                }
            }
        } else if mode == "table" {
            guard source?.valid == true, headers == nil, rows == nil,
                  kind == "transfer.preview" ? Self.validDigest(sourceDigest) : sourceDigest == nil else { return false }
            width = 256
        } else { return false }
        if kind == "transfer.describe" { return columns == nil }
        guard let columns, (1...256).contains(columns.count), columns.allSatisfy({ $0.valid && $0.sourceIndex < width }),
              Set(columns.map(\.sourceIndex)).count == columns.count,
              Set(columns.map { Data($0.name.utf8) }).count == columns.count else { return false }
        return true
    }
}
struct DataTransferReply: Codable, Equatable, Sendable {
    var jobId: String
    var state: String
    var phase: String
    var code: String?
    var message: String?
    var columns: [DataTransferColumn]?
    var diagnostics: [DataTransferDiagnostic]?
    var sql: String?
    var planDigest: String?
    var sourceDigest: String?
    var rowsRead: Int64
    var rowsWritten: Int64
    var notices: [String]
    var tableCreated: Bool
    var outcomeUnknown: Bool
    var valid: Bool {
        guard BackendMessage.validID(jobId), ["pending", "running", "described", "ready", "completed", "failed", "cancelled", "outcomeUnknown", "closed"].contains(state),
              DataTransferColumn.validText(phase, limit: 128),
              rowsRead >= 0, rowsWritten >= 0, rowsWritten <= rowsRead, (columns?.count ?? 0) <= 256,
              columns?.allSatisfy(\.valid) != false, (diagnostics?.count ?? 0) <= 100,
              notices.count <= 32, notices.allSatisfy({ DataTransferColumn.validText($0, limit: 4_096) }),
              DataTransferColumn.validText(sql ?? "", limit: 1_024 * 1_024),
              DataTransferColumn.validText(message ?? "", limit: 4_096), DataTransferColumn.validText(code ?? "", limit: 128),
              diagnostics?.allSatisfy({ $0.row >= 0 && $0.column >= 0 && DataTransferColumn.validText($0.message, limit: 4_096) }) != false,
              !outcomeUnknown || state == "outcomeUnknown" || state == "closed" else { return false }
        return state != "ready" || DataTransferRequest.validDigest(planDigest) && sql?.isEmpty == false && (diagnostics?.isEmpty ?? true)
    }
}
