import SwiftUI

struct ExplainOptionsView: View {
    let configuration: ExplainOptionsConfiguration
    let completion: (ExplainOptionsDecision?) -> Void
    private var flags = SwiftUI.State<[String: String]>(wrappedValue: [:])
    private var serialize = SwiftUI.State(wrappedValue: "default")
    private var format = SwiftUI.State(wrappedValue: "default")
    private var completed = SwiftUI.State(wrappedValue: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(configuration.mode.title + " Options").font(.title2)
            Text(configuration.profile.name + " · " + configuration.support.engine.displayName + " " + configuration.support.serverVersion)
                .font(.callout).textSelection(.enabled)
            Text(configuration.profile.endpointDescription + " · " + (configuration.transactionStatus?.rawValue ?? "unavailable transaction state"))
                .font(.caption).appSecondaryText()
            Text("Session: " + configuration.sessionID).font(.caption).appSecondaryText().textSelection(.enabled)
            ScrollView {
                Text(configuration.sql).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 90)
            ForEach(Array((configuration.support.notices ?? []).enumerated()), id: \.offset) { _, notice in
                Text(notice).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text("Choose options for this statement before its separate execution review. Defaults preserve the usual command.")
                .font(.caption).appSecondaryText()
            if configuration.support.engine == .postgresql {
                ForEach(configuration.available.filter { $0 != "serialize" }, id: \.self) { flag in
                    Picker(flag.uppercased(), selection: Binding(get: { flags.wrappedValue[flag] ?? "default" }, set: { flags.wrappedValue[flag] = $0 })) {
                        Text("Default").tag("default")
                        Text("On").tag("on")
                        Text("Off").tag("off")
                    }.controlHover()
                }
                if configuration.available.contains("serialize") {
                    Picker("SERIALIZE", selection: serialize.projectedValue) {
                        Text("Default").tag("default")
                        ForEach(ExplainSerialize.allCases, id: \.rawValue) { value in Text(value.rawValue.uppercased()).tag(value.rawValue) }
                    }.controlHover()
                }
            } else {
                Picker("MySQL format", selection: format.projectedValue) {
                    Text("Default").tag("default")
                    Text("Automatic").tag("auto")
                    ForEach(configuration.available, id: \.self) { value in Text(value.uppercased()).tag(value) }
                }.controlHover()
                if configuration.requiresJSONVersion2 {
                    Text("JSON Analyze requires this session's explain_json_format_version to already be 2. It is checked before execution. DBeer does not change the setting or rerun Analyze in another format.")
                        .font(.caption).appSecondaryText()
                }
            }
            HStack {
                Button("Cancel") { finish(nil) }.controlHover().keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") { finish(.use(chosenOptions)) }.controlHover().keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 580)
            .background(AppPalette.background).tint(AppPalette.accent).focusEffectDisabled()
            .interactiveDismissDisabled()
            .accessibilityElement(children: .contain).accessibilityIdentifier("explainOptions")
    }

    private var chosenOptions: ExplainOptions? {
        if configuration.support.engine == .postgresql {
            func value(_ name: String) -> Bool? {
                switch flags.wrappedValue[name] { case "on": true; case "off": false; default: nil }
            }
            let pg = PostgresExplainOptions(buffers: value("buffers"), wal: value("wal"), settings: value("settings"), memory: value("memory"),
                serialize: ExplainSerialize(rawValue: serialize.wrappedValue), timing: value("timing"))
            return pg.keys.isEmpty ? nil : ExplainOptions(postgresql: pg)
        }
        return MySQLExplainFormat(rawValue: format.wrappedValue).map { ExplainOptions(mysql: .init(format: $0)) }
    }

    private func finish(_ decision: ExplainOptionsDecision?) {
        guard !completed.wrappedValue else { return }
        completed.wrappedValue = true
        completion(decision)
    }
}
