import SwiftUI

struct TableStructureAdvancedKindDetails: View {
    let support: StructureAdvancedKindSupport
    var body: some View {
        GroupBox("Advanced table operation support") {
            VStack(alignment: .leading, spacing: 6) {
                Text(support.kinds.map(kindLabel).joined(separator: ", ") + " · " + String(support.familyCount) + " connected table(s)").font(.caption).textSelection(.enabled)
                Text(scope).font(.caption).foregroundStyle(.orange)
                if let relations = support.relations {
                    ForEach(Array(relations.enumerated()), id: \.offset) { _, relation in
                        DisclosureGroup(relation.target.schema + "." + relation.target.table + " · " + (relation.kind == "partitionedTable" ? "Partitioned table" : "Table") + " · " + relation.persistence) {
                            relationDetails(relation)
                        }
                    }
                }
                ForEach(support.operations, id: \.kind) { operation in
                    Text(operationLabel(operation.kind) + ": " + operation.reason).font(.caption).appSecondaryText().textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func kindLabel(_ kind: String) -> String {
        ["inheritanceParent": "Inheritance parent", "inheritanceChild": "Inheritance child", "partitionParent": "Partition parent", "partitionMember": "Partition member", "rowSecurity": "Row security", "typed": "Typed table", "unlogged": "Unlogged", "mySQLPartitions": "MySQL partitions", "myISAM": "MyISAM", "mariaDBPartitions": "MariaDB partitions", "mariaDBMyISAM": "MariaDB MyISAM", "mariaDBAria": "MariaDB Aria", "mariaDBSystemVersioned": "MariaDB system-versioned table"][kind] ?? kind
    }
    private func operationLabel(_ kind: String) -> String {
        ["renameTable": "Rename table", "renameColumn": "Rename column", "addColumn": "Append column", "dropColumn": "Drop column", "default": "Default", "nullable": "Nullability", "type": "Type", "index": "Index", "key": "Primary/unique key", "foreignKey": "Foreign key", "generation": "Generation/identity", "reconstruction": "Backfill and physical layout", "hierarchy": "Hierarchy"][kind] ?? kind
    }
    private var scope: String {
        switch support.scope {
        case "only": "Local ALTER operations use ONLY. Parent index/key operations disclose every affected native descendant before Apply."
        case "operation": "Scope follows each operation. Parent column, index and key statements list every affected descendant in Preview; local defaults use ONLY."
        default: support.kinds.contains(where: { $0.hasPrefix("mariaDB") }) ? "MariaDB DDL implicitly commits. MyISAM and Aria row writes are nontransactional." : "MySQL DDL implicitly commits. MyISAM row writes are nontransactional."
        }
    }
    @ViewBuilder private func relationDetails(_ relation: StructureAdvancedRelationFact) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if relation.storageEngine == nil {
                Text("RLS: " + (relation.rowSecurity ? "enabled" : "disabled") + " · FORCE: " + (relation.forceRowSecurity ? "enabled" : "disabled")).font(.caption).textSelection(.enabled)
            }
            if let binding = relation.typeBinding { Text("Typed table: " + binding.schema + "." + binding.name).font(.caption).textSelection(.enabled) }
            if let engine = relation.storageEngine { Text("Storage engine: " + engine).font(.caption).textSelection(.enabled) }
            ForEach(Array(relation.parents.enumerated()), id: \.offset) { _, parent in
                Text("Parent: " + parent.schema + "." + parent.table).font(.caption).textSelection(.enabled)
            }
            ForEach(Array(relation.policies.enumerated()), id: \.offset) { _, policy in
                Text("Policy " + policy.name + " · " + policy.command.uppercased() + " · " + (policy.permissive ? "permissive" : "restrictive") + " · roles: " + policy.roles.joined(separator: ", ")).font(.caption).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
