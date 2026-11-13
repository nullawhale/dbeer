import Foundation
import Testing
@testable import DBeer

/// Normal helper and runner-owned databases, private persistence and injected
/// decisions. No application start, windows, views, dialogs or file watchers.
@Suite(.serialized)
@MainActor
struct ExplainOptionsIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresNormalHelperBindsCustomAnalyzeOptionsToTheChosenSession() async throws { try await exercise(.postgresql) }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlNormalHelperBindsTreeAndJSONFormatsToTheChosenSession() async throws { try await exercise(.mysql) }

    private final class Decisions {
        var helperStarts = 0
        var parameterEntries = 0
        var options: ExplainOptions?
        var sessionID: String?
        var targetID: UUID?
        var configurations: [ExplainOptionsConfiguration] = []
        var confirmations: [OperationConfirmation] = []
    }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let environment = ProcessInfo.processInfo.environment
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let executable = environment["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ??
            repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let directory = repository.appendingPathComponent("build/explain-options-integration/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings: ConnectionSettings
        if engine == .mysql {
            settings = .init(host: environment["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
                port: try #require(Int(environment["DBEER_TEST_MYSQL_PORT"] ?? "")),
                database: environment["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: environment["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
                password: environment["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: environment["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable",
                sslRootCert: environment["DBEER_TEST_MYSQL_CA_FILE"], engine: .mysql)
        } else {
            let url = try #require(URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""))
            settings = .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()),
                user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        let profile = SavedConnection(name: "Explain options isolated owner", settings: settings)
        let credentials = MemoryConnectionCredentialStore()
        await credentials.savePassword(settings.password, for: profile.id)
        let defaultsName = "dbeer-explain-options-integration-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let themes = EditorThemeStore(defaults: defaults, directory: directory.appendingPathComponent("themes"))
        let snapshots = ResultSnapshotStore(rootURL: directory.appendingPathComponent("snapshots"))
        let plans = PlanArtifactStore(rootURL: directory.appendingPathComponent("plans"))
        let decisions = Decisions()
        let values = [QueryParameterBinding(name: "minimum", type: .integer, value: "1"),
            QueryParameterBinding(name: "excluded", type: .text, value: "excluded e\u{0301}' value")]
        let definitions = values.map { SQLParameterDefinition(name: $0.name, type: $0.type) }
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
                    #expect(decisions.configurations.last?.sessionID == decisions.sessionID)
                    #expect(request.options == decisions.options && request.parameters == values)
                    #expect(confirmation.assessment.operations.first?.explain?.options == request.options)
                    #expect(confirmation.assessment.operations.first?.explain?.support == decisions.configurations.last?.support)
                }
                decisions.confirmations.append(confirmation)
                return true
            }, queryParameterDecision: { supplied, targetProfile in
                #expect(supplied == definitions && targetProfile.id == profile.id)
                decisions.parameterEntries += 1
                return values
            }, explainOptionsDecision: { configuration in
                #expect(configuration.profile.id == profile.id && configuration.support.engine == engine)
                #expect(configuration.sessionID == decisions.sessionID && configuration.targetDocumentID == decisions.targetID)
                #expect(configuration.transactionStatus == .idle && configuration.accepts(decisions.options))
                decisions.configurations.append(configuration)
                return .use(decisions.options)
            }, helperFactory: { decisions.helperStarts += 1; return client })
        await workspace.library.loadConnections()
        let name = "f3_native_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let target = workspace.newDocument(profileID: profile.id, text: "")
        let query = "SELECT id, label FROM \(name) WHERE id > :minimum AND label <> :excluded"
        let source = workspace.newDocument(profileID: profile.id, text: query)
        source.queryParameters = definitions
        do {
            // TEMPORARY belongs only to the chosen SQL-tab connection. Helper
            // shutdown drops it even when an assertion throws before cleanup.
            try await execute(workspace, target, "CREATE TEMPORARY TABLE \(name) (id INTEGER PRIMARY KEY, label VARCHAR(80))")
            try await execute(workspace, target, "INSERT INTO \(name) VALUES (1, 'one'), (2, 'two'), (3, 'three')")
            let runtime = try #require(target.runtime)
            let session = try #require(runtime.sessionId)
            let support = try #require(runtime.explainSupport)
            decisions.sessionID = session; decisions.targetID = target.id
            #expect(await client.supportsExplainOptions())
            #expect(await client.supportsExplainParameters())
            #expect(runtime.capabilities.contains("explainOptionsV1") && runtime.capabilities.contains("explainParametersV1"))
            #expect(ExplainOptionsAdmission.validOwner(support: support, engine: engine,
                capabilities: Set(runtime.capabilities), helperSupports: await client.supportsExplainOptions()))
            #expect(workspace.services[profile.id]?.sessionId != session && source.runtime == nil)
            if engine == .postgresql {
                let available = try #require(support.options?.postgresql)
                let major = support.serverVersion.split(separator: ".").first.flatMap { Int($0) } ?? 0
                if major >= 17 { #expect(available.analyze.contains("memory") && available.analyze.contains("serialize")) }
                let options = ExplainOptions(postgresql: .init(buffers: true, wal: true, settings: true,
                    memory: available.analyze.contains("memory") ? true : nil,
                    serialize: available.analyze.contains("serialize") ? .binary : nil, timing: false))
                try await explain(workspace, source: source, target: target, decisions: decisions, values: values,
                    mode: .analyze, options: options, kind: .custom, format: "json", plans: plans)
            } else {
                let available = try #require(support.options?.mysql)
                let version = support.serverVersion.split(separator: ".")
                if version.count >= 2, let major = Int(version[0]), let minor = Int(version[1]), major > 8 || major == 8 && minor >= 3 {
                    #expect(available.analyze.contains("json") && available.jsonAnalyzeRequiresVersion2)
                }
                if available.plan.contains("tree") {
                    try await explain(workspace, source: source, target: target, decisions: decisions, values: values,
                        mode: .plan, options: .init(mysql: .init(format: .tree)), format: "tree", plans: plans)
                }
                // These are explicit test setup operations on the owned tab,
                // separate from each Explain assessment and execution.
                if available.analyze.contains("json") { try await execute(workspace, target, "SET SESSION explain_json_format_version = 1") }
                try await explain(workspace, source: source, target: target, decisions: decisions, values: values,
                    mode: .plan, options: .init(mysql: .init(format: .json)), format: "jsonV1", plans: plans)
                if available.analyze.contains("json") {
                    try await execute(workspace, target, "SET SESSION explain_json_format_version = 2")
                    try await explain(workspace, source: source, target: target, decisions: decisions, values: values,
                        mode: .analyze, options: .init(mysql: .init(format: .json)), format: "jsonV2", plans: plans)
                } else if available.analyze.contains("tree") {
                    try await explain(workspace, source: source, target: target, decisions: decisions, values: values,
                        mode: .analyze, options: .init(mysql: .init(format: .tree)), format: "tree", plans: plans)
                }
            }
            #expect(decisions.parameterEntries == decisions.configurations.count && decisions.helperStarts == 1)
            try await execute(workspace, target, "DROP TABLE \(name)")
        } catch {
            await workspace.shutdown()
            throw error
        }
        await workspace.shutdown()
        #expect(await client.waitForExit().status == 0)
    }

    private func execute(_ workspace: ApplicationWorkspace, _ document: SQLDocument, _ sql: String) async throws {
        // Normal execution requires the owning editor to contain SQL, even
        // when the explicit statement is supplied to run(_:sql:).
        document.text = sql
        await workspace.run(document, sql: sql)
        try #require(document.localError == nil && document.runtime?.queryFailure == nil)
        let execution = try #require(document.executions.last)
        try #require(execution.sql == sql && execution.status == "Completed" && execution.failure == nil)
        let acknowledged = try #require(execution.result)
        try acknowledged.validate()
        try #require(acknowledged.type == "query.result" && acknowledged.outcomeUnknown != true &&
            acknowledged.sessionId == document.runtime?.sessionId && acknowledged.transactionStatus == .idle)
    }

    private func explain(_ workspace: ApplicationWorkspace, source: SQLDocument, target: SQLDocument,
                         decisions: Decisions, values: [QueryParameterBinding], mode: ExplainMode, options: ExplainOptions,
                         kind: ExplainPlanKind? = nil, format: String, plans: PlanArtifactStore) async throws {
        decisions.options = options
        let choicesBefore = decisions.configurations.count
        let reviewsBefore = decisions.confirmations.count
        workspace.beginExplainSelection(source, mode: mode, selections: [NSRange(location: 0, length: source.text.utf16.count)])
        let draft = try #require(workspace.explainSelection)
        workspace.explainSelection = nil
        await workspace.runExplainSelection(draft, selected: Set(draft.statements.filter(\.selectedByDefault).map(\.id)),
            targetID: target.id.uuidString, planKind: kind)
        try #require(source.localError == nil)
        let plan = try #require(source.explainPlan)
        let result = try #require(plan.result)
        #expect(plan.failure == nil && plan.status == "Completed" && result.valid && result.status == "tree" && result.complete)
        #expect(decisions.configurations.count == choicesBefore + 1 && decisions.configurations.last?.mode == mode)
        #expect(plan.sessionID == decisions.sessionID && target.runtime?.sessionId == decisions.sessionID && source.runtime == nil)
        #expect(plan.targetDocumentID == target.id && plan.sourceDocumentID == source.id && plan.profileID == target.profileID)
        #expect(plan.request.context?.sessionId == decisions.sessionID && plan.request.context?.targetDocumentId == target.id.uuidString)
        #expect(plan.request.parameters == values && plan.request.planKind == kind && plan.request.options == options && result.options == options)
        #expect(result.format == format && result.support == decisions.configurations.last?.support && !result.nodes.isEmpty && !result.raw.isEmpty)
        if mode == .analyze {
            #expect(decisions.confirmations.count == reviewsBefore + 1 && decisions.confirmations.last?.assessment.decision == "confirm")
        }
        let startsBeforeSave = decisions.helperStarts
        let artifact = try PlanArtifact.capture(plan, title: "Normal helper " + format)
        let saved = try await plans.save(artifact)
        let offline = try await plans.load(saved.id)
        #expect(offline.version == 4 && offline.request == plan.request.portable && offline.result == result)
        #expect(offline.displayPlan.sessionID == nil && offline.displayPlan.targetDocumentID == nil && offline.displayPlan.profile == nil)
        #expect(try PlanArtifact.decode(offline.encoded()) == offline)
        #expect(decisions.helperStarts == startsBeforeSave)
    }
}
