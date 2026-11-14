import Foundation
import Testing
@testable import DBeer

/// Normal helper, runner-owned databases and temporary tables. Decisions and
/// stores are private and injected; no UI, default prompts, SSH or activation.
@Suite(.serialized)
@MainActor
struct ExplainDMLIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresNativeDMLUsesTheChosenSessionAndPreservesItsTransaction() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlNativeDMLUsesExplicitMultiTableForms() async throws { try await exercise(.mysql) }
    @Test func sqliteNativeEstimatedDMLNeverExecutesTheMutation() async throws { try await exercise(.sqlite) }

    private final class Decisions {
        var mode = ExplainMode.plan
        var values: [QueryParameterBinding] = []
        var reviews: [OperationConfirmation] = []
        var options = 0
    }
    private func exercise(_ engine: DatabaseEngine) async throws {
        let environment = ProcessInfo.processInfo.environment
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/explain-dml-integration/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings: ConnectionSettings
        if engine == .sqlite {
            let file = directory.appendingPathComponent("private.sqlite")
            try Data().write(to: file)
            settings = .init(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite,
                sqlite: .init(path: file.path))
        } else if engine == .mysql {
            settings = .init(host: environment["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
                port: try #require(Int(environment["DBEER_TEST_MYSQL_PORT"] ?? "")), database: environment["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer",
                user: environment["DBEER_TEST_MYSQL_USER"] ?? "dbeer", password: environment["DBEER_TEST_MYSQL_PASSWORD"] ?? "",
                sslMode: environment["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable", sslRootCert: environment["DBEER_TEST_MYSQL_CA_FILE"], engine: .mysql)
        } else {
            let url = try #require(URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""))
            settings = .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()),
                user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        let profile = SavedConnection(name: "Native DML isolated owner", settings: settings)
        let credentials = MemoryConnectionCredentialStore()
        await credentials.savePassword(settings.password, for: profile.id)
        let defaultsName = "dbeer-explain-dml-integration-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let themes = EditorThemeStore(defaults: defaults, directory: directory.appendingPathComponent("themes"))
        let snapshots = ResultSnapshotStore(rootURL: directory.appendingPathComponent("snapshots"))
        let plans = PlanArtifactStore(rootURL: directory.appendingPathComponent("plans"))
        let decisions = Decisions()
        let executable = environment["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let client = BackendClient(executableURL: executable)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            .init(connections: [profile], selectedConnectionId: profile.id)), credentialStore: credentials,
            documentStore: MemorySQLDocumentStore(), commandShortcuts: AppShortcutStore(defaults: defaults),
            copySettings: ResultCopySettings(defaults: defaults), editorThemes: themes, appearance: AppAppearance(defaults: defaults, editorThemes: themes),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: SQLLibrary(),
            tableBrowsePresets: TableBrowsePresetStore(fileURL: directory.appendingPathComponent("presets.json")),
            logicalRelationships: LogicalRelationshipStore(fileURL: directory.appendingPathComponent("relationships.json")),
            resultSnapshots: ResultSnapshotsModel(store: snapshots), planArtifacts: PlanArtifactsModel(store: plans),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { confirmation in
                if let request = confirmation.operations.first?.explain {
                    #expect(request.sql == confirmation.sourceSQL && request.parameters == decisions.values)
                    #expect((request.writeIntent != nil) == (decisions.mode == .analyze))
                    #expect(confirmation.assessment.operations.first?.explain?.dml != nil)
                }
                decisions.reviews.append(confirmation)
                return true
            }, queryParameterDecision: { definitions, _ in
                #expect(definitions == decisions.values.map { SQLParameterDefinition(name: $0.name, type: $0.type) })
                return decisions.values
            }, explainOptionsDecision: { _ in decisions.options += 1; return .use(nil) }, helperFactory: { client })
        await workspace.library.loadConnections()
        let name = "f6_native_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let other = name + "_other"
        let target = workspace.newDocument(profileID: profile.id, text: "")
        let source = workspace.newDocument(profileID: profile.id, text: "")
        do {
            try await execute(workspace, target, "CREATE TEMPORARY TABLE \(name) (id INTEGER PRIMARY KEY, label VARCHAR(80))")
            try await execute(workspace, target, "INSERT INTO \(name) VALUES (1, 'original')")
            if engine == .mysql {
                try await execute(workspace, target, "CREATE TEMPORARY TABLE \(other) (id INTEGER PRIMARY KEY)")
                try await execute(workspace, target, "INSERT INTO \(other) VALUES (1)")
            }
            let session = try #require(target.runtime?.sessionId)
            #expect(workspace.services[profile.id]?.sessionId != session && source.runtime == nil)
            let values = [QueryParameterBinding(name: "id", type: .integer, value: "1"),
                QueryParameterBinding(name: "value", type: .text, value: "exact e\u{0301}' value")]
            let update = engine == .mysql ?
                "UPDATE \(name) a, \(other) b SET a.label = :value WHERE a.id = b.id AND a.id = :id" :
                "UPDATE \(name) SET label = :value WHERE id = :id"
            for sql in ["INSERT INTO \(name) VALUES (:id, :value)", update] {
                try await explain(workspace, source: source, target: target, sql: sql, values: values, mode: .plan, decisions: decisions)
            }
            try await execute(workspace, target, "SELECT label FROM \(name) WHERE id = 1")
            #expect(target.runtime?.result?.rows?.first?.first == "original")
            let runtimeAvailable = target.runtime?.explainSupport?.dml?.analyze.isEmpty == false
            if !runtimeAvailable {
                #expect(target.runtime?.transactionStatus == .idle && source.explainPlan?.request.writeIntent == nil)
                #expect(target.runtime?.explainSupport?.dml?.analyzeTargetExecution == "unavailable")
            } else {
                try await explain(workspace, source: source, target: target, sql: update, values: values, mode: .analyze, decisions: decisions)
                #expect(source.explainPlan?.dmlOutcome?.persistence == (engine == .mysql ? "notExecuted" : "committed"))
                #expect(source.explainPlan?.dmlOutcome?.targetExecution == (engine == .mysql ? "suppressed" : "executed"))
                #expect(source.explainPlan?.result?.support.dml?.analyzeTargetExecution == (engine == .mysql ? "suppresses" : "executes"))
                try await execute(workspace, target, "SELECT label FROM \(name) WHERE id = 1")
                #expect(target.runtime?.result?.rows?.first?.first == (engine == .mysql ? "original" : values[1].value))
                try await execute(workspace, target, "BEGIN")
                let pendingValues = [values[0], QueryParameterBinding(name: "value", type: .text, value: "pending change")]
                try await explain(workspace, source: source, target: target, sql: update, values: pendingValues, mode: .analyze, decisions: decisions)
                #expect(source.explainPlan?.dmlOutcome?.persistence == (engine == .mysql ? "notExecuted" : "transactionPending"))
                #expect(target.runtime?.transactionStatus == .transaction)
                try await execute(workspace, target, "ROLLBACK")
                try await execute(workspace, target, "SELECT label FROM \(name) WHERE id = 1")
                #expect(target.runtime?.result?.rows?.first?.first == (engine == .mysql ? "original" : values[1].value))
                let delete = engine == .mysql ? "DELETE a FROM \(name) a JOIN \(other) b ON a.id = b.id WHERE a.id = :id" : "DELETE FROM \(name) WHERE id = :id"
                try await explain(workspace, source: source, target: target, sql: delete, values: [values[0]], mode: .analyze, decisions: decisions)
                try await execute(workspace, target, "SELECT count(*) FROM \(name)")
                #expect(target.runtime?.result?.rows?.first?.first == (engine == .mysql ? "1" : "0"))
                if engine == .postgresql {
                    try await explain(workspace, source: source, target: target, sql: "INSERT INTO \(name) VALUES (:id, :value)",
                        values: values, mode: .analyze, decisions: decisions)
                    try await execute(workspace, target, "SELECT label FROM \(name) WHERE id = 1")
                    #expect(target.runtime?.result?.rows?.first?.first == values[1].value)
                    let cte = "WITH changed AS (UPDATE \(name) SET label = :value WHERE id = :id RETURNING id) SELECT * FROM changed"
                    try await explain(workspace, source: source, target: target, sql: cte, values: pendingValues, mode: .analyze, decisions: decisions)
                    #expect(source.explainPlan?.dmlOutcome?.target.dataModifyingCTE == true)
                    try await execute(workspace, target, "SELECT label FROM \(name) WHERE id = 1")
                    #expect(target.runtime?.result?.rows?.first?.first == "pending change")
                }
            }
            #expect(target.runtime?.sessionId == session && source.runtime == nil)
            let plan = try #require(source.explainPlan)
            let saved = try await plans.save(PlanArtifact.capture(plan, title: "Isolated DML evidence"))
            let offline = try await plans.load(saved.id)
            #expect(offline.version == 6 && offline.request.writeIntent == nil && offline.request.context == nil)
            #expect(offline.result.dml == plan.dmlOutcome && offline.displayPlan.sessionID == nil)
            #expect(try PlanArtifact.decode(offline.encoded()) == offline)
            try await execute(workspace, target, "DROP TABLE \(name)")
            if engine == .mysql { try await execute(workspace, target, "DROP TABLE \(other)") }
        } catch { await workspace.shutdown(); throw error }
        await workspace.shutdown()
        #expect(await client.waitForExit().status == 0)
    }

    private func execute(_ workspace: ApplicationWorkspace, _ document: SQLDocument, _ sql: String) async throws {
        document.text = sql
        await workspace.run(document, sql: sql)
        try #require(document.localError == nil && document.runtime?.queryFailure == nil)
        let execution = try #require(document.executions.last)
        try #require(execution.sql == sql && execution.status == "Completed" && execution.failure == nil)
        #expect(execution.result?.sessionId == document.runtime?.sessionId)
    }
    private func explain(_ workspace: ApplicationWorkspace, source: SQLDocument, target: SQLDocument,
                         sql: String, values: [QueryParameterBinding], mode: ExplainMode, decisions: Decisions) async throws {
        source.text = sql; decisions.mode = mode; decisions.values = values
        source.queryParameters = values.map { .init(name: $0.name, type: $0.type) }
        let previousResult = target.runtime?.result
        let previousTransaction = target.runtime?.transactionStatus
        let reviewsBefore = decisions.reviews.count
        workspace.beginExplainSelection(source, mode: mode, selections: [NSRange(location: 0, length: sql.utf16.count)])
        let draft = try #require(workspace.explainSelection); workspace.explainSelection = nil
        await workspace.runExplainSelection(draft, selected: Set(draft.statements.filter(\.selectedByDefault).map(\.id)), targetID: target.id.uuidString, planKind: nil)
        try #require(source.localError == nil)
        let plan = try #require(source.explainPlan)
        #expect(plan.failure == nil && plan.result?.valid == true && plan.result?.dml != nil)
        #expect(plan.request.sql == sql && plan.request.parameters == values && plan.targetDocumentID == target.id)
        #expect(target.runtime?.result == previousResult && target.runtime?.transactionStatus == previousTransaction)
        #expect(plan.result?.dml?.execution == (mode == .plan ? "estimated" : "completed"))
        #expect(plan.result?.dml?.targetExecution == (mode == .plan ? "notExecuted" : target.runtime?.engine == .mysql ? "suppressed" : "executed"))
        #expect(plan.result?.dml?.affectedRowsUnavailableReason == (mode == .plan ? "notExecuted" : "notReported"))
        if mode == .analyze {
            #expect(decisions.reviews.count == reviewsBefore + 1 && plan.request.writeIntent?.expectedTransactionStatus == previousTransaction?.rawValue)
        }
    }
}
