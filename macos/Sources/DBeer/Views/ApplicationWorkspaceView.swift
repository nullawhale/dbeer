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

    init(workspace: ApplicationWorkspace) {
        self.workspace = workspace
        self.commands = workspace.commands
        self.appearance = workspace.appearance
    }

    var body: some View {
        HSplitView {
            sidebar
            VStack(spacing: 0) {
                documentBar
                Divider()
                if let document = workspace.selectedDocument {
                    SQLDocumentPane(document: document, workspace: workspace)
                        .id(document.id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text").font(.largeTitle).appSecondaryText()
                            .accessibilityHidden(true)
                        Button("New SQL Tab") { workspace.newDocument() }.controlHover()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                WorkspaceStatusBar(workspace: workspace, editConnection: editConnection)
            }
            .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
        }
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

    private var sidebar: some View {
        VSplitView {
            connectionsSidebar.frame(minHeight: 180)
            SQLFilesSidebarView(workspace: workspace).frame(minHeight: 180)
        }
        .frame(minWidth: 210, idealWidth: 260, maxWidth: 340)
        .background(AppPalette.isCustom ? AppPalette.sidebar : AppPalette.background)
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
        .frame(minWidth: 210, idealWidth: 260, maxWidth: 340)
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

    private var documentBar: some View {
        HStack(spacing: ControlHoverAppearance.gap) {
            ScrollView(.horizontal) {
                HStack(spacing: ControlHoverAppearance.gap) {
                    ForEach(workspace.documents) { document in
                        DocumentTab(document: document, isSelected: workspace.selectedDocumentID == document.id,
                            select: { workspace.selectedDocumentID = document.id },
                            close: { Task { await workspace.closeDocument(document) } },
                            openInNewTab: {
                                if document.table != nil { Task { await workspace.openTableInNewTab(document) } }
                                else { workspace.openSQLFileInNewTab(document) }
                            })
                    }
                }
            }
            .scrollIndicators(.hidden)
            ControlIconButton(systemName: "plus") { workspace.newDocument() }
                .help(commands.help(for: .newSQLTab))
                .accessibilityLabel("New SQL Tab")
                .accessibilityIdentifier("newSQLTab")
        }
        .padding(ControlHoverAppearance.gap)
        .frame(height: WorkspaceChrome.headerHeight)
        .background(AppPalette.isCustom ? AppPalette.panel : Color.primary.opacity(0.025))
    }
}

struct DocumentTab: View {
    @ObservedObject var document: SQLDocument
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    var openInNewTab: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: select) {
                HStack(spacing: 6) {
                    if document.fileDocument?.isDirty == true {
                        Image(systemName: "circle.fill").font(.system(size: 5)).accessibilityHidden(true)
                    }
                    if document.fileDocument?.conflict != nil || document.fileDocument?.isMissing == true {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
                    }
                    Text(document.title).lineLimit(1)
                    if document.isRunning || document.isNavigatingTable || document.grid?.isApplying == true {
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
        .contextMenu {
            if document.table != nil || document.fileURL != nil, let openInNewTab {
                Button("Open in New Tab", action: openInNewTab)
                    .disabled(document.isNavigatingTable)
            }
            Button("Rename…") {
                let alert = NSAlert()
                alert.messageText = "Rename SQL Tab"
                let field = NSTextField(string: document.title)
                field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
                alert.accessoryView = field
                alert.addButton(withTitle: "Rename")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty { document.title = title }
                }
            }.disabled(document.isNavigatingTable)
            Button("Close", action: close)
        }
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
            HStack(spacing: 8) {
                if document.table != nil { tableHistoryControls }
                Picker("Connection", selection: $document.profileID) {
                    Text("Choose a connection").tag(Optional<UUID>.none)
                    if let missingProfileID {
                        Text(workspace.library.savedConnections.contains { $0.id == missingProfileID }
                            ? "Connection outside library scope" : "Unavailable saved connection").tag(Optional(missingProfileID))
                            .help("Saved connection \(missingProfileID.uuidString)")
                    }
                    ForEach(workspace.availableSQLLibraryProfiles(for: document)) { profile in
                        Text(document.sqlLibraryEntryID == nil ? profile.name : profile.name + " · " + profile.policy.label)
                            .tag(Optional(profile.id))
                    }
                }.controlHover().labelsHidden().accessibilityLabel("Connection").frame(maxWidth: 220)
                    .accessibilityIdentifier("documentConnection")
                    .disabled(document.runtime?.sessionId != nil || document.isRunning || document.isNavigatingTable)
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
                        Label(document.tableFilters.isEmpty ? "Filter" : "Filter (\(document.tableFilters.count))",
                            systemImage: "line.3.horizontal.decrease")
                    }.controlHover().controlSize(.small)
                        .disabled(!TableBrowseNavigation.isEnabled(document: document, workspace: workspace))
                        .accessibilityIdentifier("gridFilter")
                        .popover(isPresented: showingFilters.projectedValue) {
                            TableBrowseControls(document: document, workspace: workspace)
                        }
                }
                Spacer()
                Button("Stop") { commands.perform(.stop) }.controlHover()
                    .disabled(!commands.canPerform(.stop))
                    .help(commandHelp(.stop))
                if document.table == nil {
                    Button("Run Script") { commands.perform(.runScript) }.controlHover()
                        .disabled(!commands.canPerform(.runScript))
                        .help(commandHelp(.runScript) + " · Run the entire document, stopping at the first error")
                    Menu("Run to File") {
                        Button("JSON…") { commands.perform(.runToJSON) }
                        Button("CSV…") { commands.perform(.runToCSV) }
                    }.fixedSize().controlHover().disabled(!commands.canPerform(.runToJSON))
                        .accessibilityIdentifier("runToFile")
                }
                Button {
                    commands.perform(.runCurrent)
                } label: {
                    HStack(spacing: 6) {
                        Label(document.table == nil ? "Run" : (document.grid == nil ? "Load Data" : "Refresh"),
                            systemImage: document.table == nil ? "play" : "arrow.clockwise")
                        if let shortcut = commands.shortcuts.shortcut(for: .runCurrent) {
                            Text(shortcut.displayString).opacity(0.65)
                        }
                    }.fixedSize(horizontal: true, vertical: false)
                }.controlHover()
                    .buttonStyle(.borderedProminent)
                    .disabled(document.isNavigatingTable || !commands.canPerform(.runCurrent))
                    .help(commandHelp(.runCurrent))
                    .accessibilityIdentifier("runQuery")
            }
            .padding(.horizontal, 12)
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
                Button(error == nil ? "Load Data" : "Retry Load Data") { commands.perform(.runCurrent) }
                    .controlHover().buttonStyle(.borderedProminent)
                    .disabled(document.isNavigatingTable || !commands.canPerform(.runCurrent))
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
        guard var message = tableResult ?? (document.executions.isEmpty ? document.runtime?.result : displayedExecution?.result) else { return nil }
        if let sets = message.resultSets, !sets.isEmpty {
            let index = min(resultSetIndex.wrappedValue, sets.count - 1)
            let set = sets[index]
            message.columns = set.columns
            message.rows = set.rows
            message.commandTag = set.commandTag
            message.rowCount = set.rowCount
            message.displayedRowCount = set.displayedRowCount
            message.truncated = set.truncated
            message.displayNotice = set.displayNotice
            message.affectedRowCountKnown = set.affectedRowCountKnown
            message.nextCursor = set.nextCursor
        }
        return message
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
                        ResultTableView(columns: columns, rows: result.rows ?? [],
                            copySettings: workspace.copySettings,
                            onSQLInsertCopy: { payload, pasteboard in
                                workspace.beginInsertCopy(payload, document: document, pasteboard: pasteboard)
                            },
                            onCopyError: { workspace.reportCopyError($0) },
                            copyAllowed: !document.isRunning && !workspace.isClosing,
                            commandHandler: { commands.handleKeyEvent($0, documentID: document.id) },
                            documentID: document.id)
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
