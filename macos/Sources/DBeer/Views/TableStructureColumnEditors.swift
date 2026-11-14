import SwiftUI

struct TableStructureNewColumnEditor: View {
    @Binding var column: StructureColumn
    let number: Int
    let engine: DatabaseEngine
    let create: Bool
    var authoringAvailable = false
    let canRemove: Bool
    let remove: () -> Void
    private var types: [String] { engine == .sqlite ? ["integer", "real", "text", "blob", "sqliteNumeric", "any"] : engine == .postgresql ? ["integer", "bigint", "boolean", "numeric", "varchar", "text"] : ["integer", "bigint", "numeric", "varchar", "text"] }

    var body: some View {
        GroupBox(create ? "New Column \(number)" : "Append Column") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Exact column name", text: $column.name).textFieldStyle(.roundedBorder)
                    Picker("Type", selection: Binding(get: { column.type.kind }, set: { kind in
                        column.type = .init(kind: kind, length: kind == "varchar" ? 255 : nil,
                            precision: kind == "numeric" ? 10 : nil, scale: kind == "numeric" ? 0 : nil,
                            reference: kind == "reference" ? .init(schema: "", name: "") : nil)
                    })) {
                        ForEach(types + (authoringAvailable && engine == .postgresql ? ["reference"] : []), id: \.self) { Text($0).tag($0) }
                    }.controlHover().frame(width: 165)
                    Toggle("Allow NULL", isOn: $column.nullable).controlHover().disabled(!create)
                    if canRemove {
                        ControlIconButton(systemName: "minus.circle", action: remove)
                            .help("Remove this local new-column draft").accessibilityLabel("Remove new column")
                    }
                }
                if column.type.kind == "varchar" {
                    TextField("VARCHAR length", value: Binding(get: { column.type.length ?? 255 }, set: { column.type.length = $0 }), format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 180)
                }
                if column.type.kind == "numeric" {
                    HStack {
                        TextField("Precision", value: Binding(get: { column.type.precision ?? 10 }, set: { column.type.precision = $0 }), format: .number)
                        TextField("Scale", value: Binding(get: { column.type.scale ?? 0 }, set: { column.type.scale = $0 }), format: .number)
                    }.textFieldStyle(.roundedBorder).frame(width: 250)
                }
                if column.type.kind == "reference" {
                    HStack {
                        TextField("Exact type schema", text: Binding(get: { column.type.reference?.schema ?? "" }, set: { column.type.reference?.schema = $0 }))
                        TextField("Exact type name", text: Binding(get: { column.type.reference?.name ?? "" }, set: { column.type.reference?.name = $0 }))
                    }.textFieldStyle(.roundedBorder)
                }
                TableStructureDefaultEditor(selection: Binding(get: { column.default }, set: { column.default = $0 ?? .init(kind: "none") }),
                    engine: engine, allowsKeep: false, authoringAvailable: authoringAvailable)
                    .disabled(column.generated?.storage != nil && column.generated?.storage != "none" || column.identity?.kind != nil && column.identity?.kind != "none")
                if authoringAvailable {
                    TableStructureGenerationEditor(selection: Binding(get: { column.generated }, set: {
                        column.generated = $0
                        if $0?.storage != nil && $0?.storage != "none" { column.default = .init(kind: "none"); column.identity = nil }
                    }), allowsKeep: false)
                    if create {
                        TableStructureIdentityEditor(selection: Binding(get: { column.identity }, set: {
                            column.identity = $0
                            if $0?.kind != nil && $0?.kind != "none" { column.default = .init(kind: "none"); column.generated = nil; column.nullable = false }
                        }), engine: engine, allowsKeep: false)
                    }
                }
                if !create { Text("Appended columns are nullable. Required-column backfills and existing-table identity additions need a separately reviewed operation.").font(.caption).appSecondaryText() }
            }
        }
    }
}

/// A nil selection preserves an existing default; the typed none/null/literal
/// states below are distinct and never inferred from a text field's contents.
struct TableStructureDefaultEditor: View {
    @Binding var selection: StructureDefault?
    let engine: DatabaseEngine
    let allowsKeep: Bool
    var authoringAvailable = false
    private var kind: String { selection?.kind ?? (allowsKeep ? "keep" : "none") }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("Default", selection: Binding(get: { kind }, set: { value in
                    guard value != kind else { return }
                    if value == "keep" { selection = nil }
                    else { selection = .init(kind: value, value: ["none", "null"].contains(value) ? nil : value == "boolean" ? "false" : "") }
                })) {
                    if allowsKeep { Text("Keep default").tag("keep") }
                    Text(allowsKeep ? "Drop default" : "No default").tag("none")
                    Text("SQL NULL").tag("null")
                    Text("Text literal").tag("text")
                    Text("Number literal").tag("numeric")
                    if authoringAvailable { Text("SQL expression").tag("expression") }
                    if engine == .postgresql { Text("Boolean literal").tag("boolean") }
                }.controlHover().frame(width: 230)
                if kind == "boolean" {
                    Picker("Boolean value", selection: literal) { Text("false").tag("false"); Text("true").tag("true") }.controlHover()
                } else if ["text", "numeric", "expression"].contains(kind) {
                    TextField(kind == "expression" ? "SQL expression; evaluated only on Apply or later writes" : kind == "text" ? "Exact text; empty string allowed" : "Exact numeric literal", text: literal)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if kind == "expression" {
                Text("Preview checks boundaries without running expressions. Comments and backslash escapes are unsupported; SQL semantics are checked by the server during Apply.").font(.caption).appSecondaryText()
            }
            if kind == "text" {
                Text("An empty field is an empty string. Text such as NULL or DEFAULT remains a text literal.").font(.caption).appSecondaryText()
            }
        }
    }
    private var literal: Binding<String> {
        Binding(get: { selection?.value ?? "" }, set: { if selection != nil { selection?.value = $0 } })
    }
}
