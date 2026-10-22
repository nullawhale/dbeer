import Foundation
import Testing
@testable import DBeer

/// Local files, isolated stores and optional protocol subprocesses only.
/// No native chooser, windows, application activation or desktop input.
@Suite(.serialized)
@MainActor
struct SharedSQLFileTests {
    @MainActor private final class Counter { var helperStarts = 0 }

    private final class Directory {
        let url: URL
        init() throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            url = root.appendingPathComponent("build/r12-r13/shared-files/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        func file(_ name: String = "analysis.sql") -> URL { url.appendingPathComponent(name) }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    @MainActor private struct Fixture {
        let directory: Directory
        let url: URL
        let workspace: ApplicationWorkspace
        let store: MemorySQLDocumentStore
        let counter: Counter

        func pair() async throws -> (SQLDocument, SQLDocument, SQLFileDocument) {
            let first = try #require(await workspace.openSQLFile(at: url))
            let second = try #require(workspace.openSQLFileInNewTab(first))
            let file = try #require(first.fileDocument)
            try #require(second.fileDocument === file)
            return (first, second, file)
        }
    }

    private func fixture(text: String = "SELECT 'accepted';\r\n") async throws -> Fixture {
        let directory = try Directory()
        let url = directory.file()
        try Data(text.utf8).write(to: url)
        let store = MemorySQLDocumentStore()
        let counter = Counter()
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store,
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), automaticallyWatchFiles: false,
            closeDecision: { _ in .rollback },
            helperFactory: { counter.helperStarts += 1; return BackendClient() })
        await workspace.restoreSavedWorkspace()
        return Fixture(directory: directory, url: url, workspace: workspace, store: store, counter: counter)
    }

    private func expectBytes(_ actual: String, _ expected: String) {
        #expect(actual.utf8.elementsEqual(expected.utf8))
    }

    private func sessionHelper() -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys
        sessions = {}
        sequence = 0
        def send(value): print(json.dumps(value), flush=True)
        for line in sys.stdin:
            command = json.loads(line)
            kind = command['type']
            reply = dict(requestId=command['requestId'])
            if kind == 'hello':
                reply.update(type='hello.ack', protocolVersion=\(BackendProtocol.version))
            elif kind == 'connect':
                sequence += 1
                session = 'file-view-' + str(sequence)
                sessions[session] = 'idle'
                reply.update(type='connect.result', sessionId=session, engine='postgresql',
                    capabilities=['execute','cancel','catalog','transactions'], transactionStatus='idle')
            elif kind == 'operation.assess':
                reply.update(type='operation.assessment', sessionId=command['sessionId'], queryId=command['queryId'],
                    assessment=dict(decision='allow', policy=dict(environment='unspecified', readOnly=False), authorization='fixture-grant',
                        operations=[dict(kind='read', statements=[]) for operation in command['operations']]))
            elif kind in ['execute','catalog']:
                session = command['sessionId']
                sql = command.get('sql','').strip().rstrip(';')
                if sql == 'BEGIN': sessions[session] = 'transaction'
                elif sql in ['COMMIT','ROLLBACK']: sessions[session] = 'idle'
                send(dict(type='query.started', requestId=command['requestId'], sessionId=session, queryId=command['queryId']))
                reply.update(type='query.result', sessionId=session, queryId=command['queryId'], transactionStatus=sessions[session],
                    durationMs=1, columns=[], rows=[], commandTag='SELECT 0', rowCount=0, displayedRowCount=0, truncated=False)
            elif kind == 'cancel':
                reply.update(type='cancel.ack', sessionId=command['sessionId'], queryId=command['queryId'], status='alreadyFinished')
            elif kind == 'disconnect':
                assert sessions[command['sessionId']] == 'idle'
                del sessions[command['sessionId']]
                reply.update(type='disconnect.ack', sessionId=command['sessionId'])
            elif kind == 'shutdown': reply.update(type='shutdown.ack')
            else: sys.exit(42)
            send(reply)
            if kind == 'shutdown': break
        """])
    }

    @Test func viewsShareExactTextWhileBindingsSelectionAndRuntimeRemainIndependent() async throws {
        let original = "\u{feff}SELECT 'κόσμος 🐋';\r\n-- e\u{301}\r\n"
        let fixture = try await fixture(text: original)
        let first = try #require(await fixture.workspace.openSQLFile(at: fixture.url))
        let firstRuntime = WorkspaceModel(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        first.attach(firstRuntime)
        first.profileID = UUID()
        first.selection = NSRange(location: 1, length: 2)
        first.title = "Production analysis"
        let second = try #require(fixture.workspace.openSQLFileInNewTab(first))
        #expect(second.id != first.id && second.runtime == nil && second.executions.isEmpty)
        let file = try #require(first.fileDocument)
        #expect(second.fileDocument === file && second.storedState.fileDocumentID == file.id)
        let secondRuntime = WorkspaceModel(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        second.attach(secondRuntime)
        second.profileID = UUID()
        second.selection = NSRange(location: 7, length: 0)
        second.title = "Staging analysis"
        expectBytes(first.text, original)
        let edited = original + "SELECT 'a\u{301}';\r\n"
        second.text = edited
        expectBytes(first.text, edited)
        expectBytes(file.text, edited)
        first.text = edited + "SELECT 'é';\r\n"
        expectBytes(second.text, first.text)
        #expect(first.runtime === firstRuntime && second.runtime === secondRuntime && first.runtime !== second.runtime)
        #expect(first.profileID != second.profileID && first.selection != second.selection)
        #expect(first.title == "Production analysis" && second.title == "Staging analysis")
        #expect(await fixture.workspace.openSQLFile(at: fixture.url) === first)
        #expect(fixture.workspace.documents.count == 2 && fixture.counter.helperStarts == 0)
        await fixture.workspace.shutdown()
    }

    @Test func boundSaveUpdatesEveryViewAndPreservesBOMCRLFAndUnicodeBytes() async throws {
        let fixture = try await fixture(text: "\u{feff}SELECT 'accepted';\r\n")
        let (first, second, file) = try await fixture.pair()
        let edited = "\u{feff}SELECT 'e\u{301} 😀';\r\nSELECT '';\r\n"
        first.text = edited
        #expect(file.isDirty)
        fixture.workspace.saveSQLFile(first)
        #expect(fixture.workspace.error == nil && !file.isDirty && !file.restoredBinding)
        #expect(try Data(contentsOf: fixture.url) == Data(edited.utf8))
        let saved = try SQLFileBinding.read(fixture.url)
        #expect(first.fileContentSHA256 == saved.sha256 && second.fileContentSHA256 == saved.sha256)
        #expect(file.acceptedVersion == saved.version)
        await fixture.workspace.flushDocuments()
        let snapshot = await fixture.store.load()
        #expect(snapshot.documents.map(\.fileDocumentID) == [file.id, file.id])
        #expect(snapshot.documents.allSatisfy { $0.text.utf8.elementsEqual(edited.utf8) })
        #expect(fixture.counter.helperStarts == 0)
        await fixture.workspace.shutdown()
    }

    @Test func sharedFileViewsExecuteInIndependentProfileSessionsAndTransactions() async throws {
        let directory = try Directory()
        let url = directory.file()
        try Data("BEGIN;\r\n".utf8).write(to: url)
        let primary = SavedConnection(name: "Primary fixture", settings: ConnectionSettings(host: "127.0.0.1", port: 5432,
            database: "primary", user: "fixture", password: "", sslMode: "disable"))
        let secondary = SavedConnection(name: "Secondary fixture", settings: ConnectionSettings(host: "127.0.0.1", port: 5432,
            database: "secondary", user: "fixture", password: "", sslMode: "disable"))
        let client = sessionHelper()
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            SavedConnectionLibrary(connections: [primary, secondary], selectedConnectionId: primary.id)),
            credentialStore: MemoryConnectionCredentialStore(), sqlFolders: SQLFolderLibrary(automaticallyRefresh: false),
            automaticallyWatchFiles: false, closeDecision: { _ in .rollback }, executionDecision: { _ in true },
            helperFactory: { client })
        defer { Task { await workspace.shutdown() } }
        await workspace.start()
        let first = try #require(await workspace.openSQLFile(at: url))
        let second = try #require(workspace.openSQLFileInNewTab(first))
        first.profileID = primary.id
        second.profileID = secondary.id
        await workspace.run(first)
        let firstRuntime = try #require(first.runtime)
        let firstSession = try #require(firstRuntime.sessionId)
        try #require(firstRuntime.transactionStatus == .transaction && firstRuntime.queryFailure == nil)
        #expect(second.runtime == nil)
        second.text = "SELECT 2;\r\n"
        await workspace.run(second)
        let secondRuntime = try #require(second.runtime)
        let secondSession = try #require(secondRuntime.sessionId)
        #expect(first.fileDocument === second.fileDocument && firstRuntime !== secondRuntime)
        #expect(firstSession != secondSession && firstRuntime.sessionId == firstSession)
        #expect(firstRuntime.transactionStatus == .transaction && secondRuntime.transactionStatus == .idle)
        #expect(first.profileID == primary.id && second.profileID == secondary.id && secondRuntime.queryFailure == nil)
        expectBytes(first.text, second.text)
        await workspace.closeDocument(first)
        #expect(firstRuntime.sessionId == nil && secondRuntime.sessionId == secondSession)
        #expect(secondRuntime.connectionState == .connected && secondRuntime.transactionStatus == .idle)
        #expect(workspace.documents.contains { $0 === second } && second.fileDocument != nil)
        await workspace.shutdown()
        #expect(await client.waitForExit().status == 0)
    }

    @Test func closingViewDetachesStaleObjectAndReopeningUsesCurrentSharedDraft() async throws {
        let fixture = try await fixture()
        let (first, second, file) = try await fixture.pair()
        first.text = "SELECT 'before close';\r\n"
        let oldID = first.id
        await fixture.workspace.closeDocument(first)
        #expect(first.fileDocument == nil && second.fileDocument === file)
        #expect(fixture.workspace.documents.count == 1 && fixture.workspace.canReopenClosedTab)
        first.text = "SELECT 'stale closed object';\r\n"
        expectBytes(file.text, "SELECT 'before close';\r\n")
        expectBytes(second.text, file.text)
        second.text = "SELECT 'edited while another view was closed';\r\n"
        let reopened = try #require(fixture.workspace.reopenClosedTab())
        #expect(reopened.id != oldID && reopened.fileDocument === file && reopened.runtime == nil)
        expectBytes(reopened.text, second.text)
        reopened.text += "-- shared after reopening\r\n"
        expectBytes(second.text, reopened.text)
        expectBytes(first.text, "SELECT 'stale closed object';\r\n")
        #expect(fixture.counter.helperStarts == 0)
        await fixture.workspace.shutdown()
    }

    @Test func cleanExternalUpdateIsAdoptedButDirtyConflictKeepsBothVersions() async throws {
        let fixture = try await fixture()
        let (first, second, file) = try await fixture.pair()
        let external = "SELECT 'external clean';\r\n"
        try Data(external.utf8).write(to: fixture.url, options: .atomic)
        await fixture.workspace.reconcileSQLFiles()
        expectBytes(first.text, external)
        expectBytes(second.text, external)
        #expect(!file.isDirty && file.conflict == nil)
        let accepted = file.acceptedSHA256
        let local = "SELECT 'keep local e\u{301}';\r\n"
        first.text = local
        let concurrent = "SELECT 'external after local';\r\n"
        try Data(concurrent.utf8).write(to: fixture.url, options: .atomic)
        await fixture.workspace.reconcileSQLFiles()
        let conflict = try #require(file.conflict)
        expectBytes(conflict.externalText, concurrent)
        expectBytes(first.text, local)
        expectBytes(second.text, local)
        #expect(file.isDirty && file.acceptedSHA256 == accepted)
        fixture.workspace.saveSQLFile(first)
        #expect(fixture.workspace.error != nil && file.conflict?.id == conflict.id)
        #expect(try Data(contentsOf: fixture.url) == Data(concurrent.utf8))
        expectBytes(file.text, local)
        #expect(fixture.counter.helperStarts == 0)
        await fixture.workspace.shutdown()
    }

    @Test func staleConflictAndCanonicallyEquivalentButDifferentReviewTextCannotReplace() async throws {
        let fixture = try await fixture()
        let (first, second, file) = try await fixture.pair()
        let local = "SELECT 'e\u{301}';\r\n"
        first.text = local
        let external = "SELECT 'external';\r\n"
        try Data(external.utf8).write(to: fixture.url, options: .atomic)
        await fixture.workspace.reconcileSQLFiles()
        let conflict = try #require(file.conflict)
        await #expect(throws: SQLFileDocumentFailure.self) {
            try await file.resolve(conflictID: UUID(), decision: .useExternal, expectedText: local)
        }
        let differentBytes = "SELECT 'é';\r\n"
        try #require(!differentBytes.utf8.elementsEqual(local.utf8))
        await fixture.workspace.resolveSQLFileConflict(first, conflictID: conflict.id, decision: .replaceExternal,
            expectedText: differentBytes)
        #expect(file.conflict?.id == conflict.id && file.isDirty && fixture.workspace.error != nil)
        expectBytes(first.text, local)
        expectBytes(second.text, local)
        #expect(try Data(contentsOf: fixture.url) == Data(external.utf8))
        await fixture.workspace.shutdown()
    }

    @Test(arguments: [SQLFileConflictDecision.useExternal, .replaceExternal])
    func changedAgainDiskVersionInvalidatesPreviouslyReviewedChoice(_ decision: SQLFileConflictDecision) async throws {
        let fixture = try await fixture()
        let (first, second, file) = try await fixture.pair()
        let local = "SELECT 'local';\r\n"
        first.text = local
        try Data("SELECT 'external one';\r\n".utf8).write(to: fixture.url, options: .atomic)
        await fixture.workspace.reconcileSQLFiles()
        let reviewed = try #require(file.conflict)
        let newer = "SELECT 'external two';\r\n"
        try Data(newer.utf8).write(to: fixture.url, options: .atomic)
        await fixture.workspace.resolveSQLFileConflict(first, conflictID: reviewed.id, decision: decision,
            expectedText: local)
        let latest = try #require(file.conflict)
        #expect(latest.id != reviewed.id && file.isDirty && fixture.workspace.error != nil)
        expectBytes(latest.externalText, newer)
        expectBytes(first.text, local)
        expectBytes(second.text, local)
        #expect(try Data(contentsOf: fixture.url) == Data(newer.utf8))
        await fixture.workspace.shutdown()
    }

    @Test(arguments: [SQLFileConflictDecision.useExternal, .replaceExternal])
    func reviewedResolutionUpdatesTheSharedBufferAndAcceptedDiskVersion(_ decision: SQLFileConflictDecision) async throws {
        let fixture = try await fixture()
        let (first, second, file) = try await fixture.pair()
        let local = "SELECT 'local 🐋';\r\n"
        let external = "SELECT 'external é';\r\n"
        first.text = local
        try Data(external.utf8).write(to: fixture.url, options: .atomic)
        await fixture.workspace.reconcileSQLFiles()
        let conflict = try #require(file.conflict)
        await fixture.workspace.resolveSQLFileConflict(first, conflictID: conflict.id, decision: decision,
            expectedText: local)
        let expected: String
        switch decision {
        case .useExternal: expected = external
        case .replaceExternal: expected = local
        }
        expectBytes(first.text, expected)
        expectBytes(second.text, expected)
        #expect(try Data(contentsOf: fixture.url) == Data(expected.utf8))
        #expect(file.conflict == nil && !file.isDirty && fixture.workspace.error == nil)
        let accepted = try SQLFileBinding.read(fixture.url)
        #expect(first.fileContentSHA256 == accepted.sha256 && second.fileContentSHA256 == accepted.sha256)
        #expect(fixture.counter.helperStarts == 0)
        await fixture.workspace.shutdown()
    }

    @Test func deletedFileKeepsEditableSharedDraftAndSaveAsDetachesOnlyCurrentView() async throws {
        let fixture = try await fixture()
        let (first, second, file) = try await fixture.pair()
        let profile = UUID()
        first.profileID = profile
        let runtime = WorkspaceModel(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        first.attach(runtime)
        first.text = "SELECT 'local before delete';\r\n"
        try FileManager.default.removeItem(at: fixture.url)
        await fixture.workspace.reconcileSQLFiles()
        #expect(file.isMissing && first.fileURL == fixture.url && second.fileURL == fixture.url)
        first.text += "SELECT 'still editable';\r\n"
        let local = first.text
        fixture.workspace.saveSQLFile(first)
        #expect(fixture.workspace.error != nil && !FileManager.default.fileExists(atPath: fixture.url.path))
        let destination = fixture.directory.file("local copy.sql")
        try fixture.workspace.saveSQLFile(first, to: destination, reviewedVersion: nil)
        let copy = try #require(first.fileDocument)
        #expect(copy !== file && first.fileURL == destination && second.fileDocument === file)
        #expect(second.fileURL == fixture.url && file.isMissing && first.profileID == profile && first.runtime === runtime)
        expectBytes(second.text, local)
        #expect(try Data(contentsOf: destination) == Data(local.utf8))
        first.text += "-- independent copy\r\n"
        expectBytes(second.text, local)
        #expect(copy.isDirty && !FileManager.default.fileExists(atPath: fixture.url.path))
        await fixture.workspace.shutdown()
    }

    @Test func saveAsRequiresTheExactReviewedExistingDestinationVersion() async throws {
        let fixture = try await fixture()
        let (first, second, source) = try await fixture.pair()
        first.text = "SELECT 'local copy';\r\n"
        let originalURL = first.fileURL
        let destination = fixture.directory.file("existing.sql")
        let external = "SELECT 'existing destination';\r\n"
        try Data(external.utf8).write(to: destination)
        let reviewed = try SQLFileBinding.read(destination).version
        var failed = false
        do { try fixture.workspace.saveSQLFile(first, to: destination, reviewedVersion: nil) }
        catch { failed = true }
        #expect(failed && first.fileDocument === source && second.fileDocument === source && first.fileURL == originalURL)
        #expect(try Data(contentsOf: destination) == Data(external.utf8))
        let changed = "SELECT 'changed after review';\r\n"
        try Data(changed.utf8).write(to: destination, options: .atomic)
        failed = false
        do { try fixture.workspace.saveSQLFile(first, to: destination, reviewedVersion: reviewed) }
        catch { failed = true }
        #expect(failed && first.fileDocument === source && first.fileURL == originalURL)
        #expect(try Data(contentsOf: destination) == Data(changed.utf8))
        let latest = try SQLFileBinding.read(destination).version
        try fixture.workspace.saveSQLFile(first, to: destination, reviewedVersion: latest)
        #expect(first.fileURL == destination && first.fileDocument !== source && second.fileDocument === source)
        #expect(try Data(contentsOf: destination) == Data(first.text.utf8))
        #expect(try Data(contentsOf: fixture.url) == Data("SELECT 'accepted';\r\n".utf8))
        await fixture.workspace.shutdown()
    }

    @Test func saveAsCannotSilentlyMergeAnotherFilesIndependentDirtyBuffer() async throws {
        let fixture = try await fixture()
        let (first, _, source) = try await fixture.pair()
        first.text = "SELECT 'source draft';\r\n"
        let destination = fixture.directory.file("other.sql")
        let original = "SELECT 'other disk';\r\n"
        try Data(original.utf8).write(to: destination)
        let other = try #require(await fixture.workspace.openSQLFile(at: destination))
        other.text = "SELECT 'other unsaved draft';\r\n"
        let target = try #require(other.fileDocument)
        let sourceText = first.text
        let targetText = other.text
        let reviewed = try SQLFileBinding.read(destination).version
        var failed = false
        do { try fixture.workspace.saveSQLFile(first, to: destination, reviewedVersion: reviewed) }
        catch { failed = true }
        #expect(failed && first.fileDocument === source && other.fileDocument === target)
        expectBytes(first.text, sourceText)
        expectBytes(other.text, targetText)
        #expect(try Data(contentsOf: destination) == Data(original.utf8))
        #expect(source.isDirty && target.isDirty)
        await fixture.workspace.shutdown()
    }

    @Test func saveAsJoiningAnOpenMatchingDraftRetainsTheSourcesPreservedExternalReference() async throws {
        let fixture = try await fixture()
        let (first, second, source) = try await fixture.pair()
        let recoveryURL = fixture.directory.file("source-preserved.sql")
        let preserved = "SELECT 'preserved external e\u{301}';\r\n"
        try Data(preserved.utf8).write(to: recoveryURL)
        source.retainRecovery(recoveryURL)
        let local = "SELECT 'matching local drafts';\r\n"
        first.text = local
        let destination = fixture.directory.file("open-target.sql")
        try Data("SELECT 'target before review';\r\n".utf8).write(to: destination)
        let targetView = try #require(await fixture.workspace.openSQLFile(at: destination))
        let target = try #require(targetView.fileDocument)
        targetView.text = local
        try #require(target.recoveryURL == nil && targetView.fileRecoveryURL == nil)
        let reviewed = try SQLFileBinding.read(destination).version
        try fixture.workspace.saveSQLFile(first, to: destination, reviewedVersion: reviewed)
        #expect(first.fileDocument === target && targetView.fileDocument === target && second.fileDocument === source)
        #expect(target.recoveryURL == recoveryURL && first.fileRecoveryURL == recoveryURL && targetView.fileRecoveryURL == recoveryURL)
        #expect(second.fileRecoveryURL == recoveryURL && !target.isDirty && source.isDirty)
        expectBytes(first.text, local)
        expectBytes(targetView.text, local)
        #expect(try Data(contentsOf: destination) == Data(local.utf8))
        #expect(try Data(contentsOf: fixture.url) == Data("SELECT 'accepted';\r\n".utf8))
        #expect(try Data(contentsOf: recoveryURL) == Data(preserved.utf8))
        await fixture.workspace.flushDocuments()
        #expect(await fixture.store.load().documents.allSatisfy { $0.fileRecoveryURL == recoveryURL })
        #expect(fixture.counter.helperStarts == 0)
        await fixture.workspace.shutdown()
    }

    @Test func saveAsCannotMergeDifferentPreservedExternalReferencesEvenWhenDraftTextMatches() async throws {
        let fixture = try await fixture()
        let (first, second, source) = try await fixture.pair()
        let sourceRecoveryURL = fixture.directory.file("source-preserved.sql")
        let targetRecoveryURL = fixture.directory.file("target-preserved.sql")
        let sourcePreserved = "SELECT 'source external';\r\n"
        let targetPreserved = "SELECT 'target external';\r\n"
        try Data(sourcePreserved.utf8).write(to: sourceRecoveryURL)
        try Data(targetPreserved.utf8).write(to: targetRecoveryURL)
        source.retainRecovery(sourceRecoveryURL)
        let local = "SELECT 'matching local drafts';\r\n"
        first.text = local
        let destination = fixture.directory.file("open-target.sql")
        let destinationText = "SELECT 'target must remain unchanged';\r\n"
        try Data(destinationText.utf8).write(to: destination)
        let targetView = try #require(await fixture.workspace.openSQLFile(at: destination))
        let target = try #require(targetView.fileDocument)
        targetView.text = local
        target.retainRecovery(targetRecoveryURL)
        let reviewed = try SQLFileBinding.read(destination).version
        #expect(throws: SQLFileDocumentFailure.self) {
            try fixture.workspace.saveSQLFile(first, to: destination, reviewedVersion: reviewed)
        }
        #expect(first.fileDocument === source && second.fileDocument === source && targetView.fileDocument === target)
        #expect(first.fileURL == fixture.url && targetView.fileURL == destination && source.isDirty && target.isDirty)
        #expect(source.recoveryURL == sourceRecoveryURL && target.recoveryURL == targetRecoveryURL)
        #expect(first.fileRecoveryURL == sourceRecoveryURL && second.fileRecoveryURL == sourceRecoveryURL)
        #expect(targetView.fileRecoveryURL == targetRecoveryURL)
        expectBytes(first.text, local)
        expectBytes(targetView.text, local)
        #expect(try SQLFileBinding.read(destination).version == reviewed)
        #expect(try Data(contentsOf: destination) == Data(destinationText.utf8))
        #expect(try Data(contentsOf: fixture.url) == Data("SELECT 'accepted';\r\n".utf8))
        #expect(try Data(contentsOf: sourceRecoveryURL) == Data(sourcePreserved.utf8))
        #expect(try Data(contentsOf: targetRecoveryURL) == Data(targetPreserved.utf8))
        await fixture.workspace.flushDocuments()
        let stored = await fixture.store.load().documents
        #expect(stored.first { $0.id == first.id }?.fileRecoveryURL == sourceRecoveryURL)
        #expect(stored.first { $0.id == targetView.id }?.fileRecoveryURL == targetRecoveryURL)
        #expect(fixture.counter.helperStarts == 0)
        await fixture.workspace.shutdown()
    }

    @Test func renamedFileAndAtomicCheckoutUpdateAllViewsWithoutFollowingUnrelatedHints() async throws {
        let fixture = try await fixture()
        let (first, second, file) = try await fixture.pair()
        first.title = "Keep custom title"
        let renamed = fixture.directory.file("renamed.sql")
        try FileManager.default.moveItem(at: fixture.url, to: renamed)
        await file.reconcile(suggestedURL: renamed)
        #expect(file.url == renamed && first.fileURL == renamed && second.fileURL == renamed)
        #expect(first.title == "Keep custom title" && second.title == "renamed.sql" && !file.isMissing)
        let originalIdentity = file.acceptedVersion?.identity
        let checkout = "SELECT 'new checkout';\r\n"
        try Data(checkout.utf8).write(to: renamed, options: .atomic)
        await fixture.workspace.reconcileSQLFiles()
        expectBytes(first.text, checkout)
        expectBytes(second.text, checkout)
        #expect(file.acceptedVersion?.identity != originalIdentity && file.conflict == nil)
        let unrelated = fixture.directory.file("unrelated.sql")
        try Data("SELECT 'unrelated';".utf8).write(to: unrelated)
        await file.reconcile(suggestedURL: unrelated)
        #expect(file.url == renamed && first.fileURL == renamed && second.fileURL == renamed)
        expectBytes(file.text, checkout)
        #expect(await fixture.workspace.openSQLFile(at: renamed) === first)
        await fixture.workspace.shutdown()
    }

    @Test func hardLinkPathsRemainIndependentWhenOnePathIsAtomicallyReplaced() async throws {
        let original = "SELECT 'original hard link';\r\n"
        let fixture = try await fixture(text: original)
        let aliasURL = fixture.directory.file("hard-linked.sql")
        try FileManager.default.linkItem(at: fixture.url, to: aliasURL)
        let first = try #require(await fixture.workspace.openSQLFile(at: fixture.url))
        let replaced = "SELECT 'replacement at first path';\r\n"
        try Data(replaced.utf8).write(to: fixture.url, options: .atomic)
        let alias = try #require(await fixture.workspace.openSQLFile(at: aliasURL))
        let firstFile = try #require(first.fileDocument)
        let aliasFile = try #require(alias.fileDocument)
        #expect(firstFile !== aliasFile && first.fileURL == fixture.url && alias.fileURL == aliasURL)
        expectBytes(alias.text, original)
        await fixture.workspace.reconcileSQLFiles()
        expectBytes(first.text, replaced)
        expectBytes(alias.text, original)
        alias.text = "SELECT 'saved only at second path';\r\n"
        fixture.workspace.saveSQLFile(alias)
        #expect(fixture.workspace.error == nil && !aliasFile.isDirty)
        #expect(try Data(contentsOf: aliasURL) == Data(alias.text.utf8))
        #expect(try Data(contentsOf: fixture.url) == Data(replaced.utf8))
        expectBytes(first.text, replaced)
        #expect(fixture.counter.helperStarts == 0)
        await fixture.workspace.shutdown()
    }

    @Test func workspaceRestoresSharedIDsFoldersAndDraftsWithoutFileReloadOrHelper() async throws {
        let fixture = try await fixture()
        let (first, second, file) = try await fixture.pair()
        first.text = "SELECT 'recovered shared draft';\r\n"
        first.profileID = UUID()
        second.profileID = UUID()
        _ = try await fixture.workspace.sqlFolders.attach(fixture.directory.url)
        await fixture.workspace.flushDocuments()
        let saved = await fixture.store.load()
        #expect(saved.version == 5 && saved.sqlFolders.count == 1)
        #expect(saved.documents.map(\.fileDocumentID) == [file.id, file.id])
        let external = "SELECT 'changed while closed';\r\n"
        try Data(external.utf8).write(to: fixture.url, options: .atomic)
        let counter = Counter()
        let restored = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(snapshot: saved),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), automaticallyWatchFiles: false,
            helperFactory: { counter.helperStarts += 1; return BackendClient() })
        await restored.restoreSavedWorkspace()
        let restoredFirst = try #require(restored.documents.first)
        let restoredSecond = try #require(restored.documents.last)
        #expect(restoredFirst.id == first.id && restoredSecond.id == second.id && restoredFirst.id != restoredSecond.id)
        #expect(restoredFirst.fileDocument === restoredSecond.fileDocument && restoredFirst.fileDocument?.id == file.id)
        expectBytes(restoredFirst.text, first.text)
        #expect(restoredFirst.runtime == nil && restoredSecond.runtime == nil && counter.helperStarts == 0)
        #expect(restored.sqlFolders.attachments == saved.sqlFolders && restoredFirst.fileDocument?.conflict == nil)
        #expect(try Data(contentsOf: fixture.url) == Data(external.utf8))
        await restored.reconcileSQLFiles()
        expectBytes(restoredFirst.text, first.text)
        expectBytes(restoredFirst.fileDocument?.conflict?.externalText ?? "", external)
        let third = try #require(restored.openSQLFileInNewTab(restoredFirst))
        #expect(third.fileDocument === restoredFirst.fileDocument && third.runtime == nil && third.id != restoredFirst.id)
        #expect(counter.helperStarts == 0)
        await restored.shutdown()
        await fixture.workspace.shutdown()
    }

    @Test func differingLegacyDraftsStayIndependentAndRequireSaveAsForTheRecoveryCopy() async throws {
        let fixture = try await fixture()
        let baseline = try SQLFileBinding.read(fixture.url).sha256
        let firstState = StoredSQLDocument(title: "First recovered", text: "SELECT 'first local';\r\n",
            fileURL: fixture.url, fileContentSHA256: baseline)
        let secondState = StoredSQLDocument(title: "Second recovered", text: "SELECT 'second local';\r\n",
            fileURL: fixture.url, fileContentSHA256: baseline)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(snapshot:
                SQLWorkspaceSnapshot(documents: [firstState, secondState], selectedDocumentID: secondState.id)),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), automaticallyWatchFiles: false,
            helperFactory: { fixture.counter.helperStarts += 1; return BackendClient() })
        await workspace.restoreSavedWorkspace()
        let first = try #require(workspace.documents.first)
        let second = try #require(workspace.documents.last)
        let main = try #require(first.fileDocument)
        let recovered = try #require(second.fileDocument)
        #expect(main !== recovered && !main.requiresSaveAs && recovered.requiresSaveAs)
        expectBytes(first.text, firstState.text)
        expectBytes(second.text, secondState.text)
        #expect(throws: SQLFileDocumentFailure.self) { try recovered.save() }
        workspace.saveSQLFile(second)
        #expect(workspace.error != nil && second.fileDocument === recovered)
        let copy = fixture.directory.file("recovered second.sql")
        try workspace.saveSQLFile(second, to: copy, reviewedVersion: nil)
        #expect(second.fileURL == copy && second.fileDocument !== recovered && first.fileDocument === main)
        #expect(try Data(contentsOf: fixture.url) == Data("SELECT 'accepted';\r\n".utf8))
        #expect(try Data(contentsOf: copy) == Data(secondState.text.utf8))
        #expect(fixture.counter.helperStarts == 0)
        await workspace.shutdown()
        await fixture.workspace.shutdown()
    }

    @Test func identicalLegacyBindingsMergeTheirBufferWithoutReadingDisk() async throws {
        let fixture = try await fixture()
        let baseline = try SQLFileBinding.read(fixture.url).sha256
        let draft = "SELECT 'identical recovered e\u{301}';\r\n"
        let firstState = StoredSQLDocument(title: "First recovered", text: draft,
            fileURL: fixture.url, fileContentSHA256: baseline)
        let secondState = StoredSQLDocument(title: "Second recovered", text: draft,
            fileURL: fixture.url, fileContentSHA256: baseline)
        try #require(firstState.fileDocumentID != secondState.fileDocumentID)
        try FileManager.default.removeItem(at: fixture.url)
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(documents: [firstState, secondState],
            selectedDocumentID: secondState.id))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store,
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), automaticallyWatchFiles: false,
            helperFactory: { fixture.counter.helperStarts += 1; return BackendClient() })
        await workspace.restoreSavedWorkspace()
        let first = try #require(workspace.documents.first)
        let second = try #require(workspace.documents.last)
        let file = try #require(first.fileDocument)
        #expect(second.fileDocument === file && !file.requiresSaveAs && file.issue == nil && !file.isMissing)
        expectBytes(file.text, draft)
        first.text += "-- still shared\r\n"
        expectBytes(second.text, first.text)
        await workspace.flushDocuments()
        #expect(await store.load().documents.map(\.fileDocumentID) == [file.id, file.id])
        #expect(fixture.counter.helperStarts == 0 && !FileManager.default.fileExists(atPath: fixture.url.path))
        await workspace.shutdown()
        await fixture.workspace.shutdown()
    }

    @Test(arguments: [false, true])
    func preservedExternalReferenceRestoresAndOpensAsAnIndependentUnboundDraft(_ bound: Bool) async throws {
        let fixture = try await fixture()
        let recoveryURL = fixture.directory.file("preserved-external.sql")
        let external = "\u{feff}SELECT 'preserved e\u{301} 🐋';\r\n"
        try Data(external.utf8).write(to: recoveryURL)
        let local = "SELECT 'local draft retained';\r\n"
        let state = StoredSQLDocument(title: "Recovery fixture", text: local,
            fileURL: bound ? fixture.url : nil,
            fileContentSHA256: bound ? SQLFileBinding.digestText("SELECT 'accepted';\r\n") : nil,
            fileRecoveryURL: recoveryURL)
        let encoded = try JSONEncoder().encode(SQLWorkspaceSnapshot(documents: [state], selectedDocumentID: state.id))
        let snapshot = try JSONDecoder().decode(SQLWorkspaceSnapshot.self, from: encoded)
        #expect(snapshot.documents.first?.fileRecoveryURL == recoveryURL && snapshot.documents.first?.isValid == true)
        let store = MemorySQLDocumentStore(snapshot: snapshot)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store,
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), automaticallyWatchFiles: false,
            helperFactory: { fixture.counter.helperStarts += 1; return BackendClient() })
        await workspace.restoreSavedWorkspace()
        let source = try #require(workspace.documents.first)
        #expect(source.fileRecoveryURL == recoveryURL && source.runtime == nil)
        #expect((source.fileDocument != nil) == bound)
        if bound { #expect(source.fileDocument?.recoveryURL == recoveryURL) }
        expectBytes(source.text, local)
        await workspace.openPreservedSQLFileVersion(source)
        let opened = try #require(workspace.documents.last)
        #expect(opened.id != source.id && workspace.documents.count == 2 && workspace.selectedDocumentID == opened.id)
        #expect(opened.fileDocument == nil && opened.fileURL == nil && opened.fileContentSHA256 == nil)
        #expect(opened.runtime == nil && opened.executions.isEmpty && opened.fileRecoveryURL == nil)
        expectBytes(opened.text, external)
        opened.text += "-- independently editable\r\n"
        expectBytes(source.text, local)
        #expect(source.fileRecoveryURL == recoveryURL && fixture.counter.helperStarts == 0)
        #expect(try Data(contentsOf: recoveryURL) == Data(external.utf8))
        await workspace.flushDocuments()
        let saved = await store.load()
        #expect(saved.documents.first?.fileRecoveryURL == recoveryURL && saved.documents.last?.fileURL == nil)
        #expect(saved.documents.last?.fileRecoveryURL == nil)
        await workspace.shutdown()
        await fixture.workspace.shutdown()
    }
}
