import Foundation
import Testing
@testable import DBeer

@MainActor
struct NativeFeatureIntegrationTests {
    @Test func structureInvalidationMarksOnlyItsProfilesDiagramStaleWithoutConnecting() async throws {
        let profiles = ["First", "Second"].map {
            SavedConnection(name: $0, settings: ConnectionSettings(host: "127.0.0.1", port: 5432,
                database: "fixture", user: "fixture", password: "", sslMode: "disable"))
        }
        let tables = profiles.map { ERTableID(profileID: $0.id, schema: "fixture", name: "sample") }
        let saved = zip(profiles, tables).map { profile, table in
            StoredSQLDocument(title: "ER", text: "", kind: .erDiagram,
                erDiagram: StoredERDiagram(profileID: profile.id, engine: .postgresql,
                    database: "fixture", tables: [table]))
        }
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(documents: saved,
            selectedDocumentID: saved[0].id))
        var helperStarts = 0
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(
            library: .init(connections: profiles, selectedConnectionId: profiles[0].id)),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store, helperFactory: {
                helperStarts += 1
                return BackendClient(executableURL: URL(fileURLWithPath: "/native-feature-fixtures/unused-helper"))
            })
        await workspace.start()
        let models = try workspace.documents.map { try #require($0.erDiagramModel) }
        for i in models.indices {
            models[i].context = ERDiagramLoadContext(profileID: profiles[i].id,
                sessionID: "synthetic-service-\(i)", serviceGeneration: UUID(), settingsRevision: UUID(),
                engine: .postgresql, database: "fixture")
            models[i].setMetadata(ERTableMetadata(table: tables[i], columns: [], foreignKeys: [],
                columnState: .available, relationshipState: .available))
        }
        let otherContext = models[1].context
        workspace.invalidateStructureMetadata(profiles[0].id)
        #expect(models[0].context == nil)
        let changed = try #require(models[0].metadata[tables[0]])
        switch changed.columnState {
        case .stale: break
        default: Issue.record("DDL must mark loaded ER column facts stale")
        }
        switch changed.relationshipState {
        case .stale: break
        default: Issue.record("DDL must mark loaded ER relationship facts stale")
        }
        #expect(models[1].context == otherContext)
        #expect(models[1].metadata[tables[1]]?.columnState == .available)
        #expect(models[1].metadata[tables[1]]?.relationshipState == .available)
        #expect(helperStarts == 0 && workspace.services.isEmpty)
        await workspace.shutdown()
    }
}

extension NativeFeatureIntegrationTests {
    private func integrationPipeHelper(_ body: String) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        def read(): return json.loads(sys.stdin.readline())
        def send(value): print(json.dumps(value), flush=True)
        c=read();send(dict(type='hello.ack',requestId=c['requestId'],protocolVersion=5))
        \(body)
        """])
    }

    @Test func mixedExplainAndStructureRequestsNeverReachTheHelper() async throws {
        // The first post-handshake frame must be shutdown. Any rejected frame
        // reaching the pipe makes the shutdown acknowledgement impossible.
        let client = integrationPipeHelper("""
        c=read()
        if c['type']!='shutdown': sys.exit(91)
        send(dict(type='shutdown.ack',requestId=c['requestId']))
        """)
        try await client.start()
        var explain = BackendCommand.explain(sessionId: "synthetic-session",
            request: ExplainRequest(sql: "SELECT 1", mode: .plan))
        explain.structure = StructureRequest()
        var structure = BackendCommand(type: "structure.status", requestId: UUID().uuidString,
            sessionId: "synthetic-session", queryId: UUID().uuidString, structure: StructureRequest())
        structure.explain = ExplainRequest(sql: "SELECT 1", mode: .plan)
        for command in [explain, structure] {
            await #expect(throws: BackendRequestError.invalidCommand) { try await client.request(command) }
        }
        let shutdown = await client.shutdown()
        #expect(shutdown.acknowledged && !shutdown.forced)
        #expect(await client.waitForExit().status == 0)
    }

    @Test func mixedExplainAndStructureReplyPayloadsAreRejectedInBothDirections() throws {
        let result = try #require(ExplainFixture.load().results.first)
        var explain = BackendMessage(type: "explain.result", requestId: "synthetic-explain",
            sessionId: "synthetic-session", queryId: "synthetic-query", transactionStatus: .idle,
            durationMs: 1, sqlCompleted: true, explain: result)
        _ = try NDJSONFramer.decode(JSONEncoder().encode(explain))
        explain.structure = StructureReply()
        #expect(throws: BackendTransportError(.invalidMessage)) {
            _ = try NDJSONFramer.decode(JSONEncoder().encode(explain))
        }
        var structure = BackendMessage(type: "structure.status.result", requestId: "synthetic-structure",
            sessionId: "synthetic-session", queryId: "synthetic-query", transactionStatus: .idle,
            connected: true, structure: StructureReply())
        _ = try NDJSONFramer.decode(JSONEncoder().encode(structure))
        structure.explain = result
        #expect(throws: BackendTransportError(.invalidMessage)) {
            _ = try NDJSONFramer.decode(JSONEncoder().encode(structure))
        }
    }

    @Test func structureTerminalRequiresStartedEvenWhenItsPayloadIsValid() async throws {
        let terminal = BackendMessage(type: "structure.status.result", requestId: "synthetic-request",
            sessionId: "synthetic-session", queryId: "synthetic-query", transactionStatus: .idle,
            connected: true, structure: StructureReply())
        _ = try NDJSONFramer.decode(JSONEncoder().encode(terminal))
        let client = integrationPipeHelper("""
        c=read()
        send(dict(type='structure.status.result',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'],transactionStatus='idle',connected=True,structure={}))
        sys.stdin.readline()
        """)
        try await client.start()
        let command = BackendCommand(type: "structure.status", requestId: "synthetic-request",
            sessionId: "synthetic-session", queryId: "synthetic-query", structure: StructureRequest())
        await #expect(throws: BackendTransportError(.invalidMessage)) { try await client.request(command) }
        #expect(await client.waitForFailure().code == .invalidMessage)
        _ = await client.shutdown()
    }
}


extension NativeFeatureIntegrationTests {
    @Test func optionalTransportPayloadsPreserveOmissionAndWireRoundTrips() throws {
        let empty = BackendMessage(type: "hello.ack", requestId: "synthetic-hello", protocolVersion: 5)
        let emptyData = try JSONEncoder().encode(empty)
        let fields = try #require(JSONSerialization.jsonObject(with: emptyData) as? [String: Any])
        for key in ["explain", "explainSupport", "comparison", "schemaComparison", "dataComparison"] {
            #expect(fields[key] == nil)
        }
        #expect(try NDJSONFramer.decode(emptyData) == empty)
        var withNulls = fields
        withNulls["explain"] = NSNull()
        withNulls["explainSupport"] = NSNull()
        #expect(try NDJSONFramer.decode(JSONSerialization.data(withJSONObject: withNulls)) == empty)

        let result = try #require(ExplainFixture.load().results.first)
        let explain = BackendMessage(type: "explain.result", requestId: "synthetic-explain",
            sessionId: "synthetic-session", queryId: "synthetic-query", transactionStatus: .idle,
            durationMs: 1, sqlCompleted: true, explain: result)
        let connect = BackendMessage(type: "connect.result", requestId: "synthetic-connect",
            engine: result.support.engine, capabilities: [], sessionId: "synthetic-session",
            transactionStatus: .idle, explainSupport: result.support)
        for message in [explain, connect] {
            let data = try JSONEncoder().encode(message)
            #expect(try NDJSONFramer.decode(data) == message)
            let encoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if message.explain != nil {
                let payload = try #require(encoded["explain"] as? [String: Any])
                #expect(payload["raw"] as? String == result.raw)
                #expect(encoded["explainSupport"] == nil)
            } else {
                let payload = try #require(encoded["explainSupport"] as? [String: Any])
                #expect(payload["serverVersion"] as? String == result.support.serverVersion)
                #expect(encoded["explain"] == nil)
            }
        }
    }

    @Test func optionalTransportPayloadMutationDoesNotChangeCopiedMessages() throws {
        let result = try #require(ExplainFixture.load().results.first)
        let original = BackendMessage(type: "explain.result", requestId: "synthetic-copy",
            explain: result, explainSupport: result.support)
        var copy = original
        #expect(copy == original)
        copy.explain?.raw += " copied mutation"
        copy.explain?.metrics.removeAll()
        copy.explainSupport?.modes.removeAll()
        #expect(original.explain == result && original.explainSupport == result.support)
        #expect(copy.explain?.raw == result.raw + " copied mutation")
        #expect(copy.explainSupport?.modes.isEmpty == true)
        #expect(copy != original)
        copy.explain = nil
        copy.explainSupport = nil
        #expect(original.explain != nil && original.explainSupport != nil)
        let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(copy)) as? [String: Any])
        #expect(fields["explain"] == nil && fields["explainSupport"] == nil)
        #expect(try JSONDecoder().decode(BackendMessage.self, from: JSONEncoder().encode(original)) == original)
    }
}
