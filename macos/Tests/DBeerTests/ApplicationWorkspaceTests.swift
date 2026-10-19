import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct ApplicationWorkspaceTests {
    private var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
    }

    @Test func documentsKeepIndependentTextAndProfileBindings() async {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let first = workspace.newDocument(profileID: UUID(), text: "SELECT 'first';")
        let second = workspace.newDocument(profileID: UUID(), text: "SELECT 'second';")
        first.title = "Renamed"
        workspace.selectedDocumentID = first.id
        #expect(workspace.selectedDocument?.text == "SELECT 'first';")
        #expect(first.profileID != second.profileID)
        #expect(first.runtime == nil && second.runtime == nil)
        await workspace.closeDocument(first)
        #expect(workspace.selectedDocumentID == second.id)
        #expect(second.text == "SELECT 'second';")
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func nativeWorkspaceUsesIndependentSessionsAndProfileDisconnect() async throws {
        let settings = try postgresSettings()
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: { _ in .rollback },
            executionDecision: { _ in true }, helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        try #require(await workspace.library.saveConnection(name: "Primary", settings: settings))
        let profileID = try #require(workspace.library.selectedConnectionId)
        try #require(await workspace.library.saveConnection(name: "Independent profile", settings: settings))
        let otherID = try #require(workspace.library.selectedConnectionId)

        _ = NSApplication.shared
        let content = NSHostingView(rootView: ApplicationWorkspaceView(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFront(nil)
        defer { window.close() }

        let first = workspace.newDocument(profileID: profileID, text: "BEGIN")
        let second = workspace.newDocument(profileID: profileID, text: "SELECT 2")
        let third = workspace.newDocument(profileID: otherID, text: "SELECT 3")
        async let firstExecution: Void = workspace.run(first)
        async let secondExecution: Void = workspace.run(second)
        _ = await (firstExecution, secondExecution)
        await workspace.run(third)
        let firstRuntime = try #require(first.runtime)
        let secondRuntime = try #require(second.runtime)
        let thirdRuntime = try #require(third.runtime)
        #expect(firstRuntime.transactionStatus == .transaction)
        #expect(secondRuntime.transactionStatus == .idle)
        #expect(firstRuntime.sessionId != secondRuntime.sessionId)
        #expect(workspace.services[profileID]?.sessionId != firstRuntime.sessionId)
        try #require(thirdRuntime.result?.rows?.first?.first == "3")

        await workspace.run(first, sql: "CREATE TEMP TABLE dbeer_tab_session(value integer)")
        await workspace.run(second, sql: "SELECT * FROM dbeer_tab_session")
        #expect(secondRuntime.queryFailure?.sqlState == "42P01")
        #expect(firstRuntime.transactionStatus == .transaction)
        #expect(secondRuntime.transactionStatus == .idle)

        let secondSession = secondRuntime.sessionId
        let sleep = Task { await workspace.run(second, sql: "SELECT pg_sleep(10)") }
        try await waitUntil { secondRuntime.canStop }
        await workspace.run(first, sql: "SELECT 11")
        #expect(firstRuntime.result?.rows?.first?.first == "11")
        await workspace.stop(second)
        await sleep.value
        #expect(secondRuntime.queryFailure?.category == "cancelled")
        await workspace.run(second, sql: "SELECT 22")
        #expect(secondRuntime.result?.rows?.first?.first == "22")
        #expect(secondRuntime.sessionId == secondSession)

        await workspace.disconnectProfile(profileID)
        #expect(first.runtime == nil && second.runtime == nil)
        #expect(workspace.services[profileID] == nil)
        #expect(thirdRuntime.connectionState == .connected)
        await workspace.run(third, sql: "SELECT 33")
        #expect(thirdRuntime.result?.rows?.first?.first == "33")
        try capture(content)
        await workspace.shutdown()
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty &&
                   !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func postgresAndMySQLRunInTheSameHelper() async throws {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: { _ in .rollback },
            executionDecision: { _ in true }, helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        try #require(await workspace.library.saveConnection(name: "PostgreSQL", settings: postgresSettings()))
        let pgID = try #require(workspace.library.selectedConnectionId)
        try #require(await workspace.library.saveConnection(name: "MySQL", settings: mysqlSettings()))
        let mysqlID = try #require(workspace.library.selectedConnectionId)
        let postgres = workspace.newDocument(profileID: pgID, text: "SELECT 1234567890.1234567890123456789::numeric")
        let mysql = workspace.newDocument(profileID: mysqlID, text: "SELECT CAST('1234567890.1234567890123456789' AS DECIMAL(30,19))")
        async let pgExecution: Void = workspace.run(postgres)
        async let myExecution: Void = workspace.run(mysql)
        _ = await (pgExecution, myExecution)
        #expect(postgres.runtime?.result?.rows?.first?.first == "1234567890.1234567890123456789")
        #expect(mysql.runtime?.result?.rows?.first?.first == "1234567890.1234567890123456789")
        await workspace.run(mysql, sql: "START TRANSACTION")
        #expect(mysql.runtime?.transactionStatus == .transaction)
        #expect(postgres.runtime?.transactionStatus == .idle)
        await workspace.disconnectProfile(mysqlID)
        await workspace.run(postgres, sql: "SELECT 7")
        #expect(postgres.runtime?.result?.rows?.first?.first == "7")
        await workspace.shutdown()
    }

    private func postgresSettings() throws -> ConnectionSettings {
        let dsn = ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? ""
        let url = try #require(URLComponents(string: dsn))
        let host = try #require(url.host)
        let user = try #require(url.user)
        let parameters = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        return ConnectionSettings(host: host, port: url.port ?? 5432, database: String(url.path.dropFirst()),
            user: user, password: url.password ?? "", sslMode: parameters["sslmode"] ?? "disable",
            sslRootCert: parameters["sslrootcert"])
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func objectTreeStructureQuotedSelectAndSeparateDataSession() async throws {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), executionDecision: { _ in true }, helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        try #require(await workspace.library.saveConnection(name: "Catalog", settings: postgresSettings()))
        let profileID = try #require(workspace.library.selectedConnectionId)
        let schema = "dbeer_native_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let sql = workspace.newDocument(profileID: profileID, text: "SELECT 1")
        await workspace.run(sql, sql: "CREATE SCHEMA \(schema)")
        try #require(sql.runtime?.queryFailure == nil)
        await workspace.run(sql, sql: "CREATE TABLE \(schema).\"odd%_\"\"name\" (id integer PRIMARY KEY, label text DEFAULT 'default value')")
        await workspace.run(sql, sql: "INSERT INTO \(schema).\"odd%_\"\"name\" SELECT n, 'row ' || n FROM generate_series(1, 205) n")
        try #require(sql.runtime?.queryFailure == nil)
        await workspace.loadSchemas(profileID)
        let root = try #require(workspace.catalogRoots[profileID]?.first { $0.name == schema })
        await workspace.expand(root)
        let tables = try #require(root.children?.first { $0.objectKind == "table" })
        await workspace.expand(tables)
        let table = try #require(tables.children?.first { $0.name == "odd%_\"name" })
        let select = await workspace.generatedSelect(table)
        #expect(select?.contains("\"\(schema)\".\"odd%_\"\"name\"") == true)
        #expect(await workspace.generatedName(table) == "\"\(schema)\".\"odd%_\"\"name\"")
        await workspace.inspect(table)
        #expect(workspace.inspection?.structure?.catalogRecords.first?["name"] == "id")
        #expect(workspace.inspection?.structure?.catalogRecords.first?["primaryKey"] == "1")
        workspace.inspection = nil
        let longQuery = Task { await workspace.run(sql, sql: "SELECT pg_sleep(10)") }
        try await waitUntil { sql.runtime?.canStop == true }
        await workspace.loadSchemas(profileID, refresh: true)
        #expect(workspace.catalogErrors[profileID] == nil)
        await workspace.openData(table)
        let data = try #require(workspace.selectedDocument)
        #expect(data.table?.name == table.name)
        #expect(data.runtime?.result?.rows?.count == 200)
        #expect(data.runtime?.sessionId != sql.runtime?.sessionId)
        #expect(data.runtime?.sessionId != workspace.services[profileID]?.sessionId)
        workspace.catalogSearch = "odd%_"
        await workspace.searchCatalog()
        #expect(workspace.catalogSearchResults[profileID]?.contains { $0.schema == schema && $0.name == table.name } == true)
        await workspace.stop(sql)
        await longQuery.value
        await workspace.closeDocument(data)
        await workspace.run(sql, sql: "DROP SCHEMA \(schema) CASCADE")
        #expect(sql.runtime?.queryFailure == nil)
        await workspace.shutdown()
    }

    private func mysqlSettings() throws -> ConnectionSettings {
        let env = ProcessInfo.processInfo.environment
        return ConnectionSettings(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
            port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")),
            database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer",
            user: env["DBEER_TEST_MYSQL_USER"] ?? "root", password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "",
            sslMode: env["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable", sslRootCert: env["DBEER_TEST_MYSQL_CA_FILE"], engine: .mysql)
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func scriptStopsAtFirstErrorAndDraftRestoreNeverReconnects() async throws {
        let connections = MemoryConnectionLibraryStore()
        let credentials = MemoryConnectionCredentialStore()
        let drafts = MemorySQLDocumentStore()
        let workspace = ApplicationWorkspace(connectionStore: connections, credentialStore: credentials,
            documentStore: drafts, executionDecision: { _ in true }, helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        try #require(await workspace.library.saveConnection(name: "Script", settings: postgresSettings()))
        let profile = try #require(workspace.library.selectedConnectionId)
        let text = """
            CREATE TEMP TABLE dbeer_script (value integer);
            INSERT INTO dbeer_script VALUES (1);
            SELECT value FROM dbeer_script;
            SELECT missing_value FROM dbeer_script;
            INSERT INTO dbeer_script VALUES (2);
            """
        let document = workspace.newDocument(profileID: profile, text: text)
        await workspace.runScript(document)
        #expect(document.text == text)
        #expect(document.executions.count == 5)
        #expect(document.executions[2].result?.rows?.first?.first == "1")
        #expect(document.executions[3].failure?.sqlState == "42703")
        #expect(document.executions[4].status == "Skipped")
        #expect(document.errorPosition != nil)
        #expect(workspace.history.count == 4)
        await workspace.run(document, sql: "SELECT count(*) FROM dbeer_script")
        #expect(document.runtime?.result?.rows?.first?.first == "1")
        document.text = "SELECT pg_sleep(10); INSERT INTO dbeer_script VALUES (3);"
        let script = Task { await workspace.runScript(document) }
        try await waitUntil { document.runtime?.canStop == true }
        await workspace.stop(document)
        await script.value
        #expect(document.executions[0].failure?.category == "cancelled")
        #expect(document.executions[1].status == "Skipped")
        workspace.historyEnabled = false
        let recorded = workspace.history.count
        await workspace.run(document, sql: "SELECT count(*) FROM dbeer_script")
        #expect(document.runtime?.result?.rows?.first?.first == "1")
        #expect(workspace.history.count == recorded)
        document.title = "Restored SQL"
        document.text = "SELECT 'restore must not execute this';"
        await workspace.flushDocuments()
        let id = document.id
        await workspace.shutdown()
        let restored = ApplicationWorkspace(connectionStore: connections, credentialStore: credentials,
            documentStore: drafts, executionDecision: { _ in true }, helperFactory: { BackendClient(executableURL: executable) })
        await restored.start()
        let restoredDocument = try #require(restored.documents.first { $0.id == id })
        #expect(restoredDocument.text == "SELECT 'restore must not execute this';")
        #expect(restoredDocument.title == "Restored SQL")
        #expect(restoredDocument.profileID == profile)
        #expect(restoredDocument.runtime == nil)
        #expect(restored.services.isEmpty)
        #expect(!restored.historyEnabled)
        #expect(restored.history.count == recorded)
        await restored.shutdown()
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate())
    }

    private func capture(_ view: NSView) throws {
        guard let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("m1-workspace.png"))
    }
}
