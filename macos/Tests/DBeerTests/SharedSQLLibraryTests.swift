import Foundation
import Testing
@testable import DBeer

/// Local files, memory stores and isolated protocol subprocesses only. These
/// tests never create windows, show choosers or activate the application.
@Suite(.serialized)
@MainActor
struct SharedSQLLibraryTests {
    @MainActor private final class Counter { var helperStarts = 0 }

    private final class Directory {
        let url: URL

        init() throws {
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            url = repository.appendingPathComponent("build/r14/shared-library/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func file(_ name: String) -> URL { url.appendingPathComponent(name) }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    @MainActor private final class DecisionGate {
        var confirmation: OperationConfirmation?
        private var continuation: CheckedContinuation<Bool, Never>?

        func decide(_ confirmation: OperationConfirmation) async -> Bool {
            self.confirmation = confirmation
            return await withCheckedContinuation { continuation = $0 }
        }

        func release() { continuation?.resume(returning: true); continuation = nil }
    }

    @MainActor private struct Fixture {
        let directory: Directory
        let url: URL
        let entry: SQLLibraryEntry
        let profiles: [SavedConnection]
        let workspace: ApplicationWorkspace
        let store: MemorySQLDocumentStore
        let counter: Counter
    }

    private func profiles() -> [SavedConnection] {
        [SavedConnection(name: "Development", settings: ConnectionSettings(host: "127.0.0.1", port: 5432,
            database: "development", user: "fixture", password: "", sslMode: "disable",
            policy: ExecutionPolicy(environment: .development, readOnly: false))),
         SavedConnection(name: "Production", settings: ConnectionSettings(host: "127.0.0.1", port: 5432,
            database: "production", user: "fixture", password: "", sslMode: "disable",
            policy: ExecutionPolicy(environment: .production, readOnly: true)))]
    }

    private func loadProfiles(_ workspace: ApplicationWorkspace, profiles: [SavedConnection]) async throws {
        let first = try #require(profiles.first)
        // This loads the memory connection library without starting a helper.
        try #require(await workspace.library.saveConnection(name: first.name,
            settings: first.settings(password: ""), id: first.id))
    }

    private func fixture(text: String = "SELECT 'shared';\r\n", indexed: Bool = true) async throws -> Fixture {
        let directory = try Directory()
        let url = directory.file("analysis.sql")
        try Data(text.utf8).write(to: url)
        let library = SQLLibrary()
        let entry = try library.upsertEntry(fileURL: url, folder: "Investigations", tags: ["shared", "daily"], scope: .allConnections)
        let snapshot = indexed ? library.snapshot : SQLLibrarySnapshot()
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(sqlLibrary: snapshot))
        let counter = Counter()
        let profiles = profiles()
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: profiles, selectedConnectionId: profiles[0].id)),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store,
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: SQLLibrary(), automaticallyWatchFiles: false,
            closeDecision: { _ in .rollback }, helperFactory: { counter.helperStarts += 1; return BackendClient() })
        await workspace.restoreSavedWorkspace()
        try await loadProfiles(workspace, profiles: profiles)
        return Fixture(directory: directory, url: url, entry: entry, profiles: profiles, workspace: workspace, store: store, counter: counter)
    }

    private func expectBytes(_ actual: String, _ expected: String) { #expect(actual.utf8.elementsEqual(expected.utf8)) }

    private func eventually(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await predicate())
    }

    @Test func libraryOpensOneRealFileInFreshUnboundViewsWithoutImplicitConnectionOrHelpers() async throws {
        let original = "\u{FEFF}SELECT 'e\u{301} 🐋';\r\n"
        let fixture = try await fixture(text: original)
        defer { Task { await fixture.workspace.shutdown() } }
        try #require(fixture.workspace.library.selectedConnectionId == fixture.profiles[0].id)
        let first = try #require(await fixture.workspace.openSQLLibraryEntry(fixture.entry))
        #expect(first.profileID == nil && first.runtime == nil && first.sqlLibraryEntryID == fixture.entry.id)
        #expect(fixture.workspace.sqlLibraryExecutionNotice(for: first) != nil)
        await fixture.workspace.run(first)
        #expect(first.localError != nil && first.runtime == nil && fixture.counter.helperStarts == 0)
        first.profileID = fixture.profiles[0].id
        #expect(fixture.workspace.sqlLibraryExecutionNotice(for: first) == nil)
        first.text += "SELECT 'same source';\r\n"
        let second = try #require(await fixture.workspace.openSQLLibraryEntry(fixture.entry))
        #expect(second.id != first.id && second.profileID == nil && second.runtime == nil)
        #expect(second.fileDocument === first.fileDocument && second.sqlLibraryEntryID == fixture.entry.id)
        expectBytes(second.text, first.text)
        second.profileID = fixture.profiles[1].id
        second.text += "-- one editable source\r\n"
        expectBytes(first.text, second.text)
        #expect(first.profileID != second.profileID)
        fixture.workspace.saveSQLFile(first)
        #expect(fixture.workspace.error == nil)
        #expect(try Data(contentsOf: fixture.url) == Data(second.text.utf8))
        #expect(fixture.workspace.sqlLibrary.snapshot.entries.count == 1)
        #expect(fixture.workspace.sqlLibrary.entry(id: fixture.entry.id)?.fileURL == fixture.url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.url.path).filter { $0.hasSuffix(".sql") } == ["analysis.sql"])
        await fixture.workspace.flushDocuments()
        let saved = await fixture.store.load()
        #expect(saved.documents.map(\.sqlLibraryEntryID) == [fixture.entry.id, fixture.entry.id])
        #expect(saved.documents.map(\.profileID) == fixture.profiles.map { Optional($0.id) })
        let metadata = try JSONEncoder().encode(saved.sqlLibrary)
        let object = try #require(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        let entries = try #require(object["entries"] as? [[String: Any]])
        #expect(entries.first?["text"] == nil && entries.first?["sql"] == nil && entries.first?["profile"] == nil)
        #expect(fixture.counter.helperStarts == 0)
        await fixture.workspace.shutdown()
    }

    @Test func ordinaryFileOpenOfAnIndexedPathAlsoRequiresAnExplicitProfile() async throws {
        let fixture = try await fixture()
        defer { Task { await fixture.workspace.shutdown() } }
        let document = try #require(await fixture.workspace.openSQLFile(at: fixture.url))
        #expect(document.sqlLibraryEntryID == fixture.entry.id && document.profileID == nil)
        await fixture.workspace.runScript(document)
        #expect(document.localError != nil && document.runtime == nil && fixture.counter.helperStarts == 0)
        #expect(Set(fixture.workspace.availableSQLLibraryProfiles(for: document).map(\.id)) == Set(fixture.profiles.map(\.id)))
        await fixture.workspace.shutdown()
    }

    @Test func indexingAnOpenOrdinaryFileClearsItsImplicitProfileAndRetainsItsDraft() async throws {
        let fixture = try await fixture(indexed: false)
        defer { Task { await fixture.workspace.shutdown() } }
        let document = try #require(await fixture.workspace.openSQLFile(at: fixture.url))
        #expect(document.profileID == fixture.profiles[0].id && document.sqlLibraryEntryID == nil)
        document.text += "-- local draft\r\n"
        let draft = document.text
        let entry = try fixture.workspace.sqlLibrary.upsertEntry(fileURL: fixture.url, folder: "Shared", tags: ["review"], scope: .allConnections)
        try await eventually { document.sqlLibraryEntryID == entry.id && document.profileID == nil }
        expectBytes(document.text, draft)
        await fixture.workspace.run(document)
        #expect(document.runtime == nil && fixture.counter.helperStarts == 0)
        #expect(try Data(contentsOf: fixture.url) != Data(draft.utf8))
        await fixture.workspace.shutdown()
    }

    @Test func profileGroupAndMissingScopesFailClosedBeforeStartingAHelper() async throws {
        let fixture = try await fixture()
        defer { Task { await fixture.workspace.shutdown() } }
        let library = fixture.workspace.sqlLibrary
        let group = try library.upsertGroup(name: "Reporting", profileIDs: [fixture.profiles[0].id])
        let entry = try library.upsertEntry(id: fixture.entry.id, fileURL: fixture.url,
            folder: fixture.entry.folder, tags: fixture.entry.tags, scope: .group(group.id))
        let document = try #require(await fixture.workspace.openSQLLibraryEntry(entry))
        #expect(fixture.workspace.availableSQLLibraryProfiles(for: document).map(\.id) == [fixture.profiles[0].id])
        document.profileID = fixture.profiles[1].id
        await fixture.workspace.run(document)
        #expect(document.localError != nil && document.runtime == nil && fixture.counter.helperStarts == 0)
        let context = AppCommandContext(documentID: document.id, focus: .workspace, isWorkspaceWindow: true, hasModal: false)
        for command: AppCommandID in [.runCurrent, .runScript, .runToJSON, .runToCSV] {
            #expect(!fixture.workspace.commands.canPerform(command, context: context))
        }
        _ = try library.upsertGroup(id: group.id, name: group.name, profileIDs: [fixture.profiles[1].id])
        #expect(fixture.workspace.availableSQLLibraryProfiles(for: document).map(\.id) == [fixture.profiles[1].id])
        #expect(fixture.workspace.sqlLibraryExecutionNotice(for: document) == nil)
        library.removeGroup(group.id)
        #expect(library.entry(id: entry.id)?.scope == .group(group.id))
        #expect(fixture.workspace.availableSQLLibraryProfiles(for: document).isEmpty)
        await fixture.workspace.run(document)
        #expect(document.runtime == nil && document.localError != nil && fixture.counter.helperStarts == 0)
        _ = try library.upsertEntry(id: entry.id, fileURL: fixture.url, folder: entry.folder, tags: entry.tags, scope: .profile(UUID()))
        #expect(fixture.workspace.availableSQLLibraryProfiles(for: document).isEmpty)
        await fixture.workspace.run(document)
        #expect(document.runtime == nil && fixture.counter.helperStarts == 0)
        await fixture.workspace.shutdown()
    }

    @Test func removedLibraryEntryKeepsExistingViewUnavailableButLeavesFileIntact() async throws {
        let fixture = try await fixture()
        defer { Task { await fixture.workspace.shutdown() } }
        let document = try #require(await fixture.workspace.openSQLLibraryEntry(fixture.entry))
        document.profileID = fixture.profiles[0].id
        let original = try Data(contentsOf: fixture.url)
        fixture.workspace.sqlLibrary.removeEntry(fixture.entry.id)
        #expect(document.sqlLibraryEntryID == fixture.entry.id && fixture.workspace.selectedSQLLibraryEntry(for: document) == nil)
        #expect(fixture.workspace.sqlLibraryExecutionNotice(for: document) != nil)
        await fixture.workspace.run(document)
        #expect(document.localError != nil && document.runtime == nil && fixture.counter.helperStarts == 0)
        #expect(try Data(contentsOf: fixture.url) == original)
        let ordinary = try #require(await fixture.workspace.openSQLFile(at: fixture.url, inNewTab: true))
        #expect(ordinary.id != document.id && ordinary.sqlLibraryEntryID == nil)
        #expect(ordinary.fileDocument === document.fileDocument)
        #expect(document.sqlLibraryEntryID == fixture.entry.id)
        await fixture.workspace.shutdown()
    }

    @Test func deletingAScopedProfileCannotRetargetTheSharedQueryToAnotherConnection() async throws {
        let fixture = try await fixture()
        defer { Task { await fixture.workspace.shutdown() } }
        let entry = try fixture.workspace.sqlLibrary.upsertEntry(id: fixture.entry.id, fileURL: fixture.url,
            folder: fixture.entry.folder, tags: fixture.entry.tags, scope: .profile(fixture.profiles[0].id))
        let document = try #require(await fixture.workspace.openSQLLibraryEntry(entry))
        document.profileID = fixture.profiles[0].id
        try #require(await fixture.workspace.library.deleteConnection(fixture.profiles[0].id))
        #expect(document.profileID == fixture.profiles[0].id)
        #expect(fixture.workspace.availableSQLLibraryProfiles(for: document).isEmpty)
        await fixture.workspace.run(document)
        #expect(document.runtime == nil && document.localError != nil && fixture.counter.helperStarts == 0)
        #expect(fixture.workspace.sqlLibrary.entry(id: entry.id)?.scope == .profile(fixture.profiles[0].id))
        await fixture.workspace.shutdown()
    }

    @Test func workspaceRestoresMetadataAndIndependentBindingsWithoutConnectingOrReloadingFiles() async throws {
        let fixture = try await fixture(text: "\u{FEFF}SELECT 'original';\r\n")
        let group = try fixture.workspace.sqlLibrary.upsertGroup(name: "All environments", profileIDs: fixture.profiles.map(\.id))
        let entry = try fixture.workspace.sqlLibrary.upsertEntry(id: fixture.entry.id, fileURL: fixture.url,
            folder: "Shared/Reporting", tags: ["daily"], scope: .group(group.id))
        let first = try #require(await fixture.workspace.openSQLLibraryEntry(entry))
        let second = try #require(await fixture.workspace.openSQLLibraryEntry(entry))
        first.profileID = fixture.profiles[0].id
        second.profileID = fixture.profiles[1].id
        first.text += "-- recovered shared draft e\u{301}\r\n"
        let draft = first.text
        await fixture.workspace.flushDocuments()
        let snapshot = await fixture.store.load()
        let fileStore = FileSQLDocumentStore(fileURL: fixture.directory.file("workspace.json"))
        try await fileStore.save(snapshot)
        #expect(try await fileStore.load().sqlLibrary == fixture.workspace.sqlLibrary.snapshot)
        await fixture.workspace.shutdown()
        try Data("SELECT 'external while closed';\r\n".utf8).write(to: fixture.url, options: .atomic)
        let counter = Counter()
        let restored = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: fixture.profiles, selectedConnectionId: fixture.profiles[1].id)),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: fileStore,
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: SQLLibrary(), automaticallyWatchFiles: false,
            helperFactory: { counter.helperStarts += 1; return BackendClient() })
        defer { Task { await restored.shutdown() } }
        await restored.restoreSavedWorkspace()
        #expect(restored.error == nil && restored.sqlLibrary.snapshot == snapshot.sqlLibrary)
        #expect(restored.documents.map(\.sqlLibraryEntryID) == [entry.id, entry.id])
        #expect(restored.documents.map(\.profileID) == fixture.profiles.map { Optional($0.id) })
        #expect(restored.documents.map(\.id) == [first.id, second.id])
        let views = restored.documents
        try #require(views.count == 2)
        #expect(views[0].fileDocument === views[1].fileDocument)
        for document in views {
            expectBytes(document.text, draft)
            #expect(document.runtime == nil && document.executions.isEmpty && !document.isRunning)
        }
        #expect(counter.helperStarts == 0 && restored.services.isEmpty)
        await restored.shutdown()
    }

    @Test func renameUpdatesTheIndexWhileSaveAsDetachesOnlyItsCurrentView() async throws {
        let fixture = try await fixture()
        defer { Task { await fixture.workspace.shutdown() } }
        let first = try #require(await fixture.workspace.openSQLLibraryEntry(fixture.entry))
        let second = try #require(await fixture.workspace.openSQLLibraryEntry(fixture.entry))
        let file = try #require(first.fileDocument)
        let renamed = fixture.directory.file("renamed.sql")
        try FileManager.default.moveItem(at: fixture.url, to: renamed)
        await file.reconcile(suggestedURL: renamed)
        try await eventually { fixture.workspace.sqlLibrary.entry(id: fixture.entry.id)?.fileURL == renamed }
        #expect(first.fileURL == renamed && second.fileURL == renamed)
        #expect(first.sqlLibraryEntryID == fixture.entry.id && second.sqlLibraryEntryID == fixture.entry.id)
        let current = try #require(fixture.workspace.sqlLibrary.entry(id: fixture.entry.id))
        #expect(current.folder == fixture.entry.folder && current.tags == fixture.entry.tags && current.scope == fixture.entry.scope)
        first.text += "-- editable shared draft\r\n"
        let copy = fixture.directory.file("personal-copy.sql")
        try fixture.workspace.saveSQLFile(first, to: copy, reviewedVersion: nil)
        #expect(first.sqlLibraryEntryID == nil && first.fileURL == copy)
        #expect(second.sqlLibraryEntryID == fixture.entry.id && second.fileURL == renamed)
        #expect(first.fileDocument !== second.fileDocument)
        #expect(fixture.workspace.sqlLibrary.entry(id: fixture.entry.id)?.fileURL == renamed)
        #expect(fixture.workspace.sqlLibrary.snapshot.entries.count == 1 && fixture.counter.helperStarts == 0)
        await fixture.workspace.shutdown()
    }

    private struct HelperCounts: Decodable { let connects: Int; let executions: Int; let assessments: Int }

    /// The helper records counts only. SQL, credentials and result data never
    /// enter fixture logs or auxiliary files.
    private func helper(directory: Directory, confirm: Bool = false, pauseConnect: Bool = false,
                        pauseFirstExecution: Bool = false) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, os, sys, time
        root = sys.argv[1]
        sessions = {}
        counts = dict(connects=0, executions=0, assessments=0)
        def send(value): print(json.dumps(value), flush=True)
        def record():
            with open(os.path.join(root, 'counts.json'), 'w') as handle: json.dump(counts, handle)
        def gate(name):
            open(os.path.join(root, name + '.waiting'), 'w').close()
            deadline = time.monotonic() + 6
            while not os.path.exists(os.path.join(root, name + '.release')) and time.monotonic() < deadline: time.sleep(0.005)
        record()
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            reply = dict(requestId=command['requestId'])
            if kind == 'hello':
                reply.update(type='hello.ack', protocolVersion=\(BackendProtocol.version))
            elif kind == 'connect':
                counts['connects'] += 1
                if \(pauseConnect ? "True" : "False") and counts['connects'] == 1: gate('connect')
                session = 'library-view-' + str(counts['connects'])
                sessions[session] = dict(transaction='idle', policy=command['connection']['policy'])
                reply.update(type='connect.result', sessionId=session, engine='postgresql',
                    capabilities=['execute','cancel','catalog','transactions'], transactionStatus='idle')
            elif kind == 'operation.assess':
                counts['assessments'] += 1
                policy = sessions[command['sessionId']]['policy']
                reply.update(type='operation.assessment', sessionId=command['sessionId'], queryId=command['queryId'],
                    assessment=dict(decision='confirm' if \(confirm ? "True" : "False") else 'allow',
                        policy=policy, authorization='library-fixture-grant',
                        operations=[dict(kind='read', statements=[]) for operation in command['operations']]))
            elif kind in ['execute','catalog']:
                session = sessions[command['sessionId']]
                if kind == 'execute':
                    counts['executions'] += 1
                    record()
                    if \(pauseFirstExecution ? "True" : "False") and counts['executions'] == 1: gate('execute')
                    sql = command.get('sql','').strip().rstrip(';')
                    if sql == 'BEGIN': session['transaction'] = 'transaction'
                    elif sql in ['COMMIT','ROLLBACK']: session['transaction'] = 'idle'
                send(dict(type='query.started', requestId=command['requestId'], sessionId=command['sessionId'], queryId=command['queryId']))
                reply.update(type='query.result', sessionId=command['sessionId'], queryId=command['queryId'],
                    transactionStatus=session['transaction'], durationMs=1, columns=[], rows=[],
                    commandTag='SELECT 0', rowCount=0, displayedRowCount=0, truncated=False)
            elif kind == 'cancel':
                reply.update(type='cancel.ack', sessionId=command['sessionId'], queryId=command['queryId'], status='alreadyFinished')
            elif kind == 'disconnect':
                assert sessions[command['sessionId']]['transaction'] == 'idle'
                del sessions[command['sessionId']]
                reply.update(type='disconnect.ack', sessionId=command['sessionId'])
            elif kind == 'shutdown': reply.update(type='shutdown.ack')
            else: sys.exit(42)
            record()
            send(reply)
            if kind == 'shutdown': break
        """, directory.url.path])
    }

    private func helperCounts(_ directory: Directory) throws -> HelperCounts {
        try JSONDecoder().decode(HelperCounts.self, from: Data(contentsOf: directory.file("counts.json")))
    }

    private func protocolWorkspace(directory: Directory, profiles: [SavedConnection], library: SQLLibrary,
                                   client: BackendClient,
                                   decision: @escaping @MainActor (OperationConfirmation) async -> Bool = { _ in true }) async -> ApplicationWorkspace {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: profiles, selectedConnectionId: profiles[0].id)),
            credentialStore: MemoryConnectionCredentialStore(), documentStore:
                MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(sqlLibrary: library.snapshot)),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: library, automaticallyWatchFiles: false,
            closeDecision: { _ in .rollback }, executionDecision: decision, helperFactory: { client })
        await workspace.start()
        return workspace
    }

    @Test func explicitDevelopmentAndProductionBindingsKeepIndependentSessionsTransactionsAndPolicies() async throws {
        let directory = try Directory()
        let url = directory.file("shared.sql")
        try Data("BEGIN;\r\n".utf8).write(to: url)
        let profiles = profiles()
        let library = SQLLibrary()
        let entry = try library.upsertEntry(fileURL: url, folder: "Shared", tags: [], scope: .allConnections)
        let client = helper(directory: directory)
        let workspace = await protocolWorkspace(directory: directory, profiles: profiles, library: library, client: client)
        defer { Task { await workspace.shutdown() } }
        let first = try #require(await workspace.openSQLLibraryEntry(entry))
        let second = try #require(await workspace.openSQLLibraryEntry(entry))
        try #require(first.profileID == nil && second.profileID == nil)
        first.profileID = profiles[0].id
        second.profileID = profiles[1].id
        await workspace.run(first)
        let primary = try #require(first.runtime)
        let primarySession = try #require(primary.sessionId)
        try #require(primary.transactionStatus == .transaction && primary.queryFailure == nil)
        second.text = "SELECT 2;\r\n"
        await workspace.run(second)
        let secondary = try #require(second.runtime)
        let secondarySession = try #require(secondary.sessionId)
        #expect(primarySession != secondarySession && primary !== secondary)
        #expect(first.fileDocument === second.fileDocument && primary.transactionStatus == .transaction)
        #expect(secondary.transactionStatus == .idle && secondary.queryFailure == nil)
        #expect(primary.policy == profiles[0].policy && secondary.policy == profiles[1].policy)
        #expect(primary.policy.environment == .development && secondary.policy.environment == .production && secondary.policy.readOnly)
        expectBytes(first.text, second.text)
        #expect(try helperCounts(directory).executions == 2)
        await workspace.closeDocument(first)
        #expect(primary.sessionId == nil && secondary.sessionId == secondarySession)
        #expect(secondary.connectionState == .connected && second.sqlLibraryEntryID == entry.id)
        await workspace.shutdown()
        #expect(await client.waitForExit().status == 0)
    }

    @Test func removingGroupMembershipDuringConnectionCannotExecuteThePreviouslyAllowedQuery() async throws {
        let directory = try Directory()
        let url = directory.file("shared.sql")
        try Data("SELECT 1;\r\n".utf8).write(to: url)
        let profiles = profiles()
        let library = SQLLibrary()
        let group = try library.upsertGroup(name: "Allowed", profileIDs: [profiles[0].id])
        let entry = try library.upsertEntry(fileURL: url, folder: "", tags: [], scope: .group(group.id))
        let client = helper(directory: directory, pauseConnect: true)
        let workspace = await protocolWorkspace(directory: directory, profiles: profiles, library: library, client: client)
        defer {
            try? Data().write(to: directory.file("connect.release"))
            Task { await workspace.shutdown() }
        }
        let document = try #require(await workspace.openSQLLibraryEntry(entry))
        document.profileID = profiles[0].id
        let run = Task { await workspace.run(document) }
        try await eventually { FileManager.default.fileExists(atPath: directory.file("connect.waiting").path) }
        _ = try library.upsertGroup(id: group.id, name: group.name, profileIDs: [profiles[1].id])
        try Data().write(to: directory.file("connect.release"))
        await run.value
        #expect(try helperCounts(directory).executions == 0)
        #expect(document.localError != nil && !document.isRunning)
        #expect(workspace.sqlLibraryExecutionNotice(for: document) != nil)
        await workspace.shutdown()
        #expect(await client.waitForExit().status == 0)
    }

    @Test func removingGroupMembershipDuringConfirmationInvalidatesTheCapturedAuthorization() async throws {
        let directory = try Directory()
        let url = directory.file("shared.sql")
        try Data("SELECT 1;\r\n".utf8).write(to: url)
        let profiles = profiles()
        let library = SQLLibrary()
        let group = try library.upsertGroup(name: "Allowed", profileIDs: [profiles[0].id])
        let entry = try library.upsertEntry(fileURL: url, folder: "", tags: [], scope: .group(group.id))
        let client = helper(directory: directory, confirm: true)
        let gate = DecisionGate()
        let workspace = await protocolWorkspace(directory: directory, profiles: profiles, library: library, client: client,
            decision: { await gate.decide($0) })
        defer { gate.release(); Task { await workspace.shutdown() } }
        let document = try #require(await workspace.openSQLLibraryEntry(entry))
        document.profileID = profiles[0].id
        let run = Task { await workspace.run(document) }
        try await eventually { gate.confirmation != nil }
        #expect(gate.confirmation?.profile.id == profiles[0].id)
        #expect(gate.confirmation?.profile.policy.environment == .development)
        library.removeGroup(group.id)
        gate.release()
        await run.value
        #expect(try helperCounts(directory).assessments == 1)
        #expect(try helperCounts(directory).executions == 0)
        #expect(document.executions.allSatisfy { $0.status == "Not executed" || $0.status == "Skipped" })
        #expect(workspace.sqlLibraryExecutionNotice(for: document) != nil)
        await workspace.shutdown()
        #expect(await client.waitForExit().status == 0)
    }

    @Test func changingScopeDuringTheFirstScriptStatementPreventsTheRemainingStatements() async throws {
        let directory = try Directory()
        let url = directory.file("shared.sql")
        try Data("SELECT 1;\r\nSELECT 2;\r\n".utf8).write(to: url)
        let profiles = profiles()
        let library = SQLLibrary()
        let entry = try library.upsertEntry(fileURL: url, folder: "", tags: [], scope: .allConnections)
        let client = helper(directory: directory, pauseFirstExecution: true)
        let workspace = await protocolWorkspace(directory: directory, profiles: profiles, library: library, client: client)
        defer {
            try? Data().write(to: directory.file("execute.release"))
            Task { await workspace.shutdown() }
        }
        let document = try #require(await workspace.openSQLLibraryEntry(entry))
        document.profileID = profiles[0].id
        let run = Task { await workspace.runScript(document) }
        try await eventually { FileManager.default.fileExists(atPath: directory.file("execute.waiting").path) }
        _ = try library.upsertEntry(id: entry.id, fileURL: url, folder: entry.folder, tags: entry.tags, scope: .profile(profiles[1].id))
        try Data().write(to: directory.file("execute.release"))
        await run.value
        #expect(try helperCounts(directory).executions == 1)
        #expect(document.executions.count == 2 && document.executions[0].status == "Completed" && document.executions[1].status == "Skipped")
        #expect(workspace.sqlLibraryExecutionNotice(for: document) != nil)
        await workspace.shutdown()
        #expect(await client.waitForExit().status == 0)
    }
}
