import Foundation
import Testing
@testable import DBeer

/// Real workspace factory and bundled helper against owned database fixtures.
/// Private stores/preferences and every decision are injected; no AppKit, views,
/// windows, activation, watchers, SSH, login Keychain or default dialog callbacks.
@Suite(.serialized)
@MainActor
struct TableStructureReconstructionIntegrationTests {
    @Test func sqliteBackfillAndPhysicalReconstructionPreserveTypedRowsAndDependents() async throws { try await exercise(.sqlite) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresBackfillAndPhysicalReconstructionUseActualWorkspace() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlBackfillAndNativePhysicalReconstructionUseActualWorkspace() async throws { try await exercise(.mysql) }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = env["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let folder = root.appendingPathComponent("build/reconstruction-integration/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let defaultsName = "DBeer.ReconstructionIntegration." + UUID().uuidString
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
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { decisions.append($0); return accept }, queryParameterDecision: { _, _ in nil },
            helperFactory: { starts += 1; return BackendClient(executableURL: executable) })
        await workspace.start()
        let name = "e4_native_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let parent = name + "_p", child = name + "_c", audit = name + "_a", index = name + "_i", trigger = name + "_t"
        let schema = engine == .sqlite ? "main" : engine == .postgresql ? "public" : settings.database
        var cleanup: SQLDocument?
        do {
            try #require(await workspace.library.saveConnection(name: "Reconstruction fixture", settings: settings))
            let profile = try #require(workspace.library.selectedConnectionId)
            let sql = workspace.newDocument(profileID: profile); cleanup = sql
            func run(_ text: String) async throws {
                await workspace.run(sql, sql: text)
                try #require(sql.localError == nil && sql.runtime?.queryFailure == nil)
            }
            if engine == .sqlite {
                try await run("CREATE TABLE \(parent)(k INTEGER PRIMARY KEY)")
                try await run("INSERT INTO \(parent) VALUES(1)")
                try await run("CREATE TABLE \(audit)(v INTEGER)")
                try await run("CREATE TABLE \(name)(id INTEGER PRIMARY KEY AUTOINCREMENT,label VARCHAR(40) COLLATE NOCASE UNIQUE CHECK(length(label)<30),p INTEGER REFERENCES \(parent)(k) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,mixed,derived TEXT GENERATED ALWAYS AS(label||':kept') STORED)")
                try await run("CREATE INDEX \(index) ON \(name)(lower(label)) WHERE p IS NOT NULL")
                try await run("CREATE TRIGGER \(trigger) AFTER INSERT ON \(name) BEGIN INSERT INTO \(audit) VALUES(NEW.id); END")
                try await run("CREATE TABLE \(child)(id INTEGER REFERENCES \(name)(id) ON DELETE CASCADE)")
                try await run("INSERT INTO \(name)(id,label,p,mixed) VALUES(1,'one',1,NULL),(2,'two',1,''),(3,'three',1,'NULL'),(4,'four',1,9223372036854775807),(5,'five',1,X'00FF'),(50,'deleted',1,NULL)")
                try await run("DELETE FROM \(name) WHERE id=50")
                try await run("INSERT INTO \(child) VALUES(1)")
            } else {
                let identity = engine == .mysql ? " AUTO_INCREMENT" : ""
                let label = engine == .mysql ? "VARCHAR(40) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin" : "TEXT"
                try await run("CREATE TABLE \(name)(id INTEGER NOT NULL\(identity) PRIMARY KEY,label \(label) NOT NULL UNIQUE,mixed TEXT)")
                try await run("CREATE INDEX \(index) ON \(name)(\(engine == .mysql ? "label" : "mixed"))")
                try await run("INSERT INTO \(name)(id,label,mixed) VALUES(1,'one',NULL),(2,'two',''),(3,'three','NULL')")
                if engine == .mysql {
                    try await run("CREATE TABLE \(audit)(v INTEGER)")
                    try await run("CREATE TRIGGER \(trigger) AFTER INSERT ON \(name) FOR EACH ROW INSERT INTO \(audit) VALUES(NEW.id)")
                    try await run("CREATE TABLE \(child)(id INTEGER,FOREIGN KEY(id) REFERENCES \(name)(id) ON DELETE CASCADE)")
                    try await run("INSERT INTO \(child) VALUES(1)")
                }
            }
            let projection = engine == .sqlite ? "id,label,p,mixed,derived" : "id,label,mixed"
            try await run("SELECT \(projection) FROM \(name) ORDER BY id")
            let original = try #require(sql.runtime?.result)
            let originalRows = original.rows, originalTyped = original.sqliteValues
            let node = CatalogNode(profileID: profile, name: name, kind: .object, schema: schema, objectKind: "table")
            await workspace.openTableStructure(node, create: false)
            let model = try #require(workspace.structureEditor)
            try #require(model.error == nil && model.reconstructionAvailable && model.destructiveAvailable)
            let expression = engine == .mysql ? "CONCAT(label,':required')" : "label || ':required'"
            let type = engine == .mysql ? StructureDataType(kind: "varchar", length: 80) : .init(kind: "text")
            model.draft = .init(columns: [.init(name: "required", type: type, nullable: false, default: .init(kind: "none"))], allowDestructive: true, backfills: [.init(column: "required", expression: expression)])
            let beforePreview = decisions.count
            await model.preparePreview()
            let backfill = try #require(model.preview)
            try #require(model.error == nil && backfill.sql.joined(separator: "\n").contains(expression))
            #expect(decisions.count == beforePreview && model.validation == nil && backfill.validationChecks.allSatisfy { $0.sql == nil && $0.unavailableReason != nil })
            await model.validateData()
            let validation = try #require(model.validation)
            #expect(validation.checks.allSatisfy { $0.state == "unavailable" })
            accept = false; let beforeDecline = decisions.count; await model.apply()
            #expect(decisions.count == beforeDecline + 1 && model.preview == backfill && model.outcome == nil)
            #expect(decisions.last?.generatedPreview?.contains("Digest: " + backfill.digest) == true)
            accept = true; await model.apply()
            let backfillReview = try #require(model.outcomeReview)
            try #require(backfillReview.outcome.state == "applied" && backfillReview.validation == validation && backfillReview.outcome.steps.count == backfill.sql.count)
            #expect(backfillReview.draft.backfills?.first?.expression == expression)
            try await run("SELECT \(projection) FROM \(name) ORDER BY id")
            #expect(sql.runtime?.result?.rows == originalRows && sql.runtime?.result?.sqliteValues == originalTyped)
            try await run("SELECT required FROM \(name) ORDER BY id")
            #expect(sql.runtime?.result?.rows == (engine == .sqlite ? ["one", "two", "three", "four", "five"] : ["one", "two", "three"]).map { [$0 + ":required"] })
            await model.load()
            let names = try #require(model.baseline?.columns.map(\.name)), order = Array(names.reversed())
            model.draft = .init(columns: [], allowDestructive: true, columnOrder: order, reconstruct: true)
            let beforePhysical = decisions.count; await model.preparePreview()
            let physical = try #require(model.preview)
            try #require(model.error == nil && physical.validationChecks.isEmpty && !model.canValidateData)
            #expect(decisions.count == beforePhysical)
            accept = false; await model.apply()
            #expect(model.preview == physical && model.outcome == nil && decisions.last?.generatedPreview?.contains("Digest: " + physical.digest) == true)
            accept = true; await model.apply()
            let review = try #require(model.outcomeReview)
            try #require(review.outcome.state == "applied" && review.outcome.steps.allSatisfy { $0.state == "applied" })
            #expect(review.outcome.observed?.columns.map(\.name) == order && model.historyReviews.last?.draft.backfills?.first?.expression == expression)
            #expect(review.outcome.observed?.indexes?.contains { StructureTarget.sameIdentifier($0.name, index) } == true)
            try await run("SELECT \(projection) FROM \(name) ORDER BY id")
            #expect(sql.runtime?.result?.rows == originalRows && sql.runtime?.result?.sqliteValues == originalTyped)
            if engine != .postgresql {
                try await run("SELECT count(*) FROM \(child)"); #expect(sql.runtime?.result?.rows == [["1"]])
                try await run("INSERT INTO \(name)(label,mixed,required) VALUES('after','kept','explicit')")
                try await run("SELECT max(id) FROM \(name)"); #expect(sql.runtime?.result?.rows == [[engine == .sqlite ? "51" : "4"]])
                try await run("SELECT count(*) FROM \(audit) WHERE v=\(engine == .sqlite ? 51 : 4)"); #expect(sql.runtime?.result?.rows == [["1"]])
                if engine == .sqlite {
                    for values in ["'ONE',1", "'123456789012345678901234567890',1", "'bad-parent',999"] {
                        await workspace.run(sql, sql: "INSERT INTO \(name)(label,p,required) VALUES(\(values),'explicit')")
                        #expect(sql.runtime?.queryFailure != nil)
                    }
                }
                try await run(engine == .sqlite ? "DELETE FROM \(parent) WHERE k=1" : "DELETE FROM \(name) WHERE id=1")
                try await run("SELECT count(*) FROM \(child)"); #expect(sql.runtime?.result?.rows == [["0"]])
            }
            let beforeSave = starts
            let saved = try SavedEvidenceArtifact.capture(model, title: "Physical reconstruction")
            let reference = try #require(await workspace.savedEvidence.save(saved)), restored = try await plans.loadEvidence(reference.id)
            #expect(starts == beforeSave && restored.version == 4 && restored.structure?.draft.columnOrder == order && restored.structure?.sql == physical.sql)
            await model.checkExecutionStatus()
            #expect(model.outcome?.state == "applied" && model.preview == nil && !model.canApply)
            await model.load()
            #expect(model.historyReviews.last?.draft.columnOrder == order && model.preview == nil)
            await workspace.closeTableStructure()
            if engine != .postgresql { try await run("DROP TABLE \(child)") }
            try await run("DROP TABLE \(name)")
            if engine != .postgresql { try await run("DROP TABLE \(audit)") }
            if engine == .sqlite { try await run("DROP TABLE \(parent)") }
        } catch {
            accept = true; await workspace.closeTableStructure()
            if let sql = cleanup {
                for table in [child, name, audit, parent] { await workspace.run(sql, sql: "DROP TABLE IF EXISTS \(table)") }
            }
            await workspace.shutdown(); throw error
        }
        await workspace.shutdown()
    }
}
