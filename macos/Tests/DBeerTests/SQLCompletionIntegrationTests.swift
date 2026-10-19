import Foundation
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct SQLCompletionIntegrationTests {
    private var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresConnectedCatalogFeedsTablesAndAliasColumnsWithoutBrowsing() async throws {
        try await exercise(.postgresql)
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlConnectedCatalogFeedsTablesAndAliasColumnsWithoutBrowsing() async throws {
        try await exercise(.mysql)
    }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), executionDecision: { _ in true },
            helperFactory: { BackendClient(executableURL: executable) })
        let language = SQLLanguageService(helperURL: executable)
        defer { Task { await language.shutdown(); await workspace.shutdown() } }
        await workspace.start()
        let settings = try settings(engine)
        try #require(await workspace.library.saveConnection(name: "Language fixture", settings: settings))
        let profile = try #require(workspace.library.selectedConnectionId)
        let schema = engine == .postgresql ? "public" : settings.database
        let table = "lsp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let quote = engine == .postgresql ? "\"" : "`"
        func quoted(_ name: String) -> String { quote + name.replacingOccurrences(of: quote, with: quote + quote) + quote }
        let qualified = quoted(schema) + "." + quoted(table)
        let setup = workspace.newDocument(profileID: profile)
        await workspace.run(setup, sql: "CREATE TABLE " + qualified + " (id integer PRIMARY KEY, " + quoted("Display Name") + " text)")
        try #require(setup.runtime?.queryFailure == nil)
        // Reconnect after creating the fixture: the connection itself must
        // hydrate completion metadata without opening any catalog branch.
        try #require(await workspace.disconnectProfile(profile))
        await workspace.connectProfile(profile)
        for _ in 0..<300 where workspace.completionContext(profileID: profile).catalog.first(where: { $0.name == table }) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let context = workspace.completionContext(profileID: profile)
        #expect(context.catalog.first { $0.name == table }?.columns.contains("Display Name") == true)
        #expect(workspace.catalogRoots[profile] == nil)
        #expect(workspace.completions(profileID: profile).contains(table))
        #expect(workspace.completions(profileID: profile).contains("Display Name"))

        let from = workspace.newDocument(profileID: profile, text: "SELECT * FROM " + String(table.prefix(12)))
        language.update(documentID: from.id, text: from.text, engine: engine, context: context)
        let tables = await language.completion(documentID: from.id, offset: from.text.utf16.count)
        #expect(tables.contains { $0.label == table && $0.replacement == qualified })
        #expect(from.runtime == nil)

        let document = workspace.newDocument(profileID: profile, text: "SELECT u.Di FROM " + qualified + " AS u")
        let previousHistory = workspace.history.count
        let previousSessions = workspace.services.count
        let position = (document.text as NSString).range(of: "Di")
        language.update(documentID: document.id, text: document.text, engine: engine, context: context)
        let suggestions = await language.completion(documentID: document.id, offset: NSMaxRange(position))
        let column = try #require(suggestions.first { $0.replacement == quoted("Display Name") })
        #expect(column.replacementRange == position)
        #expect(document.runtime == nil && !document.isRunning)
        #expect(workspace.services.count == previousSessions)
        #expect(workspace.history.count == previousHistory)
        #expect(document.text == "SELECT u.Di FROM " + qualified + " AS u")

        await workspace.run(setup, sql: "DROP TABLE " + qualified)
        try #require(setup.runtime?.queryFailure == nil)
        await workspace.loadSchemas(profile, refresh: true)
        #expect(!workspace.completionContext(profileID: profile).catalog.contains { $0.name == table })
        try #require(await workspace.disconnectProfile(profile))
        await workspace.loadCompletionCatalog(profile)
        #expect(workspace.completionContext(profileID: profile).catalog.isEmpty)
        #expect(workspace.services[profile] == nil)
        await language.shutdown()
        await workspace.shutdown()
    }

    private func settings(_ engine: DatabaseEngine) throws -> ConnectionSettings {
        let environment = ProcessInfo.processInfo.environment
        if engine == .mysql {
            guard let port = Int(environment["DBEER_TEST_MYSQL_PORT"] ?? "") else { throw MissingFixture() }
            return ConnectionSettings(host: environment["DBEER_TEST_MYSQL_HOST"] ?? "localhost", port: port,
                database: environment["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: environment["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
                password: environment["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: "disable", engine: .mysql)
        }
        guard let components = URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""),
              let host = components.host, let user = components.user else { throw MissingFixture() }
        return ConnectionSettings(host: host, port: components.port ?? 5432,
            database: String(components.path.dropFirst()), user: user, password: components.password ?? "", sslMode: "disable")
    }

    private struct MissingFixture: Error {}
}
