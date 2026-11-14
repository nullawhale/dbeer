import Foundation
import Testing
@testable import DBeer

/// Normal helper, owned tables, memory stores, injected decisions and private
/// evidence folders only. No windows, activation, dialogs, SSH or file watchers.
@Suite(.serialized) @MainActor struct TableStructureAdvancedIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresRLSUsesFreshKindProofAndExactPreviewApply() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlPartitionUsesFreshKindProofAndExactPreviewApply() async throws { try await exercise(.mysql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresRLSGenerationBackfillAndNativeReconstructionUseReviewedStore() async throws { try await exercise(.postgresql, dataWorkflow: true) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlPartitionGenerationBackfillAndNativeCopyUseReviewedStore() async throws { try await exercise(.mysql, dataWorkflow: true) }
    private func exercise(_ engine: DatabaseEngine, dataWorkflow: Bool = false) async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = env["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let folder = root.appendingPathComponent("build/advanced-kind-native/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let defaultsName = "DBeer.AdvancedKindIntegration." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName); try? FileManager.default.removeItem(at: folder) }
        let settings: ConnectionSettings
        if engine == .mysql {
            settings = .init(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost", port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")), database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: env["DBEER_TEST_MYSQL_USER"] ?? "dbeer", password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: "disable", engine: .mysql, policy: .init(environment: .production))
        } else {
            let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
            settings = .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "", sslMode: "disable", policy: .init(environment: .production))
        }
        let snapshots = ResultSnapshotStore(rootURL: folder.appendingPathComponent("snapshots"))
        let plans = PlanArtifactStore(rootURL: folder.appendingPathComponent("evidence"))
        var confirmations: [OperationConfirmation] = []
        var accept = true
        let themes = EditorThemeStore(defaults: defaults, directory: folder.appendingPathComponent("themes"))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
            commandShortcuts: AppShortcutStore(defaults: defaults), copySettings: ResultCopySettings(defaults: defaults), editorThemes: themes,
            appearance: AppAppearance(defaults: defaults, editorThemes: themes), sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: SQLLibrary(),
            tableBrowsePresets: TableBrowsePresetStore(fileURL: folder.appendingPathComponent("presets.json")), logicalRelationships: LogicalRelationshipStore(fileURL: folder.appendingPathComponent("relationships.json")),
            resultSnapshots: ResultSnapshotsModel(store: snapshots), planArtifacts: PlanArtifactsModel(store: plans),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { confirmations.append($0); return accept }, queryParameterDecision: { _, _ in nil }, explainOptionsDecision: { _ in nil },
            helperFactory: { BackendClient(executableURL: executable) },
            explainCollectorFactory: { id in ExplainCollector(store: PlanArtifactStore(rootURL: folder.appendingPathComponent("collector-" + id.uuidString))) })
        await workspace.start()
        let table = "e7_native_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let schema = engine == .postgresql ? "public" : settings.database
        var document: SQLDocument?
        do {
            try #require(await workspace.library.saveConnection(name: "Advanced kind fixture", settings: settings))
            let profile = try #require(workspace.library.selectedConnectionId)
            let sql = workspace.newDocument(profileID: profile); document = sql
            let suffix = engine == .mysql ? " ENGINE=InnoDB PARTITION BY RANGE(id) (PARTITION p0 VALUES LESS THAN (10),PARTITION p1 VALUES LESS THAN MAXVALUE)" : ""
            let definition = dataWorkflow ? "id INTEGER NOT NULL,base INTEGER,payload VARCHAR(40),derived INTEGER GENERATED ALWAYS AS(base*2) STORED" : "id INTEGER,payload VARCHAR(40)"
            await workspace.run(sql, sql: "CREATE TABLE \(table)(\(definition))\(suffix)")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            let insert = dataWorkflow ? "INSERT INTO \(table)(id,base,payload) VALUES (1,6,''),(11,7,'NULL')" : "INSERT INTO \(table) VALUES (1,''),(11,'NULL')"
            await workspace.run(sql, sql: insert)
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            if engine == .postgresql {
                for statement in ["ALTER TABLE \(table) ENABLE ROW LEVEL SECURITY", "ALTER TABLE \(table) FORCE ROW LEVEL SECURITY", "CREATE POLICY keep_policy ON \(table) USING (id>0)"] {
                    await workspace.run(sql, sql: statement)
                    try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
                }
            }
            await workspace.openTableStructure(CatalogNode(profileID: profile, name: table, kind: .object, schema: schema, objectKind: "table"), create: false)
            let model = try #require(workspace.structureEditor)
            try #require(model.error == nil && model.baseline?.advanced != nil && !model.canApply)
            model.draft = .init(columns: [], changes: [.init(name: "payload", default: .init(kind: "text", value: "NULL"))])
            await model.preparePreview()
            let plan = try #require(model.preview)
            try #require(model.canApply)
            accept = false
            let beforeDecline = confirmations.count
            await model.apply()
            let declined = try #require(confirmations.last)
            let boundOperation = declined.operations.first?.structure?.planId == plan.id && declined.operations.first?.structure?.digest == plan.digest
            let boundStandaloneReview = declined.generatedPreview?.contains("Plan: " + plan.id) == true && declined.generatedPreview?.contains("Digest: " + plan.digest) == true
            #expect(confirmations.count == beforeDecline + 1 && (boundOperation || boundStandaloneReview))
            #expect(model.outcome == nil && model.preview == plan)
            accept = true
            await model.apply()
            let outcome = try #require(model.outcomeReview)
            #expect(outcome.outcome.state == "applied" && outcome.outcome.observed?.advanced != nil && !model.canApply)
            #expect(outcome.outcome.steps.allSatisfy { $0.message == nil || $0.message == "" })
            await workspace.run(sql, sql: "SELECT id,payload FROM \(table) ORDER BY id")
            #expect(sql.runtime?.result?.rows == [["1", ""], ["11", "NULL"]])
            if dataWorkflow {
                // Each decision reviews the normal helper's bound plan. Preview
                // itself must not request execution or evaluate the draft.
                func applyReviewed(_ draft: StructureDraft) async throws {
                    await model.load()
                    try #require(model.error == nil && model.baseline?.advanced != nil)
                    model.draft = draft
                    let beforePreview = confirmations.count
                    await model.preparePreview()
                    let preview = try #require(model.preview)
                    try #require(model.error == nil && model.canApply && confirmations.count == beforePreview)
                    accept = false
                    await model.apply()
                    let declined = try #require(confirmations.last)
                    let boundOperation = declined.operations.first?.structure?.planId == preview.id && declined.operations.first?.structure?.digest == preview.digest
                    let boundStandalone = declined.generatedPreview?.contains("Plan: " + preview.id) == true && declined.generatedPreview?.contains("Digest: " + preview.digest) == true
                    try #require(confirmations.count == beforePreview + 1 && (boundOperation || boundStandalone))
                    try #require(model.preview == preview && model.outcome == nil)
                    accept = true
                    await model.apply()
                    let review = try #require(model.outcomeReview)
                    try #require(review.outcome.state == "applied" && review.outcome.observed?.advanced != nil && !model.canApply)
                    #expect(review.outcome.steps.allSatisfy { $0.state == "applied" && ($0.message == nil || $0.message == "") })
                }
                let generation = engine == .postgresql ? StructureGeneration(storage: "none") : StructureGeneration(storage: "stored", expression: "base * 3")
                try await applyReviewed(.init(columns: [], changes: [.init(name: "derived", generated: generation)]))
                await workspace.run(sql, sql: "SELECT derived FROM \(table) ORDER BY id")
                #expect(sql.runtime?.result?.rows == (engine == .postgresql ? [["12"], ["14"]] : [["18"], ["21"]]))
                try await applyReviewed(.init(columns: [.init(name: "required", type: .init(kind: "integer"), nullable: false, default: .init(kind: "none"))], allowDestructive: true, backfills: [.init(column: "required", expression: "id + 100")]))
                await workspace.run(sql, sql: "SELECT id,payload,required FROM \(table) ORDER BY id")
                #expect(sql.runtime?.result?.rows == [["1", "", "101"], ["11", "NULL", "111"]])
                await model.load()
                let names = try #require(model.baseline?.columns.map(\.name))
                let order: [String]? = engine == .mysql ? Array(names.reversed()) : nil
                try await applyReviewed(.init(columns: [], allowDestructive: true, columnOrder: order, reconstruct: true))
                await workspace.run(sql, sql: "SELECT id,payload,required FROM \(table) ORDER BY id")
                #expect(sql.runtime?.result?.rows == [["1", "", "101"], ["11", "NULL", "111"]])
                if engine == .postgresql {
                    await model.load()
                    let currentNames = try #require(model.baseline?.columns.map(\.name))
                    let copyOrder = Array(currentNames.reversed())
                    try await applyReviewed(.init(columns: [], allowDestructive: true, columnOrder: copyOrder, reconstruct: true))
                    let observedOrder = model.outcomeReview?.outcome.observed?.columns.map { $0.name }
                    #expect(observedOrder == copyOrder)
                    await workspace.run(sql, sql: "SELECT id,payload,required FROM \(table) ORDER BY id")
                    #expect(sql.runtime?.result?.rows == [["1", "", "101"], ["11", "NULL", "111"]])
                }
            }
            await workspace.closeTableStructure()
            await workspace.run(sql, sql: "DROP TABLE \(table)")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
        } catch {
            await workspace.closeTableStructure()
            if let document { await workspace.run(document, sql: "DROP TABLE IF EXISTS \(table)") }
            await workspace.shutdown()
            throw error
        }
        await workspace.shutdown()
    }
}
