import Foundation
import Testing
@testable import DBeer

@MainActor
private final class PhysicalIntegrationDecisions {
    var approve = true
    var reviews: [OperationConfirmation] = []
    var helpers = 0
}

/// Private state and runner credentials only. No SSH, keychain, file watchers,
/// NSApp, views/windows, default review/parameter/options/close presenters.
@MainActor
private final class PhysicalIntegrationFixture {
    let workspace: ApplicationWorkspace
    let profile: SavedConnection
    let document: SQLDocument
    let directory: URL
    let decisions: PhysicalIntegrationDecisions
    let schema: String
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let defaults: UserDefaults
    private let defaultsName: String
    private var tables: [String] = []
    init(workspace: ApplicationWorkspace, profile: SavedConnection, directory: URL, decisions: PhysicalIntegrationDecisions,
         defaults: UserDefaults, defaultsName: String, schema: String) {
        self.workspace = workspace; self.profile = profile; self.directory = directory; self.decisions = decisions
        self.defaults = defaults; self.defaultsName = defaultsName; self.schema = schema
        document = workspace.newDocument(profileID: profile.id)
    }
    static func make(_ engine: DatabaseEngine) async throws -> PhysicalIntegrationFixture {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("build/physical-native-integration/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let settings: ConnectionSettings
        if engine == .mysql {
            settings = .init(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost", port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")), database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: env["DBEER_TEST_MYSQL_USER"] ?? "dbeer", password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: "disable", engine: .mysql)
        } else {
            let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
            settings = .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        let profile = SavedConnection(name: "Isolated physical operation", settings: settings)
        let credentials = MemoryConnectionCredentialStore(); await credentials.savePassword(settings.password, for: profile.id)
        let defaultsName = "DBeer.PhysicalIntegration." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let snapshots = ResultSnapshotStore(rootURL: directory.appendingPathComponent("snapshots"))
        let plans = PlanArtifactStore(rootURL: directory.appendingPathComponent("evidence"))
        let themes = EditorThemeStore(defaults: defaults, directory: directory.appendingPathComponent("themes"))
        let decisions = PhysicalIntegrationDecisions()
        let executable = env["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library: .init(connections: [profile], selectedConnectionId: profile.id)),
            credentialStore: credentials, documentStore: MemorySQLDocumentStore(), commandShortcuts: AppShortcutStore(defaults: defaults),
            copySettings: ResultCopySettings(defaults: defaults), editorThemes: themes, appearance: AppAppearance(defaults: defaults, editorThemes: themes),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: SQLLibrary(),
            tableBrowsePresets: TableBrowsePresetStore(fileURL: directory.appendingPathComponent("presets.json")),
            logicalRelationships: LogicalRelationshipStore(fileURL: directory.appendingPathComponent("relationships.json")),
            resultSnapshots: ResultSnapshotsModel(store: snapshots), planArtifacts: PlanArtifactsModel(store: plans),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { review in
                decisions.reviews.append(review); return decisions.approve
            }, queryParameterDecision: { _, _ in nil }, explainOptionsDecision: { _ in nil }, helperFactory: {
                decisions.helpers += 1; return BackendClient(executableURL: executable)
            })
        await workspace.start(); await workspace.connectProfile(profile.id)
        let fixture = PhysicalIntegrationFixture(workspace: workspace, profile: profile, directory: directory, decisions: decisions,
            defaults: defaults, defaultsName: defaultsName, schema: engine == .postgresql ? "public" : settings.database)
        guard workspace.services[profile.id]?.connectionState == .connected else {
            await fixture.finish(); throw ExecutionPolicyError(message: "The disposable test profile did not connect.")
        }
        return fixture
    }
    func own(_ stem: String) -> String { let name = "e6n_" + stem + "_" + suffix; tables.append(name); return name }
    func run(_ sql: String) async throws {
        await workspace.run(document, sql: sql)
        try #require(document.localError == nil && document.runtime?.queryFailure == nil)
    }
    var rows: [[String?]]? { document.runtime?.result?.rows }
    func open(_ table: String) throws -> PhysicalStructureModel {
        let node = CatalogNode(profileID: profile.id, name: table, kind: .object, schema: schema, objectKind: "table")
        try #require(workspace.canManagePhysicalStructure(node))
        workspace.openPhysicalStructure(node)
        return try #require(workspace.physicalStructure)
    }
    func close() async { await workspace.closePhysicalStructure() }
    func finish() async {
        decisions.approve = true; await close()
        for table in tables.reversed() { await workspace.run(document, sql: "DROP TABLE IF EXISTS " + table + (profile.engine == .postgresql ? " CASCADE" : "")) }
        await workspace.shutdown()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Normal ApplicationWorkspace + shared helper, independent service/tab/physical
/// owners and disposable tables. All stores and user decisions are injected.
@Suite(.serialized)
@MainActor
struct PhysicalStructureIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresConcurrentSuccessAndInvalidFailureUseExactNativeReview() async throws {
        let f = try await PhysicalIntegrationFixture.make(.postgresql)
        do {
            let table = f.own("index"), index = "e6i_" + f.suffix, failedIndex = "e6bad_" + f.suffix
            try await f.run("CREATE TABLE \(table)(id INTEGER NOT NULL)")
            try await f.run("INSERT INTO \(table) VALUES(1),(1)")
            let model = try f.open(table)
            await model.inspect()
            try #require(model.error == nil && model.operationKinds.contains("concurrentIndex"))
            model.intent = .init(kind: "concurrentIndex", index: .init(action: "add", name: index, columns: ["id"]))
            await model.preparePreview()
            let plan = try #require(model.preview)
            #expect(plan.transactionMode == "outsideTransaction" && plan.sql.count == 1 && plan.sql[0].contains("CONCURRENTLY"))
            let before = f.decisions.reviews.count
            f.decisions.approve = false; await model.apply()
            #expect(model.report == nil && model.preview == plan && f.decisions.reviews.count == before + 1)
            try await f.run("SELECT count(*) FROM pg_catalog.pg_class WHERE relname='\(index)'")
            #expect(f.rows == [["0"]])
            f.decisions.approve = true; await model.apply()
            let report = try #require(model.report)
            try #require(report.outcome.state == "applied" && report.outcome.steps.map(\.state) == ["applied"])
            #expect(f.decisions.reviews.last?.generatedPreview?.contains(plan.digest) == true)
            #expect(f.decisions.reviews.last?.generatedPreview?.contains(plan.objects[0].fingerprint) == true)
            await model.checkStatus(); #expect(model.report?.id == report.id && !model.canApply)
            await f.close()
            let failed = try f.open(table)
            failed.intent = .init(kind: "concurrentIndex", index: .init(action: "add", name: failedIndex, columns: ["id"], unique: true))
            await failed.preparePreview(); try #require(failed.preview != nil)
            await failed.apply()
            try #require(failed.report?.outcome.state == "failed")
            #expect(failed.objects.first?.indexes.contains { $0.name == failedIndex && !$0.valid } == true)
            try await f.run("SELECT i.indisvalid::text FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid=i.indexrelid WHERE c.relname='\(failedIndex)'")
            #expect(f.rows == [["false"]])
            await failed.reconcile(); #expect(failed.report?.outcome.state == "failed" && !failed.canPreview)
            try await f.run("SELECT count(*) FROM \(table)"); #expect(f.rows == [["2"]])
        } catch { await f.finish(); throw error }
        await f.finish()
    }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresPartitionCreateAndConcurrentDetachPreserveIndependentNativeOwners() async throws {
        let f = try await PhysicalIntegrationFixture.make(.postgresql)
        do {
            let parent = f.own("range"), child = f.own("child")
            try await f.run("CREATE TABLE \(parent)(id INTEGER NOT NULL) PARTITION BY RANGE(id)")
            let model = try f.open(parent)
            let childTarget = StructureTarget(schema: f.schema, table: child, create: false)
            let bound = StructurePhysicalBound(kind: "range", from: [.init(kind: "integer", value: "0")], to: [.init(kind: "integer", value: "10")])
            await model.inspect(); try #require(model.error == nil && model.operationKinds.contains("createPartition"))
            model.intent = .init(kind: "createPartition", child: childTarget, bound: bound)
            await model.preparePreview(); try #require(model.preview?.transactionMode == "transaction")
            await model.apply(); try #require(model.report?.outcome.state == "applied")
            try await f.run("INSERT INTO \(parent) VALUES(1)")
            await f.close()
            let detach = try f.open(parent)
            await detach.inspect(); detach.intent = .init(kind: "detachPartition", child: childTarget, concurrent: true)
            await detach.preparePreview(); let plan = try #require(detach.preview)
            #expect(plan.transactionMode == "outsideTransaction" && plan.sql[0].contains("CONCURRENTLY"))
            await detach.apply(); try #require(detach.report?.outcome.state == "applied")
            await detach.checkStatus(); #expect(detach.report?.plan == plan && !detach.canApply)
            try await f.run("SELECT count(*) FROM \(parent)"); #expect(f.rows == [["0"]])
            try await f.run("SELECT count(*) FROM \(child)"); #expect(f.rows == [["1"]])
            let evidence = try #require(detach.report)
            let file = f.directory.appendingPathComponent("review.dbeerphysicalreport")
            await detach.saveReport(to: file, expected: evidence, version: nil)
            #expect(try PhysicalStructureReport.decode(SQLFileBinding.read(file).text) == evidence)
            await f.close()
            let reopen = try f.open(parent), helpers = f.decisions.helpers
            await reopen.openReport(from: file)
            #expect(reopen.openedReport == evidence && reopen.report == nil && reopen.preview == nil && !reopen.canCheckStatus && f.decisions.helpers == helpers)
            #expect(f.workspace.physicalStructureReports.count == 2)
        } catch { await f.finish(); throw error }
        await f.finish()
    }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlStrictOnlineIndexAndStorageEngineUseNormalNativeWorkflow() async throws {
        let f = try await PhysicalIntegrationFixture.make(.mysql)
        do {
            let table = f.own("online"), index = "e6i_" + f.suffix
            try await f.run("CREATE TABLE \(table)(id INTEGER NOT NULL PRIMARY KEY,payload INTEGER) ENGINE=InnoDB")
            try await f.run("INSERT INTO \(table) VALUES(1,7)")
            let model = try f.open(table)
            await model.inspect(); try #require(model.error == nil && model.operationKinds.contains("onlineIndex"))
            model.intent = .init(kind: "onlineIndex", index: .init(action: "add", name: index, columns: ["payload"]), algorithm: "INPLACE", lock: "NONE")
            await model.preparePreview(); let plan = try #require(model.preview)
            #expect(plan.transactionMode == "implicitCommit" && plan.sql[0].contains("ALGORITHM=INPLACE") && plan.sql[0].contains("LOCK=NONE"))
            await model.apply(); try #require(model.report?.outcome.state == "applied")
            await f.close()
            let engine = try f.open(table)
            engine.intent = .init(kind: "storageEngine", engine: "MyISAM", algorithm: "COPY", lock: "EXCLUSIVE")
            await engine.preparePreview(); try #require(engine.preview != nil)
            await engine.apply(); try #require(engine.report?.outcome.state == "applied")
            #expect(engine.objects.first?.storageEngine == "MyISAM")
            try await f.run("SELECT id,payload FROM \(table)"); #expect(f.rows == [["1", "7"]])
            #expect(!engine.canApply && !engine.canPreview)
        } catch { await f.finish(); throw error }
        await f.finish()
    }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlTypedRangePartitionAndTruncateAreReviewedSeparately() async throws {
        let f = try await PhysicalIntegrationFixture.make(.mysql)
        do {
            let table = f.own("partition")
            try await f.run("CREATE TABLE \(table)(id INTEGER NOT NULL PRIMARY KEY,payload INTEGER) ENGINE=InnoDB")
            try await f.run("INSERT INTO \(table) VALUES(1,7),(11,8)")
            let model = try f.open(table)
            let definitions = [StructurePhysicalPartitionDefinition(name: "p0", bound: .init(kind: "range", to: [.init(kind: "integer", value: "10")])),
                .init(name: "pmax", bound: .init(kind: "range", to: [.init(kind: "max")]))]
            model.intent = .init(kind: "partitionTable", algorithm: "COPY", lock: "SHARED", definitions: definitions, method: "range", columns: ["id"])
            await model.preparePreview(); let plan = try #require(model.preview)
            #expect(plan.sql[0].contains("PARTITION BY RANGE") && plan.sql[0].contains("ALGORITHM=COPY") && plan.sql[0].contains("LOCK=SHARED"))
            await model.apply(); try #require(model.report?.outcome.state == "applied")
            await f.close()
            let truncate = try f.open(table)
            await truncate.inspect(); try #require(truncate.operationKinds.contains("truncatePartition"))
            truncate.intent = .init(kind: "truncatePartition", algorithm: "INPLACE", lock: "NONE", partitions: ["p0"])
            await truncate.preparePreview(); try #require(truncate.preview?.destructive == true)
            await truncate.apply(); try #require(truncate.report?.outcome.state == "applied")
            #expect(truncate.report?.plan.draft.intent.partitions == ["p0"] && !truncate.canApply)
            try await f.run("SELECT id,payload FROM \(table) ORDER BY id"); #expect(f.rows == [["11", "8"]])
            await truncate.checkStatus(); await truncate.reconcile()
            #expect(truncate.report?.outcome.state == "applied" && truncate.report?.outcome.reconciled == true)
        } catch { await f.finish(); throw error }
        await f.finish()
    }
}
