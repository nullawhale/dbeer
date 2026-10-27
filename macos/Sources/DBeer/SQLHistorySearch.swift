import Combine
import Foundation

enum SQLHistoryProfileFilter: Hashable, Sendable {
    case all
    case profile(UUID)
    case unavailable
}

struct SQLHistoryFilter: Equatable, Sendable {
    var query = ""
    var profile: SQLHistoryProfileFilter = .all
    var from: Date? = nil
    var before: Date? = nil
    var outcome: SQLHistoryOutcome? = nil
    var favoritesOnly = false
}

enum SQLHistorySearch {
    /// Searches complete SQL, independently of the preview shown in history.
    /// Date bounds refer to the stored terminal date, with an exclusive upper bound.
    static func results(entries: [SQLHistoryEntry], filter: SQLHistoryFilter) throws -> [SQLHistoryEntry] {
        try Task.checkCancellation()
        var matches: [(offset: Int, entry: SQLHistoryEntry)] = []
        for (offset, entry) in entries.enumerated() {
            try Task.checkCancellation()
            if filter.favoritesOnly && !entry.isFavorite { continue }
            switch filter.profile {
            case .all: break
            case .profile(let id):
                guard entry.profileID == id else { continue }
            case .unavailable:
                guard entry.profileID == nil else { continue }
            }
            if let from = filter.from, entry.date < from { continue }
            if let before = filter.before, entry.date >= before { continue }
            if let outcome = filter.outcome, entry.outcome != outcome { continue }
            if !filter.query.isEmpty,
               entry.sql.range(of: filter.query, options: [.caseInsensitive, .diacriticInsensitive],
                   locale: Locale(identifier: "en_US_POSIX")) == nil { continue }
            try Task.checkCancellation()
            matches.append((offset, entry))
        }
        let sorted = matches.sorted {
            if $0.entry.date != $1.entry.date { return $0.entry.date > $1.entry.date }
            return $0.offset > $1.offset
        }
        try Task.checkCancellation()
        return sorted.map(\.entry)
    }
}

@MainActor
final class SQLHistorySearchModel: ObservableObject {
    typealias Worker = @Sendable ([SQLHistoryEntry], SQLHistoryFilter) async throws -> [SQLHistoryEntry]

    @Published private(set) var results: [SQLHistoryEntry] = []
    @Published private(set) var isSearching = false

    private let worker: Worker
    private var generation: UInt64 = 0
    private var searchTask: Task<[SQLHistoryEntry], Error>?
    private var deliveryTask: Task<Void, Never>?

    init(worker: @escaping Worker = { entries, filter in
        try SQLHistorySearch.results(entries: entries, filter: filter)
    }) {
        self.worker = worker
    }

    /// Returns a completion handle so callers can await a particular search, if needed.
    @discardableResult
    func update(entries: [SQLHistoryEntry], filter: SQLHistoryFilter) -> Task<Void, Never> {
        cancel()
        let currentGeneration = generation
        let worker = worker
        isSearching = true
        let search = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await worker(entries, filter)
        }
        searchTask = search
        let delivery = Task { [weak self] in
            do {
                let matches = try await withTaskCancellationHandler {
                    try await search.value
                } onCancel: {
                    search.cancel()
                }
                guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                self.results = matches
                self.isSearching = false
                self.searchTask = nil
                self.deliveryTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                self.results = []
                self.isSearching = false
                self.searchTask = nil
                self.deliveryTask = nil
            }
        }
        deliveryTask = delivery
        return delivery
    }

    func cancel() {
        generation &+= 1
        deliveryTask?.cancel()
        searchTask?.cancel()
        deliveryTask = nil
        searchTask = nil
        results = []
        isSearching = false
    }

    deinit {
        deliveryTask?.cancel()
        searchTask?.cancel()
    }
}
