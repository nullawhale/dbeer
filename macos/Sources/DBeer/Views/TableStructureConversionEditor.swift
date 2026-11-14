import SwiftUI

struct TableStructureConversionEditor: View {
    @Binding var change: StructureColumnChange
    let engine: DatabaseEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if engine == .postgresql || change.usingExpression != nil {
                Toggle("Use an explicit PostgreSQL USING expression", isOn: Binding(get: { change.usingExpression != nil }, set: {
                    change.usingExpression = $0 ? "" : nil
                })).controlHover().disabled(engine != .postgresql)
                if change.usingExpression != nil {
                    TextField("Exact USING expression; requires a selected type", text: Binding(get: { change.usingExpression ?? "" }, set: { change.usingExpression = $0 }))
                        .textFieldStyle(.roundedBorder).disabled(engine != .postgresql)
                    Text("Preview does not evaluate this expression. Apply can evaluate it for every row and invoke server routines. Automatic validation is unavailable when routine effects cannot be proven.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if engine.usesMySQLSyntax || change.unsigned != nil || change.charset != nil {
                Picker("Signedness", selection: Binding(get: { change.unsigned.map { $0 ? "unsigned" : "signed" } ?? "keep" }, set: {
                    change.unsigned = $0 == "keep" ? nil : $0 == "unsigned"
                })) {
                    Text("Keep signedness").tag("keep")
                    Text("Signed").tag("signed")
                    Text("Unsigned").tag("unsigned")
                }.controlHover().disabled(!engine.usesMySQLSyntax)
                Toggle("Change MySQL character set", isOn: Binding(get: { change.charset != nil }, set: { change.charset = $0 ? "" : nil }))
                    .controlHover().disabled(!engine.usesMySQLSyntax)
                if change.charset != nil {
                    TextField("Exact character set name", text: Binding(get: { change.charset ?? "" }, set: { change.charset = $0 }))
                        .textFieldStyle(.roundedBorder).disabled(!engine.usesMySQLSyntax)
                }
            }
            Toggle("Change collation", isOn: Binding(get: { change.collation != nil }, set: {
                change.collation = $0 ? .init(schema: "", name: "") : nil
            })).controlHover().disabled(engine == .sqlite)
            if change.collation != nil {
                HStack {
                    if engine == .postgresql || change.collation?.schema.isEmpty == false {
                        TextField("Exact collation schema", text: Binding(get: { change.collation?.schema ?? "" }, set: { change.collation?.schema = $0 }))
                            .disabled(engine != .postgresql)
                    }
                    TextField("Exact collation name", text: Binding(get: { change.collation?.name ?? "" }, set: { change.collation?.name = $0 }))
                }.textFieldStyle(.roundedBorder)
            }
            Text("Review conversions separately from default, nullability, generation and identity changes. Narrowing, signedness, character set and collation changes can lose or reinterpret data, change comparison and ordering, and rebuild indexes. Preview reports dependencies and consequences. Validate Data is a separate authorized read; its observations do not guarantee Apply will succeed.")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
