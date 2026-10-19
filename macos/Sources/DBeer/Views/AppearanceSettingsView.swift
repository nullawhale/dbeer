import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var appearance: AppAppearance

    var body: some View {
        Form {
            ControlSegmentPicker("Appearance", selection: $appearance.theme,
                choices: AppTheme.allCases.map { .init($0.title, value: $0) })
            .accessibilityIdentifier("appearanceTheme")

            Text("The Dock icon follows the selected appearance.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 440, height: 170)
        .tint(AppPalette.accent)
        .focusEffectDisabled()
    }
}
