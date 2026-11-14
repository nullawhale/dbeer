import Foundation
import Testing
@testable import DBeer

/// Normal helper and deliberately connected synthetic profiles. All stores and
/// decisions are injected, SSH is absent, and no AppKit/SwiftUI view is created.
@Suite(.serialized)
@MainActor
struct ERStructureIntegrationTests {
    @Test func sqliteCreateEditAndUnsupportedForeignKeyUseSharedEditor() async throws { try await exercise(.sqlite) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresLocalMappingCreatesRealForeignKeyThroughSharedPreview() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlLocalMappingCreatesRealForeignKeyThroughSharedPreview() async throws { try await exercise(.mysql) }

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ERDiagramFailure("The owned structure metadata refresh did not finish.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func exercise(_ engine: DatabaseEngine) async throws {
        let environment = ProcessInfo.processInfo.environment
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = repository.appendingPathComponent("build/c4-integration/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = environment["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let settings: ConnectionSettings
        if engine == .sqlite {
            let file = folder.appendingPathComponent("fixture.sqlite")
            _ = FileManager.default.createFile(atPath: file.path, contents: Data())
            settings = .init(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: .sqlite, sqlite: .init(path: file.path))
        } else if engine == .mysql {
            settings = .init(host: environment["DBEER_TEST_MYSQL_HOST"] ?? "localhost", port: try #require(Int(environment["DBEER_TEST_MYSQL_PORT"] ?? "")),
                database: environment["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: environment["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
                password: environment["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: "disable", engine: .mysql)
        } else {
            let url = try #require(URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""))
            settings = .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()),
                user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        var decisions = 0
        let defaultsName = "dbeer-c4-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let themes = EditorThemeStore(defaults: defaults, directory: folder.appendingPathComponent("themes"))
        let snapshots = ResultSnapshotStore(rootURL: folder.appendingPathComponent("snapshots"))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(), commandShortcuts: AppShortcutStore(defaults: defaults), copySettings: ResultCopySettings(defaults: defaults),
            editorThemes: themes, appearance: AppAppearance(defaults: defaults, editorThemes: themes),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: SQLLibrary(),
            tableBrowsePresets: TableBrowsePresetStore(fileURL: folder.appendingPathComponent("views.json")),
            logicalRelationships: LogicalRelationshipStore(fileURL: folder.appendingPathComponent("links.json")),
            resultSnapshots: ResultSnapshotsModel(store: snapshots), planArtifacts: PlanArtifactsModel(store: PlanArtifactStore(rootURL: folder.appendingPathComponent("plans"))),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in decisions += 1; return true },
            helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let childName = "c4_child_" + suffix, parentName = "c4_parent_" + suffix, createdName = "c4_new_" + suffix, keyName = "c4_fk_" + suffix
        let renamedName = childName + "_r", checkedName = "c4_checked_" + suffix, blockedKeyName = "c4_blocked_" + suffix
        var setup: SQLDocument?
        do {
            try #require(await workspace.library.saveConnection(name: "C4 structure owner", settings: settings))
            let profile = try #require(workspace.library.savedConnections.last)
            let schema = engine == .postgresql ? "public" : engine == .sqlite ? "main" : settings.database
            let sql = workspace.newDocument(profileID: profile.id); setup = sql
            var statements = ["CREATE TABLE \(parentName)(id integer primary key)", "CREATE TABLE \(childName)(id integer primary key, parent_id integer)"]
            if engine == .sqlite { statements.append("CREATE TABLE \(checkedName)(id integer primary key, parent_id integer, CHECK(id > 0))") }
            statements += ["INSERT INTO \(parentName) VALUES(1)", "INSERT INTO \(childName) VALUES(1,1)"]
            for statement in statements {
                await workspace.run(sql, sql: statement)
                try #require(sql.localError == nil && sql.runtime?.queryFailure == nil)
            }
            let child = ERTableID(profileID: profile.id, schema: schema, name: childName), parent = ERTableID(profileID: profile.id, schema: schema, name: parentName)
            let document = try #require(workspace.openERDiagram(.init(profileID: profile.id, name: child.name, kind: .object,
                schema: schema, object: child.name, objectKind: "table")))
            let graph = try #require(document.erDiagramModel)
            graph.add(parent); graph.move(child, to: .init(x: 103, y: -57)); graph.toggleCollapse(child)
            await workspace.buildERDiagram(document, connect: true)
            try #require(graph.metadata[child]?.columnState.isAvailable == true)
            let captured = try workspace.prepareERStructure(document, action: .edit(child))
            let gate = C4MetadataTerminalGate(), pending = CatalogMetadataRequest()
            pending.task = Task { await gate.pause(); pending.finished = true; return BackendMessage(type: "query.result", requestId: "synthetic") }
            graph.sourceStates[profile.id, default: .init()].request = pending
            graph.invalidateSource(profile.id, reason: "Synthetic known terminal structure result")
            let terminalPlan = StructurePlan(id: "terminal-plan", baselineId: "terminal-baseline", digest: String(repeating: "a", count: 64),
                target: .init(schema: schema, table: childName, create: false), sql: ["synthetic unexecuted step"], risks: [])
            let terminalReview = TableStructureExecutionReview(outcome: .init(executionId: "terminal-execution", planId: terminalPlan.id,
                state: "failed", steps: [.init(state: "notStarted")]), plan: terminalPlan, draft: .init(columns: []))
            var refreshed = false
            let refresh = Task { await workspace.refreshERStructureResult(captured, review: terminalReview); refreshed = true }
            defer { gate.release(); refresh.cancel() }
            try await waitFor { gate.entered }
            #expect(!refreshed && graph.metadata[child]?.columnState.isAvailable == false)
            gate.release(); await refresh.value
            #expect(refreshed && graph.metadata[child]?.columnState.isAvailable == true)
            try #require(await workspace.library.saveConnection(name: "C4 separate local owner", settings: settings))
            let otherProfile = try #require(workspace.library.savedConnections.last)
            workspace.confirmERDiagramSource(document, profileID: otherProfile.id)
            let otherTable = ERTableID(profileID: otherProfile.id, schema: schema, name: childName)
            graph.add(otherTable)
            let otherFacts = ERTableMetadata(table: otherTable, columns: [.init(name: "untouched_owner", nativeType: "integer", nullable: true, primaryKeyPosition: nil)],
                columnState: .available, relationshipState: .available)
            graph.setMetadata(otherFacts); graph.select(otherTable)
            #expect(workspace.erStructureInvocationIsCurrent(captured, document: document, model: graph) && captured.action.table == child)
            #expect(workspace.services[otherProfile.id] == nil)

            await workspace.openERStructure(document, action: .create(profileID: profile.id, schema: schema))
            let creator = try #require(workspace.structureEditor)
            #expect(creator.baseline == nil && creator.preview == nil && creator.outcome == nil)
            creator.table = createdName; await creator.load()
            try #require(creator.error == nil)
            creator.draft = .init(columns: [.init(name: "value", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))])
            await creator.preparePreview(); try #require(creator.preview != nil && creator.outcome == nil)
            await creator.apply(); try #require(creator.outcome?.state == "applied")
            let created = ERTableID(profileID: profile.id, schema: schema, name: createdName)
            try await waitFor { graph.metadata[created]?.columnState.isAvailable == true && !graph.sourceState(profile.id).loading }
            await workspace.closeTableStructure()

            await workspace.openERStructure(document, action: .edit(child))
            let editor = try #require(workspace.structureEditor)
            #expect(editor.table == childName && editor.preview == nil && editor.outcome == nil)
            editor.draft = .init(columns: [.init(name: "added", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))])
            await editor.preparePreview(); try #require(editor.preview != nil)
            // Change the live baseline after Preview; the shared helper must fence Apply.
            await workspace.run(sql, sql: "ALTER TABLE \(childName) ADD COLUMN raced integer")
            try #require(sql.localError == nil && sql.runtime?.queryFailure == nil)
            await editor.apply()
            #expect(editor.outcome?.state == "failed" || editor.error != nil)
            await editor.load(); try #require(editor.error == nil)
            #expect(editor.baseline?.columns.contains { $0.name == "raced" } == true && editor.baseline?.columns.contains { $0.name == "added" } == false)
            editor.draft = .init(columns: [.init(name: "added", type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))])
            await editor.preparePreview(); try #require(editor.preview != nil)
            await editor.apply(); try #require(editor.outcome?.state == "applied")
            try await waitFor { graph.metadata[child]?.columns.contains { $0.name == "added" } == true && !graph.sourceState(profile.id).loading }
            #expect(graph.stored.placements.first { $0.table == child }?.point == .init(x: 103, y: -57) && graph.stored.collapsed.contains(child))
            #expect(graph.metadata[otherTable] == otherFacts && workspace.services[otherProfile.id] == nil)
            await workspace.closeTableStructure()

            workspace.editLogicalRelationship(sourceProfileID: profile.id, reference: child.reference)
            let localEditor = try #require(workspace.logicalRelationshipEditor)
            localEditor.name = "C4 confirmed mapping"; localEditor.targetProfileID = profile.id
            localEditor.targetSchema = schema; localEditor.targetName = parentName
            localEditor.columns = [.init(source: "parent_id", target: "id")]
            await localEditor.validate(); try #require(localEditor.canConfirm)
            await localEditor.confirm(in: workspace.logicalRelationships); try #require(localEditor.saved)
            workspace.closeLogicalRelationshipEditor()
            let local = try #require(graph.relationships.first { $0.kind == .logical })
            try #require(local.validationNotice == nil)
            await workspace.openERStructure(document, action: .createForeignKey(local))
            let foreign = try #require(workspace.structureEditor)
            #expect(foreign.baseline != nil && foreign.preview == nil && foreign.outcome == nil && foreign.draft.keys?.first?.columns == ["parent_id"])
            foreign.draft.keys?[0].name = keyName
            try #require(foreign.canPreview)
            let reviewedDraft = foreign.draft
            let beforeApply = decisions
            let declaredName = engine == .sqlite ? "fk_0" : keyName
            await foreign.preparePreview()
            let reviewedPlan = try #require(foreign.preview)
            try #require(foreign.error == nil && reviewedPlan.destructive != true && profile.policy.environment == .unspecified)
            await foreign.apply(); try #require(foreign.outcome?.state == "applied")
            let review = try #require(foreign.outcomeReview)
            #expect(review.plan == reviewedPlan && review.draft == reviewedDraft && review.outcome.planId == reviewedPlan.id && review.outcome.steps.count == reviewedPlan.sql.count)
            #expect(reviewedPlan.sql.contains { $0.contains(keyName) })
            // The normal policy grants this exact additive FK plan without another dialog.
            #expect(decisions == beforeApply && workspace.structureOutcomeReports.contains { $0.review.id == review.id && $0.review.plan == reviewedPlan && $0.review.draft == reviewedDraft })
            try await waitFor { graph.relationships.contains { $0.kind == .declared && $0.source == child && $0.key.name == declaredName } && !graph.sourceState(profile.id).loading }
            let declared = try #require(graph.relationships.first { $0.kind == .declared && $0.source == child && $0.key.name == declaredName })
            #expect(declared.key.sameMapping(as: .init(name: declaredName, target: parent.reference, columns: [.init(source: "parent_id", target: "id", position: 1)])))
            #expect(graph.relationships.contains { $0.logicalID == local.logicalID })
            await workspace.run(sql, sql: "SELECT id,parent_id FROM \(childName)")
            #expect(sql.localError == nil && sql.runtime?.queryFailure == nil && sql.runtime?.result?.rows == [["1", "1"]])
            #expect(graph.stored.placements.first { $0.table == child }?.point == .init(x: 103, y: -57) && graph.stored.collapsed.contains(child))
            await workspace.closeTableStructure()
            if engine == .sqlite {
                let checked = ERTableID(profileID: profile.id, schema: schema, name: checkedName)
                graph.add(checked); await workspace.buildERDiagram(document, profileID: profile.id)
                try #require(graph.metadata[checked]?.relationshipState.isAvailable == true)
                let originalKeys = try #require(graph.metadata[checked]?.foreignKeys)
                #expect(originalKeys.isEmpty)
                await workspace.openERStructure(document, action: .addForeignKey(checked))
                let blocked = try #require(workspace.structureEditor)
                blocked.draft.keys = [.init(action: "add", kind: "foreign", name: blockedKeyName, columns: ["parent_id"],
                    reference: .init(schema: schema, table: parentName, create: false), referenceColumns: ["id"], onUpdate: "NO ACTION", onDelete: "NO ACTION")]
                try #require(blocked.canPreview)
                let beforeBlocked = decisions, beforeReports = workspace.structureOutcomeReports.count
                await blocked.preparePreview()
                // The retained CHECK makes this definition ineligible for bounded FK reconstruction.
                #expect(blocked.preview == nil && blocked.error?.contains("manual reconstruction") == true && blocked.outcome == nil && !blocked.canApply)
                await blocked.apply()
                #expect(blocked.outcome == nil && decisions == beforeBlocked && workspace.structureOutcomeReports.count == beforeReports)
                await workspace.buildERDiagram(document, profileID: profile.id)
                #expect(graph.metadata[checked]?.relationshipState.isAvailable == true && graph.metadata[checked]?.foreignKeys == originalKeys)
                #expect(!graph.relationships.contains { $0.kind == .declared && $0.source == checked })
                #expect(graph.relationships.contains { $0.logicalID == local.logicalID })
                await workspace.closeTableStructure()
            }
            await workspace.openERStructure(document, action: .edit(child))
            let renamer = try #require(workspace.structureEditor)
            renamer.draft = .init(columns: [], renameTable: renamedName)
            await renamer.preparePreview(); try #require(renamer.preview?.resultTarget?.table == renamedName)
            await renamer.apply(); try #require(renamer.outcome?.state == "applied")
            let renamed = ERTableID(profileID: profile.id, schema: schema, name: renamedName)
            try await waitFor { graph.metadata[renamed]?.columnState.isAvailable == true && !graph.sourceState(profile.id).loading }
            #expect(!graph.stored.tables.contains(child) && graph.stored.collapsed.contains(renamed))
            #expect(graph.stored.placements.first { $0.table == renamed }?.point == .init(x: 103, y: -57))
            await renamer.load()
            #expect(renamer.error == nil && renamer.table == renamedName)
            await workspace.closeTableStructure()
            for name in [childName, renamedName, checkedName, createdName, parentName] { await workspace.run(sql, sql: "DROP TABLE IF EXISTS \(name)") }
            await workspace.shutdown()
        } catch {
            if let setup {
                await workspace.closeTableStructure()
                for name in [childName, renamedName, checkedName, createdName, parentName] { await workspace.run(setup, sql: "DROP TABLE IF EXISTS \(name)") }
            }
            await workspace.shutdown()
            throw error
        }
    }
}

@MainActor
private final class C4MetadataTerminalGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
