import Foundation
import Testing
@testable import DBeer

/// Exercises production navigation and owned query cancellation through a
/// transparent helper proxy. No windows or application activation.
@Suite(.serialized)
@MainActor
struct LogicalRelationshipLifecycleTests {
    @MainActor private final class Gate {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-local-link-lifecycle-" + UUID().uuidString, isDirectory: true)
        var pending: CheckedContinuation<WorkspaceCloseDecision, Never>?
        init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func mark(_ name: String) { _ = FileManager.default.createFile(atPath: file(name).path, contents: Data()) }
        func choose() async -> WorkspaceCloseDecision { await withCheckedContinuation { pending = $0 } }
        func resolve() { pending?.resume(returning: .cancel); pending = nil }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }
    private func helper(_ gate: Gate) -> BackendClient {
        let executable = ProcessInfo.processInfo.environment["DBEER_TEST_HELPER"] ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core").path
        return BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, time, subprocess, threading
        from pathlib import Path
        root = Path(sys.argv[1])
        child = subprocess.Popen([sys.argv[2]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        lock = threading.Lock()
        def forward(line):
            with lock:
                child.stdin.write(line)
                child.stdin.flush()
        def output():
            for line in child.stdout:
                value = json.loads(line)
                if (root/'notice').exists():
                    for collection in value.get('catalogMetadata',{}).get('collections',[]):
                        if collection.get('selector',{}).get('kind')=='columns':
                            collection['state']='partial'; collection['issue']='Fixture metadata notice'
                line = json.dumps(value).encode()+bytes([10])
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
        reader = threading.Thread(target=output, daemon=True)
        reader.start()
        held = False
        workers = []
        def delayed(line):
            while not (root/'release').exists(): time.sleep(0.005)
            forward(line)
        for line in sys.stdin.buffer:
            command = json.loads(line)
            selectors = command.get('catalogMetadata',{}).get('selectors',[])
            columns = command.get('catalog',{}).get('kind')=='columns' or any(item.get('kind')=='columns' for item in selectors)
            if command['type'] in ['catalog','catalog.page'] and columns and (root/'hold').exists() and not held:
                held = True
                (root/'entered').write_text(json.dumps(dict(session=command['sessionId'],query=command['queryId'])))
                worker = threading.Thread(target=delayed,args=(line,),daemon=True)
                worker.start(); workers.append(worker)
                continue
            if command['type']=='cancel':
                with (root/'cancels').open('a') as log: log.write(json.dumps(dict(session=command['sessionId'],query=command['queryId']))+'\\n')
            forward(line)
            if command['type']=='shutdown': break
        for worker in workers: worker.join(timeout=3)
        child.stdin.close()
        try: child.wait(timeout=5)
        except subprocess.TimeoutExpired: child.kill(); child.wait()
        reader.join(timeout=3)
        """, gate.directory.path, executable])
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }
    @Test(arguments: ["stop", "unrelatedClose", "changedProfile", "metadataNotice"])
    func metadataReadKeepsOriginalSourceAndOwnsCancellation(mode: String) async throws {
        let gate = try Gate()
        gate.mark("fixture.sqlite")
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(), logicalRelationships: LogicalRelationshipStore(fileURL: gate.file("links/library.json")),
            automaticallyWatchFiles: false, closeDecision: { _ in await gate.choose() }, executionDecision: { _ in true }, helperFactory: { helper(gate) })
        await workspace.start()
        do {
            let settings = ConnectionSettings(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite, sqlite: .init(path: gate.file("fixture.sqlite").path))
            try #require(await workspace.library.saveConnection(name: "Lifecycle", settings: settings))
            let profileID = try #require(workspace.library.selectedConnectionId)
            let sql = workspace.newDocument(profileID: profileID)
            await workspace.run(sql, sql: "CREATE TABLE source(id INTEGER PRIMARY KEY,k TEXT,label TEXT)")
            await workspace.run(sql, sql: "CREATE TABLE target(id INTEGER PRIMARY KEY,k TEXT)")
            await workspace.run(sql, sql: "INSERT INTO source VALUES(1,'match','original')")
            await workspace.run(sql, sql: "INSERT INTO target VALUES(1,'match')")
            try #require(sql.localError == nil && sql.runtime?.queryFailure == nil)
            let table = try #require(await workspace.openData(.init(profileID: profileID, name: "source", kind: .object, schema: "main", object: "source", objectKind: "table")))
            workspace.editLogicalRelationship(sourceProfileID: profileID, reference: table.table)
            let editor = try #require(workspace.logicalRelationshipEditor)
            editor.name = "Lifecycle mapping"
            editor.targetProfileID = profileID; editor.targetSchema = "main"; editor.targetName = "target"
            editor.columns = [.init(source: "k", target: "k")]
            await editor.validate(); try #require(editor.canConfirm)
            await editor.confirm(in: workspace.logicalRelationships); try #require(editor.saved)
            workspace.closeLogicalRelationshipEditor()
            let grid = try #require(table.grid), row = try #require(grid.rows.first)
            grid.set(.init(kind: "text", value: "Kept draft"), row: 0, column: 2)
            let savedValues = grid.rows[0].values, sessionID = table.runtime?.sessionId
            let direction = try #require(workspace.logicalRelationshipDirections(table, grid: grid).first)
            if mode == "unrelatedClose" { await workspace.run(sql, sql: "BEGIN"); try #require(sql.runtime?.transactionStatus == .transaction) }
            gate.mark("hold")
            let documentCount = workspace.documents.count
            let navigation = Task { await workspace.followLogicalRelationship(direction, rowID: row.id, in: table) }
            try await waitUntil { FileManager.default.fileExists(atPath: gate.file("entered").path) }
            try #require(table.logicalRelationshipRead != nil)
            if mode == "stop" {
                await workspace.stop(table)
                #expect(table.logicalRelationshipRead?.cancelled == true)
                let held = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: gate.file("entered"))) as? [String: String])
                let cancels = try String(contentsOf: gate.file("cancels"), encoding: .utf8).split(separator: "\n")
                let last = try #require(cancels.last)
                let canceled = try #require(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: String])
                #expect(canceled == held && canceled["session"] != sessionID)
            } else if mode == "changedProfile" {
                var replacement = settings; replacement.sqlite = .init(path: gate.file("replacement.sqlite").path)
                gate.mark("replacement.sqlite")
                try #require(await workspace.library.saveConnection(name: "Lifecycle", settings: replacement, id: profileID))
            } else if mode == "metadataNotice" {
                gate.mark("notice")
            } else {
                let closing = Task { await workspace.closeDocument(sql) }
                try await waitUntil { gate.pending != nil }
                gate.mark("release")
                try await waitUntil { table.logicalRelationshipRead?.phase.contains("close decision") == true }
                #expect(workspace.documents.count == documentCount && table.grid === grid)
                gate.resolve(); await closing.value
            }
            gate.mark("release")
            await navigation.value
            #expect(table.logicalRelationshipRead == nil && !table.isNavigatingTable && !grid.isClosing)
            #expect(table.grid === grid && grid.rows[0].values == savedValues && grid.pendingCount == 1)
            #expect(table.runtime?.sessionId == sessionID && table.runtime?.transactionStatus == .idle)
            if mode == "unrelatedClose" {
                #expect(workspace.documents.count == documentCount + 1 && workspace.documents.contains { $0.table?.name == "target" })
                await workspace.run(sql, sql: "ROLLBACK")
            } else {
                #expect(workspace.documents.count == documentCount && table.tableNavigationError != nil)
                #expect(workspace.logicalRelationships.relationships.count == 1)
                if mode == "metadataNotice" { #expect(table.tableNavigationError?.contains("metadata") == true) }
            }
            grid.set(.init(kind: "text", value: "original"), row: 0, column: 2)
            await workspace.shutdown()
        } catch { gate.mark("release"); gate.resolve(); await workspace.shutdown(); throw error }
    }
}
