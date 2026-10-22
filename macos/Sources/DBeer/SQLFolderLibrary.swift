import Combine
import Foundation

struct SQLFolderAttachment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var url: URL

    init(id: UUID = UUID(), url: URL) { self.id = id; self.url = url }
    var isValid: Bool { SQLFolderScanner.isLocalFolderURL(url) && url.path.utf8.count <= 4_096 }

    private enum CodingKeys: String, CodingKey { case id, url }
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["id", "url"]) else { throw SQLFolderError.invalidFolder }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        url = try values.decode(URL.self, forKey: .url)
        guard isValid else { throw SQLFolderError.invalidFolder }
    }
}

@MainActor
final class SQLFolderNode: ObservableObject, Identifiable {
    let id: String
    let attachmentID: UUID
    let url: URL
    let isDirectory: Bool
    var name: String { url.lastPathComponent }
    @Published var children: [SQLFolderNode]?
    @Published var isExpanded = false
    @Published var isLoading = false
    @Published var error: String?
    @Published var isTruncated = false
    var loadID = UUID()

    init(attachmentID: UUID, url: URL, isDirectory: Bool) {
        id = attachmentID.uuidString + "\0" + url.path
        self.attachmentID = attachmentID
        self.url = url
        self.isDirectory = isDirectory
    }
}

/// Attachments persist in the workspace. Enumeration and searching run on
/// detached tasks; merely restoring attachment records performs no file I/O.
@MainActor
final class SQLFolderLibrary: ObservableObject {
    typealias SearchWorker = @Sendable ([SQLFolderAttachment], String, SQLFolderSearchMode, SQLFolderScanLimits) async throws -> SQLFolderSearchBatch

    @Published private(set) var attachments: [SQLFolderAttachment] = []
    @Published private(set) var roots: [SQLFolderNode] = []
    @Published private(set) var searchResults: [SQLFolderSearchMatch] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchNotice: String?
    @Published private(set) var error: String?

    private let automaticallyRefresh: Bool
    private let pollInterval: Duration
    private let limits: SQLFolderScanLimits
    private let searchWorker: SearchWorker
    private var monitor: Task<Void, Never>?
    private var searchTask: Task<SQLFolderSearchBatch, Error>?
    private var searchDelivery: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var searchQuery = ""
    private var searchMode: SQLFolderSearchMode = .all
    private var generation: UInt64 = 0
    private var stopped = false
    private var isRefreshing = false
    private var watchers: [String: SQLFileWatcher] = [:]
    private var refreshTask: Task<Void, Never>?
    private var renameTasks: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]

    init(automaticallyRefresh: Bool = true, pollInterval: Duration = .seconds(2),
         limits: SQLFolderScanLimits = .default, searchWorker: @escaping SearchWorker = { attachments, query, mode, limits in
             try SQLFolderScanner.search(attachments: attachments, query: query, mode: mode, limits: limits)
         }) {
        self.automaticallyRefresh = automaticallyRefresh
        self.pollInterval = max(pollInterval, .milliseconds(100))
        self.limits = limits
        self.searchWorker = searchWorker
    }

    @discardableResult
    func attach(_ url: URL) async throws -> SQLFolderAttachment {
        guard !stopped else { throw SQLFolderError.unavailable }
        let currentGeneration = generation
        let worker = Task.detached(priority: .userInitiated) { try SQLFolderScanner.canonicalDirectory(url) }
        let canonical = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard !stopped, !Task.isCancelled, generation == currentGeneration else { throw CancellationError() }
        if let existing = attachments.first(where: { $0.url.path == canonical.path }) { return existing }
        guard attachments.count < 32 else { throw SQLFolderError.tooManyFolders }
        let attachment = SQLFolderAttachment(url: canonical)
        attachments.append(attachment)
        let node = SQLFolderNode(attachmentID: attachment.id, url: canonical, isDirectory: true)
        roots.append(node)
        error = nil
        watch(node)
        beginMonitoring()
        restartSearchIfNeeded()
        return attachment
    }

    func detach(_ id: UUID) {
        guard !stopped else { return }
        generation &+= 1
        renameTasks.removeValue(forKey: id)?.task.cancel()
        if let node = roots.first(where: { $0.attachmentID == id }) { removeWatchers(node) }
        attachments.removeAll { $0.id == id }
        roots.removeAll { $0.attachmentID == id }
        restartSearchIfNeeded()
    }

    @discardableResult
    func restore(_ saved: [SQLFolderAttachment]) -> Bool {
        guard !stopped, saved.count <= 32, saved.allSatisfy(\.isValid),
              Set(saved.map(\.id)).count == saved.count, Set(saved.map { $0.url.path }).count == saved.count else {
            error = "The saved SQL folder attachments are invalid. Existing attachments have been kept."
            return false
        }
        generation &+= 1
        cancelSearch()
        for rename in renameTasks.values { rename.task.cancel() }
        renameTasks = [:]
        for watcher in watchers.values { watcher.stop() }
        watchers = [:]
        attachments = saved
        roots = saved.map { SQLFolderNode(attachmentID: $0.id, url: $0.url, isDirectory: true) }
        error = nil
        beginMonitoring()
        restartSearchIfNeeded()
        return true
    }

    func loadChildren(_ node: SQLFolderNode, refresh: Bool = false) async {
        guard !stopped, node.isDirectory, !node.isLoading, refresh || node.children == nil,
              contains(node), let attachment = attachments.first(where: { $0.id == node.attachmentID }) else { return }
        let request = UUID()
        node.loadID = request
        node.isLoading = true
        defer { if node.loadID == request { node.isLoading = false } }
        let limit = limits.treeEntries
        let worker = Task.detached(priority: .utility) {
            try SQLFolderScanner.children(attachment: attachment, directory: node.url, limit: limit)
        }
        do {
            let listing = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, !stopped, contains(node), node.loadID == request,
                  attachments.contains(attachment) else { return }
            let previous = Dictionary((node.children ?? []).map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
            let children = listing.entries.map { entry in
                let url = node.url.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
                if let existing = previous[url.path], existing.isDirectory == entry.isDirectory { return existing }
                return SQLFolderNode(attachmentID: attachment.id, url: url, isDirectory: entry.isDirectory)
            }
            let kept = Set(children.map(\.id))
            for old in node.children ?? [] where !kept.contains(old.id) { removeWatchers(old) }
            node.children = children
            node.isTruncated = listing.isTruncated
            node.error = nil
            watch(node)
        } catch is CancellationError {
        } catch {
            guard !stopped, contains(node), node.loadID == request else { return }
            node.error = error.localizedDescription
            node.isTruncated = false
            // Keep cached children visible as drafts/paths until a successful
            // refresh establishes the directory's current state.
        }
    }

    /// Refresh only roots and directories that have already been loaded.
    /// Unexpanded descendants are never enumerated by the monitor.
    func refresh() async {
        guard !stopped, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for root in roots {
            guard !stopped else { return }
            if root.children == nil {
                let url = root.url
                let worker = Task.detached(priority: .utility) { try SQLFolderScanner.validateRoot(url) }
                do {
                    try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard !stopped, contains(root) else { continue }
                    root.error = nil
                    watch(root)
                } catch is CancellationError { return }
                catch { if contains(root) { root.error = error.localizedDescription } }
            } else { await refreshLoaded(root) }
        }
    }

    @discardableResult
    func updateSearch(query: String, mode: SQLFolderSearchMode = .all) -> Task<Void, Never> {
        cancelSearch()
        searchQuery = query
        searchMode = mode
        guard !stopped, !query.isEmpty else { return Task {} }
        let currentGeneration = searchGeneration
        let captured = attachments
        let limits = limits
        let worker = searchWorker
        isSearching = true
        let task = Task.detached(priority: .userInitiated) {
            try await Task.sleep(for: .milliseconds(200))
            try Task.checkCancellation()
            return try await worker(captured, query, mode, limits)
        }
        searchTask = task
        let delivery = Task { [weak self] in
            do {
                let batch = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard !Task.isCancelled, let self, !self.stopped, self.searchGeneration == currentGeneration,
                      self.attachments == captured else { return }
                self.searchResults = batch.matches
                self.searchNotice = batch.notice
                self.isSearching = false
                self.searchTask = nil
                self.searchDelivery = nil
            } catch {
                guard !Task.isCancelled, let self, !self.stopped, self.searchGeneration == currentGeneration else { return }
                self.searchResults = []
                self.searchNotice = error is CancellationError ? nil : "SQL files could not be searched. Refresh the folders and retry."
                self.isSearching = false
                self.searchTask = nil
                self.searchDelivery = nil
            }
        }
        searchDelivery = delivery
        return delivery
    }

    func cancelSearch() {
        searchGeneration &+= 1
        searchTask?.cancel()
        searchDelivery?.cancel()
        searchTask = nil
        searchDelivery = nil
        searchResults = []
        searchNotice = nil
        isSearching = false
    }

    func shutdown() {
        stopped = true
        generation &+= 1
        monitor?.cancel()
        monitor = nil
        refreshTask?.cancel()
        refreshTask = nil
        for rename in renameTasks.values { rename.task.cancel() }
        renameTasks = [:]
        cancelSearch()
        for watcher in watchers.values { watcher.stop() }
        watchers = [:]
        for root in roots { invalidateLoads(root) }
    }

    private func contains(_ node: SQLFolderNode) -> Bool {
        func find(_ parent: SQLFolderNode) -> Bool {
            parent === node || (parent.children ?? []).contains(where: find)
        }
        return roots.contains(where: find)
    }

    private func refreshLoaded(_ node: SQLFolderNode) async {
        guard contains(node), node.children != nil else { return }
        await loadChildren(node, refresh: true)
        guard node.error == nil else { return }
        for child in node.children ?? [] where child.isDirectory && child.children != nil { await refreshLoaded(child) }
    }

    private func beginMonitoring() {
        guard automaticallyRefresh, !stopped, monitor == nil else { return }
        let interval = pollInterval
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, !self.stopped else { return }
                await self.refresh()
            }
        }
    }

    private func watch(_ node: SQLFolderNode) {
        guard automaticallyRefresh, watchers[node.id] == nil, watchers.count < 64 else { return }
        watchers[node.id] = SQLFileWatcher(url: node.url) { [weak self, weak node] moved in
            guard let self, let node, !self.stopped, self.contains(node) else { return }
            if let moved, self.attachments.first(where: { $0.id == node.attachmentID })?.url.path == node.url.path {
                self.followRootRename(node, to: moved)
            } else {
                self.refreshTask?.cancel()
                self.refreshTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                    await self?.refresh()
                }
            }
        }
    }

    private func followRootRename(_ old: SQLFolderNode, to proposed: URL) {
        let id = old.attachmentID
        let oldURL = old.url
        let wasLoaded = old.children != nil
        let wasExpanded = old.isExpanded
        renameTasks[id]?.task.cancel()
        let request = UUID()
        let task = Task { [weak self] in
            defer { if self?.renameTasks[id]?.id == request { self?.renameTasks[id] = nil } }
            let worker = Task.detached(priority: .utility) { try SQLFolderScanner.canonicalDirectory(proposed) }
            do {
                let canonical = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self, !self.stopped, self.contains(old), self.renameTasks[id]?.id == request,
                      let index = self.attachments.firstIndex(where: { $0.id == id && $0.url == oldURL }),
                      !self.attachments.contains(where: { $0.id != id && $0.url.path == canonical.path }) else { return }
                self.removeWatchers(old)
                self.attachments[index].url = canonical
                let replacement = SQLFolderNode(attachmentID: id, url: canonical, isDirectory: true)
                replacement.isExpanded = wasExpanded
                if let rootIndex = self.roots.firstIndex(where: { $0 === old }) { self.roots[rootIndex] = replacement }
                self.watch(replacement)
                if wasLoaded { await self.loadChildren(replacement) }
                self.restartSearchIfNeeded()
            } catch {
                guard !Task.isCancelled, let self, self.contains(old) else { return }
                old.error = SQLFolderError.unavailable.localizedDescription
            }
        }
        renameTasks[id] = (request, task)
    }

    private func removeWatchers(_ node: SQLFolderNode) {
        watchers.removeValue(forKey: node.id)?.stop()
        invalidateLoads(node)
        for child in node.children ?? [] { removeWatchers(child) }
    }

    private func invalidateLoads(_ node: SQLFolderNode) {
        node.loadID = UUID()
        node.isLoading = false
        for child in node.children ?? [] { invalidateLoads(child) }
    }

    private func restartSearchIfNeeded() {
        guard !searchQuery.isEmpty else { return }
        updateSearch(query: searchQuery, mode: searchMode)
    }

    deinit {
        monitor?.cancel()
        searchTask?.cancel()
        searchDelivery?.cancel()
        refreshTask?.cancel()
        for rename in renameTasks.values { rename.task.cancel() }
    }
}
