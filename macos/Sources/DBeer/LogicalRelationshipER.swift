import Foundation

/// Persisted confirmed intent remains visible even before a session validates
/// either endpoint. It never becomes evidence of a declared server constraint.
enum LogicalRelationshipER {
    static func edges(_ relationships: [LogicalRelationship], tables: [ERTableID], metadata: [ERTableID: ERTableMetadata],
                      profiles: [SavedConnection], metadataIsCurrent: Bool, currentSources: Set<UUID>? = nil) -> [ERRelationship] {
        let selected = Set(tables)
        let currentProfiles = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let identities = currentProfiles.mapValues(LogicalRelationshipEndpoint.fingerprint)
        let columns = metadata.mapValues { facts -> [Data: Data] in
            guard facts.columnState.isAvailable, Set(facts.columns.map { Data($0.name.utf8) }).count == facts.columns.count else { return [:] }
            return Dictionary(facts.columns.map { (Data($0.name.utf8), Data($0.nativeType.utf8)) }, uniquingKeysWith: { first, _ in first })
        }
        return relationships.filter { $0.isValid && (selected.contains($0.source.tableID) || selected.contains($0.target.tableID)) }.map { relationship in
            let sourceProfile = currentProfiles[relationship.source.profileID]
            let targetProfile = currentProfiles[relationship.target.profileID]
            let notice: String?
            if identities[relationship.source.profileID] != relationship.source.profileFingerprint || identities[relationship.target.profileID] != relationship.target.profileFingerprint {
                notice = "The original profile is missing or changed. Edit and validate the local mapping before use."
            } else if !metadataIsCurrent || currentSources.map({ !$0.contains(relationship.source.profileID) || !$0.contains(relationship.target.profileID) }) == true {
                notice = "Saved user-confirmed mapping. Current-session column metadata is not verified; navigation validates it again."
            } else if !selected.contains(relationship.source.tableID) || !selected.contains(relationship.target.tableID) {
                notice = "An endpoint is outside this diagram. Its current metadata is not loaded; navigation validates both endpoints again."
            } else if !relationship.columns.allSatisfy({ pair in
                columns[relationship.source.tableID]?[Data(pair.source.utf8)] == Data(pair.sourceType.utf8) &&
                columns[relationship.target.tableID]?[Data(pair.target.utf8)] == Data(pair.targetType.utf8)
            }) {
                notice = "Mapped columns are missing, changed or not currently verified. Edit and validate before use."
            } else { notice = nil }
            return .init(source: relationship.source.tableID, key: relationship.key, logicalID: relationship.id,
                targetProfileID: relationship.target.profileID,
                targetProfileName: targetProfile?.name ?? "Missing profile " + relationship.target.profileID.uuidString,
                sourceProfileName: sourceProfile?.name ?? "Missing profile " + relationship.source.profileID.uuidString,
                validationNotice: notice)
        }
    }
}

@MainActor
private final class LogicalRelationshipERCache {
    var signature: Signature?
    var edges: [ERRelationship] = []
    struct Signature: Equatable {
        let library: UInt64
        let profiles: UInt64
        let metadata: UInt64
        let tables: [ERTableID]
        let current: Set<UUID>
    }
}

@MainActor
extension ApplicationWorkspace {
    func bindLogicalRelationships(to model: ERDiagramModel) {
        let cache = LogicalRelationshipERCache()
        model.localRelationships = { [weak self, weak model] in
            guard let self, let model else { return [] }
            let signature = LogicalRelationshipERCache.Signature(library: self.logicalRelationships.revision,
                profiles: self.logicalProfileRevision, metadata: model.logicalMetadataRevision, tables: model.stored.tables,
                current: Set(model.stored.tables.map(\.profileID)).filter { id in
                    guard let context = model.sourceState(id).context else { return false }
                    return self.erDiagramContext(model, profileID: id) == context
                })
            if cache.signature == signature { return cache.edges }
            cache.edges = LogicalRelationshipER.edges(self.logicalRelationships.relationships, tables: model.stored.tables,
                metadata: model.metadata, profiles: self.library.savedConnections,
                metadataIsCurrent: true, currentSources: signature.current)
            cache.signature = signature
            return cache.edges
        }
    }
    func openLogicalRelationshipEndpoint(_ edge: ERRelationship, target: Bool, from document: SQLDocument) async {
        guard let id = edge.logicalID, let relationship = logicalRelationships.relationship(id: id),
              logicalRelationshipProfilesMatch(relationship), canStartOperation(document) else { return }
        let endpoint = target ? relationship.target : relationship.source
        _ = await openData(.init(profileID: endpoint.profileID, name: endpoint.name, kind: .object,
            schema: endpoint.schema, object: endpoint.name, objectKind: endpoint.kind), inNewTab: true)
    }
}
