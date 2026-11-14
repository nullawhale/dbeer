import Foundation
import Testing
@testable import DBeer

/// Uses isolated fixture profiles and real helpers without windows or application activation.
@Suite(.serialized)
@MainActor
struct DatabaseValueSearchIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresSearchUsesTypedReadonlyPredicatesAndFilteredNavigation() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlSearchUsesTypedReadonlyPredicatesAndFilteredNavigation() async throws { try await exercise(.mysql) }
    @Test func sqliteSearchKeepsStorageClassesAndTabTransactionsIndependent() async throws { try await exercise(.sqlite) }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = environment["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ??
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-data-search-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings: ConnectionSettings
        if engine == .sqlite {
            let path = directory.appendingPathComponent("fixture.sqlite").path
            _ = FileManager.default.createFile(atPath: path, contents: Data())
            settings = .init(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite, sqlite: .init(path: path))
        } else if engine == .mysql {
            settings = .init(host: environment["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
                port: try #require(Int(environment["DBEER_TEST_MYSQL_PORT"] ?? "")), database: environment["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer",
                user: environment["DBEER_TEST_MYSQL_USER"] ?? "dbeer", password: environment["DBEER_TEST_MYSQL_PASSWORD"] ?? "",
                sslMode: "disable", engine: .mysql)
        } else {
            let url = try #require(URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""))
            settings = .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()),
                user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(), automaticallyWatchFiles: false,
            closeDecision: { _ in .discard }, executionDecision: { _ in true }, helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        do {
            try #require(await workspace.library.saveConnection(name: "Data search fixture", settings: settings))
            let profileID = try #require(workspace.library.selectedConnectionId)
            let profile = try #require(workspace.library.savedConnections.first { $0.id == profileID })
            let table = "dbeer_search_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let sql = workspace.newDocument(profileID: profileID)
            let numericType = engine == .sqlite ? "INTEGER" : "DECIMAL(30,12)"
            let number = engine == .sqlite ? "9223372036854775807" : "9007199254740993.000000000001"
            let binaryType = engine == .postgresql ? "bytea" : engine == .mysql ? "VARBINARY(8)" : "BLOB"
            let bytes = engine == .postgresql ? "decode('00ff','hex')" : "X'00ff'"
            let uuidType = engine == .postgresql ? "uuid" : "VARCHAR(36)"
            let identifier = "12000000-0000-0000-0000-000000000001"
            await workspace.run(sql, sql: "CREATE TABLE \(table) (id INTEGER PRIMARY KEY,n \(numericType),label TEXT,payload \(binaryType),nullable TEXT,identifier \(uuidType))")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            await workspace.run(sql, sql: "INSERT INTO \(table) VALUES (1,\(number),'needle',\(bytes),NULL,'\(identifier)'),(2,2,'',NULL,'NULL','12000000-0000-0000-0000-000000000002')")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            await workspace.run(sql, sql: "BEGIN")
            try #require(sql.runtime?.transactionStatus == .transaction)
            let model = try #require(workspace.makeDatabaseValueSearch(profile))
            model.schema = engine == .postgresql ? "public" : engine == .sqlite ? "main" : settings.database
            await model.loadTables()
            try #require(model.error == nil)
            let selected = try #require(model.objects.first { Data($0.name.utf8) == Data(table.utf8) })
            model.selectedTables = [selected.id]
            model.query = .init(text: "needle", mode: .contains, columnKinds: [.text])
            await model.search()
            try #require(model.error == nil)
            #expect(model.observations.contains { $0.column == "label" && $0.returnedRows == 1 && $0.hasMatches })
            #expect(sql.runtime?.transactionStatus == .transaction)
            model.query = .init(text: identifier, columnKinds: [.text, .other])
            await model.search()
            #expect(model.observations.contains { $0.column == "identifier" && $0.returnedRows == 1 && $0.hasMatches })
            model.query = .init(text: number, valueKind: engine == .sqlite ? .sqliteInteger : .number, columnKinds: [.number])
            await model.search()
            #expect(model.observations.contains { $0.column == "n" && $0.returnedRows == 1 && $0.hasMatches })
            model.query = .init(text: "AP8=", valueKind: .binary, columnKinds: [.binary])
            await model.search()
            let binaryMatch = try #require(model.observations.first { $0.column == "payload" && $0.hasMatches })
            #expect(binaryMatch.returnedRows == 1)
            model.query = .init(text: "", columnKinds: [.text])
            await model.search()
            #expect(model.observations.contains { $0.column == "label" && $0.returnedRows == 1 && $0.hasMatches })
            model.query = .init(valueKind: .null, columnKinds: [.text])
            await model.search()
            #expect(model.observations.contains { $0.column == "nullable" && $0.returnedRows == 1 && $0.predicate?.condition?.operator == "isNull" })
            model.query = .init(text: "NULL", columnKinds: [.text])
            await model.search()
            #expect(model.observations.contains { $0.column == "nullable" && $0.returnedRows == 1 && $0.predicate?.condition?.operator == "eq" })
            model.query = .init(text: "' OR 1=1 --", columnKinds: [.text])
            await model.search()
            #expect(model.observations.allSatisfy { !$0.hasMatches })
            model.query = .init(text: "AP8=", valueKind: .binary, columnKinds: [.binary])
            await model.search()
            let match = try #require(model.observations.first { $0.column == "payload" && $0.hasMatches })
            // Changing the form does not retarget an observation's Open action.
            model.query.text = "AQ=="
            await model.openMatch(match)
            let opened = try #require(workspace.selectedDocument)
            #expect(opened !== sql && opened.table?.name == table)
            #expect(opened.tableFilterExpression?.condition?.column == "payload")
            #expect(opened.grid?.rows.count == 1 && opened.grid?.pendingCount == 0)
            #expect(sql.runtime?.transactionStatus == .transaction)
            await model.close()
            await workspace.run(sql, sql: "ROLLBACK")
            await workspace.run(sql, sql: "SELECT COUNT(*) FROM \(table)")
            #expect(sql.runtime?.result?.rows == [["2"]])
            await workspace.run(sql, sql: "DROP TABLE \(table)")
            try #require(sql.runtime?.queryFailure == nil)
            await workspace.shutdown()
        } catch {
            await workspace.shutdown()
            throw error
        }
    }
}
