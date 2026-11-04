import SwiftUI

struct TableImportMappingLibraryView: View {
    @ObservedObject var model: TableImportModel
    @ObservedObject var store: TransferMappingPresetStore
    private var nameState = SwiftUI.State(initialValue: "")
    private var name: String {
        get { nameState.wrappedValue }
        nonmutating set { nameState.wrappedValue = newValue }
    }
    var body: some View {
        GroupBox("Saved mappings") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Mapping name", text: nameState.projectedValue).textFieldStyle(.roundedBorder)
                    Button("Save Mapping") { Task { await model.saveMapping(name: name) } }
                        .controlHover().disabled(!store.loaded || store.isBusy || model.parsed == nil || !model.canEdit || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Menu("Use Mapping") {
                        ForEach(store.presets.filter { $0.engine == model.profile.engine && $0.purpose == "append" }) { preset in
                            Button(preset.name) { Task { await model.applyMapping(preset) } }
                        }
                    }.controlHover().disabled(!model.canEdit || store.isBusy || model.parsed == nil)
                    Menu("Delete Mapping") {
                        ForEach(store.presets) { preset in
                            Button(preset.name) { Task { try? await store.delete(preset.id) } }
                        }
                    }.controlHover().disabled(store.isBusy || !model.canEdit)
                    Button("Reload") { Task { await store.load() } }.controlHover().disabled(store.isBusy)
                }
                Text("Mappings save parser options and column names. Applying one requires matching source headers and a fresh SQL preview.")
                    .font(.caption).appSecondaryText()
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }.padding(.vertical, 4)
        }.task { if !store.loaded { await store.load() } }
    }
}
