import Foundation
import Testing
@testable import DBeer

// These suites exercise value models and isolated workspace stores only.
// They never create windows, activate the application or use saved credentials.
private func erResponse(_ names: [String], _ rows: [[String?]], truncated: Bool = false) -> BackendMessage {
    BackendMessage(type: "query.result", requestId: "fixture", columns: names.enumerated().map {
        ResultColumn(index: $0.offset, name: $0.element)
    }, rows: rows, rowCount: Int64(rows.count), truncated: truncated)
}
private let erColumnFields = ["name", "nativeType", "nullable", "primaryKey"]
private let erKeyFields = ["name", "targetSchema", "targetTable", "sourceColumn", "targetColumn", "position"]
private func erKey(_ name: String = "fk", target: ERTableID, sourceColumn: String = "parent") -> TableForeignKey {
    .init(name: name, target: target.reference, columns: [.init(source: sourceColumn, target: "id", position: 1)])
}

struct ERDiagramMetadataTests {
    @Test func exactIdentifiersAndPhysicalOrderRemainIndependentOfKeyOrder() throws {
        let profile = UUID()
        let composed = ERTableID(profileID: profile, schema: "s.with.dots", name: "é")
        let decomposed = ERTableID(profileID: profile, schema: "s.with.dots", name: "e\u{301}")
        #expect(composed != decomposed && Set([composed, decomposed]).count == 2)
        let columns = try ERDiagramMetadata.columns(erResponse(erColumnFields, [
            ["second", "numeric(38, 9)", "false", "2"], ["first", "text", "true", "1"], ["é", "text", "true", "0"], ["e\u{301}", "text", "true", "0"]]))
        #expect(columns.map(\.name) == ["second", "first", "é", "e\u{301}"])
        #expect(columns.compactMap(\.primaryKeyPosition) == [2, 1])
        #expect(columns[0].nativeType == "numeric(38, 9)" && !columns[0].nullable)
    }
    @Test func incompleteAndMalformedColumnsNeverAssertPrimaryKeys() throws {
        let cases: [[[String?]]] = [
            [["id", "integer", "false", "2"]], [["id", "integer", "unknown", "1"]],
            [["id", "integer", "false", "1"], ["id", "integer", "false", "2"]],
            [["id", "integer", "false", "1"], ["other", "integer", "false", "1"]],
            [["id", nil, "false", "1"]], [["", "integer", "false", "0"]], [["id", "integer", "false"]],
        ]
        for rows in cases { #expect(throws: ERDiagramFailure.self) { try ERDiagramMetadata.columns(erResponse(erColumnFields, rows)) } }
        #expect(throws: ERDiagramFailure.self) { try ERDiagramMetadata.columns(erResponse(erColumnFields, [["id", "integer", "false", "1"]], truncated: true)) }
        var mismatch = erResponse(erColumnFields, []); mismatch.rowCount = 3
        #expect(throws: ERDiagramFailure.self) { try ERDiagramMetadata.columns(mismatch) }
        #expect(try ERDiagramMetadata.columns(erResponse(erColumnFields, [])).isEmpty)
    }
    @Test func compositeCrossSchemaKeysAreAtomicAndNotPrimaryKeyEvidence() throws {
        let keys = try TableForeignKey.parse(erResponse(erKeyFields, [
            ["same", "other.schema", "parent.table", "b", "second", "2"],
            ["same", "other.schema", "parent.table", "a", "first", "1"],
            ["é", "other.schema", "parent.table", "a", "id", "1"],
            ["e\u{301}", "other.schema", "parent.table", "a", "id", "1"],
        ]))
        #expect(keys.count == 3)
        let composite = try #require(keys.first { $0.name == "same" })
        #expect(composite.columns.map(\.source) == ["a", "b"] && composite.target.schema == "other.schema")
        let columns = try ERDiagramMetadata.columns(erResponse(erColumnFields, [["a", "int", "false", "0"], ["b", "int", "true", "0"]]))
        #expect(columns.allSatisfy { $0.primaryKeyPosition == nil })
        #expect(throws: TableNavigationFailure.self) {
            try TableForeignKey.parse(erResponse(erKeyFields, [["fk", "s", "p", "b", "id", "2"]]))
        }
    }
}

@MainActor
struct ERDiagramLoaderTests {
    private func fixture(_ count: Int = 2) -> (ERDiagramModel, ERDiagramLoadContext) {
        let profile = UUID()
        let tables = (0..<count).map { ERTableID(profileID: profile, schema: "fixture", name: "table_\($0)") }
        let model = ERDiagramModel(stored: .init(profileID: profile, engine: .postgresql, database: "fixture", tables: tables))
        let context = ERDiagramLoadContext(profileID: profile, sessionID: "session", serviceGeneration: UUID(), settingsRevision: UUID(), engine: .postgresql, database: "fixture")
        return (model, context)
    }
    @Test func loaderReadsOnlySelectedMetadataInOrderWithoutRowsOrSQL() async throws {
        let (model, context) = fixture()
        var requests: [CatalogRequest] = []
        await ERDiagramLoader.load(model, context: context, isCurrent: { true }) { request in
            requests.append(request)
            if request.kind == "columns" { return erResponse(erColumnFields, [["id", "integer", "false", "1"]]) }
            return erResponse(erKeyFields, [["fk", "outside", "parent", "id", "unique_id", "1"]])
        }
        #expect(requests.map(\.kind) == ["columns", "foreignKeys", "columns", "foreignKeys"])
        #expect(requests.map(\.object) == ["table_0", "table_0", "table_1", "table_1"])
        #expect(model.progress == 2 && !model.isLoading && model.relationships.count == 2)
        #expect(model.relationships[0].id != model.relationships[1].id)
        #expect(model.relationships.allSatisfy { !model.stored.tables.contains($0.target) })
        #expect(model.metadata.values.allSatisfy { $0.columnState.isAvailable && $0.relationshipState.isAvailable })
    }
    @Test(arguments: [DatabaseEngine.postgresql, .mysql])
    func workspaceBuildIsExplicitConnectedOnlyAndCancelsItsExactSubmittedQuery(engine: DatabaseEngine) async throws {
        let fixture = try await PostgresTypeTestFixture.make(engine: engine)
        let workspace = fixture.workspace
        let document = try #require(workspace.openERDiagram(fixture.node("er_hold_columns", kind: "table", typeKind: "table")))
        let model = try #require(document.erDiagramModel)
        #expect(try fixture.commands().isEmpty)
        await workspace.buildERDiagram(document)
        #expect(try fixture.commands().isEmpty)
        let build = Task { await workspace.buildERDiagram(document, connect: true) }
        try await fixture.waitForCatalog("columns")
        let owned = try #require(fixture.commands().last { $0.catalog?.kind == "columns" })
        workspace.stopERDiagram(model)
        await build.value
        try await PostgresTypeTestFixture.waitFor { model.sourceState(fixture.profile.id).notice?.contains("accepted") == true }
        let cancel = try #require(fixture.commands().last { $0.type == "cancel" })
        #expect(cancel.sessionId == owned.sessionId && cancel.queryId == owned.queryId)
        #expect(model.metadata.values.allSatisfy { !$0.columnState.isAvailable })
        model.remove(model.stored.tables[0])
        model.add(.init(profileID: fixture.profile.id, schema: "public", name: "er_ready"))
        await workspace.buildERDiagram(document)
        #expect(model.metadata.values.allSatisfy { $0.columnState.isAvailable && $0.relationshipState.isAvailable })
        let commands = try fixture.commands()
        #expect(commands.filter { $0.type == "connect" }.count == 1)
        #expect(!commands.contains { $0.type == "execute" || $0.catalog?.kind == "browse" })
        #expect(await workspace.disconnectProfile(fixture.profile.id))
        let connects = try fixture.commands().filter { $0.type == "connect" }.count
        await workspace.buildERDiagram(document)
        #expect(try fixture.commands().filter { $0.type == "connect" }.count == connects)
        #expect(model.metadata.values.allSatisfy { !$0.columnState.isAvailable })
        await fixture.finish()
    }
    @Test func labelChangeDuringConnectionPreparationDoesNotDiscardBuild() async throws {
        let fixture = try await PostgresTypeTestFixture.make()
        let workspace = fixture.workspace
        let document = try #require(workspace.openERDiagram(fixture.node("er_ready", kind: "table", typeKind: "table")))
        let model = try #require(document.erDiagramModel)
        try fixture.holdConnection()
        let building = Task { await workspace.buildERDiagram(document, connect: true) }
        do {
            try await PostgresTypeTestFixture.waitFor { fixture.connectionIsWaiting }
            try #require(await workspace.library.saveConnection(name: "Renamed while connecting",
                settings: fixture.profile.settings(password: ""), id: fixture.profile.id))
            try fixture.releaseConnection()
            await building.value
            let columnsAvailable = model.metadata.values.first?.columnState.isAvailable == true
            let keysAvailable = model.metadata.values.first?.relationshipState.isAvailable == true
            let ownerLabel = model.source(fixture.profile.id)?.name
            #expect(columnsAvailable && keysAvailable && ownerLabel == "Renamed while connecting")
            let commands = try fixture.commands()
            #expect(commands.filter { $0.type == "connect" }.count == 1)
            #expect(commands.contains { $0.catalog?.kind == "columns" })
            #expect(!commands.contains { $0.type == "execute" || $0.type == "cancel" })
            await fixture.finish()
        } catch {
            try? fixture.releaseConnection(); await building.value
            await fixture.finish(); throw error
        }
    }

    @Test func queuedCancellationDoesNotCancelAnotherCatalogConsumer() async throws {
        let fixture = try await PostgresTypeTestFixture.make()
        try await fixture.connect()
        let workspace = fixture.workspace
        let document = try #require(workspace.openERDiagram(fixture.node("er_ready", kind: "table", typeKind: "table")))
        let model = try #require(document.erDiagramModel)
        let other = Task { try await workspace.catalog(CatalogRequest(kind: "objects", schema: "hold-objects", objectKind: "table"), profileID: fixture.profile.id) }
        try await fixture.waitForCatalog("objects")
        let build = Task { await workspace.buildERDiagram(document) }
        try await PostgresTypeTestFixture.waitFor { model.request != nil }
        #expect(model.request?.submitted == false)
        workspace.stopERDiagram(model)
        try fixture.releaseHeld()
        _ = try await other.value
        await build.value
        #expect(try fixture.commands().filter { $0.type == "cancel" }.isEmpty)
        #expect(try fixture.commands().filter { $0.catalog?.kind == "columns" }.isEmpty)
        await fixture.finish()
    }

    @Test func columnAndKeyFailuresStaySeparateAndRetryDoesNotReloadSuccessfulTables() async {
        let (model, context) = fixture()
        await ERDiagramLoader.load(model, context: context, isCurrent: { true }) { request in
            if request.kind == "columns" { return erResponse(erColumnFields, [["id", "integer", "false", "1"]]) }
            if request.object == "table_0" { throw ERDiagramFailure("Fixture metadata denied") }
            return erResponse(erKeyFields, [])
        }
        let first = model.stored.tables[0], second = model.stored.tables[1]
        #expect(model.metadata[first]?.columnState.isAvailable == true)
        #expect(model.metadata[first]?.relationshipState.isAvailable == false)
        #expect(model.metadata[second]?.relationshipState.isAvailable == true)
        var retried: [String?] = []
        await ERDiagramLoader.load(model, context: context, isCurrent: { true }, provider: { request in
            retried.append(request.object)
            return request.kind == "columns" ? erResponse(erColumnFields, [["id", "integer", "false", "1"]]) : erResponse(erKeyFields, [])
        }, retryFailuresOnly: true)
        #expect(retried == ["table_0", "table_0"])
        #expect(model.metadata.values.allSatisfy { $0.relationshipState.isAvailable })
    }
    @Test func obsoleteReplyAndStoppedGenerationCannotPublishMetadataOrContinue() async {
        let (model, context) = fixture()
        var requests = 0, connected = true
        await ERDiagramLoader.load(model, context: context, isCurrent: { connected }) { _ in
            requests += 1; connected = false
            return erResponse(erColumnFields, [["id", "int", "false", "1"]])
        }
        #expect(requests == 1 && model.metadata.values.allSatisfy { !$0.columnState.isAvailable })
        connected = true; requests = 0
        await ERDiagramLoader.load(model, context: context, isCurrent: { connected }) { _ in
            requests += 1; model.invalidate("Disconnected fixture")
            return erResponse(erColumnFields, [["id", "int", "false", "1"]])
        }
        #expect(requests == 1 && !model.isLoading && model.context == nil)
        #expect(model.metadata.values.allSatisfy { !$0.columnState.isAvailable })
    }
    @Test func emptyColumnsRequireSeparateAvailabilityEvidenceAndWarningsRemainPartial() async {
        let (model, context) = fixture(1)
        var kinds: [String] = []
        await ERDiagramLoader.load(model, context: context, isCurrent: { true }) { request in
            kinds.append(request.kind)
            switch request.kind {
            case "columns": return erResponse(erColumnFields, [])
            case "search": return erResponse(["name", "kind", "schema"], [["table_0", "table", "fixture"]])
            default: var reply = erResponse(erKeyFields, []); reply.displayNotice = "Metadata may be incomplete"; return reply
            }
        }
        #expect(kinds == ["columns", "search", "foreignKeys"])
        #expect(model.metadata.values.first?.columnState.isAvailable == true)
        #expect(model.metadata.values.first?.relationshipState.isAvailable == false)
        #expect(model.metadata.values.first?.relationshipState.reason?.contains("incomplete") == true)
    }
    @Test func cumulativeBoundsStopWorkWithoutTruncatingACompositeRelationship() async {
        let (model, context) = fixture(12)
        var requests = 0
        let columns = (0..<1_000).map { ["column_\($0)", "text", "true", "0"] as [String?] }
        await ERDiagramLoader.load(model, context: context, isCurrent: { true }) { request in
            requests += 1
            return request.kind == "columns" ? erResponse(erColumnFields, columns) : erResponse(erKeyFields, [])
        }
        #expect(requests == 22 && model.progress == 10)
        #expect(model.metadata.values.reduce(0) { $0 + $1.columns.count } == ERDiagramLimits.columns)
        #expect(model.notice?.contains("limit") == true && !model.isLoading)
        #expect(model.stored.placements.count == 12)
    }
}

struct ERDiagramLayoutTests {
    private func rect(_ placement: ERPlacement, metadata: [ERTableID: ERTableMetadata], collapsed: Set<ERTableID>) -> CGRect {
        CGRect(x: placement.point.x, y: placement.point.y, width: ERDiagramLayout.width,
               height: ERDiagramLayout.height(metadata[placement.table], collapsed: collapsed.contains(placement.table)))
    }
    private func hasConnectorSpace(_ a: CGRect, _ b: CGRect) -> Bool {
        let horizontal = max(a.minX - b.maxX, b.minX - a.maxX)
        let vertical = max(a.minY - b.maxY, b.minY - a.maxY)
        return horizontal >= ERDiagramLayout.horizontalGap || vertical >= ERDiagramLayout.verticalGap
    }

    @Test func generatedCardsReserveConnectorSpaceAcrossRanksAndRows() {
        let profile = UUID()
        let tables = (0..<6).map { ERTableID(profileID: profile, schema: "fixture", name: "table_\($0)") }
        let relationships = [(1, 0), (2, 0), (3, 1), (4, 1)].map {
            ERRelationship(source: tables[$0.0], key: erKey(target: tables[$0.1]))
        }
        let counts = [1, 5, 2, 8, 4, 0]
        let metadata = Dictionary(uniqueKeysWithValues: tables.enumerated().map { index, table in
            (table, ERTableMetadata(table: table, columns: (0..<counts[index]).map {
                ERColumn(name: "column_\($0)", nativeType: "integer", nullable: true, primaryKeyPosition: nil)
            }, columnState: .available))
        })
        let placements = ERDiagramLayout.positions(tables: tables, relationships: relationships, metadata: metadata, preserving: [], collapsed: [])
        #expect(placements.count == tables.count)
        var adjacentRanks = false, adjacentRows = false
        for (index, placement) in placements.enumerated() {
            let a = rect(placement, metadata: metadata, collapsed: [])
            for other in placements.dropFirst(index + 1) {
                let b = rect(other, metadata: metadata, collapsed: [])
                #expect(hasConnectorSpace(a, b))
                if max(a.minX - b.maxX, b.minX - a.maxX) == ERDiagramLayout.horizontalGap { adjacentRanks = true }
                if a.minX == b.minX, max(a.minY - b.maxY, b.minY - a.maxY) == ERDiagramLayout.verticalGap { adjacentRows = true }
            }
        }
        #expect(adjacentRanks && adjacentRows)
        #expect(placements == ERDiagramLayout.positions(tables: tables.reversed(), relationships: relationships.reversed(),
            metadata: metadata, preserving: [], collapsed: []))
    }

    @Test func generatedCardsKeepTheirDistanceFromUnchangedManualPlacements() {
        let profile = UUID()
        let tables = (0..<7).map { ERTableID(profileID: profile, schema: "fixture", name: "table_\($0)") }
        // Existing manual cards may overlap; the layout preserves their exact positions.
        let manual = [ERPlacement(table: tables[0], point: .init(x: 100, y: 40), manual: true),
                      ERPlacement(table: tables[1], point: .init(x: 270, y: 180), manual: true)]
        let metadata = Dictionary(uniqueKeysWithValues: tables.enumerated().map { index, table in
            (table, ERTableMetadata(table: table, columns: (0..<(index == 4 ? 20 : index + 2)).map {
                ERColumn(name: "column_\($0)", nativeType: "text", nullable: true, primaryKeyPosition: nil)
            }, columnState: .available))
        })
        let collapsed: Set<ERTableID> = [tables[4]]
        let relationships = [ERRelationship(source: tables[2], key: erKey(target: tables[3]))]
        let placements = ERDiagramLayout.positions(tables: tables, relationships: relationships, metadata: metadata,
            preserving: manual, collapsed: collapsed)
        #expect(placements.count == tables.count)
        for preserved in manual { #expect(placements.first { $0.table == preserved.table } == preserved) }
        for placement in placements where !manual.contains(where: { $0.table == placement.table }) {
            let a = rect(placement, metadata: metadata, collapsed: collapsed)
            for other in placements where other.table != placement.table {
                #expect(hasConnectorSpace(a, rect(other, metadata: metadata, collapsed: collapsed)))
            }
        }
        #expect(placements == ERDiagramLayout.positions(tables: tables.reversed(), relationships: relationships.reversed(),
            metadata: metadata, preserving: manual.reversed(), collapsed: collapsed))
    }

    @Test func cyclicDisconnectedSelfAndParallelEdgesHaveStableNonoverlappingGeometry() throws {
        let profile = UUID()
        let tables = (0..<8).map { ERTableID(profileID: profile, schema: "s", name: "t\($0)") }
        let edges = [ERRelationship(source: tables[0], key: erKey(target: tables[1])),
            ERRelationship(source: tables[1], key: erKey(target: tables[0])),
            ERRelationship(source: tables[0], key: erKey("second", target: tables[1])),
            ERRelationship(source: tables[0], key: erKey("self", target: tables[0])),
            ERRelationship(source: tables[2], key: erKey(target: tables[3]))]
        let positions = ERDiagramLayout.positions(tables: tables, relationships: edges, metadata: [:], preserving: [], collapsed: [])
        #expect(positions == ERDiagramLayout.positions(tables: tables.reversed(), relationships: edges.reversed(), metadata: [:], preserving: [], collapsed: []))
        #expect(positions.count == tables.count && positions.allSatisfy { $0.point.isValid })
        for (i, item) in positions.enumerated() {
            let rect = CGRect(x: item.point.x, y: item.point.y, width: ERDiagramLayout.width, height: ERDiagramLayout.height(nil, collapsed: false))
            for other in positions.dropFirst(i + 1) {
                #expect(!rect.intersects(CGRect(x: other.point.x, y: other.point.y, width: ERDiagramLayout.width, height: ERDiagramLayout.height(nil, collapsed: false))))
            }
        }
        let manual = ERPlacement(table: tables[0], point: .init(x: -100, y: 500), manual: true)
        let updated = ERDiagramLayout.positions(tables: tables, relationships: edges, metadata: [:], preserving: [manual], collapsed: [])
        #expect(updated.first { $0.table == tables[0] } == manual)
        let fitted = ERDiagramLayout.fit(updated, metadata: [:], collapsed: [], size: CGSize(width: 1_000, height: 600))
        #expect(fitted.isValid)
    }
    @Test func viewportZoomPreservesItsAnchorAndRemainsInvertible() {
        var viewport = ERViewport(zoom: 0.7, pan: .init(x: 250, y: -100))
        let point = ERPoint(x: 123, y: -54), anchor = ERPoint(x: 425, y: 329)
        let before = viewport.world(anchor)
        viewport.scale(1.8, around: anchor)
        #expect(abs(viewport.world(anchor).x - before.x) < 0.00001)
        #expect(abs(viewport.world(anchor).y - before.y) < 0.00001)
        #expect(abs(viewport.world(viewport.screen(point)).x - point.x) < 0.00001)
        viewport.scale(.infinity, around: anchor)
        #expect(viewport.isValid)
        viewport.scale(1e10, around: anchor)
        #expect(viewport.zoom == ERViewport.zoomRange.upperBound && viewport.isValid)
    }
    @Test func extremeBoundedZoomFocusAndFitKeepPresentationPersistable() {
        var viewport = ERViewport(zoom: 0.2, pan: .init(x: 1_000_000, y: -1_000_000))
        viewport.scale(15, around: .init(x: 500, y: 300))
        #expect(viewport.isValid)
        let point = ERPoint(x: 1_000_000, y: -1_000_000)
        viewport = ERDiagramLayout.focus(point, viewport: viewport, size: CGSize(width: 1_000, height: 600))
        #expect(viewport.isValid)
        let table = ERTableID(profileID: UUID(), schema: "s", name: "t")
        let fitted = ERDiagramLayout.fit([.init(table: table, point: point)], metadata: [:], collapsed: [], size: CGSize(width: 1_000, height: 600))
        #expect(fitted.isValid)
    }
    @Test func boundedHundredTableGraphRetainsAllNodesAndFinishes() {
        let profile = UUID(), clock = ContinuousClock(), start = clock.now
        let tables = (0..<100).map { ERTableID(profileID: profile, schema: "fixture", name: "t\($0)") }
        let columns = (0..<100).map { ERColumn(name: "c\($0)", nativeType: "integer", nullable: true, primaryKeyPosition: nil) }
        let metadata = Dictionary(uniqueKeysWithValues: tables.map { ($0, ERTableMetadata(table: $0, columns: columns, columnState: .available)) })
        let edges = (0..<1_000).map { ERRelationship(source: tables[$0 % 100], key: erKey("fk\($0)", target: tables[($0 * 7 + 1) % 100])) }
        let placements = ERDiagramLayout.positions(tables: tables, relationships: edges, metadata: metadata, preserving: [], collapsed: [])
        #expect(placements.count == 100 && placements.allSatisfy { $0.point.isValid })
        #expect(start.duration(to: clock.now) < .seconds(10))
    }
}

@MainActor
struct ERDiagramWorkspaceTests {
    private func stored(profileID: UUID) -> StoredSQLDocument {
        let table = ERTableID(profileID: profileID, schema: "schema.with.dot", name: "table.with.dot")
        return StoredSQLDocument(title: "ER", text: "", kind: .erDiagram,
            erDiagram: StoredERDiagram(profileID: profileID, engine: .postgresql, database: "fixture", tables: [table],
                placements: [.init(table: table, point: .init(x: 120, y: -200), manual: true)], collapsed: [table], selected: table))
    }
    @Test func restorationSelectionMovementCloseAndReopenCannotStartAHelperOrReadCredentials() async throws {
        let profile = SavedConnection(name: "Fixture", settings: ConnectionSettings(host: "127.0.0.1", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable"))
        let saved = stored(profileID: profile.id)
        let store = MemorySQLDocumentStore(snapshot: SQLWorkspaceSnapshot(documents: [saved], selectedDocumentID: saved.id))
        var starts = 0
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library: .init(connections: [profile], selectedConnectionId: profile.id)),
            credentialStore: MemoryConnectionCredentialStore(), documentStore: store, helperFactory: {
                starts += 1; return BackendClient(executableURL: URL(fileURLWithPath: "/er-fixtures/unused-helper"))
            })
        await workspace.start()
        let document = try #require(workspace.documents.first)
        let model = try #require(document.erDiagramModel)
        #expect(document.isERDiagram && !document.isSQLDocument && document.runtime == nil)
        #expect(model.metadata.isEmpty && model.context == nil && starts == 0 && workspace.services.isEmpty)
        #expect(document.storedState == saved && workspace.allOwnedRuntimeDocuments.isEmpty)
        workspace.selectDocument(document.id, in: workspace.activePaneID)
        await workspace.run(document)
        await workspace.runScript(document)
        let commandContext = AppCommandContext(documentID: document.id, focus: .sqlEditor,
            isWorkspaceWindow: true, hasModal: false)
        for command in [AppCommandID.explain, .explainAnalyze] {
            #expect(!workspace.commands.canPerform(command, context: commandContext))
        }
        #expect(workspace.executionFragment(document) == nil && starts == 0)
        model.move(try #require(model.stored.selected), to: .init(x: 320, y: 410))
        await workspace.flushDocuments()
        #expect(await store.load().documents.first?.erDiagram?.placements.first?.point == ERPoint(x: 320, y: 410))
        await workspace.closeDocument(document)
        let reopened = try #require(workspace.reopenClosedTab())
        #expect(reopened.isERDiagram && reopened.runtime == nil && reopened.erDiagramModel?.metadata.isEmpty == true)
        #expect(starts == 0 && workspace.services.isEmpty)
        await workspace.shutdown()
    }
    @Test func versionElevenMigrationPreservesPaneAndExactBytesInPrivateBackup() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/er-migration/\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sql = StoredSQLDocument(title: "Preserved", text: "SELECT 'e\u{301}';\r\n")
        let snapshot = SQLWorkspaceSnapshot(documents: [sql], selectedDocumentID: sql.id)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any])
        object["version"] = 11
        let original = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let file = root.appendingPathComponent("workspace.json"); try original.write(to: file)
        let store = FileSQLDocumentStore(fileURL: file)
        #expect(try await store.load() == snapshot)
        let backup = file.appendingPathExtension("v11.backup")
        #expect(try Data(contentsOf: backup) == original)
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func boundedPayloadRoundTripsAndRejectsUnknownFieldsReferencesAndOldVersions() throws {
        let saved = stored(profileID: UUID())
        let snapshot = SQLWorkspaceSnapshot(documents: [saved], selectedDocumentID: saved.id)
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(SQLWorkspaceSnapshot.self, from: data) == snapshot)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var old = json; old["version"] = 11
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SQLWorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: old)) }
        var payload = try #require(saved.erDiagram)
        payload.tables.append(payload.tables[0]); #expect(!payload.isValid)
        payload = try #require(saved.erDiagram); payload.viewport.zoom = 0; #expect(!payload.isValid)
        payload = try #require(saved.erDiagram); payload.placements[0].point.x = .infinity; #expect(!payload.isValid)
        payload = try #require(saved.erDiagram); payload.engine = .mongodb; #expect(!payload.isValid)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var er = try #require(object["erDiagram"] as? [String: Any]); er["sessionId"] = "not-portable"; object["erDiagram"] = er
        #expect(throws: (any Error).self) { try JSONDecoder().decode(StoredSQLDocument.self, from: JSONSerialization.data(withJSONObject: object)) }
        let encoded = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        #expect(!encoded.contains("sessionId") && !encoded.contains("password") && !encoded.contains("columns"))
    }
}
