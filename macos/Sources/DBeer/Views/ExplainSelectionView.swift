import SwiftUI

struct ExplainSelectionView: View {
    let draft: ExplainBatchDraft
    let completion: (Set<Int>, String, ExplainPlanKind?) -> Void
    @Environment(\.dismiss) private var dismiss
    private var selected: SwiftUI.State<Set<Int>>
    private var targetID: SwiftUI.State<String>
    private var planChoice = SwiftUI.State(initialValue: "default")

    init(draft: ExplainBatchDraft, completion: @escaping (Set<Int>, String, ExplainPlanKind?) -> Void) {
        self.draft = draft
        self.completion = completion
        selected = SwiftUI.State(initialValue: Set(draft.statements.filter(\.selectedByDefault).map(\.id)))
        targetID = SwiftUI.State(initialValue: draft.defaultTargetID)
    }

    private var target: ExplainBatchTarget? { draft.targets.first { $0.id == targetID.wrappedValue } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(draft.mode.title) · Choose Statements").font(.title2)
            Text("Statements run in original document order. Each operation receives a separate review. Setup commands run only when you select them.")
                .font(.callout).appSecondaryText()
            Picker("Target SQL session", selection: targetID.projectedValue) {
                ForEach(draft.targets) { target in Text(target.title).tag(target.id) }
            }.controlHover()
            if let target {
                Text(target.profile.endpointDescription + " · " + (target.transactionStatus?.rawValue ?? "new session"))
                    .font(.caption).appSecondaryText()
            }
            if let sessionID = target?.sessionID {
                Text("Session: " + sessionID).font(.caption).appSecondaryText().textSelection(.enabled)
            }
            if target?.profile.engine == .postgresql {
                Picker("PostgreSQL plan", selection: planChoice.projectedValue) {
                    Text("Server default").tag("default")
                    Text("Custom · bound values").tag("custom")
                    if draft.mode == .plan { Text("Generic · PostgreSQL 16+ · value independent").tag("generic") }
                }.controlHover()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(draft.statements) { statement in
                        Toggle(isOn: Binding(get: { selected.wrappedValue.contains(statement.id) }, set: {
                            if $0 { selected.wrappedValue.insert(statement.id) } else { selected.wrappedValue.remove(statement.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Line \(statement.line) · \(statement.action == .plan ? draft.mode.title : "Execute setup command")").font(.callout)
                                Text(statement.sql).font(.system(.caption, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                            }
                        }.toggleStyle(.checkbox).controlHover()
                    }
                }.padding(4)
            }.frame(minHeight: 120, maxHeight: 380)
            Text("Parameter values are requested next and sent as typed bindings. Generic plans use their types without planning for the entered values.")
                .font(.caption).appSecondaryText()
            HStack {
                Button("Cancel") { dismiss() }.controlHover().keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") {
                    let kind = target?.profile.engine == .postgresql ? ExplainPlanKind(rawValue: planChoice.wrappedValue) : nil
                    completion(selected.wrappedValue, targetID.wrappedValue, kind)
                }.controlHover().keyboardShortcut(.defaultAction).disabled(selected.wrappedValue.isEmpty || target == nil)
            }
        }.padding(20).frame(width: 680)
            .background(AppPalette.background).tint(AppPalette.accent).focusEffectDisabled()
            .accessibilityElement(children: .contain).accessibilityIdentifier("explainSelection")
    }
}
