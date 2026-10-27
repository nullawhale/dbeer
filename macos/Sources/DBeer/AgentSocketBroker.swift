import Darwin
import Foundation

enum AgentSocketError: Error { case unavailable, unsafePath }

/// Blocking I/O uses independent queues. A client that stops reading cannot
/// hold the main actor or prevent cancellation, revocation or app shutdown.
final class AgentSocketBroker: @unchecked Sendable {
    static let maximumRequestBytes = 128 * 1_024
    static let maximumResponseBytes = 1_024 * 1_024
    static var directory: String { "/tmp/dev.dbeer.agent-\(geteuid())" }
    static var socketPath: String { directory + "/broker.sock" }

    private let lock = NSLock()
    private var listener: Int32 = -1
    private var lease: Int32 = -1
    private var peers: [UUID: AgentSocketPeer] = [:]
    private let path: String
    private let onRequest: @Sendable (UUID, AgentRequest) async -> AgentResponse
    private let onDisconnect: @Sendable (UUID) async -> Void

    init(path: String = AgentSocketBroker.socketPath,
         onRequest: @escaping @Sendable (UUID, AgentRequest) async -> AgentResponse,
         onDisconnect: @escaping @Sendable (UUID) async -> Void) {
        self.path = path
        self.onRequest = onRequest
        self.onDisconnect = onDisconnect
    }

    func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw AgentSocketError.unavailable }
        var metadata = stat()
        guard lstat(directory, &metadata) == 0, metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o777 == 0o700 else {
            throw AgentSocketError.unsafePath
        }
        let lease = open(directory + "/broker.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lease >= 0 else { throw AgentSocketError.unsafePath }
        var boundSocket = false
        var descriptor: Int32 = -1
        do {
            guard fstat(lease, &metadata) == 0, metadata.st_uid == geteuid(),
                  metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600,
                  flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw AgentSocketError.unavailable }
            if lstat(path, &metadata) == 0 {
                guard metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFSOCK,
                      metadata.st_mode & 0o777 == 0o600 else { throw AgentSocketError.unsafePath }
                guard unlink(path) == 0 else { throw AgentSocketError.unavailable }
            } else if errno != ENOENT { throw AgentSocketError.unsafePath }
            descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw AgentSocketError.unavailable }
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AgentSocketError.unsafePath }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw AgentSocketError.unavailable }
            boundSocket = true
            guard chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
                throw AgentSocketError.unavailable
            }
            lock.withLock { self.listener = descriptor; self.lease = lease }
            let listeningDescriptor = descriptor
            DispatchQueue(label: "dbeer.agents.accept", qos: .utility).async { [weak self] in
                self?.acceptClients(listeningDescriptor)
            }
        } catch {
            if descriptor >= 0 { Darwin.close(descriptor) }
            if boundSocket { _ = unlink(path) }
            Darwin.close(lease)
            throw error
        }
    }

    func stop() {
        let state = lock.withLock { () -> (Int32, Int32, [AgentSocketPeer]) in
            let state = (listener, lease, Array(peers.values))
            listener = -1; lease = -1; peers.removeAll()
            return state
        }
        if state.0 >= 0 { shutdown(state.0, SHUT_RDWR) }
        state.2.forEach { $0.stop() }
        if state.1 >= 0 { _ = unlink(path); Darwin.close(state.1) }
    }

    func disconnect(clientID: UUID) {
        lock.withLock { peers[clientID] }?.stop()
    }

    private func acceptClients(_ descriptor: Int32) {
        defer { Darwin.close(descriptor) }
        while lock.withLock({ listener == descriptor }) {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 500)
            if ready < 0 { if errno == EINTR { continue }; return }
            if ready == 0 { continue }
            guard lock.withLock({ listener == descriptor }) else { return }
            let client = accept(descriptor, nil, nil)
            if client < 0 { if [EINTR, EAGAIN].contains(errno) { continue }; return }
            // Darwin inherits O_NONBLOCK from the listener. Peer queues use
            // blocking reads and bounded writes, so clear it before dispatch.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else {
                Darwin.close(client); continue
            }
            let id = UUID()
            let peer = AgentSocketPeer(descriptor: client, request: { [weak self] request in
                guard let self else { return AgentResponse(id: request.id, ok: false, error: "Agent access is unavailable.") }
                return await self.onRequest(id, request)
            }, disconnected: { [weak self] in
                guard let self else { return }
                _ = self.lock.withLock { self.peers.removeValue(forKey: id) }
                await self.onDisconnect(id)
            })
            let admitted = lock.withLock { () -> Bool in
                guard listener == descriptor, peers.count < 8 else { return false }
                peers[id] = peer; return true
            }
            if admitted { peer.start() } else { Darwin.close(client) }
        }
    }

    deinit { stop() }
}

private final class AgentSocketPeer: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "dbeer.agents.write", qos: .utility)
    private var stopped = false
    private var outstanding = 0
    private let request: @Sendable (AgentRequest) async -> AgentResponse
    private let disconnected: @Sendable () async -> Void

    init(descriptor: Int32, request: @escaping @Sendable (AgentRequest) async -> AgentResponse,
         disconnected: @escaping @Sendable () async -> Void) {
        self.descriptor = descriptor; self.request = request; self.disconnected = disconnected
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }

    func start() {
        DispatchQueue(label: "dbeer.agents.read", qos: .utility).async { self.readRequests() }
    }

    func stop() {
        let first = lock.withLock { () -> Bool in
            guard !stopped else { return false }; stopped = true; return true
        }
        if first { shutdown(descriptor, SHUT_RDWR) }
    }

    private func readRequests() {
        defer {
            stop()
            Task { await disconnected() }
            // All writes finish or fail after shutdown before the fd is reused.
            writer.async { Darwin.close(self.descriptor) }
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8_192)
        var identifiers = Set<String>()
        while !lock.withLock({ stopped }) {
            let count = recv(descriptor, &chunk, chunk.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk.prefix(count))
            while let end = buffer.firstIndex(of: 10) {
                let frame = buffer[..<end]
                guard frame.count <= AgentSocketBroker.maximumRequestBytes,
                      let decoded = try? JSONDecoder().decode(AgentRequest.self, from: Data(frame)),
                      BackendMessage.validID(decoded.id), !identifiers.contains(decoded.id),
                      identifiers.count < 4_096 else { return }
                buffer.removeSubrange(...end)
                identifiers.insert(decoded.id)
                let admitted = lock.withLock { () -> Bool in
                    guard !stopped, outstanding < 16 else { return false }
                    outstanding += 1; return true
                }
                guard admitted else { return }
                Task {
                    guard !self.lock.withLock({ self.stopped }) else { return }
                    let response = await self.request(decoded)
                    self.write(response)
                }
            }
            guard buffer.count <= AgentSocketBroker.maximumRequestBytes else { return }
        }
    }

    private func write(_ response: AgentResponse) {
        guard let data = try? JSONEncoder().encode(response), data.count <= AgentSocketBroker.maximumResponseBytes else {
            stop(); return
        }
        writer.async {
            defer { self.lock.withLock { self.outstanding -= 1 } }
            guard !self.lock.withLock({ self.stopped }) else { return }
            var frame = data; frame.append(10)
            let succeeded = frame.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                var offset = 0
                while offset < raw.count {
                    let written = send(self.descriptor, base.advanced(by: offset), raw.count - offset, 0)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { return false }
                    offset += written
                }
                return true
            }
            if !succeeded { self.stop() }
        }
    }
}
