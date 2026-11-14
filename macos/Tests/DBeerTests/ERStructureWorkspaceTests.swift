import Foundation
import Testing
@testable import DBeer

/// Memory stores, isolated preferences and injected decisions only. The lifetime
/// regression uses a framed fake helper that records counters, never SQL/secrets.
@Suite(.serialized)
@MainActor
struct ERStructureWorkspaceTests {
    @Test func restoredStructureActionsRequireExplicitConnectionAndNeverStartAHelper() async throws {
        let profile = SavedConnection(name: "Synthetic", settings: .init(host: "synthetic.invalid", port: 5432,
            database: "synthetic", user: "fixture", password: "", sslMode: "disable"))
        let table = ERTableID(profileID: profile.id, schema: "public", name: "child")
        let stored = StoredERDiagram(profileID: profile.id, engine: profile.engine, database: profile.database,
            sources: [.init(profile)], tables: [table], selected: table)
        let saved = StoredSQLDocument(title: "Restored", text: "", kind: .erDiagram, erDiagram: stored)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-c4-memory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var starts = 0
        let defaultsName = "dbeer-c4-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let themes = EditorThemeStore(defaults: defaults, directory: folder.appendingPathComponent("themes"))
        let snapshots = ResultSnapshotStore(rootURL: folder.appendingPathComponent("snapshots"))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library: .init(connections: [profile])),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(snapshot: .init(documents: [saved])),
            commandShortcuts: AppShortcutStore(defaults: defaults), copySettings: ResultCopySettings(defaults: defaults),
            editorThemes: themes, appearance: AppAppearance(defaults: defaults, editorThemes: themes),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: SQLLibrary(),
            tableBrowsePresets: TableBrowsePresetStore(fileURL: folder.appendingPathComponent("views.json")),
            logicalRelationships: LogicalRelationshipStore(fileURL: folder.appendingPathComponent("links.json")),
            resultSnapshots: ResultSnapshotsModel(store: snapshots), planArtifacts: PlanArtifactsModel(store: PlanArtifactStore(rootURL: folder.appendingPathComponent("plans"))),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in false },
            helperFactory: { starts += 1; return BackendClient(executableURL: URL(fileURLWithPath: "/synthetic/unused-helper")) })
        await workspace.start()
        let document = try #require(workspace.documents.first { $0.id == saved.id })
        for action in [ERStructureAction.create(profileID: profile.id, schema: "public"), .edit(table), .addForeignKey(table)] {
            #expect(workspace.erStructureUnavailableReason(document, action: action)?.contains("Connect this exact saved profile explicitly") == true)
            await workspace.openERStructure(document, action: action)
        }
        #expect(starts == 0 && workspace.services.isEmpty && workspace.structureEditor == nil)
        #expect(document.erDiagramModel?.metadata.isEmpty == true)
        let graph = try #require(document.erDiagramModel)
        graph.move(table, to: .init(x: 91, y: -31)); graph.toggleCollapse(table)
        graph.setMetadata(.init(table: table, columnState: .available, relationshipState: .available))
        let invocation = ERStructureInvocation(documentID: document.id, source: .init(profile),
            context: .init(profileID: profile.id, sessionID: "synthetic", serviceGeneration: UUID(), settingsRevision: UUID(), engine: profile.engine, database: profile.database), action: .edit(table), model: graph)
        let plan = StructurePlan(id: "plan", baselineId: "baseline", digest: String(repeating: "a", count: 64),
            target: .init(schema: table.schema, table: table.name, create: false), sql: ["synthetic step"], risks: [])
        let review = TableStructureExecutionReview(outcome: .init(executionId: "execution", planId: plan.id, state: "outcomeUnknown", steps: [.init(state: "unknown")]), plan: plan, draft: .init(columns: []))
        await workspace.refreshERStructureResult(invocation, review: review)
        #expect(!graph.metadata[table]!.columnState.isAvailable && graph.sourceState(profile.id).notice?.contains("no terminal acknowledgement") == true)
        #expect(starts == 0 && workspace.services.isEmpty && graph.stored.collapsed.contains(table))
        #expect(graph.stored.placements.first?.point == .init(x: 91, y: -31))
        await workspace.shutdown()
    }

    @Test(arguments: ["source", "card", "rebind", "label", "metadata"])
    func suspendedConfirmationCannotReviveARetiredBinding(change: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-c4-lifetime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaultsName = "dbeer-c4-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let themes = EditorThemeStore(defaults: defaults, directory: folder.appendingPathComponent("themes"))
        let snapshots = ResultSnapshotStore(rootURL: folder.appendingPathComponent("snapshots"))
        let settings = ConnectionSettings(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite,
            sqlite: .init(path: folder.appendingPathComponent("unused.sqlite").path))
        try Data().write(to: URL(fileURLWithPath: try #require(settings.sqlite?.path)))
        let profile = SavedConnection(name: "Synthetic owner", settings: settings)
        let counts = folder.appendingPathComponent("counts.json"), gate = C4StructureDecisionGate()
        let client = lifetimeClient(counts: counts)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library: .init(connections: [profile])),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
            commandShortcuts: AppShortcutStore(defaults: defaults), copySettings: ResultCopySettings(defaults: defaults),
            editorThemes: themes, appearance: AppAppearance(defaults: defaults, editorThemes: themes),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: SQLLibrary(),
            tableBrowsePresets: TableBrowsePresetStore(fileURL: folder.appendingPathComponent("views.json")),
            logicalRelationships: LogicalRelationshipStore(fileURL: folder.appendingPathComponent("links.json")),
            resultSnapshots: ResultSnapshotsModel(store: snapshots), planArtifacts: PlanArtifactsModel(store: PlanArtifactStore(rootURL: folder.appendingPathComponent("plans"))),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in await gate.decide() }, helperFactory: { client })
        await workspace.start()
        do {
            await workspace.connectProfile(profile.id)
            let table = ERTableID(profileID: profile.id, schema: "main", name: "synthetic")
            let document = try #require(workspace.openERDiagram(.init(profileID: profile.id, name: table.name, kind: .object,
                schema: table.schema, object: table.name, objectKind: "table")))
            let model = try #require(document.erDiagramModel)
            let originalContext = try #require(workspace.erDiagramContext(model, profileID: profile.id))
            await workspace.openERStructure(document, action: .edit(table))
            let editor = try #require(workspace.structureEditor)
            editor.draft = .init(columns: [], allowDestructive: true, dropTable: true)
            await editor.preparePreview()
            try #require(editor.preview?.droppedTarget == true && editor.canApply)
            let applying = Task { await editor.apply() }
            defer { gate.release(); applying.cancel() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !gate.entered {
                guard ContinuousClock.now < deadline else { throw ERDiagramFailure("The exact structure confirmation was not reached.") }
                try await Task.sleep(for: .milliseconds(10))
            }
            switch change {
            case "source":
                workspace.removeERDiagramSource(document, profileID: profile.id, expectedFingerprint: ERDiagramSource(profile).fingerprint, expectedTables: [table])
                workspace.confirmERDiagramSource(document, profileID: profile.id)
                model.add(table)
            case "card": model.remove(table); model.add(table)
            case "rebind":
                let replacement = ERTableID(profileID: profile.id, schema: table.schema, name: "other")
                workspace.rebindERDiagramTable(document, original: table, replacement: replacement)
                workspace.rebindERDiagramTable(document, original: replacement, replacement: table)
            case "label":
                try #require(await workspace.library.saveConnection(name: "Renamed human label", settings: settings, id: profile.id))
                workspace.confirmERDiagramSource(document, profileID: profile.id)
            default: model.invalidateSource(profile.id, reason: "A metadata-only refresh remains independent of structure ownership.")
            }
            #expect(workspace.erDiagramContext(model, profileID: profile.id) == originalContext && model.stored.tables.contains(table))
            gate.release(); await applying.value
            let counters = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: counts))
            if ["label", "metadata"].contains(change) {
                #expect(counters == ["assess": 1, "grants": 1, "apply": 1] && editor.outcome?.state == "applied")
            } else {
                #expect(counters == ["assess": 0, "grants": 0, "apply": 0])
                #expect(editor.invalidated && editor.outcome == nil && editor.error != nil)
            }
            #expect(gate.calls == 1)
            await workspace.closeTableStructure()
            await workspace.shutdown()
        } catch {
            gate.release()
            await workspace.closeTableStructure()
            await workspace.shutdown()
            throw error
        }
    }

    private func lifetimeClient(counts: URL) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,pathlib,sys
        counters=dict(assess=0,grants=0,apply=0)
        path=pathlib.Path(sys.argv[1])
        def record(): path.write_text(json.dumps(counters))
        def send(v): print(json.dumps(v),flush=True)
        record()
        caps=['tableStructureEditorV1','tableStructureAuthoringV2','tableStructureDestructiveV1']
        sessions={}
        target=dict(schema='main',table='synthetic',create=False)
        baseline=dict(id='baseline',target=target,engine='sqlite',fingerprint='a'*64,columns=[],limitations=[])
        for line in sys.stdin:
            c=json.loads(line);kind=c['type'];r=dict(requestId=c['requestId'])
            if kind=='hello': send(dict(r,type='hello.ack',protocolVersion=6,capabilities=caps));continue
            if kind=='shutdown': record();send(dict(r,type='shutdown.ack'));break
            if kind=='connect':
                session='session-'+str(len(sessions)+1);sessions[session]=c['connection']['policy']
                send(dict(r,type='connect.result',sessionId=session,engine='sqlite',transactionStatus='idle',connected=True,capabilities=caps));continue
            r.update(sessionId=c.get('sessionId'))
            if kind=='disconnect': send(dict(r,type='disconnect.ack'));continue
            if kind=='operation.assess':
                counters['assess']+=1;counters['grants']+=1;record()
                assessment=dict(decision='allow',policy=sessions[c['sessionId']],operations=[dict(kind='write',statements=[])],authorization='synthetic-grant')
                send(dict(r,type='operation.assessment',queryId=c['queryId'],assessment=assessment));continue
            r.update(queryId=c.get('queryId'),transactionStatus='idle',connected=True)
            send(dict(r,type='query.started'))
            if kind=='catalog':
                names=['name','nativeType','nullable','primaryKey'] if c['catalog']['kind']=='columns' else []
                rows=[['id','integer','false','1']] if names else []
                send(dict(r,type='query.result',columns=[dict(index=i,name=n,nativeType='text') for i,n in enumerate(names)],rows=rows,rowCount=len(rows),displayedRowCount=len(rows),durationMs=0,truncated=False,commandTag='SELECT 0'));continue
            payload={}
            if kind=='structure.load': payload=dict(baseline=baseline)
            elif kind=='structure.preview':
                payload=dict(plan=dict(id='plan',baselineId='baseline',digest='b'*64,target=target,sql=['synthetic reviewed DROP'],risks=[],destructive=True,droppedTarget=True))
            elif kind=='structure.apply':
                counters['apply']+=1;record();a=c['structure']['apply']
                payload=dict(outcome=dict(executionId=a['executionId'],planId=a['planId'],state='applied',steps=[dict(state='applied')],droppedTarget=True))
            send(dict(r,type=kind+'.result',structure=payload))
        """, counts.path])
    }
}

@MainActor
private final class C4StructureDecisionGate {
    var entered = false
    var calls = 0
    private var released = false
    private var continuation: CheckedContinuation<Bool, Never>?
    func decide() async -> Bool {
        calls += 1; entered = true
        if released { return true }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(returning: true); continuation = nil }
}
