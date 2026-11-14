import Combine
import Foundation
import Testing
@testable import DBeer

@MainActor
private final class CollectorWorkspaceGate {
    var entered = false
    var released = false
    var publicationAttempts = 0
    var queryIDs: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func holdPublication() async {
        publicationAttempts += 1; entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor
private final class CollectorWorkspaceDecisions {
    var helpers = 0
    var collectors = 0
    var reviews = 0
    var parameterPrompts = 0
    var optionsPrompts = 0
}

/// Private injected models only. AppAppearance is constructed with private
/// defaults but never started; no NSApp, views, windows or default presenters.
@MainActor
private final class CollectorWorkspaceFixture {
    let workspace: ApplicationWorkspace
    let documents: MemorySQLDocumentStore
    let directory: URL
    let decisions: CollectorWorkspaceDecisions
    private let defaults: UserDefaults
    private let defaultsName: String
    init(workspace: ApplicationWorkspace, documents: MemorySQLDocumentStore, directory: URL,
         decisions: CollectorWorkspaceDecisions, defaults: UserDefaults, defaultsName: String) {
        self.workspace = workspace; self.documents = documents; self.directory = directory
        self.decisions = decisions; self.defaults = defaults; self.defaultsName = defaultsName
    }
    static func make(settings: ConnectionSettings, profile: SavedConnection,
                     snapshot: SQLWorkspaceSnapshot = SQLWorkspaceSnapshot(), gate: CollectorWorkspaceGate? = nil) async throws -> CollectorWorkspaceFixture {
        let repository = TuningNativeFixture.root
        let directory = repository.appendingPathComponent("build/collector-workspace-integration/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let defaultsName = "DBeer.CollectorIntegration." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let credentials = MemoryConnectionCredentialStore()
        await credentials.savePassword(settings.password, for: profile.id)
        let documents = MemorySQLDocumentStore(snapshot: snapshot)
        let snapshots = ResultSnapshotStore(rootURL: directory.appendingPathComponent("snapshots"))
        let plans = PlanArtifactStore(rootURL: directory.appendingPathComponent("plans"))
        let themes = EditorThemeStore(defaults: defaults, directory: directory.appendingPathComponent("themes"))
        let appearance = AppAppearance(defaults: defaults, editorThemes: themes)
        let decisions = CollectorWorkspaceDecisions()
        let executable = ProcessInfo.processInfo.environment["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ??
            repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id)), credentialStore: credentials,
            documentStore: documents, commandShortcuts: AppShortcutStore(defaults: defaults),
            copySettings: ResultCopySettings(defaults: defaults), editorThemes: themes, appearance: appearance,
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: SQLLibrary(),
            tableBrowsePresets: TableBrowsePresetStore(fileURL: directory.appendingPathComponent("presets.json")),
            logicalRelationships: LogicalRelationshipStore(fileURL: directory.appendingPathComponent("relationships.json")),
            resultSnapshots: ResultSnapshotsModel(store: snapshots), planArtifacts: PlanArtifactsModel(store: plans),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in
                decisions.reviews += 1; return true
            }, queryParameterDecision: { _, _ in decisions.parameterPrompts += 1; return nil },
            explainOptionsDecision: { _ in decisions.optionsPrompts += 1; return .use(nil) }, helperFactory: {
                decisions.helpers += 1; return BackendClient(executableURL: executable)
            }, explainCollectorFactory: { documentID in
                decisions.collectors += 1
                let store = PlanArtifactStore(rootURL: directory.appendingPathComponent("collected/" + documentID.uuidString))
                return ExplainCollector(store: store, publishCapture: { artifact, configuration, lease in
                    if let gate { await gate.holdPublication() }
                    _ = try await store.saveCollected(artifact, configuration: configuration, now: .now, lease: lease)
                })
            })
        return CollectorWorkspaceFixture(workspace: workspace, documents: documents, directory: directory,
            decisions: decisions, defaults: defaults, defaultsName: defaultsName)
    }
    func finish() async {
        await workspace.shutdown()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// This tests model/runtime/helper wiring, not UI. It uses only the disposable
/// PostgreSQL endpoint and one immediate estimated capture (no interval sleep).
@Suite(.serialized)
@MainActor
struct ExplainCollectorWorkspaceIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func explicitWorkspaceCollectionUsesItsOwnerAndRestorationStaysDisconnected() async throws {
        let url = try #require(URLComponents(string: ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? ""))
        let host = try #require(url.host), user = try #require(url.user)
        let settings = ConnectionSettings(host: host, port: url.port ?? 5432, database: String(url.path.dropFirst()),
            user: user, password: url.password ?? "", sslMode: "disable", policy: .init(readOnly: true))
        let profile = SavedConnection(name: "Isolated readonly collector", settings: settings)
        let gate = CollectorWorkspaceGate()
        let fixture = try await CollectorWorkspaceFixture.make(settings: settings, profile: profile, gate: gate)
        var restored: CollectorWorkspaceFixture?
        do {
            let workspace = fixture.workspace
            await workspace.start()
            await workspace.connectProfile(profile.id)
            let source = workspace.newDocument(profileID: profile.id, text: "SELECT 1 AS collected_value")
            let other = workspace.newDocument(profileID: profile.id, text: "SELECT 2 AS independent_value")
            try await run(workspace, source, sql: source.text)
            try await run(workspace, other, sql: other.text)
            let runtime = try #require(source.runtime), independentRuntime = try #require(other.runtime)
            let owner = try #require(runtime.sessionId), independentOwner = try #require(independentRuntime.sessionId)
            #expect(owner != independentOwner && workspace.services[profile.id]?.sessionId != owner)
            workspace.beginExplainSelection(source, mode: .plan, selections: [NSRange(location: 0, length: source.text.utf16.count)])
            let draft = try #require(workspace.explainSelection)
            workspace.explainSelection = nil
            let selected = Set(draft.statements.filter { $0.selectedByDefault }.map { $0.id })
            await workspace.runExplainSelection(draft, selected: selected, targetID: source.id.uuidString, planKind: nil)
            let plan = try #require(source.explainPlan)
            let capture = try #require(plan.result)
            #expect(capture.complete && plan.failure == nil && plan.request.context?.sessionId == owner)
            #expect(runtime.capabilities.contains(TuningInspectRequest.capability))
            let panel = try #require(workspace.makeTuningPanel(source, plan: plan))
            let collector = panel.collector
            var configuration = ExplainCollectorConfiguration()
            configuration.maximumCaptures = 1; configuration.maximumRuntimeSeconds = 30
            panel.configuration = configuration
            let initialResult = runtime.result, epoch = runtime.tuningOperationEpoch
            let reviews = fixture.decisions.reviews, options = fixture.decisions.optionsPrompts
            let observation = runtime.$activeQueryId.dropFirst().sink { query in if let query { gate.queryIDs.append(query) } }
            defer { observation.cancel() }
            panel.startCollection()
            try await waitUntil { gate.entered || !collector.running }
            try #require(gate.entered)
            #expect(collector.running && gate.publicationAttempts == 1)
            try #require(gate.queryIDs.count == 1)
            let capturedQueryID = gate.queryIDs[0]
            #expect(UUID(uuidString: capturedQueryID) != nil)
            #expect(runtime.activeQueryId == nil && runtime.transactionStatus == .idle && runtime.tuningOperationEpoch == epoch)
            #expect(runtime.result == initialResult)
            // The real capture has completed through runtime.run's owned ID and
            // admission token; publication is held so the run is still active.
            try await run(workspace, other, sql: "SELECT 3 AS independent_value")
            #expect(collector.running && runtime.tuningOperationEpoch == epoch && runtime.sessionId == owner)
            #expect(independentRuntime.sessionId == independentOwner && gate.queryIDs.count == 1)
            gate.release()
            try await waitUntil { !collector.running }
            #expect(collector.status.contains("bound reached"))
            let retained = try await collector.store.list()
            try #require(retained.count == 1)
            let artifact = try await collector.store.load(retained[0].id)
            #expect(artifact.request == plan.request.portable && artifact.result.valid)
            #expect(artifact.request.context == nil && artifact.request.writeIntent == nil)
            #expect(fixture.decisions.reviews == reviews && fixture.decisions.optionsPrompts == options)
            #expect(fixture.decisions.parameterPrompts == 0 && fixture.decisions.helpers == 1 && fixture.decisions.collectors == 1)
            await workspace.flushDocuments()
            let persisted = await fixture.documents.load()
            let stored = try #require(persisted.documents.first { $0.id == source.id })
            #expect(stored.explainCollectorConfiguration == configuration)
            let bounds = try #require(stored.explainCollectorConfiguration)
            let encodedBounds = try JSONEncoder().encode(bounds)
            let fields = try #require(JSONSerialization.jsonObject(with: encodedBounds) as? [String: Any])
            #expect(Set(fields.keys) == ["intervalSeconds", "maximumCaptures", "maximumRuntimeSeconds", "maximumStorageBytes", "retentionDays"])
            let snapshotData = try JSONEncoder().encode(persisted)
            let restoredSnapshot = try JSONDecoder().decode(SQLWorkspaceSnapshot.self, from: snapshotData)
            let second = try await CollectorWorkspaceFixture.make(settings: settings, profile: profile, snapshot: restoredSnapshot)
            restored = second
            // Restoration entry point deliberately excludes ordinary app startup:
            // this isolates whether restored collector configuration starts work.
            await second.workspace.restoreSavedWorkspace()
            await second.workspace.library.loadConnections()
            let restoredSource = try #require(second.workspace.documents.first { $0.id == source.id })
            #expect(restoredSource.explainCollectorConfiguration == configuration && restoredSource.runtime == nil)
            #expect(restoredSource.explainCollector == nil && restoredSource.explainPlan == nil)
            #expect(second.workspace.services.isEmpty && second.decisions.helpers == 0 && second.decisions.collectors == 0)
            #expect(second.decisions.reviews == 0 && second.decisions.optionsPrompts == 0 && second.decisions.parameterPrompts == 0)
        } catch {
            gate.release()
            if let restored { await restored.finish() }
            await fixture.finish(); throw error
        }
        if let restored { await restored.finish() }
        await fixture.finish()
    }
    private func run(_ workspace: ApplicationWorkspace, _ document: SQLDocument, sql: String) async throws {
        document.text = sql
        await workspace.run(document, sql: sql)
        try #require(document.localError == nil && document.runtime?.queryFailure == nil)
        let execution = try #require(document.executions.last)
        #expect(execution.status == "Completed" && execution.failure == nil)
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}
