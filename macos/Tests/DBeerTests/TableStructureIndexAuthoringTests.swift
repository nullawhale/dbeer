import Foundation
import Testing
@testable import DBeer

struct TableStructureIndexAuthoringContractTests {
    @Test func sharedFixtureClosesEveryAdvancedBoundary() throws {
        struct Fixture: Decodable { var valid: [BackendCommand]; var invalid: [String] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/table-structure-index-authoring-v1.json")))
        for command in fixture.valid {
            #expect(command.structure?.valid(for: command.type) == true)
            #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command)) == command)
        }
        for raw in fixture.invalid {
            var accepted = false
            do {
                let command = try JSONDecoder().decode(BackendCommand.self, from: Data(raw.utf8))
                accepted = command.structure?.valid(for: command.type) == true
            } catch {}
            #expect(!accepted)
        }
    }

    @Test func replacementRetainsRichIntentAndRespectsKeyOwnershipAndCapabilities() throws {
        let definition = StructureIndexDefinition(method: "btree", terms: [.init(expression: "lower(\"é\")", descending: false, nullsFirst: true, opclass: .init(schema: "public", name: "text_ops"))], includes: ["payload"], predicate: "\"é\" IS NOT NULL", nullsDistinct: false, options: [.init(name: "fillfactor", value: "80")])
        var index = StructureIndex(name: "rich", columns: [], unique: true, supported: true, definition: definition)
        let replacement = try #require(index.editIntent(action: "replace", engine: .postgresql, advancedAllowed: true))
        #expect(replacement.definition == definition && replacement.columns == nil && replacement.unique == true && replacement.valid)
        let drop = try #require(index.editIntent(action: "drop", engine: .postgresql, advancedAllowed: true))
        #expect(drop.definition == nil && drop.columns == nil && drop.unique == nil && drop.valid)
        #expect(index.editIntent(action: "replace", engine: .postgresql, advancedAllowed: false) == nil)
        #expect(index.editIntent(action: "replace", engine: .sqlite, advancedAllowed: true) == nil)
        index.owner = "owning_key"
        #expect(index.editIntent(action: "drop", engine: .postgresql, advancedAllowed: true) == nil)
        index.owner = nil; index.supported = false
        #expect(index.editIntent(action: "replace", engine: .postgresql, advancedAllowed: true) == nil)
        let ordinary = StructureIndex(name: "ordinary", columns: ["é"], unique: false, supported: true)
        #expect(ordinary.editIntent(action: "replace", engine: .sqlite, advancedAllowed: false)?.columns?.first?.utf8.elementsEqual("é".utf8) == true)
    }

    @Test func partialDefinitionsRemainPortableWithoutPreviewAdmission() throws {
        let definitions: [StructureIndexDefinition] = [
            .init(method: "", terms: []),
            .init(method: "btree", terms: [.init(expression: "")], predicate: ""),
            .init(method: "btree", terms: [.init(column: "é", prefixLength: 0, opclass: .init(schema: "public", name: ""))], options: [.init(name: "", value: "")])
        ]
        for definition in definitions {
            let document = StructureDraftDocument(engine: .postgresql, target: .init(schema: "public", table: "synthetic", create: false), draft: .init(columns: [], indexes: [.init(action: "add", name: "partial", definition: definition)]))
            #expect(document.valid && !document.draft.valid && document.draft.authoringVersion == 3)
            let text = try StructureDraftStore.text(document)
            let decoded = try JSONDecoder().decode(StructureDraftDocument.self, from: Data(text.utf8))
            #expect(decoded == document && decoded.formatVersion == StructureDraftDocument.currentFormatVersion && decoded.draft.indexes?.first?.definition == definition)
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(StructureDraftDocument.self, from: Data(text.replacingOccurrences(of: "\"authoringVersion\" : 3", with: "\"authoringVersion\" : 99").utf8))
            }
            for oldVersion in [1, 2] {
                #expect(throws: (any Error).self) {
                    _ = try JSONDecoder().decode(StructureDraftDocument.self, from: Data(text.replacingOccurrences(of: "\"formatVersion\" : 5", with: "\"formatVersion\" : \(oldVersion)").utf8))
                }
            }
        }
    }

    @Test func versionsAndBoundsCannotBypassAdvancedAdmission() throws {
        let rich = StructureIndexEdit(action: "add", name: "rich", definition: .init(method: "btree", terms: [.init(column: "value")]))
        for version in [nil, 0, 2, 99] as [Int?] { #expect(!StructureDraft(columns: [], indexes: [rich], authoringVersion: version).valid) }
        #expect(StructureDraft(columns: [], indexes: [rich], authoringVersion: 3).valid)
        var mixed = rich; mixed.columns = []
        #expect(!mixed.valid)
        var oversized = rich; oversized.definition?.terms[0].expression = String(repeating: "x", count: 4097); oversized.definition?.terms[0].column = nil
        #expect(!oversized.valid)
        oversized = rich; oversized.definition?.terms[0].prefixLength = 65_536
        #expect(!oversized.valid)
        oversized = rich; oversized.definition?.options = [.init(name: "same", value: "one"), .init(name: "same", value: "two")]
        #expect(!oversized.valid)
    }
}

@MainActor
private final class IndexAuthoringModelBackend {
    var available = false
    var commands: [BackendCommand] = []
    var connections = 0
    let target = StructureTarget(schema: "public", table: "synthetic", create: false)
    func model(engine: DatabaseEngine = .postgresql) -> TableStructureEditorModel {
        .init(profile: .init(name: "Synthetic", settings: .init(host: "synthetic.invalid", port: 5432, database: "synthetic", user: "synthetic", password: "", sslMode: "disable", engine: engine)),
              schema: target.schema, table: target.table, create: false,
              connect: { self.connections += 1; return "session" }, send: request,
              authorize: { _, _, _ in "synthetic-grant" }, bindingIsCurrent: { true }, indexAuthoringSupported: { self.available }, changed: { _ in })
    }
    func request(_ command: BackendCommand) async throws -> BackendMessage {
        commands.append(command)
        var response = BackendMessage(type: command.type + ".result", requestId: command.requestId, sessionId: command.sessionId, queryId: command.queryId, transactionStatus: .idle, connected: true)
        if command.type == "structure.load" { response.structure = .init(baseline: .init(id: "baseline", target: target, engine: "postgresql", fingerprint: String(repeating: "a", count: 64), columns: [], limitations: [])) }
        if command.type == "structure.preview" { response.structure = .init(plan: .init(id: "plan", baselineId: "baseline", digest: String(repeating: "b", count: 64), target: target, sql: ["synthetic index step"], risks: [])) }
        return response
    }
}

@MainActor
struct TableStructureIndexAuthoringModelTests {
    @Test func independentCapabilityGatesBothPreviewAndApplyAndEditsInvalidatePreview() async {
        let backend = IndexAuthoringModelBackend()
        let model = backend.model()
        await model.load()
        model.draft.indexes = [.init(action: "add", name: "rich", definition: .init(method: "btree", terms: [.init(expression: "lower(value)")]))]
        #expect(model.draft.authoringVersion == 3 && model.canSaveDraft && !model.canPreview)
        await model.preparePreview()
        #expect(backend.commands.filter { $0.type == "structure.preview" }.isEmpty)
        backend.available = true
        #expect(model.canPreview && !model.authoringAvailable)
        await model.preparePreview()
        #expect(model.canApply && model.preview != nil)
        backend.available = false
        #expect(!model.canApply)
        backend.available = true
        model.draft.indexes?[0].definition?.predicate = "value IS NOT NULL"
        #expect(model.preview == nil && !model.canApply && model.canPreview)
        #expect(backend.commands.allSatisfy { $0.type != "structure.apply" })
    }

    @Test func removingRichFieldsRestoresLegacyAndVersionTwoAdmission() async {
        let backend = IndexAuthoringModelBackend()
        let model = backend.model()
        await model.load()
        model.draft.indexes = [.init(action: "add", name: "rich", definition: .init(method: "btree", terms: [.init(column: "value")]))]
        #expect(model.draft.authoringVersion == 3 && !model.canPreview)
        model.draft.indexes = [.init(action: "add", name: "ordinary", columns: ["value"])]
        #expect(model.draft.authoringVersion == nil && model.canPreview && model.portableDraft.draft.authoringVersion == nil)
        model.draft.renameTable = "after"
        #expect(model.draft.authoringVersion == 2)
        model.draft.indexes?[0].columns = nil
        model.draft.indexes?[0].definition = .init(method: "btree", terms: [.init(column: "value")])
        #expect(model.draft.authoringVersion == 3)
        model.draft.indexes = nil
        #expect(model.draft.authoringVersion == 2 && model.portableDraft.draft.authoringVersion == 2)
        model.draft.renameTable = nil
        #expect(model.draft.authoringVersion == nil)
    }

    @Test func restoreRetainsRichIntentUntilExplicitLoadAndNeverConnectsImplicitly() async throws {
        let backend = IndexAuthoringModelBackend(); backend.available = true
        let model = backend.model()
        model.discard()
        let document = StructureDraftDocument(engine: .postgresql, target: backend.target, draft: .init(columns: [], indexes: [.init(action: "add", name: "é", definition: .init(method: "btree", terms: [.init(expression: "lower('é')")]))]))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("build/index-authoring-drafts/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("synthetic.dbeerstructure")
        _ = try StructureDraftStore.write(document, to: url, expectedVersion: nil)
        await model.openDraft(from: url, expectedDocument: model.portableDraft, replaceReviewed: false)
        #expect(backend.connections == 0 && backend.commands.isEmpty && model.draft == document.draft && !model.canPreview && !model.canApply)
        await model.load()
        #expect(model.draft == document.draft && model.canPreview && model.preview == nil)
        #expect(model.draft.indexes?.first?.name.utf8.elementsEqual("é".utf8) == true)
        let sqlite = backend.model(engine: .sqlite)
        #expect(!sqlite.indexAuthoringAvailable)
    }
}

struct TableStructureIndexEvidenceVersionTests {
    private func legacy() throws -> SavedEvidenceArtifact {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/saved-evidence-v1.json"))) as? [String: Any]
        let artifacts = try #require(fixture?["artifacts"] as? [[String: Any]])
        let value = try #require(artifacts.first { $0["kind"] as? String == "structure" })
        #expect(value["version"] as? Int == 1)
        return try SavedEvidenceArtifact.decode(String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
    @Test func legacyEvidenceReadsAndWriterUsesThreeWithoutChangingHistory() throws {
        let value = try legacy()
        #expect(value.version == SavedEvidenceArtifact.currentVersion && value.valid)
        let text = try value.encoded()
        let fields = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(fields["version"] as? Int == SavedEvidenceArtifact.currentVersion)
        let decoded = try SavedEvidenceArtifact.decode(text)
        #expect(decoded == value && decoded.structure?.historicalExecutionID == value.structure?.historicalExecutionID)
        #expect(decoded.structure?.steps == value.structure?.steps && decoded.structure?.state == value.structure?.state)
        for version in [0, 99] {
            #expect(throws: (any Error).self) { try SavedEvidenceArtifact.decode(text.replacingOccurrences(of: "\"version\" : 4", with: "\"version\" : \(version)")) }
        }
    }
    @Test func richIntentAndObservationKeepVersionTwoBoundaryAndRemainOffline() throws {
        let definition = StructureIndexDefinition(method: "btree", terms: [.init(expression: "lower('é')")], includes: ["payload"], predicate: "payload IS NOT NULL")
        var value = try legacy()
        value.structure?.draft = .init(columns: [], indexes: [.init(action: "add", name: "é", definition: definition)], authoringVersion: 3)
        #expect(value.valid)
        var text = try value.encoded()
        #expect(try SavedEvidenceArtifact.decode(text).structure?.draft == value.structure?.draft)
        #expect(try SavedEvidenceArtifact.decode(text.replacingOccurrences(of: "\"version\" : 4", with: "\"version\" : 2")).structure?.draft == value.structure?.draft)
        #expect(throws: (any Error).self) { try SavedEvidenceArtifact.decode(text.replacingOccurrences(of: "\"version\" : 4", with: "\"version\" : 1")) }
        value = try legacy()
        let target = try #require(value.structure?.target)
        value.structure?.observed = SavedStructureObservation(.init(id: "must-not-survive", target: target, engine: "postgresql", fingerprint: String(repeating: "a", count: 64), columns: [], limitations: [], indexes: [.init(name: "é", columns: [], unique: false, supported: true, definition: definition)]))
        #expect(value.valid)
        text = try value.encoded()
        let decoded = try SavedEvidenceArtifact.decode(text)
        #expect(decoded.structure?.observed?.indexes?.first?.definition == definition && !text.contains("must-not-survive"))
        #expect(throws: (any Error).self) { try SavedEvidenceArtifact.decode(text.replacingOccurrences(of: "\"version\" : 4", with: "\"version\" : 1")) }
        #expect(decoded.structure?.displayReview.plan.baselineId == "offline-evidence")
    }
}

/// Framed in-memory Python responses only; no database, AppKit or desktop access.
@MainActor
struct TableStructureIndexAuthoringTransportTests {
    private func client(hello: Bool, session: Bool, richObservation: Bool, connected: Bool = true) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        def read(): return json.loads(sys.stdin.readline())
        def send(v): print(json.dumps(v),flush=True)
        cap='tableStructureIndexAuthoringV1'
        c=read();send(dict(type='hello.ack',requestId=c['requestId'],protocolVersion=6,capabilities=[cap] if \(hello ? "True" : "False") else []))
        target=dict(schema='public',table='synthetic',create=False)
        baseline=dict(id='baseline',target=target,engine='postgresql',fingerprint='a'*64,columns=[],limitations=[])
        if \(richObservation ? "True" : "False"):
            baseline['indexes']=[dict(name='rich',columns=[],unique=False,supported=True,definition=dict(method='btree',terms=[dict(expression='lower(value)')]))]
        while True:
            c=read()
            if c['type']=='shutdown':
                send(dict(type='shutdown.ack',requestId=c['requestId']));break
            if c['type']=='connect':
                send(dict(type='connect.result',requestId=c['requestId'],sessionId='session',engine='postgresql',transactionStatus='idle',connected=True,capabilities=[cap] if \(session ? "True" : "False") else []));continue
            send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
            if c['type']=='structure.load': payload=dict(baseline=baseline)
            else: payload=dict(plan=dict(id='plan',baselineId='baseline',digest='b'*64,target=target,sql=['synthetic index step'],risks=[]))
            send(dict(type=c['type']+'.result',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'],transactionStatus='idle',connected=\(connected ? "True" : "False"),structure=payload))
        """])
    }
    private func connect(_ client: BackendClient) async throws {
        try await client.start()
        _ = try await client.request(.connect(.init(host: "synthetic.invalid", port: 5432, database: "synthetic", user: "synthetic", password: "", sslMode: "disable")))
    }
    @Test(arguments: [false, true], [false, true]) func richObservedPayloadRequiresBothCapabilities(hello: Bool, session: Bool) async throws {
        let client = client(hello: hello, session: session, richObservation: true)
        try await connect(client)
        let command = BackendCommand(type: "structure.load", requestId: UUID().uuidString, sessionId: "session", queryId: UUID().uuidString, structure: .init(target: .init(schema: "public", table: "synthetic", create: false)))
        if hello && session {
            let response = try await client.request(command)
            #expect(response.structure?.baseline?.indexes?.first?.definition?.method == "btree")
        } else {
            await #expect(throws: BackendTransportError.self) { try await client.request(command) }
        }
        _ = await client.shutdown()
        _ = await client.waitForExit()
    }
    @Test(arguments: [false, true], [false, true]) func advancedPreviewRequiresBothCapabilities(hello: Bool, session: Bool) async throws {
        let client = client(hello: hello, session: session, richObservation: false)
        try await connect(client)
        let command = BackendCommand(type: "structure.preview", requestId: UUID().uuidString, sessionId: "session", queryId: UUID().uuidString, structure: .init(baselineId: "baseline", draft: .init(columns: [], indexes: [.init(action: "add", name: "rich", definition: .init(method: "btree", terms: [.init(column: "value")]))], authoringVersion: 3)))
        if hello && session {
            let response = try await client.request(command)
            #expect(response.structure?.plan?.id == "plan")
        } else {
            await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(command) }
            #expect(!(await client.hasExited()))
        }
        _ = await client.shutdown()
        _ = await client.waitForExit()
    }
    @Test func explicitVersionThreeWithoutRichFieldsRequiresCapability() async throws {
        let client = client(hello: false, session: false, richObservation: false)
        try await connect(client)
        let command = BackendCommand(type: "structure.preview", requestId: UUID().uuidString, sessionId: "session", queryId: UUID().uuidString, structure: .init(baselineId: "baseline", draft: .init(columns: [], indexes: [.init(action: "add", name: "ordinary", columns: ["value"])], authoringVersion: 3)))
        await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(command) }
        #expect(!(await client.hasExited()))
        _ = await client.shutdown()
        _ = await client.waitForExit()
    }
    @Test func richObservationRetainsOriginalCapabilityForTerminalDisconnect() async throws {
        let client = client(hello: true, session: true, richObservation: true, connected: false)
        try await connect(client)
        let response = try await client.request(.init(type: "structure.load", requestId: UUID().uuidString, sessionId: "session", queryId: UUID().uuidString, structure: .init(target: .init(schema: "public", table: "synthetic", create: false))))
        #expect(response.connected == false && response.structure?.baseline?.indexes?.first?.definition?.method == "btree")
        _ = await client.shutdown()
        _ = await client.waitForExit()
    }

}
