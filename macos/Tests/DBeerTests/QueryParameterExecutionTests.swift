import Foundation
import Testing
@testable import DBeer

/// Memory stores, local files and isolated protocol subprocesses only. No
/// windows, native parameter dialogs, choosers or application activation.
@Suite(.serialized)
@MainActor
struct QueryParameterExecutionTests {
    private final class Directory {
        let url: URL
        init() throws {
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            url = repository.appendingPathComponent("build/query-parameters/execution/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        func file(_ name: String) -> URL { url.appendingPathComponent(name) }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    @MainActor private final class Counter { var helperStarts = 0; var parameterPrompts = 0 }

    @MainActor private final class ParameterGate {
        var definitions: [SQLParameterDefinition]?
        var profile: SavedConnection?
        private var continuation: CheckedContinuation<[QueryParameterBinding]?, Never>?

        func decide(_ definitions: [SQLParameterDefinition], _ profile: SavedConnection) async -> [QueryParameterBinding]? {
            self.definitions = definitions
            self.profile = profile
            return await withCheckedContinuation { continuation = $0 }
        }
        func release(_ bindings: [QueryParameterBinding]?) {
            continuation?.resume(returning: bindings)
            continuation = nil
        }
    }

    @MainActor private final class ConfirmationGate {
        var confirmation: OperationConfirmation?
        private var continuation: CheckedContinuation<Bool, Never>?

        func decide(_ confirmation: OperationConfirmation) async -> Bool {
            self.confirmation = confirmation
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(returning: true); continuation = nil }
    }

    private struct Counts: Decodable {
        let connects: Int
        let assessments: Int
        let executions: Int
    }

    private struct Fixture {
        let directory: Directory
        let entry: SQLLibraryEntry
        let profiles: [SavedConnection]
        let library: SQLLibrary
        let workspace: ApplicationWorkspace
        let store: MemorySQLDocumentStore
        let counter: Counter
        let client: BackendClient
    }

    private var definitions: [SQLParameterDefinition] {
        [.init(name: "label", type: .text), .init(name: "amount", type: .decimal), .init(name: "optional", type: .text)]
    }

    private var bindings: [QueryParameterBinding] {
        [.init(name: "label", type: .text, value: "ephemeral-value-e\u{301}'; DROP TABLE must_not_run; --"),
         .init(name: "amount", type: .decimal, value: "9007199254740993.1200"),
         .init(name: "optional", type: .text, value: nil)]
    }

    private var source: String { "SELECT :label, :amount, :optional;\r\nSELECT :label;\r\n" }

    /// Assertions run inside the subprocess. Its only auxiliary output is a
    /// count file; neither SQL nor parameter values are written to fixture logs.
    private func helper(directory: Directory, helloCapability: Bool, sessionCapability: Bool,
                        confirm: Bool) throws -> BackendClient {
        let expectedParameters = String(decoding: try JSONEncoder().encode(bindings), as: UTF8.self)
        let expectedSQL = String(decoding: try JSONEncoder().encode(["SELECT :label, :amount, :optional", "SELECT :label"]), as: UTF8.self)
        return BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, os, sys
        root = sys.argv[1]
        expected_parameters = json.loads(sys.argv[2])
        expected_sql = json.loads(sys.argv[3])
        sessions = {}
        counts = dict(connects=0, assessments=0, executions=0)
        def send(value): print(json.dumps(value), flush=True)
        def record():
            with open(os.path.join(root, 'counts.json'), 'w') as handle: json.dump(counts, handle)
        record()
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            reply = dict(requestId=command['requestId'])
            if kind == 'hello':
                reply.update(type='hello.ack', protocolVersion=\(BackendProtocol.version),
                    capabilities=['queryParametersV1'] if \(helloCapability ? "True" : "False") else [])
            elif kind == 'connect':
                counts['connects'] += 1
                session_id = 'parameter-session-' + str(counts['connects'])
                sessions[session_id] = dict(policy=command['connection']['policy'], engine=command['connection'].get('engine','postgresql'), pending=[])
                capabilities = ['execute','cancel','catalog','transactions']
                if \(sessionCapability ? "True" : "False"): capabilities.append('queryParametersV1')
                reply.update(type='connect.result', sessionId=session_id, engine=command['connection'].get('engine','postgresql'),
                    capabilities=capabilities, transactionStatus='idle')
            elif kind == 'operation.assess':
                counts['assessments'] += 1
                operations = command['operations']
                assert [operation['sql'] for operation in operations] in [expected_sql] + [[sql] for sql in expected_sql]
                assert all(operation.get('parameters') == expected_parameters for operation in operations)
                assert all('value' in parameter for operation in operations for parameter in operation['parameters'])
                session = sessions[command['sessionId']]
                session['pending'] = list(operations)
                reply.update(type='operation.assessment', sessionId=command['sessionId'], queryId=command['queryId'],
                    assessment=dict(decision='confirm' if \(confirm ? "True" : "False") else 'allow', policy=session['policy'],
                        authorization='parameter-fixture-grant', operations=[dict(kind='read',statements=[]) for operation in operations]))
            elif kind in ['execute','catalog']:
                session = sessions[command['sessionId']]
                columns, rows = [], []
                if kind == 'execute':
                    assert \(helloCapability ? "True" : "False") and \(sessionCapability ? "True" : "False")
                    assert command.get('authorization') == 'parameter-fixture-grant'
                    assert session['pending']
                    operation = session['pending'].pop(0)
                    assert command['sql'] == operation['sql']
                    assert command.get('parameters') == operation['parameters'] == expected_parameters
                    counts['executions'] += 1
                    columns = [dict(index=0,name='fixture',engine=session['engine'],nativeType='text')]
                    rows = [['fixture-result']]
                send(dict(type='query.started',requestId=command['requestId'],sessionId=command['sessionId'],queryId=command['queryId']))
                reply.update(type='query.result',sessionId=command['sessionId'],queryId=command['queryId'],transactionStatus='idle',
                    durationMs=1,columns=columns,rows=rows,commandTag='SELECT ' + str(len(rows)),rowCount=len(rows),displayedRowCount=len(rows),truncated=False)
            elif kind == 'cancel':
                sessions[command['sessionId']]['pending'] = []
                reply.update(type='cancel.ack',sessionId=command['sessionId'],queryId=command['queryId'],status='alreadyFinished')
            elif kind == 'disconnect':
                del sessions[command['sessionId']]
                reply.update(type='disconnect.ack',sessionId=command['sessionId'])
            elif kind == 'shutdown': reply.update(type='shutdown.ack')
            else: sys.exit(42)
            record()
            send(reply)
            if kind == 'shutdown': break
        """, directory.url.path, expectedParameters, expectedSQL])
    }

    private func fixture(engine: DatabaseEngine = .postgresql, helloCapability: Bool = true,
                         sessionCapability: Bool = true, confirm: Bool = false,
                         parameterDecision: @escaping @MainActor ([SQLParameterDefinition], SavedConnection) async -> [QueryParameterBinding]?,
                         executionDecision: @escaping @MainActor (OperationConfirmation) async -> Bool = { _ in true }) async throws -> Fixture {
        let directory = try Directory()
        let url = directory.file("report.sql")
        try Data(source.utf8).write(to: url)
        let library = SQLLibrary()
        let entry = try library.upsertEntry(fileURL: url, parameters: definitions)
        let profiles = ["First", "Second"].map { name in
            SavedConnection(name: name, settings: ConnectionSettings(host: "127.0.0.1", port: engine.defaultPort,
                database: "fixture", user: "fixture", password: "", sslMode: "disable", engine: engine))
        }
        let counter = Counter()
        let client = try helper(directory: directory, helloCapability: helloCapability,
            sessionCapability: sessionCapability, confirm: confirm)
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(sqlLibrary: library.snapshot))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: profiles, selectedConnectionId: profiles[0].id)),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store,
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: library, automaticallyWatchFiles: false,
            closeDecision: { _ in .rollback }, executionDecision: executionDecision,
            queryParameterDecision: { definitions, profile in
                counter.parameterPrompts += 1
                return await parameterDecision(definitions, profile)
            }, helperFactory: { counter.helperStarts += 1; return client })
        await workspace.restoreSavedWorkspace()
        await workspace.library.loadConnections()
        return Fixture(directory: directory, entry: entry, profiles: profiles, library: library,
            workspace: workspace, store: store, counter: counter, client: client)
    }

    private func document(_ fixture: Fixture, profile: Int = 0) async throws -> SQLDocument {
        let document = try #require(await fixture.workspace.openSQLLibraryEntry(fixture.entry))
        document.profileID = fixture.profiles[profile].id
        return document
    }

    private func counts(_ fixture: Fixture) throws -> Counts {
        try JSONDecoder().decode(Counts.self, from: Data(contentsOf: fixture.directory.file("counts.json")))
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test func cancellingParameterInputNeverStartsAHelperOrChangesTheSQL() async throws {
        let fixture = try await fixture(parameterDecision: { _, _ in nil })
        let document = try await document(fixture)
        await fixture.workspace.runScript(document)
        #expect(fixture.counter.parameterPrompts == 1 && fixture.counter.helperStarts == 0)
        #expect(document.text.utf8.elementsEqual(source.utf8))
        #expect(document.runtime == nil && !document.isRunning && fixture.workspace.history.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.file("counts.json").path))
        await fixture.workspace.shutdown()
    }

    @Test(arguments: ["text", "profile", "definitions"])
    func contextChangesWhileEnteringParametersCannotStartAHelper(_ mutation: String) async throws {
        let gate = ParameterGate()
        let fixture = try await fixture(parameterDecision: { await gate.decide($0, $1) })
        let document = try await document(fixture)
        let run = Task { await fixture.workspace.runScript(document) }
        defer { gate.release(nil); Task { await fixture.workspace.shutdown() } }
        try await eventually { gate.definitions != nil }
        #expect(gate.definitions == definitions && gate.profile?.id == fixture.profiles[0].id)
        switch mutation {
        case "text": document.text += "-- changed while entering parameters\n"
        case "profile": document.profileID = fixture.profiles[1].id
        default:
            _ = try fixture.library.upsertEntry(id: fixture.entry.id, fileURL: fixture.entry.fileURL,
                parameters: [.init(name: "label", type: .integer)])
        }
        gate.release(bindings)
        await run.value
        #expect(fixture.counter.helperStarts == 0 && document.runtime == nil)
        #expect(!document.isRunning && fixture.workspace.history.isEmpty)
        await fixture.workspace.shutdown()
    }

    @Test(arguments: [DatabaseEngine.postgresql, .mysql])
    func scriptsUseExactTypedBindingsAndIndependentSessionsWithoutPersistingValues(_ engine: DatabaseEngine) async throws {
        let values = bindings
        let fixture = try await fixture(engine: engine, parameterDecision: { _, _ in values })
        defer { Task { await fixture.workspace.shutdown() } }
        let first = try await document(fixture)
        let second = try await document(fixture, profile: 1)
        await fixture.workspace.runScript(first)
        await fixture.workspace.runScript(second)
        let primary = try #require(first.runtime)
        let secondary = try #require(second.runtime)
        #expect(primary.sessionId != nil && primary.sessionId != secondary.sessionId && primary !== secondary)
        #expect(primary.queryFailure == nil && secondary.queryFailure == nil)
        #expect(first.text.utf8.elementsEqual(source.utf8) && second.text.utf8.elementsEqual(source.utf8))
        #expect(first.executions.count == 2 && second.executions.count == 2)
        #expect((first.executions + second.executions).allSatisfy { $0.status == "Completed" && $0.sql.contains(":label") })
        #expect(fixture.counter.parameterPrompts == 2 && fixture.counter.helperStarts == 1)
        let totals = try counts(fixture)
        #expect(totals.assessments == 2 && totals.executions == 4 && totals.connects == 4)
        #expect(fixture.workspace.history.count == 4)
        #expect(fixture.workspace.history.allSatisfy { $0.sql.contains(":label") })
        let capture = try #require(fixture.workspace.snapshotCapture(for: first))
        let capturedSQL = "/* Parameter values were supplied for this execution and are not stored. */\n" +
            first.executions[first.selectedExecution].sql
        #expect(capture.sql.utf8.elementsEqual(capturedSQL.utf8) && capture.rows == [["fixture-result"]])
        for value in values.compactMap(\.value) { #expect(!capture.sql.contains(value)) }
        let historical = try #require(fixture.workspace.history.first)
        let reopened = fixture.workspace.openHistoryEntry(historical)
        #expect(reopened.runtime == nil && reopened.text.utf8.elementsEqual(historical.sql.utf8))
        await fixture.workspace.run(reopened)
        #expect(fixture.counter.parameterPrompts == 3 && reopened.runtime?.queryFailure == nil)
        #expect(reopened.executions.count == 1 && reopened.executions.first?.status == "Completed")
        #expect(reopened.runtime?.sessionId != primary.sessionId)
        let repeated = try counts(fixture)
        #expect(repeated.assessments == 3 && repeated.executions == 5 && repeated.connects == 5)
        await fixture.workspace.flushDocuments()
        let saved = await fixture.store.load()
        let serialized = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        for value in values.compactMap(\.value) { #expect(!serialized.contains(value)) }
        #expect(saved.documents.filter { $0.id == first.id || $0.id == second.id }
            .allSatisfy { $0.text.utf8.elementsEqual(source.utf8) })
        let storedReopened = try #require(saved.documents.first { $0.id == reopened.id })
        #expect(storedReopened.queryParameters == definitions)
        let restored = SQLDocument(restoring: storedReopened)
        #expect(restored.queryParameters == definitions && restored.runtime == nil && restored.executions.isEmpty)
        #expect(restored.text.utf8.elementsEqual(reopened.text.utf8))
        await fixture.workspace.shutdown()
        #expect(await fixture.client.waitForExit().status == 0)
    }

    @Test func parameterDefinitionChangesDuringOperationReviewInvalidateTheGrant() async throws {
        let gate = ConfirmationGate()
        let values = bindings
        let fixture = try await fixture(confirm: true, parameterDecision: { _, _ in values },
            executionDecision: { await gate.decide($0) })
        let document = try await document(fixture)
        let run = Task { await fixture.workspace.runScript(document) }
        defer { gate.release(); Task { await fixture.workspace.shutdown() } }
        try await eventually { gate.confirmation != nil }
        #expect(gate.confirmation?.operations.count == 2)
        #expect(gate.confirmation?.operations.allSatisfy { $0.parameters == values } == true)
        _ = try fixture.library.upsertEntry(id: fixture.entry.id, fileURL: fixture.entry.fileURL,
            parameters: [.init(name: "label", type: .integer)])
        gate.release()
        await run.value
        let totals = try counts(fixture)
        #expect(totals.assessments == 1 && totals.executions == 0)
        #expect(!document.isRunning && fixture.workspace.history.isEmpty)
        await fixture.workspace.shutdown()
        #expect(await fixture.client.waitForExit().status == 0)
    }

    @Test(arguments: [DatabaseEngine.cassandra, .mongodb])
    func unsupportedEnginesRejectParameterizedLibraryQueriesBeforeStartingAHelper(_ engine: DatabaseEngine) async throws {
        let values = bindings
        let fixture = try await fixture(engine: engine, parameterDecision: { _, _ in values })
        let document = try await document(fixture)
        await fixture.workspace.runScript(document)
        #expect(fixture.counter.helperStarts == 0 && document.runtime == nil)
        #expect(document.localError != nil && fixture.workspace.history.isEmpty)
        await fixture.workspace.shutdown()
    }

    @Test(arguments: [false, true])
    func missingHelloOrSessionCapabilityRejectsBeforeAssessmentAndExecution(_ helloCapability: Bool) async throws {
        let values = bindings
        let fixture = try await fixture(helloCapability: helloCapability, sessionCapability: !helloCapability,
            parameterDecision: { _, _ in values })
        let document = try await document(fixture)
        await fixture.workspace.runScript(document)
        let totals = try counts(fixture)
        #expect(totals.assessments == 0 && totals.executions == 0)
        #expect(document.localError != nil && !document.isRunning && fixture.workspace.history.isEmpty)
        await fixture.workspace.shutdown()
        #expect(await fixture.client.waitForExit().status == 0)
    }
}
