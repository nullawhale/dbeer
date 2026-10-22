import SwiftUI

struct SQLHistoryView: View {
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject private var library: WorkspaceModel
    @StateObject private var search = SQLHistorySearchModel()
    private var clearDrafts = SwiftUI.State(initialValue: false)
    private var query = SwiftUI.State(initialValue: "")
    private var profile = SwiftUI.State(initialValue: SQLHistoryProfileFilter.all)
    private var period = SwiftUI.State(initialValue: SQLHistoryPeriod.all)
    private var fromDate = SwiftUI.State(initialValue: Date.now)
    private var throughDate = SwiftUI.State(initialValue: Date.now)
    private var outcome = SwiftUI.State<SQLHistoryOutcome?>(initialValue: nil)
    private var favoritesOnly = SwiftUI.State(initialValue: false)
    private var settingsPresented = SwiftUI.State(initialValue: false)
    private var clearSelection = SwiftUI.State<SQLHistoryClearSelection?>(initialValue: nil)

    init(workspace: ApplicationWorkspace) {
        self.workspace = workspace
        self.library = workspace.library
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SQL History").font(.title2)
                Spacer()
                Button("Done") { workspace.isHistoryPresented = false }.controlHover().keyboardShortcut(.cancelAction)
            }
            HStack {
                Toggle("Record executed SQL", isOn: $workspace.historyEnabled).controlHover()
                Spacer()
                Button("Storage Settings…") { settingsPresented.wrappedValue = true }.controlHover()
                    .accessibilityIdentifier("historyStorageSettings")
            }
            Text("Up to \(workspace.historySettings.maxEntries.formatted()) ordinary executions from the last \(workspace.historySettings.retentionDays.formatted()) days, stored on this Mac. Favorites are kept until you delete them.")
                .font(.caption).appSecondaryText()
            if let error = workspace.historyError {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .accessibilityIdentifier("historyStorageError")
            }
            searchControls
            historyList
            HStack {
                Button("Clear Matching…", role: .destructive) {
                    clearSelection.wrappedValue = SQLHistoryClearSelection(entries: search.results, scope: .matchingFilters)
                }.controlHover().disabled(search.isSearching || search.results.isEmpty || invalidPeriod)
                    .accessibilityIdentifier("clearMatchingHistory")
                Button("Clear History…", role: .destructive) {
                    clearSelection.wrappedValue = SQLHistoryClearSelection(entries: workspace.history, scope: .allHistory)
                }.controlHover().disabled(workspace.history.isEmpty)
                    .accessibilityIdentifier("clearAllHistory")
                Spacer()
                Button("Clear SQL Drafts…", role: .destructive) { clearDrafts.wrappedValue = true }.controlHover()
            }
        }
        .padding(20).frame(minWidth: 720, minHeight: 520)
        .tint(AppPalette.accent)
        .focusEffectDisabled()
        .onAppear(perform: updateSearch)
        .onChange(of: workspace.history) { updateSearch() }
        .onChange(of: filter) { updateSearch() }
        .onDisappear { search.cancel() }
        .sheet(isPresented: settingsPresented.projectedValue) {
            SQLHistorySettingsView(workspace: workspace)
        }
        .alert(clearSelection.wrappedValue?.title ?? "Clear SQL History?", isPresented: Binding(
            get: { clearSelection.wrappedValue != nil },
            set: { if !$0 { clearSelection.wrappedValue = nil } }), presenting: clearSelection.wrappedValue) { selection in
            Button("Cancel", role: .cancel) {}
            if selection.ordinaryCount > 0 {
                Button("Clear Ordinary", role: .destructive) { clear(selection, includeFavorites: false) }
                    .keyboardShortcut(.defaultAction)
            }
            if selection.favoriteCount > 0 {
                Button(selection.scope == .favoriteEntry ? "Delete Favorite" : "Clear Including Favorites", role: .destructive) {
                    clear(selection, includeFavorites: true)
                }
            }
        } message: { selection in
            Text(selection.message)
        }
        .alert("Clear SQL Drafts?", isPresented: clearDrafts.projectedValue) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Drafts", role: .destructive) { Task { await workspace.clearRestoredDocuments() } }
        } message: {
            Text("Close the current documents and remove the saved drafts. Saved .sql files stay on disk.")
        }
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").appSecondaryText().accessibilityHidden(true)
                TextField("Search all SQL", text: query.projectedValue)
                    .textFieldStyle(.roundedBorder)
                    .help("Find a fragment anywhere in the full SQL text, ignoring case and accents.")
                    .accessibilityIdentifier("historySQLSearch")
                if !query.wrappedValue.isEmpty {
                    ControlIconButton(systemName: "xmark") { query.wrappedValue = "" }
                        .help("Clear SQL search").accessibilityLabel("Clear SQL search")
                }
            }
            HStack(spacing: 12) {
                Picker("Connection", selection: profile.projectedValue) {
                    Text("All connections").tag(SQLHistoryProfileFilter.all)
                    ForEach(profileOptions) { option in
                        Text(option.label).tag(SQLHistoryProfileFilter.profile(option.id))
                    }
                    if workspace.history.contains(where: { $0.profileID == nil }) || profile.wrappedValue == .unavailable {
                        Text("Connection unavailable").tag(SQLHistoryProfileFilter.unavailable)
                    }
                }.controlHover().labelsHidden().accessibilityLabel("Connection")
                    .frame(maxWidth: .infinity).accessibilityIdentifier("historyProfileFilter")
                Picker("Period", selection: period.projectedValue) {
                    ForEach(SQLHistoryPeriod.allCases) { period in Text(period.label).tag(period) }
                }.controlHover().labelsHidden().accessibilityLabel("Period")
                    .frame(width: 150).accessibilityIdentifier("historyPeriodFilter")
                Picker("Outcome", selection: outcome.projectedValue) {
                    Text("All outcomes").tag(Optional<SQLHistoryOutcome>.none)
                    Text("Completed").tag(Optional(SQLHistoryOutcome.succeeded))
                    Text("Failed").tag(Optional(SQLHistoryOutcome.failed))
                    Text("Cancelled").tag(Optional(SQLHistoryOutcome.cancelled))
                    Text("Timed out").tag(Optional(SQLHistoryOutcome.timedOut))
                    Text("Unknown / unavailable").tag(Optional(SQLHistoryOutcome.unknown))
                }.controlHover().labelsHidden().accessibilityLabel("Outcome")
                    .frame(width: 190).accessibilityIdentifier("historyOutcomeFilter")
            }
            if period.wrappedValue == .custom {
                HStack(spacing: 16) {
                    DatePicker("From", selection: fromDate.projectedValue, displayedComponents: .date)
                        .controlHover().accessibilityIdentifier("historyFromDate")
                    DatePicker("Through", selection: throughDate.projectedValue, displayedComponents: .date)
                        .controlHover().accessibilityIdentifier("historyThroughDate")
                    Spacer()
                }.fixedSize(horizontal: true, vertical: false)
                if invalidPeriod {
                    Text("The From date must be on or before the Through date.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            HStack {
                Toggle("Favorites only", isOn: favoritesOnly.projectedValue).controlHover()
                    .toggleStyle(.checkbox).accessibilityIdentifier("historyFavoritesFilter")
                Spacer()
                if search.isSearching {
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                } else {
                    Text("\(search.results.count.formatted()) of \(workspace.history.count.formatted()) executions")
                }
                Button("Reset Filters", action: resetFilters).controlHover().disabled(!hasFilters)
            }.font(.caption).appSecondaryText()
        }
    }

    private var historyList: some View {
        List(search.results) { entry in historyRow(entry) }
            .overlay {
                if search.results.isEmpty, !search.isSearching {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").font(.title2).accessibilityHidden(true)
                        Text(invalidPeriod ? "Choose a valid period" : workspace.history.isEmpty ? "No SQL history yet" : "No matching executions")
                            .font(.headline)
                        if !workspace.history.isEmpty, !invalidPeriod {
                            Text("Change the SQL search or filters to find an execution.").font(.callout)
                        }
                    }.appSecondaryText().padding()
                }
            }
    }

    private func historyRow(_ entry: SQLHistoryEntry) -> some View {
        let sqlPreview = entry.sql.prefix(2_000)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(entry.date, style: .date)
                Text(entry.date, style: .time)
                Spacer()
                Text(entry.outcomeLabel)
                ControlIconButton(systemName: entry.isFavorite ? "star.fill" : "star") {
                    Task { await workspace.setHistoryFavorite(entry.id, isFavorite: !entry.isFavorite) }
                }
                .foregroundStyle(entry.isFavorite ? AppPalette.accent : AppPalette.secondaryText)
                .help(entry.isFavorite ? "Remove from favorites. Ordinary storage limits apply immediately." : "Add to favorites")
                .accessibilityLabel(entry.isFavorite ? "Remove from favorites" : "Add to favorites")
                .accessibilityIdentifier("historyFavorite-\(entry.id.uuidString)")
                ControlIconButton(systemName: "trash") { delete(entry) }
                    .help("Delete execution from history").accessibilityLabel("Delete execution from history")
                    .accessibilityIdentifier("deleteHistory-\(entry.id.uuidString)")
            }.font(.caption).appSecondaryText()
            if let profile = entry.profile {
                Text(profile.summary).font(.caption).appSecondaryText().textSelection(.enabled)
            } else {
                Text("Original connection details unavailable").font(.caption).appSecondaryText()
            }
            if let startedAt = entry.startedAt, let finishedAt = entry.finishedAt {
                Text("Started \(startedAt.formatted(date: .abbreviated, time: .standard)) · Finished \(finishedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).appSecondaryText()
            }
            Text(entry.executionSummary).font(.caption).appSecondaryText()
            if entry.truncated == true {
                Text("Result display truncated. Loaded rows are not the full result.").font(.caption).appSecondaryText()
            }
            if entry.countsArePartial == true {
                Text("Counts cover retained results only; additional results may be unavailable.").font(.caption).appSecondaryText()
            }
            if entry.sqlCompleted == true, entry.outcome != .succeeded {
                Text("SQL completion was confirmed; result delivery or export failed. Do not rerun SQL to recover the result.")
                    .font(.caption).appSecondaryText()
            } else if entry.outcome == .unknown, entry.legacyOutcome == nil {
                Text("SQL outcome is unknown. Inspect the database before retrying.").font(.caption).appSecondaryText()
            }
            if let message = entry.errorMessage {
                Text(message + (entry.sqlState.map { " (SQLSTATE \($0))" } ?? "")).font(.caption).textSelection(.enabled)
            }
            Text(String(sqlPreview)).font(.system(.callout, design: .monospaced)).lineLimit(4).textSelection(.enabled)
            if sqlPreview.endIndex != entry.sql.endIndex {
                Text("SQL preview truncated. Open the tab to view the full SQL.").font(.caption).appSecondaryText()
            }
            Button {
                workspace.openHistoryEntry(entry)
                workspace.isHistoryPresented = false
            } label: {
                Text("Open in SQL Tab").padding(.horizontal, 8).frame(minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(AppPalette.accent).controlHover()
        }.padding(.vertical, 5)
    }

    private var invalidPeriod: Bool {
        !dateBounds.isValid
    }

    private var dateBounds: SQLHistoryDateBounds {
        period.wrappedValue.dateBounds(from: fromDate.wrappedValue, through: throughDate.wrappedValue)
    }

    private var filter: SQLHistoryFilter {
        let bounds = dateBounds
        return SQLHistoryFilter(query: query.wrappedValue, profile: profile.wrappedValue,
            from: bounds.from, before: bounds.before, outcome: outcome.wrappedValue, favoritesOnly: favoritesOnly.wrappedValue)
    }

    private var hasFilters: Bool {
        !query.wrappedValue.isEmpty || profile.wrappedValue != .all || period.wrappedValue != .all || outcome.wrappedValue != nil || favoritesOnly.wrappedValue
    }

    private func updateSearch() { search.update(entries: workspace.history, filter: filter) }

    private func resetFilters() {
        query.wrappedValue = ""
        profile.wrappedValue = .all
        period.wrappedValue = .all
        outcome.wrappedValue = nil
        favoritesOnly.wrappedValue = false
    }

    private func delete(_ entry: SQLHistoryEntry) {
        if entry.isFavorite {
            clearSelection.wrappedValue = SQLHistoryClearSelection(entries: [entry], scope: .favoriteEntry)
        } else {
            Task { await workspace.deleteHistoryEntry(entry.id) }
        }
    }

    private func clear(_ selection: SQLHistoryClearSelection, includeFavorites: Bool) {
        Task {
            if selection.scope == .favoriteEntry, let id = selection.entryIDs.first {
                await workspace.deleteHistoryEntry(id, includeFavorite: true)
            } else {
                await workspace.clearHistory(entryIDs: selection.entryIDs, includeFavorites: includeFavorites)
            }
        }
    }

    private var profileOptions: [SQLHistoryProfileOption] {
        SQLHistoryProfileOption.options(connections: library.savedConnections, history: workspace.history, selected: profile.wrappedValue)
    }
}

/// Freezes a manual deletion scope when confirmation opens, without retaining SQL text.
struct SQLHistoryClearSelection: Equatable, Sendable {
    enum Scope: Equatable, Sendable { case allHistory, matchingFilters, favoriteEntry }

    let entryIDs: Set<UUID>
    let ordinaryCount: Int
    let favoriteCount: Int
    let scope: Scope

    init(entries: [SQLHistoryEntry], scope: Scope) {
        let uniqueEntries = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        entryIDs = Set(uniqueEntries.keys)
        favoriteCount = uniqueEntries.values.filter(\.isFavorite).count
        ordinaryCount = uniqueEntries.count - favoriteCount
        self.scope = scope
    }

    var title: String { scope == .favoriteEntry ? "Delete Favorite?" : "Clear SQL History?" }

    var message: String {
        if scope == .favoriteEntry {
            return "Permanently delete this favorite from SQL history? Its SQL tabs and saved files stay on disk."
        }
        let scopeDescription = scope == .allHistory ? "All history entries currently stored" : "Entries matching the current SQL search and connection, period, outcome and favorites filters"
        let counts = "\(ordinaryCount.formatted()) ordinary executions and \(favoriteCount.formatted()) favorites selected."
        let favoriteChoice = favoriteCount > 0
            ? ordinaryCount > 0
                ? "Clear Ordinary preserves every favorite. Clear Including Favorites also permanently deletes the selected favorites."
                : "Only favorites are selected. Clear Including Favorites permanently deletes them."
            : "No favorites are selected; favorites are preserved."
        return "\(scopeDescription): \(counts) New executions are excluded. \(favoriteChoice) SQL tabs and saved files stay on disk."
    }
}

struct SQLHistoryDateBounds: Equatable, Sendable {
    var from: Date?
    var before: Date?

    var isValid: Bool {
        guard let from, let before else { return true }
        return from < before
    }
}

enum SQLHistoryPeriod: String, CaseIterable, Identifiable {
    case all, today, last7Days, last30Days, custom
    var id: Self { self }
    var label: String {
        switch self {
        case .all: "All dates"
        case .today: "Today"
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        case .custom: "Custom dates"
        }
    }

    func dateBounds(from: Date, through: Date, now: Date = .now, calendar: Calendar = .current) -> SQLHistoryDateBounds {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .all:
            return SQLHistoryDateBounds()
        case .today, .last7Days, .last30Days:
            let days = self == .today ? 0 : self == .last7Days ? -6 : -29
            return SQLHistoryDateBounds(from: calendar.date(byAdding: .day, value: days, to: today),
                before: calendar.date(byAdding: .day, value: 1, to: today))
        case .custom:
            return SQLHistoryDateBounds(from: calendar.startOfDay(for: from),
                before: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: through)))
        }
    }
}

struct SQLHistoryProfileOption: Identifiable, Equatable {
    var id: UUID
    var label: String

    static func options(connections: [SavedConnection], history: [SQLHistoryEntry], selected: SQLHistoryProfileFilter = .all) -> [Self] {
        var options = Dictionary(uniqueKeysWithValues: connections.map { profile in
            (profile.id, Self(id: profile.id,
                label: "\(profile.name) · \(profile.user)@\(profile.host):\(profile.port)/\(profile.database)"))
        })
        for entry in history.reversed() {
            guard let id = entry.profileID, options[id] == nil else { continue }
            let label: String
            if let snapshot = entry.profile {
                label = "\(snapshot.name) (deleted) · \(snapshot.user)@\(snapshot.host):\(snapshot.port)/\(snapshot.database)"
            } else {
                label = "Unavailable connection · \(id.uuidString.suffix(8))"
            }
            options[id] = Self(id: id, label: label)
        }
        if case let .profile(id) = selected, options[id] == nil {
            options[id] = Self(id: id, label: "Unavailable connection · \(id.uuidString.suffix(8))")
        }
        let labelCounts = Dictionary(grouping: options.values, by: \.label).mapValues(\.count)
        return options.values.map { option in
            var option = option
            if labelCounts[option.label, default: 0] > 1 {
                option.label += " · \(option.id.uuidString.suffix(8))"
            }
            return option
        }.sorted {
            let order = $0.label.localizedStandardCompare($1.label)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
}
