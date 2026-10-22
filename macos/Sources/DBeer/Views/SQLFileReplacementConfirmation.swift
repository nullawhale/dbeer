import AppKit
import SwiftUI

@MainActor
enum SQLFileReplacementConfirmation {
    static func present(localText: String, external: LoadedSQLFile, url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace Existing SQL File?"
        alert.informativeText = "Compare the local draft with the file at the chosen destination. Only the external version shown here can be replaced."
        alert.addButton(withTitle: "Replace Reviewed Version")
        alert.addButton(withTitle: "Cancel")
        let comparison = NSHostingView(rootView: SQLFileReplacementComparison(
            localText: localText, externalText: external.text, url: url))
        comparison.frame = NSRect(x: 0, y: 0, width: 780, height: 350)
        alert.accessoryView = comparison
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct SQLFileReplacementComparison: View {
    let localText: String
    let externalText: String
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(url.path).font(.caption).appSecondaryText().textSelection(.enabled)
            HSplitView {
                version("Local Draft", text: localText)
                version("Existing File", text: externalText)
            }
        }
        .frame(width: 780, height: 350)
        .focusEffectDisabled()
    }

    private func version(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(text.utf8.count.formatted()) bytes").font(.caption).appSecondaryText()
            }
            SQLEditorView(text: .constant(text), isEditable: false)
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(title)
        }.padding(6)
    }
}
