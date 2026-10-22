import SwiftUI

struct ResultCopySettingsView: View {
    @ObservedObject var settings: ResultCopySettings

    var body: some View {
        Form {
            Section {
                Picker("Default copy format", selection: $settings.options.format) {
                    ForEach(ResultCopyFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }.controlHover().accessibilityIdentifier("resultCopyFormat")
                Toggle("Include column headers", isOn: $settings.options.includesHeaders)
                    .controlHover().accessibilityIdentifier("resultCopyHeaders")
            } header: {
                Text("Copying result selections")
            } footer: {
                Text("Applies to Copy, Copy Cell, Copy Rows and Copy Range. JSON always includes column metadata. SQL INSERT asks for a target table each time.")
            }
            Section {
                Text("NULL is \\N, DEFAULT is <DEFAULT>, and binary data is <BINARY:base64>. Empty strings and text matching these markers are quoted. Markdown text uses quoted strings with escaped line breaks.")
                    .font(.callout).appSecondaryText()
                Button("Restore Defaults") { settings.reset() }.controlHover()
                    .accessibilityIdentifier("restoreCopyDefaults")
            }
        }
        .formStyle(.grouped).appFormSurface().padding(8)
        .frame(width: 650, height: 360)
        .background(AppPalette.window).tint(AppPalette.accent).focusEffectDisabled()
    }
}
