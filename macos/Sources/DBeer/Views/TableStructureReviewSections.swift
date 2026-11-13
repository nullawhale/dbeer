import SwiftUI

struct TableStructureBaselineDetails: View {
    let baseline: StructureBaseline
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Columns (\(baseline.columns.count))") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(baseline.columns.enumerated()), id: \.offset) { _, column in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(column.name + " · " + column.nativeType + (column.nullable ? " · NULL" : " · NOT NULL"))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text("Default: " + (column.defaultExpression ?? "not reported / no explicit default"))
                                .font(.caption).textSelection(.enabled)
                            if column.canModify != true { Text("Read-only column attributes").font(.caption).appSecondaryText() }
                        }
                    }
                }.padding(.leading, 8)
            }
            DisclosureGroup("Keys (\(baseline.keys?.count ?? 0)) and indexes (\(baseline.indexes?.count ?? 0))") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((baseline.keys ?? []).enumerated()), id: \.offset) { _, key in
                        DisclosureGroup(key.kind.capitalized + " key · " + key.name) {
                            StructureOrderedNamesSummary(title: "Source columns", names: key.columns)
                            if let reference = key.reference {
                                Text("Referenced schema/database: " + reference.schema).textSelection(.enabled)
                                Text("Referenced table: " + reference.table).textSelection(.enabled)
                                StructureOrderedNamesSummary(title: "Referenced columns", names: key.referenceColumns ?? [])
                                Text("ON UPDATE: " + (key.onUpdate ?? "not reported") + " · ON DELETE: " + (key.onDelete ?? "not reported"))
                                    .font(.caption).textSelection(.enabled)
                            }
                            if !key.supported { Text("Read-only: this key has unsupported attributes or incomplete metadata.").font(.caption).appSecondaryText() }
                        }
                    }
                    ForEach(Array((baseline.indexes ?? []).enumerated()), id: \.offset) { _, index in
                        DisclosureGroup((index.unique ? "Unique index · " : "Index · ") + index.name) {
                            if let definition = index.definition { TableStructureIndexDefinitionSummary(definition: definition) }
                            else { StructureOrderedNamesSummary(title: "Columns", names: index.columns) }
                            if let owner = index.owner { Text("Owned by key: " + owner + ". Change the key as one operation.").font(.caption).appSecondaryText() }
                            if !index.supported { Text("Read-only: this index has unsupported attributes or incomplete metadata.").font(.caption).appSecondaryText() }
                        }
                    }
                    if (baseline.keys ?? []).isEmpty && (baseline.indexes ?? []).isEmpty {
                        Text("No key/index facts were reported for this baseline.").font(.caption).appSecondaryText()
                    }
                }.padding(.leading, 8)
            }
            ForEach(Array(baseline.limitations.enumerated()), id: \.offset) { _, limitation in
                Text(limitation).font(.caption).appSecondaryText().textSelection(.enabled)
            }
        }
    }
}

struct TableStructureExecutionReportView: View {
    let review: TableStructureExecutionReview
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Execution: " + StructureReviewPresentation.state(review.outcome.state)).font(.headline).textSelection(.enabled)
            Text("Reviewed target: " + review.plan.target.schema + " · " + review.plan.target.table).font(.caption).textSelection(.enabled)
            if let result = review.plan.resultTarget {
                Text("Intended resulting target: " + result.schema + " · " + result.table).font(.caption).textSelection(.enabled)
            }
            DisclosureGroup("Intended changes retained from this review") { TableStructureDraftSummary(draft: review.draft) }
            ForEach(review.plan.sql.indices, id: \.self) { i in
                step(i)
            }
            if review.outcome.steps.count > review.plan.sql.count {
                Text("Additional outcome evidence is not mapped to reviewed SQL.").foregroundStyle(.orange)
            }
            if let error = review.outcome.refreshError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let observed = review.outcome.observed {
                DisclosureGroup("Observed structure after this execution") { TableStructureBaselineDetails(baseline: observed) }
            } else {
                Text("No observed structure is available for this execution. Reconcile explicitly before another edit.").font(.caption).appSecondaryText()
            }
            Text("Stop, Discard and closing a draft do not undo acknowledged DDL. Reconciliation reads current structure and does not change an earlier unknown outcome.")
                .font(.caption).appSecondaryText()
        }
    }
    private func step(_ i: Int) -> some View {
        let evidence = review.outcome.steps.indices.contains(i) ? review.outcome.steps[i] : nil
        return GroupBox {
            VStack(alignment: .leading, spacing: 5) {
                Text("Step \(i + 1) · " + (evidence.map { StructureReviewPresentation.state($0.state) } ?? "No acknowledgement available"))
                    .font(.subheadline).textSelection(.enabled)
                if let message = evidence?.message { Text(message).font(.caption).textSelection(.enabled) }
                ScrollView([.horizontal, .vertical]) {
                    Text(review.plan.sql[i]).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 35, maxHeight: 110)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TableStructureDraftSummary: View {
    let draft: StructureDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = draft.renameTable { Text("Rename table to: " + name).textSelection(.enabled) }
            ForEach(Array(draft.columns.enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: 2) {
                    Text("New column: " + column.name).font(.subheadline)
                    Text(StructureReviewPresentation.type(column.type) + (column.nullable ? " · NULL" : " · NOT NULL"))
                    Text(StructureReviewPresentation.defaultValue(column.default))
                    if let generated = column.generated { Text(StructureReviewPresentation.generation(generated)) }
                    if let identity = column.identity { Text(StructureReviewPresentation.identity(identity)) }
                }.textSelection(.enabled)
            }
            ForEach(Array((draft.changes ?? []).enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Change column: " + change.name).font(.subheadline)
                    if let name = change.renameTo { Text("Rename to: " + name) }
                    if let generated = change.generated { Text(StructureReviewPresentation.generation(generated)) }
                    if let identity = change.identity { Text(StructureReviewPresentation.identity(identity)) }
                    Text(change.type.map(StructureReviewPresentation.type) ?? "Keep existing type")
                    Text(change.nullable.map { $0 ? "Allow NULL" : "Require NOT NULL" } ?? "Keep existing nullability")
                    Text(StructureReviewPresentation.defaultValue(change.default))
                }.textSelection(.enabled)
            }
            ForEach(Array((draft.indexes ?? []).enumerated()), id: \.offset) { _, index in
                VStack(alignment: .leading, spacing: 2) {
                    Text(index.action.capitalized + " index: " + index.name + (index.unique == true ? " · unique" : "")).font(.subheadline)
                    if let definition = index.definition { TableStructureIndexDefinitionSummary(definition: definition) }
                    else if let columns = index.columns { StructureOrderedNamesSummary(title: "Columns", names: columns) }
                }.textSelection(.enabled)
            }
            ForEach(Array((draft.keys ?? []).enumerated()), id: \.offset) { _, key in
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.action.capitalized + " " + key.kind + " key: " + key.name).font(.subheadline)
                    if let columns = key.columns { StructureOrderedNamesSummary(title: "Source columns", names: columns) }
                    if let reference = key.reference {
                        Text("Referenced schema/database: " + reference.schema)
                        Text("Referenced table: " + reference.table)
                        StructureOrderedNamesSummary(title: "Referenced columns", names: key.referenceColumns ?? [])
                        Text("ON UPDATE: " + (key.onUpdate ?? "not supplied") + " · ON DELETE: " + (key.onDelete ?? "not supplied"))
                    }
                }.textSelection(.enabled)
            }
        }.font(.caption).padding(.leading, 8)
    }
}

private struct StructureOrderedNamesSummary: View {
    let title: String
    let names: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title + " (in order)").font(.caption).appSecondaryText()
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                Text("\(i + 1). " + name).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
}

private enum StructureReviewPresentation {
    static func state(_ state: String) -> String {
        switch state {
        case "outcomeUnknown", "unknown": "Outcome unknown"
        case "partiallyApplied": "Partially applied"
        case "notStarted": "Not started"
        case "rolledBack": "Rolled back"
        default: state.capitalized
        }
    }
    static func type(_ type: StructureDataType) -> String {
        switch type.kind {
        case "reference": (type.reference?.schema ?? "") + "." + (type.reference?.name ?? "")
        case "varchar": "varchar · length \(type.length ?? 0)"
        case "numeric": "numeric · precision \(type.precision ?? 0) · scale \(type.scale ?? 0)"
        default: type.kind
        }
    }
    static func generation(_ value: StructureGeneration) -> String {
        value.storage == "none" ? "Remove generation" : value.storage.capitalized + " generation: " + (value.expression ?? "")
    }
    static func identity(_ value: StructureIdentity) -> String {
        let settings = [("start", value.start), ("increment", value.increment), ("minimum", value.minimum), ("maximum", value.maximum), ("cache", value.cache)]
            .compactMap { name, number in number.map { name + "=" + $0 } }
        return "Identity: " + value.kind + (settings.isEmpty ? "" : " · " + settings.joined(separator: ", ")) + (value.cycle.map { $0 ? " · CYCLE" : " · NO CYCLE" } ?? "")
    }
    static func defaultValue(_ value: StructureDefault?) -> String {
        guard let value else { return "Keep existing default" }
        switch value.kind {
        case "none": return "No explicit default (drop if present)"
        case "null": return "SQL NULL default"
        case "text": return value.value == "" ? "Empty text literal default" : "Text literal default: «" + (value.value ?? "") + "»"
        case "numeric": return "Exact numeric default: " + (value.value ?? "")
        case "boolean": return "Boolean default: " + (value.value ?? "")
        case "expression": return "Expression default: " + (value.value ?? "")
        default: return "Default kind: " + value.kind
        }
    }
}

struct TableStructureIndexDefinitionSummary: View {
    let definition: StructureIndexDefinition
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Access method / index type: " + definition.method)
            ForEach(Array(definition.terms.enumerated()), id: \.offset) { i, term in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Term \(i + 1): " + (term.column.map { "column · " + $0 } ?? "expression · " + (term.expression ?? "")))
                    if let descending = term.descending { Text(descending ? "Descending" : "Ascending") }
                    if let nullsFirst = term.nullsFirst { Text(nullsFirst ? "NULLS FIRST" : "NULLS LAST") }
                    if let prefix = term.prefixLength { Text("Prefix length: \(prefix)") }
                    if let collation = term.collation { Text("Collation: " + collation.schema + "." + collation.name) }
                    if let opclass = term.opclass { Text("Operator class: " + opclass.schema + "." + opclass.name) }
                    optionSummary(term.options, title: "Operator class option")
                }.padding(.leading, 8)
            }
            if let includes = definition.includes { StructureOrderedNamesSummary(title: "INCLUDE columns", names: includes) }
            if let predicate = definition.predicate { Text("Predicate: " + predicate) }
            if let distinct = definition.nullsDistinct { Text(distinct ? "NULLS DISTINCT" : "NULLS NOT DISTINCT") }
            if let visible = definition.visible { Text(visible ? "Visible" : "Invisible") }
            optionSummary(definition.options, title: "Index option")
        }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
    }
    private func optionSummary(_ values: [StructureIndexOption]?, title: String) -> some View {
        ForEach(Array((values ?? []).enumerated()), id: \.offset) { _, option in
            Text(title + ": " + option.name + " = " + option.value)
        }
    }
}
