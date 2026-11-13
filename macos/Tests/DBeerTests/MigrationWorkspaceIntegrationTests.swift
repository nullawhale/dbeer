import Foundation
import Testing
@testable import DBeer

/// Normal workspace/shared helper, disposable owned tables and private file/memory
/// stores. Every decision and preference is injected. No AppKit, views, windows,
/// activation, watchers, SSH, password commands or login credential stores.
@Suite(.serialized)
@MainActor
struct MigrationWorkspaceIntegrationTests {
    @Test func sqliteDependencyOrderAndPartialFailureUseNormalWorkspace() async throws { try await exercise(.sqlite) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresSelectedRepairRenameAndPartialFailureUseNormalWorkspace() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlSelectedRepairRenameAndPartialFailureUseNormalWorkspace() async throws { try await exercise(.mysql) }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = env["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let folder = root.appendingPathComponent("build/migration-integration/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let defaultsName = "DBeer.MigrationIntegration." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName); try? FileManager.default.removeItem(at: folder) }
        let settings: ConnectionSettings
        switch engine {
        case .sqlite:
            let path = folder.appendingPathComponent("owned.sqlite"); try Data().write(to: path)
            settings = .init(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite, sqlite: .init(path: path.path))
        case .mysql:
            settings = .init(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost", port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")), database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: env["DBEER_TEST_MYSQL_USER"] ?? "dbeer", password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: "disable", engine: .mysql)
        default:
            let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
            settings = .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        let snapshots = ResultSnapshotStore(rootURL: folder.appendingPathComponent("snapshots"))
        let plans = PlanArtifactStore(rootURL: folder.appendingPathComponent("evidence"))
        let themes = EditorThemeStore(defaults: defaults, directory: folder.appendingPathComponent("themes"))
        var accept = true, starts = 0
        var decisions: [OperationConfirmation] = []
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
            commandShortcuts: AppShortcutStore(defaults: defaults), copySettings: ResultCopySettings(defaults: defaults), editorThemes: themes,
            appearance: AppAppearance(defaults: defaults, editorThemes: themes), sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: SQLLibrary(),
            tableBrowsePresets: TableBrowsePresetStore(fileURL: folder.appendingPathComponent("presets.json")), logicalRelationships: LogicalRelationshipStore(fileURL: folder.appendingPathComponent("relationships.json")),
            resultSnapshots: ResultSnapshotsModel(store: snapshots), planArtifacts: PlanArtifactsModel(store: plans),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { decisions.append($0); return accept }, queryParameterDecision: { _, _ in nil }, explainOptionsDecision: { _ in nil },
            helperFactory: { starts += 1; return BackendClient(executableURL: executable) })
        await workspace.start()
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let parent = "e5n_p_" + suffix, child = "e5n_c_" + suffix, fk = "e5n_fk_" + suffix, index = "e5n_i_" + suffix
        let schema = engine == .sqlite ? "main" : engine == .postgresql ? "public" : settings.database
        var cleanup: SQLDocument?
        do {
            try #require(await workspace.library.saveConnection(name: "Migration fixture", settings: settings))
            let profile = try #require(workspace.library.selectedConnectionId)
            let sql = workspace.newDocument(profileID: profile); cleanup = sql
            func run(_ text: String) async throws {
                await workspace.run(sql, sql: text)
                try #require(sql.localError == nil && sql.runtime?.queryFailure == nil)
            }
            try await run("CREATE TABLE \(parent)(id INTEGER NOT NULL PRIMARY KEY)")
            try await run("INSERT INTO \(parent) VALUES(1)")
            try await run("CREATE TABLE \(child)(id INTEGER NOT NULL PRIMARY KEY,parent_id INTEGER,CONSTRAINT \(fk) FOREIGN KEY(parent_id) REFERENCES \(parent)(id) ON UPDATE NO ACTION ON DELETE NO ACTION)")
            try await run("INSERT INTO \(child) VALUES(1,1),(2,1)")
            let node = CatalogNode(profileID: profile, name: schema, kind: .schema, schema: schema)
            workspace.openMigration(node)
            let model = try #require(workspace.migrationComposer)
            #expect(model.preview == nil && model.report == nil && model.canOpenDraft)
            let parentTarget = StructureTarget(schema: schema, table: parent, create: false)
            let childTarget = StructureTarget(schema: schema, table: child, create: false)
            // Exercise the composer through its typed per-object authoring seam.
            await model.editObject(nil, target: parentTarget)
            let editor = try #require(model.objectEditor)
            editor.draft = .init(columns: [.init(name: "parent_added", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))],
                changes: engine == .sqlite ? nil : [.init(name: "id", renameTo: "renamed_id")])
            model.stageObject()
            let parentID = try #require(model.draft.objects.first?.id)
            await model.editObject(nil, target: childTarget)
            let childEditor = try #require(model.objectEditor)
            childEditor.draft = .init(columns: [.init(name: "child_added", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))])
            model.stageObject()
            let childID = try #require(model.draft.objects.last?.id)
            model.setPrerequisite(objectID: childID, prerequisiteID: parentID, selected: true)
            if engine != .sqlite {
                await model.loadRepairTarget(childTarget)
                let key = try #require(model.repairBaseline?.keys?.first { $0.name == fk })
                #expect(model.draft.repairs.isEmpty)
                model.selectRepair(key: key)
                model.draft.repairs[0].replacement?.referenceColumns = ["renamed_id"]
            }
            let beforePreview = decisions.count
            await model.preparePreview()
            try #require(model.error == nil)
            let reviewed = try #require(model.preview)
            try #require(model.error == nil && reviewed.valid && model.canApply)
            #expect(decisions.count == beforePreview && reviewed.steps.filter { $0.phase == "object" }.map(\.objectId) == [parentID, childID])
            if engine != .sqlite { #expect(reviewed.steps.first?.phase == "repairDrop" && reviewed.steps.last?.phase == "repairAdd") }
            accept = false; await model.apply()
            #expect(model.preview == reviewed && model.report == nil && decisions.count == beforePreview + 1)
            #expect(decisions.last?.generatedPreview?.contains("Digest: " + reviewed.digest) == true)
            #expect(decisions.last?.generatedPreview?.contains("non-atomic") == true)
            accept = true; await model.apply()
            let report = try #require(model.report)
            try #require(report.outcome.state == "applied" && report.valid && report.outcome.steps.allSatisfy { $0.state == "applied" })
            #expect(!model.canApply && !model.canPreview && model.reconciliationRequired)
            try await run("SELECT \(engine == .sqlite ? "id" : "renamed_id"),parent_added FROM \(parent)")
            #expect(sql.runtime?.result?.rows == [["1", nil]])
            try await run("SELECT count(*) FROM \(child)")
            #expect(sql.runtime?.result?.rows == [["2"]])
            let savedReport = folder.appendingPathComponent("review.dbeermigrationreport")
            await model.saveReport(to: savedReport, expected: report, version: nil)
            #expect(try MigrationExecutionDocument.decode(SQLFileBinding.read(savedReport).text) == report)
            let exported = folder.appendingPathComponent("review.sql")
            await model.exportSQL(to: exported, expected: reviewed, version: nil)
            let exportedSQL = try SQLFileBinding.read(exported).text
            #expect(reviewed.steps.flatMap(\.sql).allSatisfy(exportedSQL.contains))
            await model.checkStatus()
            #expect(model.report?.id == report.id && model.preview == nil)
            await model.reconcile()
            try #require(model.error == nil && !model.reconciliationRequired && model.retainedIntentNeedsReview && !model.canPreview)
            model.reviewRetainedIntent()
            #expect(model.history.contains { $0.id == report.id } && model.report == nil)
            // A later independent group fails on duplicate values. Earlier
            // acknowledged work remains, with no implicit retry or replay.
            // MySQL keeps a UNIQUE constraint and its backing index as one unit.
            let failingDraft: StructureDraft = engine == .mysql
                ? .init(columns: [], keys: [.init(action: "add", kind: "unique", name: index, columns: ["parent_id"])])
                : .init(columns: [], indexes: [.init(action: "add", name: index, columns: ["parent_id"], unique: true)])
            model.draft = .init(version: 1, objects: [
                .init(id: "first", target: parentTarget, draft: .init(columns: [.init(name: "before_failure", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))]), after: []),
                .init(id: "second", target: childTarget, draft: failingDraft, after: ["first"])
            ], repairs: [])
            await model.preparePreview()
            try #require(model.error == nil)
            let failedPlan = try #require(model.preview)
            #expect(failedPlan.draft.objects.last?.draft == failingDraft)
            await model.apply()
            let failed = try #require(model.report)
            try #require(failed.outcome.state == "partiallyApplied" && failed.valid)
            #expect(failed.outcome.steps.first?.state == "applied" && failed.outcome.steps.last?.state == "failed")
            #expect(failed.plan == failedPlan && failed.plan.draft.objects.count == 2 && !model.canPreview && !model.canApply)
            try await run("SELECT before_failure FROM \(parent)")
            #expect(sql.runtime?.result?.rows == [[nil]])
            let intentURL = folder.appendingPathComponent("remaining.dbeermigration")
            await model.saveDraft(to: intentURL, expected: model.portableDraft, version: nil)
            let intent = try MigrationDraftDocument.decode(SQLFileBinding.read(intentURL).text)
            #expect(intent.draft.objects.count == 2)
            await model.checkStatus()
            #expect(model.report?.id == failed.id && model.report?.outcome.steps == failed.outcome.steps)
            await model.reconcile()
            #expect(!model.reconciliationRequired && !model.canPreview && model.report?.id == failed.id)
            await workspace.closeMigration()
            #expect(workspace.migrationComposer == nil && workspace.migrationOutcomeReports.count == 2)
            workspace.openMigration(node)
            let reopened = try #require(workspace.migrationComposer), beforeOpen = starts
            await reopened.openDraft(from: intentURL, expected: reopened.portableDraft)
            #expect(starts == beforeOpen && reopened.preview == nil && reopened.report == nil && reopened.canOpenDraft && reopened.draft == intent.draft)
            await reopened.openReport(from: savedReport)
            #expect(starts == beforeOpen && reopened.report == nil && reopened.preview == nil && reopened.history.contains { $0.id == report.id })
            await workspace.closeMigration()
            try await run("DROP TABLE \(child)"); try await run("DROP TABLE \(parent)")
        } catch {
            accept = true; await workspace.closeMigration()
            if let sql = cleanup { for table in [child, parent] { await workspace.run(sql, sql: "DROP TABLE IF EXISTS \(table)") } }
            await workspace.shutdown(); throw error
        }
        await workspace.shutdown()
    }
}
