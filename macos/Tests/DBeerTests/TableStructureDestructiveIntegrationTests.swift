import Foundation
import Testing
@testable import DBeer

/// Owned database fixtures/files, private stores and injected decisions only.
/// No windows, panels, NSApplication, appearance.start(), watchers or activation.
@Suite(.serialized)
@MainActor
struct TableStructureDestructiveIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresConversionsValidationAndDropsUseNormalWorkspace() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlConversionsValidationAndDropsUseNormalWorkspace() async throws { try await exercise(.mysql) }
    @Test func sqliteNativeDropsPreserveExactRemainingValues() async throws { try await exercise(.sqlite) }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let environment = ProcessInfo.processInfo.environment
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = environment["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let folder = repository.appendingPathComponent("build/destructive-integration/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let preferenceName = "DBeer.DestructiveIntegration." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: preferenceName))
        defer { defaults.removePersistentDomain(forName: preferenceName); try? FileManager.default.removeItem(at: folder) }
        let settings: ConnectionSettings
        switch engine {
        case .sqlite:
            settings = .init(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite, sqlite: .init(path: folder.appendingPathComponent("fixture.sqlite").path))
            try Data().write(to: URL(fileURLWithPath: try #require(settings.sqlite?.path)))
        case .mysql:
            settings = .init(host: environment["DBEER_TEST_MYSQL_HOST"] ?? "localhost", port: try #require(Int(environment["DBEER_TEST_MYSQL_PORT"] ?? "")), database: environment["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: environment["DBEER_TEST_MYSQL_USER"] ?? "dbeer", password: environment["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: "disable", engine: .mysql)
        default:
            let url = try #require(URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""))
            settings = .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        let snapshots = ResultSnapshotStore(rootURL: folder.appendingPathComponent("snapshots"))
        let plans = PlanArtifactStore(rootURL: folder.appendingPathComponent("evidence"))
        let themes = EditorThemeStore(defaults: defaults, directory: folder.appendingPathComponent("themes"))
        var decisions: [OperationConfirmation] = []
        var accept = true
        var starts = 0
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
            commandShortcuts: AppShortcutStore(defaults: defaults), copySettings: ResultCopySettings(defaults: defaults), editorThemes: themes,
            appearance: AppAppearance(defaults: defaults, editorThemes: themes), sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: SQLLibrary(),
            tableBrowsePresets: TableBrowsePresetStore(fileURL: folder.appendingPathComponent("presets.json")), logicalRelationships: LogicalRelationshipStore(fileURL: folder.appendingPathComponent("relationships.json")),
            resultSnapshots: ResultSnapshotsModel(store: snapshots), planArtifacts: PlanArtifactsModel(store: plans),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { decisions.append($0); return accept },
            helperFactory: { starts += 1; return BackendClient(executableURL: executable) })
        await workspace.start()
        let name = "e3_native_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let schema = engine == .sqlite ? "main" : engine == .postgresql ? "public" : settings.database
        var cleanup: SQLDocument?
        do {
            try #require(await workspace.library.saveConnection(name: "Destructive structure fixture", settings: settings))
            let profile = try #require(workspace.library.selectedConnectionId)
            let sql = workspace.newDocument(profileID: profile); cleanup = sql
            let label = engine == .postgresql ? "VARCHAR(40) COLLATE pg_catalog.\"C\"" : engine == .mysql ? "VARCHAR(40) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin" : "TEXT"
            await workspace.run(sql, sql: "CREATE TABLE \(name)(id INTEGER PRIMARY KEY,amount BIGINT,label \(label),doomed TEXT,kept TEXT)")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            await workspace.run(sql, sql: "INSERT INTO \(name) VALUES(1,7,'é','remove',NULL),(2,NULL,'NULL',NULL,'')")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            let node = CatalogNode(profileID: profile, name: name, kind: .object, schema: schema, objectKind: "table")
            await workspace.openTableStructure(node, create: false)
            let model = try #require(workspace.structureEditor)
            try #require(model.error == nil && model.destructiveAvailable)
            if engine != .sqlite {
                model.draft = .init(columns: [], changes: [.init(name: "amount", type: .init(kind: "integer"))], allowDestructive: true, authoringVersion: 4)
                let beforePreview = decisions.count
                await model.preparePreview()
                let plan = try #require(model.preview)
                try #require(model.error == nil && !plan.consequences.isEmpty && !plan.validationChecks.isEmpty)
                #expect(decisions.count == beforePreview && model.validation == nil)
                await model.validateData()
                let validation = try #require(model.validation)
                try #require(model.error == nil && validation.state == "completed" && validation.checks.contains { $0.state == "passed" && $0.invalidRows == "0" })
                let validationDecision = try #require(decisions.last)
                #expect(validationDecision.operations.first?.type == "structure.validate" && validationDecision.operations.first?.structure?.digest == plan.digest)
                #expect(validationDecision.generatedPreview?.contains(plan.validationChecks.first?.sql ?? "missing") == true)
                accept = false
                let beforeCancel = decisions.count
                await model.apply()
                #expect(decisions.count == beforeCancel + 1 && model.preview == plan && model.outcome == nil && model.validation == validation)
                #expect(decisions.last?.generatedPreview?.contains("Digest: " + plan.digest) == true)
                await workspace.run(sql, sql: "SELECT amount FROM \(name) ORDER BY id")
                #expect(sql.runtime?.result?.rows == [["7"], [nil]])
                accept = true
                await model.apply()
                try #require(model.outcome?.state == "applied" && model.outcomeReview?.validation == validation)
                #expect(model.outcome?.observed?.columns.first { $0.name == "amount" }?.editableType?.kind == "integer")
                await model.load()
                if engine == .postgresql {
                    model.draft = .init(columns: [], changes: [.init(name: "amount", type: .init(kind: "bigint"), usingExpression: "amount::bigint")], allowDestructive: true)
                } else {
                    model.draft = .init(columns: [], changes: [.init(name: "amount", unsigned: true)], allowDestructive: true)
                }
                await model.preparePreview(); try #require(model.preview != nil && model.error == nil)
                await model.validateData(); try #require(model.validation != nil && model.error == nil)
                if engine == .postgresql { #expect(model.validation?.checks.contains { $0.state == "unavailable" } == true) }
                await model.apply(); try #require(model.outcome?.state == "applied")
                if engine == .mysql { #expect(model.outcome?.observed?.columns.first { $0.name == "amount" }?.unsigned == true) }
                await model.load()
                model.draft = .init(columns: [], changes: [.init(name: "label", collation: .init(schema: engine == .postgresql ? "pg_catalog" : "", name: engine == .postgresql ? "C" : "utf8mb4_general_ci"))], allowDestructive: true)
                if engine == .mysql { model.draft.changes?[0].charset = "utf8mb4" }
                await model.preparePreview(); try #require(model.preview != nil && model.error == nil)
                await model.apply(); try #require(model.outcome?.state == "applied")
                #expect(model.outcome?.observed?.columns.first { $0.name == "label" }?.collation?.name == (engine == .postgresql ? "C" : "utf8mb4_general_ci"))
                await model.load()
            } else { #expect(!model.conversionAvailable) }
            model.draft = .init(columns: [], changes: [.init(name: "doomed", drop: true)], allowDestructive: true)
            let beforeDropPreview = decisions.count
            await model.preparePreview()
            let drop = try #require(model.preview)
            try #require(model.error == nil && !drop.consequences.isEmpty && !drop.validationChecks.isEmpty)
            #expect(model.validation == nil && decisions.count == beforeDropPreview)
            await model.validateData(); try #require(model.validation != nil)
            await model.apply()
            let review = try #require(model.outcomeReview)
            try #require(review.outcome.state == "applied" && review.outcome.steps.allSatisfy { $0.state == "applied" })
            #expect(review.outcome.observed?.columns.contains { $0.name == "doomed" } == false)
            await workspace.run(sql, sql: "SELECT id,amount,label,kept FROM \(name) ORDER BY id")
            #expect(sql.runtime?.result?.rows == [["1", "7", "é", nil], ["2", nil, "NULL", ""]])
            let startsBeforeEvidence = starts
            let artifact = try SavedEvidenceArtifact.capture(model, title: "Destructive outcome")
            let reference = try #require(await workspace.savedEvidence.save(artifact))
            let offline = try await plans.loadEvidence(reference.id)
            #expect(starts == startsBeforeEvidence && offline.version == SavedEvidenceArtifact.currentVersion && offline.structure?.validation == review.validation)
            #expect(offline.structure?.displayReview.plan.consequences == review.plan.consequences)
            await model.load()
            model.draft = .init(columns: [], allowDestructive: true, dropTable: true)
            await model.preparePreview(); try #require(model.preview?.droppedTarget == true && model.error == nil)
            await model.apply()
            try #require(model.outcome?.state == "applied" && model.outcome?.droppedTarget == true && model.targetWasDropped)
            let dropped = try SavedEvidenceArtifact.capture(model, title: "Dropped table")
            #expect(dropped.valid && dropped.structure?.droppedTarget == true && dropped.structure?.state == "applied")
            await model.checkExecutionStatus()
            #expect(model.targetWasDropped && model.outcomeReview?.plan.target.table == name && model.error == nil)
            await workspace.closeTableStructure()
        } catch {
            await workspace.closeTableStructure()
            if let sql = cleanup { accept = true; await workspace.run(sql, sql: "DROP TABLE IF EXISTS \(name)") }
            await workspace.shutdown()
            throw error
        }
        await workspace.shutdown()
    }
}
