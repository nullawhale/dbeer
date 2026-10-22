import CryptoKit
import Darwin
import Foundation

struct LoadedSQLFile: Sendable {
    let text: String
    let sha256: String
}

enum SQLFileBindingError: LocalizedError {
    case read, changed, write, invalidTarget

    var errorDescription: String? {
        switch self {
        case .read: "The SQL file could not be opened as a local UTF-8 file."
        case .changed: "The bound SQL file changed or is unavailable. The draft is still open. Use Save As to choose where to save it."
        case .write: "The SQL file could not be saved. The draft and its file binding have been kept."
        case .invalidTarget: "Choose a local regular file for this SQL document."
        }
    }
}

/// Restoring a binding never reads or writes the file. Its last accepted bytes
/// are checked only when the user explicitly saves the recovered draft.
enum SQLFileBinding {
    private struct Contents {
        let data: Data
        let device: dev_t
        let inode: ino_t
        let permissions: mode_t

        var sha256: String { SQLFileBinding.digest(data) }
        func matches(_ other: Contents) -> Bool {
            device == other.device && inode == other.inode && data == other.data
        }
    }

    static func read(_ url: URL) throws -> LoadedSQLFile {
        do {
            let contents = try contents(url)
            guard let text = String(data: contents.data, encoding: .utf8) else { throw SQLFileBindingError.read }
            return LoadedSQLFile(text: text, sha256: contents.sha256)
        } catch { throw SQLFileBindingError.read }
    }

    /// A nil expected hash is reserved for a destination explicitly reviewed in
    /// the native Save As chooser. Ordinary Save must provide its accepted hash.
    static func write(_ text: String, to destination: URL, expectedSHA256: String?) throws -> String {
        guard isLocalFile(destination) else { throw SQLFileBindingError.invalidTarget }
        let original: Contents?
        do { original = try existingContents(destination) }
        catch { throw expectedSHA256 == nil ? SQLFileBindingError.invalidTarget : SQLFileBindingError.changed }
        if let expectedSHA256 {
            guard expectedSHA256.count == 64, original?.sha256 == expectedSHA256 else { throw SQLFileBindingError.changed }
        }

        let data = Data(text.utf8)
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".dbeer-sql-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SQLFileBindingError.write }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            if let original {
                guard fchmod(descriptor, original.permissions & 0o777) == 0 else { throw SQLFileBindingError.write }
            }
            try handle.close()

            let current = try existingContents(destination)
            if let original {
                guard let current, original.matches(current) else { throw SQLFileBindingError.changed }
                guard rename(temporary.path, destination.path) == 0 else { throw SQLFileBindingError.write }
            } else {
                guard current == nil else { throw SQLFileBindingError.changed }
                // A newly appeared destination must not be replaced by a Save As.
                guard link(temporary.path, destination.path) == 0 else { throw SQLFileBindingError.write }
            }
            return digest(data)
        } catch let error as SQLFileBindingError {
            try? handle.close()
            throw error
        } catch {
            try? handle.close()
            throw SQLFileBindingError.write
        }
    }

    private static func isLocalFile(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") &&
            url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil &&
            url.path.hasPrefix("/") && !url.path.contains("\0") && !url.lastPathComponent.isEmpty && url.path != "/"
    }

    private static func existingContents(_ url: URL) throws -> Contents? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw SQLFileBindingError.read
        }
        return try contents(url)
    }

    private static func contents(_ url: URL) throws -> Contents {
        guard isLocalFile(url) else { throw SQLFileBindingError.invalidTarget }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw SQLFileBindingError.read }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw SQLFileBindingError.read }
        let data = try handle.readToEnd() ?? Data()
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, Int64(data.count) == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw SQLFileBindingError.read }
        return Contents(data: data, device: after.st_dev, inode: after.st_ino, permissions: after.st_mode)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
