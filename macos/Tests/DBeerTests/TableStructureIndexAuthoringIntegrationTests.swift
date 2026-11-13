import Foundation
import Testing
@testable import DBeer

/// Owned database fixtures, memory stores and injected decisions only.
/// No windows, modal presentation, application activation, SSH or file watchers.
@Suite(.serialized)
@MainActor
struct TableStructureIndexAuthoringIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresRichIndexesUseNormalHelperAndExactConfirmation() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlRichIndexesUseNormalHelperAndExactConfirmation() async throws { try await exercise(.mysql) }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = env["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let folder = root.appendingPathComponent("build/index-authoring-integration/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings: ConnectionSettings
        if engine == .mysql {
            settings = .init(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost", port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")), database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: env["DBEER_TEST_MYSQL_USER"] ?? "dbeer", password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: "disable", engine: .mysql)
        } else {
            let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
            settings = .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        let snapshots = ResultSnapshotStore(rootURL: folder.appendingPathComponent("snapshots"))
        let plans = PlanArtifactStore(rootURL: folder.appendingPathComponent("evidence"))
        var confirmations: [OperationConfirmation] = []
        var accept = true
        var helperStarts = 0
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
            resultSnapshots: ResultSnapshotsModel(store: snapshots), planArtifacts: PlanArtifactsModel(store: plans),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { confirmations.append($0); return accept },
            helperFactory: { helperStarts += 1; return BackendClient(executableURL: executable) })
        await workspace.start()
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let table = "e2_native_" + suffix, indexName = "e2_index_" + suffix
        let schema = engine == .postgresql ? "public" : settings.database
        var cleanupDocument: SQLDocument?
        do {
            try #require(await workspace.library.saveConnection(name: "Index authoring fixture", settings: settings))
            let profile = try #require(workspace.library.selectedConnectionId)
            let sql = workspace.newDocument(profileID: profile); cleanupDocument = sql
            await workspace.run(sql, sql: "CREATE TABLE \(table)(id INTEGER PRIMARY KEY,base INTEGER,label VARCHAR(40) NOT NULL,payload INTEGER)")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            await workspace.run(sql, sql: "INSERT INTO \(table) VALUES(1,10,'Alpha',7)")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            let node = CatalogNode(profileID: profile, name: table, kind: .object, schema: schema, objectKind: "table")
            await workspace.openTableStructure(node, create: false)
            let model = try #require(workspace.structureEditor)
            try #require(model.error == nil && model.indexAuthoringAvailable)
            let primary = try #require(model.baseline?.keys?.first { $0.kind == "primary" })
            let backing = try #require(model.baseline?.indexes?.first { $0.owner != nil })
            #expect(backing.editIntent(action: "replace", engine: engine, advancedAllowed: true) == nil)
            let definition: StructureIndexDefinition
            if engine == .postgresql {
                definition = .init(method: "btree", terms: [.init(expression: "lower(label)", descending: true, nullsFirst: false, collation: .init(schema: "pg_catalog", name: "C"), opclass: .init(schema: "pg_catalog", name: "text_pattern_ops")), .init(column: "base", descending: true)], includes: ["payload"], predicate: "base > 0", options: [.init(name: "fillfactor", value: "80")])
            } else {
                definition = .init(method: "btree", terms: [.init(column: "label", descending: true, prefixLength: 8), .init(expression: "base * 2")], visible: false, options: [.init(name: "comment", value: "Exact é")])
            }
            model.draft = .init(columns: [], indexes: [.init(action: "add", name: indexName, definition: definition)])
            await model.preparePreview()
            let addPlan = try #require(model.preview)
            try #require(model.error == nil && addPlan.destructive == true && model.canApply)
            let countBefore = confirmations.count
            accept = false
            await model.apply()
            try #require(confirmations.count == countBefore + 1 && model.outcome == nil && model.preview == addPlan)
            let cancelled = try #require(confirmations.last)
            #expect(cancelled.assessment.decision == "confirm" && cancelled.operations.first?.structure?.planId == addPlan.id && cancelled.operations.first?.structure?.digest == addPlan.digest)
            #expect(cancelled.generatedPreview == addPlan.sql.joined(separator: "\n") + "\n\n" + addPlan.risks.joined(separator: "\n"))
            let countSQL = engine == .postgresql
                ? "SELECT count(*) FROM pg_indexes WHERE schemaname='\(schema)' AND tablename='\(table)' AND indexname='\(indexName)'"
                : "SELECT count(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='\(schema)' AND TABLE_NAME='\(table)' AND INDEX_NAME='\(indexName)'"
            await workspace.run(sql, sql: countSQL)
            #expect(sql.runtime?.result?.rows == [["0"]])
            accept = true
            await model.apply()
            let addReview = try #require(model.outcomeReview)
            try #require(addReview.outcome.state == "applied" && addReview.outcome.steps.allSatisfy { $0.message == nil || $0.message == "" })
            let added = try #require(addReview.outcome.observed?.indexes?.first { StructureTarget.sameIdentifier($0.name, indexName) })
            let observed = try #require(added.definition)
            #expect(added.supported && added.owner == nil && observed.method == "btree" && observed.terms.count == 2 && observed.terms[0].descending == true)
            if engine == .postgresql { #expect(observed.includes == ["payload"] && observed.predicate != nil && observed.terms[0].expression?.contains("lower") == true) }
            else {
                #expect(observed.terms[0].prefixLength == 8 && observed.options?.first?.value.utf8.elementsEqual("Exact é".utf8) == true)
                #expect(observed.terms[1].expression?.contains("base") == true && observed.terms[1].expression?.contains("*") == true && observed.visible == false)
            }
            #expect(addReview.draft.indexes?.first?.definition == definition)
            let startsBeforeEvidence = helperStarts
            let evidence = try SavedEvidenceArtifact.capture(model, title: "Advanced index outcome")
            let saved = try #require(await workspace.savedEvidence.save(evidence))
            let offline = try await plans.loadEvidence(saved.id)
            #expect(helperStarts == startsBeforeEvidence && offline.version == 2 && offline.structure?.draft == addReview.draft)
            #expect(offline.structure?.observed?.indexes?.first { StructureTarget.sameIdentifier($0.name, indexName) }?.definition == observed)
            #expect(offline.structure?.displayReview.plan.baselineId == "offline-evidence")
            let text = try offline.encoded()
            #expect(throws: (any Error).self) { try SavedEvidenceArtifact.decode(text.replacingOccurrences(of: "\"version\" : 2", with: "\"version\" : 1")) }
            await model.load()
            try #require(model.error == nil && model.historyReviews.last?.outcome.executionId == addReview.outcome.executionId)
            let current = try #require(model.baseline?.indexes?.first { StructureTarget.sameIdentifier($0.name, indexName) })
            var replace = try #require(current.editIntent(action: "replace", engine: engine, advancedAllowed: model.indexAuthoringAvailable))
            replace.definition?.options = [.init(name: engine == .postgresql ? "fillfactor" : "comment", value: engine == .postgresql ? "70" : "Replaced é")]
            replace.definition?.terms[0].descending = false
            if engine == .mysql { replace.definition?.visible = true }
            model.draft = .init(columns: [], indexes: [replace], allowDestructive: true)
            await model.preparePreview()
            let replacePlan = try #require(model.preview)
            await model.apply()
            try #require(model.outcome?.state == "applied")
            #expect(confirmations.last?.operations.first?.structure?.digest == replacePlan.digest)
            let changed = try #require(model.outcome?.observed?.indexes?.first { StructureTarget.sameIdentifier($0.name, indexName) })
            #expect(changed.definition?.terms[0].descending == false && changed.definition?.options?.first?.value == (engine == .postgresql ? "70" : "Replaced é"))
            if engine == .mysql { #expect(changed.definition?.visible == true && changed.definition?.terms[1].expression != nil) }
            await model.load()
            let drop = try #require(changed.editIntent(action: "drop", engine: engine, advancedAllowed: model.indexAuthoringAvailable))
            model.draft = .init(columns: [], indexes: [drop], allowDestructive: true)
            await model.preparePreview()
            await model.apply()
            try #require(model.outcome?.state == "applied")
            #expect(model.outcome?.observed?.indexes?.contains { StructureTarget.sameIdentifier($0.name, indexName) } == false)
            #expect(model.outcome?.observed?.keys?.contains(primary) == true && model.outcome?.observed?.indexes?.contains(backing) == true)
            #expect(model.historyReviews.contains { $0.outcome.executionId == addReview.outcome.executionId && $0.draft.indexes?.first?.definition == definition })
            await workspace.run(sql, sql: "SELECT id,base,label,payload FROM \(table)")
            #expect(sql.runtime?.result?.rows == [["1", "10", "Alpha", "7"]])
            await workspace.closeTableStructure()
            await workspace.run(sql, sql: "DROP TABLE \(table)")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
        } catch {
            await workspace.closeTableStructure()
            if let sql = cleanupDocument { await workspace.run(sql, sql: "DROP TABLE IF EXISTS \(table)") }
            await workspace.shutdown()
            throw error
        }
        await workspace.shutdown()
    }
}
