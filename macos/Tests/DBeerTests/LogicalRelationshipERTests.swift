import Foundation
import Testing
@testable import DBeer

@MainActor
struct LogicalRelationshipERTests {
    private func profile(_ name: String = "Fixture") -> SavedConnection {
        .init(name: name, settings: .init(host: "example.invalid", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable"))
    }
    private func link(_ first: SavedConnection, _ second: SavedConnection) -> LogicalRelationship {
        .init(name: "Confirmed mapping", source: .init(profile: first, reference: .init(schema: "public", name: "same", kind: "table")),
            target: .init(profile: second, reference: .init(schema: "public", name: "same", kind: "table")),
            columns: [.init(source: "é", target: "e\u{0301}", sourceType: "text", targetType: "text"),
                      .init(source: "tenant", target: "tenant", sourceType: "numeric(40,0)", targetType: "numeric(40,0)")])
    }
    @Test func profileQualifiedExternalStubsRetainConfirmedIntentAndExactColumnNames() throws {
        let first = profile("First"), second = profile("Second"), relationship = link(first, second)
        let source = relationship.source.tableID, target = relationship.target.tableID
        let edges = LogicalRelationshipER.edges([relationship], tables: [source], metadata: [:], profiles: [first, second], metadataIsCurrent: false)
        let edge = try #require(edges.first)
        #expect(edges.count == 1 && edge.kind == .logical && edge.logicalID == relationship.id)
        #expect(edge.source != edge.target && edge.source == source && edge.target == target)
        #expect(edge.sourceProfileName == "First" && edge.targetProfileName == "Second" && edge.validationNotice != nil)
        #expect(Data(edge.key.columns[0].source.utf8) != Data(edge.key.columns[0].target.utf8))
        for table in [source, target] {
            let geometry = ERDiagramRouting.Geometry(tables: [table], placements: [.init(table: table, point: .init(x: 0, y: 0))], metadata: [:], collapsed: [])
            let routes = ERDiagramRouting.routes(geometry, relationships: edges)
            #expect(routes.count == 1 && routes[0].points.count >= 2 && routes[0].relationshipID == edge.id)
        }
    }
    @Test func changedOrMissingProfilesRemainVisibleWithReasonsAndNeverRebind() throws {
        let first = profile(), second = profile("Target"), relationship = link(first, second)
        var replacement = second; replacement.host = "replacement.invalid"
        let originalTarget = relationship.target.tableID
        for profiles in [[first, replacement], [first]] {
            let edges = LogicalRelationshipER.edges([relationship], tables: [relationship.source.tableID], metadata: [:], profiles: profiles, metadataIsCurrent: true)
            #expect(edges.first?.target == originalTarget && edges.first?.kind == .logical)
            #expect(edges.first?.validationNotice?.contains("missing or changed") == true)
        }
    }
    @Test func currentMetadataRequiresEveryOrderedExactNameAndNativeType() throws {
        let saved = profile()
        var relationship = link(saved, saved)
        relationship.target = .init(profile: saved, reference: .init(schema: "public", name: "other", kind: "table"))
        let source = relationship.source.tableID, target = relationship.target.tableID
        var facts = [source: ERTableMetadata(table: source,
                columns: [.init(name: "é", nativeType: "text", nullable: false, primaryKeyPosition: nil), .init(name: "tenant", nativeType: "numeric(40,0)", nullable: false, primaryKeyPosition: nil)], columnState: .available),
            target: ERTableMetadata(table: target,
                columns: [.init(name: "e\u{0301}", nativeType: "text", nullable: false, primaryKeyPosition: nil), .init(name: "tenant", nativeType: "numeric(40,0)", nullable: false, primaryKeyPosition: nil)], columnState: .available)]
        func edges() -> [ERRelationship] { LogicalRelationshipER.edges([relationship], tables: [source, target], metadata: facts, profiles: [saved], metadataIsCurrent: true) }
        #expect(edges().first?.validationNotice == nil)
        facts[target]?.columns[0] = .init(name: "é", nativeType: "text", nullable: false, primaryKeyPosition: nil)
        #expect(edges().first?.validationNotice != nil)
        facts[target]?.columns[0] = .init(name: "e\u{0301}", nativeType: "varchar", nullable: false, primaryKeyPosition: nil)
        #expect(edges().first?.validationNotice != nil)
        facts[source]?.columnState = .stale("Disconnected")
        #expect(edges().first?.validationNotice != nil)
    }
    @Test func changingConfirmedMappingInvalidatesRoutesWithoutChangingTableGeometry() throws {
        let first = profile(), second = profile("Target")
        var relationship = link(first, second)
        let source = relationship.source.tableID
        let model = ERDiagramModel(stored: .init(profileID: first.id, engine: first.engine, database: first.database,
            tables: [source], placements: [.init(table: source, point: .init(x: 0, y: 0))]))
        model.localRelationships = { LogicalRelationshipER.edges([relationship], tables: model.stored.tables, metadata: [:], profiles: [first, second], metadataIsCurrent: false) }
        let initial = model.relationshipRoutes
        #expect(initial.count == 1)
        relationship.id = UUID()
        let next = model.relationshipRoutes
        #expect(next.count == 1 && initial.first?.relationshipID != next.first?.relationshipID)
        model.localRelationships = { [] }
        #expect(model.relationships.isEmpty && model.relationshipRoutes.isEmpty)
    }

    @Test func confirmedViewMappingsExportWithoutRelaxingDeclaredForeignKeys() throws {
        let first = profile(), second = profile("Target")
        var relationship = link(first, second)
        relationship.target = .init(profile: second, reference: .init(schema: "public", name: "readable_view", kind: "view"))
        let table = relationship.source.tableID
        let edge = try #require(LogicalRelationshipER.edges([relationship], tables: [table], metadata: [:], profiles: [first, second], metadataIsCurrent: false).first)
        #expect(edge.kind == .logical && edge.key.target.kind == "view" && edge.isValid)
        #expect(!ERRelationship(source: table, key: edge.key).isValid)
        let snapshot = ERDiagramExportSnapshot(title: "View mapping", profileName: first.name, scope: .diagram,
            tables: [table], metadata: [:], placements: [.init(table: table, point: .init(x: 0, y: 0))], collapsed: [],
            relationships: [edge], relationshipDescriptions: [.init(id: edge.id, kind: .logical, targetProfileName: second.name)], notice: edge.validationNotice)
        try snapshot.validate()
        let original = String(decoding: try snapshot.originalMetadata(), as: UTF8.self)
        #expect(original.contains("readable_view") && original.contains("logical"))
    }

    @Test func combinedServerAndLocalEdgesStayBoundedWithVisibleExportedNotice() {
        let first = profile(), second = profile("Target"), relationship = link(first, second)
        let table = relationship.source.tableID
        let model = ERDiagramModel(stored: .init(profileID: first.id, engine: first.engine, database: first.database, tables: [table]))
        let serverKeys = (0..<ERDiagramLimits.relationships).map { index in
            TableForeignKey(name: "server_\(index)", target: .init(schema: "public", name: "parent", kind: "table"),
                columns: [.init(source: "id", target: "id", position: 1)])
        }
        model.setMetadata(.init(table: table, foreignKeys: serverKeys, relationshipState: .available))
        model.localRelationships = { [relationship] in
            LogicalRelationshipER.edges([relationship], tables: [table], metadata: [:], profiles: [first, second], metadataIsCurrent: false)
        }
        #expect(model.relationships.count == ERDiagramLimits.relationships)
        #expect(model.relationshipLimitNotice?.contains("1 additional") == true)
        #expect(model.displayNotice?.contains("Narrow the selected area") == true)
    }

    @Test func normalOfflineWorkspaceBindingRefreshesLocalProfileLabelsAndDeletedIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("logical-er-binding-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = profile(), second = profile("Target"), relationship = link(first, second)
        let links = LogicalRelationshipStore(fileURL: directory.appendingPathComponent("library.json"))
        await links.load(); try await links.saveConfirmed(relationship)
        let saved = StoredSQLDocument(title: "Offline links", text: "", kind: .erDiagram,
            erDiagram: .init(profileID: first.id, engine: first.engine, database: first.database, tables: [relationship.source.tableID]))
        var helpers = 0
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
            .init(connections: [first, second], selectedConnectionId: first.id)), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(snapshot: .init(documents: [saved])), logicalRelationships: links,
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in true },
            helperFactory: { helpers += 1; return BackendClient() })
        await workspace.start()
        let document = try #require(workspace.documents.first), model = try #require(document.erDiagramModel)
        #expect(model.relationships.first?.sourceProfileName == first.name && model.relationships.first?.validationNotice != nil)
        try #require(await workspace.library.saveConnection(name: "Renamed local label", settings: first.settings(password: ""), id: first.id))
        #expect(model.relationships.first?.sourceProfileName == "Renamed local label")
        try await links.delete(id: relationship.id)
        #expect(model.relationships.isEmpty && helpers == 0 && workspace.services.isEmpty)
        await workspace.shutdown()
    }
}
