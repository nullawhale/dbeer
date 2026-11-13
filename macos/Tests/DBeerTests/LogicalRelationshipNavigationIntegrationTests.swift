import Foundation
import Testing
@testable import DBeer

/// Uses normal workspace/editor/navigation paths, disposable databases and
/// injected decisions only. No windows, application activation or UI automation.
@Suite(.serialized)
@MainActor
struct LogicalRelationshipNavigationIntegrationTests {
    @Test func sqliteConfirmedCompositeCrossProfileNavigationRestoresDisconnected() async throws { try await exercise(.sqlite) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresConfirmedCompositeCrossProfileNavigation() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlConfirmedCompositeCrossProfileNavigation() async throws { try await exercise(.mysql) }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresExternalTypeChangeRejectsOldNumericCaptureBeforeOpeningTarget() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = try #require(URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""))
        let settings = ConnectionSettings(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()),
            user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        let executable = environment["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-stale-logical-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            logicalRelationships: LogicalRelationshipStore(fileURL: directory.appendingPathComponent("links/library.json")),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in true },
            helperFactory: { BackendClient(executableURL: executable) })
        let outside = BackendClient(executableURL: executable)
        await workspace.start(); try await outside.start()
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let sourceName = "stale_logical_source_" + suffix, targetName = "stale_logical_target_" + suffix
        var outsideSession: String?
        func approvedOutside(_ statement: String, session: String) async throws -> BackendMessage {
            let operation = OperationRequest(type: "execute", sql: statement)
            let assessed = try await outside.request(.assess(sessionId: session, operations: [operation]))
            let review = try #require(assessed.assessment)
            try #require(["allow", "confirm"].contains(review.decision))
            var command = BackendCommand.execute(sessionId: session, sql: statement)
            command.authorization = try #require(review.authorization)
            return try await outside.request(command)
        }
        do {
            outsideSession = try #require(try await outside.request(.connect(settings)).sessionId)
            let session = try #require(outsideSession)
            _ = try await approvedOutside("CREATE TABLE \(sourceName)(id integer primary key,amount numeric)", session: session)
            _ = try await approvedOutside("CREATE TABLE \(targetName)(id integer primary key,amount numeric)", session: session)
            _ = try await approvedOutside("INSERT INTO \(sourceName) VALUES(1,0.1)", session: session)
            _ = try await approvedOutside("INSERT INTO \(targetName) VALUES(1,0.1),(2,0.100000001490116119384765625)", session: session)
            try #require(await workspace.library.saveConnection(name: "Stale capture", settings: settings))
            let profile = try #require(workspace.library.selectedConnectionId)
            let table = try #require(await workspace.openData(.init(profileID: profile, name: sourceName, kind: .object, schema: "public", object: sourceName, objectKind: "table")))
            let grid = try #require(table.grid), row = try #require(grid.rows.first)
            try #require(grid.columns[1].typeOid == 1700 && grid.metadata[1]["nativeType"] == "numeric" && row.original?[1].value == "0.1")
            // This separate physical client does not notify the workspace or
            // replace its old grid. Revalidation must not relabel old bytes.
            _ = try await approvedOutside("ALTER TABLE \(sourceName) ALTER COLUMN amount TYPE real USING amount::real", session: session)
            workspace.editLogicalRelationship(sourceProfileID: profile, reference: table.table)
            let editor = try #require(workspace.logicalRelationshipEditor)
            editor.name = "Fresh mapping over an old grid"
            editor.targetProfileID = profile; editor.targetSchema = "public"; editor.targetName = targetName
            editor.columns = [.init(source: "amount", target: "amount")]
            await editor.validate(); try #require(editor.canConfirm)
            await editor.confirm(in: workspace.logicalRelationships); try #require(editor.saved)
            workspace.closeLogicalRelationshipEditor()
            let direction = try #require(workspace.logicalRelationshipDirections(table, grid: grid).first)
            try #require(direction.oriented.columns[0].sourceType == "real" && !grid.resultIsStale)
            let count = workspace.documents.count, sessions = workspace.services.count
            await workspace.followLogicalRelationship(direction, rowID: row.id, in: table)
            #expect(workspace.documents.count == count && workspace.services.count == sessions)
            #expect(table.logicalRelationshipRead == nil && table.grid === grid && grid.rows.first?.original == row.original)
            #expect(table.tableNavigationError?.contains("Reload the source row") == true)
            #expect(!workspace.documents.contains { $0.table?.name == targetName })
            _ = try await approvedOutside("DROP TABLE \(sourceName),\(targetName)", session: session)
            _ = await outside.shutdown(); await workspace.shutdown()
        } catch {
            if let session = outsideSession { _ = try? await approvedOutside("DROP TABLE IF EXISTS \(sourceName),\(targetName)", session: session) }
            _ = await outside.shutdown(); await workspace.shutdown(); throw error
        }
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresResolvedArrayAndBinaryDomainCapturesRetainNativeNavigation() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = try #require(URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""))
        let settings = ConnectionSettings(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()),
            user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        let executable = environment["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-custom-logical-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            logicalRelationships: LogicalRelationshipStore(fileURL: directory.appendingPathComponent("links/library.json")),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in true },
            helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let domain = "logical_bytes_" + suffix, sourceName = "custom_logical_source_" + suffix, targetName = "custom_logical_target_" + suffix
        var setup: SQLDocument?
        do {
            try #require(await workspace.library.saveConnection(name: "Resolved native captures", settings: settings))
            let profile = try #require(workspace.library.selectedConnectionId)
            let sql = workspace.newDocument(profileID: profile); setup = sql
            for statement in ["CREATE DOMAIN \(domain) AS bytea", "CREATE TABLE \(sourceName)(id integer primary key,items integer[],payload \(domain))",
                "CREATE TABLE \(targetName)(id integer primary key,items integer[],payload bytea)",
                "INSERT INTO \(sourceName) VALUES(1,ARRAY[1,2],decode('00ff','hex'))",
                "INSERT INTO \(targetName) VALUES(1,ARRAY[1,2],decode('00ff','hex')),(2,ARRAY[1,3],decode('00ff','hex')),(3,ARRAY[1,2],decode('00fe','hex'))"] {
                await workspace.run(sql, sql: statement)
                try #require(sql.localError == nil && sql.runtime?.queryFailure == nil)
            }
            let table = try #require(await workspace.openData(.init(profileID: profile, name: sourceName, kind: .object, schema: "public", object: sourceName, objectKind: "table")))
            let grid = try #require(table.grid), row = try #require(grid.rows.first)
            try #require(grid.columns[1].typeOid == 1007 && grid.columns[1].nativeType == "_int4")
            try #require(grid.metadata[1]["nativeType"] == "integer[]" && grid.metadata[2]["nativeType"]?.contains(domain) == true)
            try #require(grid.columns[1].typeIdentity?.hasPrefix("pgtype-v1:") == true && grid.columns[2].typeIdentity?.hasPrefix("pgtype-v1:") == true)
            workspace.editLogicalRelationship(sourceProfileID: profile, reference: table.table)
            let editor = try #require(workspace.logicalRelationshipEditor)
            editor.name = "Array and domain capture"
            editor.targetProfileID = profile; editor.targetSchema = "public"; editor.targetName = targetName
            editor.columns = [.init(source: "items", target: "items"), .init(source: "payload", target: "payload")]
            await editor.validate(); try #require(editor.canConfirm)
            await editor.confirm(in: workspace.logicalRelationships); try #require(editor.saved)
            workspace.closeLogicalRelationshipEditor()
            let direction = try #require(workspace.logicalRelationshipDirections(table, grid: grid).first)
            await workspace.followLogicalRelationship(direction, rowID: row.id, in: table)
            let target = try #require(workspace.documents.last { $0.table?.name == targetName }, Comment(rawValue: table.tableNavigationError ?? "Resolved native target unavailable"))
            #expect(target.grid?.rows.count == 1 && target.grid?.rows.first?.values.first?.value == "1")
            #expect(target.tableFilters[0].nativeValue?.cell == row.original?[1] && target.tableFilters[1].nativeValue?.cell == row.original?[2])
            await workspace.run(sql, sql: "DROP TABLE \(sourceName),\(targetName)")
            await workspace.run(sql, sql: "DROP DOMAIN \(domain)")
            await workspace.shutdown()
        } catch {
            if let setup {
                await workspace.run(setup, sql: "DROP TABLE IF EXISTS \(sourceName),\(targetName)")
                await workspace.run(setup, sql: "DROP DOMAIN IF EXISTS \(domain)")
            }
            await workspace.shutdown(); throw error
        }
    }

    private func exercise(_ engine: DatabaseEngine) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-logical-navigation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = ProcessInfo.processInfo.environment
        let executable = environment["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        func settings(_ filename: String) throws -> ConnectionSettings {
            if engine == .sqlite {
                let file = directory.appendingPathComponent(filename)
                _ = FileManager.default.createFile(atPath: file.path, contents: Data())
                return .init(host: "", port: 0, database: "", user: "", password: "", sslMode: "disable", engine: engine, sqlite: .init(path: file.path))
            }
            if engine == .mysql { return .init(host: environment["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
                port: try #require(Int(environment["DBEER_TEST_MYSQL_PORT"] ?? "")),
                database: environment["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: environment["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
                password: environment["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: "disable", engine: engine) }
            let url = try #require(URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""))
            return .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()),
                user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
        }
        let connectionStore = MemoryConnectionLibraryStore(), credentials = MemoryConnectionCredentialStore(), documents = MemorySQLDocumentStore()
        let linksURL = directory.appendingPathComponent("private-links/library.json")
        let workspace = ApplicationWorkspace(connectionStore: connectionStore, credentialStore: credentials, documentStore: documents,
            logicalRelationships: LogicalRelationshipStore(fileURL: linksURL), automaticallyWatchFiles: false,
            closeDecision: { _ in .discard }, executionDecision: { _ in true }, helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let sourceName = "logical_source_" + suffix, targetName = engine == .sqlite ? sourceName : "logical_target_" + suffix
        var sourceSQL: SQLDocument?, targetSQL: SQLDocument?
        do {
            try #require(await workspace.library.saveConnection(name: "Logical source", settings: try settings("source.sqlite")))
            let sourceID = try #require(workspace.library.selectedConnectionId)
            try #require(await workspace.library.saveConnection(name: "Logical target", settings: try settings("target.sqlite")))
            let targetID = try #require(workspace.library.selectedConnectionId)
            let source = workspace.newDocument(profileID: sourceID), target = workspace.newDocument(profileID: targetID)
            sourceSQL = source; targetSQL = target
            let schema = engine == .postgresql ? "public" : engine == .mysql ? (environment["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer") : "main"
            let quote = engine == .mysql ? "`" : "\""
            let nfc = quote + "é" + quote, nfd = quote + "e\u{0301}" + quote
            let numeric = engine == .sqlite ? "TEXT" : "DECIMAL(40,18)"
            let binary = engine == .postgresql ? "bytea" : engine == .mysql ? "VARBINARY(8)" : "BLOB"
            let bytes = engine == .postgresql ? "decode('00ff','hex')" : "X'00ff'"
            let otherBytes = engine == .postgresql ? "decode('00fe','hex')" : "X'00fe'"
            let exact = "9007199254740993.000000000000000001"
            for (sql, name) in [(source, sourceName), (target, targetName)] {
                await workspace.run(sql, sql: "CREATE TABLE \(name)(id INTEGER PRIMARY KEY, amount \(numeric), payload \(binary), \(nfc) TEXT, \(nfd) TEXT, label VARCHAR(80))")
                try #require(sql.localError == nil && sql.runtime?.queryFailure == nil)
                await workspace.run(sql, sql: "INSERT INTO \(name) VALUES(1,'\(exact)',\(bytes),'NFC','NFD','match'),(2,'\(exact)',\(otherBytes),'NFC','NFD','other bytes'),(3,'9007199254740992.000000000000000001',\(bytes),'NFC','NFD','other number')")
                try #require(sql.localError == nil && sql.runtime?.queryFailure == nil)
            }
            let node = CatalogNode(profileID: sourceID, name: sourceName, kind: .object, schema: schema, object: sourceName, objectKind: "table")
            let table = try #require(await workspace.openData(node, inNewTab: true))
            let grid = try #require(table.grid), row = try #require(grid.rows.first(where: { $0.values.first?.value == "1" }))
            workspace.editLogicalRelationship(sourceProfileID: sourceID, reference: table.table)
            let editor = try #require(workspace.logicalRelationshipEditor)
            editor.name = "Exact cross-profile composite"
            editor.targetProfileID = targetID; editor.targetSchema = schema; editor.targetName = targetName
            editor.columns = [.init(source: "amount", target: "amount"), .init(source: "payload", target: "payload"),
                              .init(source: "é", target: "é"), .init(source: "e\u{0301}", target: "e\u{0301}")]
            try #require(workspace.logicalRelationships.relationships.isEmpty)
            await editor.validate(); try #require(editor.canConfirm, Comment(rawValue: editor.error ?? "Editor validation unavailable"))
            await editor.confirm(in: workspace.logicalRelationships)
            try #require(editor.saved)
            workspace.closeLogicalRelationshipEditor()
            let direction = try #require(workspace.logicalRelationshipDirections(table, grid: grid).first)
            let labelIndex = try #require(grid.columns.firstIndex { $0.name == "label" })
            let sourceRowIndex = try #require(grid.rows.firstIndex { $0.id == row.id })
            grid.set(.init(kind: "text", value: "Unrelated local draft"), row: sourceRowIndex, column: labelIndex)
            let originalValues = grid.rows[sourceRowIndex].values
            let originalDocumentCount = workspace.documents.count
            await workspace.followLogicalRelationship(direction, rowID: row.id, in: table)
            let opened = try #require(workspace.documents.first { $0.table?.name == targetName && $0.profileID == targetID })
            try #require(opened !== table && workspace.documents.count == originalDocumentCount + 1,
                         Comment(rawValue: table.tableNavigationError ?? "Independent target tab unavailable"))
            #expect(opened.runtime !== table.runtime && opened.runtime?.sessionId != table.runtime?.sessionId)
            #expect(opened.tableFilters.count == 4 && opened.tableFilters.allSatisfy { $0.nativeValue != nil && $0.value == nil })
            #expect(opened.tableRelationshipScope == nil && opened.grid?.rows.count == 1 && opened.grid?.rows.first?.values.first?.value == "1")
            #expect(table.grid === grid && grid.pendingCount == 1 && grid.rows[sourceRowIndex].values == originalValues)
            #expect(opened.tableFilters[0].nativeValue?.cell == row.original?[1])
            let keyIndex = try #require(grid.columns.firstIndex { Data($0.name.utf8) == Data("e\u{0301}".utf8) })
            grid.set(.init(kind: "text", value: "Changed key"), row: sourceRowIndex, column: keyIndex)
            let afterFirst = workspace.documents.count
            await workspace.followLogicalRelationship(direction, rowID: row.id, in: table)
            #expect(workspace.documents.count == afterFirst && table.tableNavigationError?.contains("changed relationship-key") == true)
            grid.set(try #require(row.original?[keyIndex]), row: sourceRowIndex, column: keyIndex)
            await workspace.run(target, sql: "ALTER TABLE \(targetName) DROP COLUMN \(nfd)")
            try #require(target.localError == nil && target.runtime?.queryFailure == nil)
            await workspace.followLogicalRelationship(direction, rowID: row.id, in: table)
            #expect(workspace.documents.count == afterFirst && table.tableNavigationError?.contains("mapped column") == true)
            #expect(table.grid === grid && grid.pendingCount == 1)
            await workspace.flushDocuments()
            // Release source edits before shutdown so restoration tests remain
            // about persisted navigation intent rather than grid draft recovery.
            grid.set(try #require(row.original?[labelIndex]), row: sourceRowIndex, column: labelIndex)
            if engine != .sqlite {
                await workspace.run(source, sql: "DROP TABLE IF EXISTS \(sourceName)")
                await workspace.run(target, sql: "DROP TABLE IF EXISTS \(targetName)")
            }
            await workspace.shutdown()
            let restoredLinks = LogicalRelationshipStore(fileURL: linksURL)
            let restored = ApplicationWorkspace(connectionStore: connectionStore, credentialStore: credentials, documentStore: documents,
                logicalRelationships: restoredLinks, automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in true },
                helperFactory: { self.recordingHelper(executable: executable, directory: directory) })
            await restored.start()
            #expect(restoredLinks.relationships.count == 1)
            #expect(restored.documents.allSatisfy { $0.runtime?.connectionState != .connected && $0.grid == nil })
            #expect(restored.documents.contains { $0.profileID == targetID && $0.tableFilters.count == 4 && $0.tableFilters.allSatisfy { $0.nativeValue != nil } })
            await restored.shutdown()
            let commands = try String(contentsOf: directory.appendingPathComponent("restoration-commands"), encoding: .utf8).split(separator: "\n")
            #expect(!commands.isEmpty && commands.allSatisfy { ["hello", "shutdown"].contains(String($0)) })
        } catch {
            if engine != .sqlite {
                if let sourceSQL { await workspace.run(sourceSQL, sql: "DROP TABLE IF EXISTS \(sourceName)") }
                if let targetSQL { await workspace.run(targetSQL, sql: "DROP TABLE IF EXISTS \(targetName)") }
            }
            await workspace.shutdown(); throw error
        }
    }
    private func recordingHelper(executable: URL, directory: URL) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json, sys, subprocess, threading
        from pathlib import Path
        log = Path(sys.argv[1])/'restoration-commands'
        child = subprocess.Popen([sys.argv[2]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        def output():
            for line in child.stdout:
                sys.stdout.buffer.write(line); sys.stdout.buffer.flush()
        reader = threading.Thread(target=output,daemon=True); reader.start()
        for line in sys.stdin.buffer:
            kind = json.loads(line)['type']
            with log.open('a') as file: file.write(kind+'\\n')
            child.stdin.write(line); child.stdin.flush()
            if kind=='shutdown': break
        child.stdin.close()
        try: child.wait(timeout=5)
        except subprocess.TimeoutExpired: child.kill(); child.wait()
        reader.join(timeout=3)
        """, directory.path, executable.path])
    }

}
