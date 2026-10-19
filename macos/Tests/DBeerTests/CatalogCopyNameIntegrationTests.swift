import AppKit
import Foundation
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct CatalogCopyNameIntegrationTests {
    private var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresCopyNameCallbackQuotesEveryObjectKindAndUsesUnqualifiedTriggerNames() async throws {
        try await exercise(.postgresql)
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlCopyNameCallbackQuotesEveryObjectKindIncludingQualifiedTriggers() async throws {
        try await exercise(.mysql)
    }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), helperFactory: { BackendClient(executableURL: executable) })
        defer { Task { await workspace.shutdown() } }
        await workspace.start()
        let settings = try settings(engine)
        try #require(await workspace.library.saveConnection(name: "Copy Name fixture", settings: settings))
        let profile = try #require(workspace.library.selectedConnectionId)
        let prefix = "copy_" + UUID().uuidString.prefix(12).replacingOccurrences(of: "-", with: "")
        let schema = engine == .postgresql ? prefix + " schema\"Ω" : settings.database
        func quote(_ value: String) -> String {
            let delimiter = engine == .postgresql ? "\"" : "`"
            return delimiter + value.replacingOccurrences(of: delimiter, with: delimiter + delimiter) + delimiter
        }
        func qualified(_ name: String) -> String { quote(schema) + "." + quote(name) }
        let table = prefix + " table`\"Ω"
        let view = prefix + " view`\"空"
        let function = engine == .mysql ? prefix + String(repeating: "猫", count: 44) + "函`\"" : prefix + " function`\"Ω"
        let procedure = engine == .mysql ? prefix + String(repeating: "猫", count: 44) + "程`\"" : prefix + " procedure`\"空"
        let trigger = engine == .mysql ? prefix + String(repeating: "猫", count: 44) + "触`\"" : prefix + " trigger`\"Ω"
        let hook = prefix + " hook`\"空"
        let sql = workspace.newDocument(profileID: profile)
        func run(_ statement: String) async throws {
            await workspace.run(sql, sql: statement)
            try #require(sql.runtime?.queryFailure == nil)
        }
        if engine == .postgresql { try await run("CREATE SCHEMA " + quote(schema)) }
        try await run("CREATE TABLE " + qualified(table) + " (id integer PRIMARY KEY)")
        try await run("INSERT INTO " + qualified(table) + " VALUES (1)")
        try await run("CREATE VIEW " + qualified(view) + " AS SELECT id FROM " + qualified(table))
        if engine == .postgresql {
            try await run("CREATE FUNCTION " + qualified(function) + "() RETURNS integer LANGUAGE sql AS 'SELECT 1'")
            try await run("CREATE PROCEDURE " + qualified(procedure) + "() LANGUAGE plpgsql AS $$BEGIN NULL; END$$")
            try await run("CREATE FUNCTION " + qualified(hook) + "() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$")
            try await run("CREATE TRIGGER " + quote(trigger) + " BEFORE INSERT ON " + qualified(table) + " FOR EACH ROW EXECUTE FUNCTION " + qualified(hook) + "()")
        } else {
            try await run("CREATE FUNCTION " + qualified(function) + "() RETURNS INT DETERMINISTIC NO SQL RETURN 1")
            try await run("CREATE PROCEDURE " + qualified(procedure) + "() SELECT 1")
            try await run("CREATE TRIGGER " + qualified(trigger) + " BEFORE INSERT ON " + qualified(table) + " FOR EACH ROW SET NEW.id=NEW.id")
        }
        let board = NSPasteboard(name: NSPasteboard.Name("dev.dbeer.tests.catalog-copy.\(UUID().uuidString)"))
        await workspace.loadSchemas(profile)
        let root = try #require(workspace.catalogRoots[profile]?.first { $0.name == schema })
        await workspace.expand(root)
        for (kind, name) in [("table", table), ("view", view), ("function", function), ("procedure", procedure), ("trigger", trigger)] {
            let group = try #require(root.children?.first { $0.objectKind == kind })
            await workspace.expand(group)
            let node = try #require(group.children?.first { $0.name == name })
            // Exercise the exact tree/search nodes, including streamed identity.
            #expect(await workspace.copyName(node, to: board))
            let expected = engine == .postgresql && kind == "trigger" ? quote(name) : qualified(name)
            #expect(board.string(forType: .string) == expected)
            workspace.catalogSearch = name
            await workspace.searchCatalog()
            #expect(workspace.catalogErrors[profile] == nil)
            let found = try #require(workspace.catalogSearchResults[profile]?.first { $0.name == name && $0.objectKind == kind },
                "Missing fixture search kind \(kind); returned kinds \(workspace.catalogSearchResults[profile]?.map(\.objectKind) ?? [])")
            #expect(found.identity == node.identity)
            if engine == .mysql && name.utf8.count > 128 {
                #expect(name.count <= 64)
                #expect((node.identity?.utf8.count ?? 0) <= 128 && node.identity != name)
            }
            #expect(await workspace.copyName(found, to: board))
            let copied = try #require(board.string(forType: .string))
            #expect(copied == expected)
            switch kind {
            case "table", "view": try await run("SELECT id FROM " + copied)
            case "function": try await run("SELECT " + copied + "()")
            case "procedure": try await run("CALL " + copied + "()")
            default: try await run("DROP TRIGGER " + copied + (engine == .postgresql ? " ON " + qualified(table) : ""))
            }
        }
        let previous = try #require(board.string(forType: .string))
        let missing = CatalogNode(profileID: profile, name: prefix + " missing`\"空", kind: .object,
            schema: schema, object: prefix + " missing`\"空", objectKind: "function")
        #expect(!(await workspace.copyName(missing, to: board)))
        #expect(board.string(forType: .string) == previous)
        if engine == .postgresql {
            try await run("DROP SCHEMA " + quote(schema) + " CASCADE")
        } else {
            try await run("DROP VIEW " + qualified(view))
            try await run("DROP FUNCTION " + qualified(function))
            try await run("DROP PROCEDURE " + qualified(procedure))
            try await run("DROP TABLE " + qualified(table))
        }
        await workspace.shutdown()
    }

    private func settings(_ engine: DatabaseEngine) throws -> ConnectionSettings {
        let environment = ProcessInfo.processInfo.environment
        if engine == .mysql {
            return ConnectionSettings(host: environment["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
                port: try #require(Int(environment["DBEER_TEST_MYSQL_PORT"] ?? "")),
                database: environment["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: environment["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
                password: environment["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: "disable", engine: .mysql)
        }
        let components = try #require(URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""))
        return ConnectionSettings(host: try #require(components.host), port: components.port ?? 5432,
            database: String(components.path.dropFirst()), user: try #require(components.user),
            password: components.password ?? "", sslMode: "disable")
    }
}
