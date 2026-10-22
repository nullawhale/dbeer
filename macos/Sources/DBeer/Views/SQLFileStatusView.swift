import SwiftUI

private struct SQLFileComparison: Identifiable {
    let id = UUID()
    let fileID: UUID
    let conflict: SQLFileConflict
    let localText: String
}

struct SQLFileStatusView: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject var file: SQLFileDocument
    private var comparison = SwiftUI.State<SQLFileComparison?>(initialValue: nil)

    init(document: SQLDocument, workspace: ApplicationWorkspace, file: SQLFileDocument) {
        self.document = document
        self.workspace = workspace
        self.file = file
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: file.isMissing ? "doc.badge.ellipsis" : "doc.text").accessibilityHidden(true)
                Text(file.url.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 0)
                if file.isSaving || file.isChecking { ProgressView().controlSize(.mini) }
                ControlIconButton(systemName: "arrow.clockwise") {
                    Task { await workspace.reconcileSQLFiles() }
                }
                .disabled(file.isSaving || file.isChecking)
                .help("Check for file changes").accessibilityLabel("Check for file changes")
                .accessibilityIdentifier("checkSQLFile")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(file.statusMessage).textSelection(.enabled)
                    .foregroundStyle(file.conflict != nil || file.issue != nil || file.isMissing ? Color.orange : Color.secondary)
                Spacer(minLength: 0)
                if file.conflict != nil {
                    Button("Compare Versions…", action: showComparison).controlHover()
                        .disabled(file.isSaving).accessibilityIdentifier("compareSQLFileVersions")
                }
                if file.isMissing || file.conflict != nil || file.issue != nil {
                    Button("Save As…") { workspace.saveSQLFile(document, chooseLocation: true) }.controlHover()
                        .disabled(file.isSaving).accessibilityIdentifier("saveSQLFileCopy")
                }
            }
            if file.recoveryURL != nil {
                SQLFileRecoveryStatusView(document: document, workspace: workspace, isSaving: file.isSaving)
            }
        }
        .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .contain).accessibilityIdentifier("documentFileBinding")
        .sheet(item: comparison.projectedValue) { selected in
            SQLFileComparisonView(document: document, workspace: workspace, file: file, comparison: selected,
                refresh: showComparison, close: { comparison.wrappedValue = nil })
        }
    }

    private func showComparison() {
        guard let conflict = file.conflict else { return }
        comparison.wrappedValue = SQLFileComparison(fileID: file.id, conflict: conflict, localText: file.text)
    }
}

struct SQLFileRecoveryStatusView: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var workspace: ApplicationWorkspace
    var isSaving = false

    var body: some View {
        if let recoveryURL = document.fileRecoveryURL {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Preserved external version: \(recoveryURL.path)")
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle).foregroundStyle(.orange)
                Spacer(minLength: 0)
                Button("Open Preserved Version") {
                    Task { await workspace.openPreservedSQLFileVersion(document) }
                }.controlHover().disabled(isSaving)
                    .accessibilityIdentifier("openPreservedSQLFileVersion")
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("sqlFileRecoveryNotice")
        }
    }
}

private struct SQLFileComparisonView: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject var file: SQLFileDocument
    let comparison: SQLFileComparison
    let refresh: () -> Void
    let close: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var isCurrent: Bool {
        document.fileDocument?.id == comparison.fileID && file.conflict?.id == comparison.conflict.id &&
            file.text.utf8.elementsEqual(comparison.localText.utf8)
    }
    private var canResolve: Bool { isCurrent && !file.isSaving && !file.isChecking }
    private var editorTheme: EditorTheme {
        if workspace.editorThemes.selectedThemeID == EditorThemeStore.automaticID,
           let theme = workspace.appearance.selectedColorTheme { return theme }
        return workspace.editorThemes.effectiveTheme(isDark: colorScheme == .dark)
    }
    private var engine: DatabaseEngine {
        workspace.library.savedConnections.first { $0.id == document.profileID }?.engine ?? .postgresql
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SQL File Changed").font(.title2)
                Spacer()
                Button("Done", action: close).controlHover().keyboardShortcut(.cancelAction)
                    .disabled(file.isSaving)
            }
            Text(comparison.conflict.url.path).font(.caption).appSecondaryText().textSelection(.enabled)
            Text("Keep a copy of the local draft, accept the external file, or replace the external version shown here. All views of this file share its text.")
                .font(.callout)
            if !isCurrent {
                HStack(spacing: 8) {
                    Label("The draft or external file changed while you were comparing. Refresh before choosing a version.",
                        systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    Button("Refresh Comparison", action: refresh).controlHover()
                        .disabled(file.conflict == nil || file.isSaving)
                }.font(.callout)
                .accessibilityIdentifier("staleSQLFileComparison")
            }
            HSplitView {
                version("Local Draft", text: comparison.localText)
                version("External File", text: comparison.conflict.externalText)
            }
            .frame(minHeight: 280, maxHeight: .infinity)
            if let issue = file.issue ?? workspace.error {
                Text(issue).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button("Keep Local Copy…") {
                    guard canResolve else { return }
                    workspace.saveSQLFile(document, chooseLocation: true)
                    if document.fileDocument?.id != comparison.fileID || file.conflict == nil { close() }
                }.controlHover().disabled(!canResolve)
                    .help("Save this draft to a separate file. Other views keep their current file.")
                    .accessibilityIdentifier("keepLocalSQLFileCopy")
                Spacer()
                if file.isSaving { ProgressView().controlSize(.small) }
                Button("Use External Version", role: .destructive) { resolve(.useExternal) }
                    .controlHover().disabled(!canResolve).accessibilityIdentifier("useExternalSQLFileVersion")
                Button("Replace Reviewed External Version", role: .destructive) { resolve(.replaceExternal) }
                    .controlHover().disabled(!canResolve).accessibilityIdentifier("replaceExternalSQLFileVersion")
            }
        }
        .padding(20).frame(minWidth: 800, minHeight: 500)
        .background(AppPalette.background).tint(AppPalette.accent).focusEffectDisabled()
        .applicationTheme(appearance: workspace.appearance)
    }

    private func version(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(text.utf8.count.formatted()) bytes").font(.caption).appSecondaryText()
            }
            SQLEditorView(text: .constant(text), isEditable: false, engine: engine, editorTheme: editorTheme)
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(title)
        }
        .padding(8)
    }

    private func resolve(_ decision: SQLFileConflictDecision) {
        guard canResolve else { return }
        let conflictID = comparison.conflict.id
        let reviewedText = comparison.localText
        Task {
            await workspace.resolveSQLFileConflict(document, conflictID: conflictID, decision: decision,
                expectedText: reviewedText)
            if document.fileDocument?.id != comparison.fileID || file.conflict == nil { close() }
        }
    }
}
