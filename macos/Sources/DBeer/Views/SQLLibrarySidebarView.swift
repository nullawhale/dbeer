import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SQLLibraryEditRequest: Identifiable {
    let id = UUID()
    let url: URL
}

struct SQLLibrarySidebarView: View {
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject private var library: SQLLibrary
    private var query = SwiftUI.State(initialValue: "")
    private var profile = SwiftUI.State<UUID?>(initialValue: nil)
    private var folder = SwiftUI.State<String?>(initialValue: nil)
    private var tag = SwiftUI.State<String?>(initialValue: nil)
    private var editing = SwiftUI.State<SQLLibraryEditRequest?>(initialValue: nil)
    private var managingGroups = SwiftUI.State(initialValue: false)

    init(workspace: ApplicationWorkspace) {
        self.workspace = workspace
        library = workspace.sqlLibrary
    }

    private var entries: [SQLLibraryEntry] {
        library.filteredEntries(query: query.wrappedValue, profileID: profile.wrappedValue,
            folder: folder.wrappedValue, tag: tag.wrappedValue)
    }
    private var folders: [String] {
        Set(library.snapshot.entries.map(\.folder).filter { !$0.isEmpty }).sorted()
    }
    private var tags: [String] { Set(library.snapshot.entries.flatMap(\.tags)).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("SQL Library").font(.headline)
                Spacer(minLength: 0)
                ControlIconButton(systemName: "person.2") { managingGroups.wrappedValue = true }
                    .help("Manage connection groups").accessibilityLabel("Manage connection groups")
                    .accessibilityIdentifier("manageSQLProfileGroups")
                ControlIconButton(systemName: "plus") { chooseFile() }
                    .help("Add an existing SQL file").accessibilityLabel("Add SQL file to library")
                    .accessibilityIdentifier("addSQLLibraryFile")
            }.padding(.horizontal, 12).frame(height: 36)
            Divider()
            filters
            Divider()
            List {
                ForEach(entries) { entry in entryRow(entry) }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .overlay {
                    if library.snapshot.entries.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "books.vertical").font(.title2).accessibilityHidden(true)
                            Text("Share a SQL file across connections.").font(.callout).multilineTextAlignment(.center)
                            Button("Add SQL File…", action: chooseFile).controlHover()
                        }.padding().appSecondaryText()
                    } else if entries.isEmpty {
                        Text("No matching library files").font(.callout).appSecondaryText().padding()
                    }
                }
            if let error = library.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("sqlLibrarySidebar")
        .sheet(item: editing.projectedValue) { request in
            SQLLibraryEntryEditor(workspace: workspace, fileURL: request.url)
        }
        .sheet(isPresented: managingGroups.projectedValue) { SQLProfileGroupsView(workspace: workspace) }
    }

    private var filters: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").appSecondaryText().accessibilityHidden(true)
                TextField("Search names, folders and tags", text: query.projectedValue)
                    .textFieldStyle(.plain).onExitCommand { query.wrappedValue = "" }
                    .accessibilityLabel("Search SQL library").accessibilityIdentifier("sqlLibrarySearch")
                if !query.wrappedValue.isEmpty {
                    ControlIconButton(systemName: "xmark") { query.wrappedValue = "" }
                        .help("Clear library search").accessibilityLabel("Clear library search")
                }
            }
            Picker("Connection filter", selection: profile.projectedValue) {
                Text("All connections").tag(Optional<UUID>.none)
                ForEach(workspace.library.savedConnections) { connection in
                    Text(connection.name).tag(Optional(connection.id))
                }
                if let current = profile.wrappedValue,
                   !workspace.library.savedConnections.contains(where: { $0.id == current }) {
                    Text("Unavailable saved connection").tag(Optional(current))
                }
            }.labelsHidden().controlHover().accessibilityLabel("Filter SQL library by connection")
                .accessibilityIdentifier("sqlLibraryProfileFilter")
            HStack(spacing: 6) {
                Picker("Folder", selection: folder.projectedValue) {
                    Text("All folders").tag(Optional<String>.none)
                    ForEach(folders, id: \.self) { Text($0).tag(Optional($0)) }
                    if let current = folder.wrappedValue, !folders.contains(current) {
                        Text(current + " (unavailable)").tag(Optional(current))
                    }
                }.controlHover().labelsHidden().accessibilityLabel("Filter SQL library by folder")
                Picker("Tag", selection: tag.projectedValue) {
                    Text("All tags").tag(Optional<String>.none)
                    ForEach(tags, id: \.self) { Text($0).tag(Optional($0)) }
                    if let current = tag.wrappedValue, !tags.contains(current) {
                        Text(current + " (unavailable)").tag(Optional(current))
                    }
                }.controlHover().labelsHidden().accessibilityLabel("Filter SQL library by tag")
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func entryRow(_ entry: SQLLibraryEntry) -> some View {
        Button { Task { await workspace.openSQLLibraryEntry(entry) } } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label(entry.fileURL.lastPathComponent, systemImage: "doc.text").lineLimit(1)
                if !entry.folder.isEmpty { Text(entry.folder).font(.caption).appSecondaryText().lineLimit(1) }
                Text(scopeLabel(entry.scope, workspace: workspace)).font(.caption).appSecondaryText().lineLimit(2)
                if !entry.tags.isEmpty {
                    Text(entry.tags.map { "#" + $0 }.joined(separator: " ")).font(.caption).appSecondaryText().lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).controlHover().help(entry.fileURL.path)
            .contextMenu {
                Button("Open in New Tab") { Task { await workspace.openSQLLibraryEntry(entry) } }
                Button("Edit Library Details…") { editing.wrappedValue = SQLLibraryEditRequest(url: entry.fileURL) }
                Button("Remove from Library") { library.removeEntry(entry.id) }
                    .help("Remove the library reference. The SQL file stays on disk.")
            }
    }

    private func chooseFile() {
        if let url = chooseSQLLibraryFile() { editing.wrappedValue = SQLLibraryEditRequest(url: url) }
    }
}

/// Adds metadata for an existing file; this sheet never copies or executes SQL.
struct SQLLibraryEntryEditor: View {
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject private var library: SQLLibrary
    @Environment(\.dismiss) private var dismiss
    private let entryID: UUID?
    private var fileURL: SwiftUI.State<URL>
    private var folder: SwiftUI.State<String>
    private var tags: SwiftUI.State<String>
    private var scopeKind: SwiftUI.State<String>
    private var profileID: SwiftUI.State<UUID?>
    private var groupID: SwiftUI.State<UUID?>
    private var error = SwiftUI.State<String?>(initialValue: nil)

    init(workspace: ApplicationWorkspace, fileURL: URL) {
        self.workspace = workspace
        library = workspace.sqlLibrary
        let entry = workspace.sqlLibrary.entry(at: fileURL)
        entryID = entry?.id
        self.fileURL = SwiftUI.State(initialValue: entry?.fileURL ?? fileURL)
        folder = SwiftUI.State(initialValue: entry?.folder ?? "")
        tags = SwiftUI.State(initialValue: entry?.tags.joined(separator: "\n") ?? "")
        var kind = "all"
        var profile: UUID?
        var group: UUID?
        if let scope = entry?.scope {
            switch scope {
            case .allConnections: break
            case .profile(let id): kind = "profile"; profile = id
            case .group(let id): kind = "group"; group = id
            }
        }
        scopeKind = SwiftUI.State(initialValue: kind)
        profileID = SwiftUI.State(initialValue: profile)
        groupID = SwiftUI.State(initialValue: group)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entryID == nil ? "Add to SQL Library" : "SQL Library Details").font(.title2)
            HStack {
                Text(fileURL.wrappedValue.path).font(.callout).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
                Spacer()
                Button("Choose File…") {
                    if let url = chooseSQLLibraryFile() { fileURL.wrappedValue = url }
                }.controlHover()
            }
            Text("The SQL stays in this file. Library folders and tags organize its reference on this Mac.")
                .font(.caption).appSecondaryText()
            Form {
                TextField("Library folder", text: folder.projectedValue, prompt: Text("Optional, for example Reports/Weekly"))
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("sqlLibraryEntryFolder")
                LabeledContent("Tags, one per line") {
                    TextEditor(text: tags.projectedValue).font(.body).frame(height: 60)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.25)))
                        .accessibilityLabel("SQL library tags, one per line")
                        .accessibilityIdentifier("sqlLibraryEntryTags")
                }
                Picker("Available to", selection: scopeKind.projectedValue) {
                    Text("All connections").tag("all")
                    Text("One connection").tag("profile")
                    Text("Connection group").tag("group")
                }.controlHover().accessibilityIdentifier("sqlLibraryEntryScope")
                if scopeKind.wrappedValue == "profile" { profilePicker }
                if scopeKind.wrappedValue == "group" { groupPicker }
            }
            if let error = error.wrappedValue {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { dismiss() }.controlHover().keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Details", action: save).controlHover().keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("saveSQLLibraryEntry")
            }
        }.padding(20).frame(minWidth: 500)
            .background(AppPalette.background).tint(AppPalette.accent).focusEffectDisabled()
            .applicationTheme(appearance: workspace.appearance)
    }

    private var profilePicker: some View {
        Picker("Connection", selection: profileID.projectedValue) {
            Text("Choose a connection").tag(Optional<UUID>.none)
            ForEach(workspace.library.savedConnections) { profile in
                Text(profile.name + " · " + profile.policy.label).tag(Optional(profile.id))
            }
            if let id = profileID.wrappedValue, !workspace.library.savedConnections.contains(where: { $0.id == id }) {
                Text("Unavailable saved connection").tag(Optional(id))
            }
        }.controlHover()
    }

    private var groupPicker: some View {
        Picker("Group", selection: groupID.projectedValue) {
            Text("Choose a group").tag(Optional<UUID>.none)
            ForEach(library.snapshot.groups) { group in Text(group.name).tag(Optional(group.id)) }
            if let id = groupID.wrappedValue, !library.snapshot.groups.contains(where: { $0.id == id }) {
                Text("Unavailable saved group").tag(Optional(id))
            }
        }.controlHover()
    }

    private func save() {
        let scope: SQLLibraryScope
        switch scopeKind.wrappedValue {
        case "profile":
            guard let id = profileID.wrappedValue else { error.wrappedValue = "Choose a connection for this file."; return }
            scope = .profile(id)
        case "group":
            guard let id = groupID.wrappedValue else { error.wrappedValue = "Choose a connection group for this file."; return }
            scope = .group(id)
        default: scope = .allConnections
        }
        do {
            _ = try library.upsertEntry(id: entryID, fileURL: fileURL.wrappedValue, folder: folder.wrappedValue,
                tags: tags.wrappedValue.components(separatedBy: .newlines), scope: scope)
            dismiss()
        } catch { self.error.wrappedValue = error.localizedDescription }
    }
}

private struct SQLProfileGroupsView: View {
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject private var library: SQLLibrary
    @Environment(\.dismiss) private var dismiss
    private var groupID = SwiftUI.State<UUID?>(initialValue: nil)
    private var name = SwiftUI.State(initialValue: "")
    private var members = SwiftUI.State<Set<UUID>>(initialValue: [])
    private var error = SwiftUI.State<String?>(initialValue: nil)

    init(workspace: ApplicationWorkspace) {
        self.workspace = workspace
        library = workspace.sqlLibrary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connection Groups").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.controlHover().keyboardShortcut(.cancelAction)
            }
            Text("Group memberships organize shared SQL. Removing a group leaves its library files unavailable until you choose another scope.")
                .font(.caption).appSecondaryText()
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    List {
                        ForEach(library.snapshot.groups) { group in
                            Button { edit(group) } label: {
                                HStack {
                                    Text(group.name).lineLimit(1)
                                    Spacer()
                                    Text("\(group.profileIDs.count)").font(.caption).appSecondaryText()
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).controlHover()
                                .listRowBackground(groupID.wrappedValue == group.id ? AppPalette.accent.opacity(0.12) : Color.clear)
                        }
                    }.listStyle(.sidebar).scrollContentBackground(.hidden)
                    Button("New Group") { clear() }.controlHover()
                }.frame(minWidth: 160, idealWidth: 200)
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Group name", text: name.projectedValue).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("sqlProfileGroupName")
                    Text("Connections").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(workspace.library.savedConnections) { profile in
                                Toggle(profile.name + " · " + profile.policy.label, isOn: membership(profile.id)).controlHover()
                            }
                            ForEach(unavailableMembers, id: \.self) { id in
                                Toggle("Unavailable saved connection", isOn: membership(id)).controlHover()
                                    .help(id.uuidString)
                            }
                            if workspace.library.savedConnections.isEmpty && unavailableMembers.isEmpty {
                                Text("Save a connection to add it to this group.").font(.callout).appSecondaryText()
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 150)
                    if let error = error.wrappedValue {
                        Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    HStack {
                        if let id = groupID.wrappedValue {
                            Button("Remove Group", role: .destructive) { library.removeGroup(id); clear() }.controlHover()
                        }
                        Spacer()
                        Button("Save Group", action: save).controlHover()
                            .accessibilityIdentifier("saveSQLProfileGroup")
                    }
                }.padding(.leading, 12).frame(minWidth: 300)
            }
        }.padding(20).frame(minWidth: 600, minHeight: 380)
            .background(AppPalette.background).tint(AppPalette.accent).focusEffectDisabled()
            .applicationTheme(appearance: workspace.appearance)
    }

    private var unavailableMembers: [UUID] {
        members.wrappedValue.filter { id in !workspace.library.savedConnections.contains { $0.id == id } }
            .sorted { $0.uuidString < $1.uuidString }
    }

    private func membership(_ id: UUID) -> Binding<Bool> {
        Binding(get: { members.wrappedValue.contains(id) }, set: { included in
            if included { members.wrappedValue.insert(id) } else { members.wrappedValue.remove(id) }
        })
    }

    private func edit(_ group: SQLProfileGroup) {
        groupID.wrappedValue = group.id
        name.wrappedValue = group.name
        members.wrappedValue = Set(group.profileIDs)
        error.wrappedValue = nil
    }

    private func clear() {
        groupID.wrappedValue = nil
        name.wrappedValue = ""
        members.wrappedValue = []
        error.wrappedValue = nil
    }

    private func save() {
        do {
            let group = try library.upsertGroup(id: groupID.wrappedValue, name: name.wrappedValue,
                profileIDs: members.wrappedValue.sorted { $0.uuidString < $1.uuidString })
            edit(group)
        } catch { self.error.wrappedValue = error.localizedDescription }
    }
}

@MainActor private func scopeLabel(_ scope: SQLLibraryScope, workspace: ApplicationWorkspace) -> String {
    switch scope {
    case .allConnections: "All connections"
    case .profile(let id):
        workspace.library.savedConnections.first { $0.id == id }.map { $0.name + " · " + $0.policy.label }
            ?? "Unavailable saved connection"
    case .group(let id):
        workspace.sqlLibrary.snapshot.groups.first { $0.id == id }.map { "Group: " + $0.name }
            ?? "Unavailable saved group"
    }
}

@MainActor private func chooseSQLLibraryFile() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.prompt = "Choose SQL File"
    return panel.runModal() == .OK ? panel.url : nil
}
