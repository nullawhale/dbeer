import SwiftUI

struct StructureIndexDefinitionEditor: View {
    @Binding var definition: StructureIndexDefinition
    let names: [String]
    let engine: DatabaseEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if engine == .postgresql {
                TextField("Access method (for example, btree or gin)", text: $definition.method).textFieldStyle(.roundedBorder)
            } else {
                Picker("Index type", selection: $definition.method) {
                    Text("BTREE").tag("btree")
                    Text("FULLTEXT").tag("fulltext"); Text("SPATIAL").tag("spatial")
                    if !["btree", "fulltext", "spatial"].contains(definition.method) { Text(definition.method).tag(definition.method) }
                }.controlHover()
            }
            ForEach(definition.terms.indices, id: \.self) { i in
                StructureIndexTermEditor(term: termBinding(i), names: names, engine: engine, method: definition.method, ordinal: i + 1) {
                    guard definition.terms.indices.contains(i) else { return }; definition.terms.remove(at: i)
                }
            }
            Button("Append Index Term") { definition.terms.append(.init(column: "")) }
                .controlHover().disabled(definition.terms.count >= 32)
            if engine == .postgresql {
                StructureOrderedColumnsEditor(title: "INCLUDE columns", options: names, columns: Binding(get: { definition.includes ?? [] }, set: { definition.includes = $0.isEmpty ? nil : $0 }))
                Toggle("Partial index", isOn: Binding(get: { definition.predicate != nil }, set: { definition.predicate = $0 ? "" : nil })).controlHover()
                if definition.predicate != nil {
                    TextField("Exact predicate expression", text: Binding(get: { definition.predicate ?? "" }, set: { definition.predicate = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                }
                StructureIndexOptionalBoolPicker(title: "Unique NULL treatment", defaultLabel: "Server default NULL treatment", trueLabel: "NULLS DISTINCT", falseLabel: "NULLS NOT DISTINCT", value: $definition.nullsDistinct)
            } else {
                StructureIndexOptionalBoolPicker(title: engine == .mariadb ? "Optimizer use" : "Visibility", defaultLabel: "Server default", trueLabel: engine == .mariadb ? "Not ignored" : "Visible", falseLabel: engine == .mariadb ? "Ignored" : "Invisible", value: $definition.visible)
            }
            StructureIndexOptionsEditor(title: "Index options", options: $definition.options)
            Text("Preview checks each option against this engine, access method and server version. Expressions and predicates are retained exactly; Preview does not evaluate them. Apply requires review of the generated SQL.")
                .font(.caption).appSecondaryText()
        }
    }
    private func termBinding(_ i: Int) -> Binding<StructureIndexTerm> {
        Binding(get: { definition.terms.indices.contains(i) ? definition.terms[i] : .init(column: "") }, set: {
            guard definition.terms.indices.contains(i) else { return }; definition.terms[i] = $0
        })
    }
}

private struct StructureIndexTermEditor: View {
    @Binding var term: StructureIndexTerm
    let names: [String]
    let engine: DatabaseEngine
    let method: String
    let ordinal: Int
    private var isBtree: Bool { method.lowercased() == "btree" }
    private var allowsExpression: Bool { engine == .postgresql || isBtree }
    let remove: () -> Void
    var body: some View {
        GroupBox("Term \(ordinal)") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if allowsExpression || term.expression != nil {
                        Picker("Source", selection: Binding(get: { term.expression != nil ? "expression" : "column" }, set: {
                            if $0 == "expression" { term.expression = ""; term.column = nil }
                            else { term.column = ""; term.expression = nil }
                        })) { Text("Column").tag("column"); Text("Expression").tag("expression").disabled(!allowsExpression) }.controlHover()
                    }
                    if term.expression != nil {
                        TextField("Exact index expression", text: Binding(get: { term.expression ?? "" }, set: { term.expression = $0 }))
                            .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    } else {
                        StructureExactNamePicker(title: "Column", placeholder: "Choose column", names: names,
                            selection: Binding(get: { term.column ?? "" }, set: { term.column = $0 }))
                    }
                    ControlIconButton(systemName: "minus.circle", action: remove).help("Remove this index term").accessibilityLabel("Remove index term")
                }
                if isBtree || term.descending != nil {
                    StructureIndexOptionalBoolPicker(title: "Direction", defaultLabel: "Default direction", trueLabel: "Descending", falseLabel: "Ascending", value: $term.descending, allowsExplicit: isBtree)
                }
                if engine == .postgresql {
                    if isBtree || term.nullsFirst != nil {
                        StructureIndexOptionalBoolPicker(title: "NULL order", defaultLabel: "Default NULL order", trueLabel: "NULLS FIRST", falseLabel: "NULLS LAST", value: $term.nullsFirst, allowsExplicit: isBtree)
                    }
                    StructureIndexReferenceEditor(title: "Collation", value: $term.collation)
                    StructureIndexReferenceEditor(title: "Operator class", value: $term.opclass)
                    StructureIndexOptionsEditor(title: "Operator class options", options: $term.options)
                } else if isBtree || term.prefixLength != nil {
                    Toggle("Prefix length", isOn: Binding(get: { term.prefixLength != nil }, set: {
                        guard !$0 || isBtree else { return }; term.prefixLength = $0 ? 0 : nil
                    })).controlHover()
                    if term.prefixLength != nil {
                        TextField("Prefix length", value: Binding(get: { term.prefixLength ?? 0 }, set: { term.prefixLength = $0 }), format: .number)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Index prefix length")
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StructureIndexReferenceEditor: View {
    let title: String
    @Binding var value: StructureTypeReference?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("Explicit " + title.lowercased(), isOn: Binding(get: { value != nil }, set: { value = $0 ? .init(schema: "", name: "") : nil })).controlHover()
            if value != nil {
                HStack {
                    TextField(title + " schema", text: Binding(get: { value?.schema ?? "" }, set: { value?.schema = $0 })).textFieldStyle(.roundedBorder)
                    TextField(title + " name", text: Binding(get: { value?.name ?? "" }, set: { value?.name = $0 })).textFieldStyle(.roundedBorder)
                }
            }
        }
    }
}

private struct StructureIndexOptionalBoolPicker: View {
    let title: String
    let defaultLabel: String
    let trueLabel: String
    let falseLabel: String
    @Binding var value: Bool?
    var allowsExplicit = true
    var body: some View {
        Picker(title, selection: Binding(get: { value.map { $0 ? "true" : "false" } ?? "default" }, set: { value = $0 == "default" ? nil : $0 == "true" })) {
            Text(defaultLabel).tag("default"); Text(trueLabel).tag("true").disabled(!allowsExplicit); Text(falseLabel).tag("false").disabled(!allowsExplicit)
        }.controlHover()
    }
}

private struct StructureIndexOptionsEditor: View {
    let title: String
    @Binding var options: [StructureIndexOption]?
    private var values: [StructureIndexOption] { options ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).appSecondaryText()
            ForEach(values.indices, id: \.self) { i in
                HStack {
                    TextField("Exact option name", text: binding(i, \.name)).textFieldStyle(.roundedBorder)
                    TextField("Exact option value", text: binding(i, \.value)).textFieldStyle(.roundedBorder)
                    ControlIconButton(systemName: "minus.circle") {
                        guard values.indices.contains(i) else { return }; options?.remove(at: i)
                    }.help("Remove this option").accessibilityLabel("Remove index option")
                }
            }
            Button("Append " + title.lowercased() + " entry") { options = values + [.init(name: "", value: "")] }
                .controlHover().disabled(values.count >= 32)
        }
    }
    private func binding(_ i: Int, _ key: WritableKeyPath<StructureIndexOption, String>) -> Binding<String> {
        Binding(get: { values.indices.contains(i) ? values[i][keyPath: key] : "" }, set: {
            guard values.indices.contains(i) else { return }; options?[i][keyPath: key] = $0
        })
    }
}
