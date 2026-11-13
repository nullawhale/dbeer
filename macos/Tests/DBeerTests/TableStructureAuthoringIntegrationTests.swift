import Foundation
import Testing
@testable import DBeer

/// Disposable owned databases/files, memory stores and injected policy decisions.
/// No windows, modal presentation, application activation or desktop interaction.
@Suite(.serialized)
@MainActor
struct TableStructureAuthoringIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresAuthoringUsesNormalHelperAndExactPolicyPlan() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlAuthoringUsesNormalHelperAndExplicitSupportingKey() async throws { try await exercise(.mysql) }
    @Test func sqliteAuthoringUsesNormalHelperAndPreservesOriginalHistory() async throws { try await exercise(.sqlite) }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = env["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let folder = root.appendingPathComponent("build/structure-authoring/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings: ConnectionSettings
        switch engine {
        case .sqlite:
            settings = .init(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite, sqlite: .init(path: folder.appendingPathComponent("fixture.sqlite").path))
            _ = FileManager.default.createFile(atPath: settings.sqlite!.path, contents: Data())
        case .mysql:
            settings = .init(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost", port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")), database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: env["DBEER_TEST_MYSQL_USER"] ?? "dbeer", password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: "disable", engine: .mysql)
        default:
            let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
            settings = .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(), automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in true }, helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        do {
            try #require(await workspace.library.saveConnection(name: "Structure authoring fixture", settings: settings))
            let profile = try #require(workspace.library.selectedConnectionId)
            let sql = workspace.newDocument(profileID: profile)
            let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let name = "e1_native_" + suffix, resultingName = "e1_result_" + suffix, typeName = "e1_type_" + suffix
            let schema = engine == .postgresql ? "public" : engine == .sqlite ? "main" : settings.database
            await workspace.run(sql, sql: engine == .postgresql ? "CREATE TYPE \(typeName) AS ENUM('kept')" : "SELECT 1")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            let node = CatalogNode(profileID: profile, name: schema, kind: .schema, schema: schema)
            await workspace.openTableStructure(node, create: true)
            let model = try #require(workspace.structureEditor)
            model.table = name
            await model.load()
            try #require(model.error == nil && model.authoringAvailable)
            model.draft = .init(columns: [
                .init(name: "id", type: .init(kind: "integer"), nullable: false, default: .init(kind: "none"), identity: .init(kind: engine == .postgresql ? "always" : "autoIncrement")),
                .init(name: "base", type: .init(kind: "integer"), nullable: true, default: .init(kind: "numeric", value: "7")),
                .init(name: "derived", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"), generated: .init(storage: "stored", expression: "base * 2"))
            ], keys: [.init(action: "add", kind: "primary", name: engine == .mysql ? "PRIMARY" : "authored_pk", columns: ["id"])])
            await model.preparePreview()
            try #require(model.error == nil && model.preview?.destructive == true && model.canApply)
            if engine == .mysql { #expect(model.preview?.sql.count == 3) }
            await model.apply()
            try #require(model.outcome?.state == "applied" && model.outcome?.steps.allSatisfy { $0.message == nil || $0.message == "" } == true)
            await workspace.run(sql, sql: engine == .mysql ? "INSERT INTO \(name) () VALUES()" : "INSERT INTO \(name) DEFAULT VALUES")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            await model.load()
            let type = engine == .postgresql ? StructureDataType(kind: "reference", reference: .init(schema: schema, name: typeName)) : .init(kind: "integer")
            model.draft = .init(columns: [
                .init(name: "first_added", type: type, nullable: true, default: .init(kind: "none")),
                .init(name: "second_added", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))
            ])
            await model.preparePreview()
            try #require(model.error == nil && model.preview != nil)
            await model.apply()
            try #require(model.outcome?.state == "applied" && model.outcome?.observed?.columns.count == 5)
            await model.load()
            model.draft = .init(columns: [], changes: [.init(name: "id", renameTo: "renamed_id")], renameTable: resultingName)
            await model.preparePreview()
            try #require(model.error == nil && model.preview?.target.table == name && model.preview?.resultTarget?.table == resultingName)
            await model.apply()
            try #require(model.outcome?.state == "applied" && model.outcome?.observed?.target.table == resultingName)
            let review = try #require(model.outcomeReview)
            #expect(review.plan.target.table == name && review.draft.renameTable == resultingName)
            await model.load()
            #expect(model.table == resultingName && model.historyReviews.last?.plan.target.table == name)
            await workspace.run(sql, sql: "SELECT renamed_id,derived FROM \(resultingName)")
            #expect(sql.runtime?.result?.rows == [["1", "14"]])
            #expect(workspace.structureOutcomeReports.contains { $0.matchesTable(schema: schema, table: resultingName) && $0.review.plan.target.table == name })
            if engine == .sqlite {
                await workspace.run(sql, sql: "INSERT INTO \(resultingName) DEFAULT VALUES")
                model.draft = .init(columns: [.init(name: "must_rollback", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))], indexes: [.init(action: "add", name: "duplicate_base", columns: ["base"], unique: true)])
                await model.preparePreview()
                try #require(model.preview?.sql.count == 2)
                await model.apply()
                #expect(model.outcome?.state == "failed" && model.outcome?.steps.allSatisfy { $0.state == "rolledBack" } == true)
                await model.checkExecutionStatus()
                #expect(model.outcome?.state == "failed" && model.outcome?.observed?.columns.count == 5)
                #expect(!model.canApply)
            }
            await workspace.closeTableStructure()
            await workspace.run(sql, sql: "DROP TABLE \(resultingName)")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            if engine == .postgresql { await workspace.run(sql, sql: "DROP TYPE \(typeName)") }
        } catch {
            await workspace.shutdown()
            throw error
        }
        await workspace.shutdown()
    }
}
