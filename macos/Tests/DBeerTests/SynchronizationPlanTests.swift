import Foundation
import Testing
@testable import DBeer

enum SynchronizationPlanTestFixtures {
    struct Fixture: Decodable { var version: Int; var capability: String; var commands: [BackendCommand]; var responses: [BackendMessage] }
    static func wire() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/synchronization-plan-v1.json")))
    }
    static func schema() throws -> SynchronizationSQLPlan { try #require(wire().responses.first?.schemaComparison?.plan) }
}

actor SynchronizationSchemaBackend: SchemaComparisonBackend {
    let base: SchemaComparisonTestBackend
    var requests: [SchemaComparisonRequest] = []
    var suspendPlan = false
    private var continuation: CheckedContinuation<Void, Never>?
    init() throws { base = try SchemaComparisonTestBackend() }
    func delayPlan() { suspendPlan = true }
    func releasePlan() { continuation?.resume(); continuation = nil }
    func start(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse { try await base.start(request) }
    func request(_ operation: String, _ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        if operation != "plan" { return try await base.request(operation, request) }
        requests.append(request)
        if suspendPlan { await withCheckedContinuation { continuation = $0 } }
        var plan = try SynchronizationPlanTestFixtures.schema(); plan.modelDigest = request.modelDigest!
        return .init(jobId: request.jobId!, state: .completed, plan: plan)
    }
    func shutdown() async { await base.shutdown() }
}

actor SynchronizationDataBackend: DataComparisonBackend {
    let base: DataComparisonTestBackend
    var requests: [DataComparisonRequest] = []
    init() throws { base = try DataComparisonTestBackend() }
    func begin(_ operation: String, _ request: DataComparisonRequest) async throws -> DataComparisonResponse { try await base.begin(operation, request) }
    func request(_ operation: String, _ request: DataComparisonRequest) async throws -> DataComparisonResponse {
        if operation != "plan" { return try await base.request(operation, request) }
        requests.append(request)
        var plan = try #require(SynchronizationPlanTestFixtures.wire().responses.last?.dataComparison?.plan)
        plan.modelDigest = request.modelDigest!; plan.engine = "postgresql"
        return .init(jobId: request.jobId!, state: .completed, plan: plan)
    }
    func shutdown() async { await base.shutdown() }
}

struct SynchronizationPlanProtocolTests {
    @Test func sharedFixtureAndStrictEnvelopeValidation() throws {
        let fixture = try SynchronizationPlanTestFixtures.wire()
        #expect(fixture.version == BackendProtocol.version && fixture.capability == "synchronizationPlanV1")
        for command in fixture.commands {
            #expect(command.terminalType == command.type + ".result")
            #expect(command.schemaComparison?.valid(for: command.type) ?? command.dataComparison?.valid(for: command.type) == true)
            #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command)) == command)
        }
        for response in fixture.responses { try response.validate() }
        #expect(!SchemaComparisonRequest(jobId: "job").valid(for: "schema.plan"))
        #expect(!DataComparisonRequest(jobId: "job", modelDigest: String(repeating: "A", count: 64)).valid(for: "data.plan"))
        #expect(!SchemaComparisonRequest(jobId: "job", offset: 0, modelDigest: String(repeating: "a", count: 64)).valid(for: "schema.plan"))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.responses[0])) as? [String: Any])
        object["type"] = "schema.status.result"
        let response = try JSONDecoder().decode(BackendMessage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: BackendTransportError.self) { try response.validate() }
    }

    @Test func selectionPreservesDependenciesAndDestructiveOptIn() throws {
        var plan = try SynchronizationPlanTestFixtures.schema()
        #expect(plan.valid && plan.steps.filter(\.destructive).allSatisfy { !$0.selected })
        let first = try #require(plan.steps.first)
        plan.steps.append(.init(id: "dependent", title: "Dependent", sql: "SELECT 1;", destructive: false, manual: false, reason: "", dependsOn: [first.id], selected: true))
        #expect(plan.valid)
        #expect(plan.selectionError(["dependent"]) != nil)
        #expect(plan.selectionError([first.id, "dependent"]) == nil)
        #expect(plan.selectionError(["convert-type"]) != nil)
        plan.steps[0].selected = false
        #expect(!plan.valid)
        plan.steps[0].selected = true; plan.steps[0].destructive = true
        #expect(!plan.valid)
    }

    @Test(arguments: ["schema", "data"])
    func transportRejectsMismatchedPlanDigest(_ kind: String) async throws {
        let response = try SynchronizationPlanTestFixtures.wire().responses[kind == "schema" ? 0 : 1]
        let encoded = try JSONEncoder().encode(response).base64EncodedString()
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import base64,json,sys
        c=json.loads(sys.stdin.readline())
        print(json.dumps({'type':'hello.ack','requestId':c['requestId'],'protocolVersion':5,'capabilities':['schemaComparisonV1','dataComparisonV1','synchronizationPlanV1']}),flush=True)
        c=json.loads(sys.stdin.readline())
        response=json.loads(base64.b64decode('\(encoded)'));response['requestId']=c['requestId']
        print(json.dumps(response),flush=True)
        sys.stdin.readline()
        """])
        try await client.start()
        let digest = String(repeating: "b", count: 64)
        await #expect(throws: BackendTransportError.self) {
            if kind == "schema" { _ = try await client.request(.compareSchema("plan", .init(jobId: "schema-job", modelDigest: digest))) }
            else { _ = try await client.request(.compareData("plan", .init(jobId: "data-job", modelDigest: digest))) }
        }
        _ = await client.shutdown()
    }
}

/// Models, private temporary files and framed helper subprocesses only; no windows.
@MainActor
struct SynchronizationPlanModelTests {
    @Test func previewSaveAndOpenUseCapturedTargetAndInvalidateOnClose() throws {
        let plan = try SynchronizationPlanTestFixtures.schema()
        var profiles = SchemaComparisonTestFixtures.profiles(); profiles[0].name = "source\nSELECT 'untrusted';"
        var opened: [(String, UUID)] = []; var targetCurrent = true
        let draft = SynchronizationPlanDraft(plan: plan, source: profiles[0], target: profiles[1], validateTarget: { _ in targetCurrent }, open: { sql, target in opened.append((sql, target.id)); return true })
        let sql = try #require(draft.sql)
        #expect(sql.contains("\n-- SELECT 'untrusted';") && !sql.contains("\nSELECT 'untrusted';"))
        #expect(sql.contains("ADD COLUMN") && !sql.contains("DROP COLUMN"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("plan.sql")
        draft.save(to: path)
        #expect(try String(contentsOf: path, encoding: .utf8) == sql)
        #expect((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(draft.saved)
        draft.selected.insert("drop-column"); #expect(!draft.saved)
        draft.selected.remove("drop-column")
        #expect(draft.openInEditor() && opened.last?.1 == profiles[1].id)
        #expect(!draft.openInEditor() && opened.count == 1)
        let stale = SynchronizationPlanDraft(plan: plan, source: profiles[0], target: profiles[1], validateTarget: { _ in targetCurrent }, open: { sql, target in opened.append((sql, target.id)); return true })
        targetCurrent = false
        #expect(!stale.openInEditor() && opened.count == 1)
        stale.selected.insert("drop-column"); stale.save(to: path)
        #expect(try String(contentsOf: path, encoding: .utf8) == sql)
        draft.invalidate(); #expect(draft.sql == nil && !draft.openInEditor())
    }

    @Test func workspaceOpensANewDisconnectedDraftForTheCapturedProfileAndRejectsChangedSettings() async throws {
        let profiles = SchemaComparisonTestFixtures.profiles()
        let store = MemoryConnectionLibraryStore(library: .init(connections: profiles, selectedConnectionId: profiles[0].id))
        let workspace = ApplicationWorkspace(connectionStore: store, credentialStore: MemoryConnectionCredentialStore(), automaticallyWatchFiles: false)
        await workspace.library.loadConnections()
        let existing = workspace.newDocument(profileID: profiles[0].id, text: "SELECT 'existing';")
        #expect(workspace.openSynchronizationPlan("SELECT 'generated';", target: profiles[1]))
        let draft = try #require(workspace.selectedDocument)
        #expect(draft !== existing && draft.profileID == profiles[1].id && draft.runtime == nil && draft.executions.isEmpty)
        #expect(existing.text == "SELECT 'existing';" && workspace.library.connectionState == .disconnected)
        var changed = profiles[1].settings(password: ""); changed.host = "changed.example"
        #expect(await workspace.library.saveConnection(name: profiles[1].name, settings: changed, id: profiles[1].id))
        #expect(!workspace.openSynchronizationPlan("SELECT 'stale';", target: profiles[1]) && workspace.documents.count == 2)
        await workspace.shutdown()
    }

    @Test func schemaPlanGenerationNeverResolvesCredentialsAgainAndRejectsALatePlan() async throws {
        let profiles = SchemaComparisonTestFixtures.profiles(), backend = try SynchronizationSchemaBackend()
        var resolutions = 0; var opened: UUID?
        let model = SchemaComparisonModel(profiles: profiles, resolve: { profile in resolutions += 1; return profile.settings(password: "") }, factory: { backend }, openPlan: { _, target in opened = target.id; return true })
        model.sourceID = profiles[0].id; model.targetID = profiles[1].id
        await model.start(); try await DataComparisonTestFixtures.wait { model.summary != nil }
        await model.generatePlan()
        let draft = try #require(model.planDraft)
        #expect(resolutions == 2 && draft.openInEditor() && opened == profiles[1].id)
        #expect(await backend.requests.first?.modelDigest == model.summary?.modelDigest)
        await backend.delayPlan()
        let pending = Task { await model.generatePlan() }
        try await DataComparisonTestFixtures.wait { model.isGeneratingPlan }
        await model.close(); await backend.releasePlan(); await pending.value
        #expect(model.planDraft == nil && !draft.isValid && !draft.openInEditor())
    }

    @Test func dataPlanGenerationUsesTheRetainedComparisonJobAndDigest() async throws {
        let profiles = DataComparisonTestFixtures.profiles(), backend = try SynchronizationDataBackend()
        let model = DataComparisonModel(profiles: profiles, resolve: { profile, _ in profile.settings(password: "") }, factory: { backend })
        DataComparisonTestFixtures.configure(model, profiles)
        await model.readMetadata(); try await DataComparisonTestFixtures.wait { model.metadataMatches && !model.isWorking }
        model.mappings[0].key = true; model.sourceLimit = 3; model.targetLimit = 3
        await model.compare(); try await DataComparisonTestFixtures.wait { model.summary != nil }
        await model.generatePlan()
        #expect(model.planDraft?.plan.kind == "data")
        #expect(await backend.requests.first?.modelDigest == model.summary?.modelDigest)
        #expect(await backend.requests.first?.source == nil)
        let draft = try #require(model.planDraft); await model.reset()
        #expect(!draft.isValid && draft.sql == nil && model.planDraft == nil)
    }
}
