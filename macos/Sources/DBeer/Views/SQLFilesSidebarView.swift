import SwiftUI

struct SQLFilesSidebarView: View {
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject private var library: SQLFolderLibrary
    private var query = SwiftUI.State(initialValue: "")
    private var mode = SwiftUI.State(initialValue: SQLFolderSearchMode.all)
    private var editingLibrary = SwiftUI.State<SQLLibraryEditRequest?>(initialValue: nil)

    init(workspace: ApplicationWorkspace) {
        self.workspace = workspace
        self.library = workspace.sqlFolders
    }

    private var isSearchingQuery: Bool {
        !query.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Files").font(.headline)
                Spacer(minLength: 0)
                if library.isSearching { ProgressView().controlSize(.mini) }
                ControlIconButton(systemName: "arrow.clockwise") {
                    Task { await library.refresh() }
                }
                .help("Refresh SQL folders").accessibilityLabel("Refresh SQL folders")
                .accessibilityIdentifier("refreshSQLFolders")
                ControlIconButton(systemName: "folder.badge.plus") { workspace.attachSQLFolder() }
                    .help("Attach an existing SQL folder").accessibilityLabel("Attach SQL folder")
                    .accessibilityIdentifier("attachSQLFolder")
                WorkspaceSidebarCloseButton(workspace: workspace, panel: .files)
            }
            .padding(.horizontal, 12).frame(height: 36)
            Divider()
            searchControls
            Divider()
            List {
                if !isSearchingQuery {
                    ForEach(library.roots) { node in
                        SQLFolderTreeRow(node: node, workspace: workspace, library: library, isRoot: true)
                    }
                } else {
                    ForEach(library.searchResults) { match in searchRow(match) }
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .overlay {
                if library.attachments.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "folder").font(.title2).accessibilityHidden(true)
                        Text("Attach a folder to browse SQL files.")
                            .font(.callout).multilineTextAlignment(.center)
                        Button("Attach Folder…") { workspace.attachSQLFolder() }.controlHover()
                    }.padding().appSecondaryText()
                } else if isSearchingQuery, !library.isSearching, library.searchResults.isEmpty {
                    Text("No matching SQL files").font(.callout).appSecondaryText().padding()
                }
            }
            if let notice = library.searchNotice, isSearchingQuery {
                Text(notice).font(.caption).appSecondaryText().textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            if let error = library.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("sqlFoldersSidebar")
        .sheet(item: editingLibrary.projectedValue) { request in
            SQLLibraryEntryEditor(workspace: workspace, fileURL: request.url)
        }
    }

    private var searchControls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").appSecondaryText().accessibilityHidden(true)
                TextField("Search SQL files", text: query.projectedValue)
                    .textFieldStyle(.plain).onExitCommand { query.wrappedValue = "" }
                    .accessibilityLabel("Search SQL files").accessibilityIdentifier("sqlFolderSearch")
                if !query.wrappedValue.isEmpty {
                    ControlIconButton(systemName: "xmark") { query.wrappedValue = "" }
                        .help("Clear SQL file search").accessibilityLabel("Clear SQL file search")
                }
            }
            ControlSegmentPicker("Search in", selection: mode.projectedValue, choices: [
                .init("Names", value: .name), .init("Contents", value: .contents), .init("Both", value: .all),
            ])
            .labelsHidden().font(.caption)
            .accessibilityLabel("Search SQL file names or contents")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onChange(of: query.wrappedValue) { _, _ in updateSearch() }
        .onChange(of: mode.wrappedValue) { _, _ in updateSearch() }
    }

    private func updateSearch() {
        library.updateSearch(query: query.wrappedValue, mode: mode.wrappedValue)
    }

    private func searchRow(_ match: SQLFolderSearchMatch) -> some View {
        Button {
            Task { await workspace.openSQLFile(at: match.url) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label(match.relativePath, systemImage: "doc.text").lineLimit(1)
                if let preview = match.preview {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let line = match.lineNumber { Text("\(line):").monospacedDigit() }
                        Text(preview).lineLimit(2)
                    }.font(.caption).appSecondaryText()
                }
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).catalogRowHover().help(match.url.path)
        .contextMenu {
            Button("Open") { Task { await workspace.openSQLFile(at: match.url) } }
            Button("Open in New Tab") { Task { await workspace.openSQLFile(at: match.url, inNewTab: true) } }
            Button(workspace.sqlLibrary.entry(at: match.url) == nil ? "Add to SQL Library…" : "Edit Library Details…") {
                editingLibrary.wrappedValue = SQLLibraryEditRequest(url: match.url)
            }
        }
    }
}

private struct SQLFolderTreeRow: View {
    @ObservedObject var node: SQLFolderNode
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject var library: SQLFolderLibrary
    var isRoot = false
    private var editingLibrary = SwiftUI.State<SQLLibraryEditRequest?>(initialValue: nil)

    var body: some View {
        Group {
            if node.isDirectory {
                DisclosureGroup(isExpanded: $node.isExpanded) {
                    if node.isLoading { ProgressView().controlSize(.mini) }
                    if let error = node.error {
                        Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        Button("Retry") { Task { await library.loadChildren(node, refresh: true) } }.controlHover()
                    }
                    if let children = node.children {
                        ForEach(children) { child in
                            AnyView(SQLFolderTreeRow(node: child, workspace: workspace, library: library))
                        }
                        if children.isEmpty, node.error == nil {
                            Text("No SQL files").font(.caption).appSecondaryText()
                        }
                    }
                    if node.isTruncated {
                        Text("Folder display limit reached. Use search to find a file.")
                            .font(.caption).appSecondaryText()
                    }
                } label: {
                    Label(node.name, systemImage: "folder").lineLimit(1).help(node.url.path)
                        .padding(.leading, 8)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { node.isExpanded.toggle() }
                        .catalogRowHover()
                }
                .onChange(of: node.isExpanded) { _, expanded in
                    if expanded { Task { await library.loadChildren(node) } }
                }
                .contextMenu {
                    Button("Refresh") { Task { await library.loadChildren(node, refresh: true) } }
                    if isRoot {
                        Button("Remove Folder") { library.detach(node.attachmentID) }
                            .help("Remove this folder from the sidebar. Files stay on disk.")
                    }
                }
            } else {
                Button {
                    Task { await workspace.openSQLFile(at: node.url) }
                } label: {
                    Label(node.name, systemImage: "doc.text")
                        .lineLimit(1)
                        .padding(.leading, 8)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).catalogRowHover().help(node.url.path)
                .contextMenu {
                    Button("Open") { Task { await workspace.openSQLFile(at: node.url) } }
                    Button("Open in New Tab") { Task { await workspace.openSQLFile(at: node.url, inNewTab: true) } }
                    Button(workspace.sqlLibrary.entry(at: node.url) == nil ? "Add to SQL Library…" : "Edit Library Details…") {
                        editingLibrary.wrappedValue = SQLLibraryEditRequest(url: node.url)
                    }
                }
            }
        }
        .sheet(item: editingLibrary.projectedValue) { request in
            SQLLibraryEntryEditor(workspace: workspace, fileURL: request.url)
        }
    }
}
