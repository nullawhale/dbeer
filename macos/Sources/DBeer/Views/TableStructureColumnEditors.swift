import SwiftUI

struct TableStructureNewColumnEditor: View {
    @Binding var column: StructureColumn
    let number: Int
    let engine: DatabaseEngine
    let create: Bool
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
                            precision: kind == "numeric" ? 10 : nil, scale: kind == "numeric" ? 0 : nil)
                    })) {
                        ForEach(types, id: \.self) { Text($0).tag($0) }
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
                TableStructureDefaultEditor(selection: Binding(get: { column.default }, set: { column.default = $0 ?? .init(kind: "none") }),
                    engine: engine, allowsKeep: false)
                if !create { Text("Append adds one nullable column. Change an existing column through a separate column-change draft.").font(.caption).appSecondaryText() }
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
                    if engine == .postgresql { Text("Boolean literal").tag("boolean") }
                }.controlHover().frame(width: 230)
                if kind == "boolean" {
                    Picker("Boolean value", selection: literal) { Text("false").tag("false"); Text("true").tag("true") }.controlHover()
                } else if kind == "text" || kind == "numeric" {
                    TextField(kind == "text" ? "Exact text; empty string allowed" : "Exact numeric literal", text: literal)
                        .textFieldStyle(.roundedBorder)
                }
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
