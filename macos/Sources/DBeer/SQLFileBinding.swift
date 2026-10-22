import CryptoKit
import Darwin
import Foundation

struct SQLFileIdentity: Codable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64

    fileprivate init(_ metadata: stat) {
        device = UInt64(bitPattern: Int64(metadata.st_dev))
        inode = UInt64(metadata.st_ino)
    }

    init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
}

struct SQLFileVersion: Codable, Equatable, Sendable {
    let identity: SQLFileIdentity
    let sha256: String
}

struct LoadedSQLFile: Equatable, Sendable {
    let text: String
    let sha256: String
    let identity: SQLFileIdentity
    var version: SQLFileVersion { SQLFileVersion(identity: identity, sha256: sha256) }
}

enum SQLFileBindingError: LocalizedError {
    case read, changed, write, invalidTarget
    case recovery(URL)

    var recoveryURL: URL? { if case .recovery(let url) = self { return url }; return nil }

    var errorDescription: String? {
        switch self {
        case .read: "The SQL file could not be opened as a local UTF-8 file."
        case .changed: "The SQL file changed or is unavailable. The local draft has been kept. Review the external version or use Save As."
        case .write: "The SQL file could not be saved. The draft and its file binding have been kept."
        case .invalidTarget: "Choose a local regular file for this SQL document."
        case .recovery(let url): "A concurrent file change was preserved at \(url.path). The local draft is still open. Review both versions before saving again."
        }
    }
}

/// Hooks exercise the filesystem boundary without depending on thread timing.
enum SQLFilePublicationStage { case willDisplace, didDisplace, willPublish, didPublish }

enum SQLFileBinding {
    private struct Contents {
        let data: Data
        let metadata: stat
        var identity: SQLFileIdentity { SQLFileIdentity(metadata) }
        var version: SQLFileVersion { SQLFileVersion(identity: identity, sha256: digest(data)) }
        var loaded: LoadedSQLFile? {
            // Foundation's String(data:encoding:) removes a UTF-8 BOM. Decode
            // exact bytes instead and reject invalid sequences by round-trip.
            let text = String(decoding: data, as: UTF8.self)
            guard Data(text.utf8) == data else { return nil }
            return LoadedSQLFile(text: text, sha256: digest(data), identity: identity)
        }
    }

    static func digestText(_ text: String) -> String { digest(Data(text.utf8)) }

    static func read(_ url: URL) throws -> LoadedSQLFile {
        guard isLocalFile(url) else { throw SQLFileBindingError.invalidTarget }
        let parent = try openParent(of: url)
        defer { close(parent) }
        guard let contents = try contents(at: url.lastPathComponent, in: parent),
              parentMatches(parent, url: url.deletingLastPathComponent()),
              let loaded = contents.loaded else { throw SQLFileBindingError.read }
        return loaded
    }

    /// A reviewed version binds replacement to one inode and its exact bytes.
    /// A nil version only creates a new destination; it cannot replace a file.
    static func write(_ text: String, to destination: URL, expectedVersion: SQLFileVersion?,
                      publicationHook: ((SQLFilePublicationStage, URL?) throws -> Void)? = nil) throws -> LoadedSQLFile {
        guard isLocalFile(destination) else { throw SQLFileBindingError.invalidTarget }
        var coordinationError: NSError?
        var result: Result<LoadedSQLFile, any Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { url in
            result = Result { try publish(text, to: url, expectedVersion: expectedVersion, hook: publicationHook) }
        }
        if let result { return try result.get() }
        throw SQLFileBindingError.write
    }

    /// Compatibility for callers that have a persisted content fingerprint but
    /// no live inode. Save As must capture a reviewed version before replacing.
    static func write(_ text: String, to destination: URL, expectedSHA256: String?) throws -> String {
        let version: SQLFileVersion?
        if let expectedSHA256 {
            guard let accepted = try? read(destination), accepted.sha256 == expectedSHA256 else { throw SQLFileBindingError.changed }
            version = accepted.version
        } else { version = nil }
        return try write(text, to: destination, expectedVersion: version).sha256
    }

    private static func publish(_ text: String, to destination: URL, expectedVersion: SQLFileVersion?,
                                hook: ((SQLFilePublicationStage, URL?) throws -> Void)?) throws -> LoadedSQLFile {
        let parent = try openParent(of: destination)
        defer { close(parent) }
        let directory = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        let original: Contents?
        do { original = try contents(at: name, in: parent) }
        catch { throw expectedVersion == nil ? SQLFileBindingError.invalidTarget : SQLFileBindingError.changed }
        if let expectedVersion {
            guard original?.version == expectedVersion else { throw SQLFileBindingError.changed }
        } else if original != nil { throw SQLFileBindingError.changed }

        let temporary = ".dbeer-sql-\(UUID().uuidString).tmp"
        let recovery = ".dbeer-sql-\(UUID().uuidString).recovery"
        var keepRecovery = false
        var displaced = false
        defer {
            _ = unlinkat(parent, temporary, 0)
            if !keepRecovery { _ = unlinkat(parent, recovery, 0) }
        }
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SQLFileBindingError.write }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(text.utf8))
            if let original, fchmod(descriptor, original.metadata.st_mode & 0o777) != 0 { throw SQLFileBindingError.write }
            try handle.synchronize()
            var written = stat()
            guard fstat(descriptor, &written) == 0 else { throw SQLFileBindingError.write }
            let publishedVersion = SQLFileVersion(identity: SQLFileIdentity(written), sha256: digestText(text))
            try handle.close()

            // Pin the parent and reviewed target immediately before moving
            // anything. Recheck the displaced inode so a pathname replacement
            // between these steps cannot silently lose the external bytes.
            guard parentMatches(parent, url: directory), try contents(at: name, in: parent)?.version == expectedVersion else {
                throw SQLFileBindingError.changed
            }
            try hook?(.willDisplace, nil)
            if expectedVersion != nil {
                guard renameatx_np(parent, name, parent, recovery, UInt32(RENAME_EXCL)) == 0 else { throw SQLFileBindingError.changed }
                displaced = true
                try hook?(.didDisplace, resolvedDirectory(parent, fallback: directory).appendingPathComponent(recovery))
                guard try contents(at: recovery, in: parent)?.version == expectedVersion else { throw SQLFileBindingError.changed }
            }
            guard parentMatches(parent, url: directory) else { throw SQLFileBindingError.changed }
            try hook?(.willPublish, displaced ? resolvedDirectory(parent, fallback: directory).appendingPathComponent(recovery) : nil)
            guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else { throw SQLFileBindingError.changed }
            try hook?(.didPublish, displaced ? resolvedDirectory(parent, fallback: directory).appendingPathComponent(recovery) : nil)
            let displacedVersion: SQLFileVersion?
            if displaced { displacedVersion = try contents(at: recovery, in: parent)?.version }
            else { displacedVersion = nil }
            guard parentMatches(parent, url: directory),
                  let published = try contents(at: name, in: parent), published.version == publishedVersion,
                  !displaced || displacedVersion == expectedVersion,
                  let loaded = published.loaded else {
                if displaced { keepRecovery = true }
                throw displaced ? SQLFileBindingError.recovery(resolvedDirectory(parent, fallback: directory).appendingPathComponent(recovery)) : SQLFileBindingError.changed
            }
            if displaced { _ = unlinkat(parent, recovery, 0); displaced = false }
            _ = fsync(parent)
            return loaded
        } catch {
            try? handle.close()
            if displaced {
                // Restore only into an absent path. A newer external version
                // wins its pathname; keep the displaced version in a named
                // recovery file instead of deleting it during cleanup.
                if renameatx_np(parent, recovery, parent, name, UInt32(RENAME_EXCL)) != 0 {
                    keepRecovery = true
                    _ = fsync(parent)
                    throw SQLFileBindingError.recovery(resolvedDirectory(parent, fallback: directory).appendingPathComponent(recovery))
                }
                _ = fsync(parent)
                displaced = false
                keepRecovery = false
                // A successful rollback consumed the recovery path. Report
                // the changed destination without exposing a stale location.
                if let error = error as? SQLFileBindingError, case .recovery = error {
                    throw SQLFileBindingError.changed
                }
            }
            if let error = error as? SQLFileBindingError { throw error }
            throw SQLFileBindingError.write
        }
    }

    static func isLocalFile(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") &&
            url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil &&
            url.path.hasPrefix("/") && !url.path.contains("\0") && !url.lastPathComponent.isEmpty && url.path != "/"
    }

    private static func openParent(of url: URL) throws -> Int32 {
        guard isLocalFile(url) else { throw SQLFileBindingError.invalidTarget }
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SQLFileBindingError.read }
        return descriptor
    }

    private static func parentMatches(_ descriptor: Int32, url: URL) -> Bool {
        var pinned = stat()
        guard fstat(descriptor, &pinned) == 0 else { return false }
        let current = open(url.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard current >= 0 else { return false }
        defer { close(current) }
        var metadata = stat()
        return fstat(current, &metadata) == 0 && SQLFileIdentity(pinned) == SQLFileIdentity(metadata)
    }

    private static func contents(at name: String, in parent: Int32) throws -> Contents? {
        let descriptor = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw SQLFileBindingError.read
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw SQLFileBindingError.read }
        let data = try handle.readToEnd() ?? Data()
        var after = stat()
        var pathname = stat()
        guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, Int64(data.count) == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              fstatat(parent, name, &pathname, AT_SYMLINK_NOFOLLOW) == 0,
              pathname.st_mode & S_IFMT == S_IFREG, SQLFileIdentity(pathname) == SQLFileIdentity(after),
              pathname.st_size == after.st_size, pathname.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              pathname.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw SQLFileBindingError.read }
        return Contents(data: data, metadata: after)
    }

    private static func resolvedDirectory(_ descriptor: Int32, fallback: URL) -> URL {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else { return fallback }
        return URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
