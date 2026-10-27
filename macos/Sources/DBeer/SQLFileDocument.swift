import Combine
import Foundation

struct SQLFileConflict: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let externalText: String
    let externalSHA256: String
    let version: SQLFileVersion

    init(url: URL, external: LoadedSQLFile) {
        id = UUID()
        self.url = url
        externalText = external.text
        externalSHA256 = external.sha256
        version = external.version
    }
}

enum SQLFileConflictDecision: Sendable { case useExternal, replaceExternal }

struct SQLFileDocumentFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One file has one editable buffer. SQL tabs observe it while retaining their
/// own profile, execution state and database session.
@MainActor
final class SQLFileDocument: ObservableObject, Identifiable {
    let id: UUID
    @Published var text: String {
        didSet {
            if !Self.sameBytes(text, oldValue) { revision &+= 1 }
        }
    }
    @Published private(set) var url: URL
    @Published private(set) var acceptedSHA256: String?
    @Published private(set) var conflict: SQLFileConflict?
    @Published private(set) var issue: String?
    @Published private(set) var isMissing = false
    @Published private(set) var isSaving = false
    @Published private(set) var isChecking = false
    @Published private(set) var restoredBinding: Bool
    @Published private(set) var recoveryURL: URL?
    private(set) var acceptedVersion: SQLFileVersion?
    private(set) var revision: UInt64 = 0
    let requiresSaveAs: Bool
    private var watcher: SQLFileWatcher?
    private var pollTask: Task<Void, Never>?
    private var checkID = UUID()
    private var isWatching = false
    private var observedStamp: FileStamp?

    init(id: UUID = UUID(), url: URL, text: String, acceptedSHA256: String?,
         loaded: LoadedSQLFile? = nil, restored: Bool = false, requiresSaveAs: Bool = false, recoveryURL: URL? = nil) {
        self.id = id
        self.url = url.standardizedFileURL
        self.text = text
        self.acceptedSHA256 = acceptedSHA256
        acceptedVersion = loaded?.version
        restoredBinding = restored
        self.requiresSaveAs = requiresSaveAs
        self.recoveryURL = recoveryURL
        if requiresSaveAs {
            issue = "Another recovered view has a different draft for this file. This copy is preserved independently; use Save As to keep it."
        }
    }

    var isDirty: Bool { acceptedSHA256 != SQLFileBinding.digestText(text) }
    var statusMessage: String {
        if isSaving { return "Saving SQL file…" }
        if requiresSaveAs { return issue ?? "Recovered local copy — use Save As." }
        if isMissing { return "The SQL file was deleted or moved. Your draft is still editable; use Save As to keep it." }
        if conflict != nil { return "The file changed outside DBeer. Compare both versions before saving." }
        if let issue { return issue }
        if acceptedSHA256 == nil { return "This recovered file binding needs review before saving." }
        return isDirty ? "Unsaved file changes" : "Saved"
    }

    static func sameBytes(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }

    func startWatching() {
        guard !isWatching, !requiresSaveAs else { return }
        isWatching = true
        installWatcher()
        pollTask = Task { @MainActor [weak self] in
            await self?.reconcile()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self, self.isWatching else { return }
                let location = self.url
                let stamp = await Task.detached { FileStamp(location) }.value
                if stamp != self.observedStamp || self.isMissing { await self.reconcile() }
            }
        }
    }

    func stopWatching() {
        isWatching = false
        checkID = UUID()
        isChecking = false
        watcher?.stop()
        watcher = nil
        pollTask?.cancel()
        pollTask = nil
    }

    private func installWatcher() {
        watcher?.stop()
        watcher = SQLFileWatcher(url: url) { [weak self] movedURL in
            Task { @MainActor [weak self] in await self?.reconcile(suggestedURL: movedURL) }
        }
    }

    func reconcile(suggestedURL: URL? = nil) async {
        guard !requiresSaveAs, !isSaving else { return }
        let originalURL = url
        let location = suggestedURL?.standardizedFileURL ?? originalURL
        let token = UUID()
        checkID = token
        isChecking = true
        defer { if checkID == token { isChecking = false } }
        do {
            let (loaded, stamp) = try await Task.detached {
                let stamp = FileStamp(location)
                return (try SQLFileBinding.read(location), stamp)
            }.value
            guard checkID == token, url == originalURL, !isSaving else { return }
            // A rename hint is accepted only for the same physical file. An
            // atomic checkout at the original path is reconciled there instead.
            if location != originalURL {
                guard loaded.identity == acceptedVersion?.identity ||
                      (watcher?.url == location && watcher?.identity == loaded.identity) else {
                    await reconcile()
                    return
                }
                url = location
                if isWatching { installWatcher() }
            }
            // A pre-read stamp may cause an extra check, but can never claim
            // that older bytes describe a newer filesystem observation.
            observedStamp = stamp
            reconcile(loaded)
        } catch {
            guard checkID == token, url == originalURL, !isSaving else { return }
            let exists = await Task.detached { FileManager.default.fileExists(atPath: originalURL.path) }.value
            guard checkID == token else { return }
            isMissing = !exists
            issue = isMissing ? nil : "The SQL file is unreadable or is no longer a regular UTF-8 file. The local draft has been kept."
            observedStamp = nil
        }
    }

    private func reconcile(_ loaded: LoadedSQLFile) {
        isMissing = false
        issue = nil
        if loaded.sha256 == acceptedSHA256 {
            acceptedVersion = loaded.version
            conflict = nil
        } else if !isDirty || SQLFileBinding.digestText(text) == loaded.sha256 {
            accept(loaded, restored: restoredBinding)
        } else if conflict?.version != loaded.version {
            conflict = SQLFileConflict(url: url, external: loaded)
        }
    }

    /// Save always re-reads the file. Watcher delivery is an optimization, not
    /// permission to replace bytes that have not been reviewed.
    @discardableResult
    func save() throws -> LoadedSQLFile {
        guard !requiresSaveAs else { throw SQLFileDocumentFailure(message: statusMessage) }
        guard !isSaving else { throw SQLFileDocumentFailure(message: "This SQL file is already being saved.") }
        guard let acceptedSHA256 else {
            throw SQLFileDocumentFailure(message: "The recovered file has no accepted disk version. Use Save As and review the destination.")
        }
        isSaving = true
        checkID = UUID()
        isChecking = false
        defer { isSaving = false }
        do {
            let current = try SQLFileBinding.read(url)
            guard current.sha256 == acceptedSHA256 else {
                let hadLocalChanges = isDirty
                reconcile(current)
                if !hadLocalChanges || SQLFileBinding.digestText(text) == current.sha256 {
                    accept(current, restored: false)
                    return current
                }
                throw SQLFileBindingError.changed
            }
            let saved = try SQLFileBinding.write(text, to: url, expectedVersion: current.version)
            accept(saved, restored: false)
            if isWatching { installWatcher() }
            return saved
        } catch {
            recordFailure(error)
            if !FileManager.default.fileExists(atPath: url.path) { isMissing = true }
            throw error
        }
    }

    func resolve(conflictID: UUID, decision: SQLFileConflictDecision, expectedText: String?) async throws {
        guard !isSaving, let reviewed = conflict, reviewed.id == conflictID,
              expectedText.map({ Self.sameBytes($0, text) }) != false else {
            throw SQLFileDocumentFailure(message: "The file or local draft changed after comparison. Review both versions again.")
        }
        let local = text
        let location = url
        isSaving = true
        checkID = UUID()
        isChecking = false
        defer { isSaving = false }
        do {
            let current = try await Task.detached { try SQLFileBinding.read(location) }.value
            guard url == location, conflict?.id == conflictID, Self.sameBytes(text, local) else {
                throw SQLFileDocumentFailure(message: "The local draft changed after comparison. Review both versions again.")
            }
            guard current.version == reviewed.version else {
                reconcile(current)
                throw SQLFileDocumentFailure(message: "The file changed again after comparison. Review the latest external version.")
            }
            switch decision {
            case .useExternal:
                accept(current, restored: false)
            case .replaceExternal:
                let saved = try await Task.detached {
                    try SQLFileBinding.write(local, to: location, expectedVersion: reviewed.version)
                }.value
                // A later programmatic edit stays dirty against the saved version.
                accept(saved, replacingText: Self.sameBytes(text, local), restored: false)
            }
            if isWatching { installWatcher() }
        } catch {
            recordFailure(error)
            if !FileManager.default.fileExists(atPath: location.path) { isMissing = true }
            throw error
        }
    }

    func acceptSaved(_ loaded: LoadedSQLFile) { accept(loaded, replacingText: false, restored: false) }

    func retainRecovery(_ url: URL?) {
        if recoveryURL == nil { recoveryURL = url }
    }

    func recordFailure(_ error: any Error) {
        issue = error.localizedDescription
        if let url = (error as? SQLFileBindingError)?.recoveryURL { recoveryURL = url }
    }

    private func accept(_ loaded: LoadedSQLFile, replacingText: Bool = true, restored: Bool) {
        if replacingText { text = loaded.text }
        acceptedSHA256 = loaded.sha256
        acceptedVersion = loaded.version
        restoredBinding = restored
        conflict = nil
        issue = nil
        isMissing = false
        observedStamp = nil
    }

    private struct FileStamp: Equatable, Sendable {
        let inode: UInt64
        let size: UInt64
        let modified: Date

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            self.inode = inode.uint64Value
            self.size = size.uint64Value
            self.modified = modified
        }
    }
}
