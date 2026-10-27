import AppKit
import Combine
import SwiftUI

@MainActor final class SQLEditorPreferences: ObservableObject {
    static let shared = SQLEditorPreferences()
    private let defaults: UserDefaults
    @Published var fontName: String { didSet { save() } }
    @Published var fontSize: Double { didSet { save() } }
    @Published var wrapsLines: Bool { didSet { save() } }
    @Published var showsInvisibles: Bool { didSet { save() } }
    @Published var usesTabs: Bool { didSet { save() } }
    @Published var indentWidth: Int { didSet { save() } }
    @Published var autoPairs: Bool { didSet { save() } }
    @Published var autoIndent: Bool { didSet { save() } }
    @Published var keywordCase: String { didSet { save() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fontName = defaults.string(forKey: "editor.fontName") ?? ""
        fontSize = defaults.object(forKey: "editor.fontSize") as? Double ?? 13
        wrapsLines = defaults.object(forKey: "editor.wrapsLines") as? Bool ?? true
        showsInvisibles = defaults.bool(forKey: "editor.showsInvisibles")
        usesTabs = defaults.bool(forKey: "editor.usesTabs")
        indentWidth = defaults.object(forKey: "editor.indentWidth") as? Int ?? 4
        autoPairs = defaults.object(forKey: "editor.autoPairs") as? Bool ?? true
        autoIndent = defaults.object(forKey: "editor.autoIndent") as? Bool ?? true
        keywordCase = defaults.string(forKey: "editor.keywordCase") ?? "preserve"
    }

    private func save() {
        let values: [String: Any] = ["fontName": fontName, "fontSize": fontSize,
            "wrapsLines": wrapsLines, "showsInvisibles": showsInvisibles, "usesTabs": usesTabs,
            "indentWidth": indentWidth, "autoPairs": autoPairs, "autoIndent": autoIndent, "keywordCase": keywordCase]
        for (key, value) in values { defaults.set(value, forKey: "editor." + key) }
        NotificationCenter.default.post(name: .editorPreferencesChanged, object: self)
    }

    func apply(to editor: SQLTextView) {
        let size = min(48, max(9, fontSize))
        let font = NSFont(name: fontName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        if editor.font != font { editor.font = font }
        editor.editorIndentWidth = min(8, max(1, indentWidth))
        editor.editorUsesTabs = usesTabs
        editor.editorAutoPairs = autoPairs
        editor.editorAutoIndent = autoIndent
        editor.layoutManager?.showsInvisibleCharacters = showsInvisibles
        editor.isHorizontallyResizable = !wrapsLines
        editor.textContainer?.widthTracksTextView = wrapsLines
        editor.enclosingScrollView?.hasHorizontalScroller = !wrapsLines
        if !wrapsLines { editor.textContainer?.containerSize.width = CGFloat.greatestFiniteMagnitude }
        else if let width = editor.enclosingScrollView?.contentSize.width {
            editor.textContainer?.containerSize.width = max(0, width - editor.textContainerInset.width * 2)
        }
        editor.needsDisplay = true
    }
}

extension Notification.Name { static let editorPreferencesChanged = Notification.Name("DBeerEditorPreferencesChanged") }

struct EditorSettingsView: View {
    @ObservedObject private var preferences = SQLEditorPreferences.shared
    var body: some View {
        Form {
            Section("Text") {
                TextField("Font name (empty for system monospace)", text: $preferences.fontName)
                Stepper("Font size: \(Int(preferences.fontSize)) pt", value: $preferences.fontSize, in: 9...48)
                Toggle("Wrap long lines", isOn: $preferences.wrapsLines)
                Toggle("Show invisible characters", isOn: $preferences.showsInvisibles)
            }
            Section("Editing") {
                Toggle("Indent with tabs", isOn: $preferences.usesTabs)
                Stepper("Indent width: \(preferences.indentWidth)", value: $preferences.indentWidth, in: 1...8)
                Toggle("Automatically indent new lines", isOn: $preferences.autoIndent)
                Toggle("Insert matching brackets and quotes", isOn: $preferences.autoPairs)
                Picker("Format keyword case", selection: $preferences.keywordCase) {
                    Text("Preserve").tag("preserve")
                    Text("UPPERCASE").tag("upper")
                    Text("lowercase").tag("lower")
                }
            }
        }.formStyle(.grouped).padding(8).frame(width: 620, height: 420)
    }
}
