import Foundation
import Testing
@testable import DBeer

/// Value/model checks only: no helper, windows, prompts or credential access.
@MainActor
struct ERStructureActionTests {
    private func fixture(targetProfile: UUID? = nil, notice: String? = nil, targetKind: String = "table", targetSchema: String = "public", engine: DatabaseEngine = .postgresql) -> (ERDiagramModel, ERRelationship) {
        let profile = SavedConnection(name: "Synthetic", settings: .init(host: "synthetic.invalid", port: 5432,
            database: "synthetic", user: "fixture", password: "", sslMode: "disable", engine: engine))
        let source = ERTableID(profileID: profile.id, schema: "public", name: "child")
        let target = ERTableID(profileID: targetProfile ?? profile.id, schema: targetSchema, name: "parent")
        let sources: [ERDiagramSource] = target.profileID == profile.id ? [.init(profile)] : [.init(profile),
            .init(SavedConnection(id: target.profileID, name: "Synthetic other owner", settings: profile.settings(password: "")))]
        let model = ERDiagramModel(stored: .init(profileID: profile.id, engine: profile.engine, database: profile.database,
            sources: sources, tables: [source, target]))
        let edge = ERRelationship(source: source, key: .init(name: "Local composite", target: .init(schema: target.schema, name: target.name, kind: targetKind),
            columns: [.init(source: "e\u{301}", target: "first", position: 1), .init(source: "second", target: "é", position: 2)]),
            logicalID: UUID(), targetProfileID: target.profileID, validationNotice: notice)
        model.localRelationships = { [edge] }
        model.setMetadata(.init(table: source, columns: [.init(name: "e\u{301}", nativeType: "integer", nullable: true, primaryKeyPosition: nil),
            .init(name: "second", nativeType: "integer", nullable: true, primaryKeyPosition: nil)], columnState: .available, relationshipState: .available))
        model.setMetadata(.init(table: target, columns: [.init(name: "first", nativeType: "integer", nullable: false, primaryKeyPosition: 1),
            .init(name: "é", nativeType: "integer", nullable: false, primaryKeyPosition: 2)], columnState: .available, relationshipState: .available))
        return (model, edge)
    }

    @Test func proposedForeignKeyRetainsExactOrderedMappingAndLocalDeclaration() throws {
        let (model, edge) = fixture()
        let action = ERStructureAction.createForeignKey(edge)
        try action.validate(in: model)
        let key = try #require(action.initialDraft?.keys?.first)
        #expect(key.name.isEmpty && key.kind == "foreign" && key.action == "add")
        #expect(key.columns?.map { Data($0.utf8) } == [Data("e\u{301}".utf8), Data("second".utf8)])
        #expect(key.referenceColumns?.map { Data($0.utf8) } == [Data("first".utf8), Data("é".utf8)])
        #expect(key.reference?.table == "parent" && !action.initialDraft!.valid)
        #expect(model.relationships.count == 1 && model.relationships.first?.logicalID == edge.logicalID)
    }
    @Test(arguments: [DatabaseEngine.postgresql, .mysql])
    func sameProfileCrossSchemaMappingPreservesQualifiedReference(engine: DatabaseEngine) throws {
        let (model, edge) = fixture(targetSchema: "other_database", engine: engine)
        try ERStructureAction.createForeignKey(edge).validate(in: model)
        #expect(ERStructureAction.createForeignKey(edge).initialDraft?.keys?.first?.reference?.schema == "other_database")
    }
    @Test func crossProfileAndUnprovenLinksHaveConcreteReasons() {
        let (cross, external) = fixture(targetProfile: UUID())
        do { try ERStructureAction.createForeignKey(external).validate(in: cross); Issue.record("Cross-profile FK was admitted") }
        catch { #expect(error.localizedDescription.contains("same captured saved profile")) }
        for (notice, kind) in [("Metadata stale", "table"), (nil, "view")] {
            let (model, edge) = fixture(notice: notice, targetKind: kind)
            #expect(throws: ERDiagramFailure.self) { try ERStructureAction.createForeignKey(edge).validate(in: model) }
        }
    }
    @Test func canonicallyEquivalentColumnNamesNeverSatisfyTheExactMapping() {
        let (model, edge) = fixture()
        model.setMetadata(.init(table: edge.source, columns: [.init(name: "é", nativeType: "integer", nullable: true, primaryKeyPosition: nil),
            .init(name: "second", nativeType: "integer", nullable: true, primaryKeyPosition: nil)], columnState: .available, relationshipState: .available))
        #expect(throws: ERDiagramFailure.self) { try ERStructureAction.createForeignKey(edge).validate(in: model) }
    }
    @Test(arguments: ["source", "sourceCard", "targetCard", "rebind", "canonical"])
    func retiredOwnershipNeverMatchesARecreatedIdentifier(change: String) throws {
        let (model, edge) = fixture()
        let source = try #require(model.source(edge.source.profileID))
        let invocation = ERStructureInvocation(documentID: UUID(), source: source,
            context: .init(profileID: source.profileID, sessionID: "synthetic", serviceGeneration: UUID(), settingsRevision: UUID(), engine: source.engine, database: source.database),
            action: .createForeignKey(edge), model: model)
        let profile = SavedConnection(id: source.profileID, name: "Synthetic", settings: .init(host: "synthetic.invalid", port: 5432,
            database: "synthetic", user: "fixture", password: "", sslMode: "disable"))
        #expect(invocation.bindingLifetimesAreCurrent(in: model))
        switch change {
        case "source":
            model.removeSource(source.profileID); #expect(model.bindSource(profile))
            model.add(edge.source); model.add(edge.target)
        case "sourceCard": model.remove(edge.source); model.add(edge.source)
        case "targetCard": model.remove(edge.target); model.add(edge.target)
        case "rebind":
            let replacement = ERTableID(profileID: source.profileID, schema: edge.source.schema, name: "replacement")
            try model.rebind(edge.source, to: replacement, profile: profile)
            try model.rebind(replacement, to: edge.source, profile: profile)
        default:
            let replacement = ERTableID(profileID: source.profileID, schema: edge.source.schema, name: "canonical")
            model.adoptCanonicalIdentity(edge.source, resolved: replacement)
            model.adoptCanonicalIdentity(replacement, resolved: edge.source)
        }
        #expect(model.stored.tables.contains(edge.source) && model.stored.tables.contains(edge.target))
        #expect(!invocation.bindingLifetimesAreCurrent(in: model))
    }
    @Test func metadataAndCosmeticLabelsKeepOwnershipLifetimes() throws {
        let (model, edge) = fixture()
        let source = try #require(model.source(edge.source.profileID))
        let invocation = ERStructureInvocation(documentID: UUID(), source: source,
            context: .init(profileID: source.profileID, sessionID: "synthetic", serviceGeneration: UUID(), settingsRevision: UUID(), engine: source.engine, database: source.database),
            action: .edit(edge.source), model: model)
        let relabeled = SavedConnection(id: source.profileID, name: "New cosmetic label", settings: .init(host: "synthetic.invalid", port: 5432,
            database: "synthetic", user: "fixture", password: "", sslMode: "disable"))
        #expect(model.bindSource(relabeled))
        model.invalidateSource(source.profileID, reason: "Metadata changed")
        model.beginLoad(profileID: source.profileID)
        model.setMetadata(.init(table: edge.source, columnState: .available, relationshipState: .available))
        #expect(invocation.bindingLifetimesAreCurrent(in: model))
    }
    @Test func acknowledgedRenameCannotReviveTheRetiredDestinationCard() throws {
        let (model, edge) = fixture()
        let source = try #require(model.source(edge.source.profileID))
        let retired = ERStructureInvocation(documentID: UUID(), source: source,
            context: .init(profileID: source.profileID, sessionID: "synthetic", serviceGeneration: UUID(), settingsRevision: UUID(), engine: source.engine, database: source.database),
            action: .edit(edge.target), model: model)
        model.remove(edge.target)
        let plan = StructurePlan(id: "plan", baselineId: "baseline", digest: String(repeating: "a", count: 64),
            target: .init(schema: edge.source.schema, table: edge.source.name, create: false), sql: ["synthetic rename"], risks: [],
            resultTarget: .init(schema: edge.target.schema, table: edge.target.name, create: false))
        let review = TableStructureExecutionReview(outcome: .init(executionId: "execution", planId: plan.id, state: "applied", steps: [.init(state: "applied")]),
            plan: plan, draft: .init(columns: [], renameTable: edge.target.name))
        model.acceptStructureResult(review, profileID: source.profileID, addCreatedTable: false)
        #expect(model.stored.tables.contains(edge.target) && !retired.bindingLifetimesAreCurrent(in: model))
    }
    @Test(arguments: ["applied", "partiallyApplied", "outcomeUnknown"])
    func onlyCompletedRenamesMoveExactCardIdentityAndPreservePresentation(state: String) {
        let (model, edge) = fixture()
        model.move(edge.source, to: .init(x: 117, y: -43)); model.toggleCollapse(edge.source); model.select(edge.source)
        let source = model.source(edge.source.profileID)!
        let invocation = ERStructureInvocation(documentID: UUID(), source: source,
            context: .init(profileID: source.profileID, sessionID: "synthetic", serviceGeneration: UUID(), settingsRevision: UUID(), engine: source.engine, database: source.database),
            action: .edit(edge.source), model: model)
        let renamed = ERTableID(profileID: edge.source.profileID, schema: edge.source.schema, name: "renamed")
        let plan = StructurePlan(id: "plan", baselineId: "baseline", digest: String(repeating: "a", count: 64),
            target: .init(schema: edge.source.schema, table: edge.source.name, create: false), sql: ["synthetic rename", "synthetic follow-up"], risks: [],
            resultTarget: .init(schema: renamed.schema, table: renamed.name, create: false))
        let review = TableStructureExecutionReview(outcome: .init(executionId: "execution", planId: plan.id, state: state,
            steps: state == "partiallyApplied" ? [.init(state: "applied"), .init(state: "notStarted")] : [.init(state: state == "outcomeUnknown" ? "unknown" : "applied"), .init(state: state == "outcomeUnknown" ? "unknown" : "applied")]), plan: plan, draft: .init(columns: [], renameTable: renamed.name))
        invocation.acknowledge(review)
        model.acceptStructureResult(review, profileID: edge.source.profileID, addCreatedTable: false)
        let expected = state == "applied" ? renamed : edge.source
        #expect(model.stored.tables.contains(expected) && model.stored.collapsed.contains(expected) && model.stored.selected == expected)
        #expect(model.stored.placements.first { $0.table == expected }?.point == .init(x: 117, y: -43))
        #expect(model.stored.placements.first { $0.table == expected }?.manual == true)
        #expect(invocation.bindingLifetimesAreCurrent(in: model))
    }
}
