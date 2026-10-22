import Darwin
import Foundation

/// Observe both the item and its parent so replacing or deleting the file does
/// not strand observation on its old inode. This watcher never reads SQL.
@MainActor
final class SQLFileWatcher {
    private final class Registration: @unchecked Sendable {
        let descriptor: Int32
        let identity: SQLFileIdentity
        let source: any DispatchSourceFileSystemObject

        init?(url: URL, handler: @escaping @Sendable () -> Void) {
            descriptor = open(url.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { return nil }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG || metadata.st_mode & S_IFMT == S_IFDIR else {
                close(descriptor)
                return nil
            }
            identity = SQLFileIdentity(device: UInt64(bitPattern: Int64(metadata.st_dev)), inode: UInt64(metadata.st_ino))
            source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .revoke], queue: DispatchQueue.global(qos: .utility))
            source.setEventHandler(handler: handler)
            let descriptor = descriptor
            source.setCancelHandler { close(descriptor) }
            source.resume()
        }

        func cancel() { source.cancel() }

        func movedURL() -> URL? {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &path) == 0 else { return nil }
            let url = URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            guard !url.lastPathComponent.hasPrefix(".dbeer-sql-"), !url.pathComponents.contains(".git") else { return nil }
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG || metadata.st_mode & S_IFMT == S_IFDIR,
                  SQLFileIdentity(device: UInt64(bitPattern: Int64(metadata.st_dev)), inode: UInt64(metadata.st_ino)) == identity else { return nil }
            return url
        }
    }

    private(set) var url: URL
    var identity: SQLFileIdentity? { item?.identity }
    private let onChange: @MainActor (URL?) -> Void
    private var item: Registration?
    private var parent: Registration?
    private var pending: Task<Void, Never>?
    private var stopped = false

    init(url: URL, onChange: @escaping @MainActor (URL?) -> Void) {
        self.url = url.standardizedFileURL
        self.onChange = onChange
        rebuild()
    }

    deinit { item?.cancel(); parent?.cancel(); pending?.cancel() }

    func stop() {
        stopped = true
        pending?.cancel()
        pending = nil
        item?.cancel()
        parent?.cancel()
        item = nil
        parent = nil
    }

    private func rebuild() {
        item?.cancel()
        parent?.cancel()
        item = nil
        parent = nil
        guard !stopped, SQLFileBinding.isLocalFile(url) else { return }
        let event: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleChange() }
        }
        item = Registration(url: url, handler: event)
        var ancestor = url.deletingLastPathComponent()
        while true {
            if let registration = Registration(url: ancestor, handler: event) { parent = registration; break }
            let next = ancestor.deletingLastPathComponent()
            if next == ancestor { break }
            ancestor = next
        }
    }

    private func scheduleChange() {
        guard !stopped else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard let self, !self.stopped else { return }
            var metadata = stat()
            let currentExists = lstat(self.url.path, &metadata) == 0
            let moved = currentExists ? nil : self.item?.movedURL()
            if let moved { self.url = moved }
            self.rebuild()
            self.onChange(moved)
        }
    }
}
