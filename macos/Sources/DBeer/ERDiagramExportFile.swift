import CryptoKit
import Darwin
import Foundation

enum ERDiagramExportPublicationPhase: Equatable, Sendable { case writing, beforePublish, afterPublish }
struct ERDiagramExportPublicationProgress: Sendable {
    let phase: ERDiagramExportPublicationPhase
    let offset: Int
    let workerIsMainThread: Bool
}
typealias ERDiagramExportPublicationHook = @Sendable (ERDiagramExportPublicationProgress) async throws -> Void
typealias ERDiagramExportCleanupHook = @Sendable () async -> Void

final class ERDiagramExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        try Task.checkCancellation()
        guard lock.withLock({ !cancelled }) else { throw CancellationError() }
    }
    func admit(_ operation: () throws -> Void) throws {
        try lock.withLock {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            try operation()
        }
    }
}

/// A new-file export never displaces an existing pathname. Parent and file
/// identities remain pinned across rendering, writing and publication.
final class ERDiagramExportFile {
    private struct Identity: Equatable, Sendable {
        let device: UInt64, inode: UInt64
        init(_ metadata: stat) { device = UInt64(bitPattern: Int64(metadata.st_dev)); inode = UInt64(metadata.st_ino) }
    }
    private struct Stamp: Equatable, Sendable {
        let identity: Identity
        let size: Int64, seconds: Int64, nanos: Int64
        init(_ value: stat) {
            identity = Identity(value); size = value.st_size
            seconds = Int64(value.st_mtimespec.tv_sec); nanos = Int64(value.st_mtimespec.tv_nsec)
        }
    }
    private let destination: URL
    private let parent: Int32
    private let file: Int32
    private let identity: Identity
    private let parentIdentity: Identity
    private let temporary: String
    private var location: String
    private var expectedHash: Data?
    private var committed = false
    private var retired = false

    @MainActor init(destination: URL) throws {
        guard Self.isLocalFile(destination) else { throw ERDiagramExportFailure.write }
        let parent = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw ERDiagramExportFailure.write }
        var parentStat = stat()
        guard fstat(parent, &parentStat) == 0 else { Darwin.close(parent); throw ERDiagramExportFailure.write }
        var existing = stat()
        let target = fstatat(parent, destination.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW)
        if target == 0 { Darwin.close(parent); throw ERDiagramExportFailure.exists }
        guard errno == ENOENT else { Darwin.close(parent); throw ERDiagramExportFailure.write }
        let temporary = ".dbeer-er-" + UUID().uuidString + ".tmp"
        let file = openat(parent, temporary, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { Darwin.close(parent); throw ERDiagramExportFailure.write }
        var fileStat = stat()
        guard fchmod(file, 0o600) == 0, fstat(file, &fileStat) == 0 else {
            Darwin.close(file); _ = unlinkat(parent, temporary, 0); Darwin.close(parent); throw ERDiagramExportFailure.write
        }
        self.destination = destination; self.parent = parent; self.file = file
        self.identity = Identity(fileStat); self.parentIdentity = Identity(parentStat)
        self.temporary = temporary; self.location = temporary
    }

    deinit { Darwin.close(file); Darwin.close(parent) }

    @MainActor func publish(_ data: Data, cancellation: ERDiagramExportCancellation,
                 isCurrent: @escaping @MainActor @Sendable () -> Bool,
                 hook: ERDiagramExportPublicationHook? = nil, didCommit: () -> Void = {}) async throws {
        guard !committed, !retired, location == temporary, data.count <= ERDiagramExportLimits.fileBytes else { throw ERDiagramExportFailure.invalid }
        try cancellation.check()
        guard isCurrent(), parentMatches(), owns(at: temporary) else { throw CancellationError() }
        let verification = try Verification(parent: parent, file: file, name: temporary, identity: identity)
        let worker = Task.detached(priority: .userInitiated) {
            try await verification.write(data, cancellation: cancellation, current: isCurrent, hook: hook)
        }
        let receipt = try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel(); worker.cancel() }
        expectedHash = receipt.hash
        try cancellation.admit {
            guard isCurrent(), parentMatches(), owns(at: temporary, stamp: receipt.stamp) else { throw CancellationError() }
            guard renameatx_np(parent, temporary, parent, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
                throw errno == EEXIST ? ERDiagramExportFailure.exists : ERDiagramExportFailure.changed
            }
            location = destination.lastPathComponent
        }
        let published = try Verification(parent: parent, file: file, name: location, identity: identity)
        let verifier = Task.detached(priority: .userInitiated) {
            try await published.verify(bytes: data.count, expected: receipt.hash, phase: .afterPublish, cancellation: cancellation, current: isCurrent, hook: hook)
        }
        let final = try await withTaskCancellationHandler { try await verifier.value } onCancel: { cancellation.cancel(); verifier.cancel() }
        try cancellation.admit {
            guard isCurrent(), parentMatches(), owns(at: location, stamp: final.stamp) else { throw CancellationError() }
            committed = true
            didCommit()
        }
    }

    /// Await workers before this call. An externally modified published inode
    /// is kept even when its pathname still points to our original file.
    @MainActor func finishOwnership(hook: ERDiagramExportCleanupHook? = nil) async {
        guard !retired else { return }
        retired = true
        guard !committed else { return }
        let directory = dup(parent)
        guard directory >= 0 else { return }
        let receipt = Cleanup(parent: directory, name: location, identity: identity,
                              privateFile: location == temporary, hash: expectedHash)
        await Task.detached(priority: .utility) { await hook?(); receipt.perform() }.value
    }

    private func owns(at name: String, stamp: Stamp? = nil) -> Bool {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0, value.st_mode & S_IFMT == S_IFREG,
              Identity(value) == identity, value.st_nlink == 1, value.st_mode & 0o777 == 0o600 else { return false }
        return stamp == nil || Stamp(value) == stamp
    }
    private func parentMatches() -> Bool {
        let current = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { return false }
        defer { Darwin.close(current) }
        var value = stat()
        return fstat(current, &value) == 0 && Identity(value) == parentIdentity
    }
    private static func isLocalFile(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") && url.query == nil && url.fragment == nil &&
            url.path.hasPrefix("/") && !url.path.contains("\0") && !url.lastPathComponent.isEmpty && url.path != "/"
    }

    private final class Verification: Sendable {
        struct Receipt: Sendable { let stamp: Stamp; let hash: Data }
        let parent: Int32, file: Int32
        let name: String
        let identity: Identity
        init(parent: Int32, file: Int32, name: String, identity: Identity) throws {
            let directory = dup(parent), descriptor = dup(file)
            guard directory >= 0, descriptor >= 0 else {
                if directory >= 0 { Darwin.close(directory) }; if descriptor >= 0 { Darwin.close(descriptor) }
                throw ERDiagramExportFailure.write
            }
            self.parent = directory; self.file = descriptor; self.name = name; self.identity = identity
        }
        deinit { Darwin.close(file); Darwin.close(parent) }
        func write(_ data: Data, cancellation: ERDiagramExportCancellation,
                   current: @escaping @MainActor @Sendable () -> Bool, hook: ERDiagramExportPublicationHook?) async throws -> Receipt {
            var offset = 0
            while offset < data.count {
                try cancellation.check(); guard await current() else { throw CancellationError() }
                let count = min(65_536, data.count - offset), chunk = data.subdata(in: offset..<(offset + count))
                try chunk.withUnsafeBytes { buffer in
                    var written = 0
                    while written < buffer.count {
                        try cancellation.check()
                        let amount = pwrite(file, buffer.baseAddress!.advanced(by: written), buffer.count - written, off_t(offset + written))
                        if amount < 0 && errno == EINTR { continue }
                        guard amount > 0 else { throw ERDiagramExportFailure.write }
                        written += amount
                    }
                }
                offset += count
                try await hook?(.init(phase: .writing, offset: offset, workerIsMainThread: Self.onMainThread()))
            }
            try cancellation.check()
            guard fsync(file) == 0 else { throw ERDiagramExportFailure.write }
            let digest = Data(SHA256.hash(data: data))
            return try await verify(bytes: data.count, expected: digest, phase: .beforePublish, cancellation: cancellation, current: current, hook: hook)
        }
        func verify(bytes: Int, expected: Data, phase: ERDiagramExportPublicationPhase, cancellation: ERDiagramExportCancellation,
                    current: @escaping @MainActor @Sendable () -> Bool, hook: ERDiagramExportPublicationHook?) async throws -> Receipt {
            try cancellation.check()
            guard bytes <= ERDiagramExportLimits.fileBytes else { throw ERDiagramExportFailure.tooLarge }
            var before = stat()
            guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG, Identity(before) == identity,
                  before.st_nlink == 1, before.st_size == bytes else { throw ERDiagramExportFailure.changed }
            var hash = SHA256(), offset = 0
            var buffer = [UInt8](repeating: 0, count: 65_536)
            repeat {
                try cancellation.check(); guard await current() else { throw CancellationError() }
                let wanted = min(buffer.count, bytes - offset)
                let count = pread(file, &buffer, wanted, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count >= 0, count == wanted else { throw ERDiagramExportFailure.changed }
                if count > 0 { hash.update(data: Data(buffer.prefix(count))); offset += count }
                try await hook?(.init(phase: phase, offset: offset, workerIsMainThread: Self.onMainThread()))
            } while offset < bytes
            try cancellation.check()
            var after = stat(), named = stat()
            let digest = Data(hash.finalize())
            guard digest == expected, fstat(file, &after) == 0, Stamp(before) == Stamp(after),
                  fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, Stamp(named) == Stamp(after),
                  named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1, named.st_mode & 0o777 == 0o600,
                  fsync(file) == 0, fsync(parent) == 0 else { throw ERDiagramExportFailure.changed }
            return Receipt(stamp: Stamp(after), hash: digest)
        }
        private static func onMainThread() -> Bool { Thread.isMainThread }
    }

    private final class Cleanup: Sendable {
        let parent: Int32
        let name: String
        let identity: Identity
        let privateFile: Bool
        let hash: Data?
        init(parent: Int32, name: String, identity: Identity, privateFile: Bool, hash: Data?) {
            self.parent = parent; self.name = name; self.identity = identity; self.privateFile = privateFile; self.hash = hash
        }
        deinit { Darwin.close(parent) }
        func perform() {
            let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { return }
            defer { Darwin.close(descriptor) }
            var before = stat()
            guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  Identity(before) == identity, before.st_nlink == 1, before.st_size >= 0,
                  before.st_size <= ERDiagramExportLimits.fileBytes else { return }
            if !privateFile {
                guard let hash else { return }
                var calculated = SHA256(), offset = 0
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while offset < before.st_size {
                    let count = pread(descriptor, &buffer, min(buffer.count, Int(before.st_size) - offset), off_t(offset))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return }
                    calculated.update(data: Data(buffer.prefix(count))); offset += count
                }
                guard Data(calculated.finalize()) == hash else { return }
            }
            var after = stat(), named = stat()
            guard fstat(descriptor, &after) == 0, Stamp(before) == Stamp(after),
                  fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, Stamp(named) == Stamp(after),
                  named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1 else { return }
            _ = unlinkat(parent, name, 0); _ = fsync(parent)
        }
    }
}
