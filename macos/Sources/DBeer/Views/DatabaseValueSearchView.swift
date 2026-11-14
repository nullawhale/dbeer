import AppKit
import SwiftUI

struct DatabaseValueSearchView: View {
    @ObservedObject var model: DatabaseValueSearchModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Find Data").font(.title2.weight(.semibold))
                    Text(model.profile.name + " · " + model.profile.engine.displayName).appSecondaryText()
                }
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction).controlHover()
            }
            if let unavailable = model.unavailableReason {
                Text(unavailable).textSelection(.enabled)
                Spacer()
            } else {
                HSplitView {
                    scope.frame(minWidth: 300, idealWidth: 340)
                    report.frame(minWidth: 460)
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let notice = model.notice { Text(notice).font(.caption).appSecondaryText().textSelection(.enabled) }
        }
        .padding(18)
        .frame(minWidth: 850, minHeight: 580)
    }

    private var scope: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Exact schema or database", text: $model.schema)
                    .accessibilityLabel("Search schema or database")
                    .disabled(model.isBusy || model.profile.engine == .sqlite)
                Menu {
                    ForEach(model.schemas.indices, id: \.self) { index in
                        Button(model.schemas[index]) { model.schema = model.schemas[index] }
                    }
                    Divider()
                    Button("Load Schemas") { Task { await model.loadSchemas() } }
                } label: { Image(systemName: "list.bullet") }
                .disabled(!model.canStartAction).help("Choose a loaded schema or explicitly load schemas")
            }
            HStack {
                Button("Load Tables") { Task { await model.loadTables() } }.controlHover()
                Button("Clear Scope") { model.clearScope() }.controlHover()
            }.disabled(!model.canStartAction)
            TextField("Filter loaded table names", text: $model.objectFilter)
                .accessibilityLabel("Filter loaded search objects")
            HStack {
                Text("\(model.selectedTables.count) selected · maximum 100").font(.caption).appSecondaryText()
                Spacer()
                Button("Select Loaded") { model.selectedTables.formUnion(model.visibleObjects.map(\.id)) }
                    .disabled(model.isBusy || model.selectedTables.union(model.visibleObjects.map(\.id)).count > DatabaseValueSearchModel.maximumTables)
                    .controlHover()
            }
            List(model.visibleObjects) { table in
                Toggle(isOn: Binding(get: { model.selectedTables.contains(table.id) }, set: { selected in
                    if selected { model.selectedTables.insert(table.id) } else { model.selectedTables.remove(table.id) }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(table.name)
                        Text(table.schema + " · " + table.kind).font(.caption).appSecondaryText()
                    }
                }.toggleStyle(.checkbox).disabled(model.isBusy)
            }
            if let issue = model.inventoryNotice { Text(issue).font(.caption).appSecondaryText().textSelection(.enabled) }
            Text("Load additional schemas to add their tables to this scope. Only selected objects are searched.")
                .font(.caption).appSecondaryText()
        }.padding(.trailing, 12)
    }

    private var report: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                HStack {
                    Picker("Match", selection: $model.query.mode) {
                        ForEach(DatabaseSearchMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Value", selection: $model.query.valueKind) {
                        ForEach(DatabaseSearchValueKind.available(model.profile.engine)) { Text($0.title).tag($0) }
                    }
                }
                TextField(model.query.valueKind == .binary ? "Canonical Base64 value" : "Search value", text: $model.query.text)
                    .disabled(model.query.valueKind == .null)
                    .accessibilityLabel("Value to find")
                HStack {
                    ForEach(DatabaseSearchColumnKind.allCases) { kind in
                        Toggle(kind.title, isOn: Binding(get: { model.query.columnKinds.contains(kind) }, set: { included in
                            if included { model.query.columnKinds.insert(kind) } else { model.query.columnKinds.remove(kind) }
                        })).toggleStyle(.checkbox)
                    }
                }
            }.disabled(model.isBusy)
            HStack {
                Picker("Deadline", selection: $model.query.timeoutSeconds) {
                    ForEach([15, 30, 60, 120, 300], id: \.self) { Text("\($0) seconds").tag($0) }
                }.frame(maxWidth: 210).disabled(model.isBusy)
                Spacer()
                Button("Stop") { Task { await model.stop() } }.disabled(!model.isBusy).controlHover()
                Button("Search") { Task { await model.search() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!model.canSearch).controlHover()
            }
            Text("Each column query returns at most 200 matching rows. A server scan can read more data; the deadline and Stop apply to this search.")
                .font(.caption).appSecondaryText()
            if model.pendingSettings {
                Text("Settings changed. The report and its Open actions retain the previous search predicates.")
                    .font(.caption).appSecondaryText()
            }
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text("\(model.completedColumns) column reads · \(model.tableReports.filter { $0.state == "Checked" }.count)/\(model.tableReports.count) objects checked")
                    .font(.caption).appSecondaryText()
                Spacer()
                Toggle("Matches only", isOn: $model.matchesOnly).toggleStyle(.checkbox)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.tableReports) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.table.schema + "." + item.table.name + " · " + item.state).font(.caption.weight(.semibold))
                            if let notice = item.notice { Text(notice).font(.caption).appSecondaryText().textSelection(.enabled) }
                        }
                    }
                    Divider()
                    ForEach(model.visibleObservations) { item in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.table.schema + "." + item.table.name + " · " + item.column)
                                Text(item.hasMatches ? "\(item.returnedRows)\(item.limited ? "+" : "") matching rows observed" : item.state.rawValue.capitalized)
                                    .font(.caption).appSecondaryText()
                                if let notice = item.notice { Text(notice).font(.caption).appSecondaryText().textSelection(.enabled) }
                            }
                            Spacer()
                            if item.hasMatches {
                                Button("Open Filtered Table") { Task { await model.openMatch(item) } }
                                    .disabled(!model.canStartAction).controlHover()
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.leading, 12)
    }
}

@MainActor
final class DatabaseValueSearchWindowController: NSWindowController, NSWindowDelegate {
    let model: DatabaseValueSearchModel
    private let requestClose: @MainActor () -> Void

    init(model: DatabaseValueSearchModel, appearance: AppAppearance, requestClose: @escaping @MainActor () -> Void) {
        self.model = model; self.requestClose = requestClose
        let content = DatabaseValueSearchView(model: model, close: requestClose).applicationTheme(appearance: appearance)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Find Data — " + model.profile.name
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self; window.center()
    }
    required init?(coder: NSCoder) { return nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose(); return false }
    func finishClosing() { window?.delegate = nil; window?.close() }
}
