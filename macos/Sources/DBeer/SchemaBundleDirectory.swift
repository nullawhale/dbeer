import CryptoKit
import Darwin
import Foundation

enum SchemaBundlePublicationStage { case willPublish, didPublish }

/// A new bundle is assembled in a private, owned sibling directory. Every file
/// is written through retained descriptors; publication never replaces a path.
final class SchemaBundleDirectory {
    private struct Identity: Equatable, Sendable {
        let device: dev_t; let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }
    private struct OpenFile {
        let description: SchemaBundleFile; var descriptor: Int32?; let identity: Identity
        var bytes: Int64 = 0; var hash = SHA256(); var finished = false
    }
    private let destination: URL
    private let parent: Int32
    private let directory: Int32
    private let directoryIdentity: Identity
    private let temporary: String
    private var files: [String: OpenFile] = [:]
    private var declaredBytes: Int64 = 0
    private var published = false
    private var retired = false
    private var location: String

    init(destination: URL) throws {
        guard SQLFileBinding.isLocalFile(destination), destination.lastPathComponent != ".", destination.lastPathComponent != "..",
              destination.lastPathComponent.utf8.count <= 255 else { throw SchemaBundleFailure.invalid }
        let parent = try Self.openDirectory(destination.deletingLastPathComponent())
        var keepParent = false
        defer { if !keepParent { Darwin.close(parent) } }
        var existing = stat()
        guard fstatat(parent, destination.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw SchemaBundleFailure.changed }
        let temporary = ".dbeer-schema-" + UUID().uuidString
        guard mkdirat(parent, temporary, 0o700) == 0 else { throw SchemaBundleFailure.write }
        let directory = openat(parent, temporary, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw SchemaBundleFailure.write }
        var metadata = stat()
        let observed = fstat(directory, &metadata) == 0
        guard observed, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o777 == 0o700 else {
            var named = stat()
            if observed, fstatat(parent, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0, Identity(named) == Identity(metadata) { _ = unlinkat(parent, temporary, AT_REMOVEDIR) }
            Darwin.close(directory); throw SchemaBundleFailure.write
        }
        self.destination = destination; self.parent = parent; self.directory = directory; self.temporary = temporary
        directoryIdentity = Identity(metadata); location = temporary; keepParent = true
    }
    deinit { cleanup(); Darwin.close(directory); Darwin.close(parent) }

    func begin(_ file: SchemaBundleFile) throws {
        try Task.checkCancellation()
        guard file.valid, !file.path.isEmpty, file.path == (file.path as NSString).lastPathComponent,
              file.path != ".", file.path != "..", !file.path.contains("\0"), file.path.utf8.count <= 100,
              files[file.path] == nil, files.count <= 10_001, file.bytes <= SchemaBundleManifest.maximumBytes - declaredBytes, !published else { throw SchemaBundleFailure.invalid }
        let descriptor = openat(directory, file.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SchemaBundleFailure.write }
        var metadata = stat()
        let observed = fstat(descriptor, &metadata) == 0
        guard observed, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600 else {
            var named = stat()
            if observed, fstatat(directory, file.path, &named, AT_SYMLINK_NOFOLLOW) == 0, Identity(named) == Identity(metadata) { _ = unlinkat(directory, file.path, 0) }
            Darwin.close(descriptor); throw SchemaBundleFailure.write
        }
        files[file.path] = OpenFile(description: file, descriptor: descriptor, identity: Identity(metadata))
        declaredBytes += file.bytes
    }
    func append(_ data: Data, to file: SchemaBundleFile) throws {
        try Task.checkCancellation()
        guard var value = files[file.path], let descriptor = value.descriptor, value.description == file, !value.finished,
              Int64(data.count) <= file.bytes - value.bytes else { throw SchemaBundleFailure.invalid }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SchemaBundleFailure.write }
                offset += count
            }
        }
        value.bytes += Int64(data.count); value.hash.update(data: data); files[file.path] = value
    }
    func finish(_ file: SchemaBundleFile) throws {
        try Task.checkCancellation()
        guard var value = files[file.path], let descriptor = value.descriptor, value.description == file, !value.finished, value.bytes == file.bytes,
              value.hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256,
              owns(value) else { throw SchemaBundleFailure.invalid }
        Darwin.close(descriptor); value.descriptor = nil; value.finished = true; files[file.path] = value
    }
    /// Only immutable descriptor snapshots leave the main actor. Rename and
    /// success admission run together with their current-context checks.
    @MainActor
    func publish(expectedFiles: [SchemaBundleFile], cancellation: SchemaBundlePublicationCancellation = .init(),
                 isCurrent: @escaping @MainActor @Sendable () -> Bool = { true },
                 hook: ((SchemaBundlePublicationStage) throws -> Void)? = nil,
                 verificationHook: SchemaBundleVerificationHook? = nil, didCommit: () -> Void = {}) async throws {
        try cancellation.check()
        guard !published, !retired, expectedFiles.count == files.count, Set(expectedFiles.map(\.path)).count == expectedFiles.count,
              expectedFiles.allSatisfy({ file in files[file.path].map { $0.finished && $0.description == file } == true }) else { throw SchemaBundleFailure.changed }
        let snapshots = try expectedFiles.map { file -> Verification.File in
            guard let value = files[file.path] else { throw SchemaBundleFailure.changed }
            return .init(description: file, identity: value.identity)
        }
        let verification = try Verification(directory: directory, parent: parent, files: snapshots)
        do {
            try await verify(verification, phase: .beforePublish, cancellation: cancellation, current: isCurrent, hook: verificationHook)
            try cancellation.check()
            guard isCurrent(), parentMatches(), ownsDirectory(at: temporary) else { throw CancellationError() }
            try hook?(.willPublish)
            try cancellation.check()
            guard isCurrent(), parentMatches(), ownsDirectory(at: temporary),
                  renameatx_np(parent, temporary, parent, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw SchemaBundleFailure.changed }
            location = destination.lastPathComponent
            try hook?(.didPublish)
            try cancellation.check()
            guard isCurrent(), parentMatches(), ownsDirectory(at: location) else { throw SchemaBundleFailure.changed }
            try await verify(verification, phase: .afterPublish, cancellation: cancellation, current: isCurrent, hook: verificationHook)
            // This short, non-suspending commit is also the UI success point.
            // A queued Stop either wins before it, or observes completed work.
            try cancellation.commit {
                guard isCurrent(), parentMatches(), ownsDirectory(at: location) else { throw CancellationError() }
                published = true
                files = [:]
                didCommit()
            }
        } catch {
            if location != temporary, ownsDirectory(at: location),
               renameatx_np(parent, location, parent, temporary, UInt32(RENAME_EXCL)) == 0 { location = temporary }
            throw error
        }
    }
    @MainActor
    private func verify(_ snapshot: Verification, phase: SchemaBundleVerificationPhase, cancellation: SchemaBundlePublicationCancellation,
                        current: @escaping @MainActor @Sendable () -> Bool, hook: SchemaBundleVerificationHook?) async throws {
        let worker = Task.detached(priority: .userInitiated) { try await snapshot.verify(phase: phase, cancellation: cancellation, current: current, hook: hook) }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel(); worker.cancel() }
    }
    /// Error cleanup can also touch thousands of files. Transfer an immutable
    /// identity receipt and duplicated directory handles to a detached worker.
    @MainActor
    func finishOwnership() async {
        guard !retired else { return }
        retired = true
        guard !published else { return }
        let receipt = Cleanup(directory: dup(directory), parent: dup(parent), identity: directoryIdentity, location: location,
                              files: files.values.map { .init(path: $0.description.path, identity: $0.identity, descriptor: $0.descriptor) })
        files = [:]
        await Task.detached(priority: .utility) { receipt.perform() }.value
    }
    private func owns(_ value: OpenFile) -> Bool {
        var named = stat()
        guard fstatat(directory, value.description.path, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(named) == value.identity, named.st_mode & S_IFMT == S_IFREG,
              named.st_nlink == 1, named.st_size == value.bytes, named.st_mode & 0o777 == 0o600 else { return false }
        if let descriptor = value.descriptor { var opened = stat(); return fstat(descriptor, &opened) == 0 && Identity(opened) == value.identity }
        return true
    }
    private func ownsIdentity(_ value: OpenFile) -> Bool {
        var metadata = stat()
        return fstatat(directory, value.description.path, &metadata, AT_SYMLINK_NOFOLLOW) == 0 && Identity(metadata) == value.identity && metadata.st_mode & S_IFMT == S_IFREG && metadata.st_nlink == 1
    }
    private func ownsDirectory(at name: String) -> Bool {
        var opened = stat(), named = stat()
        return fstat(directory, &opened) == 0 && fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
            Identity(opened) == directoryIdentity && Identity(named) == directoryIdentity && named.st_mode & S_IFMT == S_IFDIR && named.st_mode & 0o777 == 0o700
    }
    private func parentMatches() -> Bool {
        guard let current = try? Self.openDirectory(destination.deletingLastPathComponent()) else { return false }
        defer { Darwin.close(current) }
        var pinned = stat(), actual = stat()
        return fstat(parent, &pinned) == 0 && fstat(current, &actual) == 0 && Identity(pinned) == Identity(actual)
    }
    private func cleanup() {
        guard !published, !retired else { return }
        for value in files.values { if ownsIdentity(value) { _ = unlinkat(directory, value.description.path, 0) }; if let descriptor = value.descriptor { Darwin.close(descriptor) } }
        files = [:]
        if ownsDirectory(at: location) { _ = unlinkat(parent, location, AT_REMOVEDIR) }
    }
    private final class Verification: Sendable {
        struct File: Sendable { let description: SchemaBundleFile; let identity: Identity }
        let directory: Int32
        let parent: Int32
        let files: [File]
        init(directory: Int32, parent: Int32, files: [File]) throws {
            let directoryCopy = dup(directory), parentCopy = dup(parent)
            guard directoryCopy >= 0, parentCopy >= 0 else {
                if directoryCopy >= 0 { Darwin.close(directoryCopy) }; if parentCopy >= 0 { Darwin.close(parentCopy) }
                throw SchemaBundleFailure.write
            }
            self.directory = directoryCopy; self.parent = parentCopy; self.files = files
        }
        deinit { Darwin.close(directory); Darwin.close(parent) }
        func verify(phase: SchemaBundleVerificationPhase, cancellation: SchemaBundlePublicationCancellation,
                    current: @escaping @MainActor @Sendable () -> Bool, hook: SchemaBundleVerificationHook?) async throws {
            try cancellation.check()
            guard await current() else { throw CancellationError() }
            try checkNames(cancellation)
            for file in files {
                try cancellation.check()
                guard await current() else { throw CancellationError() }
                let descriptor = openat(directory, file.description.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                guard descriptor >= 0 else { throw SchemaBundleFailure.changed }
                do {
                    try check(file, descriptor: descriptor)
                    guard fsync(descriptor) == 0 else { throw SchemaBundleFailure.write }
                    var hash = SHA256(), offset: Int64 = 0
                    var buffer = [UInt8](repeating: 0, count: 65_536)
                    repeat {
                        try cancellation.check()
                        guard await current() else { throw CancellationError() }
                        try await hook?(.init(phase: phase, fileID: file.description.id, offset: offset, workerIsMainThread: Self.runningOnMainThread()))
                        try cancellation.check()
                        if offset == file.description.bytes { break }
                        let requested = Int(min(Int64(buffer.count), file.description.bytes - offset))
                        let count = pread(descriptor, &buffer, requested, off_t(offset))
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw SchemaBundleFailure.changed }
                        try cancellation.check()
                        hash.update(data: Data(buffer.prefix(count))); offset += Int64(count)
                        await Task.yield()
                    } while true
                    guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.description.sha256 else { throw SchemaBundleFailure.changed }
                    try check(file, descriptor: descriptor)
                    Darwin.close(descriptor)
                } catch { Darwin.close(descriptor); throw error }
            }
            try checkNames(cancellation)
            try cancellation.check()
            guard await current() else { throw CancellationError() }
            guard fsync(directory) == 0, fsync(parent) == 0 else { throw SchemaBundleFailure.write }
            try cancellation.check()
        }
        private static func runningOnMainThread() -> Bool { Thread.isMainThread }
        private func check(_ file: File, descriptor: Int32) throws {
            var opened = stat(), named = stat()
            guard fstat(descriptor, &opened) == 0, fstatat(directory, file.description.path, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  Identity(opened) == file.identity, Identity(named) == file.identity, opened.st_mode & S_IFMT == S_IFREG,
                  opened.st_nlink == 1, opened.st_size == file.description.bytes, opened.st_mode & 0o777 == 0o600 else { throw SchemaBundleFailure.changed }
        }
        private func checkNames(_ cancellation: SchemaBundlePublicationCancellation) throws {
            let copy = dup(directory)
            guard copy >= 0 else { throw SchemaBundleFailure.write }
            guard let stream = fdopendir(copy) else { Darwin.close(copy); throw SchemaBundleFailure.write }
            defer { closedir(stream) }
            rewinddir(stream)
            var names: Set<String> = []
            while true {
                try cancellation.check()
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw SchemaBundleFailure.changed }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    String(validatingCString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
                }
                guard let name else { throw SchemaBundleFailure.changed }
                if name == "." || name == ".." { continue }
                guard names.count < 10_002, names.insert(name).inserted else { throw SchemaBundleFailure.changed }
            }
            guard names == Set(files.map { $0.description.path }) else { throw SchemaBundleFailure.changed }
        }
    }
    private final class Cleanup: Sendable {
        struct File: Sendable { let path: String; let identity: Identity; let descriptor: Int32? }
        let directory: Int32; let parent: Int32; let identity: Identity; let location: String; let files: [File]
        init(directory: Int32, parent: Int32, identity: Identity, location: String, files: [File]) {
            self.directory = directory; self.parent = parent; self.identity = identity; self.location = location; self.files = files
        }
        deinit { if directory >= 0 { Darwin.close(directory) }; if parent >= 0 { Darwin.close(parent) } }
        func perform() {
            for file in files {
                var named = stat()
                if directory >= 0, fstatat(directory, file.path, &named, AT_SYMLINK_NOFOLLOW) == 0,
                   Identity(named) == file.identity, named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1 { _ = unlinkat(directory, file.path, 0) }
                if let descriptor = file.descriptor { Darwin.close(descriptor) }
            }
            var named = stat()
            if directory >= 0, parent >= 0, fstatat(parent, location, &named, AT_SYMLINK_NOFOLLOW) == 0,
               Identity(named) == identity, named.st_mode & S_IFMT == S_IFDIR { _ = unlinkat(parent, location, AT_REMOVEDIR) }
        }
    }
    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw SchemaBundleFailure.invalid }
        // macOS uses intermediate aliases such as /var -> /private/var. Pin the
        // selected final directory and recheck its identity before publication.
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SchemaBundleFailure.changed }
        return descriptor
    }
}
