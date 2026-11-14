import Foundation

@MainActor
struct ERDiagramExportOwner {
    weak var document: SQLDocument?
    weak var graph: ERDiagramModel?
    let model: ERDiagramExportModel
    var sourceProfileIDs: Set<UUID> = []
    var sourceBindings: [UUID: Data] = [:]
}

/// Selection and geometry are frozen when the export command is invoked,
/// before the destination panel can suspend the caller.
@MainActor
struct ERDiagramExportInvocation {
    let snapshot: ERDiagramExportSnapshot
    let graph: ERDiagramModel
    let generation: UInt64
    let profileID: UUID
    let engine: DatabaseEngine
    let database: Data
    let sourceBindings: [UUID: Data]
}

extension ApplicationWorkspace {
    func makeERDiagramExport(_ document: SQLDocument) -> ERDiagramExportModel? {
        if let graph = document.erDiagramModel, let existing = erDiagramExports[document.id], existing.document === document,
           existing.graph === graph, existing.model.profileID == graph.stored.profileID { return existing.model }
        guard canStartOperation(document), let graph = document.erDiagramModel,
              erExportDocumentIsCurrent(document, model: graph) else { return nil }
        if let existing = erDiagramExports[document.id] { Task { await existing.model.close() } }
        let profileID = graph.stored.profileID
        let model = ERDiagramExportModel(documentID: document.id, profileID: profileID,
            startAllowed: { [weak self, weak document] in
                guard let self, let document else { return false }
                return self.canStartOperation(document)
            }, available: { [weak self, weak document, weak graph] in
                guard let self, let document, let graph else { return false }
                return self.erExportDocumentIsCurrent(document, model: graph) && graph.stored.profileID == profileID
            })
        erDiagramExports[document.id] = ERDiagramExportOwner(document: document, graph: graph, model: model,
            sourceProfileIDs: Set(graph.stored.tables.map(\.profileID) + graph.relationships.flatMap { [$0.source.profileID, $0.target.profileID] }))
        return model
    }

    private func erExportSourceBindings(_ graph: ERDiagramModel, owners: Set<UUID>, profiles: [SavedConnection]? = nil) -> [UUID: Data] {
        let profiles = profiles ?? library.savedConnections
        return Dictionary(uniqueKeysWithValues: owners.map { id in
            let original = graph.source(id)?.fingerprint ?? (id == graph.stored.profileID ? "legacy:" + graph.stored.engine.rawValue + ":" + Data(graph.stored.database.utf8).base64EncodedString() : "external")
            let current = profiles.first(where: { $0.id == id }).map(LogicalRelationshipEndpoint.fingerprint) ?? "missing"
            return (id, Data((original + "\n" + current + "\n" + String(graph.ownerRevisions[id, default: 0])).utf8))
        })
    }

    func prepareERDiagramExport(_ document: SQLDocument, scope: ERDiagramExportScope) throws -> ERDiagramExportInvocation {
        guard canStartOperation(document), let graph = document.erDiagramModel else { throw ERDiagramExportFailure.invalid }
        let snapshot = try erDiagramExportSnapshot(document, scope: scope)
        let owners = Set(snapshot.tables.map(\.profileID) + snapshot.relationships.flatMap { [$0.source.profileID, $0.target.profileID] })
        guard owners.allSatisfy({ canStartERSource($0) }) else { throw ERDiagramExportFailure.invalid }
        let bindings = erExportSourceBindings(graph, owners: owners)
        return ERDiagramExportInvocation(snapshot: snapshot, graph: graph,
            generation: graph.generation, profileID: graph.stored.profileID, engine: graph.stored.engine,
            database: Data(graph.stored.database.utf8), sourceBindings: bindings)
    }

    func erDiagramExportSnapshot(_ document: SQLDocument, scope: ERDiagramExportScope) throws -> ERDiagramExportSnapshot {
        guard let graph = document.erDiagramModel, erExportDocumentIsCurrent(document, model: graph) else { throw ERDiagramExportFailure.invalid }
        let tables: [ERTableID]
        switch scope {
        case .diagram: tables = graph.stored.tables
        case .selectedTable:
            guard let selected = graph.stored.selected, graph.stored.tables.contains(selected) else { throw ERDiagramExportFailure.empty }
            tables = [selected]
        }
        let selected = Set(tables)
        let edges = graph.relationships.filter { selected.contains($0.source) || selected.contains($0.target) }
        let descriptions = edges.map { edge in
            ERDiagramExportSnapshot.RelationshipDescription(id: edge.id, kind: edge.kind == .logical ? .logical : .declared,
                targetProfileName: edge.targetProfileName, sourceProfileName: edge.sourceProfileName, validationNotice: edge.validationNotice)
        }
        let ownerIDs = Set(tables.map(\.profileID) + edges.flatMap { [$0.source.profileID, $0.target.profileID] })
        let labels = Dictionary(uniqueKeysWithValues: ownerIDs.map { id in
            (id, graph.source(id)?.name ?? library.savedConnections.first(where: { $0.id == id })?.name ?? "Missing profile " + id.uuidString)
        })
        let snapshot = ERDiagramExportSnapshot(title: document.title,
            profileName: ownerIDs.count == 1 ? (labels.values.first ?? "Missing connection") : "\(ownerIDs.count) profiles",
            profileNames: labels, scope: scope, tables: tables, metadata: graph.metadata.filter { selected.contains($0.key) },
            placements: graph.stored.placements.filter { selected.contains($0.table) },
            collapsed: Set(graph.stored.collapsed).intersection(selected), relationships: edges,
            relationshipDescriptions: descriptions, notice: graph.displayNotice)
        try snapshot.validate()
        return snapshot
    }

    func exportERDiagram(_ document: SQLDocument, scope: ERDiagramExportScope, format: ERDiagramExportFormat,
                         options: ERDiagramExportOptions, to destination: URL,
                         publicationHook: ERDiagramExportPublicationHook? = nil) async {
        guard let model = makeERDiagramExport(document) else { return }
        do {
            let invocation = try prepareERDiagramExport(document, scope: scope)
            await exportERDiagram(document, invocation: invocation, format: format, options: options, to: destination, publicationHook: publicationHook)
        } catch { model.report(error) }
    }

    func exportERDiagram(_ document: SQLDocument, invocation: ERDiagramExportInvocation, format: ERDiagramExportFormat,
                         options: ERDiagramExportOptions, to destination: URL,
                         publicationHook: ERDiagramExportPublicationHook? = nil) async {
        guard let model = makeERDiagramExport(document), model.canStart,
              document.erDiagramModel === invocation.graph else { return }
        let graph = invocation.graph
        let owners = Set(invocation.sourceBindings.keys)
        // Recheck start gates after the destination panel; running exports keep durable ownership.
        guard owners.allSatisfy({ canStartERSource($0) }) else { return }
        erDiagramExports[document.id]?.sourceProfileIDs = owners
        erDiagramExports[document.id]?.sourceBindings = invocation.sourceBindings
        await model.export(invocation.snapshot, format: format, options: options, to: destination, sourceIsCurrent: { [weak self, weak document, weak graph] in
                guard let self, let document, let graph else { return false }
                return self.erExportDocumentIsCurrent(document, model: graph) && graph.generation == invocation.generation &&
                    graph.stored.profileID == invocation.profileID &&
                    (!owners.contains(graph.stored.profileID) || (graph.stored.engine == invocation.engine && Data(graph.stored.database.utf8) == invocation.database)) &&
                    invocation.snapshot.tables.allSatisfy { graph.stored.tables.contains($0) } &&
                    self.erExportSourceBindings(graph, owners: owners) == invocation.sourceBindings
            }, publicationHook: publicationHook)
    }

    func retireChangedERDiagramExports(profiles: [SavedConnection]? = nil) {
        for (id, owner) in erDiagramExports {
            guard let graph = owner.graph, !owner.sourceBindings.isEmpty,
                  erExportSourceBindings(graph, owners: owner.sourceProfileIDs, profiles: profiles) != owner.sourceBindings else { continue }
            owner.model.preventNewExports()
            Task {
                await owner.model.close()
                if erDiagramExports[id]?.model === owner.model { erDiagramExports[id] = nil }
            }
        }
    }

    func retireERDiagramSourceOwners(profileID: UUID) {
        for document in documents {
            guard let graph = document.erDiagramModel,
                  graph.ownsSource(profileID) || graph.relationships.contains(where: { $0.source.profileID == profileID || $0.target.profileID == profileID }) else { continue }
            graph.ownerRevisions[profileID, default: 0] &+= 1
        }
    }

    func closeERDiagramExports(documentIDs: Set<UUID>? = nil, profileID: UUID? = nil) async {
        let owners = erDiagramExports.filter { key, owner in
            (documentIDs == nil || documentIDs!.contains(key)) && (profileID == nil || owner.sourceProfileIDs.contains(profileID!))
        }
        for (id, owner) in owners {
            await owner.model.close()
            if erDiagramExports[id]?.model === owner.model { erDiagramExports[id] = nil }
        }
    }
}
