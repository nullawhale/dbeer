import Foundation
import Testing
@testable import DBeer

/// Private local artifacts and model state only. No windows, helper processes,
/// Keychain, application activation or database connections are used.
@MainActor
struct ResultSnapshotDocumentTests {
    private func directory() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/r15/documents-\(UUID().uuidString)")
    }

    private func capture() -> ResultSnapshotCapture {
        ResultSnapshotCapture(title: "Captured result", sql: "SELECT 'captured SQL fixture';",
            engine: .postgresql,
            columns: [
                ResultColumn(index: 0, name: "same", typeOid: 25, nativeType: "text"),
                ResultColumn(index: 1, name: "same", typeOid: 1700, nativeType: "numeric"),
                ResultColumn(index: 2, name: "binary", typeOid: 17, nativeType: "bytea", encoding: "base64")
            ], rows: [
                [nil, "9007199254740993.12345678901234567890", "AP+A"],
                ["", "-0.00000000000000000001", ""],
                ["NULL", nil, nil],
                ["κόσμος 🐋\0", "1.2300", "AA=="],
                ["last row", "9999999999999999999999999999999999999999", "AQID"]
            ], capturedAt: Date(timeIntervalSince1970: 1_760_000_000.125), profileID: UUID(),
            profileName: "Synthetic production", environment: .production,
            outcome: .succeeded, sourceRowCount: 5, commandTag: "SELECT 5")
    }

    private func workspaceObject(_ snapshot: SQLWorkspaceSnapshot) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try #require(JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any])
    }

    @Test func localPagesPreserveExactValuesTypesAndCaptureContextAcrossAStoreRestart() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("snapshots")
        let store = ResultSnapshotStore(rootURL: root)
        let original = capture()
        let summary = try await store.save(original)
        let model = ResultSnapshotDocumentModel(id: summary.id, store: store, pageSize: 2)
        #expect(model.manifest == nil && model.result == nil && !model.isLoading && model.error == nil)
        await model.load()
        let manifest = try #require(model.manifest)
        #expect(model.isAvailable && model.pageIndex == 0 && model.pageCount == 3 && model.pageOffset == 0)
        #expect(!model.canLoadPrevious && model.canLoadNext)
        #expect(manifest.sql == original.sql && manifest.columns == original.columns)
        #expect(manifest.capturedAt == original.capturedAt && manifest.profileID == original.profileID)
        #expect(manifest.profileName == original.profileName && manifest.environment == .production)
        #expect(manifest.outcome == .succeeded && manifest.isComplete)
        #expect(model.result?.columns == original.columns && model.result?.rows == Array(original.rows.prefix(2)))
        #expect(model.result?.sessionId == nil && model.result?.queryId == nil)
        #expect(model.result?.rowCount == 5 && model.result?.displayedRowCount == 2)

        await model.loadPage(1)
        #expect(model.result?.rows == Array(original.rows[2..<4]) && model.pageOffset == 2)
        #expect(model.canLoadPrevious && model.canLoadNext)
        await model.loadPage(2)
        #expect(model.result?.rows == [original.rows[4]] && model.pageOffset == 4)
        #expect(model.canLoadPrevious && !model.canLoadNext)
        let page = model.result
        await model.loadPage(-1)
        await model.loadPage(3)
        await model.loadPage(Int.max)
        #expect(model.result == page && model.error == nil && model.pageIndex == 2)

        let restarted = ResultSnapshotDocumentModel(id: summary.id,
            store: ResultSnapshotStore(rootURL: root), pageSize: 2)
        await restarted.load()
        #expect(restarted.manifest == manifest && restarted.result?.rows == Array(original.rows.prefix(2)))
        #expect(try await store.load(id: summary.id).rows == original.rows)
    }

    @Test func partialSnapshotKeepsSourceCountsAndOutcomeWithoutClaimingCompleteness() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultSnapshotStore(rootURL: directory.appendingPathComponent("snapshots"))
        var original = capture()
        original.sourceRowCount = 8
        original.truncated = true
        original.outcome = .failed
        let summary = try await store.save(original)
        let model = ResultSnapshotDocumentModel(id: summary.id, store: store)
        await model.load()
        #expect(model.isAvailable && model.manifest?.partial == true && model.manifest?.truncated == true)
        #expect(model.manifest?.outcome == .failed && model.manifest?.isComplete == false)
        #expect(model.result?.rowCount == 8 && model.result?.displayedRowCount == 5)
        #expect(model.result?.displayNotice?.contains("partial") == true)
    }

    @Test func emptyArtifactIsAnAvailableSinglePageWithColumns() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultSnapshotStore(rootURL: directory.appendingPathComponent("snapshots"))
        var original = capture()
        original.rows = []
        original.sourceRowCount = 0
        let summary = try await store.save(original)
        let model = ResultSnapshotDocumentModel(id: summary.id, store: store)
        await model.load()
        #expect(model.isAvailable && model.pageCount == 1 && model.pageIndex == 0)
        #expect(model.result?.columns == original.columns && model.result?.rows == [])
        #expect(model.result?.displayedRowCount == 0 && model.result?.rowCount == 0)
        #expect(!model.canLoadPrevious && !model.canLoadNext)
    }

    @Test func corruptionOutsideTheVisiblePageClearsRowsAndRetainsReadableSQLProvenance() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("snapshots")
        let store = ResultSnapshotStore(rootURL: root)
        let original = capture()
        let summary = try await store.save(original)
        let rowsURL = root.appendingPathComponent(summary.id.uuidString.lowercased()).appendingPathComponent("rows.jsonl")
        let bytes = try Data(contentsOf: rowsURL)
        let text = try #require(String(data: bytes, encoding: .utf8))
        // Keep a valid positional row and the exact byte count so checksum
        // validation, including rows outside page zero, catches the damage.
        let changed = Data(text.replacingOccurrences(of: "last row", with: "lost row").utf8)
        #expect(changed.count == bytes.count && changed != bytes)
        try changed.write(to: rowsURL)
        let model = ResultSnapshotDocumentModel(id: summary.id, store: store, pageSize: 2)
        await model.load()
        #expect(!model.isAvailable && model.result == nil && model.error?.contains("damaged") == true)
        #expect(model.manifest?.sql == original.sql && model.manifest?.profileID == original.profileID)
        #expect(!model.canLoadPrevious && !model.canLoadNext)
        #expect(try Data(contentsOf: rowsURL) == changed)
    }

    @Test func missingOrRemovedArtifactRemainsUnavailableAndNeverPresentsStaleRows() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultSnapshotStore(rootURL: directory.appendingPathComponent("snapshots"))
        let missing = ResultSnapshotDocumentModel(id: UUID(), store: store)
        await missing.load()
        #expect(missing.result == nil && missing.manifest == nil && !missing.isAvailable)
        #expect(missing.error?.contains("no longer available") == true)

        let original = capture()
        let summary = try await store.save(original)
        let model = ResultSnapshotDocumentModel(id: summary.id, store: store)
        await model.load()
        #expect(model.isAvailable)
        try await store.delete(id: summary.id)
        await model.load()
        #expect(!model.isAvailable && model.result == nil && model.error != nil)
        #expect(model.manifest?.sql == original.sql)
    }

    @Test func changedManifestCannotKeepAnOldPageAvailableWhenTheRequestedPageDisappears() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("snapshots")
        let store = ResultSnapshotStore(rootURL: root)
        let summary = try await store.save(capture())
        let model = ResultSnapshotDocumentModel(id: summary.id, store: store, pageSize: 2)
        await model.load()
        let validatedManifest = try #require(model.manifest)
        #expect(model.isAvailable && model.pageCount == 3)
        let manifestURL = root.appendingPathComponent(summary.id.uuidString.lowercased()).appendingPathComponent("manifest.json")
        var metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        metadata["rowCount"] = 1
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: manifestURL)
        await model.loadPage(2)
        #expect(model.result == nil && !model.isAvailable && model.error?.contains("damaged") == true)
        #expect(model.manifest == validatedManifest && !model.isLoading)
        #expect(!model.canLoadPrevious && !model.canLoadNext)
    }

    @Test func revisitingACachedPageDetectsExternalRemovalAndRecoversWithoutResettingThePage() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("snapshots")
        let store = ResultSnapshotStore(rootURL: root)
        let original = capture()
        let summary = try await store.save(original)
        let model = ResultSnapshotDocumentModel(id: summary.id, store: store, pageSize: 2)
        await model.loadPage(2)
        #expect(model.isAvailable && model.pageIndex == 2 && model.result?.rows == [original.rows[4]])
        let artifact = root.appendingPathComponent(summary.id.uuidString.lowercased())
        let moved = directory.appendingPathComponent("temporarily-unavailable-artifact")
        try FileManager.default.moveItem(at: artifact, to: moved)
        await model.revalidateCurrentPage()
        #expect(!model.isAvailable && model.result == nil && model.error?.contains("no longer available") == true)
        #expect(model.pageIndex == 2 && model.pageOffset == 4 && model.manifest?.sql == original.sql)
        try FileManager.default.moveItem(at: moved, to: artifact)
        await model.revalidateCurrentPage()
        #expect(model.isAvailable && model.error == nil && model.pageIndex == 2 && model.pageOffset == 4)
        #expect(model.result?.rows == [original.rows[4]])
    }

    @Test func snapshotWorkspaceAndClosedTabStoreOnlyTheOpaqueArtifactReference() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = capture()
        let artifactStore = ResultSnapshotStore(rootURL: directory.appendingPathComponent("snapshots"))
        let summary = try await artifactStore.save(capture)
        let snapshot = StoredSQLDocument(title: summary.title, text: "", kind: .snapshot, snapshotID: summary.id)
        let sql = StoredSQLDocument(title: "Independent draft", text: "SELECT 'unrelated draft';", profileID: UUID())
        let table = StoredSQLDocument(title: "Table", text: "Table data", profileID: UUID(), kind: .table,
            table: StoredTableDocument(reference: TableReference(schema: "public", name: "items", kind: "table")))
        let workspace = SQLWorkspaceSnapshot(documents: [sql, snapshot, table], selectedDocumentID: snapshot.id)
        let url = directory.appendingPathComponent("workspace.json")
        try await FileSQLDocumentStore(fileURL: url).save(workspace)
        let restored = try await FileSQLDocumentStore(fileURL: url).load()
        #expect(restored == workspace && restored.version == SQLWorkspaceSnapshot.currentVersion)
        let data = try Data(contentsOf: url)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(object["documents"] as? [[String: Any]])
        #expect(Set(records[1].keys) == ["id", "title", "kind", "snapshotID"])
        #expect(records[1]["snapshotID"] as? String == summary.id.uuidString)
        #expect(!String(decoding: data, as: UTF8.self).contains(capture.sql))
        let closed = ClosedWorkspaceTab(state: restored.documents[1], originalIndex: 1)
        #expect(closed.state.snapshotID == summary.id && closed.state.kind == .snapshot)
        #expect(closed.state.text.isEmpty && closed.state.profileID == nil && closed.state.table == nil)
        let offline = ResultSnapshotDocumentModel(id: try #require(closed.state.snapshotID),
            store: ResultSnapshotStore(rootURL: directory.appendingPathComponent("snapshots")))
        await offline.load()
        #expect(offline.isAvailable && offline.result?.rows == capture.rows && offline.manifest?.sql == capture.sql)
    }

    @Test func v6MigrationBacksUpExactBytesAndPreservesSQLAndTableBindings() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sql = StoredSQLDocument(title: "Draft", text: "SELECT 'existing SQL';", profileID: UUID())
        let table = StoredSQLDocument(title: "Table", text: "Table data", profileID: UUID(), kind: .table,
            table: StoredTableDocument(reference: TableReference(schema: "public", name: "items", kind: "table"), page: 3))
        var object = try workspaceObject(SQLWorkspaceSnapshot(documents: [sql, table], selectedDocumentID: table.id))
        object["version"] = 6
        object["paneLayout"] = nil
        let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let url = directory.appendingPathComponent("workspace.json")
        try original.write(to: url)
        let migrated = try await FileSQLDocumentStore(fileURL: url).load()
        #expect(migrated.version == SQLWorkspaceSnapshot.currentVersion && migrated.documents == [sql, table] && migrated.selectedDocumentID == table.id)
        let backup = url.appendingPathExtension("v6.backup")
        #expect(try Data(contentsOf: backup) == original)
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try await FileSQLDocumentStore(fileURL: url).load() == migrated)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test func mixedOperationalSnapshotBindingsCannotReplaceAnIntactWorkspace() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let valid = StoredSQLDocument(title: "Snapshot", text: "", kind: .snapshot, snapshotID: UUID())
        let store = FileSQLDocumentStore(fileURL: url)
        try await store.save(SQLWorkspaceSnapshot(documents: [valid], selectedDocumentID: valid.id))
        let bytes = try Data(contentsOf: url)
        var invalid: [StoredSQLDocument] = []
        var changed = valid; changed.snapshotID = nil; invalid.append(changed)
        changed = valid; changed.text = "SELECT 'must not execute';"; invalid.append(changed)
        changed = valid; changed.profileID = UUID(); invalid.append(changed)
        changed = valid; changed.table = StoredTableDocument(reference: TableReference(schema: "public", name: "items", kind: "table")); invalid.append(changed)
        changed = valid; changed.fileURL = URL(fileURLWithPath: "/snapshot-fixtures/query.sql"); invalid.append(changed)
        changed = valid; changed.fileContentSHA256 = String(repeating: "a", count: 64); invalid.append(changed)
        changed = valid; changed.fileDocumentID = UUID(); invalid.append(changed)
        changed = valid; changed.fileRecoveryURL = URL(fileURLWithPath: "/snapshot-fixtures/recovery.sql"); invalid.append(changed)
        changed = valid; changed.sqlLibraryEntryID = UUID(); invalid.append(changed)
        changed = valid; changed.kind = .sql; invalid.append(changed)
        changed = valid; changed.kind = .table; invalid.append(changed)
        for document in invalid {
            #expect(!document.isValid)
            await #expect(throws: SQLDocumentStoreError.self) {
                try await store.save(SQLWorkspaceSnapshot(documents: [document], selectedDocumentID: document.id))
            }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func malformedSnapshotReferencesAndNewBindingsInOldFormatsRemainUntouched() async throws {
        let base = StoredSQLDocument(title: "Snapshot", text: "", kind: .snapshot, snapshotID: UUID())
        let object = try workspaceObject(SQLWorkspaceSnapshot(documents: [base], selectedDocumentID: base.id))
        let baseRecord = try #require((object["documents"] as? [[String: Any]])?.first)
        var malformed: [[String: Any]] = []
        for value in [NSNull(), "../../private-file", "not-a-uuid"] as [Any] {
            var record = baseRecord; record["snapshotID"] = value
            malformed.append(object.merging(["documents": [record]]) { _, new in new })
        }
        var missing = baseRecord; missing.removeValue(forKey: "snapshotID")
        malformed.append(object.merging(["documents": [missing]]) { _, new in new })
        for field in ["profileID", "fileDocumentID", "sqlLibraryEntryID"] {
            var record = baseRecord; record[field] = UUID().uuidString
            malformed.append(object.merging(["documents": [record]]) { _, new in new })
        }
        for (field, value) in [("text", "SELECT 'must not execute';"),
                               ("fileURL", "file:///snapshot-fixtures/query.sql"),
                               ("fileRecoveryURL", "file:///snapshot-fixtures/recovery.sql"),
                               ("fileContentSHA256", String(repeating: "a", count: 64))] {
            var record = baseRecord; record[field] = value
            malformed.append(object.merging(["documents": [record]]) { _, new in new })
        }
        for field in ["rows", "password", "sessionId", "runtime"] {
            var record = baseRecord; record[field] = "forbidden fixture"
            malformed.append(object.merging(["documents": [record]]) { _, new in new })
        }
        for field in ["text", "profileID", "table", "fileURL", "fileDocumentID", "fileRecoveryURL", "sqlLibraryEntryID"] {
            var record = baseRecord; record[field] = NSNull()
            malformed.append(object.merging(["documents": [record]]) { _, new in new })
        }
        var legacySnapshot = object
        legacySnapshot["version"] = 6
        legacySnapshot["paneLayout"] = nil
        malformed.append(legacySnapshot)
        let sql = StoredSQLDocument(title: "SQL", text: "SELECT 1;")
        var oldSQL = try workspaceObject(SQLWorkspaceSnapshot(documents: [sql], selectedDocumentID: sql.id))
        var oldRecord = try #require((oldSQL["documents"] as? [[String: Any]])?.first)
        oldRecord["snapshotID"] = NSNull()
        oldSQL["documents"] = [oldRecord]
        oldSQL["version"] = 6
        oldSQL["paneLayout"] = nil
        malformed.append(oldSQL)
        for document in malformed {
            let directory = directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("workspace.json")
            let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            try bytes.write(to: url)
            let store = FileSQLDocumentStore(fileURL: url)
            await #expect(throws: SQLDocumentStoreError.self) { _ = try await store.load() }
            await #expect(throws: SQLDocumentStoreError.self) { try await store.save(SQLWorkspaceSnapshot()) }
            #expect(try Data(contentsOf: url) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["workspace.json"])
        }
    }
}
