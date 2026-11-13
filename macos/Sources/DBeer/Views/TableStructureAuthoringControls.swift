import SwiftUI

struct TableStructureGenerationEditor: View {
    @Binding var selection: StructureGeneration?
    let allowsKeep: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Generation", selection: Binding(get: { selection?.storage == "none" && !allowsKeep ? "keep" : selection?.storage ?? "keep" }, set: {
                selection = $0 == "keep" ? nil : .init(storage: $0, expression: $0 == "none" ? nil : "")
            })) {
                Text(allowsKeep ? "Keep generation" : "Ordinary column").tag("keep")
                if allowsKeep { Text("Remove generation").tag("none") }
                Text("Stored generated").tag("stored")
                Text("Virtual generated").tag("virtual")
            }.controlHover().frame(width: 250)
            if let selection, selection.storage != "none" {
                TextField("Generation expression", text: Binding(get: { selection.expression ?? "" }, set: { self.selection?.expression = $0 }))
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            }
        }
    }
}

struct TableStructureIdentityEditor: View {
    @Binding var selection: StructureIdentity?
    let engine: DatabaseEngine
    let allowsKeep: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Identity", selection: Binding(get: { selection?.kind == "none" && !allowsKeep ? "keep" : selection?.kind ?? "keep" }, set: {
                selection = $0 == "keep" ? nil : .init(kind: $0)
            })) {
                Text(allowsKeep ? "Keep identity" : "No identity").tag("keep")
                if allowsKeep { Text("Remove identity").tag("none") }
                if engine == .postgresql {
                    Text("Identity ALWAYS").tag("always")
                    Text("Identity BY DEFAULT").tag("byDefault")
                } else { Text("AUTO_INCREMENT").tag("autoIncrement") }
            }.controlHover().frame(width: 250)
            if engine == .postgresql, let selection, ["always", "byDefault"].contains(selection.kind) {
                HStack {
                    option("Start", \.start)
                    option("Increment", \.increment)
                    option("Minimum", \.minimum)
                    option("Maximum", \.maximum)
                    option("Cache", \.cache)
                }
                Picker("Sequence cycle", selection: Binding(get: { selection.cycle.map { $0 ? "cycle" : "noCycle" } ?? "keep" }, set: {
                    self.selection?.cycle = $0 == "keep" ? nil : $0 == "cycle"
                })) {
                    Text(allowsKeep ? "Keep cycle setting" : "Default cycle setting").tag("keep")
                    Text("CYCLE").tag("cycle")
                    Text("NO CYCLE").tag("noCycle")
                }.controlHover()
                Text("Empty sequence fields preserve existing settings or use server defaults for a new identity. Values remain exact integers.")
                    .font(.caption).appSecondaryText()
            } else if selection?.kind == "autoIncrement" {
                Text(engine == .sqlite ? "Select an explicit single-column INTEGER primary key below. Existing-table identity changes require reconstruction." : "Select an explicit key or index led by this column. Preview orders its supporting key before enabling AUTO_INCREMENT.")
                    .font(.caption).appSecondaryText()
            }
        }
    }
    private func option(_ title: String, _ key: WritableKeyPath<StructureIdentity, String?>) -> some View {
        TextField(title, text: Binding(get: { selection?[keyPath: key] ?? "" }, set: {
            selection?[keyPath: key] = $0.isEmpty ? nil : $0
        })).textFieldStyle(.roundedBorder).accessibilityLabel("Identity " + title.lowercased())
    }
}
