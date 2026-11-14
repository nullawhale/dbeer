import Foundation
import Testing
@testable import DBeer

enum SchemaSourceFixtures {
    static let digest = String(repeating: "a", count: 64)
    static func imported(_ path: String = "/synthetic/schema-bundle") -> SchemaImportedSource {
        .init(source: .init(path: path, engine: "postgresql", manifestSha256: digest, contentSha256: digest),
              label: "Historical é", schemas: ["public"], modifiedSQL: 0, manualObjects: 0, complete: true)
    }
    static func origin(_ imported: SchemaImportedSource) -> SchemaHistoricalOrigin {
        .init(kind: imported.modifiedSQL == 0 ? "bundle" : "editedBundle", label: imported.label,
              manifestSha256: imported.source.manifestSha256!, contentSha256: imported.source.contentSha256!,
              modifiedSQL: imported.modifiedSQL, manualObjects: imported.manualObjects)
    }
}

struct SchemaBundleSourceProtocolTests {
    @Test func sharedSourceRequestsKeepOriginalUnicode() throws {
        struct Fixture: Decodable { let validCommandJSON: [String]; let invalidCommandJSON: [String] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/schema-bundle-source-v1.json")))
        #expect(fixture.validCommandJSON.count >= 5 && fixture.invalidCommandJSON.count >= 5)
        for raw in fixture.validCommandJSON {
            let command = try JSONDecoder().decode(BackendCommand.self, from: Data(raw.utf8))
            #expect(command.schemaComparison?.valid(for: command.type) == true)
            let encoded = try JSONEncoder().encode(command)
            let again = try JSONDecoder().decode(BackendCommand.self, from: encoded)
            #expect(again == command)
        }
        for raw in fixture.invalidCommandJSON {
            #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(BackendCommand.self, from: Data(raw.utf8)) }
        }
    }
    @Test func sharedSourceWireUsesExplicitPortableContextsAndClosedFields() throws {
        struct Wire: Decodable { var version: Int; var capability: String; var commands: [BackendCommand]; var responses: [BackendMessage] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let wire = try JSONDecoder().decode(Wire.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/schema-bundle-source-v1.json")))
        #expect(wire.version == BackendProtocol.version && wire.capability == "schemaBundleSourceV1")
        for command in wire.commands {
            #expect(command.schemaComparison?.valid(for: command.type) == true)
            #expect(command.terminalType == command.type + ".result")
        }
        for response in wire.responses { _ = try NDJSONFramer.decode(JSONEncoder().encode(response)) }
        let context = try #require(wire.responses.last?.schemaComparison?.summary?.source)
        #expect(context.valid && context.origin != nil && context.startedAt.isEmpty && context.version.isEmpty)
        var missing = context; missing.origin = nil; #expect(!missing.valid)
        var fake = context; fake.startedAt = "invented"; #expect(!fake.valid)
        let frame = String(decoding: try JSONEncoder().encode(wire.responses[1]), as: UTF8.self)
        for mutated in [
            frame.replacingOccurrences(of: "\"manualObjects\":0", with: "\"manualObjects\":0,\"manualObjects\":1"),
            frame.replacingOccurrences(of: "\"manualObjects\":0", with: "\"manualObjects\":0.0"),
            frame.replacingOccurrences(of: "\"source\":{", with: "\"source\":{\"foreign\":true,"),
            frame.replacingOccurrences(of: "\"allowSQLChanges\":false", with: "\"allowSQLChanges\":null")
        ] { #expect(throws: (any Error).self) { _ = try NDJSONFramer.decode(Data(mutated.utf8)) } }
    }
    @Test func exactDescriptorAndOneOfSourcesRejectInvalidShapes() throws {
        let file = SchemaSourceFixtures.imported()
        #expect(file.valid)
        #expect(SchemaComparisonSide(bundle: file.source).valid)
        #expect(!SchemaComparisonSide().valid)
        let settings = SchemaComparisonTestFixtures.profiles()[0].settings(password: "")
        #expect(!SchemaComparisonSide(connection: settings, bundle: file.source).valid)
        var invalid = file.source; invalid.path = "relative"; #expect(!invalid.valid(inspecting: false))
        invalid = file.source; invalid.contentSha256 = String(repeating: "A", count: 64); #expect(!invalid.valid(inspecting: false))
        let a = SchemaBundleSourceDescriptor(path: "/synthetic/é"), b = SchemaBundleSourceDescriptor(path: "/synthetic/e\u{301}")
        #expect(a != b)
        let bytes = try JSONEncoder().encode(SchemaComparisonSide(bundle: file.source))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("connection"))
    }
}

actor SchemaSourceTestBackend: SchemaComparisonBackend {
    var starts: [SchemaComparisonRequest] = []
    var inspections: [SchemaComparisonRequest] = []
    var operations: [String] = []
    var inspected = SchemaSourceFixtures.imported()
    let wire: SchemaComparisonTestFixtures.Fixture
    init() throws { wire = try SchemaComparisonTestFixtures.wire() }
    func inspect(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        inspections.append(request)
        inspected.source.path = request.bundle!.path
        inspected.source.allowSQLChanges = request.bundle!.allowSQLChanges
        return .init(jobId: "import-job", state: .pending)
    }
    func start(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        starts.append(request); return wire.responses[0].schemaComparison!
    }
    func request(_ operation: String, _ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        operations.append(operation)
        if operation == "import.status" { return .init(jobId: "import-job", state: .completed, importSummary: inspected) }
        if operation == "import.close" { return .init(jobId: "import-job", state: .closed) }
        if operation == "import.cancel" { return .init(jobId: "import-job", state: .cancelled) }
        if operation == "status" {
            var response = wire.responses[1].schemaComparison!
            let start = starts.last!
            response.summary?.mappings = start.mappings!
            if start.source?.bundle != nil {
                response.summary?.source.origin = SchemaSourceFixtures.origin(inspected)
                response.summary?.source.startedAt = ""; response.summary?.source.finishedAt = ""
                response.summary?.source.database = ""; response.summary?.source.version = ""
            }
            if start.target?.bundle != nil {
                response.summary?.target.origin = SchemaSourceFixtures.origin(inspected)
                response.summary?.target.startedAt = ""; response.summary?.target.finishedAt = ""
                response.summary?.target.database = ""; response.summary?.target.version = ""
            }
            return response
        }
        let index = try #require(["start", "status", "page", "value", "export", "cancel", "close"].firstIndex(of: operation))
        return wire.responses[index].schemaComparison!
    }
    func shutdown() async { operations.append("shutdown") }
}

@MainActor
struct SchemaBundleSourceModelTests {
    @Test func sourceConfigurationStaysIdleAndBothOfflineComparisonUsesNoCredentials() async throws {
        let backend = try SchemaSourceTestBackend(); var factories = 0, resolutions = 0
        let model = SchemaComparisonModel(profiles: [], resolve: { _ in resolutions += 1; throw CancellationError() }, factory: { factories += 1; return backend })
        model.sourceMode = .bundle; model.targetMode = .bundle
        #expect(!model.canStart && factories == 0 && resolutions == 0)
        let url = URL(fileURLWithPath: "/synthetic/schema-bundle", isDirectory: true)
        await model.inspectBundle(at: url, target: false)
        await model.inspectBundle(at: url, target: true)
        #expect(model.canStart && resolutions == 0 && factories == 2)
        await model.start()
        try await DataComparisonTestFixtures.wait { model.summary != nil }
        let starts = await backend.starts
        #expect(starts.count == 1 && starts[0].source?.connection == nil && starts[0].target?.connection == nil)
        #expect(model.sourceProfile == nil && model.targetProfile == nil && resolutions == 0)
        #expect(model.summary?.source.origin?.valid == true && model.summary?.source.startedAt == "")
        await model.close()
    }
    @Test func mixedSourcesResolveOnlyExplicitLiveSelectionAndHonorActiveBinding() async throws {
        let backend = try SchemaSourceTestBackend(); let profile = SchemaComparisonTestFixtures.profiles()[1]
        var resolutions: [UUID] = []; var active = true
        let model = SchemaComparisonModel(profiles: [profile], resolve: { resolutions.append($0.id); return $0.settings(password: "") }, factory: { backend }, current: { _ in active })
        model.sourceMode = .bundle; model.targetID = profile.id
        await model.inspectBundle(at: URL(fileURLWithPath: "/synthetic/schema-bundle"), target: false)
        await model.start(); try await DataComparisonTestFixtures.wait { model.summary != nil }
        #expect(resolutions == [profile.id] && model.sourceProfile == nil && model.targetProfile?.id == profile.id)
        let start = try #require(await backend.starts.first)
        #expect(start.source?.bundle != nil && start.target?.connection?.policy.readOnly == true)
        active = false
        #expect(!model.canGeneratePlan)
        await model.close()
    }
    @Test func offlineTargetDraftExportsExactPreviewButNeedsFreshLiveComparisonToOpen() throws {
        let file = SchemaSourceFixtures.imported(), endpoint = try #require(SynchronizationPlanEndpoint(bundle: file))
        let plan = SynchronizationSQLPlan(formatVersion: 1, kind: "schema", engine: "postgresql", modelDigest: SchemaSourceFixtures.digest,
            warnings: [], steps: [.init(id: "create", title: "Create table", sql: "CREATE TABLE public.added(id integer);", destructive: false, manual: false, reason: "", dependsOn: [], selected: true)])
        var opened = false
        let draft = SynchronizationPlanDraft(plan: plan, source: endpoint, target: endpoint, current: { true }, validateTarget: { _ in true }, open: { _, _ in opened = true; return true })
        let preview = try #require(draft.sql)
        #expect(!draft.canOpenInEditor && !draft.openInEditor() && !opened)
        let directory = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("plan.sql")
        draft.save(to: destination, expectedSQL: preview)
        let exported = try Data(contentsOf: destination)
        #expect(draft.saved && String(decoding: exported, as: UTF8.self) == preview)
        draft.invalidate(); #expect(draft.sql == nil)
    }
}

actor DelayedSchemaSourceBackend: SchemaComparisonBackend {
    var entered = false
    var operations: [String] = []
    private var continuation: CheckedContinuation<SchemaComparisonResponse, Never>?
    func inspect(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: .init(jobId: "late-import", state: .pending)); continuation = nil }
    func start(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse { throw CancellationError() }
    func request(_ operation: String, _ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        operations.append(operation); throw CancellationError()
    }
    func shutdown() async { operations.append("shutdown") }
}

@MainActor
struct SchemaBundleSourceLifecycleTests {
    @Test func closeRetiresInspectionBeforeLateStartReplyAndNeverResolvesCredentials() async throws {
        let backend = DelayedSchemaSourceBackend(); var resolutions = 0
        let model = SchemaComparisonModel(profiles: [], resolve: { _ in resolutions += 1; throw CancellationError() }, factory: { backend })
        let pending = Task { await model.inspectBundle(at: URL(fileURLWithPath: "/synthetic/schema-bundle"), target: false) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await backend.entered), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await backend.entered)
        await model.close(); await backend.release(); await pending.value
        #expect(!model.isInspecting && model.sourceBundle == nil && resolutions == 0)
        #expect(!(await backend.operations).contains("import.status"))
    }
    @Test func activeComparisonIgnoresTransientStartGateAndRejectsPermanentBindingLoss() async throws {
        let backend = try SchemaSourceTestBackend(); let profiles = SchemaComparisonTestFixtures.profiles()
        var allowed = true, current = true
        let model = SchemaComparisonModel(profiles: profiles, resolve: { $0.settings(password: "") }, factory: { backend }, current: { _ in current }, startAllowed: { allowed })
        model.sourceID = profiles[0].id; model.targetID = profiles[1].id
        await model.start(); allowed = false
        try await DataComparisonTestFixtures.wait { model.summary != nil }
        #expect(model.phase == .completed && model.canGeneratePlan)
        current = false; #expect(!model.canGeneratePlan)
        await model.close()
    }
}

actor PausedSchemaReportBackend: SchemaComparisonBackend {
    let base: SchemaComparisonTestBackend
    private var pause = false
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    init() throws { base = try SchemaComparisonTestBackend() }
    func pauseNextExport() { pause = true; entered = false }
    func release() { continuation?.resume(); continuation = nil }
    func start(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse { try await base.start(request) }
    func request(_ operation: String, _ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        if operation == "export", pause {
            pause = false; entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        return try await base.request(operation, request)
    }
    func shutdown() async { await base.shutdown() }
}

/// Models, local temporary files and an actor gate only; no chooser or window.
@MainActor
struct SchemaComparisonExportGuardTests {
    @Test(arguments: ["create", "replace", "edit", "close"])
    func suspendedReportExportPreservesForeignBytesAndAllowsReviewedRetry(_ mutation: String) async throws {
        let backend = try PausedSchemaReportBackend(), profiles = SchemaComparisonTestFixtures.profiles()
        let model = SchemaComparisonModel(profiles: profiles, resolve: { $0.settings(password: "") }, factory: { backend })
        model.sourceID = profiles[0].id; model.targetID = profiles[1].id
        await model.start()
        try await DataComparisonTestFixtures.wait { model.summary != nil }
        let directory = try SchemaBundleFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("report.json")
        if mutation != "create" { try Data("reviewed original".utf8).write(to: destination) }
        await backend.pauseNextExport()
        let exporting = Task { await model.export(to: destination) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await backend.entered), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await backend.entered)
        let foreign = Data("external replacement".utf8)
        if mutation == "replace" { try FileManager.default.removeItem(at: destination) }
        try foreign.write(to: destination)
        if mutation == "close" { await model.close() }
        await backend.release(); await exporting.value
        let preserved = try Data(contentsOf: destination)
        #expect(preserved == foreign && !model.exportComplete && !model.isExporting)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["report.json"])
        if mutation != "close" {
            await model.export(to: destination)
            let acknowledged = try Data(contentsOf: destination)
            #expect(model.exportComplete && acknowledged != foreign)
            await model.close()
            #expect(try Data(contentsOf: destination) == acknowledged)
        }
    }
}

/// A prepared local file and synchronous filesystem hooks only; no desktop use.
struct PreparedReportFilePublicationTests {
    @Test(arguments: [false, true])
    func racingPublicationRetainsForeignDestinationAndReviewedRecovery(afterPublish: Bool) throws {
        let directory = try SchemaBundleFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("report.json"), temporary = directory.appendingPathComponent("prepared.tmp")
        let original = Data("reviewed original".utf8), foreign = Data("foreign replacement".utf8), report = Data("prepared report".utf8)
        try original.write(to: destination); try report.write(to: temporary)
        let parent = try SQLFileBinding.parentIdentity(of: destination)
        let reviewed = try SQLFileBinding.reviewedVersion(at: destination)
        var recovery: URL?
        do {
            try SQLFileBinding.publishPreparedFile(temporary, to: destination, expectedVersion: reviewed, expectedParent: parent,
                expectedSHA256: SchemaBundleManifest.digest(report), maximumBytes: 1_024, publicationHook: { stage, _ in
                    if afterPublish ? stage == .didPublish : stage == .willPublish { try foreign.write(to: destination) }
                })
            Issue.record("Foreign publication was accepted")
        } catch let failure as SQLFileBindingError { recovery = failure.recoveryURL }
        let retained = try #require(recovery)
        #expect(try Data(contentsOf: destination) == foreign)
        #expect(try Data(contentsOf: retained) == original)
    }
}
