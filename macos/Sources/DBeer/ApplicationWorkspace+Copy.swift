import AppKit
import Foundation

struct InsertCopyTarget: Sendable {
    var engine: DatabaseEngine
    var schema: String
    var table: String
    var columnNames: [String]

    func request(payload: ResultClipboardPayload) throws -> InsertFormatRequest {
        try ResultCopy.validate(payload)
        guard columnNames.count == payload.columns.count else { throw ResultCopyError.malformed }
        let request = InsertFormatRequest(engine: engine, schema: schema, table: table,
            columns: columnNames.map { InsertFormatColumn(name: $0) },
            rows: payload.values.map { row in row.map { ChangeValue(kind: $0.kind.rawValue, value: $0.value) } })
        guard request.valid else { throw ResultCopyError.malformed }
        return request
    }
}

/// A copy target refers to the captured loaded values, independently of sessions.
@MainActor
struct InsertCopySelection: Identifiable {
    let id = UUID()
    let payload: ResultClipboardPayload
    let engine: DatabaseEngine
    let schema: String
    let table: String
    let pasteboard: NSPasteboard

    func request(engine: DatabaseEngine, schema: String, table: String,
                 columnNames: [String]) throws -> InsertFormatRequest {
        try InsertCopyTarget(engine: engine, schema: schema, table: table, columnNames: columnNames)
            .request(payload: payload)
    }
}

extension ApplicationWorkspace {
    func beginInsertCopy(_ payload: ResultClipboardPayload, document: SQLDocument,
                         pasteboard: NSPasteboard) {
        guard canStartOperation(document), !document.isRunning, document.grid?.isApplying != true,
              insertCopySelection == nil else { return }
        let sourceEngine = payload.columns.first?.engine ?? .postgresql
        insertCopySelection = InsertCopySelection(payload: payload,
            engine: sourceEngine == .mysql ? .mysql : .postgresql,
            schema: document.table?.schema ?? "", table: document.table?.name ?? "", pasteboard: pasteboard)
    }

    /// Formatting uses only the helper's offline adapter entry point.
    func formatInsertCopy(_ request: InsertFormatRequest) async throws -> String {
        let client = try await ensureHelper()
        let reply = try await client.request(.formatInserts(request))
        guard reply.type == "insertSQL", let sql = reply.sql, !sql.isEmpty else {
            throw ResultCopyError.malformed
        }
        return sql
    }
}
