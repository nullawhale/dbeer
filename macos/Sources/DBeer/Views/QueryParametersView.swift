import SwiftUI

struct QueryParametersView: View {
    let context: String
    let completion: ([QueryParameterBinding]?) -> Void
    private var inputs: SwiftUI.State<[SQLParameterInput]>
    private var error = SwiftUI.State<String?>(initialValue: nil)
    private var completed = SwiftUI.State(initialValue: false)

    init(definitions: [SQLParameterDefinition], context: String = "",
         completion: @escaping ([QueryParameterBinding]?) -> Void) {
        self.context = context
        self.completion = completion
        inputs = SwiftUI.State(initialValue: definitions.map { SQLParameterInput(definition: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Query Parameters").font(.title2)
            if !context.isEmpty { Text(context).font(.callout).appSecondaryText().textSelection(.enabled) }
            Text("Values are used for this run only. Empty text and SQL NULL are different values. Dates and timestamps use the entered wall time without a time zone.")
                .font(.caption).appSecondaryText()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(inputs.wrappedValue.indices, id: \.self) { index in inputRow(index) }
                }.padding(.trailing, 8)
            }.frame(minHeight: 70, idealHeight: max(70, min(CGFloat(inputs.wrappedValue.count) * 85, 360)), maxHeight: 400)
            if let error = error.wrappedValue {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .accessibilityIdentifier("queryParameterError")
            }
            HStack {
                Button("Cancel") { finish(nil) }.controlHover().keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancelQueryParameters")
                Spacer()
                Button("Continue", action: submit).controlHover().keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("submitQueryParameters")
            }
        }.padding(20).frame(width: 580)
            .background(AppPalette.background).tint(AppPalette.accent).focusEffectDisabled()
            .interactiveDismissDisabled()
            .accessibilityElement(children: .contain).accessibilityIdentifier("queryParameters")
    }

    private func inputRow(_ index: Int) -> some View {
        let input = inputs.wrappedValue[index]
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(":" + input.definition.name).font(.system(.body, design: .monospaced))
                Text(input.definition.type.label).font(.caption).appSecondaryText()
                Spacer()
                Toggle("NULL", isOn: Binding(get: {
                    inputs.wrappedValue.indices.contains(index) && inputs.wrappedValue[index].isNull
                }, set: {
                    guard inputs.wrappedValue.indices.contains(index) else { return }
                    inputs.wrappedValue[index].isNull = $0
                    error.wrappedValue = nil
                })).toggleStyle(.checkbox).controlHover()
                    .accessibilityLabel("Use SQL NULL for " + input.definition.name)
                    .accessibilityIdentifier("queryParameterNull-\(input.definition.name)")
            }
            TextField(input.definition.type.placeholder, text: Binding(get: {
                inputs.wrappedValue.indices.contains(index) ? inputs.wrappedValue[index].value : ""
            }, set: {
                guard inputs.wrappedValue.indices.contains(index) else { return }
                inputs.wrappedValue[index].value = $0
                error.wrappedValue = nil
            })).textFieldStyle(.roundedBorder).disabled(input.isNull)
                .accessibilityLabel("Value for " + input.definition.name + ", " + input.definition.type.label)
                .accessibilityIdentifier("queryParameterValue-\(input.definition.name)")
        }
    }

    private func submit() {
        do { finish(try SQLParameterInput.validate(inputs.wrappedValue)) }
        catch { self.error.wrappedValue = error.localizedDescription }
    }

    private func finish(_ bindings: [QueryParameterBinding]?) {
        guard !completed.wrappedValue else { return }
        completed.wrappedValue = true
        inputs.wrappedValue = []
        completion(bindings)
    }
}
