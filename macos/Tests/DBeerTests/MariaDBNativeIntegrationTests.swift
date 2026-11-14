import Foundation
import Testing
@testable import DBeer

/// Normal helper with owned tables and the fully private R8 dependency graph.
/// No application windows, activation, presenters, file watchers or SSH.
@Suite(.serialized) @MainActor struct MariaDBNativeIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MARIADB_PORT"] ?? "").isEmpty || ProcessInfo.processInfo.environment["DBEER_REQUIRE_MARIADB"] == "1"))
    func normalHelperExplainExecutesOnceAndMonitorKeepsSeparateOwner() async throws {
        try await exercise(explainWorkflow: true)
    }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MARIADB_PORT"] ?? "").isEmpty || ProcessInfo.processInfo.environment["DBEER_REQUIRE_MARIADB"] == "1"))
    func normalHelperOptimizerTrialRequiresReviewAndRestoresNativeState() async throws {
        try await exercise(tuningWorkflow: true)
    }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MARIADB_PORT"] ?? "").isEmpty || ProcessInfo.processInfo.environment["DBEER_REQUIRE_MARIADB"] == "1"))
    func normalHelperRowsImportPreserveExactValuesAndReviewedAuthority() async throws {
        try await exercise(rowWorkflow: true)
    }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MARIADB_PORT"] ?? "").isEmpty || ProcessInfo.processInfo.environment["DBEER_REQUIRE_MARIADB"] == "1"))
    func normalHelperTransferRetainsRowsAndOneUseAuthority() async throws {
        try await exercise(transferWorkflow: true)
    }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MARIADB_PORT"] ?? "").isEmpty || ProcessInfo.processInfo.environment["DBEER_REQUIRE_MARIADB"] == "1"))
    func normalHelperBasicStructureCreatesAppendsDefaultsAndIndexes() async throws {
        try await exercise(basicStructureWorkflow: true)
    }
    private func exercise(explainWorkflow: Bool = false, tuningWorkflow: Bool = false, rowWorkflow: Bool = false, transferWorkflow: Bool = false, basicStructureWorkflow: Bool = false) async throws {
        let env = ProcessInfo.processInfo.environment
        let port = try #require(Int(env["DBEER_TEST_MARIADB_PORT"] ?? ""))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = env["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let folder = root.appendingPathComponent("build/mariadb-native/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let defaultsName = "DBeer.MariaDBIntegration." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName); try? FileManager.default.removeItem(at: folder) }
        let requiredTLS = env["DBEER_REQUIRE_MARIADB_TLS"] == "1"
        let globalMetadata = !explainWorkflow && !rowWorkflow && !transferWorkflow
        if globalMetadata {
            try #require(env["DBEER_TEST_MARIADB_ADMIN_USER"]?.isEmpty == false)
            try #require(env["DBEER_TEST_MARIADB_ADMIN_PASSWORD"]?.isEmpty == false)
        }
        if requiredTLS { try #require(env["DBEER_TEST_MARIADB_CA_FILE"]?.isEmpty == false) }
        let settings = ConnectionSettings(host: env["DBEER_TEST_MARIADB_HOST"] ?? "localhost", port: port,
            database: env["DBEER_TEST_MARIADB_DATABASE"] ?? "dbeer", user: globalMetadata ? (env["DBEER_TEST_MARIADB_ADMIN_USER"] ?? "") : (env["DBEER_TEST_MARIADB_USER"] ?? "dbeer"),
            password: globalMetadata ? (env["DBEER_TEST_MARIADB_ADMIN_PASSWORD"] ?? "") : (env["DBEER_TEST_MARIADB_PASSWORD"] ?? ""), sslMode: requiredTLS ? "verify-full" : (env["DBEER_TEST_MARIADB_SSLMODE"] ?? "disable"),
            sslRootCert: env["DBEER_TEST_MARIADB_CA_FILE"], engine: .mariadb, policy: .init(environment: .production))
        let snapshots = ResultSnapshotStore(rootURL: folder.appendingPathComponent("snapshots"))
        let plans = PlanArtifactStore(rootURL: folder.appendingPathComponent("evidence"))
        let themes = EditorThemeStore(defaults: defaults, directory: folder.appendingPathComponent("themes"))
        var confirmations: [OperationConfirmation] = []
        var accept = true
        let client = BackendClient(executableURL: executable)
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
            commandShortcuts: AppShortcutStore(defaults: defaults), copySettings: ResultCopySettings(defaults: defaults), editorThemes: themes,
            appearance: AppAppearance(defaults: defaults, editorThemes: themes), sqlFolders: SQLFolderLibrary(automaticallyRefresh: false), sqlLibrary: SQLLibrary(),
            tableBrowsePresets: TableBrowsePresetStore(fileURL: folder.appendingPathComponent("presets.json")),
            tableImportMappingPresets: TransferMappingPresetStore(url: folder.appendingPathComponent("import-mappings.json")),
            logicalRelationships: LogicalRelationshipStore(fileURL: folder.appendingPathComponent("relationships.json")),
            resultSnapshots: ResultSnapshotsModel(store: snapshots), planArtifacts: PlanArtifactsModel(store: plans),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { confirmations.append($0); return accept },
            queryParameterDecision: { _, _ in nil }, explainOptionsDecision: { _ in .use(nil) }, helperFactory: { client },
            explainCollectorFactory: { id in ExplainCollector(store: PlanArtifactStore(rootURL: folder.appendingPathComponent("collector-" + id.uuidString))) })
        await workspace.start()
        let table = "g1_native_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var document: SQLDocument?
        do {
            try #require(await workspace.library.saveConnection(name: "MariaDB native fixture", settings: settings))
            let profile = try #require(workspace.library.selectedConnectionId)
            let sql = workspace.newDocument(profileID: profile); document = sql
            let other = workspace.newDocument(profileID: profile)
            let rowColumns = rowWorkflow ? ",f FLOAT,d DOUBLE,t TIMESTAMP(6) NULL,e ENUM('','a'),s SET('','a'),g BIGINT AS(id*2) PERSISTENT" : ""
            await workspace.run(sql, sql: "CREATE TABLE \(table)(id BIGINT PRIMARY KEY,payload VARCHAR(40),n DECIMAL(65,38),b LONGBLOB,j JSON,calls INTEGER NOT NULL DEFAULT 0\(rowColumns)) ENGINE=InnoDB")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            let exactJSON = "{ \"a\":1, \"a\":2 }"
            let decimal = "123456789012345678901234567.12345678901234567890123456789012345678"
            await workspace.run(sql, sql: "INSERT INTO \(table)(id,payload,n,b,j) VALUES(1,'',\(decimal),X'00FF','\(exactJSON)'),(11,'NULL',NULL,NULL,NULL),(12,NULL,NULL,X'',NULL)")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            await workspace.run(sql, sql: "SELECT id,payload,n,HEX(b),j FROM \(table) ORDER BY id")
            let originalRows = try #require(sql.runtime?.result?.rows)
            #expect(originalRows == [["1", "", decimal, "00FF", exactJSON], ["11", "NULL", nil, nil, nil], ["12", nil, nil, "", nil]])
            let columns = try #require(sql.runtime?.result?.columns)
            #expect(columns.allSatisfy { $0.engine == .mariadb })
            await workspace.run(sql, sql: "START TRANSACTION")
            await workspace.run(sql, sql: "INSERT INTO \(table)(id) VALUES(2)")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
            await workspace.run(other, sql: "SELECT COUNT(*) FROM \(table) WHERE id=2")
            #expect(other.runtime?.result?.rows == [["0"]])
            await workspace.run(sql, sql: "ROLLBACK")
            if rowWorkflow {
                await workspace.run(sql, sql: "UPDATE \(table) SET f=1.25,d=1.0000000000000002,t='2024-10-27 00:30:00.123456',e=1,s=1 WHERE id=1")
                try #require(sql.runtime?.queryFailure == nil)
                try await rowsAndImport(workspace, target: sql, other: other, profile: profile, schema: settings.database,
                    table: table, folder: folder, decimal: decimal, json: exactJSON,
                    setAcceptance: { accept = $0 }, confirmations: { confirmations })
            } else if basicStructureWorkflow {
                try await basicStructure(workspace, target: sql, profile: profile, schema: settings.database,
                    table: table + "_basic", setAcceptance: { accept = $0 }, confirmationCount: { confirmations.count })
            } else if transferWorkflow {
                try await transfer(workspace, target: sql, other: other, profile: profile, settings: settings,
                    table: table, folder: folder, executable: executable, expected: originalRows)
            } else if tuningWorkflow {
                try await tune(workspace, target: sql, profile: profile, schema: settings.database, table: table,
                    setAcceptance: { accept = $0 }, confirmationCount: { confirmations.count })
            } else if explainWorkflow {
                try await explain(workspace, target: sql, other: other, profile: profile, table: table)
                var monitorSettings = settings
                monitorSettings.sessionPurpose = "monitor"
                let connected = try await client.request(.connect(monitorSettings))
                let monitor = try #require(connected.sessionId)
                #expect(monitor != sql.runtime?.sessionId && connected.engine == .mariadb)
                let snapshot = try await client.request(.monitorSnapshot(sessionId: monitor))
                #expect(snapshot.monitor?.engine == .mariadb)
                _ = try await client.request(.disconnect(sessionId: monitor))
            }
            await workspace.run(sql, sql: "DROP TABLE \(table)")
            try #require(sql.runtime?.queryFailure == nil && sql.localError == nil)
        } catch {
            await workspace.closeTableStructure()
            await workspace.closeTableImport()
            if let document { await workspace.run(document, sql: "ROLLBACK"); await workspace.run(document, sql: "DROP TABLE IF EXISTS \(table)") }
            await workspace.shutdown()
            throw error
        }
        await workspace.shutdown()
    }

    private func basicStructure(_ workspace: ApplicationWorkspace, target: SQLDocument, profile: UUID,
                                schema: String, table: String, setAcceptance: (Bool) -> Void,
                                confirmationCount: () -> Int) async throws {
        await workspace.openTableStructure(CatalogNode(profileID: profile, name: schema, kind: .schema, schema: schema), create: true)
        let model = try #require(workspace.structureEditor)
        model.table = table
        do {
            func apply(_ draft: StructureDraft, stage: String, declineFirst: Bool = false) async throws {
                await model.load()
                try #require(model.error == nil && model.baseline?.engine == "mariadb")
                model.draft = draft
                await model.preparePreview()
                let plan = try #require(model.preview)
                try #require(model.error == nil && model.canApply)
                let count = confirmationCount()
                if declineFirst {
                    setAcceptance(false)
                    await model.apply()
                    #expect(model.preview == plan && model.outcome == nil && confirmationCount() == count + 1)
                    await workspace.run(target, sql: "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='\(table)'")
                    #expect(target.runtime?.result?.rows == [["0"]])
                }
                setAcceptance(true)
                await model.apply()
                let outcome = try #require(model.outcomeReview?.outcome)
                try #require(outcome.state == "applied" && !model.canApply && outcome.steps.allSatisfy { $0.state == "applied" && ($0.message == nil || $0.message == "") },
                    "\(stage): outcome=\(outcome.state), steps=\(outcome.steps.map(\.state)), stepMessages=\(outcome.steps.map { $0.message?.isEmpty == false }), canApply=\(model.canApply), modelError=\(model.error != nil), refreshError=\(outcome.refreshError?.isEmpty == false), observed=\(outcome.observed != nil)")
                #expect(confirmationCount() == count + (declineFirst ? 2 : 1))
            }
            try await apply(.init(columns: [
                .init(name: "id", type: .init(kind: "bigint"), nullable: false, default: .init(kind: "none")),
                .init(name: "payload", type: .init(kind: "varchar", length: 40), nullable: true, default: .init(kind: "none"))
            ]), stage: "create table", declineFirst: true)
            await workspace.run(target, sql: "INSERT INTO \(table)(id,payload) VALUES(1,'kept')")
            try #require(target.runtime?.queryFailure == nil)
            try await apply(.init(columns: [.init(name: "extra", type: .init(kind: "bigint"), nullable: true, default: .init(kind: "none"))]), stage: "append column")
            try await apply(.init(columns: [], changes: [.init(name: "payload", default: .init(kind: "text", value: "NULL"))]), stage: "set literal text default")
            try await apply(.init(columns: [], indexes: [.init(action: "add", name: "native_payload_idx", columns: ["payload"], unique: false)]), stage: "add nonunique index")
            let indexes = model.outcomeReview?.outcome.observed?.indexes ?? []
            #expect(indexes.contains(where: { $0.name == "native_payload_idx" && $0.columns == ["payload"] }))
            await workspace.run(target, sql: "INSERT INTO \(table)(id) VALUES(2)")
            try #require(target.runtime?.queryFailure == nil)
            await workspace.run(target, sql: "SELECT id,payload,extra FROM \(table) ORDER BY id")
            #expect(target.runtime?.result?.rows == [["1", "kept", nil], ["2", "NULL", nil]])
            await workspace.closeTableStructure()
            await workspace.run(target, sql: "DROP TABLE \(table)")
            try #require(target.runtime?.queryFailure == nil)
        } catch {
            await workspace.closeTableStructure()
            await workspace.run(target, sql: "DROP TABLE IF EXISTS \(table)")
            throw error
        }
    }

    private func transfer(_ workspace: ApplicationWorkspace, target: SQLDocument, other: SQLDocument, profile: UUID,
                          settings: ConnectionSettings, table: String, folder: URL, executable: URL, expected: [[String?]]) async throws {
        let destination = table + "_copy"
        let saved = SavedConnection(id: profile, name: "Private transfer fixture", settings: settings)
        var accept = false, reviews = 0, changed = 0
        let model = DataTransferModel(profiles: [saved], resolve: { _, _ in settings }, current: { $0.id == profile },
            authorize: { _, review in
                reviews += 1
                return accept && review.state == "ready" && review.planDigest?.isEmpty == false
            }, factory: { DataTransferHelperBackend(executableURL: executable, scratchParentURL: folder) },
            presets: TransferMappingPresetStore(url: folder.appendingPathComponent("transfer-mappings.json")), changed: { _ in changed += 1 })
        model.mode = "table"; model.sourceID = profile; model.targetID = profile
        model.sourceSchema = settings.database; model.sourceTable = table
        model.targetSchema = settings.database; model.targetTable = destination
        do {
            await workspace.run(target, sql: "START TRANSACTION")
            await workspace.run(target, sql: "INSERT INTO \(table)(id) VALUES(2)")
            try #require(target.runtime?.queryFailure == nil && target.runtime?.transactionStatus == .transaction)
            await model.describe()
            try #require(model.error == nil && model.reply?.state == "described" && model.columns.contains(where: { $0.type == "decimal" && $0.scale == 38 }))
            await model.preview()
            let reviewed = try #require(model.reply)
            try #require(model.error == nil && model.canApply && reviewed.state == "ready" && reviewed.rowsRead == 3)
            await model.apply()
            #expect(reviews == 1 && model.reply?.planDigest == reviewed.planDigest && model.canApply && changed == 0)
            await workspace.run(other, sql: "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='\(destination)'")
            #expect(other.runtime?.result?.rows == [["0"]])
            await workspace.run(target, sql: "UPDATE \(table) SET payload='changed after review' WHERE id=1")
            try #require(target.runtime?.queryFailure == nil)
            accept = true
            await model.apply()
            let completed = try #require(model.reply)
            try #require(model.error == nil && completed.state == "completed" && completed.rowsWritten == 3 && completed.tableCreated && !completed.outcomeUnknown)
            #expect(reviews == 2 && changed == 1 && !model.canApply && target.runtime?.transactionStatus == .transaction)
            await workspace.run(other, sql: "SELECT id,payload,n,HEX(b),j FROM \(destination) ORDER BY id")
            #expect(other.runtime?.result?.rows == expected)
            await model.apply()
            #expect(reviews == 2 && model.reply == completed)
            await workspace.run(target, sql: "ROLLBACK")
            await model.close()
            await workspace.run(other, sql: "DROP TABLE \(destination)")
            try #require(other.runtime?.queryFailure == nil)
        } catch {
            await model.close()
            await workspace.run(target, sql: "ROLLBACK")
            await workspace.run(other, sql: "DROP TABLE IF EXISTS \(destination)")
            throw error
        }
    }

    private func rowsAndImport(_ workspace: ApplicationWorkspace, target: SQLDocument, other: SQLDocument, profile: UUID,
                               schema: String, table: String, folder: URL, decimal: String, json: String,
                               setAcceptance: (Bool) -> Void, confirmations: () -> [OperationConfirmation]) async throws {
        let node = CatalogNode(profileID: profile, name: table, kind: .object, schema: schema, object: table, objectKind: "table")
        await workspace.connectProfile(profile)
        let service = try #require(workspace.services[profile])
        try #require(service.connectionState == .connected)
        let catalogOwner = try #require(service.sessionId)
        let opened = await workspace.openData(node, inNewTab: true)
        let document = try #require(opened)
        document.tableSort = [.init(column: "id", direction: "asc")]
        await workspace.run(document)
        let grid = try #require(document.grid)
        let idColumn = try #require(grid.columns.firstIndex { $0.name == "id" })
        let payloadColumn = try #require(grid.columns.firstIndex { $0.name == "payload" })
        let generatedColumn = try #require(grid.columns.firstIndex { $0.name == "g" })
        let row = try #require(grid.rows.firstIndex { $0.values[idColumn].value == "1" })
        #expect(grid.rows.map { $0.values[idColumn].value } == ["1", "11", "12"])
        try #require(grid.canEditRow(row) && grid.nativeValues != nil)
        try #require(grid.rows[row].originalStorageToken?.hasPrefix("mariadb.storage.v1:") == true)
        let generated = grid.rows[row].values[generatedColumn]
        grid.set(.init(kind: "text", value: "unrequested"), row: row, column: generatedColumn)
        #expect(grid.pendingCount == 0 && grid.rows[row].values[generatedColumn] == generated)
        grid.set(.init(kind: "text", value: "edited"), row: row, column: payloadColumn)
        let reviewed = grid.request()
        #expect(reviewed.columns.allSatisfy { $0.engine == .mariadb } && reviewed.changes.first?.storageToken == grid.rows[row].originalStorageToken)
        await workspace.previewGrid(document)
        try #require(grid.error == nil && grid.preview != nil && grid.pendingCount == 1)
        let count = confirmations().count
        setAcceptance(false)
        let cancelled = await workspace.applyGrid(document)
        #expect(!cancelled && grid.pendingCount == 1 && confirmations().count == count + 1 && !grid.outcomeUnknown)
        #expect(confirmations().last?.operations.first?.changes == reviewed)
        await workspace.run(other, sql: "SELECT payload FROM \(table) WHERE id=1")
        #expect(other.runtime?.result?.rows == [[""]])
        setAcceptance(true)
        let applied = await workspace.applyGrid(document)
        try #require(applied)
        #expect(confirmations().count == count + 2)
        await workspace.run(target, sql: "SELECT payload,n,HEX(b),j,g FROM \(table) WHERE id=1")
        #expect(target.runtime?.result?.rows == [["edited", decimal, "00FF", json, "2"]])
        let fresh = try #require(document.grid)
        let freshRow = try #require(fresh.rows.firstIndex { $0.values[idColumn].value == "1" })
        let lateRow = try #require(fresh.rows.firstIndex { $0.values[idColumn].value == "11" })
        fresh.set(.init(kind: "text", value: "local"), row: freshRow, column: payloadColumn)
        fresh.set(.init(kind: "text", value: "local2"), row: lateRow, column: payloadColumn)
        await workspace.run(other, sql: "UPDATE \(table) SET payload='late' WHERE id=11")
        await workspace.previewGrid(document)
        try #require(fresh.error == nil && fresh.preview != nil)
        let conflicted = await workspace.applyGrid(document)
        #expect(!conflicted && fresh.pendingCount == 2 && fresh.error != nil && !fresh.outcomeUnknown)
        await workspace.run(target, sql: "SELECT id,payload FROM \(table) WHERE id IN (1,11) ORDER BY id")
        #expect(target.runtime?.result?.rows == [["1", "edited"], ["11", "late"]])
        await workspace.discardGrid(document)
        let exact = try #require(document.grid)
        let nullRow = try #require(exact.rows.firstIndex { $0.values[idColumn].value == "11" })
        let emptyRow = try #require(exact.rows.firstIndex { $0.values[idColumn].value == "12" })
        let binaryColumn = try #require(exact.columns.firstIndex { $0.name == "b" })
        let jsonColumn = try #require(exact.columns.firstIndex { $0.name == "j" })
        exact.set(.null, row: nullRow, column: payloadColumn)
        exact.set(.init(kind: "binary", value: ""), row: nullRow, column: binaryColumn)
        exact.set(.init(kind: "text", value: json), row: nullRow, column: jsonColumn)
        exact.set(.init(kind: "text", value: ""), row: emptyRow, column: payloadColumn)
        exact.set(.init(kind: "binary", value: "AP8="), row: emptyRow, column: binaryColumn)
        await workspace.previewGrid(document)
        try #require(exact.error == nil && exact.preview != nil)
        let exactApplied = await workspace.applyGrid(document)
        try #require(exactApplied)
        await workspace.run(target, sql: "SELECT id,payload,HEX(b),j FROM \(table) WHERE id IN (11,12) ORDER BY id")
        #expect(target.runtime?.result?.rows == [["11", nil, "", json], ["12", "", "00FF", nil]])
        try #require(workspace.canImportTableData(node))
        await workspace.openTableImport(node)
        let importer = try #require(workspace.tableImporter)
        try #require(importer.error == nil && importer.columns.contains { $0.name == "g" && $0.generated })
        let input = folder.appendingPathComponent("rows.csv")
        try Data("id,payload,n\n21,\"NULL\",0.12345678901234567890123456789012345678\n22,\"\",0.45678901234567890123456789012345678901\n".utf8).write(to: input)
        await importer.loadFile(url: input)
        try #require(importer.canPreview)
        await importer.preparePreview()
        try #require(importer.preview?.rowCount == 2 && importer.canApply && importer.error == nil)
        try Data("id,payload,n\n99,changed,1\n".utf8).write(to: input)
        let sqlOwner = try #require(target.runtime?.sessionId)
        await workspace.run(target, sql: "START TRANSACTION")
        await workspace.run(target, sql: "INSERT INTO \(table)(id) VALUES(2)")
        try #require(target.runtime?.transactionStatus == .transaction && target.runtime?.queryFailure == nil)
        let importCount = confirmations().count
        setAcceptance(false)
        await importer.apply()
        #expect(importer.appliedRowCount == nil && importer.canApply && confirmations().count == importCount + 1)
        setAcceptance(true)
        await importer.apply()
        try #require(importer.appliedRowCount == 2 && importer.error == nil && !importer.canApply)
        #expect(target.runtime?.sessionId == sqlOwner && target.runtime?.transactionStatus == .transaction)
        let completedConfirmations = confirmations().count
        await importer.apply()
        #expect(confirmations().count == completedConfirmations)
        await workspace.run(other, sql: "SELECT id,payload,n,g,calls FROM \(table) WHERE id IN (2,21,22,99) ORDER BY id")
        #expect(other.runtime?.result?.rows == [["21", "NULL", "0.12345678901234567890123456789012345678", "42", "0"], ["22", "", "0.45678901234567890123456789012345678901", "44", "0"]])
        await workspace.run(target, sql: "ROLLBACK")
        await workspace.closeTableImport()
        #expect(workspace.tableImporter == nil)
        #expect(workspace.services[profile] === service && service.sessionId == catalogOwner && service.connectionState == .connected)
        await workspace.run(target, sql: "SELECT COUNT(*) FROM \(table) WHERE id=2")
        #expect(target.runtime?.result?.rows == [["0"]])
    }
    private func explain(_ workspace: ApplicationWorkspace, target: SQLDocument, other: SQLDocument, profile: UUID, table: String) async throws {
        let source = workspace.newDocument(profileID: profile, text: "")
        let session = try #require(target.runtime?.sessionId)
        let support = try #require(target.runtime?.explainSupport)
        try #require(support.engine == .mariadb && support.format == "json" && support.options == nil && support.dml?.analyzeTargetExecution == "executes")
        func run(_ sql: String, mode: ExplainMode) async throws -> ExplainPlanModel {
            source.text = sql
            workspace.beginExplainSelection(source, mode: mode, selections: [NSRange(location: 0, length: sql.utf16.count)])
            let selected = try #require(workspace.explainSelection)
            workspace.explainSelection = nil
            await workspace.runExplainSelection(selected, selected: Set(selected.statements.filter(\.selectedByDefault).map(\.id)), targetID: target.id.uuidString, planKind: nil)
            let plan = try #require(source.explainPlan)
            try #require(source.localError == nil && plan.failure == nil && plan.result?.valid == true)
            #expect(source.runtime == nil && plan.sessionID == session && plan.targetDocumentID == target.id)
            #expect(plan.request.options == nil && plan.result?.support.engine == .mariadb)
            return plan
        }
        let estimated = try await run("UPDATE \(table) SET payload='analyzed',calls=calls+1 WHERE id=1", mode: .plan)
        #expect(estimated.dmlOutcome?.execution == "estimated" && estimated.dmlOutcome?.targetExecution == "notExecuted")
        await workspace.run(target, sql: "SELECT payload FROM \(table) WHERE id=1")
        #expect(target.runtime?.result?.rows == [[""]])
        let analyzed = try await run("UPDATE \(table) SET payload='analyzed',calls=calls+1 WHERE id=1", mode: .analyze)
        #expect(analyzed.dmlOutcome?.execution == "completed" && analyzed.dmlOutcome?.targetExecution == "executed" && analyzed.dmlOutcome?.persistence == "committed")
        #expect(analyzed.request.writeIntent?.expectedTransactionStatus == "idle")
        await workspace.run(target, sql: "SELECT payload FROM \(table) WHERE id=1")
        #expect(target.runtime?.result?.rows == [["analyzed"]])
        await workspace.run(target, sql: "SELECT calls FROM \(table) WHERE id=1")
        #expect(target.runtime?.result?.rows == [["1"]])
        await workspace.run(target, sql: "START TRANSACTION")
        let pending = try await run("UPDATE \(table) SET payload='pending',calls=calls+1 WHERE id=1", mode: .analyze)
        #expect(pending.dmlOutcome?.persistence == "transactionPending" && target.runtime?.transactionStatus == .transaction)
        await workspace.run(other, sql: "SELECT payload FROM \(table) WHERE id=1")
        #expect(other.runtime?.result?.rows == [["analyzed"]])
        await workspace.run(target, sql: "ROLLBACK")
        await workspace.run(target, sql: "SELECT payload FROM \(table) WHERE id=1")
        #expect(target.runtime?.result?.rows == [["analyzed"]])
        await workspace.run(target, sql: "SELECT calls FROM \(table) WHERE id=1")
        #expect(target.runtime?.result?.rows == [["1"]])
        let plan = try await run("SELECT id,payload FROM \(table) WHERE id=1", mode: .analyze)
        let result = try #require(plan.result)
        #expect(result.format == "json" && !result.raw.isEmpty && !result.nodes.isEmpty)
        #expect(result.nodes.compactMap { $0.metrics["totalTime"] }.allSatisfy { $0.unit == "ms" && $0.basis == "inclusiveTotal" })
    }

    private func tune(_ workspace: ApplicationWorkspace, target: SQLDocument, profile: UUID, schema: String, table: String,
                      setAcceptance: (Bool) -> Void, confirmationCount: () -> Int) async throws {
        await workspace.run(target, sql: "SELECT @@SESSION.optimizer_switch")
        let beforeRows = try #require(target.runtime?.result?.rows)
        let before = try #require(beforeRows.first?.first ?? nil)
        try #require((schema + table).utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 })
        let qualified = schema + "." + table
        let text = "SELECT id,calls FROM \(qualified) WHERE calls=0"
        let source = workspace.newDocument(profileID: profile, text: text)
        workspace.beginExplainSelection(source, mode: .plan, selections: [NSRange(location: 0, length: text.utf16.count)])
        let selected = try #require(workspace.explainSelection)
        workspace.explainSelection = nil
        await workspace.runExplainSelection(selected, selected: Set(selected.statements.filter(\.selectedByDefault).map(\.id)), targetID: target.id.uuidString, planKind: nil)
        let plan = try #require(source.explainPlan)
        try #require(plan.result?.valid == true && plan.failure == nil)
        let model = try #require(workspace.makeTuningPanel(source, plan: plan))
        await model.inspect(schema: schema, table: table)
        let observed = try #require(model.inspection?.mariaDBOptimizer)
        #expect(observed.valid && observed.nativeSwitch.utf8.elementsEqual(before.utf8))
        let count = confirmationCount()
        setAcceptance(false)
        await model.validateOptimizer()
        #expect(confirmationCount() == count + 1 && model.validation == nil)
        setAcceptance(true)
        await model.inspect(schema: schema, table: table)
        await model.validateOptimizer()
        let result = try #require(model.validation)
        #expect(result.complete && result.state == "observedEqual" && result.originalRows == 3 && result.variantRows == 3)
        #expect(confirmationCount() == count + 2 && target.runtime?.transactionStatus == .idle)
        await workspace.run(target, sql: "SELECT @@SESSION.optimizer_switch")
        let afterRows = try #require(target.runtime?.result?.rows)
        let after = try #require(afterRows.first?.first ?? nil)
        #expect(after.utf8.elementsEqual(before.utf8))
        await workspace.run(target, sql: "SELECT SUM(calls) FROM \(qualified)")
        #expect(target.runtime?.result?.rows == [["0"]])
        await model.close()
    }

}
