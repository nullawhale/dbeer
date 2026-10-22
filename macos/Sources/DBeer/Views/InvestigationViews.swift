import AppKit
import SwiftUI

/// The library persists independently of the tabs that happen to be open.
struct InvestigationLibraryView: View {
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject private var library: InvestigationLibraryModel
    private var query = SwiftUI.State(initialValue: "")

    init(workspace: ApplicationWorkspace) {
        self.workspace = workspace
        self.library = workspace.investigations
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Investigations").font(.headline)
                Spacer(minLength: 0)
                if library.isLoading || library.isSaving { ProgressView().controlSize(.mini) }
                ControlIconButton(systemName: "plus") {
                    Task { _ = await workspace.newInvestigation() }
                }.disabled(!library.isLoaded || !workspace.canManageWorkspace)
                    .help("New investigation").accessibilityLabel("New Investigation")
                    .accessibilityIdentifier("createInvestigation")
                WorkspaceSidebarCloseButton(workspace: workspace, panel: .investigations)
            }
            .padding(.horizontal, 12).frame(height: 36)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").appSecondaryText().accessibilityHidden(true)
                TextField("Search investigations", text: query.projectedValue)
                    .textFieldStyle(.plain).onExitCommand { query.wrappedValue = "" }
                    .accessibilityLabel("Search investigations")
                if !query.wrappedValue.isEmpty {
                    ControlIconButton(systemName: "xmark") { query.wrappedValue = "" }
                        .help("Clear search").accessibilityLabel("Clear investigation search")
                }
            }.padding(.horizontal, 12).frame(height: 40)
            Divider()
            List {
                ForEach(documents) { document in
                    Button { _ = workspace.openInvestigation(id: document.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(document.title, systemImage: "doc.richtext").lineLimit(1)
                            Text("\(document.blocks.count) blocks · \(document.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).appSecondaryText().lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).catalogRowHover()
                        .disabled(!workspace.canManageWorkspace)
                        .accessibilityIdentifier("openInvestigation-\(document.id.uuidString)")
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .overlay {
                if library.isLoaded, library.documents.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.richtext").font(.title2).accessibilityHidden(true)
                        Text("Keep notes, SQL blocks and saved results together.")
                            .font(.callout).multilineTextAlignment(.center)
                        Button("New Investigation") { Task { _ = await workspace.newInvestigation() } }
                            .controlHover().disabled(!workspace.canManageWorkspace)
                    }.padding().appSecondaryText()
                } else if library.isLoaded, documents.isEmpty {
                    Text("No matching investigations").appSecondaryText().padding().allowsHitTesting(false)
                }
            }
            .accessibilityIdentifier("investigationsLibraryList")
            if let error = library.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .font(.caption).textSelection(.enabled).padding(10)
                    .accessibilityIdentifier("investigationsLibraryError")
                Button("Retry") { Task { await library.restore() } }.controlHover().padding(.bottom, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("investigationsLibrary")
        .task { await library.restore() }
    }

    private var documents: [StoredInvestigation] {
        let search = query.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.documents.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
}

struct InvestigationDocumentView: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var model: InvestigationDocumentModel
    @ObservedObject var workspace: ApplicationWorkspace
    private var choosingSnapshot = SwiftUI.State(initialValue: false)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext").appSecondaryText().accessibilityHidden(true)
                TextField("Investigation title", text: $model.title)
                    .textFieldStyle(.plain).font(.headline)
                    .disabled(!canEdit)
                    .accessibilityLabel("Investigation title")
                    .accessibilityIdentifier("investigationTitle")
                if model.isSaving || childIsBusy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(model.isSaving ? "Saving investigation" : "A SQL block is busy")
                }
                Button("Save") { Task { _ = await workspace.saveInvestigation(document) } }
                    .controlHover().disabled(!canEdit || model.isSaving)
                    .help("Save the title and all blocks to the local investigation library")
                    .accessibilityIdentifier("saveInvestigation")
            }.padding(.horizontal, 12).frame(height: 40)
            Divider()
            if let reason = model.unavailableReason {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Investigation unavailable", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(reason).textSelection(.enabled)
                    Text("Its saved reference has been retained. No replacement document was created.")
                        .font(.callout).appSecondaryText()
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("investigationUnavailable")
            } else {
                GeometryReader { geometry in
                    if geometry.size.width >= 560 {
                        HSplitView {
                            contents.frame(minWidth: 150, idealWidth: 185, maxWidth: 250)
                            selectedBlock.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        VStack(spacing: 0) {
                            compactContents
                            Divider()
                            selectedBlock.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            if let error = model.error {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .accessibilityIdentifier("investigationSaveError")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("investigationDocument")
        .sheet(isPresented: choosingSnapshot.projectedValue) {
            InvestigationSnapshotPicker(workspace: workspace) { snapshot in
                _ = workspace.addInvestigationSnapshot(document, snapshotID: snapshot.id)
                choosingSnapshot.wrappedValue = false
            }
        }
    }

    private var canEdit: Bool { workspace.canEditInvestigation(document) }
    private var childIsBusy: Bool {
        model.allSQLDocuments.contains {
            $0.isRunning || $0.isNavigatingTable || $0.grid?.isApplying == true || $0.runtime?.isConnecting == true
        }
    }

    private var contents: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Contents").font(.headline)
                Spacer(minLength: 4)
                addBlockMenu
            }.padding(.horizontal, 10).frame(height: 36)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.blocks.enumerated()), id: \.element.id) { index, block in
                        Button { select(block.id) } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(index + 1)").monospacedDigit().appSecondaryText().frame(width: 18)
                                Image(systemName: symbol(block.kind)).frame(width: 14).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(blockTitle(block, index: index)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    if let child = model.sqlDocument(for: block.id) {
                                        InvestigationSQLBlockStatus(document: child, workspace: workspace)
                                    }
                                }
                            }.font(.caption).padding(7).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).controlHover()
                            .background(model.selectedBlockID == block.id ? AppPalette.accent.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: ControlHoverAppearance.cornerRadius))
                            .disabled(!canEdit)
                            .accessibilityLabel("\(index + 1). \(blockTitle(block, index: index))")
                            .accessibilityValue(model.selectedBlockID == block.id ? "Selected" : "")
                            .accessibilityIdentifier("selectInvestigationBlock-\(block.id.uuidString)")
                    }
                }.padding(5)
            }
            Divider()
            blockOrderControls.padding(8)
        }
        .background(AppPalette.isCustom ? AppPalette.panel : Color.primary.opacity(0.02))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("investigationContents")
    }

    private var compactContents: some View {
        HStack(spacing: 7) {
            Menu {
                ForEach(Array(model.blocks.enumerated()), id: \.element.id) { index, block in
                    Button("\(index + 1). \(blockTitle(block, index: index))") { select(block.id) }
                }
            } label: {
                Label(selectedBlockTitle, systemImage: "list.bullet").lineLimit(1)
            }.controlHover().disabled(!canEdit || model.blocks.isEmpty)
                .accessibilityLabel("Investigation contents")
                .accessibilityIdentifier("investigationCompactContents")
            Spacer(minLength: 0)
            addBlockMenu
            blockOrderControls
        }.padding(.horizontal, 8).frame(height: 36)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("investigationContents")
    }

    private var addBlockMenu: some View {
        Menu {
            Button("Markdown") { addMarkdown() }
            Button("SQL") { addSQL() }
            Button("Saved Snapshot…") { if commitBlockEditor() { choosingSnapshot.wrappedValue = true } }
        } label: { Image(systemName: "plus").frame(width: 18) }
            .menuIndicator(.hidden).fixedSize().controlHover().disabled(!canEdit)
            .help("Add a block").accessibilityLabel("Add Investigation Block")
            .accessibilityIdentifier("addInvestigationBlock")
    }

    private var blockOrderControls: some View {
        HStack(spacing: ControlHoverAppearance.gap) {
            ControlIconButton(systemName: "arrow.up") { moveSelection(by: -1) }
                .disabled(!canEdit || selectedIndex == nil || selectedIndex == 0)
                .help("Move selected block up").accessibilityLabel("Move Block Up")
                .accessibilityIdentifier("moveInvestigationBlockUp")
            ControlIconButton(systemName: "arrow.down") { moveSelection(by: 1) }
                .disabled(!canEdit || selectedIndex == nil || selectedIndex == model.blocks.count - 1)
                .help("Move selected block down").accessibilityLabel("Move Block Down")
                .accessibilityIdentifier("moveInvestigationBlockDown")
            ControlIconButton(systemName: "trash") {
                guard let id = model.selectedBlockID else { return }
                Task { _ = await workspace.deleteInvestigationBlock(document, blockID: id) }
            }.disabled(!canEdit || model.selectedBlockID == nil)
                .help("Delete selected block after reviewing any pending SQL work")
                .accessibilityLabel("Delete Block").accessibilityIdentifier("deleteInvestigationBlock")
        }
    }

    @ViewBuilder private var selectedBlock: some View {
        if let block = model.selectedBlock {
            switch block.kind {
            case .markdown:
                InvestigationMarkdownView(text: Binding(get: { model.blocks.first { $0.id == block.id }?.text ?? "" },
                    set: { model.setText($0, for: block.id) }), isEditable: canEdit)
                    .id(block.id)
            case .sql:
                if let child = model.sqlDocument(for: block.id) {
                    VStack(spacing: 0) {
                        InvestigationSQLBlockContext(document: child, workspace: workspace)
                        Divider()
                        SQLDocumentPane(document: child, workspace: workspace)
                    }.id(block.id)
                }
            case .snapshot:
                if let snapshot = workspace.investigationSnapshotDocument(document, blockID: block.id),
                   let page = snapshot.snapshotModel {
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Snapshot explanation").font(.caption).appSecondaryText()
                            TextEditor(text: Binding(get: { model.blocks.first { $0.id == block.id }?.explanation ?? "" },
                                set: { model.setExplanation($0, for: block.id) }))
                                .font(.body).frame(minHeight: 46, idealHeight: 62, maxHeight: 92)
                                .disabled(!canEdit)
                                .accessibilityLabel("Snapshot explanation")
                                .accessibilityIdentifier("investigationSnapshotExplanation")
                            if !block.explanation.isEmpty {
                                InvestigationMarkdownPreview(source: block.explanation)
                                    .frame(maxHeight: 80)
                                    .accessibilityIdentifier("investigationSnapshotExplanationPreview")
                            }
                        }.padding(10)
                        Divider()
                        ResultSnapshotDocumentView(document: snapshot, model: page, workspace: workspace)
                    }.id(block.id)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.richtext").font(.largeTitle).appSecondaryText().accessibilityHidden(true)
                Text("Add a block to begin").font(.headline)
                Text("Use Markdown for notes, SQL for an independent session, or a saved snapshot for offline results.")
                    .font(.callout).appSecondaryText().multilineTextAlignment(.center)
                HStack {
                    Button("Add Markdown") { addMarkdown() }.controlHover()
                        .accessibilityIdentifier("addFirstInvestigationMarkdown")
                    Button("Add SQL") { addSQL() }.controlHover()
                        .accessibilityIdentifier("addFirstInvestigationSQL")
                }.disabled(!canEdit)
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedIndex: Int? { model.blocks.firstIndex { $0.id == model.selectedBlockID } }
    private var selectedBlockTitle: String {
        guard let index = selectedIndex else { return "Contents" }
        return "\(index + 1). " + blockTitle(model.blocks[index], index: index)
    }
    private func select(_ id: UUID) {
        guard canEdit, commitBlockEditor() else { return }
        model.selectBlock(id)
        if let pane = workspace.pane(containing: document.id) { workspace.activatePane(pane) }
    }
    private func commitBlockEditor() -> Bool {
        workspace.presentationWindow?.makeFirstResponder(nil) != false
    }
    private func addMarkdown() {
        guard canEdit, commitBlockEditor() else { return }
        _ = workspace.addInvestigationMarkdown(document)
    }
    private func addSQL() {
        guard canEdit, commitBlockEditor() else { return }
        _ = workspace.addInvestigationSQL(document)
    }
    private func moveSelection(by offset: Int) {
        guard canEdit, let id = model.selectedBlockID else { return }
        model.moveBlock(id, by: offset)
    }
    private func symbol(_ kind: InvestigationBlockKind) -> String {
        switch kind { case .markdown: "text.alignleft"; case .sql: "chevron.left.forwardslash.chevron.right"; case .snapshot: "pin.fill" }
    }
    private func blockTitle(_ block: StoredInvestigationBlock, index: Int) -> String {
        switch block.kind {
        case .markdown:
            let first = block.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let title = first.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
            return title.isEmpty ? "Markdown" : title
        case .sql: return "SQL Block"
        case .snapshot: return "Saved Snapshot"
        }
    }
}

private struct InvestigationMarkdownView: View {
    @Binding var text: String
    let isEditable: Bool

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Markdown source").font(.caption).appSecondaryText()
                TextEditor(text: $text).font(.system(.body, design: .monospaced)).disabled(!isEditable)
                    .accessibilityLabel("Markdown source").accessibilityIdentifier("investigationMarkdownSource")
            }.padding(10).frame(minHeight: 120, idealHeight: 220)
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview").font(.caption).appSecondaryText()
                InvestigationMarkdownPreview(source: text)
                    .accessibilityIdentifier("investigationMarkdownPreview")
            }.padding(10).frame(minHeight: 100, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("investigationMarkdownBlock")
    }
}

private struct InvestigationMarkdownPreview: View {
    let source: String
    private var rendered: AttributedString {
        (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full))) ?? AttributedString(source)
    }
    var body: some View {
        ScrollView {
            Text(rendered).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct InvestigationSQLBlockContext: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var workspace: ApplicationWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Independent SQL block").fontWeight(.medium)
                Spacer(minLength: 0)
                InvestigationSQLBlockStatus(document: document, workspace: workspace)
            }
            if document.profileID == nil {
                Text("Choose this block’s connection before running it.").appSecondaryText()
            } else if !workspace.library.savedConnections.contains(where: { $0.id == document.profileID }) {
                Label("This block’s saved connection is unavailable. Choose a connection explicitly.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if document.runtime?.sessionId != nil {
                HStack {
                    Text("This block owns its session and transaction.").appSecondaryText()
                    Spacer(minLength: 0)
                    Button("Disconnect Block") { Task { _ = await workspace.disconnectInvestigationBlock(document) } }
                        .controlHover().disabled(document.isRunning)
                        .accessibilityIdentifier("disconnectInvestigationBlock")
                }
            } else {
                Text("Run Block executes only this block. It connects when you run it.").appSecondaryText()
            }
        }.font(.caption).padding(.horizontal, 10).padding(.vertical, 7)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("investigationSQLContext")
    }
}

private struct InvestigationSQLBlockStatus: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var workspace: ApplicationWorkspace
    var body: some View {
        HStack(spacing: 4) {
            if document.isRunning || document.grid?.isApplying == true {
                ProgressView().controlSize(.mini)
                Text("Running")
            } else if document.runtime?.isConnecting == true { Text("Connecting") }
            else if document.runtime?.sessionId != nil { Text("Connected") }
            else { Text(document.profileID == nil ? "Unbound" : "Disconnected") }
            if document.localError != nil || document.executions.contains(where: { $0.failure != nil }) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityLabel("Block has an error")
            }
        }.font(.caption2).appSecondaryText()
    }
}

private struct InvestigationSnapshotPicker: View {
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject private var snapshots: ResultSnapshotsModel
    let insert: (ResultSnapshotSummary) -> Void
    @Environment(\.dismiss) private var dismiss

    init(workspace: ApplicationWorkspace, insert: @escaping (ResultSnapshotSummary) -> Void) {
        self.workspace = workspace
        self.snapshots = workspace.resultSnapshots
        self.insert = insert
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insert Saved Snapshot").font(.title2.weight(.semibold))
            Text("Choose an existing local artifact. Its explanation remains in the investigation if the saved data is later deleted.")
                .font(.callout).appSecondaryText()
            List(snapshots.snapshots) { snapshot in
                Button { insert(snapshot) } label: {
                    HStack {
                        Image(systemName: "pin.fill").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snapshot.title)
                            Text(snapshot.isAvailable ? "\(snapshot.rowCount.formatted()) saved rows" : "Saved artifact unavailable")
                                .font(.caption).appSecondaryText()
                        }
                        Spacer()
                        Image(systemName: "plus.circle").accessibilityHidden(true)
                    }.padding(.vertical, 3).contentShape(Rectangle())
                }.buttonStyle(.plain).controlHover()
                    .accessibilityIdentifier("insertInvestigationSnapshot-\(snapshot.id.uuidString)")
            }.accessibilityIdentifier("investigationSnapshotChoices")
            if snapshots.snapshots.isEmpty, !snapshots.isBusy {
                Text("No saved snapshots. Pin a completed result first.").appSecondaryText()
            }
            if let error = snapshots.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                if snapshots.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.controlHover().keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancelInvestigationSnapshot")
            }
        }.padding(20).frame(width: 580, height: 430)
            .accessibilityElement(children: .contain).accessibilityIdentifier("investigationSnapshotPicker")
            .task { await snapshots.refresh() }
    }
}
