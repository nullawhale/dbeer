import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AppearanceSettingsView: View {
    @ObservedObject var appearance: AppAppearance
    @ObservedObject var editorThemes: EditorThemeStore
    @Environment(\.colorScheme) private var colorScheme
    private var importing = SwiftUI.State(initialValue: false)
    private var themeError = SwiftUI.State<String?>(initialValue: nil)

    init(appearance: AppAppearance, editorThemes: EditorThemeStore? = nil) {
        self.appearance = appearance
        self.editorThemes = editorThemes ?? appearance.editorThemes
    }

    private var selectedTheme: EditorTheme? {
        editorThemes.themes.first { $0.id == editorThemes.selectedThemeID }
    }

    var body: some View {
        Form {
            Section("Application") {
                VStack(alignment: .leading) {
                    Picker("Theme", selection: Binding(get: { appearance.selectionID },
                        set: { appearance.chooseSelection($0) })) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                        Divider()
                        ForEach(editorThemes.themes) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    .pickerStyle(.menu)
                    // Grouped forms size the row to its text; leave room for
                    // the taller native popup before laying out its hover.
                    .frame(minHeight: 24).controlHover()
                    .accessibilityLabel("Application theme")
                    .accessibilityIdentifier("appearanceTheme")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("applicationTheme")
                Text("Choose a native appearance or an editor color scheme for the application. The Dock icon follows its light or dark appearance.")
                    .font(.callout).appSecondaryText()
            }
            Section("SQL editor") {
                Picker("Color scheme", selection: $editorThemes.selectedThemeID) {
                    Text("Follow App Appearance").tag("automatic")
                    Divider()
                    ForEach(editorThemes.themes) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: 24).controlHover()
                .accessibilityLabel("Editor color scheme")
                .accessibilityIdentifier("editorColorScheme")
                HStack(spacing: 8) {
                    Button("Import Theme…") {
                        themeError.wrappedValue = nil
                        importing.wrappedValue = true
                    }.controlHover().accessibilityIdentifier("importEditorTheme")
                    Button("Remove Theme") {
                        guard let selectedTheme, selectedTheme.isImported else { return }
                        do {
                            try editorThemes.removeTheme(id: selectedTheme.id)
                            themeError.wrappedValue = nil
                        } catch { themeError.wrappedValue = error.localizedDescription }
                    }
                    .controlHover().disabled(selectedTheme?.isImported != true)
                    .accessibilityIdentifier("removeEditorTheme")
                    Spacer()
                }.buttonStyle(.bordered)
                Text("Import VS Code (.json, .jsonc), TextMate (.tmTheme) or JetBrains (.icls) color schemes for both menus. The application and editor selections are independent.")
                    .font(.caption).appSecondaryText()
                    .fixedSize(horizontal: false, vertical: true)
                if let error = themeError.wrappedValue ?? editorThemes.loadError {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("editorThemeError")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview").font(.caption).appSecondaryText()
                    SQLEditorView(text: .constant(Self.previewSQL), isEditable: false,
                        editorTheme: effectiveEditorTheme)
                        .frame(height: 154)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(AppPalette.border, lineWidth: 0.5))
                        .accessibilityIdentifier("editorThemePreview")
                }
            }
        }
        .formStyle(.grouped)
        .appFormSurface()
        .padding(8)
        .frame(width: 650, height: 540)
        .background(AppPalette.window)
        .tint(AppPalette.accent)
        .applicationTheme(appearance: appearance)
        .focusEffectDisabled()
        .fileImporter(isPresented: importing.projectedValue, allowedContentTypes: Self.themeFileTypes) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                _ = try editorThemes.importTheme(from: url)
                themeError.wrappedValue = nil
            } catch {
                let error = error as NSError
                if error.domain != NSCocoaErrorDomain || error.code != NSUserCancelledError {
                    themeError.wrappedValue = error.localizedDescription
                }
            }
        }
    }

    private var effectiveEditorTheme: EditorTheme {
        if editorThemes.selectedThemeID == EditorThemeStore.automaticID,
           let theme = appearance.selectedColorTheme { return theme }
        return editorThemes.effectiveTheme(isDark: colorScheme == .dark)
    }

    private static let themeFileTypes = [UTType.json, UTType(filenameExtension: "jsonc") ?? .json,
        UTType(filenameExtension: "tmTheme") ?? .xml, UTType(filenameExtension: "icls") ?? .xml]
    private static let previewSQL = """
    -- Beer inventory
    SELECT b.name, round(b.abv, 1) AS strength
    FROM public.beers AS b
    WHERE b.style = 'IPA' AND b.abv >= 5.5;
    """
}
