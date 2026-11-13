import Foundation

extension ApplicationWorkspace {
    func prepareERStructure(_ document: SQLDocument, action: ERStructureAction) throws -> ERStructureInvocation {
        guard canStartOperation(document), let model = document.erDiagramModel, model.stored.isValid,
              document.profileID == model.stored.profileID, canStartERSource(action.profileID),
              let source = model.source(action.profileID),
              let profile = library.savedConnections.first(where: { $0.id == action.profileID }), source.matches(profile) else {
            throw ERDiagramFailure("The original diagram source is missing, changed or unconfirmed. Review its exact binding before editing structure.")
        }
        try action.validate(in: model)
        guard let context = erDiagramContext(model, profileID: action.profileID) else {
            throw ERDiagramFailure("Connect this exact saved profile explicitly before editing its database structure.")
        }
        if case .createForeignKey = action, model.sourceState(action.profileID).context != context {
            throw ERDiagramFailure("Build both exact endpoints on this connected source before proposing a database foreign key.")
        }
        let node = CatalogNode(profileID: action.profileID, name: action.table?.name ?? action.schema,
            kind: action.createsTable ? .schema : .object, schema: action.schema,
            object: action.table?.name ?? "", objectKind: action.createsTable ? "" : "table", engine: source.engine)
        guard structureEditor == nil, canEditTableStructure(node) else {
            throw ERDiagramFailure("Close the current structure draft or finish the active profile operation before editing this table.")
        }
        return .init(documentID: document.id, source: source, context: context, action: action, model: model)
    }

    func erStructureUnavailableReason(_ document: SQLDocument, action: ERStructureAction) -> String? {
        do { _ = try prepareERStructure(document, action: action); return nil }
        catch { return error.localizedDescription }
    }

    func erStructureInvocationIsCurrent(_ invocation: ERStructureInvocation, document: SQLDocument, model: ERDiagramModel) -> Bool {
        guard document.id == invocation.documentID, invocation.bindingLifetimesAreCurrent(in: model), erDiagramBindingIsCurrent(document, model: model, context: invocation.context),
              model.source(invocation.source.profileID)?.fingerprint == invocation.source.fingerprint,
              let profile = library.savedConnections.first(where: { $0.id == invocation.source.profileID }), invocation.source.matches(profile) else { return false }
        if case .createForeignKey(let edge) = invocation.action, invocation.acknowledgedTable == nil {
            return model.stored.tables.contains(edge.target) && model.relationships.contains {
                $0.id == edge.id && $0.source == edge.source && $0.target == edge.target && $0.key.sameMapping(as: edge.key)
            }
        }
        return true
    }

    func openERStructure(_ document: SQLDocument, action: ERStructureAction) async {
        do {
            let invocation = try prepareERStructure(document, action: action)
            guard let model = document.erDiagramModel else { return }
            let node = CatalogNode(profileID: action.profileID, name: action.table?.name ?? action.schema,
                kind: action.createsTable ? .schema : .object, schema: action.schema,
                object: action.table?.name ?? "", objectKind: action.createsTable ? "" : "table", engine: invocation.source.engine)
            await openTableStructure(node, create: action.createsTable, bindingIsCurrent: { [weak self, weak document, weak model] in
                guard let self, let document, let model else { return false }
                return self.erStructureInvocationIsCurrent(invocation, document: document, model: model)
            }, initialDraft: action.initialDraft, changed: { [weak self] review in
                invocation.acknowledge(review)
                Task { @MainActor [weak self] in await self?.refreshERStructureResult(invocation, review: review) }
            })
        } catch { document.erDiagramModel?.notice = error.localizedDescription }
    }

    /// Acknowledgements trigger catalog reads only on already-connected sources.
    /// Unknown/in-progress evidence never becomes an automatic replay or reconcile.
    func refreshERStructureResult(_ invocation: ERStructureInvocation, review: TableStructureExecutionReview) async {
        let id = invocation.source.profileID
        guard !["outcomeUnknown", "applying"].contains(review.outcome.state) else {
            for document in documents {
                guard let model = document.erDiagramModel, model.source(id)?.fingerprint == invocation.source.fingerprint else { continue }
                stopERDiagramSource(model, profileID: id, reason: "Structure execution has no terminal acknowledgement. Inspect the database and reconcile explicitly before another edit; diagram facts remain stale.")
            }
            return
        }
        // Capture the owners before the first read; unrelated navigation cannot redirect a refresh.
        let owners = documents.compactMap { document -> (SQLDocument, ERDiagramModel, UInt64)? in
            guard let model = document.erDiagramModel, model.source(id)?.fingerprint == invocation.source.fingerprint,
                  document.id != invocation.documentID || invocation.bindingLifetimesAreCurrent(in: model),
                  document.id == invocation.documentID || model.metadata.keys.contains(where: { $0.profileID == id }) else { return nil }
            return (document, model, model.sourceState(id).generation)
        }
        for (document, model, generation) in owners {
            guard !Task.isCancelled, canStartOperation(document), model.sourceState(id).generation == generation,
                  erDiagramBindingIsCurrent(document, model: model, context: invocation.context),
                  model.source(id)?.fingerprint == invocation.source.fingerprint,
                  document.id != invocation.documentID || invocation.bindingLifetimesAreCurrent(in: model) else { continue }
            if let pending = model.sourceState(id).request, !pending.finished {
                // Submitted metadata must receive its terminal reply before a new read.
                if let task = pending.task { _ = await task.result }
                while !pending.finished, model.sourceState(id).request === pending, !Task.isCancelled,
                      model.sourceState(id).generation == generation,
                      erDiagramBindingIsCurrent(document, model: model, context: invocation.context) {
                    await Task.yield()
                }
            }
            guard !Task.isCancelled, canStartOperation(document), model.sourceState(id).generation == generation,
                  erDiagramBindingIsCurrent(document, model: model, context: invocation.context),
                  model.source(id)?.fingerprint == invocation.source.fingerprint,
                  document.id != invocation.documentID || invocation.bindingLifetimesAreCurrent(in: model) else { continue }
            model.acceptStructureResult(review, profileID: id, addCreatedTable: document.id == invocation.documentID)
            await buildERDiagram(document, profileID: id)
            guard erDiagramBindingIsCurrent(document, model: model, context: invocation.context) else { continue }
            if review.outcome.state == "partiallyApplied" {
                model.notice = "Only part of the reviewed structure change was acknowledged. Diagram metadata was refreshed; retain the execution report and review the remaining changes explicitly."
            }
        }
    }
}
