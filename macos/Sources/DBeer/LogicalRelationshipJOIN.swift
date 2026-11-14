import Foundation

/// Completion consumes only the confirmed library and already-loaded metadata.
/// It cannot connect, validate a suggestion or turn a local link into a constraint.
enum LogicalRelationshipJOIN {
    static func merge(_ context: SQLCompletionContext, relationships: [LogicalRelationship], profile: SavedConnection?, enabled: Bool) -> SQLCompletionContext {
        guard enabled, let profile, context.profileID == profile.id else { return context }
        var result = context
        for link in relationships where unavailableReason(link, context: context, profile: profile) == nil {
            guard let index = relationIndex(link.source, in: result.catalog), result.catalog[index].foreignKeys.count < 64 else { continue }
            result.catalog[index].foreignKeys.append(.init(name: link.name, targetSchema: link.target.schema, targetTable: link.target.name,
                columns: link.columns.map { .init(source: $0.source, target: $0.target) }, origin: "logical"))
        }
        return result
    }
    static func unavailableReason(_ link: LogicalRelationship, context: SQLCompletionContext, profile: SavedConnection?) -> String? {
        guard link.isValid else { return "The confirmed mapping is invalid. Edit and validate it again." }
        guard !link.isCrossProfile else { return "Cross-profile mappings navigate independent tabs; they cannot generate JOIN SQL." }
        guard let profile, context.profileID == profile.id, link.source.matches(profile), link.target.matches(profile) else {
            return "The original profile is missing or changed. Edit and validate the mapping again."
        }
        guard let sourceIndex = relationIndex(link.source, in: context.catalog), let targetIndex = relationIndex(link.target, in: context.catalog) else {
            return "Refresh the connected catalog to load both exact endpoints before JOIN completion."
        }
        let source = context.catalog[sourceIndex], target = context.catalog[targetIndex]
        for pair in link.columns {
            let sources = source.columnTypeEntries.filter { Data($0.name.utf8) == Data(pair.source.utf8) }
            let targets = target.columnTypeEntries.filter { Data($0.name.utf8) == Data(pair.target.utf8) }
            guard sources.count == 1, targets.count == 1, let a = sources.first, let b = targets.first,
                  source.columns.filter({ Data($0.utf8) == Data(pair.source.utf8) }).count == 1,
                  target.columns.filter({ Data($0.utf8) == Data(pair.target.utf8) }).count == 1,
                  Data(a.nativeType.utf8) == Data(pair.sourceType.utf8), Data(b.nativeType.utf8) == Data(pair.targetType.utf8),
                  let left = a.comparison, let right = b.comparison, left.isValid, right.isValid else {
                return "Mapped columns or exact comparison metadata are missing or changed. Refresh and validate the mapping again."
            }
            // SQLite target = +source removes source affinity while retaining
            // the actual target affinity/collation, like a captured bound value.
            if profile.engine == .sqlite { continue }
            guard left.kind != "unknown", left.kind == right.kind else {
                return "JOIN comparison is unproven for a mapped custom or unsupported type. Typed navigation remains available."
            }
            if left.kind == "text" {
                let compatibleBase = left.baseType == right.baseType || profile.engine == .postgresql &&
                    ["pg_catalog.text", "pg_catalog.varchar"].contains(left.baseType) && ["pg_catalog.text", "pg_catalog.varchar"].contains(right.baseType)
                guard compatibleBase, !left.charset.isEmpty, !left.collationName.isEmpty, !left.collationIdentity.isEmpty,
                      Data(left.charset.utf8) == Data(right.charset.utf8),
                      Data(left.collationSchema.utf8) == Data(right.collationSchema.utf8),
                      Data(left.collationName.utf8) == Data(right.collationName.utf8),
                      Data(left.collationIdentity.utf8) == Data(right.collationIdentity.utf8) else {
                    return "Text JOIN requires compatible built-in types and the same verified character set and collation. Typed navigation remains available."
                }
            } else {
                let supported: Set<String> = profile.engine == .postgresql
                    ? ["pg_catalog.int2", "pg_catalog.int4", "pg_catalog.int8", "pg_catalog.numeric", "pg_catalog.bool", "pg_catalog.uuid", "pg_catalog.bytea"]
                    : ["tinyint", "smallint", "mediumint", "int", "bigint", "decimal", "numeric", "bit", "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob"]
                guard Data(left.baseType.utf8) == Data(right.baseType.utf8), supported.contains(left.baseType) else {
                    return "JOIN equality is not proven for these native types. Typed navigation remains available."
                }
                // MySQL signedness, precision and binary width affect native
                // conversion; exact declarations avoid introducing SQL casts.
                if profile.engine.usesMySQLSyntax, Data(a.nativeType.utf8) != Data(b.nativeType.utf8) {
                    return profile.engine.displayName + " native JOIN columns require identical current declarations. Typed navigation remains available."
                }
            }
        }
        return nil
    }
    private static func relationIndex(_ endpoint: LogicalRelationshipEndpoint, in relations: [SQLCompletionRelation]) -> Int? {
        let indices = relations.indices.filter {
            Data(relations[$0].schema.utf8) == Data(endpoint.schema.utf8) && Data(relations[$0].name.utf8) == Data(endpoint.name.utf8) && relations[$0].kind == endpoint.kind
        }
        return indices.count == 1 ? indices.first : nil
    }
}

@MainActor
extension ApplicationWorkspace {
    func logicalCompletionContext(_ context: SQLCompletionContext, profile: SavedConnection?, capabilities: Set<String>, connected: Bool) -> SQLCompletionContext {
        LogicalRelationshipJOIN.merge(context, relationships: logicalRelationships.relationships, profile: profile,
            enabled: connected && capabilities.contains(CatalogColumnTypeEntry.capability))
    }
    func logicalRelationshipJOINNotice(_ link: LogicalRelationship) -> String {
        guard !link.isCrossProfile else { return "JOIN unavailable: cross-profile mappings navigate independent tabs." }
        guard let service = services[link.source.profileID], service.connectionState == .connected,
              service.capabilities.contains(CatalogColumnTypeEntry.capability) else {
            return "JOIN completion requires an explicitly connected profile and current exact comparison metadata."
        }
        return LogicalRelationshipJOIN.unavailableReason(link, context: completionContext(profileID: link.source.profileID),
            profile: library.savedConnections.first { $0.id == link.source.profileID }).map { "JOIN unavailable: " + $0 } ??
            "JOIN completion: local confirmed mapping; current types and comparison semantics match."
    }
}
