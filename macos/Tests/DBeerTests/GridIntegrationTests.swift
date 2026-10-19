import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct GridIntegrationTests {
    private final class CloseDecision { var value = WorkspaceCloseDecision.cancel }
    private var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresNativeGridAppliesTypedChangesAndKeepsConflictsLocal() async throws {
        try await exercise(engine: .postgresql)
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlNativeGridAppliesTypedChangesAndKeepsConflictsLocal() async throws {
        try await exercise(engine: .mysql)
    }

    private func exercise(engine: DatabaseEngine) async throws {
        let decision = CloseDecision()
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: { _ in decision.value },
            helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        let settings = try settings(engine)
        try #require(await workspace.library.saveConnection(name: engine.rawValue, settings: settings))
        let profile = try #require(workspace.library.selectedConnectionId)
        let name = "dbeer_grid_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let schema = engine == .postgresql ? "public" : settings.database
        let sql = workspace.newDocument(profileID: profile)
        let binary = engine == .postgresql ? "bytea" : "blob"
        let generated = engine == .postgresql ? "integer GENERATED ALWAYS AS (tenant + 10) STORED" : "integer GENERATED ALWAYS AS (tenant + 10) STORED"
        await workspace.run(sql, sql: "CREATE TABLE \(name) (tenant integer, code varchar(32), label varchar(200) DEFAULT 'fallback', amount decimal(30,10), payload \(binary), computed \(generated), PRIMARY KEY (tenant, code), CHECK (amount >= 0))")
        try #require(sql.runtime?.queryFailure == nil)
        await workspace.run(sql, sql: "INSERT INTO \(name) (tenant,code,label,amount) VALUES (1,'a','original',1.25),(1,'b','other',2.5)")
        try #require(sql.runtime?.queryFailure == nil)
        let node = CatalogNode(profileID: profile, name: name, kind: .object,
            schema: schema, object: name, objectKind: "table")
        await workspace.openData(node)
        let document = try #require(workspace.selectedDocument)
        let grid = try #require(document.grid)
        try #require(grid.canEdit && grid.rows.count == 2)
        #expect(!grid.editableColumns.contains(5))
        grid.set(ChangeValue(kind: "text", value: ""), row: 0, column: 2)
        grid.set(ChangeValue(kind: "text", value: "12345678901234567890.1234567890"), row: 0, column: 3)
        grid.set(ChangeValue(kind: "binary", value: "AP8="), row: 0, column: 4)
        await workspace.previewGrid(document)
        #expect(grid.preview?.catalogRecords.first?["sql"]?.contains(engine == .postgresql ? "$1" : "?") == true)
        await workspace.run(sql, sql: "SELECT label FROM \(name) WHERE tenant=1 AND code='a'")
        #expect(sql.runtime?.result?.rows == [["original"]])
        await workspace.run(sql, sql: engine == .postgresql ? "BEGIN" : "START TRANSACTION")
        try #require(sql.runtime?.transactionStatus == .transaction)
        #expect(await workspace.applyGrid(document))
        #expect(sql.runtime?.transactionStatus == .transaction)
        let applied = try #require(document.grid)
        #expect(applied.rows[0].values[2] == ChangeValue(kind: "text", value: ""))
        #expect(applied.rows[0].values[3].value == "12345678901234567890.1234567890")
        #expect(applied.rows[0].values[4] == ChangeValue(kind: "binary", value: "AP8="))
        await workspace.run(sql, sql: "ROLLBACK")

        // An external write conflicts with the original full-row snapshot.
        applied.set(.null, row: 0, column: 2)
        await workspace.run(sql, sql: "UPDATE \(name) SET label='external' WHERE tenant=1 AND code='a'")
        #expect(!(await workspace.applyGrid(document)))
        #expect(document.grid === applied)
        #expect(applied.pendingCount == 1 && !applied.outcomeUnknown)
        #expect(applied.error != nil)
        await workspace.closeDocument(document)
        #expect(workspace.documents.contains { $0.id == document.id })
        await workspace.discardGrid(document)
        let fresh = try #require(document.grid)
        #expect(fresh.rows[0].values[2].value == "external")

        // A late constraint failure rolls back preceding edits in the batch.
        fresh.set(ChangeValue(kind: "text", value: "rolled back"), row: 0, column: 2)
        fresh.set(ChangeValue(kind: "text", value: "-1"), row: 1, column: 3)
        #expect(!(await workspace.applyGrid(document)))
        #expect(fresh.pendingCount == 2)
        await workspace.run(sql, sql: "SELECT label FROM \(name) WHERE tenant=1 AND code='a'")
        #expect(sql.runtime?.result?.rows == [["external"]])
        await workspace.discardGrid(document)
        let insert = try #require(document.grid)
        insert.insert()
        insert.set(ChangeValue(kind: "text", value: "2"), row: 2, column: 0)
        insert.set(ChangeValue(kind: "text", value: "c"), row: 2, column: 1)
        insert.set(.null, row: 2, column: 3)
        #expect(await workspace.applyGrid(document))
        let inserted = try #require(document.grid)
        #expect(inserted.rows[2].values[2].value == "fallback")
        #expect(inserted.rows[2].values[3] == .null)
        #expect(inserted.rows[2].values[5].value == "12")
        inserted.selectedRows = IndexSet(integer: 2)
        inserted.deleteSelected()
        try capture(workspace, engine: engine)
        decision.value = .apply
        await workspace.closeDocument(document)
        #expect(!workspace.documents.contains { $0.id == document.id })
        await workspace.run(sql, sql: "SELECT count(*) FROM \(name)")
        #expect(sql.runtime?.result?.rows == [["2"]])
        await workspace.run(sql, sql: "DROP TABLE \(name)")
        try #require(sql.runtime?.queryFailure == nil)
        await workspace.shutdown()
    }

    private func settings(_ engine: DatabaseEngine) throws -> ConnectionSettings {
        let env = ProcessInfo.processInfo.environment
        if engine == .mysql {
            return ConnectionSettings(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
                port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")),
                database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: env["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
                password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: "disable", engine: .mysql)
        }
        let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
        return ConnectionSettings(host: try #require(url.host), port: url.port ?? 5432,
            database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
    }

    private func capture(_ workspace: ApplicationWorkspace, engine: DatabaseEngine) throws {
        guard let output = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        _ = NSApplication.shared
        let content = NSHostingView(rootView: ApplicationWorkspaceView(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 850),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFront(nil)
        defer { window.close() }
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("m5-grid-\(engine.rawValue).png"))
    }
}
