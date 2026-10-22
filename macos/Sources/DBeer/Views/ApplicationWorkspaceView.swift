import AppKit
import SwiftUI

private enum WorkspaceChrome {
    // Paired rows on either side of the split share their divider positions.
    static let headerHeight: CGFloat = 36
    static let toolbarHeight: CGFloat = 40
}

struct ApplicationWorkspaceView: View {
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject private var commands: AppCommandRegistry
    @ObservedObject private var appearance: AppAppearance
    @Environment(\.colorScheme) private var colorScheme
    private var connectionEditorRequest = SwiftUI.State<ConnectionEditorRequest>(initialValue: .new)
    private var deletion = SwiftUI.State<SavedConnection?>(initialValue: nil)
    private var tabDragSessionID = SwiftUI.State(initialValue: UUID())
    private var sidebarWidth = SwiftUI.State<CGFloat>(initialValue: 260)
    @FocusState private var catalogSearchFocused: Bool

    init(workspace: ApplicationWorkspace) {
        self.workspace = workspace
        self.commands = workspace.commands
        self.appearance = workspace.appearance
    }

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebarRail(workspace: workspace)
            Divider()
            HSplitView {
                if let panel = workspace.sidebarPanel {
                    sidebar(panel)
                        .frame(minWidth: 230, idealWidth: sidebarWidth.wrappedValue, maxWidth: 420)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.onChange(of: geometry.size.width) { _, width in
                                    sidebarWidth.wrappedValue = width
                                }
                            }
                        }
                }
                VStack(spacing: 0) {
                    WorkspacePanesSplitView(workspace: workspace) { pane in
                        workingPane(pane)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        WorkspaceNotificationToast(notifications: workspace.notifications).padding(12)
                    }
                    Divider()
                    WorkspaceStatusBar(workspace: workspace, editConnection: editConnection)
                }
                .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .background(AppPalette.background).tint(AppPalette.accent)
        .applicationTheme(appearance: appearance)
        .focusEffectDisabled()
        .background(WorkspaceWindowCloseGuard(workspace: workspace).frame(width: 0, height: 0))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 7) {
                    Image(nsImage: NSImage(named: NSImage.Name(colorScheme == .dark ? "ToolbarIconDark" : "ToolbarIcon"))
                          ?? NSApplication.shared.applicationIconImage)
                        .renderingMode(.original)
                        .resizable().scaledToFit().frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    Text("DBeer").fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: Binding(get: { workspace.library.isConnectionEditorPresented },
            set: { workspace.library.isConnectionEditorPresented = $0 }),
            onDismiss: { connectionEditorRequest.wrappedValue = .new }) {
            ConnectionEditorView(model: workspace.library, request: connectionEditorRequest.wrappedValue,
                onConnect: { id, ssh in await workspace.connectProfile(id, sshSnapshot: ssh) }) {
                workspace.library.isConnectionEditorPresented = false
                connectionEditorRequest.wrappedValue = .new
            }
            .applicationTheme(appearance: appearance)
        }
        .sheet(item: $workspace.inspection) { inspection in
            CatalogInspectionView(inspection: inspection) { workspace.inspection = nil }
                .applicationTheme(appearance: appearance)
        }
        .sheet(item: Binding(get: { workspace.typeInspection },
            set: { if $0 == nil { workspace.dismissPostgresTypeInspection() } })) { inspection in
            postgresTypeInspector(inspection)
        }
        .sheet(item: $workspace.clusterInspection) { inspection in
            CassandraClusterView(inspection: inspection,
                refresh: { Task { await workspace.refreshClusterNodes() } },
                close: { workspace.clusterInspection = nil })
                .applicationTheme(appearance: appearance)
        }
        .sheet(isPresented: $workspace.isHistoryPresented) {
            SQLHistoryView(workspace: workspace)
                .applicationTheme(appearance: appearance)
        }
        .sheet(item: Binding(get: { workspace.dataComparison }, set: { if $0 == nil { workspace.dismissDataComparison() } })) { model in
            DataComparisonView(model: model, close: { workspace.dismissDataComparison() })
                .applicationTheme(appearance: appearance)
        }
        .sheet(item: Binding(get: { workspace.schemaComparison }, set: { if $0 == nil { workspace.dismissSchemaComparison() } })) { model in
            SchemaComparisonView(model: model, close: { workspace.dismissSchemaComparison() })
                .applicationTheme(appearance: appearance)
        }
        .sheet(isPresented: $workspace.isSnapshotsPresented) {
            ResultSnapshotsView(model: workspace.resultSnapshots) { snapshot in
                if workspace.openResultSnapshot(id: snapshot.id, title: snapshot.title) != nil {
                    workspace.isSnapshotsPresented = false
                }
            }
                .applicationTheme(appearance: appearance)
        }
        .sheet(item: $workspace.insertCopySelection) { selection in
            InsertCopyView(workspace: workspace, selection: selection)
                .applicationTheme(appearance: appearance)
        }
        .sheet(isPresented: Binding(get: { workspace.importPreview != nil },
            set: { if !$0 { workspace.importPreview = nil } })) {
            ProfileImportView(workspace: workspace)
                .applicationTheme(appearance: appearance)
        }
        .alert("Delete Connection?", isPresented: Binding(get: { deletion.wrappedValue != nil },
            set: { if !$0 { deletion.wrappedValue = nil } })) {
            Button("Cancel", role: .cancel) { deletion.wrappedValue = nil }
            Button("Delete", role: .destructive) {
                if let profile = deletion.wrappedValue {
                    Task {
                        if await workspace.disconnectProfile(profile.id) {
                            _ = await workspace.library.deleteConnection(profile.id)
                        }
                    }
                }
                deletion.wrappedValue = nil
            }
        } message: {
            Text("Delete the saved profile and its password from Keychain?")
        }
    }

    private func postgresTypeInspector(_ inspection: PostgresTypeInspectionModel) -> some View {
        PostgresTypeInspectionView(model: inspection,
            refresh: {
                Task {
                    guard workspace.typeInspection?.id == inspection.id else { return }
                    await workspace.refreshPostgresTypeInspection()
                }
            },
            preview: { change in
                Task {
                    guard workspace.typeInspection?.id == inspection.id else { return }
                    await workspace.previewPostgresTypeChange(change)
                }
            },
            discardPreview: {
                if workspace.typeInspection?.id == inspection.id { workspace.discardPostgresTypePreview() }
            },
            stop: {
                if workspace.typeInspection?.id == inspection.id { workspace.stopPostgresTypeInspection() }
            },
            openSQL: {
                guard workspace.typeInspection?.id == inspection.id else { return }
                if workspace.openPostgresTypeSQLDraft() != nil { workspace.dismissPostgresTypeInspection() }
            },
            close: {
                if workspace.typeInspection?.id == inspection.id { workspace.dismissPostgresTypeInspection() }
            })
            .applicationTheme(appearance: appearance)
            .onDisappear {
                if workspace.typeInspection?.id == inspection.id { workspace.dismissPostgresTypeInspection() }
            }
    }

    private func sidebar(_ panel: WorkspaceSidebarPanel) -> some View {
        Group {
            switch panel {
            case .connections: connectionsSidebar
            case .files: SQLFilesSidebarView(workspace: workspace)
            case .library: SQLLibrarySidebarView(workspace: workspace)
            case .investigations: InvestigationLibraryView(workspace: workspace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.isCustom ? AppPalette.sidebar : AppPalette.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panel.title)
        .accessibilityIdentifier("workspaceSidebar-\(panel.rawValue)")
    }

    private var connectionsSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connections").font(.headline)
                Spacer()
                ControlIconButton(systemName: "plus") {
                    connectionEditorRequest.wrappedValue = .new
                    workspace.library.isConnectionEditorPresented = true
                }
                .help(commands.help(for: .newConnection))
                .accessibilityLabel("New Connection")
                .accessibilityIdentifier("newConnection")
                WorkspaceSidebarCloseButton(workspace: workspace, panel: .connections)
            }
            .padding(.horizontal, 12)
            .frame(height: WorkspaceChrome.headerHeight)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .appSecondaryText()
                    .accessibilityHidden(true)
                TextField("Search object names", text: $workspace.catalogSearch)
                    .textFieldStyle(.plain)
                    .focused($catalogSearchFocused)
                    .task(id: workspace.catalogSearchFocusRequested) {
                        guard workspace.catalogSearchFocusRequested else { return }
                        catalogSearchFocused = true
                        workspace.catalogSearchFocusRequested = false
                    }
                    .onExitCommand { workspace.catalogSearch = "" }
                    .help(commands.help(for: .findInConnections))
                    .accessibilityLabel("Search object names")
                    .accessibilityIdentifier("catalogSearch")
                if !workspace.catalogSearch.isEmpty {
                    ControlIconButton(systemName: "xmark") { workspace.catalogSearch = "" }
                        .help("Clear search (Esc)")
                        .accessibilityLabel("Clear search")
                        .accessibilityIdentifier("clearCatalogSearch")
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: WorkspaceChrome.toolbarHeight)
            .background(AppPalette.isCustom ? AppPalette.panel : Color.primary.opacity(0.025))
            .task(id: workspace.catalogSearch) {
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { return }
                await workspace.searchCatalog()
            }
            Divider()
            List {
                ForEach(workspace.library.savedConnections) { profile in
                    profileRow(profile)
                }
            }
            .listStyle(.sidebar)
            .catalogContextMenu()
            .scrollContentBackground(.hidden)
        }
        .background(AppPalette.isCustom ? AppPalette.sidebar : AppPalette.background)
    }

    private func profileRow(_ profile: SavedConnection) -> some View {
        ProfileCatalogRow(profile: profile, workspace: workspace,
            edit: { editConnection(profile.id) }, duplicate: { duplicateConnection(profile.id) },
            delete: { deletion.wrappedValue = profile })
    }

    private func editConnection(_ id: UUID) {
        Task {
            guard let current = await workspace.prepareConnectionEditor(id) else { return }
            connectionEditorRequest.wrappedValue = .edit(current)
            workspace.library.isConnectionEditorPresented = true
        }
    }

    private func duplicateConnection(_ id: UUID) {
        guard !workspace.library.isSavingConnection,
              let current = workspace.library.savedConnections.first(where: { $0.id == id }) else { return }
        connectionEditorRequest.wrappedValue = .duplicate(current)
        workspace.library.isConnectionEditorPresented = true
    }

    private func workingPane(_ pane: WorkspacePaneID) -> some View {
        VStack(spacing: 0) {
            documentBar(in: pane)
            Divider()
            Group {
                if let document = workspace.selectedDocument(in: pane) {
                    if document.isInvestigation, let model = document.investigationModel {
                        InvestigationDocumentView(document: document, model: model, workspace: workspace)
                            .id(document.id)
                    } else if document.isSnapshot {
                        if let model = document.snapshotModel {
                            ResultSnapshotDocumentView(document: document, model: model, workspace: workspace)
                                .id(document.id)
                        } else {
                            Text("Snapshot unavailable. Its saved reference is missing.")
                                .appSecondaryText().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        SQLDocumentPane(document: document, workspace: workspace).id(document.id)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: workspace.paneLayout.isSplit ? "rectangle.split.2x1" : "doc.text")
                            .font(.largeTitle).appSecondaryText()
                            .accessibilityHidden(true)
                        Text(workspace.paneLayout.isSplit ? "No tabs in this pane" : "No tabs open").appSecondaryText()
                        Button("New SQL Tab") { workspace.newDocument(in: pane) }.controlHover()
                        if workspace.paneLayout.isSplit {
                            Text("Move a tab here with its menu or drag it into this tab bar.")
                                .font(.caption).appSecondaryText().multilineTextAlignment(.center)
                        }
                    }
                    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("emptyWorkspacePane-\(pane.rawValue)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(workspace.paneLayout.isSplit && workspace.activePaneID == pane ? AppPalette.accent : Color.clear)
                .frame(height: 2).allowsHitTesting(false).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(workspace.paneTitle(pane))
        .accessibilityValue(workspace.activePaneID == pane ? "Active pane" : "Inactive pane")
        .accessibilityIdentifier("workspacePaneContent-\(pane.rawValue)")
        .environment(\.colorScheme, colorScheme)
        .applicationTheme(appearance: appearance)
        .tint(AppPalette.accent)
        .focusEffectDisabled()
    }

    private func documentBar(in pane: WorkspacePaneID) -> some View {
        HStack(spacing: ControlHoverAppearance.gap) {
            ScrollView(.horizontal) {
                HStack(spacing: ControlHoverAppearance.gap) {
                    ForEach(Array(workspace.documents(in: pane).enumerated()), id: \.element.id) { index, document in
                        DocumentTab(document: document, isSelected: workspace.selectedDocument(in: pane)?.id == document.id,
                            select: { workspace.selectDocument(document.id, in: pane) },
                            close: { Task { await workspace.closeDocument(document) } },
                            openInNewTab: {
                                if document.table != nil { Task { await workspace.openTableInNewTab(document) } }
                                else { workspace.openSQLFileInNewTab(document) }
                            },
                            split: workspace.paneLayout.canSplit && workspace.canManageWorkspace
                                ? { workspace.splitDocument(document.id, direction: $0) } : nil,
                            unsplitCurrent: workspace.paneLayout.isSplit ? { workspace.unsplitPane(pane) } : nil,
                            unsplitAll: workspace.paneLayout.isSplit ? { workspace.mergePanes() } : nil,
                            moveToPanes: workspace.paneLayout.paneIDs.filter { $0 != pane }.map { target in
                                DocumentTabPaneAction(id: target, title: workspace.paneTitle(target),
                                    perform: { moveDocument(document.id, to: target) })
                            },
                            moveEarlier: index > 0 ? { moveDocument(document.id, to: pane, at: index - 1) } : nil,
                            moveLater: index + 1 < workspace.documents(in: pane).count
                                ? { moveDocument(document.id, to: pane, at: index + 1) } : nil,
                            canRename: !document.isInvestigation || workspace.canEditInvestigation(document))
                            .draggable(WorkspaceTabTransfer(workspaceSessionID: tabDragSessionID.wrappedValue, documentID: document.id))
                            .dropDestination(for: WorkspaceTabTransfer.self) { values, _ in
                                moveDroppedTab(values, to: pane, before: document.id)
                            }
                    }
                }
            }
            .scrollIndicators(.hidden)
            ControlIconButton(systemName: "plus") { workspace.newDocument(in: pane) }
                .help(commands.help(for: .newSQLTab))
                .accessibilityLabel("New SQL Tab")
                .accessibilityIdentifier("newSQLTab")
        }
        .padding(ControlHoverAppearance.gap)
        .frame(height: WorkspaceChrome.headerHeight)
        .background(AppPalette.isCustom ? AppPalette.panel : Color.primary.opacity(0.025))
        .contentShape(Rectangle())
        .dropDestination(for: WorkspaceTabTransfer.self) { values, _ in moveDroppedTab(values, to: pane) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("documentBar-\(pane.rawValue)")
    }

    private func moveDocument(_ id: UUID, to pane: WorkspacePaneID, at index: Int? = nil) {
        workspace.moveDocument(id, to: pane, at: index)
    }

    private func moveDroppedTab(_ values: [WorkspaceTabTransfer], to pane: WorkspacePaneID, before target: UUID? = nil) -> Bool {
        guard values.count == 1, let id = values[0].validatedDocumentID(in: workspace, sessionID: tabDragSessionID.wrappedValue),
              id != target else { return false }
        var index = target.flatMap { target in workspace.documents(in: pane).firstIndex { $0.id == target } }
        if let destination = index, workspace.pane(containing: id) == pane,
           let source = workspace.documents(in: pane).firstIndex(where: { $0.id == id }), source < destination {
            index = destination - 1
        }
        moveDocument(id, to: pane, at: index)
        return true
    }

}

struct DocumentTabPaneAction: Identifiable {
    let id: WorkspacePaneID
    let title: String
    let perform: () -> Void
}

struct DocumentTab: View {
    @ObservedObject var document: SQLDocument
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    var openInNewTab: (() -> Void)? = nil
    var split: ((WorkspaceSplitDirection) -> Void)? = nil
    var unsplitCurrent: (() -> Void)? = nil
    var unsplitAll: (() -> Void)? = nil
    var moveToPanes: [DocumentTabPaneAction] = []
    var moveEarlier: (() -> Void)? = nil
    var moveLater: (() -> Void)? = nil
    var canRename = true

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: select) {
                HStack(spacing: 6) {
                    if document.fileDocument?.isDirty == true {
                        Image(systemName: "circle.fill").font(.system(size: 5)).accessibilityHidden(true)
                    }
                    if document.investigationModel?.isDirty == true {
                        Image(systemName: "circle.fill").font(.system(size: 5)).accessibilityHidden(true)
                    }
                    if document.isInvestigation {
                        Image(systemName: "doc.richtext").font(.caption).accessibilityLabel("Investigation")
                    }
                    if document.isSnapshot {
                        Image(systemName: "pin.fill").font(.caption).accessibilityLabel("Offline snapshot")
                    }
                    if document.fileDocument?.conflict != nil || document.fileDocument?.isMissing == true {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
                    }
                    Text(document.title).lineLimit(1)
                    if isBusy {
                        ProgressView().controlSize(.mini)
                    }
                }
                // Reserve the close target inside the full tab button, so its
                // hover and selection also cover the surrounding empty space.
                .padding(.leading, 8)
                .padding(.trailing, 18 + ControlHoverAppearance.gap * 2)
                .frame(height: 23)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).controlHover()
            .accessibilityLabel(document.title)
            .accessibilityIdentifier("selectDocument-\(document.id.uuidString)")
            Button(action: close) {
                Image(systemName: "xmark").font(.caption2)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }.controlHover()
                .buttonStyle(.plain).help("Close tab")
                .accessibilityLabel("Close \(document.title)")
                .accessibilityIdentifier("closeDocument-\(document.id.uuidString)")
                .padding(.trailing, ControlHoverAppearance.gap)
        }
        .font(.system(size: 12)).frame(height: 23)
        .background(isSelected ? AppPalette.accent.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: ControlHoverAppearance.cornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("documentTab-\(document.id.uuidString)")
        .accessibilityActions {
            if let split {
                ForEach(WorkspaceSplitDirection.allCases, id: \.self) { direction in
                    Button(direction.title) { split(direction) }
                }
            }
            if let unsplitCurrent { Button("Unsplit Current", action: unsplitCurrent) }
            if let unsplitAll { Button("Unsplit All", action: unsplitAll) }
            ForEach(moveToPanes) { target in
                Button("Move to \(target.title)", action: target.perform)
            }
            if let moveEarlier { Button("Move Tab Left", action: moveEarlier) }
            if let moveLater { Button("Move Tab Right", action: moveLater) }
        }
        .contextMenu {
            if document.table != nil || document.fileURL != nil, let openInNewTab {
                Button("Open in New Tab", action: openInNewTab)
                    .disabled(document.isNavigatingTable)
            }
            Button("Rename…") {
                let alert = NSAlert()
                alert.messageText = document.isInvestigation ? "Rename Investigation" : document.isSnapshot ? "Rename Snapshot Tab" : "Rename SQL Tab"
                let field = NSTextField(string: document.title)
                field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
                alert.accessoryView = field
                alert.addButton(withTitle: "Rename")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        if let investigation = document.investigationModel { investigation.title = title }
                        else { document.title = title }
                    }
                }
            }.disabled(document.isNavigatingTable || !canRename)
            if let split {
                Divider()
                ForEach(WorkspaceSplitDirection.allCases, id: \.self) { direction in
                    Button(direction.title) { split(direction) }
                }
            }
            if let unsplitCurrent { Button("Unsplit Current", action: unsplitCurrent) }
            if let unsplitAll { Button("Unsplit All", action: unsplitAll) }
            if !moveToPanes.isEmpty {
                Menu("Move to Pane") {
                    ForEach(moveToPanes) { target in Button(target.title, action: target.perform) }
                }
            }
            if split != nil || unsplitAll != nil {
                Divider()
                Button("Move Tab Left") { moveEarlier?() }.disabled(moveEarlier == nil)
                Button("Move Tab Right") { moveLater?() }.disabled(moveLater == nil)
            }
            Button("Close", action: close)
        }
    }

    private var isBusy: Bool {
        document.isRunning || document.isNavigatingTable || document.grid?.isApplying == true ||
            document.investigationModel?.isSaving == true ||
            document.investigationModel?.allSQLDocuments.contains {
                $0.isRunning || $0.isNavigatingTable || $0.grid?.isApplying == true || $0.runtime?.isConnecting == true
            } == true
    }
}

struct SQLDocumentPane: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject private var commands: AppCommandRegistry
    @ObservedObject private var editorThemes: EditorThemeStore
    @ObservedObject private var appearance: AppAppearance
    @Environment(\.colorScheme) private var colorScheme
    private var resultSetIndex = SwiftUI.State(initialValue: 0)
    private var showingFilters = SwiftUI.State(initialValue: false)
    private var editingLibrary = SwiftUI.State<SQLLibraryEditRequest?>(initialValue: nil)

    init(document: SQLDocument, workspace: ApplicationWorkspace) {
        self.document = document
        self.workspace = workspace
        self.commands = workspace.commands
        self.editorThemes = workspace.editorThemes
        self.appearance = workspace.appearance
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                documentToolbar(compact: false).frame(minWidth: 620)
                documentToolbar(compact: true)
            }
            .padding(.horizontal, 8)
            .frame(height: WorkspaceChrome.toolbarHeight)
            Divider()
            if document.table == nil, let url = document.fileURL {
                libraryContext(url)
                Divider()
            }
            if document.table != nil, let error = document.tableNavigationError {
                HStack(alignment: .top, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).textSelection(.enabled)
                    Spacer(minLength: 4)
                    ControlIconButton(systemName: "xmark") { document.tableNavigationError = nil }
                        .help("Dismiss navigation message").accessibilityLabel("Dismiss navigation message")
                }
                .font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
                .accessibilityIdentifier("tableNavigationError")
                Divider()
            }
            if let notice = document.historyConnectionNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption).appSecondaryText()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .accessibilityIdentifier("historyConnectionNotice")
                Divider()
            }
            if document.table == nil, let file = document.fileDocument {
                SQLFileStatusView(document: document, workspace: workspace, file: file)
                Divider()
            } else if document.table == nil, let fileURL = document.fileURL {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").accessibilityHidden(true)
                        Text(fileURL.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    if document.restoredFileBinding {
                        Text(document.fileContentSHA256 == nil
                            ? "Recovered draft. The file has not been reloaded; use Save As to choose where to save it."
                            : "Recovered draft. The file has not been reloaded; Save checks for external changes.")
                            .accessibilityIdentifier("restoredFileBindingNotice")
                    }
                }
                .font(.caption).appSecondaryText()
                .padding(.horizontal, 12).padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("documentFileBinding")
                Divider()
            }
            if document.table == nil, document.fileDocument == nil, document.fileRecoveryURL != nil {
                SQLFileRecoveryStatusView(document: document, workspace: workspace)
                    .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }
            if document.table == nil {
                VSplitView {
                    SQLEditorView(text: $document.text, isEditable: document.fileDocument?.isSaving != true,
                        editorState: workspace.editorState, documentID: document.id,
                        engine: workspace.library.savedConnections.first { $0.id == document.profileID }?.engine ?? .postgresql,
                        selectionChanged: { document.selection = $0 },
                        onCommandEvent: { event, selection in
                            commands.handleKeyEvent(event, documentID: document.id, selection: selection)
                        }, completions: workspace.completions(profileID: document.profileID),
                        languageService: workspace.editorState.languageService,
                        completionContext: workspace.completionContext(profileID: document.profileID, keyspace: document.runtime?.currentKeyspace),
                        errorPosition: document.errorPosition,
                        editorTheme: effectiveEditorTheme,
                        successfulExecutionRanges: document.successfulExecutionRanges)
                        .frame(minHeight: 160, idealHeight: 240)
                    VStack(spacing: 0) {
                        executionBar
                        result
                    }.frame(minHeight: 180, maxHeight: .infinity)
                }
            } else {
                result.frame(maxHeight: .infinity)
            }
        }
        .onChange(of: document.selectedExecution) { _, _ in resultSetIndex.wrappedValue = 0 }
        .onChange(of: document.isRunning) { _, value in if value { resultSetIndex.wrappedValue = 0 } }
        .sheet(item: editingLibrary.projectedValue) { request in
            SQLLibraryEntryEditor(workspace: workspace, fileURL: request.url)
        }
    }

    private func canPerform(_ command: AppCommandID) -> Bool {
        commands.canPerform(command, context: commands.context(for: document))
    }

    private func perform(_ command: AppCommandID) {
        commands.perform(command, context: commands.context(for: document))
    }

    private func documentToolbar(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 8) {
            if document.table != nil, !compact { tableHistoryControls }
            Picker("Connection", selection: profileBinding) {
                Text(isInvestigationBlock ? "Unbound connection" : "Choose a connection").tag(Optional<UUID>.none)
                if let missingProfileID {
                    Text(workspace.library.savedConnections.contains { $0.id == missingProfileID }
                        ? "Connection outside library scope" : "Unavailable saved connection").tag(Optional(missingProfileID))
                        .help("Saved connection \(missingProfileID.uuidString)")
                }
                ForEach(workspace.availableSQLLibraryProfiles(for: document)) { profile in
                    Text(document.sqlLibraryEntryID == nil ? profile.name : profile.name + " · " + profile.policy.label)
                        .tag(Optional(profile.id))
                }
            }.controlHover().labelsHidden().accessibilityLabel("Connection").frame(minWidth: 64, maxWidth: compact ? .infinity : 220)
                .accessibilityIdentifier("documentConnection")
                .disabled(isInvestigationBlock ? !workspace.canBindInvestigationProfile(document) :
                    document.runtime?.sessionId != nil || document.isRunning || document.isNavigatingTable)
            if let profile = workspace.library.savedConnections.first(where: { $0.id == document.profileID }),
               (document.runtime?.policy ?? profile.policy).readOnly {
                Text(profile.engine == .cassandra ? "Local RO" : "RO")
                    .font(.caption2.weight(.regular)).foregroundStyle(.tertiary)
                    .help(profile.engine == .cassandra ? "Local readonly; use restricted server roles for strict protection" : "Readonly")
                    .accessibilityLabel(profile.engine == .cassandra ? "Local readonly" : "Readonly")
                    .accessibilityIdentifier("documentReadOnly")
            }
            if document.table != nil, document.grid != nil {
                Button {
                    showingFilters.wrappedValue.toggle()
                } label: {
                    if compact {
                        Image(systemName: "line.3.horizontal.decrease")
                    } else {
                        Label(document.tableFilters.isEmpty ? "Filter" : "Filter (\(document.tableFilters.count))",
                            systemImage: "line.3.horizontal.decrease")
                    }
                }.controlHover().controlSize(.small)
                    .disabled(!TableBrowseNavigation.isEnabled(document: document, workspace: workspace))
                    .accessibilityLabel(document.tableFilters.isEmpty ? "Filter" : "Filter (\(document.tableFilters.count))")
                    .accessibilityIdentifier("gridFilter")
                    .popover(isPresented: showingFilters.projectedValue) {
                        TableBrowseControls(document: document, workspace: workspace)
                    }
            }
            Spacer(minLength: 0)
            Button { perform(.stop) } label: {
                if compact { Image(systemName: "stop.fill") } else { Text("Stop") }
            }.controlHover()
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("stopQuery")
                .disabled(!canPerform(.stop))
                .help(commandHelp(.stop))
            if compact {
                Menu {
                    if document.table == nil {
                        if isInvestigationBlock {
                            Button("Run Statement") { perform(.runCurrent) }.disabled(!canPerform(.runCurrent))
                        } else {
                            Button("Run Script") { perform(.runScript) }.disabled(!canPerform(.runScript))
                        }
                        Menu("Run to File") {
                            Button("JSON…") { perform(.runToJSON) }.disabled(!canPerform(.runToJSON))
                            Button("CSV…") { perform(.runToCSV) }.disabled(!canPerform(.runToCSV))
                        }
                    } else {
                        Button("Back to Previous Table View") {
                            Task { await workspace.navigateTableBack(document) }
                        }.disabled(!canNavigateTableHistory || !document.canNavigateTableBack)
                        Button("Forward to Next Table View") {
                            Task { await workspace.navigateTableForward(document) }
                        }.disabled(!canNavigateTableHistory || !document.canNavigateTableForward)
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 18)
                }.menuIndicator(.hidden).fixedSize().controlHover()
                    .accessibilityLabel("More query actions")
                    .accessibilityIdentifier("queryActions")
            } else if document.table == nil {
                Button(isInvestigationBlock ? "Run Statement" : "Run Script") {
                    perform(isInvestigationBlock ? .runCurrent : .runScript)
                }.controlHover()
                    .disabled(!canPerform(isInvestigationBlock ? .runCurrent : .runScript))
                    .help(isInvestigationBlock ? "Run the current statement or selection in this block" :
                        commandHelp(.runScript) + " · Run the entire document, stopping at the first error")
                Menu("Run to File") {
                    Button("JSON…") { perform(.runToJSON) }
                    Button("CSV…") { perform(.runToCSV) }
                }.fixedSize().controlHover().disabled(!canPerform(.runToJSON))
                    .accessibilityIdentifier("runToFile")
            }
            Button {
                perform(primaryRunCommand)
            } label: {
                HStack(spacing: 6) {
                    if compact {
                        Image(systemName: document.table == nil ? "play.fill" : "arrow.clockwise")
                    } else {
                        Label(primaryRunTitle,
                            systemImage: document.table == nil ? "play" : "arrow.clockwise")
                    }
                    if !compact, let shortcut = commands.shortcuts.shortcut(for: primaryRunCommand) {
                        Text(shortcut.displayString).opacity(0.65)
                    }
                }.fixedSize(horizontal: true, vertical: false)
            }.controlHover()
                .buttonStyle(.borderedProminent)
                .disabled(document.isNavigatingTable || !canPerform(primaryRunCommand))
                .help(isInvestigationBlock ? "Run only this SQL block, stopping at its first error" : commandHelp(.runCurrent))
                .accessibilityLabel(primaryRunTitle)
                .accessibilityIdentifier(isInvestigationBlock ? "runInvestigationBlock" : "runQuery")
        }
    }

    private var isInvestigationBlock: Bool { workspace.isInvestigationSQLDocument(document) }
    private var primaryRunCommand: AppCommandID { isInvestigationBlock ? .runScript : .runCurrent }
    private var primaryRunTitle: String {
        isInvestigationBlock ? "Run Block" : document.table == nil ? "Run" : document.grid == nil ? "Load Data" : "Refresh"
    }
    private var profileBinding: Binding<UUID?> {
        Binding(get: { document.profileID }, set: { value in
            if isInvestigationBlock { _ = workspace.bindInvestigationProfile(document, profileID: value) }
            else { document.profileID = value }
        })
    }

    private func libraryContext(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if document.sqlLibraryEntryID != nil {
                    Label(workspace.selectedSQLLibraryEntry(for: document)?.fileURL.lastPathComponent ?? "Unavailable library reference",
                        systemImage: "books.vertical").lineLimit(1)
                    if let profile = workspace.library.savedConnections.first(where: { $0.id == document.profileID }) {
                        Text(profile.name + " · " + profile.policy.label).foregroundStyle(.tertiary).lineLimit(1)
                            .accessibilityIdentifier("sqlLibraryExecutionConnection")
                    }
                }
                Spacer(minLength: 0)
                Button(workspace.sqlLibrary.entry(at: url) == nil ? "Add to SQL Library…" : "Library Details…") {
                    editingLibrary.wrappedValue = SQLLibraryEditRequest(url: url)
                }.controlHover().accessibilityIdentifier("documentSQLLibraryDetails")
            }
            if let notice = workspace.sqlLibraryExecutionNotice(for: document) {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled)
                    .accessibilityIdentifier("sqlLibraryExecutionNotice")
            }
        }.font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
            .accessibilityElement(children: .contain).accessibilityIdentifier("sqlLibraryExecutionContext")
    }

    private var missingProfileID: UUID? {
        guard let id = document.profileID,
              !workspace.availableSQLLibraryProfiles(for: document).contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private var tableHistoryControls: some View {
        HStack(spacing: ControlHoverAppearance.gap) {
            ControlIconButton(systemName: "chevron.backward") {
                Task { await workspace.navigateTableBack(document) }
            }
            .disabled(!canNavigateTableHistory || !document.canNavigateTableBack)
            .help("Back to previous table view")
            .accessibilityLabel("Back to previous table view")
            .accessibilityIdentifier("tableNavigateBack")
            ControlIconButton(systemName: "chevron.forward") {
                Task { await workspace.navigateTableForward(document) }
            }
            .disabled(!canNavigateTableHistory || !document.canNavigateTableForward)
            .help("Forward to next table view")
            .accessibilityLabel("Forward to next table view")
            .accessibilityIdentifier("tableNavigateForward")
        }
    }

    private var canNavigateTableHistory: Bool {
        workspace.canStartOperation(document) && !workspace.isClosing && document.canNavigateTable
    }

    private func unloadedTable(_ table: TableReference, error: String? = nil) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Table data is not loaded", systemImage: table.kind == "view" ? "eye" : "tablecells")
                    .font(.title3)
                Text("This tab keeps its table and browsing settings. Load Data opens a new session and reads the selected page.")
                    .font(.callout).appSecondaryText()
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        .accessibilityIdentifier("unloadedTableError")
                }
                SwiftUI.Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    SwiftUI.GridRow {
                        Text("Schema / database").appSecondaryText()
                        Text(table.schema).textSelection(.enabled)
                    }
                    SwiftUI.GridRow {
                        Text(table.kind == "view" ? "View" : "Table").appSecondaryText()
                        Text(table.name).textSelection(.enabled)
                    }
                    SwiftUI.GridRow {
                        Text("Connection").appSecondaryText()
                        Text(workspace.library.savedConnections.first(where: { $0.id == document.profileID })?.name
                            ?? (missingProfileID == nil ? "Not selected" : "Unavailable saved connection"))
                    }
                    SwiftUI.GridRow {
                        Text("Saved page").appSecondaryText()
                        Text("\(document.page + 1)").monospacedDigit()
                    }
                }.font(.callout)
                if !document.tableFilters.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Saved filters").font(.headline)
                        ForEach(Array(document.tableFilters.enumerated()), id: \.offset) { _, filter in
                            Text(filterDescription(filter))
                                .font(.callout).textSelection(.enabled).lineLimit(3)
                        }
                    }
                }
                if !document.tableSort.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Saved sort").font(.headline)
                        ForEach(Array(document.tableSort.enumerated()), id: \.offset) { _, sort in
                            Text("\(sort.column) · \(sort.direction == "desc" ? "Descending" : "Ascending")")
                                .font(.callout).textSelection(.enabled)
                        }
                    }
                }
                if workspace.library.savedConnections.first(where: { $0.id == document.profileID })?.engine == .cassandra {
                    Text("Cassandra paging starts from the first page when loading a restored tab.")
                        .font(.caption).appSecondaryText()
                }
                if document.profileID == nil || missingProfileID != nil {
                    Text("Choose a connection above before loading this table.")
                        .font(.callout).foregroundStyle(.orange)
                }
                Button(error == nil ? "Load Data" : "Retry Load Data") { perform(.runCurrent) }
                    .controlHover().buttonStyle(.borderedProminent)
                    .disabled(document.isNavigatingTable || !canPerform(.runCurrent))
                    .accessibilityIdentifier("loadRestoredTable")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("unloadedTableContext")
    }

    private func filterDescription(_ filter: CatalogFilter) -> String {
        let operation = switch filter.operator {
        case "eq": "="
        case "ne": "≠"
        case "lt": "<"
        case "lte": "≤"
        case "gt": ">"
        case "gte": "≥"
        case "isNull": "is NULL"
        case "isNotNull": "is not NULL"
        default: filter.operator
        }
        return "\(filter.column) \(operation)" + (filter.value.map { " \(String(reflecting: $0))" } ?? "")
    }

    private var effectiveEditorTheme: EditorTheme {
        if editorThemes.selectedThemeID == EditorThemeStore.automaticID,
           let theme = appearance.selectedColorTheme { return theme }
        return editorThemes.effectiveTheme(isDark: colorScheme == .dark)
    }

    private func commandHelp(_ command: AppCommandID) -> String {
        commands.help(for: command)
    }

    private var displayedExecution: SQLExecution? {
        document.executions.indices.contains(document.selectedExecution) ? document.executions[document.selectedExecution] : nil
    }

    private var displayedResult: BackendMessage? {
        if document.table != nil, document.grid == nil { return nil }
        let tableResult = document.table != nil && document.grid != nil ? document.tableResult : nil
        guard let message = tableResult ?? (document.executions.isEmpty ? document.runtime?.result : displayedExecution?.result) else { return nil }
        return ResultSnapshotSource.project(message, resultSetIndex: resultSetIndex.wrappedValue)
    }

    private var displayedFailure: WorkspaceModel.QueryFailure? {
        if document.table != nil, document.tableResult != nil { return document.tableFailure }
        return document.executions.isEmpty ? document.runtime?.queryFailure : displayedExecution?.failure
    }

    private var unloadedTableError: String? {
        if let error = document.localError { return error }
        if let failure = displayedFailure {
            var message = "\(failure.title): \(failure.message)"
            if let sqlState = failure.sqlState { message += "\nSQLSTATE \(sqlState)" }
            if failure.outcomeUnknown {
                message += "\nThe SQL outcome is unknown. Check the database before repeating this command."
            }
            return message
        }
        if document.table != nil, document.tableResult != nil { return nil }
        return document.runtime?.errorMessage ?? document.runtime?.connectionsError
    }

    @ViewBuilder private var executionBar: some View {
        if document.executions.count > 1 {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(Array(document.executions.enumerated()), id: \.element.id) { index, execution in
                        Button("\(index + 1) · \(execution.status)") { document.selectedExecution = index }.controlHover()
                            .buttonStyle(.bordered)
                            .tint(index == document.selectedExecution ? AppPalette.accent : .secondary)
                            .help(execution.sql)
                    }
                }.padding(8)
            }
            Divider()
        }
    }

    @ViewBuilder private var result: some View {
        if let table = document.table, document.grid == nil, !document.isRunning, displayedResult == nil {
            unloadedTable(table, error: unloadedTableError)
        } else if let error = document.localError {
            Text(error).foregroundStyle(.orange).textSelection(.enabled).padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let failure = displayedFailure, displayedResult == nil {
            VStack(alignment: .leading, spacing: 10) {
                Label(failure.title, systemImage: "exclamationmark.circle").font(.headline)
                Text(failure.message).textSelection(.enabled)
                if let sqlState = failure.sqlState { Text("SQLSTATE \(sqlState)").appSecondaryText() }
                if failure.outcomeUnknown { Text("The SQL outcome is unknown. Check the database before repeating this command.").foregroundStyle(.orange) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20)
        } else if let result = displayedResult {
            VStack(spacing: 0) {
                if displayedFailure?.outcomeUnknown == true || result.outcomeUnknown == true {
                    Text("The write outcome is unknown. Check the database before repeating this command.")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled).padding(10)
                }
                if let failure = displayedFailure {
                    Label("\(failure.title): \(failure.message)", systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled).padding(10)
                }
                if document.table == nil {
                    HStack {
                        let showsRows = result.columns?.isEmpty == false
                        if !showsRows { Text(result.commandTag ?? "Results").font(.headline) }
                        if let sets = result.resultSets, sets.count > 1 {
                            Picker("Result Set", selection: resultSetIndex.projectedValue) {
                                ForEach(sets.indices, id: \.self) { index in
                                    Text("\(index + 1) · \(sets[index].commandTag)").tag(index)
                                }
                            }.controlHover().frame(maxWidth: 240)
                        }
                        Spacer()
                        Button("Pin Result") {
                            let index = resultSetIndex.wrappedValue
                            Task { await workspace.pinResult(document, resultSetIndex: index) }
                        }.controlHover()
                            .disabled(workspace.resultSnapshots.isBusy || workspace.snapshotCapture(for: document,
                                resultSetIndex: resultSetIndex.wrappedValue) == nil)
                            .help("Save the selected result set as an offline snapshot")
                            .accessibilityIdentifier("pinQueryResult")
                        Menu("Export Loaded") {
                            Button("JSON…") { workspace.exportLoaded(ExportResultSet(result), title: document.title, format: "json") }
                            Button("CSV…") { workspace.exportLoaded(ExportResultSet(result), title: document.title, format: "csv") }
                        }.fixedSize().controlHover().disabled((document.grid?.pendingCount ?? 0) > 0 || document.grid?.isApplying == true || document.grid?.outcomeUnknown == true)
                        let shown = result.displayedRowCount ?? result.rows?.count ?? 0
                        Text(result.affectedRowCountKnown == false && !showsRows ? "Affected rows unknown" : (showsRows ? "\(shown) from \(result.rowCount ?? Int64(shown)) rows shown" : "\(shown) rows shown"))
                            .accessibilityIdentifier("queryRowCount")
                        if let duration = result.durationMs { Text(String(format: "%.1f ms", duration)) }
                    }.font(.callout).padding(12)
                }
                if let path = result.exportPath {
                    Text("Saved \(result.exportRowCount ?? 0) rows to \(path)")
                        .font(.caption).appSecondaryText().textSelection(.enabled).padding(8)
                }
                if result.truncated == true || result.displayNotice != nil {
                    Text(result.displayNotice ?? "Result truncated at 1000 rows or 8 MiB.")
                        .font(.caption).foregroundStyle(.orange).padding(8)
                }
                Divider()
                if let columns = result.columns, !columns.isEmpty {
                    if document.table != nil, let grid = document.grid {
                        DataGridView(document: document, workspace: workspace, grid: grid, result: result).id(ObjectIdentifier(grid))
                    } else {
                        InspectedResultTableView(table: ResultTableView(columns: columns, rows: result.rows ?? [],
                            copySettings: workspace.copySettings,
                            onSQLInsertCopy: { payload, pasteboard in
                                workspace.beginInsertCopy(payload, document: document, pasteboard: pasteboard)
                            },
                            onCopyError: { workspace.reportCopyError($0) },
                            copyAllowed: !document.isRunning && !workspace.isClosing,
                            commandHandler: { commands.handleKeyEvent($0, documentID: document.id) },
                            documentID: document.id))
                    }
                } else { Text("Command completed").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        } else if document.isRunning {
            ProgressView("Running query…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = document.runtime?.errorMessage ?? document.runtime?.connectionsError {
            Text(error).foregroundStyle(.orange).textSelection(.enabled).padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let table = document.table {
            unloadedTable(table)
        } else {
            Text("Run SQL to see its result").appSecondaryText()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
