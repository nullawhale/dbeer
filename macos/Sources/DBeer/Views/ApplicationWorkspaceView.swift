import AppKit
import SwiftUI

private struct CatalogSearchFocusKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var focusCatalogSearch: (() -> Void)? {
        get { self[CatalogSearchFocusKey.self] }
        set { self[CatalogSearchFocusKey.self] = newValue }
    }
}

struct ApplicationWorkspaceView: View {
    @ObservedObject var workspace: ApplicationWorkspace
    @Environment(\.colorScheme) private var colorScheme
    private var editing = SwiftUI.State<SavedConnection?>(initialValue: nil)
    private var deletion = SwiftUI.State<SavedConnection?>(initialValue: nil)

    init(workspace: ApplicationWorkspace) {
        self.workspace = workspace
    }

    var body: some View {
        HSplitView {
            sidebar
            VStack(spacing: 0) {
                documentBar
                if let error = workspace.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    Divider()
                }
                if let document = workspace.selectedDocument {
                    SQLDocumentPane(document: document, workspace: workspace)
                        .id(document.id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Button("New SQL Tab") { workspace.newDocument() }.controlHover()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppPalette.background).tint(AppPalette.accent)
        .focusEffectDisabled()
        .focusedSceneValue(\.focusCatalogSearch, focusCatalogSearch)
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
            set: { workspace.library.isConnectionEditorPresented = $0 })) {
            ConnectionEditorView(model: workspace.library, connection: editing.wrappedValue,
                onConnect: { id in await workspace.connectProfile(id) }) {
                workspace.library.isConnectionEditorPresented = false
                editing.wrappedValue = nil
            }
        }
        .sheet(item: $workspace.inspection) { inspection in
            CatalogInspectionView(inspection: inspection) { workspace.inspection = nil }
        }
        .sheet(isPresented: $workspace.isHistoryPresented) {
            SQLHistoryView(workspace: workspace)
        }
        .sheet(isPresented: Binding(get: { workspace.importPreview != nil },
            set: { if !$0 { workspace.importPreview = nil } })) {
            ProfileImportView(workspace: workspace)
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

    private func focusCatalogSearch() {
        guard let content = NSApplication.shared.keyWindow?.contentView else { return }
        func searchField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField,
               field.accessibilityIdentifier() == "catalogSearch" || field.placeholderString == "Search object names" {
                return field
            }
            return view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        // AppKit selects the full field editor range even if it already has focus.
        searchField(in: content)?.selectText(nil)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connections").font(.headline)
                Spacer()
                ControlIconButton(systemName: "plus") {
                    editing.wrappedValue = nil
                    workspace.library.isConnectionEditorPresented = true
                }
                .help("New Connection")
                .accessibilityLabel("New Connection")
                .accessibilityIdentifier("newConnection")
            }.padding(12)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search object names", text: $workspace.catalogSearch)
                    .textFieldStyle(.plain)
                    .onExitCommand { workspace.catalogSearch = "" }
                    .help("Search object names (⌘F)")
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
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(.primary.opacity(0.025))
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
            if let error = workspace.library.connectionsError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(12)
            }
        }
        .frame(minWidth: 210, idealWidth: 260, maxWidth: 340)
        .background(AppPalette.background)
    }

    private func profileRow(_ profile: SavedConnection) -> some View {
        ProfileCatalogRow(profile: profile, workspace: workspace, edit: {
                Task {
                    guard await workspace.disconnectProfile(profile.id),
                          let current = workspace.library.savedConnections.first(where: { $0.id == profile.id }) else { return }
                    editing.wrappedValue = current
                    workspace.library.isConnectionEditorPresented = true
                }
            }, delete: { deletion.wrappedValue = profile })
    }

    private var documentBar: some View {
        HStack(spacing: ControlHoverAppearance.gap) {
            ScrollView(.horizontal) {
                HStack(spacing: ControlHoverAppearance.gap) {
                    ForEach(workspace.documents) { document in
                        DocumentTab(document: document, isSelected: workspace.selectedDocumentID == document.id,
                            select: { workspace.selectedDocumentID = document.id },
                            close: { Task { await workspace.closeDocument(document) } })
                    }
                }
            }
            .scrollIndicators(.hidden)
            ControlIconButton(systemName: "plus") { workspace.newDocument() }
                .help("New SQL Tab (⌘T)")
                .accessibilityLabel("New SQL Tab")
                .accessibilityIdentifier("newSQLTab")
        }
        .padding(ControlHoverAppearance.gap)
        .frame(height: 32)
        .background(.primary.opacity(0.025))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct DocumentTab: View {
    @ObservedObject var document: SQLDocument
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Text(document.title).lineLimit(1)
                    if document.isRunning || document.grid?.isApplying == true { ProgressView().controlSize(.mini) }
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
            }
            Button("Close", action: close)
        }
    }
}

private struct SQLDocumentPane: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var workspace: ApplicationWorkspace
    private var resultSetIndex = SwiftUI.State(initialValue: 0)

    init(document: SQLDocument, workspace: ApplicationWorkspace) {
        self.document = document
        self.workspace = workspace
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Connection", selection: $document.profileID) {
                    Text("Choose a connection").tag(Optional<UUID>.none)
                    ForEach(workspace.library.savedConnections) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }.controlHover().labelsHidden().accessibilityLabel("Connection").frame(maxWidth: 220)
                    .disabled(document.runtime?.sessionId != nil || document.isRunning)
                Spacer()
                Button("Stop") { Task { await workspace.stop(document) } }.controlHover()
                    .disabled(!document.isRunning && document.grid?.isApplying != true)
                if document.table == nil {
                    Button("Run Script") { Task { await workspace.runScript(document) } }.controlHover()
                        .disabled(document.isRunning || document.profileID == nil)
                        .help("Run all statements in order, stopping at the first error")
                    Menu("Run to File") {
                        Button("JSON…") { Task { await workspace.runToFile(document, format: "json") } }
                        Button("CSV…") { Task { await workspace.runToFile(document, format: "csv") } }
                    }.fixedSize().controlHover().disabled(document.isRunning || document.profileID == nil)
                        .accessibilityIdentifier("runToFile")
                }
                Button {
                    Task { await workspace.run(document) }
                } label: { Label(document.table == nil ? "Run" : "Refresh", systemImage: document.table == nil ? "play" : "arrow.clockwise") }.controlHover()
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(document.isRunning || document.grid?.isApplying == true || document.profileID == nil || document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("runQuery")
            }.padding(12)
            Divider()
            if document.table == nil {
                VSplitView {
                    SQLEditorView(text: $document.text, editorState: workspace.editorState, documentID: document.id,
                        engine: workspace.library.savedConnections.first { $0.id == document.profileID }?.engine ?? .postgresql,
                        selectionChanged: { document.selection = $0 },
                        onRunSelection: { selection in
                            document.selection = selection
                            Task { await workspace.run(document) }
                        }, completions: workspace.completions(profileID: document.profileID),
                        errorPosition: document.errorPosition)
                        .padding(12).frame(minHeight: 160, idealHeight: 240)
                    VStack(spacing: 0) {
                        executionBar
                        result
                    }.frame(minHeight: 180, maxHeight: .infinity)
                }
            } else {
                TableBrowseControls(document: document, workspace: workspace)
                result.frame(maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text(document.runtime?.transactionLabel ?? "No session")
                Spacer()
                Text(document.runtime?.connectionSummary ?? "Session opens on first Run")
            }.font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .onChange(of: document.selectedExecution) { _, _ in resultSetIndex.wrappedValue = 0 }
        .onChange(of: document.isRunning) { _, value in if value { resultSetIndex.wrappedValue = 0 } }
    }

    private var displayedExecution: SQLExecution? {
        document.executions.indices.contains(document.selectedExecution) ? document.executions[document.selectedExecution] : nil
    }

    private var displayedResult: BackendMessage? {
        guard var message = document.executions.isEmpty ? document.runtime?.result : displayedExecution?.result else { return nil }
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
        }
        return message
    }

    private var displayedFailure: WorkspaceModel.QueryFailure? {
        document.executions.isEmpty ? document.runtime?.queryFailure : displayedExecution?.failure
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
        if let error = document.localError {
            Text(error).foregroundStyle(.orange).textSelection(.enabled).padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let failure = displayedFailure, displayedResult == nil {
            VStack(alignment: .leading, spacing: 10) {
                Label(failure.title, systemImage: "exclamationmark.circle").font(.headline)
                Text(failure.message).textSelection(.enabled)
                if let sqlState = failure.sqlState { Text("SQLSTATE \(sqlState)").foregroundStyle(.secondary) }
                if failure.outcomeUnknown { Text("The SQL outcome is unknown. Check the database before repeating this command.").foregroundStyle(.orange) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20)
        } else if let result = displayedResult {
            VStack(spacing: 0) {
                if let failure = displayedFailure {
                    Label("\(failure.title): \(failure.message)", systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled).padding(10)
                }
                HStack {
                    Text(result.commandTag ?? "Results").font(.headline)
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
                    Text("\(result.displayedRowCount ?? 0) rows shown")
                    if let duration = result.durationMs { Text(String(format: "%.1f ms", duration)) }
                }.font(.callout).padding(12)
                if let path = result.exportPath {
                    Text("Saved \(result.exportRowCount ?? 0) rows to \(path)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(8)
                }
                if result.truncated == true || result.displayNotice != nil {
                    Text(result.displayNotice ?? "Result truncated at 1000 rows or 8 MiB.")
                        .font(.caption).foregroundStyle(.orange).padding(8)
                }
                Divider()
                if let columns = result.columns, !columns.isEmpty {
                    if document.table != nil, let grid = document.grid {
                        DataGridView(document: document, workspace: workspace, grid: grid).id(ObjectIdentifier(grid))
                    } else {
                        Text("Query results are read only. Open a table from Connections to edit its data.")
                            .font(.caption).foregroundStyle(.secondary).padding(8)
                        ResultTableView(columns: columns, rows: result.rows ?? [])
                    }
                } else { Text("Command completed").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        } else if document.isRunning {
            ProgressView("Running query…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = document.runtime?.errorMessage ?? document.runtime?.connectionsError {
            Text(error).foregroundStyle(.orange).textSelection(.enabled).padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Run SQL to see its result").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
